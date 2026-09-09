package node_test

import (
	"context"
	"errors"
	"math/big"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"threshold-vrf/node/internal/blsvrf"
	"threshold-vrf/node/internal/chain"
	"threshold-vrf/node/internal/dkg"
	"threshold-vrf/node/internal/mesh"
	"threshold-vrf/node/internal/metrics"
	"threshold-vrf/node/internal/node"
)

const (
	operators = 3
	quorum    = 2
)

// fakeChain stands in for the coordinator. It enforces the one rule the node
// depends on: a request closes exactly once.
type fakeChain struct {
	mu         sync.Mutex
	seed       [32]byte
	seedCalls  int
	closed     bool
	signatures [][]byte
	attempts   int
	// failFulfils makes the first n send attempts fail the way a throttled
	// endpoint does: the request stays open, nobody published it.
	failFulfils int
	landed      int
	openCalls   int
}

func (f *fakeChain) fulfilled() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.landed
}

func (f *fakeChain) openChecks() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.openCalls
}

func (f *fakeChain) attemptCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.attempts
}

func (f *fakeChain) SeedOf(context.Context, *big.Int) ([32]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.seedCalls++
	return f.seed, nil
}

func (f *fakeChain) DeriveSeed(*big.Int, common.Address) [32]byte { return f.seed }

func (f *fakeChain) IsOpen(context.Context, *big.Int) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.openCalls++
	return !f.closed, nil
}

func (f *fakeChain) Fulfill(
	_ context.Context, _ *big.Int, sig []byte, _ uint32,
) (common.Hash, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.attempts++
	if f.failFulfils > 0 {
		f.failFulfils--
		return common.Hash{}, errThrottled
	}
	if f.closed {
		return common.Hash{}, errRequestClosed
	}
	f.closed = true
	f.landed++
	f.signatures = append(f.signatures, sig)
	return common.Hash{1}, nil
}

var errRequestClosed = &closedError{}

// What a public endpoint answering nine operators returns under a burst.
var errThrottled = errors.New("429 Too Many Requests")

type closedError struct{}

func (*closedError) Error() string { return "request closed" }

// Three nodes, each its own aggregator, all told about the same request at
// once. Exactly one transaction must reach the chain, and it must carry the
// group signature.
func TestThreeNodesConvergeOnOneFulfillment(t *testing.T) {
	ctx := context.Background()
	shares, err := dkg.RunLocal(operators, quorum, 1)
	if err != nil {
		t.Fatal(err)
	}

	var seed [32]byte
	seed[31] = 42
	shared := &fakeChain{seed: seed}

	nodes := make([]*node.Node, operators)
	servers := make([]*httptest.Server, operators)
	for i := range nodes {
		nodes[i] = node.New(node.Config{
			Share:     shares[i],
			Threshold: quorum,
			Operators: operators,
			Chain:     shared,
		})
		servers[i] = httptest.NewServer(mesh.NewServer(nodes[i].OnPeerShare, nil))
		defer servers[i].Close()
	}
	// everyone talks to everyone else
	for i := range nodes {
		peers := make([]string, 0, operators-1)
		for j := range servers {
			if i != j {
				peers = append(peers, servers[j].URL)
			}
		}
		nodes[i].SetPeers(mesh.NewClient(peers, 2*time.Second))
	}

	request := chain.Request{ID: big.NewInt(7), Seed: seed, NumWords: 1}

	var wg sync.WaitGroup
	for i := range nodes {
		wg.Add(1)
		go func(n *node.Node) {
			defer wg.Done()
			n.OnRequest(ctx, request)
		}(nodes[i])
	}
	wg.Wait()

	// give the last in-flight broadcasts a moment to land
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		shared.mu.Lock()
		done := shared.closed
		shared.mu.Unlock()
		if done {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	shared.mu.Lock()
	defer shared.mu.Unlock()
	if len(shared.signatures) != 1 {
		t.Fatalf("expected exactly one fulfillment, got %d", len(shared.signatures))
	}

	point, err := blsvrf.PointFromSignature(shared.signatures[0])
	if err != nil {
		t.Fatal(err)
	}
	if !blsvrf.Verify(shares[0].GroupPublic, seed, point) {
		t.Fatal("the published signature does not verify against the group key")
	}
}

// A node must refuse to sign a seed that disagrees with the contract: the event
// is only a hint, the contract is the authority.
func TestASeedThatDisagreesWithTheContractIsNotSigned(t *testing.T) {
	ctx := context.Background()
	shares, err := dkg.RunLocal(operators, quorum, 1)
	if err != nil {
		t.Fatal(err)
	}

	var onChain, claimed [32]byte
	onChain[0] = 1
	claimed[0] = 2

	fake := &fakeChain{seed: onChain}
	n := node.New(node.Config{Share: shares[0], Threshold: quorum, Operators: operators, Chain: fake})
	n.SetPeers(mesh.NewClient(nil, time.Second))

	n.OnRequest(ctx, chain.Request{ID: big.NewInt(1), Seed: claimed, NumWords: 1})

	if n.Sessions() != 0 {
		t.Fatal("the node opened a session for a seed that is not what the coordinator will check")
	}
	if fake.attempts != 0 {
		t.Fatal("it published anyway")
	}
}

// The share endpoint is open to the internet. A share for a request this node
// has never seen must not turn into an RPC call, or anyone with the URL can
// spend the operator's RPC quota for free.
func TestAShareForAnUnknownRequestCostsNoRpcCall(t *testing.T) {
	ctx := context.Background()
	shares, err := dkg.RunLocal(operators, quorum, 1)
	if err != nil {
		t.Fatal(err)
	}

	var seed [32]byte
	seed[31] = 5
	fake := &fakeChain{seed: seed}
	n := node.New(node.Config{Share: shares[0], Threshold: quorum, Operators: operators, Chain: fake})
	n.SetPeers(mesh.NewClient(nil, time.Second))

	for i := 0; i < 50; i++ {
		_ = n.OnPeerShare(ctx, envelopeFor(t, shares[1], seed, "0x"+big.NewInt(int64(i)).Text(16)))
	}

	fake.mu.Lock()
	calls := fake.seedCalls
	fake.mu.Unlock()
	if calls != 0 {
		t.Fatalf("50 shares for unknown requests made %d RPC calls", calls)
	}
}

// A peer can legitimately be a poll interval ahead of us. Its share is held
// until our own watcher announces the request, then filed.
func TestAShareThatArrivesBeforeTheRequestIsReplayed(t *testing.T) {
	ctx := context.Background()
	shares, err := dkg.RunLocal(operators, quorum, 1)
	if err != nil {
		t.Fatal(err)
	}

	var seed [32]byte
	seed[31] = 5
	fake := &fakeChain{seed: seed}
	n := node.New(node.Config{Share: shares[0], Threshold: quorum, Operators: operators, Chain: fake})
	n.SetPeers(mesh.NewClient(nil, time.Second))

	// a peer gets there first, while we have not seen the request at all
	if err := n.OnPeerShare(ctx, envelopeFor(t, shares[1], seed, "0x9")); err != nil {
		t.Fatalf("an early share was refused: %v", err)
	}
	if n.Parked() != 1 {
		t.Fatal("the early share was dropped instead of held")
	}

	// then our own watcher catches up: the held share plus our own makes the
	// quorum, with no further help
	n.OnRequest(ctx, chain.Request{ID: big.NewInt(9), Seed: seed, NumWords: 1})

	if n.Parked() != 0 {
		t.Fatal("the holding area was not drained")
	}

	fake.mu.Lock()
	defer fake.mu.Unlock()
	if len(fake.signatures) != 1 {
		t.Fatalf("the parked shares did not add up to a fulfilment (%d)", len(fake.signatures))
	}
}

// Parking has to be bounded, or the same open endpoint fills memory instead.
func TestTheHoldingAreaIsBounded(t *testing.T) {
	ctx := context.Background()
	shares, err := dkg.RunLocal(operators, quorum, 1)
	if err != nil {
		t.Fatal(err)
	}

	var seed [32]byte
	seed[31] = 5
	n := node.New(node.Config{
		Share: shares[0], Threshold: quorum, Operators: operators, Chain: &fakeChain{seed: seed},
	})
	n.SetPeers(mesh.NewClient(nil, time.Second))

	for i := 0; i < 5000; i++ {
		_ = n.OnPeerShare(ctx, envelopeFor(t, shares[1], seed, "0x"+big.NewInt(int64(i)).Text(16)))
	}
	if held := n.Parked(); held > node.MaxParkedRequests {
		t.Fatalf("holding %d requests, cap is %d", held, node.MaxParkedRequests)
	}
}

// A share whose seed disagrees with the request we are actually tracking is
// rejected without any crypto being done.
func TestAShareWithTheWrongSeedIsRejected(t *testing.T) {
	ctx := context.Background()
	shares, err := dkg.RunLocal(operators, quorum, 1)
	if err != nil {
		t.Fatal(err)
	}

	var seed, wrong [32]byte
	seed[31] = 5
	wrong[0] = 0xff
	n := node.New(node.Config{
		Share: shares[0], Threshold: quorum, Operators: operators, Chain: &fakeChain{seed: seed},
	})
	n.SetPeers(mesh.NewClient(nil, time.Second))
	n.OnRequest(ctx, chain.Request{ID: big.NewInt(9), Seed: seed, NumWords: 1})

	if err := n.OnPeerShare(ctx, envelopeFor(t, shares[1], wrong, "0x9")); err == nil {
		t.Fatal("a share for a different seed was accepted")
	}
}

// Without staggering, every operator that reaches the threshold sends a
// transaction and all but one revert, paying gas for nothing. The publish order
// rotates per request, so the cost is shared rather than always borne by the
// same node.
func TestOnlyTheDesignatedOperatorPublishesWhenStaggered(t *testing.T) {
	ctx := context.Background()
	shares, err := dkg.RunLocal(operators, quorum, 1)
	if err != nil {
		t.Fatal(err)
	}

	var seed [32]byte
	seed[31] = 11
	shared := &fakeChain{seed: seed}

	nodes := make([]*node.Node, operators)
	servers := make([]*httptest.Server, operators)
	for i := range nodes {
		nodes[i] = node.New(node.Config{
			Share:        shares[i],
			Threshold:    quorum,
			Operators:    operators,
			Chain:        shared,
			PublishDelay: 300 * time.Millisecond,
		})
		servers[i] = httptest.NewServer(mesh.NewServer(nodes[i].OnPeerShare, nil))
		defer servers[i].Close()
	}
	for i := range nodes {
		peers := make([]string, 0, operators-1)
		for j := range servers {
			if i != j {
				peers = append(peers, servers[j].URL)
			}
		}
		nodes[i].SetPeers(mesh.NewClient(peers, 2*time.Second))
	}

	request := chain.Request{ID: big.NewInt(7), Seed: seed, NumWords: 1}
	var wg sync.WaitGroup
	for i := range nodes {
		wg.Add(1)
		go func(n *node.Node) {
			defer wg.Done()
			n.OnRequest(ctx, request)
		}(nodes[i])
	}
	wg.Wait()
	// Publishing no longer happens on the caller's goroutine: a share arriving
	// from a peer must be answered at once, not after this operator's turn to
	// publish comes round. Waited out rather than slept through, so the point
	// being checked stays "exactly one transaction", not "one so far".
	waitFor(t, 5*time.Second, func() bool {
		shared.mu.Lock()
		defer shared.mu.Unlock()
		return len(shared.signatures) == 1
	})
	// long enough that a second operator, if it were going to send, would have
	time.Sleep(4 * 300 * time.Millisecond)

	shared.mu.Lock()
	defer shared.mu.Unlock()
	if len(shared.signatures) != 1 {
		t.Fatalf("expected one fulfillment, got %d", len(shared.signatures))
	}
	if shared.attempts != 1 {
		t.Fatalf("%d operators sent a transaction; staggering should leave one", shared.attempts)
	}
}

// waitFor polls until the condition holds or the budget runs out.
func waitFor(t *testing.T, budget time.Duration, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(budget)
	for time.Now().Before(deadline) {
		if ok() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("condition still false after %v", budget)
}

func TestThePublishOrderRotatesBetweenRequests(t *testing.T) {
	seen := map[uint32]bool{}
	for id := int64(0); id < 12; id++ {
		seen[node.PublishRank(big.NewInt(id), 0, operators)] = true
	}
	if len(seen) < operators {
		t.Fatalf("operator 0 only ever takes ranks %v; the cost is not shared", seen)
	}
}

// After a restart a node rescans recent blocks and sees requests that were
// already dealt with. Signing them again is wasted work, and publishing them
// is a guaranteed revert. The fulfilments sit in those same rescanned blocks,
// which is how the node knows without asking the chain once per request.
func TestAlreadyClosedRequestsAreSkipped(t *testing.T) {
	ctx := context.Background()
	shares, err := dkg.RunLocal(operators, quorum, 1)
	if err != nil {
		t.Fatal(err)
	}

	var seed [32]byte
	seed[31] = 13
	fake := &fakeChain{seed: seed, closed: true}

	n := node.New(node.Config{Share: shares[0], Threshold: quorum, Operators: operators, Chain: fake})
	n.SetPeers(mesh.NewClient(nil, time.Second))
	n.OnFulfilled(big.NewInt(3)) // read out of the same block range as the request
	n.OnRequest(ctx, chain.Request{ID: big.NewInt(3), Seed: seed, NumWords: 1})

	if n.Sessions() != 0 {
		t.Fatal("a closed request opened a session")
	}
	if fake.attempts != 0 {
		t.Fatal("a closed request was published to")
	}
	if fake.openChecks() != 0 {
		t.Fatal("asked the chain about a request the log stream had settled")
	}
}

// The counters are what the operator monitor is built on, so the wiring between
// the node and the registry has to be exercised, not assumed.
func TestTheCountersFollowWhatTheNodeActuallyDid(t *testing.T) {
	ctx := context.Background()
	shares, err := dkg.RunLocal(operators, quorum, 1)
	if err != nil {
		t.Fatal(err)
	}

	var seed [32]byte
	seed[31] = 21
	fake := &fakeChain{seed: seed}
	counters := metrics.New(shares[0].Index, quorum, operators)
	n := node.New(node.Config{
		Share: shares[0], Threshold: quorum, Operators: operators,
		Chain: fake, Metrics: counters,
	})
	n.SetPeers(mesh.NewClient(nil, time.Second))

	n.OnRequest(ctx, chain.Request{ID: big.NewInt(4), Seed: seed, NumWords: 1, Block: 99})
	// peer 1 completes the quorum, peer 2 is late, a forgery from peer 2 fails
	_ = n.OnPeerShare(ctx, envelopeFor(t, shares[1], seed, "0x4"))
	_ = n.OnPeerShare(ctx, envelopeFor(t, shares[2], seed, "0x4"))

	body := scrapeMetrics(t, counters)
	for _, want := range []string{
		"vrf_operator_index 0",
		"vrf_requests_seen_total 1",
		"vrf_shares_sent_total 1",
		"vrf_last_seen_block 99",
		"vrf_fulfilments_published_total 1",
		`vrf_shares_received_total{peer="1"} 1`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("missing %q in:\n%s", want, body)
		}
	}
}

// A share that a peer refused — because it was busy, rate limited, or briefly
// unreachable — used to be gone for good, and with it any chance of that request
// ever reaching a quorum. Under load that is not an edge case: it is what a
// burst looks like.
func TestAShareIsResentUntilTheQuorumIsThere(t *testing.T) {
	ctx := context.Background()
	shares, err := dkg.RunLocal(operators, quorum, 1)
	if err != nil {
		t.Fatal(err)
	}

	var seed [32]byte
	seed[31] = 31
	fake := &fakeChain{seed: seed}

	var mu sync.Mutex
	attempts := 0
	peer := httptest.NewServer(mesh.NewServer(func(context.Context, mesh.Envelope) error {
		mu.Lock()
		defer mu.Unlock()
		attempts++
		if attempts < 3 {
			return mesh.ErrRejected // busy
		}
		return nil
	}, nil))
	defer peer.Close()

	n := node.New(node.Config{
		Share: shares[0], Threshold: quorum, Operators: operators, Chain: fake,
		RebroadcastInterval: 50 * time.Millisecond,
		RebroadcastAttempts: 5,
	})
	n.SetPeers(mesh.NewClient([]string{peer.URL}, time.Second))
	n.OnRequest(ctx, chain.Request{ID: big.NewInt(31), Seed: seed, NumWords: 1})

	mu.Lock()
	defer mu.Unlock()
	if attempts < 3 {
		t.Fatalf("gave up after %d attempts; a refused share was simply dropped", attempts)
	}
}

// ...but not forever: once the quorum is in hand there is nothing left to chase.
func TestResendingStopsOnceTheQuorumIsMet(t *testing.T) {
	ctx := context.Background()
	shares, err := dkg.RunLocal(operators, quorum, 1)
	if err != nil {
		t.Fatal(err)
	}

	var seed [32]byte
	seed[31] = 32
	fake := &fakeChain{seed: seed}

	var mu sync.Mutex
	attempts := 0
	peer := httptest.NewServer(mesh.NewServer(func(context.Context, mesh.Envelope) error {
		mu.Lock()
		attempts++
		mu.Unlock()
		return nil
	}, nil))
	defer peer.Close()

	n := node.New(node.Config{
		Share: shares[0], Threshold: 2, Operators: operators, Chain: fake,
		RebroadcastInterval: 50 * time.Millisecond,
		RebroadcastAttempts: 10,
	})
	n.SetPeers(mesh.NewClient([]string{peer.URL}, time.Second))

	// one peer share completes the quorum of two straight away
	_ = n.OnPeerShare(ctx, envelopeFor(t, shares[1], seed, "0x20"))
	n.OnRequest(ctx, chain.Request{ID: big.NewInt(0x20), Seed: seed, NumWords: 1})

	mu.Lock()
	defer mu.Unlock()
	if attempts > 2 {
		t.Fatalf("kept resending %d times with the quorum already complete", attempts)
	}
}

// An RPC endpoint that refuses is not another operator winning the race. Losing
// the race means the request is someone else's now; being refused means nobody
// has it, and dropping it there strands the request for good.
func TestARefusedTransactionIsRetriedNotTreatedAsALostRace(t *testing.T) {
	ctx := context.Background()
	shares, err := dkg.RunLocal(operators, 2, 1)
	if err != nil {
		t.Fatal(err)
	}

	var seed [32]byte
	seed[31] = 41
	fake := &fakeChain{seed: seed, failFulfils: 2} // refuses twice, then accepts

	n := node.New(node.Config{
		Share: shares[0], Threshold: 2, Operators: operators, Chain: fake,
		SendRetryInterval: 20 * time.Millisecond,
		SendRetries:       4,
	})
	_ = n.OnPeerShare(ctx, envelopeFor(t, shares[1], seed, "0x29"))
	n.OnRequest(ctx, chain.Request{ID: big.NewInt(0x29), Seed: seed, NumWords: 1})

	if got := fake.fulfilled(); got != 1 {
		t.Fatalf("fulfilled %d times; a refused send was mistaken for a lost race", got)
	}
}

// ...but a request another operator really did publish must be dropped at once.
// Retrying that one is a guaranteed-to-revert transaction, paid for in real gas.
func TestARequestAnotherOperatorPublishedIsNotRetried(t *testing.T) {
	ctx := context.Background()
	shares, err := dkg.RunLocal(operators, 2, 1)
	if err != nil {
		t.Fatal(err)
	}

	var seed [32]byte
	seed[31] = 42
	fake := &fakeChain{seed: seed, closed: true}

	n := node.New(node.Config{
		Share: shares[0], Threshold: 2, Operators: operators, Chain: fake,
		SendRetryInterval: 20 * time.Millisecond,
		SendRetries:       4,
	})
	_ = n.OnPeerShare(ctx, envelopeFor(t, shares[1], seed, "0x2a"))
	n.OnRequest(ctx, chain.Request{ID: big.NewInt(0x2a), Seed: seed, NumWords: 1})

	if got := fake.fulfilled(); got != 0 {
		t.Fatalf("sent %d transactions for a request that was already fulfilled", got)
	}
}

// Eight of nine operators lose every race. Having each of them ask the chain
// about every request costs, for a burst of fifty, four hundred and fifty calls
// at the same endpoint the whole group depends on. The log stream already says
// which requests are settled — an operator that has read it has no question
// left to ask.
func TestARequestKnownSettledCostsNoChainCalls(t *testing.T) {
	ctx := context.Background()
	shares, err := dkg.RunLocal(operators, 2, 1)
	if err != nil {
		t.Fatal(err)
	}

	var seed [32]byte
	seed[31] = 51
	fake := &fakeChain{seed: seed}

	n := node.New(node.Config{
		Share: shares[0], Threshold: 2, Operators: operators, Chain: fake,
	})
	n.OnFulfilled(big.NewInt(0x33)) // seen settled in the log stream

	_ = n.OnPeerShare(ctx, envelopeFor(t, shares[1], seed, "0x33"))
	n.OnRequest(ctx, chain.Request{ID: big.NewInt(0x33), Seed: seed, NumWords: 1})

	if got := fake.openChecks(); got != 0 {
		t.Fatalf("asked the chain %d times about a request it had already seen settled", got)
	}
	if got := fake.attemptCount(); got != 0 {
		t.Fatalf("sent %d transactions for a request it had already seen settled", got)
	}
}

// The log stream lags by up to one poll, so it can only ever prove a request is
// closed — never that it is still open. A request it has said nothing about
// must still be checked, or the group would publish nothing at all.
func TestARequestNotYetSeenSettledIsStillChecked(t *testing.T) {
	ctx := context.Background()
	shares, err := dkg.RunLocal(operators, 2, 1)
	if err != nil {
		t.Fatal(err)
	}

	var seed [32]byte
	seed[31] = 52
	fake := &fakeChain{seed: seed}

	n := node.New(node.Config{
		Share: shares[0], Threshold: 2, Operators: operators, Chain: fake,
	})
	n.OnFulfilled(big.NewInt(0x99)) // a different request

	_ = n.OnPeerShare(ctx, envelopeFor(t, shares[1], seed, "0x34"))
	n.OnRequest(ctx, chain.Request{ID: big.NewInt(0x34), Seed: seed, NumWords: 1})

	if got := fake.fulfilled(); got != 1 {
		t.Fatalf("fulfilled %d times; the shortcut swallowed a live request", got)
	}
}

// Publishing waits for this operator's turn — up to sixteen seconds with nine
// of them. Doing that on the request path meant a peer's POST of a share sat
// open for the whole wait, so under a burst peers timed out on each other and
// the shares never landed. Answering the peer is not the same thing as doing
// the work it triggered.
func TestTakingAShareDoesNotBlockOnThePublishTurn(t *testing.T) {
	ctx := context.Background()
	shares, err := dkg.RunLocal(operators, 2, 1)
	if err != nil {
		t.Fatal(err)
	}

	var seed [32]byte
	seed[31] = 61
	fake := &fakeChain{seed: seed}

	// id 0x25 puts operator 0 at rank 2 of 3, so publishing waits two delays
	const id = 0x25
	if got := node.PublishRank(big.NewInt(id), 0, operators); got == 0 {
		t.Fatalf("rank %d: this request would publish immediately and prove nothing", got)
	}

	n := node.New(node.Config{
		Share: shares[0], Threshold: 2, Operators: operators, Chain: fake,
		PublishDelay: 5 * time.Second,
	})
	n.OnRequest(ctx, chain.Request{ID: big.NewInt(id), Seed: seed, NumWords: 1})

	start := time.Now()
	if err := n.OnPeerShare(ctx, envelopeFor(t, shares[1], seed, "0x25")); err != nil {
		t.Fatal(err)
	}
	if took := time.Since(start); took > time.Second {
		t.Fatalf("answering a peer took %v: the publish wait is on the request path", took)
	}
}
