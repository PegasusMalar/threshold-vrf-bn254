package dkgnet_test

import (
	"context"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"threshold-vrf/node/internal/blsvrf"
	"threshold-vrf/node/internal/dkg"
	"threshold-vrf/node/internal/dkgnet"
	"threshold-vrf/node/internal/threshold"
)

const (
	participants = 5
	quorum       = 3
)

// The ceremony over real HTTP, one participant per server. This is the version
// that matters: unlike dkg.RunLocal, no process here ever holds more than its
// own share.
func TestNetworkedCeremonyProducesAWorkingGroupKey(t *testing.T) {
	shares := runCeremony(t, participants, quorum, 1, nil, nil)

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

	var seed [32]byte
	seed[31] = 3
	partials := make([]threshold.Partial, 0, quorum)
	for i := 0; i < quorum; i++ {
		partials = append(partials, threshold.Partial{
			Index: shares[i].Index, Sig: blsvrf.Sign(shares[i].Secret, seed),
		})
	}
	sig, err := threshold.Aggregate(partials, quorum, participants)
	if err != nil {
		t.Fatal(err)
	}
	if !blsvrf.Verify(shares[0].GroupPublic, seed, sig) {
		t.Fatal("a quorum of the networked ceremony cannot sign for its own key")
	}
}

// Resharing over the network, with the operator set changing: the deployed key
// must survive it, which is what makes a rotation window cheap.
func TestNetworkedResharingKeepsTheGroupKey(t *testing.T) {
	before := runCeremony(t, participants, quorum, 1, nil, nil)

	members := append(dkg.Members(before)[1:], dkg.NewMember(uint32(participants)))
	after := runCeremony(t, participants, quorum, 2, before, members)

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
			t.Fatal("a networked rotation changed the group public key")
		}
	}

	var seed [32]byte
	seed[31] = 8
	partials := make([]threshold.Partial, 0, quorum)
	for i := len(after) - quorum; i < len(after); i++ {
		partials = append(partials, threshold.Partial{
			Index: after[i].Index, Sig: blsvrf.Sign(after[i].Secret, seed),
		})
	}
	sig, err := threshold.Aggregate(partials, quorum, participants)
	if err != nil {
		t.Fatal(err)
	}
	if !blsvrf.Verify(before[0].GroupPublic, seed, sig) {
		t.Fatal("the rotated group cannot sign for the key that is already deployed")
	}
}

// runCeremony stands up one HTTP server per participant and runs them all at
// once, which is as close to the real thing as a single test process gets.
func runCeremony(t *testing.T, n, threshold_ int, epoch uint64, old []dkg.Share, members []dkg.Member) []dkg.Share {
	t.Helper()

	if members == nil {
		members = make([]dkg.Member, n)
		for i := range members {
			members[i] = dkg.NewMember(uint32(i))
		}
	}
	// everyone who deals or receives takes part
	taking := members
	if old != nil {
		taking = nil
		seen := map[uint32]bool{}
		for _, s := range old {
			taking = append(taking, s.Member)
			seen[s.Index] = true
		}
		for _, m := range members {
			if !seen[m.Index] {
				taking = append(taking, m)
			}
		}
	}

	boards := make([]*dkgnet.Board, len(taking))
	servers := make([]*httptest.Server, len(taking))
	urls := make([]string, len(taking))
	for i := range taking {
		boards[i] = dkgnet.NewBoard(nil, 4*len(taking), nil)
		servers[i] = httptest.NewServer(boards[i].Handler())
		urls[i] = servers[i].URL
		t.Cleanup(servers[i].Close)
	}
	for i := range boards {
		peers := make([]string, 0, len(urls)-1)
		for j, u := range urls {
			if i != j {
				peers = append(peers, u)
			}
		}
		boards[i].SetPeers(peers)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	results := make([]dkg.Share, len(taking))
	errs := make([]error, len(taking))
	var wg sync.WaitGroup
	for i := range taking {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			p := dkgnet.Params{
				Self:        taking[i],
				Members:     members,
				Threshold:   threshold_,
				Epoch:       epoch,
				PhasePeriod: 500 * time.Millisecond,
			}
			if old != nil {
				p.OldMembers = dkg.Members(old)
				p.OldThreshold = threshold_
				p.OldCommits = old[0].Commits // public, same for everyone
				for k := range old {
					if old[k].Index == taking[i].Index {
						p.Old = &old[k]
					}
				}
			}
			results[i], errs[i] = dkgnet.Run(ctx, p, boards[i])
		}(i)
	}
	wg.Wait()

	out := make([]dkg.Share, 0, len(members))
	for i := range taking {
		if errs[i] != nil {
			// a departing participant only deals and gets no share back
			if old != nil && !inMembers(members, taking[i].Index) {
				continue
			}
			t.Fatalf("participant %d: %v", taking[i].Index, errs[i])
		}
		out = append(out, results[i])
	}
	if len(out) != len(members) {
		t.Fatalf("expected %d shares, got %d", len(members), len(out))
	}
	return out
}

func inMembers(members []dkg.Member, index uint32) bool {
	for _, m := range members {
		if m.Index == index {
			return true
		}
	}
	return false
}
