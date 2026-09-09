package chain_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"threshold-vrf/node/internal/chain"
)

// A public RPC endpoint answers nine operators at once. When it starts refusing,
// polling it at the same rate is not just useless, it is the thing keeping it
// refusing. rpcStub counts how hard it is being hit.
type rpcStub struct {
	mu       sync.Mutex
	polls    int
	refusing bool
}

func (s *rpcStub) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.polls
}

func (s *rpcStub) relent() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.refusing = false
}

func (s *rpcStub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	var call struct {
		ID     json.RawMessage `json:"id"`
		Method string          `json:"method"`
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
		reply(`"0x60006000"`) // enough that Dial sees a contract
	case "eth_blockNumber":
		s.mu.Lock()
		s.polls++
		refusing := s.refusing
		s.mu.Unlock()
		if refusing {
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		// the head advances, as on a live chain: a static head means the loop
		// has nothing new to scan and would report no progress for good reason
		reply(fmt.Sprintf(`"0x%x"`, s.polls))
	case "eth_getLogs":
		reply(`[]`)
	default:
		reply(`"0x0"`)
	}
}

func TestPollingBacksOffWhenTheRpcRefuses(t *testing.T) {
	stub := &rpcStub{refusing: true}
	server := httptest.NewServer(stub)
	defer server.Close()

	client, err := chain.Dial(
		context.Background(), server.URL, common.HexToAddress("0xdead"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_ = client.Watch(ctx, chain.WatchOptions{
		Interval:  20 * time.Millisecond,
		OnRequest: func(chain.Request) {},
		OnError:   func(error) {},
	})

	// Flat out, two seconds at 20ms is ~100 polls. Backing off has to bring
	// that down by an order of magnitude, or nine nodes will keep a struggling
	// endpoint pinned down.
	if got := stub.count(); got > 20 {
		t.Fatalf("hammered a refusing endpoint %d times; it never backed off", got)
	}
	if stub.count() < 2 {
		t.Fatalf("only %d polls: it gave up rather than backed off", stub.count())
	}
}

func TestPollingSpeedsBackUpOnceTheRpcRecovers(t *testing.T) {
	stub := &rpcStub{refusing: true}
	server := httptest.NewServer(stub)
	defer server.Close()

	client, err := chain.Dial(
		context.Background(), server.URL, common.HexToAddress("0xdead"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	var scans int
	var mu sync.Mutex
	go func() {
		time.Sleep(time.Second) // let it back well off first
		stub.relent()
	}()
	_ = client.Watch(ctx, chain.WatchOptions{
		Interval:  20 * time.Millisecond,
		OnRequest: func(chain.Request) {},
		OnScanned: func(uint64) { mu.Lock(); scans++; mu.Unlock() },
		OnError:   func(error) {},
	})

	mu.Lock()
	defer mu.Unlock()
	// A backoff that never resets is a node that stays half-asleep for the rest
	// of its life.
	if scans < 10 {
		t.Fatalf("only %d scans in the two seconds after recovery; the backoff never reset", scans)
	}
}
