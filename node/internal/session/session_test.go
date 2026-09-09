package session_test

import (
	"testing"

	"threshold-vrf/node/internal/blsvrf"
	"threshold-vrf/node/internal/dkg"
	"threshold-vrf/node/internal/session"
	"threshold-vrf/node/internal/threshold"
)

const (
	operators = 9
	quorum    = 5
)

func fixture(t *testing.T) ([]dkg.Share, [32]byte) {
	t.Helper()
	shares, err := dkg.RunLocal(operators, quorum, 1)
	if err != nil {
		t.Fatal(err)
	}
	var seed [32]byte
	seed[31] = 7
	return shares, seed
}

func partial(s dkg.Share, seed [32]byte) threshold.Partial {
	return threshold.Partial{Index: s.Index, Sig: blsvrf.Sign(s.Secret, seed)}
}

func TestCollectsUntilThresholdThenProducesTheGroupSignature(t *testing.T) {
	shares, seed := fixture(t)
	sess := session.New(seed, shares[0].Commits, quorum, operators)

	for i := 0; i < quorum-1; i++ {
		if _, err := sess.Add(partial(shares[i], seed)); err != nil {
			t.Fatal(err)
		}
		if sess.Ready() {
			t.Fatalf("ready after only %d shares", i+1)
		}
	}

	if _, err := sess.Add(partial(shares[quorum-1], seed)); err != nil {
		t.Fatal(err)
	}
	if !sess.Ready() {
		t.Fatal("not ready at the threshold")
	}

	sig, err := sess.Signature()
	if err != nil {
		t.Fatal(err)
	}
	if len(sig) != blsvrf.SignatureLength {
		t.Fatalf("signature is %d bytes", len(sig))
	}

	point, err := blsvrf.PointFromSignature(sig)
	if err != nil {
		t.Fatal(err)
	}
	if !blsvrf.Verify(shares[0].GroupPublic, seed, point) {
		t.Fatal("collected signature does not verify against the group key")
	}
}

// Nothing that fails to verify may reach the aggregator: one bad partial
// silently poisons the result, and the node would publish a transaction that
// reverts and costs it gas.
func TestRejectsAPartialThatDoesNotVerify(t *testing.T) {
	shares, seed := fixture(t)
	sess := session.New(seed, shares[0].Commits, quorum, operators)

	forged := threshold.Partial{Index: shares[0].Index, Sig: blsvrf.Sign(shares[3].Secret, seed)}
	if _, err := sess.Add(forged); err == nil {
		t.Fatal("a partial signed with the wrong share was accepted")
	}
	if sess.Collected() != 0 {
		t.Fatal("a rejected partial was still counted")
	}
}

func TestRejectsAPartialForAnotherSeed(t *testing.T) {
	shares, seed := fixture(t)
	sess := session.New(seed, shares[0].Commits, quorum, operators)

	var other [32]byte
	other[0] = 1
	if _, err := sess.Add(partial(shares[0], other)); err == nil {
		t.Fatal("a partial for a different seed was accepted")
	}
}

func TestRejectsAnUnknownOperatorIndex(t *testing.T) {
	shares, seed := fixture(t)
	sess := session.New(seed, shares[0].Commits, quorum, operators)

	p := partial(shares[0], seed)
	p.Index = operators + 3
	if _, err := sess.Add(p); err == nil {
		t.Fatal("a partial from an index outside the group was accepted")
	}
}

func TestDuplicateFromTheSameOperatorIsIgnoredNotCounted(t *testing.T) {
	shares, seed := fixture(t)
	sess := session.New(seed, shares[0].Commits, quorum, operators)

	added, err := sess.Add(partial(shares[0], seed))
	if err != nil || !added {
		t.Fatalf("first partial rejected: %v", err)
	}
	added, err = sess.Add(partial(shares[0], seed))
	if err != nil {
		t.Fatal(err)
	}
	if added {
		t.Fatal("the same partial was counted twice")
	}
	if sess.Collected() != 1 {
		t.Fatalf("collected %d", sess.Collected())
	}
}

// Two different valid-looking partials for one seed from one operator is
// equivocation: cryptographic evidence, and one of the two slashable offences
// in TZ section 8.2.
func TestKeepsEvidenceOfEquivocation(t *testing.T) {
	shares, seed := fixture(t)
	sess := session.New(seed, shares[0].Commits, quorum, operators)

	if _, err := sess.Add(partial(shares[0], seed)); err != nil {
		t.Fatal(err)
	}

	// a second, different point claimed for the same index
	bogus := threshold.Partial{Index: shares[0].Index, Sig: blsvrf.Sign(shares[1].Secret, seed)}
	if _, err := sess.Add(bogus); err == nil {
		t.Fatal("the conflicting partial should not verify")
	}

	ev, ok := sess.Equivocation()
	if !ok {
		t.Fatal("no equivocation recorded")
	}
	if ev.Index != shares[0].Index {
		t.Fatalf("evidence points at operator %d", ev.Index)
	}
	if ev.First.Equal(ev.Second) {
		t.Fatal("evidence holds two identical signatures")
	}
}

func TestSignatureBeforeThresholdIsAnError(t *testing.T) {
	shares, seed := fixture(t)
	sess := session.New(seed, shares[0].Commits, quorum, operators)
	if _, err := sess.Add(partial(shares[0], seed)); err != nil {
		t.Fatal(err)
	}
	if _, err := sess.Signature(); err == nil {
		t.Fatal("produced a signature below the threshold")
	}
}

// A share that arrives after the quorum is complete is no longer needed for the
// signature — but it is the only proof its sender is alive, and that is what the
// operator monitor runs on. It must still be checked and counted, or a slow but
// healthy operator becomes indistinguishable from a dead one.
func TestALateButValidShareIsStillVerifiedAndCounted(t *testing.T) {
	shares, seed := fixture(t)
	sess := session.New(seed, shares[0].Commits, quorum, operators)

	for i := 0; i < quorum; i++ {
		if _, err := sess.Add(partial(shares[i], seed)); err != nil {
			t.Fatal(err)
		}
	}
	if !sess.Ready() {
		t.Fatal("not ready at the threshold")
	}

	added, err := sess.Add(partial(shares[quorum], seed))
	if err != nil {
		t.Fatalf("a late but valid share was refused: %v", err)
	}
	if !added {
		t.Fatal("a late share was dropped, so its sender looks silent to the monitor")
	}
}

// The same share arriving twice — which happens constantly, since everyone
// broadcasts to everyone — must not cost a second pairing.
func TestARepeatOfAKnownShareIsFree(t *testing.T) {
	shares, seed := fixture(t)
	sess := session.New(seed, shares[0].Commits, quorum, operators)

	if _, err := sess.Add(partial(shares[0], seed)); err != nil {
		t.Fatal(err)
	}
	before := sess.Verifications()
	for i := 0; i < 20; i++ {
		if _, err := sess.Add(partial(shares[0], seed)); err != nil {
			t.Fatal(err)
		}
	}
	if sess.Verifications() != before {
		t.Fatal("repeats of a known share bought further verifications")
	}
}

// / One operator flooding conflicting partials for its own index must not be
// / able to buy more than one verification with them.
func TestAFloodOfConflictingPartialsCostsOneVerification(t *testing.T) {
	shares, seed := fixture(t)
	sess := session.New(seed, shares[0].Commits, quorum, operators)

	if _, err := sess.Add(partial(shares[0], seed)); err != nil {
		t.Fatal(err)
	}
	before := sess.Verifications()

	for i := 1; i < 20; i++ {
		// never share 0 itself, or the "conflict" would be the real signature
		other := shares[1+i%(operators-1)]
		bogus := threshold.Partial{Index: shares[0].Index, Sig: blsvrf.Sign(other.Secret, seed)}
		if _, err := sess.Add(bogus); err == nil {
			t.Fatal("a conflicting partial was accepted")
		}
	}

	if spent := sess.Verifications() - before; spent > 1 {
		t.Fatalf("19 conflicting partials bought %d verifications", spent)
	}
	if _, found := sess.Equivocation(); !found {
		t.Fatal("the conflict was not recorded as evidence")
	}
}

// / Garbage for an index nobody has claimed yet still costs one verification —
// / that is unavoidable — but only one per index, so the whole request is bounded.
func TestTotalVerificationsAreBoundedByTheGroupSize(t *testing.T) {
	shares, seed := fixture(t)
	sess := session.New(seed, shares[0].Commits, quorum, operators)

	for round := 0; round < 5; round++ {
		for i := 0; i < operators; i++ {
			bogus := threshold.Partial{
				Index: uint32(i),
				Sig:   blsvrf.Sign(shares[(i+1)%operators].Secret, seed),
			}
			_, _ = sess.Add(bogus)
		}
	}

	if sess.Verifications() > operators {
		t.Fatalf("%d verifications for a group of %d", sess.Verifications(), operators)
	}
}
