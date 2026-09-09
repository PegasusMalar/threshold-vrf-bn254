package chain_test

import (
	"testing"

	"threshold-vrf/node/internal/chain"
)

// The transaction limit is not what a fulfilment spends — unused gas is not
// charged — but it is what the operator's balance has to cover before the chain
// will accept the transaction at all. Sending every request under the limit the
// largest possible callback would need therefore freezes several times the
// float an ordinary request requires, and freezes it for nothing.
func TestTheGasLimitFollowsTheCallbackTheRequestAskedFor(t *testing.T) {
	small := chain.FulfilGasLimit(100_000)
	large := chain.FulfilGasLimit(2_500_000)

	if small >= large {
		t.Fatalf("a 100k callback reserves %d, a 2.5M one %d", small, large)
	}
	// The coordinator refuses to start unless the whole budget is available,
	// and the 64/63 rule means the callee only ever receives 63/64 of what is
	// left — so the limit has to clear the budget by that margin plus the
	// verification and the bookkeeping around it.
	if small < 100_000*64/63+165_000 {
		t.Fatalf("%d does not cover a 100k callback plus the verification", small)
	}
	if small > 350_000 {
		t.Fatalf("%d is still sized for somebody else's callback", small)
	}
}

// The old fixed limit has to remain reachable, because it is what the largest
// request the coordinator accepts actually needs.
func TestTheLargestCallbackStillGetsTheWholeLimit(t *testing.T) {
	if got := chain.FulfilGasLimit(2_500_000); got < 2_500_000*64/63 {
		t.Fatalf("%d cannot cover the largest callback the coordinator allows", got)
	}
}

// A request that asks for nothing still has to pay for the pairing.
func TestAZeroCallbackStillCoversTheVerification(t *testing.T) {
	if got := chain.FulfilGasLimit(0); got < 165_000 {
		t.Fatalf("%d does not cover a verification", got)
	}
}

// Monotonic, so a larger request can never end up with a smaller limit than a
// smaller one — the kind of inversion that would only show up under load.
func TestTheLimitNeverShrinksAsTheCallbackGrows(t *testing.T) {
	previous := uint64(0)
	for budget := uint32(0); budget <= 2_500_000; budget += 50_000 {
		got := chain.FulfilGasLimit(budget)
		if got < previous {
			t.Fatalf("budget %d got %d, less than the %d before it", budget, got, previous)
		}
		previous = got
	}
}
