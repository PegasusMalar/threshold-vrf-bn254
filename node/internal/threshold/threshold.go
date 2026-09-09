// Package threshold turns partial signatures into the one group signature.
package threshold

import (
	"errors"

	"github.com/drand/kyber"
	"github.com/drand/kyber/share"

	"threshold-vrf/node/internal/blsvrf"
)

// Partial is one operator's signature share over a seed.
type Partial struct {
	Index uint32
	Sig   kyber.Point
}

// Aggregate interpolates partial signatures at zero.
//
// Given at least `t` honest partials the result is exactly the group's BLS
// signature — the same one, whichever quorum produced it. Fewer partials, or
// any corrupted one, yields a point that simply fails verification; there is no
// input that steers the result somewhere chosen.
func Aggregate(partials []Partial, t, n int) (kyber.Point, error) {
	if len(partials) < t {
		return nil, errors.New("threshold: not enough partial signatures")
	}

	pubShares := make([]*share.PubShare, 0, len(partials))
	seen := make(map[uint32]bool, len(partials))
	for _, p := range partials {
		if seen[p.Index] {
			return nil, errors.New("threshold: duplicate operator index")
		}
		seen[p.Index] = true
		pubShares = append(pubShares, &share.PubShare{I: int(p.Index), V: p.Sig})
	}

	return share.RecoverCommit(blsvrf.Suite().G1(), pubShares, t, n)
}
