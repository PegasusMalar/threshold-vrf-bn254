package chain

import (
	"context"
	"math/big"
	"sync"
	"time"
)

// BalanceCache keeps the publishing account's balance without asking the chain
// every time somebody looks.
//
// The question is worth a gauge of its own because an operator that has run out
// of gas money is invisible from outside: it keeps scanning the chain, keeps
// verifying, keeps broadcasting its share — every counter on the node moves —
// and only the one step that costs money stops. A load test found all nine
// operators in exactly that state, delivering 8 fulfilments out of 100 while
// every health signal read green.
//
// Cached rather than read on demand because /metrics is public and
// unauthenticated. A live read would let any visitor turn a scrape into an RPC
// call, on endpoints whose free tier is already the fleet's tightest limit.
type BalanceCache struct {
	read  func(context.Context) (*big.Int, error)
	every time.Duration

	mu      sync.Mutex
	now     func() time.Time
	value   *big.Int
	fetched time.Time
}

// NewBalanceCache refreshes at most once per `every`.
func NewBalanceCache(read func(context.Context) (*big.Int, error), every time.Duration) *BalanceCache {
	return &BalanceCache{read: read, every: every, now: time.Now}
}

// SetClock replaces the source of time, for tests.
func (c *BalanceCache) SetClock(now func() time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = now
}

// Refresh re-reads the balance if the held one has gone stale, and reports
// whether it actually went to the chain. Called from the poll loop, which
// already runs on a timer, so nothing else needs a goroutine; the return value
// is what lets a caller log the news once per refresh rather than once per poll.
func (c *BalanceCache) Refresh(ctx context.Context) bool {
	c.mu.Lock()
	now, fetched := c.now(), c.fetched
	c.mu.Unlock()
	if !fetched.IsZero() && now.Sub(fetched) < c.every {
		return false
	}

	value, err := c.read(ctx)
	if err != nil {
		// Deliberately keeps the previous value and the previous timestamp: a
		// flapping endpoint must not blank the one gauge that says this node
		// has stopped being able to pay, and must not be retried every poll.
		return false
	}

	c.mu.Lock()
	defer c.mu.Unlock()
	c.value, c.fetched = value, now
	return true
}

// Invalidate marks the held value stale, so the next Refresh goes to the chain
// whatever the interval says.
//
// For the one moment the cache cannot predict: this node has just published,
// which is the only event that moves its balance and its earnings at once. The
// interval exists to keep a public metrics scrape from becoming an RPC call,
// not to make the node wait to learn something it already knows happened.
func (c *BalanceCache) Invalidate() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.fetched = time.Time{}
}

// Last is what the metrics handler serves: the last known balance, or nil if
// none has been read yet. It never blocks on the network.
func (c *BalanceCache) Last() *big.Int {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.value == nil {
		return nil
	}
	return new(big.Int).Set(c.value)
}

// Balance is what this account is worth on chain right now.
func (c *Client) Balance(ctx context.Context) (*big.Int, error) {
	return c.eth.BalanceAt(ctx, c.from, nil)
}
