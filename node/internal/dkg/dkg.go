// Package dkg runs the distributed key generation that gives the group its key.
//
// No single machine ever holds the group secret: each operator ends up with a
// share, and the secret exists only as a mathematical fact about `t` of them.
// The protocol itself is drand/kyber's Pedersen DKG — nothing here reimplements
// any of it.
//
// The DKG runs over G2, so the commitments (and therefore the group public key)
// are G2 points, which is what VRFVerifier takes. Signing happens in G1 with the
// same scalar shares: both groups share the scalar field Fr.
package dkg

import (
	"fmt"

	"github.com/drand/kyber"
	"github.com/drand/kyber/pairing/bn254"
	kdkg "github.com/drand/kyber/share/dkg"
	"github.com/drand/kyber/sign"
	"github.com/drand/kyber/util/random"
)

// Member is an operator's identity in the ceremony. In production the private
// half lives only on that operator's machine.
type Member struct {
	Index    uint32
	Longterm kyber.Scalar
	Public   kyber.Point
}

// Share is what one operator keeps after the ceremony.
type Share struct {
	Member
	// Secret is this operator's share of the group secret. Never leaves the node.
	Secret kyber.Scalar
	// GroupPublic is the key deployed into VRFVerifier. Identical for everyone.
	GroupPublic kyber.Point
	// Commits are the public polynomial coefficients, needed to reshare later.
	Commits []kyber.Point
}

func suite() *bn254.Suite {
	return bn254.NewSuiteG2()
}

// Suite is the group the ceremony runs in: G2, so that the commitments — and
// therefore the group public key — are the G2 points VRFVerifier takes.
func Suite() *bn254.Suite { return suite() }

// Nodes converts members into the form kyber's DKG expects.
func Nodes(members []Member) []kdkg.Node { return toNodes(members) }

// Scheme is the signature scheme that authenticates ceremony packets.
func Scheme() sign.Scheme { return scheme(suite()) }

// NewMember mints a fresh operator identity.
func NewMember(index uint32) Member {
	s := suite()
	longterm := s.G2().Scalar().Pick(random.New())
	return Member{Index: index, Longterm: longterm, Public: s.G2().Point().Mul(longterm, nil)}
}

// Members returns the identities behind a set of shares, so a rotation can be
// expressed as "this list, minus that one, plus this newcomer".
func Members(shares []Share) []Member {
	out := make([]Member, len(shares))
	for i, s := range shares {
		out[i] = s.Member
	}
	return out
}

// RunLocal performs the whole ceremony in one process.
//
// This is for local development, the three-node debug setup and the tests. In
// production the same kyber protocol runs across the network, one participant
// per machine, and the whole point is that nobody sees every share at once —
// which is exactly what this function does see.
func RunLocal(n, t int, epoch uint64) ([]Share, error) {
	if t < 1 || t > n {
		return nil, fmt.Errorf("dkg: bad threshold %d of %d", t, n)
	}
	members := make([]Member, n)
	for i := range members {
		members[i] = NewMember(uint32(i))
	}

	s := suite()
	nodes := toNodes(members)
	nonce, err := SessionNonce(epoch, members)
	if err != nil {
		return nil, err
	}
	configs := make([]*kdkg.Config, n)
	for i := range members {
		configs[i] = &kdkg.Config{
			Suite:     s,
			Longterm:  members[i].Longterm,
			NewNodes:  nodes,
			Threshold: t,
			Nonce:     nonce,
			Auth:      scheme(s),
		}
	}
	return collect(configs, members, alwaysTrue(n), alwaysTrue(n))
}

// ResharLocal redistributes the same group secret onto `members`, which may add,
// drop or keep operators.
//
// The group public key does not change. That is what makes rotation cheap: the
// key already deployed in VRFVerifier stays valid, and no integration notices
// that the operator set moved underneath it.
func ResharLocal(old []Share, members []Member, t int, epoch uint64) ([]Share, error) {
	if len(old) == 0 {
		return nil, fmt.Errorf("dkg: nothing to reshare")
	}
	if t < 1 || t > len(members) {
		return nil, fmt.Errorf("dkg: bad threshold %d of %d", t, len(members))
	}

	s := suite()
	oldNodes := toNodes(Members(old))
	newNodes := toNodes(members)

	// Everyone who has a share deals it out; everyone in the new set receives.
	// A newcomer only receives, a departing operator only deals.
	participants := union(old, members)
	nonce, err := SessionNonce(epoch, participants)
	if err != nil {
		return nil, err
	}
	configs := make([]*kdkg.Config, len(participants))
	issues := make([]bool, len(participants))
	receives := make([]bool, len(participants))

	for i, p := range participants {
		cfg := &kdkg.Config{
			Suite:        s,
			Longterm:     p.Longterm,
			OldNodes:     oldNodes,
			NewNodes:     newNodes,
			Threshold:    t,
			OldThreshold: thresholdOf(old),
			Nonce:        nonce,
			PublicCoeffs: old[0].Commits,
			Auth:         scheme(s),
		}
		if sh, ok := findShare(old, p.Index); ok {
			cfg.Share = &kdkg.DistKeyShare{Commits: sh.Commits, Share: priShare(sh)}
			issues[i] = true
		}
		receives[i] = contains(members, p.Index)
		configs[i] = cfg
	}

	return collect(configs, participants, issues, receives)
}

func collect(configs []*kdkg.Config, members []Member, issues, receives []bool) ([]Share, error) {
	handlers := make([]*kdkg.DistKeyGenerator, len(configs))
	for i, c := range configs {
		h, err := kdkg.NewDistKeyHandler(c)
		if err != nil {
			return nil, fmt.Errorf("dkg: handler %d: %w", i, err)
		}
		handlers[i] = h
	}

	var deals []*kdkg.DealBundle
	for i, h := range handlers {
		if !issues[i] {
			continue
		}
		d, err := h.Deals()
		if err != nil {
			return nil, fmt.Errorf("dkg: deals from %d: %w", i, err)
		}
		deals = append(deals, d)
	}

	var responses []*kdkg.ResponseBundle
	for i, h := range handlers {
		if !receives[i] {
			continue
		}
		r, err := h.ProcessDeals(deals)
		if err != nil {
			return nil, fmt.Errorf("dkg: %d processing deals: %w", i, err)
		}
		if r != nil {
			responses = append(responses, r)
		}
	}

	shares := make([]Share, 0, len(members))
	for i, h := range handlers {
		if !receives[i] {
			continue
		}
		res, justifications, err := h.ProcessResponses(responses)
		if err != nil {
			return nil, fmt.Errorf("dkg: %d processing responses: %w", i, err)
		}
		if res == nil {
			return nil, fmt.Errorf(
				"dkg: unresolved complaints at participant %d (justifications pending: %v)",
				i, justifications != nil,
			)
		}
		shares = append(shares, Share{
			Member:      members[i],
			Secret:      res.Key.Share.V,
			GroupPublic: res.Key.Public(),
			Commits:     res.Key.Commits,
		})
	}
	return shares, nil
}

func toNodes(members []Member) []kdkg.Node {
	nodes := make([]kdkg.Node, len(members))
	for i, m := range members {
		nodes[i] = kdkg.Node{Index: m.Index, Public: m.Public}
	}
	return nodes
}

// union lists every machine that takes part: old share holders first, then any
// newcomer that was not among them.
func union(old []Share, members []Member) []Member {
	out := Members(old)
	for _, m := range members {
		if !containsMember(out, m.Index) {
			out = append(out, m)
		}
	}
	return out
}

func containsMember(members []Member, index uint32) bool {
	for _, m := range members {
		if m.Index == index {
			return true
		}
	}
	return false
}

func contains(members []Member, index uint32) bool { return containsMember(members, index) }

func findShare(shares []Share, index uint32) (Share, bool) {
	for _, s := range shares {
		if s.Index == index {
			return s, true
		}
	}
	return Share{}, false
}

func thresholdOf(shares []Share) int { return len(shares[0].Commits) }

func alwaysTrue(n int) []bool {
	out := make([]bool, n)
	for i := range out {
		out[i] = true
	}
	return out
}
