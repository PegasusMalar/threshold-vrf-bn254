package blsvrf_test

import (
	"testing"

	"threshold-vrf/node/internal/blsvrf"
	"threshold-vrf/node/internal/dkg"
	"threshold-vrf/node/internal/threshold"
)

// TZ section 10.4: how long a share takes to produce and a quorum to combine.
func BenchmarkSignShare(b *testing.B) {
	shares, err := dkg.RunLocal(9, 5, 1)
	if err != nil {
		b.Fatal(err)
	}
	var seed [32]byte
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		seed[0] = byte(i)
		blsvrf.Sign(shares[0].Secret, seed)
	}
}

func BenchmarkVerifyShare(b *testing.B) {
	shares, err := dkg.RunLocal(9, 5, 1)
	if err != nil {
		b.Fatal(err)
	}
	var seed [32]byte
	sig := blsvrf.Sign(shares[3].Secret, seed)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if !blsvrf.VerifyPartial(shares[0].Commits, shares[3].Index, seed, sig) {
			b.Fatal("partial did not verify")
		}
	}
}

func BenchmarkAggregateFiveOfNine(b *testing.B) {
	shares, err := dkg.RunLocal(9, 5, 1)
	if err != nil {
		b.Fatal(err)
	}
	var seed [32]byte
	partials := make([]threshold.Partial, 0, 5)
	for i := 0; i < 5; i++ {
		partials = append(partials, threshold.Partial{
			Index: shares[i].Index, Sig: blsvrf.Sign(shares[i].Secret, seed),
		})
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := threshold.Aggregate(partials, 5, 9); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkDkgNineOfFive(b *testing.B) {
	for i := 0; i < b.N; i++ {
		if _, err := dkg.RunLocal(9, 5, uint64(i)); err != nil {
			b.Fatal(err)
		}
	}
}
