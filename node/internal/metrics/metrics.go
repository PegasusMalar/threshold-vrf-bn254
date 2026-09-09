// Package metrics is what makes the operator set checkable from outside.
//
// Whether an operator is doing its job cannot be read off the chain: the
// threshold signature is identical whichever quorum produced it, so the chain
// shows who *published* and never who *signed*. The only place that knowledge
// exists is in the other operators, each of which knows who sent it a share.
//
// So each node publishes its own counts, and the monitor asks all of them and
// compares. One node's word about another proves nothing; eight nodes agreeing
// that a ninth sends nothing is evidence. That is also why the endpoint is
// CORS-open: the page doing the comparing runs in a visitor's browser and talks
// to every operator directly, so there is no aggregator to trust.
package metrics

import (
	"fmt"
	"math/big"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
)

// Path is where the counters are served.
const Path = "/metrics"

// Registry holds one operator's counters.
type Registry struct {
	operatorIndex uint32
	threshold     int
	operators     int
	startedAt     time.Time

	mu             sync.Mutex
	requestsSeen   uint64
	sharesSent     uint64
	published      uint64
	racesLost      uint64
	lastSeenBlock  uint64
	sharesReceived map[uint32]uint64
	sharesRejected map[uint32]uint64
	equivocations  map[uint32]uint64

	sessions func() int
	parked   func() int
	balance  func() *big.Int
}

// New starts a registry for one operator.
func New(operatorIndex uint32, threshold, operators int) *Registry {
	return &Registry{
		operatorIndex:  operatorIndex,
		threshold:      threshold,
		operators:      operators,
		startedAt:      time.Now(),
		sharesReceived: make(map[uint32]uint64),
		sharesRejected: make(map[uint32]uint64),
		equivocations:  make(map[uint32]uint64),
	}
}

// SetGauges wires up values that are read at scrape time rather than counted.
func (r *Registry) SetGauges(sessions, parked func() int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.sessions, r.parked = sessions, parked
}

// SetBalanceGauge wires up the publishing account's balance, read at scrape
// time. Left unset it reports nothing at all rather than zero: a monitor has to
// be able to tell a node that could not read its balance from one that has
// nothing left to spend.
func (r *Registry) SetBalanceGauge(read func() *big.Int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.balance = read
}

func (r *Registry) RequestSeen() { r.bump(&r.requestsSeen) }
func (r *Registry) ShareSent()   { r.bump(&r.sharesSent) }
func (r *Registry) Published()   { r.bump(&r.published) }
func (r *Registry) RaceLost()    { r.bump(&r.racesLost) }

func (r *Registry) ShareReceived(peer uint32) { r.bumpPeer(r.sharesReceived, peer) }
func (r *Registry) ShareRejected(peer uint32) { r.bumpPeer(r.sharesRejected, peer) }
func (r *Registry) Equivocation(peer uint32)  { r.bumpPeer(r.equivocations, peer) }

// BlockSeen records how far this node has scanned, which is how a monitor spots
// a node that is up but has fallen behind the chain.
func (r *Registry) BlockSeen(block uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if block > r.lastSeenBlock {
		r.lastSeenBlock = block
	}
}

func (r *Registry) bump(counter *uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	*counter++
}

func (r *Registry) bumpPeer(counters map[uint32]uint64, peer uint32) {
	r.mu.Lock()
	defer r.mu.Unlock()
	counters[peer]++
}

// Handler serves the counters in Prometheus text format.
func (r *Registry) Handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write([]byte(r.render()))
	})
}

func (r *Registry) render() string {
	r.mu.Lock()
	sessions, parked := 0, 0
	if r.sessions != nil {
		sessions = r.sessions()
	}
	if r.parked != nil {
		parked = r.parked()
	}
	var balance *big.Int
	if r.balance != nil {
		balance = r.balance()
	}
	snapshot := struct {
		requests, sent, published, lost, block uint64
		received, rejected, equivocations      map[uint32]uint64
	}{
		r.requestsSeen, r.sharesSent, r.published, r.racesLost, r.lastSeenBlock,
		copyOf(r.sharesReceived), copyOf(r.sharesRejected), copyOf(r.equivocations),
	}
	r.mu.Unlock()

	var b strings.Builder
	gauge := func(name, help string, value any) {
		fmt.Fprintf(&b, "# HELP %s %s\n# TYPE %s gauge\n%s %v\n", name, help, name, name, value)
	}
	counter := func(name, help string, value uint64) {
		fmt.Fprintf(&b, "# HELP %s %s\n# TYPE %s counter\n%s %d\n", name, help, name, name, value)
	}
	perPeer := func(name, help string, values map[uint32]uint64) {
		fmt.Fprintf(&b, "# HELP %s %s\n# TYPE %s counter\n", name, help, name)
		for _, peer := range sortedKeys(values) {
			fmt.Fprintf(&b, "%s{peer=\"%d\"} %d\n", name, peer, values[peer])
		}
	}

	gauge("vrf_operator_index", "Index of the operator answering this scrape.", r.operatorIndex)
	gauge("vrf_threshold", "Signatures needed to produce a group signature.", r.threshold)
	gauge("vrf_operators", "Size of the operator group.", r.operators)
	gauge("vrf_uptime_seconds", "Seconds since this node started.",
		int64(time.Since(r.startedAt).Seconds()))
	gauge("vrf_sessions_active", "Requests currently being signed.", sessions)
	gauge("vrf_parked_requests", "Requests with shares held from peers that got here first.", parked)
	gauge("vrf_last_seen_block", "Highest L2 block this node has scanned for requests.", snapshot.block)
	// Absent, not zero, when unknown — see SetBalanceGauge. An operator out of
	// gas keeps every other counter moving and stops only publishing, which is
	// why this one is here at all.
	if balance != nil {
		gauge("vrf_publisher_balance_wei",
			"Native balance of the account this node publishes fulfilments from.", balance)
	}

	counter("vrf_requests_seen_total", "Requests observed on the chain.", snapshot.requests)
	counter("vrf_shares_sent_total", "Signature shares broadcast to peers.", snapshot.sent)
	// Sent, not landed: the node counts a fulfilment when the transaction is
	// accepted by the endpoint, and does not wait for a receipt. Under a burst
	// several operators send for the same request and all but one revert, so
	// the fleet's total runs above the number of fulfilments — measured at 70
	// sends for 50 fulfilments on a 50-request burst. Naming it "landed" would
	// make an audit metric overstate the work its operator actually did.
	counter("vrf_fulfilments_published_total",
		"Fulfilment transactions this node sent. Several operators may send for one "+
			"request, so a fleet total above the number of fulfilments is expected.",
		snapshot.published)
	counter("vrf_fulfilments_lost_total",
		"Fulfilments another operator published first. Expected, not a fault.", snapshot.lost)

	perPeer("vrf_shares_received_total",
		"Verified signature shares accepted from each operator.", snapshot.received)
	perPeer("vrf_shares_rejected_total",
		"Shares refused from each operator: bad signature, wrong seed, or unwanted.",
		snapshot.rejected)
	perPeer("vrf_equivocations_total",
		"Times an operator sent two different shares for one seed. Slashable.",
		snapshot.equivocations)

	return b.String()
}

func copyOf(m map[uint32]uint64) map[uint32]uint64 {
	out := make(map[uint32]uint64, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

func sortedKeys(m map[uint32]uint64) []uint32 {
	keys := make([]uint32, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i] < keys[j] })
	return keys
}
