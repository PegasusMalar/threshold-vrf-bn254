package dkgnet

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	kdkg "github.com/drand/kyber/share/dkg"
)

// BundlePath is where participants post ceremony bundles to each other.
const BundlePath = "/v1/dkg"

// Board carries the ceremony's three rounds between participants.
//
// Bundles are broadcast to everyone, including back to the sender: kyber's
// protocol expects to receive its own packets like any other.
//
// Delivery is retried within a bounded window, because the ordinary case is a
// peer that is not listening *yet*. Nine operators start a ceremony by hand on
// nine machines and do not start in the same millisecond; the first round's
// deals go out immediately, and a single-shot send means everyone slower than
// the fastest starter simply never receives them. The protocol tolerates a
// participant that goes missing — it does not rescue one that was never
// reached, and the sender is evicted by the peers that heard nothing from it.
// That is not a hypothetical: it is how the first real ceremony on this fleet
// failed, six of nine evicted with "connection refused" in every log.
//
// Bounded, because a peer that never comes back must not hold a round open
// past the phase it belongs to. Past the window it is a genuine absence, which
// is what the protocol's complaints are for.
type Board struct {
	peers  []string
	client *http.Client
	log    *slog.Logger

	deals chan kdkg.DealBundle
	resps chan kdkg.ResponseBundle
	justs chan kdkg.JustificationBundle

	mu          sync.Mutex
	outbound    sync.WaitGroup
	closed      bool
	retryWindow time.Duration
}

// DefaultRetryWindow is how long a bundle keeps looking for a peer that has
// not come up. Long enough for hands on nine keyboards, short enough to stay
// inside a generous phase period.
const DefaultRetryWindow = 45 * time.Second

// NewBoard talks to the other participants. `buffer` should be at least the
// number of participants, so nobody blocks on a slow reader.
func NewBoard(peers []string, buffer int, log *slog.Logger) *Board {
	if log == nil {
		log = slog.Default()
	}
	if buffer < 8 {
		buffer = 8
	}
	return &Board{
		peers:  peers,
		client: &http.Client{Timeout: 10 * time.Second},
		log:    log,
		deals:  make(chan kdkg.DealBundle, buffer),
		resps:  make(chan kdkg.ResponseBundle, buffer),
		justs:  make(chan kdkg.JustificationBundle, buffer),

		retryWindow: DefaultRetryWindow,
	}
}

// SetPeers points the board at the other participants. Separate from
// construction so a participant can start listening before it learns who else
// is taking part.
func (b *Board) SetPeers(peers []string) { b.peers = peers }

// Handler is the HTTP surface a participant exposes during a ceremony. It is
// deliberately separate from the node's own mesh: a ceremony is a scheduled,
// supervised event, and it should be possible to open this port for an hour and
// close it again.
func (b *Board) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc(BundlePath, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		buf := new(bytes.Buffer)
		if _, err := buf.ReadFrom(http.MaxBytesReader(w, r.Body, 1<<20)); err != nil {
			http.Error(w, "body too large", http.StatusBadRequest)
			return
		}
		if err := b.Deliver(buf.Bytes()); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		w.WriteHeader(http.StatusAccepted)
	})
	return mux
}

// Deliver feeds a received bundle into the protocol.
func (b *Board) Deliver(raw []byte) error {
	kind, err := KindOf(raw)
	if err != nil {
		return err
	}
	switch kind {
	case "deals":
		bundle, err := DecodeDeals(raw)
		if err != nil {
			return err
		}
		return b.push(func() { b.deals <- *bundle })
	case "responses":
		bundle, err := DecodeResponses(raw)
		if err != nil {
			return err
		}
		return b.push(func() { b.resps <- *bundle })
	default:
		bundle, err := DecodeJustifications(raw)
		if err != nil {
			return err
		}
		return b.push(func() { b.justs <- *bundle })
	}
}

func (b *Board) push(send func()) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return fmt.Errorf("dkgnet: ceremony is over")
	}
	send()
	return nil
}

func (b *Board) PushDeals(bundle *kdkg.DealBundle) {
	raw, err := EncodeDeals(bundle)
	if err != nil {
		b.log.Error("encoding deals", "err", err)
		return
	}
	_ = b.Deliver(raw)
	b.broadcast(raw, "deals")
}

func (b *Board) PushResponses(bundle *kdkg.ResponseBundle) {
	raw, err := EncodeResponses(bundle)
	if err != nil {
		b.log.Error("encoding responses", "err", err)
		return
	}
	_ = b.Deliver(raw)
	b.broadcast(raw, "responses")
}

func (b *Board) PushJustifications(bundle *kdkg.JustificationBundle) {
	raw, err := EncodeJustifications(bundle)
	if err != nil {
		b.log.Error("encoding justifications", "err", err)
		return
	}
	_ = b.Deliver(raw)
	b.broadcast(raw, "justifications")
}

func (b *Board) IncomingDeal() <-chan kdkg.DealBundle                   { return b.deals }
func (b *Board) IncomingResponse() <-chan kdkg.ResponseBundle           { return b.resps }
func (b *Board) IncomingJustification() <-chan kdkg.JustificationBundle { return b.justs }

// SetRetryWindow bounds how long delivery keeps trying. Zero sends once.
func (b *Board) SetRetryWindow(d time.Duration) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.retryWindow = d
}

// Broadcast sends one encoded bundle to every participant. Exported because it
// is the whole of the board's outbound behaviour and the part worth testing on
// its own; the Push* methods are encoders in front of it.
func (b *Board) Broadcast(raw []byte, kind string) { b.broadcast(raw, kind) }

func (b *Board) broadcast(raw []byte, kind string) {
	b.mu.Lock()
	window := b.retryWindow
	b.mu.Unlock()

	for _, peer := range b.peers {
		b.outbound.Add(1)
		go func(peer string) {
			defer b.outbound.Done()
			if err := b.deliver(peer, raw, window); err != nil {
				// Past the window this is a genuine absence. A participant
				// that misses a deal complains about it in the next round,
				// which is what the rounds are for.
				b.log.Warn("bundle not delivered", "kind", kind, "peer", peer, "err", err)
			}
		}(peer)
	}
}

func (b *Board) post(peer string, raw []byte) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		strings.TrimSuffix(peer, "/")+BundlePath, bytes.NewReader(raw))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := b.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return fmt.Errorf("status %d", resp.StatusCode)
	}
	return nil
}

// Close stops accepting bundles once the ceremony is done.
func (b *Board) Close() {
	b.mu.Lock()
	b.closed = true
	b.mu.Unlock()
	b.outbound.Wait()
}

// deliver posts to one peer, retrying a refusal until the window closes.
//
// Backoff doubles from a quarter-second: a peer that is one second late costs
// four attempts, one that never arrives costs a handful rather than a busy
// loop. It stops early when the board closes, so the ceremony ending does not
// leave goroutines knocking on a dead address.
func (b *Board) deliver(peer string, raw []byte, window time.Duration) error {
	deadline := time.Now().Add(window)
	wait := 250 * time.Millisecond

	for attempt := 0; ; attempt++ {
		err := b.post(peer, raw)
		if err == nil {
			if attempt > 0 {
				b.log.Info("bundle delivered after retrying", "peer", peer, "attempts", attempt+1)
			}
			return nil
		}
		if time.Now().Add(wait).After(deadline) || b.isClosed() {
			return err
		}
		time.Sleep(wait)
		if wait < 4*time.Second {
			wait *= 2
		}
	}
}

func (b *Board) isClosed() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.closed
}
