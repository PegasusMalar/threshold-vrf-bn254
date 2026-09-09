// Package node is the operator daemon's brain: it decides what to sign, what to
// accept from peers, and when to publish.
//
// Every node is its own aggregator. It signs, broadcasts its share to all the
// others, collects theirs, and whoever reaches the threshold first publishes.
// The losers of that race find the request already closed and drop their
// transaction. No leader, no coordinator, nobody whose absence stops the
// service — and no way for a fast node to change the outcome, because the
// signature over a seed is unique no matter who assembles it.
package node

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"threshold-vrf/node/internal/blsvrf"
	"threshold-vrf/node/internal/chain"
	"threshold-vrf/node/internal/dkg"
	"threshold-vrf/node/internal/mesh"
	"threshold-vrf/node/internal/metrics"
	"threshold-vrf/node/internal/session"
	"threshold-vrf/node/internal/threshold"
)

// MaxParkedRequests caps how many not-yet-seen requests the node will hold
// shares for. The share endpoint is open to the internet, so anything it can be
// made to remember has to have a ceiling.
const MaxParkedRequests = 256

// Chain is the part of the coordinator the node depends on. Narrow on purpose:
// everything here is exercised against both a live chain and a fake one.
type Chain interface {
	// DeriveSeed computes the seed locally from data the event already carries.
	DeriveSeed(requestID *big.Int, consumer common.Address) [32]byte
	// SeedOf asks the contract, for requests this node did not see announced.
	SeedOf(context.Context, *big.Int) ([32]byte, error)
	IsOpen(context.Context, *big.Int) (bool, error)
	// Fulfill publishes, under a limit sized for this request's callback.
	Fulfill(context.Context, *big.Int, []byte, uint32) (common.Hash, error)
}

// Config is what one operator needs to run.
type Config struct {
	Share     dkg.Share
	Threshold int
	Operators int
	Chain     Chain
	// AfterPublish runs when this node lands a fulfilment, which is the only
	// moment its balance falls and its earnings rise. Wired to the balance
	// check so an operator that has just spent its float notices at once
	// rather than at the next tick of a timer — a thinly funded operator that
	// waits is one the rotation has to walk past.
	AfterPublish func()
	Logger       *slog.Logger
	// Metrics is optional; without it the node simply counts nothing.
	Metrics *metrics.Registry
	// SendRetryInterval is how long to wait before trying the fulfillment
	// transaction again after a send that failed for a reason other than the
	// request already being closed. Zero disables it.
	SendRetryInterval time.Duration
	// SendRetries caps how many times the transaction is retried.
	SendRetries int
	// RebroadcastInterval is how long to wait before offering a share again to
	// peers that have not answered. Zero disables it.
	RebroadcastInterval time.Duration
	// RebroadcastAttempts caps how many times a share is re-offered.
	RebroadcastAttempts int
	// PublishDelay staggers publication so that operators do not all send the
	// same transaction at once. Each request gets a different running order, so
	// the wasted gas of a losing race is shared instead of always falling on
	// the same node. Zero means publish immediately.
	PublishDelay time.Duration
}

// Node is one operator.
type Node struct {
	cfg   Config
	log   *slog.Logger
	peers *mesh.Client

	mu        sync.Mutex
	sessions  map[string]*session.Session
	published map[string]bool
	// What each request asked for as a callback budget, so the publishing
	// transaction can be sized for that request instead of for the largest one
	// the coordinator would accept. Unused gas is not charged, but the limit is
	// what the operator's balance must cover before the chain accepts the
	// transaction — an over-sized limit freezes float for nothing.
	callbackGas map[string]uint32
	// Shares that arrived before this node had seen the request they belong to.
	// A peer can legitimately be one poll interval ahead of us.
	parked      map[string][]mesh.Envelope
	parkedOrder []string
	// Requests seen settled in the log stream. Eight of nine operators lose
	// every race, and having each of them ask the chain about every request is,
	// for a burst of fifty, four hundred and fifty calls at the endpoint the
	// whole group depends on. The logs are already being read; this is what
	// they are worth.
	settled      map[string]bool
	settledOrder []string
}

// MaxSettledMemory bounds the set of requests known to be finished. Ten
// thousand covers far more than any burst, and past that the oldest are
// dropped: forgetting one only costs a single chain call.
const MaxSettledMemory = 10_000

// New builds a node. Peers are attached separately so a node can come up and
// start verifying before it knows who else is out there.
func New(cfg Config) *Node {
	log := cfg.Logger
	if log == nil {
		log = slog.Default()
	}
	n := &Node{
		cfg:         cfg,
		log:         log.With("operator", cfg.Share.Index),
		sessions:    make(map[string]*session.Session),
		published:   make(map[string]bool),
		callbackGas: make(map[string]uint32),
		parked:      make(map[string][]mesh.Envelope),
		settled:     make(map[string]bool),
	}
	if cfg.Metrics != nil {
		cfg.Metrics.SetGauges(n.Sessions, n.Parked)
	}
	return n
}

// The counters are optional, so every call goes through a nil check rather than
// forcing a registry on callers that do not want one.
func (n *Node) count(f func(*metrics.Registry)) {
	if n.cfg.Metrics != nil {
		f(n.cfg.Metrics)
	}
}

// SetPeers points the node at the other operators.
func (n *Node) SetPeers(peers *mesh.Client) { n.peers = peers }

// Sessions is how many requests are currently in flight.
func (n *Node) Sessions() int {
	n.mu.Lock()
	defer n.mu.Unlock()
	return len(n.sessions)
}

// OnRequest handles a RequestCreated event: sign, file, tell everyone.
// callbackGasOf is what the request asked for, or zero if this node never saw
// the announcement — a share that arrived before the request, or a restart. Zero
// still yields a limit that covers the verification, so the worst case is a
// transaction sized for a callback that turns out to need more, which the
// coordinator refuses cleanly rather than half-performing.
func (n *Node) callbackGasOf(key string) uint32 {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.callbackGas[key]
}

func (n *Node) OnRequest(ctx context.Context, req chain.Request) {
	n.mu.Lock()
	n.callbackGas[hexID(req.ID)] = req.CallbackGasLimit
	n.mu.Unlock()

	// The seed is a pure function of things the event already carries, so it is
	// recomputed here rather than asked for. That is one round trip saved and,
	// more importantly, one fewer party to trust: a node that asks a server
	// what to sign will sign whatever that server answers.
	n.count(func(m *metrics.Registry) {
		m.RequestSeen()
		m.BlockSeen(req.Block)
	})

	seed := n.cfg.Chain.DeriveSeed(req.ID, req.Consumer)
	if seed != req.Seed {
		n.log.Error("event seed does not match the coordinator's formula",
			"request", hexID(req.ID), "announced", fmt.Sprintf("%x", req.Seed))
		return
	}

	// A node that has just restarted rescans recent blocks and will see
	// requests that closed while it was down. Signing those is wasted work.
	//
	// Answered from the log stream rather than by asking the chain: those same
	// blocks carry the fulfilments, and a call here is paid on every request by
	// every operator — for a burst of fifty across nine, four hundred and fifty
	// calls at the endpoint the whole group shares, almost all of them
	// answering "yes, still open" about a request that was made moments ago.
	// Being wrong here costs one wasted signature, never a wasted transaction:
	// maybePublish checks again before it sends anything.
	if n.knownSettled(hexID(req.ID)) {
		n.log.Debug("request already closed", "request", hexID(req.ID))
		return
	}

	sess := n.sessionFor(req.ID, seed)
	partial := threshold.Partial{
		Index: n.cfg.Share.Index,
		Sig:   blsvrf.Sign(n.cfg.Share.Secret, seed),
	}
	if _, err := sess.Add(partial); err != nil {
		// our own share failing to verify means the loaded key does not belong
		// to the deployed group at all
		n.log.Error("own partial rejected — wrong key for this group?", "err", err)
		return
	}

	// Anything peers sent before we knew about this request can be filed now.
	for _, held := range n.takeParked(hexID(req.ID)) {
		heldSeed, partial, err := held.Decode()
		if err != nil || heldSeed != seed {
			continue
		}
		if added, err := sess.Add(partial); err != nil {
			n.count(func(m *metrics.Registry) { m.ShareRejected(partial.Index) })
			n.log.Debug("held share rejected", "request", hexID(req.ID), "err", err)
		} else if added {
			n.count(func(m *metrics.Registry) { m.ShareReceived(partial.Index) })
		}
	}

	if n.peers != nil {
		raw, err := blsvrf.SignatureBytes(partial.Sig)
		if err == nil {
			envelope := mesh.Envelope{
				RequestID: hexID(req.ID),
				Seed:      "0x" + common.Bytes2Hex(seed[:]),
				Index:     partial.Index,
				Partial:   "0x" + common.Bytes2Hex(raw),
			}
			n.count(func(m *metrics.Registry) { m.ShareSent() })
			if err := n.peers.Broadcast(ctx, envelope); err != nil {
				// not fatal: t of n means several peers can be unreachable
				n.log.Warn("share not delivered everywhere", "err", err)
			}
			// A peer that refused — busy, rate limited, briefly unreachable —
			// would otherwise have dropped this share for good, and with it any
			// chance of this request reaching a quorum. Under load that is not
			// an edge case; it is what a burst looks like.
			n.chaseQuorum(ctx, req.ID, sess, envelope)
		}
	}

	n.maybePublish(ctx, req.ID, sess)
}

// OnPeerShare files another operator's share.
//
// This is reachable by anyone who can open a TCP connection, so the cheap
// checks come first and nothing here talks to the chain. A share for a request
// this node has not seen announced is held, not investigated: asking an RPC
// endpoint about an attacker-supplied request id would hand out the operator's
// quota to whoever asks.
func (n *Node) OnPeerShare(ctx context.Context, e mesh.Envelope) error {
	claimedSeed, partial, err := e.Decode()
	if err != nil {
		return err
	}
	id, ok := new(big.Int).SetString(trim0x(e.RequestID), 16)
	if !ok {
		return errors.New("node: unparseable request id")
	}
	key := hexID(id)

	sess := n.existingSession(key)
	if sess == nil {
		n.park(key, e)
		return nil
	}
	if sess.Seed() != claimedSeed {
		return fmt.Errorf("node: share for %s carries the wrong seed", key)
	}

	added, err := sess.Add(partial)
	if err != nil {
		n.count(func(m *metrics.Registry) { m.ShareRejected(partial.Index) })
		if ev, found := sess.Equivocation(); found {
			n.count(func(m *metrics.Registry) { m.Equivocation(ev.Index) })
			n.log.Error("equivocation: two different shares for one seed",
				"operator", ev.Index, "request", key)
		}
		return err
	}
	if added {
		n.count(func(m *metrics.Registry) { m.ShareReceived(partial.Index) })
	}

	// Off the request path: publishing waits for this operator's turn, which
	// with nine of them is up to sixteen seconds, and holding a peer's POST
	// open for that long is what made peers time out on each other under load.
	// WithoutCancel because the work outlives the request that triggered it —
	// the peer's HTTP context is cancelled the moment we answer.
	go n.maybePublish(context.WithoutCancel(ctx), id, sess)
	return nil
}

// chaseQuorum re-offers our share while the quorum is still short. It stops the
// moment there are enough partials, or the request closes, or the attempts run
// out — whichever comes first.
func (n *Node) chaseQuorum(
	ctx context.Context, id *big.Int, sess *session.Session, envelope mesh.Envelope,
) {
	if n.cfg.RebroadcastInterval <= 0 || n.cfg.RebroadcastAttempts <= 0 {
		return
	}
	key := hexID(id)

	for attempt := 0; attempt < n.cfg.RebroadcastAttempts; attempt++ {
		select {
		case <-ctx.Done():
			return
		case <-time.After(n.cfg.RebroadcastInterval):
		}

		if sess.Ready() {
			return
		}
		n.mu.Lock()
		published := n.published[key]
		n.mu.Unlock()
		if published {
			return
		}

		n.log.Debug("quorum still short, offering the share again",
			"request", key, "have", sess.Collected(), "need", n.cfg.Threshold)
		if err := n.peers.Broadcast(ctx, envelope); err != nil {
			n.log.Warn("share still not delivered everywhere", "err", err)
		}
		n.maybePublish(ctx, id, sess)
	}
}

// jitter spreads a wait over its last fifth. Nine operators backing off in
// lockstep would retry in lockstep, which is what caused the refusal.
func jitter(d time.Duration) time.Duration {
	if d <= 0 {
		return d
	}
	spread := d / 5
	if spread <= 0 {
		return d
	}
	n, err := rand.Int(rand.Reader, big.NewInt(int64(spread)))
	if err != nil {
		return d
	}
	return d + time.Duration(n.Int64())
}

func (n *Node) existingSession(key string) *session.Session {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.sessions[key]
}

// park holds a share until the request it belongs to is announced. Bounded in
// both directions: a fixed number of requests, and no more shares per request
// than there are operators.
func (n *Node) park(key string, e mesh.Envelope) {
	n.mu.Lock()
	defer n.mu.Unlock()

	held, known := n.parked[key]
	if !known {
		if len(n.parkedOrder) >= MaxParkedRequests {
			oldest := n.parkedOrder[0]
			n.parkedOrder = n.parkedOrder[1:]
			delete(n.parked, oldest)
		}
		n.parkedOrder = append(n.parkedOrder, key)
	}
	if len(held) >= n.cfg.Operators {
		return
	}
	n.parked[key] = append(held, e)
}

// takeParked removes and returns whatever was being held for a request.
func (n *Node) takeParked(key string) []mesh.Envelope {
	n.mu.Lock()
	defer n.mu.Unlock()

	held := n.parked[key]
	if held == nil {
		return nil
	}
	delete(n.parked, key)
	for i, k := range n.parkedOrder {
		if k == key {
			n.parkedOrder = append(n.parkedOrder[:i], n.parkedOrder[i+1:]...)
			break
		}
	}
	return held
}

// Parked is how many requests currently have shares waiting on them.
func (n *Node) Parked() int {
	n.mu.Lock()
	defer n.mu.Unlock()
	return len(n.parked)
}

func (n *Node) sessionFor(id *big.Int, seed [32]byte) *session.Session {
	key := hexID(id)
	n.mu.Lock()
	defer n.mu.Unlock()
	if s, ok := n.sessions[key]; ok {
		return s
	}
	s := session.New(seed, n.cfg.Share.Commits, n.cfg.Threshold, n.cfg.Operators)
	n.sessions[key] = s
	return s
}

// maybePublish sends the transaction if this node got there first.
func (n *Node) maybePublish(ctx context.Context, id *big.Int, sess *session.Session) {
	if !sess.Ready() {
		return
	}

	key := hexID(id)
	n.mu.Lock()
	if n.published[key] {
		n.mu.Unlock()
		return
	}
	n.published[key] = true
	n.mu.Unlock()

	signature, err := sess.Signature()
	if err != nil {
		n.log.Error("aggregation failed", "request", key, "err", err)
		n.forget(key)
		return
	}

	if n.knownSettled(key) {
		n.count(func(m *metrics.Registry) { m.RaceLost() })
		n.log.Debug("already fulfilled, seen in the log stream", "request", key)
		n.forget(key)
		return
	}

	if rank := PublishRank(id, n.cfg.Share.Index, n.cfg.Operators); rank > 0 && n.cfg.PublishDelay > 0 {
		select {
		case <-ctx.Done():
			n.forget(key)
			return
		case <-time.After(time.Duration(rank) * n.cfg.PublishDelay):
		}
	}

	// The wait is where the log stream usually catches up, so ask again before
	// spending a call.
	if n.knownSettled(key) {
		n.count(func(m *metrics.Registry) { m.RaceLost() })
		n.log.Debug("already fulfilled, seen in the log stream", "request", key)
		n.forget(key)
		return
	}

	// The logs lag by up to one poll, so they can prove a request closed but
	// never that it is still open. Anything they have not spoken about still
	// costs one call.
	open, err := n.cfg.Chain.IsOpen(ctx, id)
	if err == nil && !open {
		n.count(func(m *metrics.Registry) { m.RaceLost() })
		n.log.Info("already fulfilled by another operator", "request", key)
		n.forget(key)
		return
	}

	// A refusal from the endpoint is not another operator winning the race.
	// Losing the race means the request belongs to someone else now; being
	// refused means nobody has it, and giving up there strands it for good.
	// Which of the two it was is decided by asking the chain, not by reading
	// the error text.
	for attempt := 0; ; attempt++ {
		hash, err := n.cfg.Chain.Fulfill(ctx, id, signature, n.callbackGasOf(key))
		if err == nil {
			n.count(func(m *metrics.Registry) { m.Published() })
			n.log.Info("published", "request", key, "tx", hash)
			n.forget(key)
			if n.cfg.AfterPublish != nil {
				go n.cfg.AfterPublish()
			}
			return
		}

		exhausted := attempt >= n.cfg.SendRetries || n.cfg.SendRetryInterval <= 0
		if !exhausted {
			select {
			case <-ctx.Done():
				n.forget(key)
				return
			case <-time.After(jitter(n.cfg.SendRetryInterval << attempt)):
			}
			// Whoever else was waiting has had a chance to publish by now.
			if open, checkErr := n.cfg.Chain.IsOpen(ctx, id); checkErr == nil && !open {
				exhausted = true
			}
		}
		if exhausted {
			n.count(func(m *metrics.Registry) { m.RaceLost() })
			n.log.Info("did not land the fulfillment",
				"request", key, "attempts", attempt+1, "err", err)
			n.forget(key)
			return
		}
		n.log.Warn("fulfillment refused, trying again",
			"request", key, "attempt", attempt+1, "err", err)
	}
}

// OnFulfilled records that a request has been settled on chain. Called from the
// log stream, which every operator is reading anyway.
func (n *Node) OnFulfilled(id *big.Int) {
	key := hexID(id)
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.settled[key] {
		return
	}
	n.settled[key] = true
	n.settledOrder = append(n.settledOrder, key)
	for len(n.settledOrder) > MaxSettledMemory {
		delete(n.settled, n.settledOrder[0])
		n.settledOrder = n.settledOrder[1:]
	}
}

func (n *Node) knownSettled(key string) bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.settled[key]
}

func (n *Node) forget(key string) {
	n.mu.Lock()
	delete(n.sessions, key)
	n.mu.Unlock()
}

// PublishRank is this operator's place in the queue for one request. Rank 0
// publishes immediately; the rest wait their turn and normally find the request
// already closed. The leader rotates with the request id, so no single operator
// carries the gas cost of always going first.
func PublishRank(id *big.Int, index uint32, operators int) uint32 {
	if operators <= 0 {
		return 0
	}
	n := big.NewInt(int64(operators))
	offset := new(big.Int).Mod(id, n).Uint64()
	return uint32((uint64(index) + uint64(operators) - offset) % uint64(operators))
}

func hexID(id *big.Int) string { return "0x" + id.Text(16) }

func trim0x(s string) string {
	if len(s) > 2 && (s[:2] == "0x" || s[:2] == "0X") {
		return s[2:]
	}
	return s
}
