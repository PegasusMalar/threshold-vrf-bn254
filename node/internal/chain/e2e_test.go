//go:build integration

package chain_test

import (
	"context"
	"crypto/ecdsa"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"

	"threshold-vrf/node/internal/blsvrf"
	"threshold-vrf/node/internal/chain"
	"threshold-vrf/node/internal/dkg"
	"threshold-vrf/node/internal/session"
	"threshold-vrf/node/internal/threshold"
)

// anvil's first account
const devKey = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

const (
	operators = 9
	quorum    = 5
	rpcPort   = "8601"
)

// The whole pipeline on a live chain: a real Pedersen DKG produces a key, the
// key is deployed, a request is made, nine operators sign their shares, five of
// them are aggregated, and the resulting transaction is accepted by the
// contract. Nothing here is mocked except that the nine operators live in one
// process.
func TestEndToEndRequestIsFulfilledByTheNode(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	stop := startAnvil(t)
	defer stop()

	rpc := "http://127.0.0.1:" + rpcPort
	key, err := crypto.HexToECDSA(devKey)
	if err != nil {
		t.Fatal(err)
	}
	deployer := crypto.PubkeyToAddress(key.PublicKey)

	eth, err := ethclient.DialContext(ctx, rpc)
	if err != nil {
		t.Fatal(err)
	}
	defer eth.Close()
	chainID, err := eth.ChainID(ctx)
	if err != nil {
		t.Fatal(err)
	}
	tx := &txSender{t: t, eth: eth, key: key, from: deployer, chainID: chainID, ctx: ctx}

	// --- the ceremony ------------------------------------------------------
	shares, err := dkg.RunLocal(operators, quorum, 1)
	if err != nil {
		t.Fatal(err)
	}
	pk, err := blsvrf.SerializeG2(shares[0].GroupPublic)
	if err != nil {
		t.Fatal(err)
	}

	// --- deployment --------------------------------------------------------
	verifierABI, verifierBin := artifact(t, "VRFVerifier")
	args, err := verifierABI.Pack("", [4]*big.Int{pk[0], pk[1], pk[2], pk[3]}, uint64(1))
	if err != nil {
		t.Fatal(err)
	}
	verifier := tx.deploy(append(verifierBin, args...))
	t.Logf("verifier at %s", verifier)

	coordABI, coordBin := artifact(t, "VRFCoordinator")
	cap_ := new(big.Int).SetUint64(1_000_000_000_000_000) // 0.001 ETH ceiling
	args, err = coordABI.Pack(
		"", verifier, big.NewInt(0), big.NewInt(0), big.NewInt(0), cap_, cap_, big.NewInt(1e9),
	)
	if err != nil {
		t.Fatal(err)
	}
	coordinator := tx.deploy(append(coordBin, args...))
	t.Logf("coordinator at %s", coordinator)

	// --- subscription ------------------------------------------------------
	coordCalls := mustABI(t, `[
      {"type":"function","name":"subscriptions","stateMutability":"view","inputs":[],"outputs":[{"type":"address"}]},
      {"type":"function","name":"requestRandomWords","stateMutability":"nonpayable",
       "inputs":[{"type":"tuple","components":[
         {"name":"keyHash","type":"bytes32"},{"name":"subId","type":"uint256"},
         {"name":"requestConfirmations","type":"uint16"},
         {"name":"callbackGasLimit","type":"uint32"},{"name":"numWords","type":"uint32"},
         {"name":"extraArgs","type":"bytes"}]}],
       "outputs":[{"type":"uint256"}]}]`)
	subsCalls := mustABI(t, `[
      {"type":"function","name":"createSubscription","stateMutability":"nonpayable","inputs":[],"outputs":[{"type":"uint256"}]},
      {"type":"function","name":"addConsumer","stateMutability":"nonpayable","inputs":[{"type":"uint256"},{"type":"address"}],"outputs":[]}]`)

	subsAddr := common.BytesToAddress(tx.call(coordinator, pack(t, coordCalls, "subscriptions")))
	tx.send(subsAddr, pack(t, subsCalls, "createSubscription"))
	// the EOA is the consumer: a callback to an account with no code simply
	// succeeds, which is exactly what we want to isolate the protocol here
	tx.send(subsAddr, pack(t, subsCalls, "addConsumer", big.NewInt(1), deployer))

	from, err := eth.BlockNumber(ctx)
	if err != nil {
		t.Fatal(err)
	}

	// --- the request -------------------------------------------------------
	type randomWordsRequest struct {
		KeyHash              [32]byte
		SubId                *big.Int
		RequestConfirmations uint16
		CallbackGasLimit     uint32
		NumWords             uint32
		ExtraArgs            []byte
	}
	tx.send(coordinator, pack(t, coordCalls, "requestRandomWords", randomWordsRequest{
		SubId: big.NewInt(1), CallbackGasLimit: 500_000, NumWords: 3, ExtraArgs: []byte{},
	}))

	// --- the node ----------------------------------------------------------
	client, err := chain.Dial(ctx, rpc, coordinator, key)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	head, err := client.BlockNumber(ctx)
	if err != nil {
		t.Fatal(err)
	}
	requests, err := client.RequestsBetween(ctx, from, head)
	if err != nil {
		t.Fatal(err)
	}
	if len(requests) != 1 {
		t.Fatalf("expected one request, saw %d", len(requests))
	}
	req := requests[0]

	// the seed in the event must be the seed the contract will check against
	onChainSeed, err := client.SeedOf(ctx, req.ID)
	if err != nil {
		t.Fatal(err)
	}
	if onChainSeed != req.Seed {
		t.Fatalf("event seed %x != contract seed %x", req.Seed, onChainSeed)
	}

	// and the node must be able to reach the same value without asking anyone,
	// which is what keeps the RPC endpoint out of the trust boundary
	if derived := client.DeriveSeed(req.ID, req.Consumer); derived != onChainSeed {
		t.Fatalf("locally derived seed %x != contract seed %x", derived, onChainSeed)
	}

	open, err := client.IsOpen(ctx, req.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !open {
		t.Fatal("request is not open before fulfillment")
	}

	// nine operators sign, the session takes the first five that verify
	sess := session.New(req.Seed, shares[0].Commits, quorum, operators)
	for _, s := range shares {
		if sess.Ready() {
			break
		}
		if _, err := sess.Add(threshold.Partial{Index: s.Index, Sig: blsvrf.Sign(s.Secret, req.Seed)}); err != nil {
			t.Fatalf("partial from operator %d rejected: %v", s.Index, err)
		}
	}
	if !sess.Ready() {
		t.Fatal("threshold never reached")
	}
	signature, err := sess.Signature()
	if err != nil {
		t.Fatal(err)
	}

	hash, err := client.Fulfill(ctx, req.ID, signature)
	if err != nil {
		t.Fatalf("publishing failed: %v", err)
	}
	receipt, err := client.WaitMined(ctx, hash)
	if err != nil {
		t.Fatal(err)
	}
	if receipt.Status != types.ReceiptStatusSuccessful {
		t.Fatal("fulfillRandomWords reverted")
	}
	t.Logf("fulfilled in %d gas", receipt.GasUsed)

	open, err = client.IsOpen(ctx, req.ID)
	if err != nil {
		t.Fatal(err)
	}
	if open {
		t.Fatal("request still open after a successful fulfillment")
	}

	// Republishing must fail. The node no longer runs eth_estimateGas before
	// publishing — that was a round trip on the hot path — so a doomed
	// transaction now gets as far as the chain and reverts there. What matters
	// is that the coordinator refuses it, not where the refusal happens.
	second, err := client.Fulfill(ctx, req.ID, signature)
	if err != nil {
		return // rejected before it left, which is also fine
	}
	receipt, err = client.WaitMined(ctx, second)
	if err != nil {
		t.Fatal(err)
	}
	if receipt.Status == types.ReceiptStatusSuccessful {
		t.Fatal("the coordinator accepted a second fulfillment")
	}
}

/* ------------------------------ test harness ----------------------------- */

func startAnvil(t *testing.T) func() {
	t.Helper()
	cmd := exec.Command("anvil", "--silent", "--port", rpcPort)
	if err := cmd.Start(); err != nil {
		t.Skipf("anvil is not available: %v", err)
	}
	for i := 0; i < 50; i++ {
		time.Sleep(100 * time.Millisecond)
		if c, err := ethclient.Dial("http://127.0.0.1:" + rpcPort); err == nil {
			if _, err := c.ChainID(context.Background()); err == nil {
				c.Close()
				return func() { _ = cmd.Process.Kill() }
			}
			c.Close()
		}
	}
	_ = cmd.Process.Kill()
	t.Fatal("anvil did not come up")
	return func() {}
}

func artifact(t *testing.T, name string) (abi.ABI, []byte) {
	t.Helper()
	path := filepath.Join("..", "..", "..", "out", name+".sol", name+".json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Skipf("run `forge build` first: %v", err)
	}
	var art struct {
		ABI      json.RawMessage `json:"abi"`
		Bytecode struct {
			Object string `json:"object"`
		} `json:"bytecode"`
	}
	if err := json.Unmarshal(raw, &art); err != nil {
		t.Fatal(err)
	}
	parsed, err := abi.JSON(strings.NewReader(string(art.ABI)))
	if err != nil {
		t.Fatal(err)
	}
	return parsed, common.FromHex(art.Bytecode.Object)
}

func mustABI(t *testing.T, definition string) abi.ABI {
	t.Helper()
	parsed, err := abi.JSON(strings.NewReader(definition))
	if err != nil {
		t.Fatal(err)
	}
	return parsed
}

func pack(t *testing.T, a abi.ABI, method string, args ...interface{}) []byte {
	t.Helper()
	data, err := a.Pack(method, args...)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

type txSender struct {
	t       *testing.T
	ctx     context.Context
	eth     *ethclient.Client
	key     *ecdsa.PrivateKey
	from    common.Address
	chainID *big.Int
}

func (s *txSender) deploy(data []byte) common.Address {
	receipt := s.submit(nil, data)
	if receipt.ContractAddress == (common.Address{}) {
		s.t.Fatal("deployment produced no address")
	}
	return receipt.ContractAddress
}

func (s *txSender) send(to common.Address, data []byte) *types.Receipt {
	return s.submit(&to, data)
}

func (s *txSender) submit(to *common.Address, data []byte) *types.Receipt {
	s.t.Helper()
	nonce, err := s.eth.PendingNonceAt(s.ctx, s.from)
	if err != nil {
		s.t.Fatal(err)
	}
	head, err := s.eth.HeaderByNumber(s.ctx, nil)
	if err != nil {
		s.t.Fatal(err)
	}
	tx := types.NewTx(&types.DynamicFeeTx{
		ChainID:   s.chainID,
		Nonce:     nonce,
		GasTipCap: big.NewInt(1),
		GasFeeCap: new(big.Int).Mul(head.BaseFee, big.NewInt(4)),
		Gas:       8_000_000,
		To:        to,
		Data:      data,
	})
	signed, err := types.SignTx(tx, types.LatestSignerForChainID(s.chainID), s.key)
	if err != nil {
		s.t.Fatal(err)
	}
	if err := s.eth.SendTransaction(s.ctx, signed); err != nil {
		s.t.Fatal(err)
	}
	for i := 0; i < 100; i++ {
		receipt, err := s.eth.TransactionReceipt(s.ctx, signed.Hash())
		if err == nil {
			if receipt.Status != types.ReceiptStatusSuccessful {
				s.t.Fatalf("transaction reverted: %s", signed.Hash())
			}
			return receipt
		}
		time.Sleep(100 * time.Millisecond)
	}
	s.t.Fatal(fmt.Sprintf("transaction %s never mined", signed.Hash()))
	return nil
}

func (s *txSender) call(to common.Address, data []byte) []byte {
	s.t.Helper()
	res, err := s.eth.CallContract(s.ctx, ethereumCallMsg(s.from, to, data), nil)
	if err != nil {
		s.t.Fatal(err)
	}
	return res
}

// A node on a quiet chain must still report that it is scanning. Without that,
// "nothing is happening" and "I stopped looking" are the same reading, which is
// exactly the failure the operator monitor exists to catch.
func TestWatchReportsProgressOnAQuietChain(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	stop := startAnvil(t)
	defer stop()

	rpc := "http://127.0.0.1:" + rpcPort
	key, err := crypto.HexToECDSA(devKey)
	if err != nil {
		t.Fatal(err)
	}
	deployer := crypto.PubkeyToAddress(key.PublicKey)

	eth, err := ethclient.DialContext(ctx, rpc)
	if err != nil {
		t.Fatal(err)
	}
	defer eth.Close()
	chainID, err := eth.ChainID(ctx)
	if err != nil {
		t.Fatal(err)
	}
	tx := &txSender{t: t, eth: eth, key: key, from: deployer, chainID: chainID, ctx: ctx}

	// something with code at the coordinator address; it emits nothing
	verifierABI, verifierBin := artifact(t, "VRFVerifier")
	shares, err := dkg.RunLocal(operators, quorum, 1)
	if err != nil {
		t.Fatal(err)
	}
	pk, err := blsvrf.SerializeG2(shares[0].GroupPublic)
	if err != nil {
		t.Fatal(err)
	}
	args, err := verifierABI.Pack("", [4]*big.Int{pk[0], pk[1], pk[2], pk[3]}, uint64(1))
	if err != nil {
		t.Fatal(err)
	}
	quiet := tx.deploy(append(verifierBin, args...))

	client, err := chain.Dial(ctx, rpc, quiet, key)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	scanned := make(chan uint64, 8)
	watchCtx, done := context.WithCancel(ctx)
	defer done()
	go func() {
		_ = client.Watch(watchCtx, chain.WatchOptions{
			From:      0,
			Interval:  100 * time.Millisecond,
			OnRequest: func(chain.Request) { t.Error("a quiet chain produced a request") },
			OnScanned: func(head uint64) { scanned <- head },
			OnError:   func(err error) { t.Errorf("poll failed: %v", err) },
		})
	}()

	select {
	case head := <-scanned:
		if head == 0 {
			t.Fatal("reported scanning block zero")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no progress reported in five seconds on a reachable chain")
	}
}

// The failure this replaces: a poll that errors every time used to leave the
// loop spinning in silence, looking healthy from the outside while scanning
// nothing at all.
func TestWatchReportsAChainThatWentAway(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	stop := startAnvil(t)
	rpc := "http://127.0.0.1:" + rpcPort
	key, err := crypto.HexToECDSA(devKey)
	if err != nil {
		t.Fatal(err)
	}
	deployer := crypto.PubkeyToAddress(key.PublicKey)

	eth, err := ethclient.DialContext(ctx, rpc)
	if err != nil {
		t.Fatal(err)
	}
	chainID, err := eth.ChainID(ctx)
	if err != nil {
		t.Fatal(err)
	}
	tx := &txSender{t: t, eth: eth, key: key, from: deployer, chainID: chainID, ctx: ctx}

	verifierABI, verifierBin := artifact(t, "VRFVerifier")
	shares, err := dkg.RunLocal(operators, quorum, 1)
	if err != nil {
		t.Fatal(err)
	}
	pk, err := blsvrf.SerializeG2(shares[0].GroupPublic)
	if err != nil {
		t.Fatal(err)
	}
	args, err := verifierABI.Pack("", [4]*big.Int{pk[0], pk[1], pk[2], pk[3]}, uint64(1))
	if err != nil {
		t.Fatal(err)
	}
	target := tx.deploy(append(verifierBin, args...))
	eth.Close()

	client, err := chain.Dial(ctx, rpc, target, key)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	failures := make(chan error, 8)
	watchCtx, done := context.WithCancel(ctx)
	defer done()
	go func() {
		_ = client.Watch(watchCtx, chain.WatchOptions{
			From:      0,
			Interval:  100 * time.Millisecond,
			OnRequest: func(chain.Request) {},
			OnError: func(err error) {
				select {
				case failures <- err:
				default:
				}
			},
		})
	}()

	time.Sleep(300 * time.Millisecond)
	stop() // the chain goes away underneath a running node

	select {
	case err := <-failures:
		if err == nil {
			t.Fatal("reported a nil failure")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the chain disappeared and the watcher said nothing")
	}
}
