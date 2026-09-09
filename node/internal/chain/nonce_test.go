package chain_test

import (
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"

	"threshold-vrf/node/internal/chain"
)

// An operator with several fulfilments ready at once used to read the same
// pending nonce for all of them: the chain has not seen any of them yet, so it
// keeps answering with the same number. Every transaction but one was then
// rejected as "nonce too low", and the requests behind them were dropped.
type nonceStub struct {
	mu     sync.Mutex
	nonces []uint64
	// rejectNth refuses one send, the way the chain does when another operator
	// published the same request first. 0 rejects nothing.
	rejectNth int
	sends     int
}

func (s *nonceStub) seen() []uint64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]uint64, len(s.nonces))
	copy(out, s.nonces)
	return out
}

func (s *nonceStub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	var call struct {
		ID     json.RawMessage `json:"id"`
		Method string          `json:"method"`
		Params []any           `json:"params"`
	}
	_ = json.NewDecoder(r.Body).Decode(&call)

	reply := func(result string) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"jsonrpc":"2.0","id":%s,"result":%s}`, call.ID, result)
	}

	switch call.Method {
	case "eth_chainId":
		reply(`"0xb616"`)
	case "eth_getCode":
		reply(`"0x60006000"`)
	case "eth_getTransactionCount":
		// Always 7: nothing this node sent has been mined yet, which is exactly
		// the situation a burst creates.
		reply(`"0x7"`)
	case "eth_maxPriorityFeePerGas":
		reply(`"0x5f5e100"`)
	case "eth_getBlockByNumber":
		reply(`{"number":"0x1","baseFeePerGas":"0x5f5e100","hash":"0x0000000000000000000000000000000000000000000000000000000000000001","parentHash":"0x0000000000000000000000000000000000000000000000000000000000000000","sha3Uncles":"0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347","stateRoot":"0x0000000000000000000000000000000000000000000000000000000000000000","transactionsRoot":"0x0000000000000000000000000000000000000000000000000000000000000000","receiptsRoot":"0x0000000000000000000000000000000000000000000000000000000000000000","logsBloom":"0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000","difficulty":"0x0","gasLimit":"0x1","gasUsed":"0x0","timestamp":"0x1","extraData":"0x","miner":"0x0000000000000000000000000000000000000000","mixHash":"0x0000000000000000000000000000000000000000000000000000000000000000","nonce":"0x0000000000000000","transactions":[],"uncles":[]}`)
	case "eth_sendRawTransaction":
		raw, _ := call.Params[0].(string)
		// UnmarshalBinary, not rlp: a typed (EIP-1559) transaction is a type
		// byte followed by the payload, and rlp.DecodeBytes leaves it empty.
		var tx types.Transaction
		if err := tx.UnmarshalBinary(common.FromHex(raw)); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		s.mu.Lock()
		s.nonces = append(s.nonces, tx.Nonce())
		s.sends++
		rejected := s.rejectNth > 0 && s.sends == s.rejectNth
		s.mu.Unlock()
		if rejected {
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprintf(w,
				`{"jsonrpc":"2.0","id":%s,"error":{"code":-32000,"message":"nonce too low"}}`,
				call.ID)
			return
		}
		reply(`"0x0000000000000000000000000000000000000000000000000000000000000001"`)
	default:
		reply(`"0x0"`)
	}
}

func TestConcurrentFulfilmentsGetDistinctNonces(t *testing.T) {
	stub := &nonceStub{}
	server := httptest.NewServer(stub)
	defer server.Close()

	key, err := crypto.GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	client, err := chain.Dial(
		context.Background(), server.URL, common.HexToAddress("0xdead"), key)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	const burst = 12
	var wg sync.WaitGroup
	errs := make([]error, burst)
	for i := 0; i < burst; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, errs[i] = client.Fulfill(ctx, big.NewInt(int64(i)), make([]byte, 64), 100_000)
		}(i)
	}
	wg.Wait()

	for i, err := range errs {
		if err != nil {
			t.Fatalf("fulfilment %d failed: %v", i, err)
		}
	}

	seen := stub.seen()
	if len(seen) != burst {
		t.Fatalf("sent %d transactions, expected %d", len(seen), burst)
	}
	unique := map[uint64]bool{}
	for _, n := range seen {
		unique[n] = true
	}
	if len(unique) != burst {
		t.Fatalf("%d transactions carried only %d distinct nonces %v: "+
			"all but one would be rejected as nonce too low", burst, len(unique), seen)
	}
}

// A local counter is only worth keeping while the chain agrees with it. The
// ordinary way it stops agreeing is another operator publishing first, which
// rejects our transaction — after that, guessing the next number would reject
// every fulfilment this node ever tries again.
func TestTheNonceCounterIsRebuiltAfterARejection(t *testing.T) {
	stub := &nonceStub{rejectNth: 2}
	server := httptest.NewServer(stub)
	defer server.Close()

	key, err := crypto.GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	client, err := chain.Dial(
		context.Background(), server.URL, common.HexToAddress("0xdead"), key)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	for i := 0; i < 4; i++ {
		_, err := client.Fulfill(ctx, big.NewInt(int64(i)), make([]byte, 64), 100_000)
		if i == 1 && err == nil {
			t.Fatal("the rejected send was reported as a success")
		}
		if i != 1 && err != nil {
			t.Fatalf("fulfilment %d failed: %v", i, err)
		}
	}

	// The stub always answers 7, so after the rejection the counter must have
	// gone back to it rather than carrying on from a number the chain never
	// confirmed.
	seen := stub.seen()
	want := []uint64{7, 8, 7, 8}
	if len(seen) != len(want) {
		t.Fatalf("sent %v, expected %d transactions", seen, len(want))
	}
	for i := range want {
		if seen[i] != want[i] {
			t.Fatalf("nonces %v, expected %v: the counter was not rebuilt", seen, want)
		}
	}
}
