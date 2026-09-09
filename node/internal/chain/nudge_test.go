package chain_test

import (
	"context"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"threshold-vrf/node/internal/chain"
)

func dialStub(t *testing.T, stub *rpcStub) (*chain.Client, func()) {
	t.Helper()
	server := httptest.NewServer(stub)
	client, err := chain.Dial(
		context.Background(), server.URL, common.HexToAddress("0xdead"), nil)
	if err != nil {
		server.Close()
		t.Fatal(err)
	}
	return client, func() { client.Close(); server.Close() }
}

// The interval is what the node waits when nothing tells it otherwise, and on a
// chain with 0.1s blocks a three-second interval is most of the latency a
// consumer sees. A nudge — a log arriving over a subscription — should make the
// loop look now rather than at the end of its timer.
func TestANudgeScansWithoutWaitingForTheInterval(t *testing.T) {
	stub := &rpcStub{}
	client, done := dialStub(t, stub)
	defer done()

	nudge := make(chan struct{}, 1)
	ctx, cancel := context.WithTimeout(context.Background(), 800*time.Millisecond)
	defer cancel()

	go func() {
		time.Sleep(100 * time.Millisecond)
		nudge <- struct{}{}
	}()
	_ = client.Watch(ctx, chain.WatchOptions{
		// Far longer than the test: without the nudge there is exactly one scan,
		// the one the loop does before it first sleeps.
		Interval:  30 * time.Second,
		Nudge:     nudge,
		OnRequest: func(chain.Request) {},
		OnError:   func(error) {},
	})

	if got := stub.count(); got < 2 {
		t.Fatalf("%d scans: the nudge did not wake the loop", got)
	}
}

// Under load a subscription delivers a log per request, and a burst of them
// must not become a burst of eth_getLogs — that is the shape that gets an
// endpoint to start refusing, which is the problem this was meant to relieve.
func TestABurstOfNudgesCoalescesIntoOneScan(t *testing.T) {
	stub := &rpcStub{}
	client, done := dialStub(t, stub)
	defer done()

	nudge := make(chan struct{}, 1)
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()

	go func() {
		for i := 0; i < 200; i++ {
			select {
			case nudge <- struct{}{}:
			default: // the sender never blocks: a full channel already means "look"
			}
			time.Sleep(time.Millisecond)
		}
	}()
	_ = client.Watch(ctx, chain.WatchOptions{
		Interval:  30 * time.Second,
		Nudge:     nudge,
		OnRequest: func(chain.Request) {},
		OnError:   func(error) {},
	})

	// Two hundred nudges in half a second. Each one scanning would be 200
	// calls; coalescing keeps it to a handful.
	if got := stub.count(); got > 60 {
		t.Fatalf("%d scans from 200 nudges: they did not coalesce", got)
	}
	if stub.count() < 2 {
		t.Fatalf("%d scans: the nudges did nothing at all", stub.count())
	}
}

// A subscription that dies closes its channel, and a closed channel is always
// ready to receive. Left alone that turns the poll loop into a busy loop that
// hammers the endpoint as fast as it can answer — a worse failure than the
// silence the subscription was replacing.
func TestAClosedNudgeChannelDoesNotBecomeABusyLoop(t *testing.T) {
	stub := &rpcStub{}
	client, done := dialStub(t, stub)
	defer done()

	nudge := make(chan struct{})
	close(nudge)

	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	_ = client.Watch(ctx, chain.WatchOptions{
		Interval:  50 * time.Millisecond,
		Nudge:     nudge,
		OnRequest: func(chain.Request) {},
		OnError:   func(error) {},
	})

	// Half a second at 50ms is ~10 polls. A busy loop is thousands.
	if got := stub.count(); got > 40 {
		t.Fatalf("%d polls in 500ms: a dead subscription became a busy loop", got)
	}
}

// Nothing about correctness may depend on the nudge. With no channel at all the
// loop is exactly what it was.
func TestPollingIsUnchangedWithoutANudge(t *testing.T) {
	stub := &rpcStub{}
	client, done := dialStub(t, stub)
	defer done()

	ctx, cancel := context.WithTimeout(context.Background(), 400*time.Millisecond)
	defer cancel()
	_ = client.Watch(ctx, chain.WatchOptions{
		Interval:  50 * time.Millisecond,
		OnRequest: func(chain.Request) {},
		OnError:   func(error) {},
	})

	if got := stub.count(); got < 4 {
		t.Fatalf("%d polls in 400ms at a 50ms interval: the loop stopped polling", got)
	}
}
