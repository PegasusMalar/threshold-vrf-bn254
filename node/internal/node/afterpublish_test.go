package node_test

import (
	"context"
	"math/big"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"threshold-vrf/node/internal/chain"
	"threshold-vrf/node/internal/dkg"
	"threshold-vrf/node/internal/mesh"
	"threshold-vrf/node/internal/node"
)

// Runs a full group and returns how many times the publish hook fired.
func publishHookFirings(t *testing.T, requestID int64, closed bool) int32 {
	t.Helper()
	ctx := context.Background()
	shares, err := dkg.RunLocal(operators, quorum, 1)
	if err != nil {
		t.Fatal(err)
	}
	var seed [32]byte
	seed[31] = 9
	shared := &fakeChain{seed: seed, closed: closed}

	var fired atomic.Int32
	nodes := make([]*node.Node, operators)
	servers := make([]*httptest.Server, operators)
	for i := range nodes {
		nodes[i] = node.New(node.Config{
			Share:        shares[i],
			Threshold:    quorum,
			Operators:    operators,
			Chain:        shared,
			AfterPublish: func() { fired.Add(1) },
		})
		servers[i] = httptest.NewServer(mesh.NewServer(nodes[i].OnPeerShare, nil))
		defer servers[i].Close()
	}
	for i := range nodes {
		peers := make([]string, 0, operators-1)
		for j := range servers {
			if i != j {
				peers = append(peers, servers[j].URL)
			}
		}
		nodes[i].SetPeers(mesh.NewClient(peers, 2*time.Second))
	}

	var wg sync.WaitGroup
	for i := range nodes {
		wg.Add(1)
		go func(n *node.Node) {
			defer wg.Done()
			n.OnRequest(ctx, chain.Request{ID: big.NewInt(requestID), Seed: seed, NumWords: 1})
		}(nodes[i])
	}
	wg.Wait()
	time.Sleep(300 * time.Millisecond)
	return fired.Load()
}

// Publishing is the only moment an operator's balance falls and its earnings
// rise, and the node knows about it before anyone else. Leaving that to the
// next scheduled balance check keeps the operator below its floor — and so
// unable to publish again — for as long as that timer runs, while the group
// walks the rotation looking for somebody solvent. On a thinly funded fleet
// that showed as a median of 9.75s against 3.93s for the same request when
// several operators had room.
func TestPublishingPromptsABalanceCheck(t *testing.T) {
	if got := publishHookFirings(t, 11, false); got == 0 {
		t.Fatal("a published fulfilment did not prompt a balance check")
	}
}

// A race this node lost costs it no gas and earns it nothing, so there is
// nothing for a balance check to discover and no reason to spend the calls.
func TestALostRaceDoesNotPromptABalanceCheck(t *testing.T) {
	if got := publishHookFirings(t, 12, true); got != 0 {
		t.Fatalf("a request nobody could publish prompted %d balance checks", got)
	}
}
