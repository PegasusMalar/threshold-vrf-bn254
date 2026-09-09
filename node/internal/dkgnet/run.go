package dkgnet

import (
	"context"
	"fmt"
	"time"

	"github.com/drand/kyber"
	kdkg "github.com/drand/kyber/share/dkg"

	"threshold-vrf/node/internal/dkg"
)

// Params is everything one participant needs to take part in a ceremony.
//
// Every participant must supply the same member list, threshold and epoch, or
// the session nonce will differ and their bundles will be rejected as replays
// from another run. That is the intended behaviour: disagreement about who is
// in the group should stop a ceremony, not silently produce two of them.
type Params struct {
	Self      dkg.Member
	Members   []dkg.Member
	Threshold int
	Epoch     uint64

	// PhasePeriod is how long to wait for stragglers in each round. Generous is
	// correct here: a ceremony happens once a month and is supervised.
	PhasePeriod time.Duration

	// Set these for a resharing and leave them empty for a first ceremony.
	//
	// OldMembers, OldThreshold and OldCommits are public and must be identical
	// for everyone taking part — a newcomer with no old share still needs them,
	// both to check the deals it receives and to arrive at the same session
	// nonce as the dealers. Getting that wrong is silent: bundles simply look
	// like replays from another run and the newcomer ends up with nothing.
	Old          *dkg.Share
	OldMembers   []dkg.Member
	OldThreshold int
	OldCommits   []kyber.Point
}

// Run takes part in one ceremony and returns this participant's share.
//
// The protocol is drand/kyber's; this only supplies the transport and the
// configuration. Unlike dkg.RunLocal, no machine here ever holds more than its
// own share — which is the whole reason the network version exists.
func Run(ctx context.Context, p Params, board *Board) (dkg.Share, error) {
	var out dkg.Share

	if p.Threshold < 1 || p.Threshold > len(p.Members) {
		return out, fmt.Errorf("dkgnet: bad threshold %d of %d", p.Threshold, len(p.Members))
	}
	if p.PhasePeriod <= 0 {
		p.PhasePeriod = 10 * time.Second
	}

	cfg := &kdkg.Config{
		Suite:     dkg.Suite(),
		Longterm:  p.Self.Longterm,
		NewNodes:  dkg.Nodes(p.Members),
		Threshold: p.Threshold,
		Auth:      dkg.Scheme(),
	}

	nonceMembers := p.Members
	if len(p.OldMembers) > 0 {
		commits := p.OldCommits
		if commits == nil && p.Old != nil {
			commits = p.Old.Commits
		}
		cfg.OldNodes = dkg.Nodes(p.OldMembers)
		cfg.OldThreshold = p.OldThreshold
		cfg.PublicCoeffs = commits
		// Only a participant that actually holds an old share deals one out.
		// A newcomer takes part with everything above, minus this.
		if p.Old != nil {
			cfg.Share = &kdkg.DistKeyShare{Commits: commits, Share: p.Old.PriShare()}
		}
		nonceMembers = union(p.OldMembers, p.Members)
	}

	nonce, err := dkg.SessionNonce(p.Epoch, nonceMembers)
	if err != nil {
		return out, err
	}
	cfg.Nonce = nonce

	phaser := kdkg.NewTimePhaser(p.PhasePeriod)
	protocol, err := kdkg.NewProtocol(cfg, board, phaser, false)
	if err != nil {
		return out, fmt.Errorf("dkgnet: %w", err)
	}
	go phaser.Start()

	select {
	case <-ctx.Done():
		return out, ctx.Err()
	case result := <-protocol.WaitEnd():
		if result.Error != nil {
			return out, fmt.Errorf("dkgnet: ceremony failed: %w", result.Error)
		}
		return dkg.Share{
			Member:      p.Self,
			Secret:      result.Result.Key.Share.V,
			GroupPublic: result.Result.Key.Public(),
			Commits:     result.Result.Key.Commits,
		}, nil
	}
}

func union(old, next []dkg.Member) []dkg.Member {
	out := append([]dkg.Member(nil), old...)
	for _, m := range next {
		found := false
		for _, o := range out {
			if o.Index == m.Index {
				found = true
				break
			}
		}
		if !found {
			out = append(out, m)
		}
	}
	return out
}
