package chain_test

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"threshold-vrf/node/internal/chain"
)

// A subscription that fails, comes back, and fails again — which is what a
// websocket over a public endpoint actually does.
type flakySource struct {
	opens  atomic.Int32
	fail   atomic.Bool
	events chan struct{}
}

func (f *flakySource) open(ctx context.Context, out chan<- struct{}) error {
	f.opens.Add(1)
	if f.fail.Load() {
		return errors.New("subscription refused")
	}
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case _, ok := <-f.events:
			if !ok {
				return errors.New("subscription closed by the server")
			}
			select {
			case out <- struct{}{}:
			default:
			}
		}
	}
}

// The point of the whole arrangement: a log arriving over the wire turns into a
// nudge, and the poll loop sees it now rather than at the end of its interval.
func TestAnEventBecomesANudge(t *testing.T) {
	src := &flakySource{events: make(chan struct{}, 4)}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	nudges := chain.Nudges(ctx, src.open, nil)
	src.events <- struct{}{}

	select {
	case <-nudges:
	case <-time.After(500 * time.Millisecond):
		t.Fatal("an event never reached the loop as a nudge")
	}
}

// The failure the original design was right to fear: a subscription that stops
// delivering. It must be reopened rather than left dead, and it must not spin.
func TestADeadSubscriptionIsReopenedWithoutSpinning(t *testing.T) {
	src := &flakySource{events: make(chan struct{}, 4)}
	src.fail.Store(true)

	ctx, cancel := context.WithTimeout(context.Background(), 900*time.Millisecond)
	defer cancel()
	_ = chain.Nudges(ctx, src.open, nil)
	<-ctx.Done()

	opens := src.opens.Load()
	if opens < 2 {
		t.Fatalf("opened %d times: a failed subscription was never retried", opens)
	}
	// Retrying flat out would be hundreds in a second, and would do to the
	// endpoint exactly what the poll backoff exists to prevent.
	if opens > 12 {
		t.Fatalf("opened %d times in 900ms: reconnecting is a busy loop", opens)
	}
}

// The channel must never be the thing that blocks a subscription reader. If a
// nudge cannot be delivered it is because one is already pending, and a pending
// nudge already says everything the next one would.
func TestNudgesAreDroppedRatherThanQueued(t *testing.T) {
	src := &flakySource{events: make(chan struct{}, 64)}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	nudges := chain.Nudges(ctx, src.open, nil)
	for i := 0; i < 64; i++ {
		src.events <- struct{}{}
	}

	time.Sleep(200 * time.Millisecond)
	drained := 0
	for {
		select {
		case <-nudges:
			drained++
			continue
		default:
		}
		break
	}
	if drained > 2 {
		t.Fatalf("%d nudges queued up: they are being buffered, not coalesced", drained)
	}
}
