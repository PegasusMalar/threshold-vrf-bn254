// Command vrfload drives load at a deployed coordinator and reports what came back.
//
// It measures three things and refuses to conflate them:
//
//   - how many requests were fulfilled at all, and how many were lost;
//   - how long each one took, as a distribution rather than an average;
//   - how the rate the operators actually sustained compares to the rate asked
//     for, which is where a ceiling shows up.
//
// Load is fired through a LoadGenerator contract so that a whole burst lands in
// one block. Sending one transaction per request would measure the tester's own
// nonce, not the operators.
package main

import (
	"context"
	"crypto/ecdsa"
	"encoding/json"
	"flag"
	"fmt"
	"math/big"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
)

const loadGeneratorABI = `[
  {"type":"function","name":"fire","stateMutability":"nonpayable",
   "inputs":[{"type":"uint32"},{"type":"uint32"},{"type":"uint32"}],"outputs":[{"type":"uint256"}]},
  {"type":"function","name":"requestCount","stateMutability":"view","inputs":[],"outputs":[{"type":"uint256"}]},
  {"type":"function","name":"requestsFrom","stateMutability":"view",
   "inputs":[{"type":"uint256"},{"type":"uint256"}],"outputs":[{"type":"uint256[]"}]},
  {"type":"function","name":"delivered","stateMutability":"view","inputs":[],"outputs":[{"type":"uint256"}]}
]`

const coordinatorABI = `[
  {"type":"function","name":"requests","stateMutability":"view","inputs":[{"type":"uint256"}],
   "outputs":[{"type":"address"},{"type":"uint256"},{"type":"uint32"},{"type":"uint32"},
              {"type":"bool"},{"type":"bool"},{"type":"bool"}]},
  {"type":"event","name":"RandomWordsFulfilled","anonymous":false,"inputs":[
    {"name":"requestId","type":"uint256","indexed":true},
    {"name":"outputSeed","type":"uint256","indexed":false},
    {"name":"subId","type":"uint256","indexed":true},
    {"name":"payment","type":"uint96","indexed":false},
    {"name":"nativePayment","type":"bool","indexed":false},
    {"name":"success","type":"bool","indexed":false},
    {"name":"onlyPremium","type":"bool","indexed":false}]}
]`

// pollGap is how often the fulfilment log is re-read. Fast enough that latency
// is measured to a fraction of a second, slow enough that nine operators keep
// their share of a public endpoint.
const pollGap = 500 * time.Millisecond

// settlement is when a fulfilment was first seen, and whether the consumer's
// callback ran — which is a separate question from the words being delivered.
type settlement struct {
	at         time.Time
	callbackOK bool
}

type outcome struct {
	id       *big.Int
	fired    time.Time
	settled  time.Time
	fulfille bool
	callback bool
}

func main() {
	var (
		rpcURL    = flag.String("rpc", "", "chain RPC endpoint")
		generator = flag.String("generator", "", "LoadGenerator address")
		coord     = flag.String("coordinator", "", "VRFCoordinator address")
		bursts    = flag.Int("bursts", 1, "how many bursts to fire")
		size      = flag.Int("size", 10, "requests per burst")
		gap       = flag.Duration("gap", 0, "wait between bursts; 0 fires them back to back")
		numWords  = flag.Int("words", 1, "words per request")
		cbGas     = flag.Int("callback-gas", 100_000, "callback gas per request")
		deadline  = flag.Duration("deadline", 3*time.Minute, "how long to wait for the last one")
		jsonOut   = flag.String("json", "", "also write the raw results here")
	)
	flag.Parse()

	if *rpcURL == "" || *generator == "" || *coord == "" {
		fail("-rpc, -generator and -coordinator are required")
	}
	keyHex := strings.TrimPrefix(os.Getenv("VRF_DEPLOYER_KEY"), "0x")
	if keyHex == "" {
		fail("VRF_DEPLOYER_KEY is not set")
	}
	key, err := crypto.HexToECDSA(keyHex)
	if err != nil {
		fail("VRF_DEPLOYER_KEY: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), *deadline+2*time.Minute)
	defer cancel()

	eth, err := ethclient.DialContext(ctx, *rpcURL)
	if err != nil {
		fail("dial: %v", err)
	}
	defer eth.Close()

	genABI, _ := abi.JSON(strings.NewReader(loadGeneratorABI))
	coordAbi, _ := abi.JSON(strings.NewReader(coordinatorABI))
	genAddr := common.HexToAddress(*generator)
	coordAddr := common.HexToAddress(*coord)

	firedBlock, err := eth.BlockNumber(ctx)
	if err != nil {
		fail("head: %v", err)
	}
	before := readCount(ctx, eth, genABI, genAddr)
	total := *bursts * *size
	fmt.Printf("firing %d requests in %d burst(s) of %d, %d word(s), %d gas callback\n",
		total, *bursts, *size, *numWords, *cbGas)

	// Watching starts before the first burst, not after the last. Polling only
	// once everything is away means every request fulfilled in the meantime is
	// first seen on the same scan and stamped with the same instant — which
	// reads as an identical latency for a whole wave, and is a property of the
	// measurement rather than of the service.
	seenAt := make(map[string]settlement)
	var seenMu sync.Mutex
	watchCtx, stopWatching := context.WithCancel(ctx)
	defer stopWatching()
	watching := make(chan struct{})
	go func() {
		defer close(watching)
		watchFulfilments(watchCtx, eth, coordAbi, coordAddr, firedBlock, &seenMu, seenAt)
	}()

	firedAt := make([]time.Time, 0, *bursts)
	for b := 0; b < *bursts; b++ {
		data, err := genABI.Pack("fire", uint32(*size), uint32(*numWords), uint32(*cbGas))
		if err != nil {
			fail("pack: %v", err)
		}
		start := time.Now()
		if err := send(ctx, eth, key, genAddr, data); err != nil {
			fail("burst %d: %v", b, err)
		}
		firedAt = append(firedAt, start)
		fmt.Printf("  burst %d away after %.2fs\n", b, time.Since(start).Seconds())
		if *gap > 0 && b < *bursts-1 {
			time.Sleep(*gap)
		}
	}
	firedWindow := time.Since(firedAt[0])

	ids := readIds(ctx, eth, genABI, genAddr, before, total)
	if len(ids) != total {
		fmt.Printf("!! generator recorded %d ids, expected %d\n", len(ids), total)
	}

	results := make([]outcome, len(ids))
	for i, id := range ids {
		// every request in burst b shares that burst's start
		results[i] = outcome{id: id, fired: firedAt[i/(*size)%len(firedAt)]}
	}

	fmt.Println("waiting for fulfilments...")
	watchUntil := time.Now().Add(*deadline)
	pending := len(results)
	for pending > 0 && time.Now().Before(watchUntil) {
		time.Sleep(pollGap)
		seenMu.Lock()
		for i := range results {
			if results[i].fulfille {
				continue
			}
			s, found := seenAt[results[i].id.String()]
			if !found {
				continue
			}
			results[i].fulfille = true
			results[i].callback = s.callbackOK
			results[i].settled = s.at
			pending--
		}
		seenMu.Unlock()
	}
	stopWatching()
	<-watching

	// One direct read each for whatever is still outstanding — a handful of
	// calls, not a flood. Without it a log the endpoint dropped would be
	// reported as a request that never came back, which is a very different
	// claim about the system.
	if pending > 0 {
		fmt.Printf("checking %d still-outstanding request(s) directly\n", pending)
		for i := range results {
			if results[i].fulfille {
				continue
			}
			fulfilled, callbackOK := requestState(ctx, eth, coordAbi, coordAddr, results[i].id)
			if fulfilled {
				results[i].fulfille = true
				results[i].callback = callbackOK
				// the log was missed, so the time it landed is not known: left
				// out of the latency figures rather than guessed at
				pending--
			}
		}
	}

	report(results, firedWindow, *jsonOut)
	if pending > 0 {
		os.Exit(1)
	}
}

// watchFulfilments records when each fulfilment was first seen, for as long as
// the context lives. One log scan per tick, whatever the size of the burst:
// asking after each request separately is, for fifty requests four times a
// second, two hundred calls a second at the endpoint the operators depend on,
// so the measurement would be throttling the thing it measures.
func watchFulfilments(
	ctx context.Context, eth *ethclient.Client, a abi.ABI, at common.Address,
	from uint64, mu *sync.Mutex, into map[string]settlement,
) {
	topic := a.Events["RandomWordsFulfilled"].ID
	next := from

	for {
		select {
		case <-ctx.Done():
			return
		case <-time.After(pollGap):
		}

		head, err := eth.BlockNumber(ctx)
		if err != nil || head < next {
			continue // a throttled read is a slow measurement, not a lost one
		}
		logs, err := eth.FilterLogs(ctx, ethereum.FilterQuery{
			FromBlock: new(big.Int).SetUint64(next),
			ToBlock:   new(big.Int).SetUint64(head),
			Addresses: []common.Address{at},
			Topics:    [][]common.Hash{{topic}},
		})
		if err != nil {
			continue
		}
		now := time.Now()
		mu.Lock()
		for _, l := range logs {
			if len(l.Topics) < 2 {
				continue
			}
			id := new(big.Int).SetBytes(l.Topics[1][:]).String()
			if _, already := into[id]; already {
				continue
			}
			// success says whether the consumer's callback ran, which is a
			// different thing from the randomness having been delivered
			var body struct {
				OutputSeed    *big.Int
				Payment       *big.Int
				NativePayment bool
				Success       bool
				OnlyPremium   bool
			}
			if err := a.UnpackIntoInterface(&body, "RandomWordsFulfilled", l.Data); err != nil {
				continue
			}
			into[id] = settlement{at: now, callbackOK: body.Success}
		}
		mu.Unlock()
		next = head + 1
	}
}

func report(results []outcome, firedWindow time.Duration, jsonPath string) {
	var latencies []float64
	fulfilled, callbackFailed := 0, 0
	var last time.Time
	for _, r := range results {
		if !r.fulfille {
			continue
		}
		fulfilled++
		if !r.callback {
			callbackFailed++
		}
		if r.settled.IsZero() {
			continue // fulfilled, but found by a direct read: the time is unknown
		}
		latencies = append(latencies, r.settled.Sub(r.fired).Seconds())
		if r.settled.After(last) {
			last = r.settled
		}
	}
	sort.Float64s(latencies)

	fmt.Println()
	fmt.Printf("  requests            %d\n", len(results))
	fmt.Printf("  fulfilled           %d\n", fulfilled)
	fmt.Printf("  never fulfilled     %d\n", len(results)-fulfilled)
	fmt.Printf("  callback failed     %d\n", callbackFailed)
	if len(latencies) == 0 {
		fmt.Println("  nothing came back")
		return
	}
	fmt.Printf("  latency  min %.2fs  P50 %.2fs  P95 %.2fs  P99 %.2fs  max %.2fs\n",
		latencies[0], pct(latencies, 50), pct(latencies, 95), pct(latencies, 99),
		latencies[len(latencies)-1])

	// Throughput measured over the window that actually mattered: from the first
	// request going out to the last answer coming back.
	span := last.Sub(results[0].fired).Seconds()
	if span > 0 {
		fmt.Printf("  sustained           %.2f fulfilments/s over %.1fs\n", float64(fulfilled)/span, span)
	}
	fmt.Printf("  all requests were in flight within %.2fs of each other\n", firedWindow.Seconds())

	if jsonPath != "" {
		rows := make([]map[string]any, 0, len(results))
		for _, r := range results {
			row := map[string]any{"id": r.id.String(), "fulfilled": r.fulfille, "callbackOk": r.callback}
			if r.fulfille {
				row["seconds"] = r.settled.Sub(r.fired).Seconds()
			}
			rows = append(rows, row)
		}
		body, _ := json.MarshalIndent(rows, "", "  ")
		_ = os.WriteFile(jsonPath, body, 0o644)
		fmt.Printf("  raw results in %s\n", jsonPath)
	}
}

func pct(sorted []float64, p int) float64 {
	if len(sorted) == 0 {
		return 0
	}
	i := (p * (len(sorted) - 1)) / 100
	return sorted[i]
}

func readCount(ctx context.Context, eth *ethclient.Client, a abi.ABI, at common.Address) int {
	data, _ := a.Pack("requestCount")
	out := call(ctx, eth, at, data)
	values, err := a.Unpack("requestCount", out)
	if err != nil {
		fail("requestCount: %v", err)
	}
	return int(values[0].(*big.Int).Int64())
}

func readIds(ctx context.Context, eth *ethclient.Client, a abi.ABI, at common.Address, from, count int) []*big.Int {
	data, _ := a.Pack("requestsFrom", big.NewInt(int64(from)), big.NewInt(int64(count)))
	out := call(ctx, eth, at, data)
	values, err := a.Unpack("requestsFrom", out)
	if err != nil {
		fail("requestsFrom: %v", err)
	}
	return values[0].([]*big.Int)
}

func requestState(ctx context.Context, eth *ethclient.Client, a abi.ABI, at common.Address, id *big.Int) (bool, bool) {
	data, _ := a.Pack("requests", id)
	out := call(ctx, eth, at, data)
	values, err := a.Unpack("requests", out)
	if err != nil {
		return false, false
	}
	return values[4].(bool), values[6].(bool)
}

func call(ctx context.Context, eth *ethclient.Client, to common.Address, data []byte) []byte {
	out, err := eth.CallContract(ctx, ethereumCall(to, data), nil)
	if err != nil {
		fail("call: %v", err)
	}
	return out
}

func send(ctx context.Context, eth *ethclient.Client, key *ecdsa.PrivateKey, to common.Address, data []byte) error {
	from := crypto.PubkeyToAddress(key.PublicKey)
	nonce, err := eth.PendingNonceAt(ctx, from)
	if err != nil {
		return err
	}
	chainID, err := eth.ChainID(ctx)
	if err != nil {
		return err
	}
	head, err := eth.HeaderByNumber(ctx, nil)
	if err != nil {
		return err
	}
	// The endpoint throttles under exactly the load this is meant to create, so
	// the harness has to ride that out. A burst that never leaves because the
	// tester was refused says nothing about the operators.
	var gas uint64
	for attempt := 0; ; attempt++ {
		gas, err = eth.EstimateGas(ctx, ethereumCallFrom(from, to, data))
		if err == nil {
			break
		}
		if attempt >= 5 {
			return fmt.Errorf("estimate: %w", err)
		}
		fmt.Printf("    estimate refused, retrying (%v)\n", err)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Duration(1<<attempt) * time.Second):
		}
	}

	tx := types.NewTx(&types.DynamicFeeTx{
		ChainID:   chainID,
		Nonce:     nonce,
		GasTipCap: big.NewInt(0),
		GasFeeCap: new(big.Int).Mul(head.BaseFee, big.NewInt(4)),
		Gas:       gas + gas/5,
		To:        &to,
		Data:      data,
	})
	signed, err := types.SignTx(tx, types.LatestSignerForChainID(chainID), key)
	if err != nil {
		return err
	}
	for attempt := 0; ; attempt++ {
		err := eth.SendTransaction(ctx, signed)
		if err == nil {
			break
		}
		if attempt >= 5 {
			return err
		}
		fmt.Printf("    send refused, retrying (%v)\n", err)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Duration(1<<attempt) * time.Second):
		}
	}
	for i := 0; i < 300; i++ {
		receipt, err := eth.TransactionReceipt(ctx, signed.Hash())
		if err == nil {
			if receipt.Status != types.ReceiptStatusSuccessful {
				return fmt.Errorf("burst transaction reverted: %s", signed.Hash())
			}
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return fmt.Errorf("burst transaction never mined: %s", signed.Hash())
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "error: "+format+"\n", args...)
	os.Exit(1)
}
