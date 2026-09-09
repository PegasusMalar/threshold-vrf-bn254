package chain_test

import (
	"context"
	"errors"
	"math/big"
	"testing"
	"time"

	"threshold-vrf/node/internal/chain"
)

// A fake account, so the cache can be tested without a chain.
type account struct {
	calls int
	value int64
	err   error
}

func (a *account) read(context.Context) (*big.Int, error) {
	a.calls++
	if a.err != nil {
		return nil, a.err
	}
	return big.NewInt(a.value), nil
}

func at(t time.Time) func() time.Time { return func() time.Time { return t } }

func TestNothingIsKnownBeforeTheFirstRefresh(t *testing.T) {
	c := chain.NewBalanceCache((&account{value: 7}).read, time.Minute)
	if got := c.Last(); got != nil {
		t.Fatalf("expected no value before the first refresh, got %v", got)
	}
}

func TestRefreshRecordsWhatTheChainSays(t *testing.T) {
	c := chain.NewBalanceCache((&account{value: 42}).read, time.Minute)
	c.Refresh(context.Background())
	if got := c.Last(); got == nil || got.Int64() != 42 {
		t.Fatalf("expected 42, got %v", got)
	}
}

// The point of the cache: /metrics is public, and a scrape must not turn into
// an RPC call on an endpoint whose free tier is the fleet's tightest limit.
func TestAFreshValueIsNotFetchedAgain(t *testing.T) {
	acct := &account{value: 1}
	start := time.Now()
	c := chain.NewBalanceCache(acct.read, time.Minute)
	c.SetClock(at(start))

	c.Refresh(context.Background())
	c.SetClock(at(start.Add(59 * time.Second)))
	c.Refresh(context.Background())

	if acct.calls != 1 {
		t.Fatalf("expected one call while the value is fresh, got %d", acct.calls)
	}
}

func TestAStaleValueIsFetchedAgain(t *testing.T) {
	acct := &account{value: 1}
	start := time.Now()
	c := chain.NewBalanceCache(acct.read, time.Minute)
	c.SetClock(at(start))

	c.Refresh(context.Background())
	acct.value = 2
	c.SetClock(at(start.Add(61 * time.Second)))
	c.Refresh(context.Background())

	if acct.calls != 2 {
		t.Fatalf("expected a second call once stale, got %d", acct.calls)
	}
	if got := c.Last(); got.Int64() != 2 {
		t.Fatalf("expected the fresh value 2, got %v", got)
	}
}

// A refresh that fails must not erase what we knew: a flapping endpoint would
// otherwise blank the one gauge that says the node has run out of money.
func TestAFailedRefreshKeepsTheLastKnownValue(t *testing.T) {
	acct := &account{value: 5}
	start := time.Now()
	c := chain.NewBalanceCache(acct.read, time.Minute)
	c.SetClock(at(start))
	c.Refresh(context.Background())

	acct.err = errors.New("rpc down")
	c.SetClock(at(start.Add(2 * time.Minute)))
	c.Refresh(context.Background())

	if got := c.Last(); got == nil || got.Int64() != 5 {
		t.Fatalf("expected the last known 5 to survive, got %v", got)
	}
}

// Refresh says whether it actually went to the chain, so a caller can log the
// news once a minute instead of once per poll. Warning on every scan buries the
// journal in a line that says nothing new.
func TestRefreshReportsWhetherItFetched(t *testing.T) {
	acct := &account{value: 1}
	start := time.Now()
	c := chain.NewBalanceCache(acct.read, time.Minute)
	c.SetClock(at(start))

	if !c.Refresh(context.Background()) {
		t.Fatal("the first refresh should report a fetch")
	}
	c.SetClock(at(start.Add(30 * time.Second)))
	if c.Refresh(context.Background()) {
		t.Fatal("a refresh that found the value fresh should report no fetch")
	}
	c.SetClock(at(start.Add(2 * time.Minute)))
	if !c.Refresh(context.Background()) {
		t.Fatal("a refresh past the interval should report a fetch")
	}

	acct.err = errors.New("rpc down")
	c.SetClock(at(start.Add(4 * time.Minute)))
	if c.Refresh(context.Background()) {
		t.Fatal("a failed refresh should not report a fetch")
	}
}
