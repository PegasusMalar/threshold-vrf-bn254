package dkg_test

import (
	"testing"

	"threshold-vrf/node/internal/blsvrf"
	"threshold-vrf/node/internal/dkg"
	"threshold-vrf/node/internal/threshold"
)

const (
	operators = 9
	quorum    = 5
)

func seed(b byte) [32]byte {
	var s [32]byte
	s[31] = b
	return s
}

func signWith(shares []dkg.Share, indices []int, s [32]byte) []threshold.Partial {
	partials := make([]threshold.Partial, 0, len(indices))
	for _, i := range indices {
		partials = append(partials, threshold.Partial{
			Index: shares[i].Index,
			Sig:   blsvrf.Sign(shares[i].Secret, s),
		})
	}
	return partials
}

func TestEveryParticipantEndsUpWithTheSameGroupKey(t *testing.T) {
	shares, err := dkg.RunLocal(operators, quorum, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(shares) != operators {
		t.Fatalf("expected %d shares, got %d", operators, len(shares))
	}

	first, err := blsvrf.SerializeG2(shares[0].GroupPublic)
	if err != nil {
		t.Fatal(err)
	}
	for i, s := range shares {
		got, err := blsvrf.SerializeG2(s.GroupPublic)
		if err != nil {
			t.Fatal(err)
		}
		for j := range got {
			if got[j].Cmp(first[j]) != 0 {
				t.Fatalf("participant %d disagrees about the group key", i)
			}
		}
	}
}

// The property the whole design rests on: which five operators happen to sign
// cannot change the result.
func TestAnyQuorumProducesTheSameSignature(t *testing.T) {
	shares, err := dkg.RunLocal(operators, quorum, 1)
	if err != nil {
		t.Fatal(err)
	}
	s := seed(1)

	a, err := threshold.Aggregate(signWith(shares, []int{0, 1, 2, 3, 4}, s), quorum, operators)
	if err != nil {
		t.Fatal(err)
	}
	b, err := threshold.Aggregate(signWith(shares, []int{4, 5, 6, 7, 8}, s), quorum, operators)
	if err != nil {
		t.Fatal(err)
	}

	if !a.Equal(b) {
		t.Fatal("two quorums produced different signatures")
	}
	if !blsvrf.Verify(shares[0].GroupPublic, s, a) {
		t.Fatal("aggregated signature does not verify against the group key")
	}
}

func TestBelowThresholdNoValidSignatureComesOut(t *testing.T) {
	shares, err := dkg.RunLocal(operators, quorum, 1)
	if err != nil {
		t.Fatal(err)
	}
	s := seed(2)

	partials := signWith(shares, []int{0, 1, 2, 3}, s)
	sig, err := threshold.Aggregate(partials, quorum, operators)
	if err == nil && blsvrf.Verify(shares[0].GroupPublic, s, sig) {
		t.Fatal("four of nine produced a valid signature")
	}
}

// A single dishonest partial must not be able to steer the outcome — it can
// only spoil it, which verification then catches.
func TestOneCorruptedPartialInvalidatesTheAggregate(t *testing.T) {
	shares, err := dkg.RunLocal(operators, quorum, 1)
	if err != nil {
		t.Fatal(err)
	}
	s := seed(3)

	partials := signWith(shares, []int{0, 1, 2, 3, 4}, s)
	partials[2].Sig = blsvrf.Sign(shares[7].Secret, s) // wrong share, right index

	sig, err := threshold.Aggregate(partials, quorum, operators)
	if err == nil && blsvrf.Verify(shares[0].GroupPublic, s, sig) {
		t.Fatal("a forged partial signature was absorbed into a valid aggregate")
	}
}

// TZ open question 4. If resharing changed the group key, every integration
// would break on every rotation and the verifier would need an epoch registry.
func TestResharingKeepsTheGroupPublicKeyUnchanged(t *testing.T) {
	before, err := dkg.RunLocal(operators, quorum, 1)
	if err != nil {
		t.Fatal(err)
	}
	after, err := dkg.ResharLocal(before, dkg.Members(before), quorum, 2)
	if err != nil {
		t.Fatal(err)
	}

	oldKey, err := blsvrf.SerializeG2(before[0].GroupPublic)
	if err != nil {
		t.Fatal(err)
	}
	newKey, err := blsvrf.SerializeG2(after[0].GroupPublic)
	if err != nil {
		t.Fatal(err)
	}
	for i := range oldKey {
		if oldKey[i].Cmp(newKey[i]) != 0 {
			t.Fatalf("resharing changed the group public key at limb %d", i)
		}
	}

	// and the new shares really are new: old and new secrets differ, yet both
	// sets sign to the same thing
	s := seed(4)
	sigBefore, err := threshold.Aggregate(signWith(before, []int{0, 1, 2, 3, 4}, s), quorum, operators)
	if err != nil {
		t.Fatal(err)
	}
	sigAfter, err := threshold.Aggregate(signWith(after, []int{4, 5, 6, 7, 8}, s), quorum, operators)
	if err != nil {
		t.Fatal(err)
	}
	if before[0].Secret.Equal(after[0].Secret) {
		t.Fatal("resharing did not actually refresh the shares")
	}
	if !sigBefore.Equal(sigAfter) {
		t.Fatal("shares from before and after resharing disagree")
	}
}

// The rotation window from TZ section 8.3: one operator leaves, a newcomer
// takes their place, the group key survives and the departing operator's share
// is worthless afterwards.
func TestRotationCanReplaceAnOperatorAndKeepTheKey(t *testing.T) {
	before, err := dkg.RunLocal(operators, quorum, 1)
	if err != nil {
		t.Fatal(err)
	}

	members := append(dkg.Members(before)[1:], dkg.NewMember(uint32(operators)))
	after, err := dkg.ResharLocal(before, members, quorum, 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(after) != operators {
		t.Fatalf("expected %d shares after rotation, got %d", operators, len(after))
	}

	oldKey, err := blsvrf.SerializeG2(before[0].GroupPublic)
	if err != nil {
		t.Fatal(err)
	}
	newKey, err := blsvrf.SerializeG2(after[0].GroupPublic)
	if err != nil {
		t.Fatal(err)
	}
	for i := range oldKey {
		if oldKey[i].Cmp(newKey[i]) != 0 {
			t.Fatal("replacing an operator changed the group public key")
		}
	}

	// the new set, including the newcomer, signs to the same value as before
	s := seed(5)
	sigNew, err := threshold.Aggregate(signWith(after, []int{4, 5, 6, 7, 8}, s), quorum, operators)
	if err != nil {
		t.Fatal(err)
	}
	if !blsvrf.Verify(before[0].GroupPublic, s, sigNew) {
		t.Fatal("the rotated group cannot sign for the deployed key")
	}

	// the operator that left cannot rejoin a quorum with its stale share
	stale := append(signWith(before, []int{0}, s), signWith(after, []int{4, 5, 6, 7}, s)...)
	if sig, err := threshold.Aggregate(stale, quorum, operators); err == nil &&
		blsvrf.Verify(before[0].GroupPublic, s, sig) {
		t.Fatal("a share from before the rotation still works")
	}
}
