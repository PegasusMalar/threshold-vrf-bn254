package chain_test

import (
	"math/big"
	"testing"

	"threshold-vrf/node/internal/chain"
)

func wei(x int64) *big.Int { return big.NewInt(x) }

// An operator's fee does not arrive in its wallet. It is credited inside the
// subscription contract and sits there until somebody calls withdraw, so an
// operator that never claims runs its balance down to nothing while its
// earnings pile up untouched — which is exactly how the testnet fleet stopped,
// with every health counter green.
func TestClaimingIsWorthItOnlyWhenThereIsSomethingToClaim(t *testing.T) {
	cost := wei(100)

	if chain.ShouldClaim(wei(10), wei(0), wei(1000), cost) {
		t.Fatal("claimed nothing at all")
	}
	// Earnings smaller than the transaction that collects them: claiming makes
	// the operator poorer, so it waits for them to add up.
	if chain.ShouldClaim(wei(10), wei(50), wei(1000), cost) {
		t.Fatal("spent 100 to collect 50")
	}
	if !chain.ShouldClaim(wei(10), wei(5000), wei(1000), cost) {
		t.Fatal("did not collect earnings worth many times the claim")
	}
}

// Only when it needs the money. A claim is a transaction like any other, and
// an operator that sweeps after every fulfilment spends a meaningful slice of
// what it just earned on the sweeping.
func TestAComfortableOperatorDoesNotClaim(t *testing.T) {
	if chain.ShouldClaim(wei(9000), wei(5000), wei(1000), wei(100)) {
		t.Fatal("claimed while well above the floor")
	}
	if !chain.ShouldClaim(wei(999), wei(5000), wei(1000), wei(100)) {
		t.Fatal("did not claim once below the floor")
	}
}

// Unknown balance is not zero. A node that could not read its balance must not
// conclude it is broke and start sending transactions about it.
func TestNothingIsClaimedOnMissingInformation(t *testing.T) {
	if chain.ShouldClaim(nil, wei(5000), wei(1000), wei(100)) {
		t.Fatal("claimed without knowing the balance")
	}
	if chain.ShouldClaim(wei(10), nil, wei(1000), wei(100)) {
		t.Fatal("claimed without knowing the earnings")
	}
}

// The margin has to be real. Earnings worth exactly the claim leave the
// operator no better off, and a fleet of nine doing that every minute is a
// self-inflicted denial of service on its own endpoint.
func TestEarningsMustBeWorthSeveralTimesTheClaim(t *testing.T) {
	cost := wei(100)
	if chain.ShouldClaim(wei(10), wei(100), wei(1000), cost) {
		t.Fatal("claimed earnings worth exactly the transaction that collects them")
	}
	if chain.ShouldClaim(wei(10), wei(299), wei(1000), cost) {
		t.Fatal("claimed on a margin too thin to be worth a transaction")
	}
	if !chain.ShouldClaim(wei(10), wei(301), wei(1000), cost) {
		t.Fatal("refused a claim worth three times its cost")
	}
}

// A claim is one storage write and a transfer. Sending it under the
// fulfilment's gas limit makes the node reserve ten times what the claim can
// possibly spend — and since the reserve is checked against the balance before
// the transaction is accepted, an operator poor enough to need its earnings
// would be too poor to go and get them. A deadlock reachable only when the
// mechanism matters.
func TestAClaimIsSentUnderItsOwnGasLimit(t *testing.T) {
	if chain.ClaimGas >= chain.DefaultGasLimit {
		t.Fatalf("a claim reserves %d gas, the same as a fulfilment's %d",
			chain.ClaimGas, chain.DefaultGasLimit)
	}
	// Room for the write and the transfer, and not much more.
	if chain.ClaimGas < 40_000 || chain.ClaimGas > 120_000 {
		t.Fatalf("ClaimGas of %d is not the cost of a claim", chain.ClaimGas)
	}
}
