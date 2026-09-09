package dkgnet_test

import (
	"io"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"threshold-vrf/node/internal/dkgnet"
)

// A participant that is not listening yet, and then is.
//
// This is the ordinary case, not the exotic one: nine operators start a
// ceremony by hand, on nine machines, and they do not start in the same
// millisecond. The first round's deals go out immediately, so a peer that is
// three seconds behind never receives them — and the sender is then evicted by
// the peers that did not hear from it, which is what happened on the first
// real run of this fleet.
type latePeer struct {
	server  *httptest.Server
	up      atomic.Bool
	arrived chan []byte
}

func newLatePeer() *latePeer {
	p := &latePeer{arrived: make(chan []byte, 8)}
	p.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !p.up.Load() {
			// What a closed port looks like from the sender's side, near
			// enough: the request does not succeed and nothing is recorded.
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		body, _ := io.ReadAll(r.Body)
		select {
		case p.arrived <- body:
		default:
		}
		w.WriteHeader(http.StatusOK)
	}))
	return p
}

func TestABundleIsRetriedUntilALatePeerIsListening(t *testing.T) {
	peer := newLatePeer()
	defer peer.server.Close()

	board := dkgnet.NewBoard([]string{peer.server.URL}, 8, nil)
	board.SetRetryWindow(5 * time.Second)
	defer board.Close()

	board.Broadcast([]byte(`{"kind":"deals"}`), "deals")

	// It comes up a moment after the bundle was first sent.
	time.Sleep(300 * time.Millisecond)
	peer.up.Store(true)

	select {
	case <-peer.arrived:
	case <-time.After(6 * time.Second):
		t.Fatal("the bundle never reached a peer that came up late")
	}
}

// The retry has to end. A peer that never comes back must not hold the
// ceremony open past the round it belongs to.
func TestRetryingGivesUpAtTheEndOfTheWindow(t *testing.T) {
	peer := newLatePeer() // never brought up
	defer peer.server.Close()

	board := dkgnet.NewBoard([]string{peer.server.URL}, 8, nil)
	board.SetRetryWindow(600 * time.Millisecond)
	defer board.Close()

	start := time.Now()
	board.Broadcast([]byte(`{"kind":"deals"}`), "deals")
	board.Close() // waits for whatever is still in flight
	elapsed := time.Since(start)

	if elapsed > 4*time.Second {
		t.Fatalf("gave up after %s, which is not a bounded window", elapsed)
	}
}

// Closing the board stops the retries: the ceremony is over and a goroutine
// still knocking on a dead peer is a leak, not persistence.
func TestClosingTheBoardStopsRetrying(t *testing.T) {
	peer := newLatePeer()
	defer peer.server.Close()

	board := dkgnet.NewBoard([]string{peer.server.URL}, 8, nil)
	board.SetRetryWindow(30 * time.Second)

	board.Broadcast([]byte(`{"kind":"deals"}`), "deals")
	time.Sleep(200 * time.Millisecond)

	done := make(chan struct{})
	go func() { board.Close(); close(done) }()

	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("a retry outlived the board it belongs to")
	}
}
