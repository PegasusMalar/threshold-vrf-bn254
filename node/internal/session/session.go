// Package session tracks one VRF request from "seed announced" to "signature
// ready to publish".
//
// Every partial signature is verified against the sender's own public key
// before it is counted. That is not politeness: an unverified partial poisons
// the aggregate silently, and the node would discover it only by paying gas for
// a transaction that reverts.
package session

import (
	"errors"
	"fmt"
	"sync"

	"github.com/drand/kyber"

	"threshold-vrf/node/internal/blsvrf"
	"threshold-vrf/node/internal/threshold"
)

// Equivocation is cryptographic evidence that one operator produced two
// different signature shares for a single seed — one of the two slashable
// offences. It is self-contained: anyone holding the DKG commitments can check
// it without trusting the reporter.
type Equivocation struct {
	Index  uint32
	Seed   [32]byte
	First  kyber.Point
	Second kyber.Point
}

// Session collects partial signatures for one seed.
type Session struct {
	seed      [32]byte
	commits   []kyber.Point
	threshold int
	operators int

	mu            sync.Mutex
	partials      map[uint32]threshold.Partial
	spent         map[uint32]bool
	equivocation  *Equivocation
	verifications int
}

// New starts a session for one request.
func New(seed [32]byte, commits []kyber.Point, thresholdT, operators int) *Session {
	return &Session{
		seed:      seed,
		commits:   commits,
		threshold: thresholdT,
		operators: operators,
		partials:  make(map[uint32]threshold.Partial, operators),
		spent:     make(map[uint32]bool, operators),
	}
}

// Add verifies a partial signature and files it.
//
// Returns false without an error when the partial was not needed — already
// known, or arriving after the threshold was met. That is the normal case, not
// a fault: every operator broadcasts to every other one.
//
// Verification is a pairing, and this is reachable from an open port, so the
// work one request can provoke is capped at one verification per operator
// index. Beyond that, a flood is answered with a map lookup.
//
// Deliberately *not* capped at the threshold: a share arriving after the quorum
// is complete is no longer needed for the signature, but it is the only
// evidence that its sender is alive, and that evidence is what the operator
// monitor is built on. Dropping it unverified would make a healthy operator
// that happens to be slow indistinguishable from one that is down.
func (s *Session) Add(p threshold.Partial) (bool, error) {
	if int(p.Index) >= s.operators {
		return false, fmt.Errorf("session: operator index %d is outside the group", p.Index)
	}
	if p.Sig == nil {
		return false, errors.New("session: nil signature")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if existing, ok := s.partials[p.Index]; ok {
		if existing.Sig.Equal(p.Sig) {
			return false, nil
		}
		// Two different points claimed for one index. Only one of them can
		// verify; the conflict is evidence, and this index has now spent its
		// verification budget.
		s.recordEquivocation(p.Index, existing.Sig, p.Sig)
		s.spent[p.Index] = true
		return false, fmt.Errorf("session: conflicting partial for operator %d", p.Index)
	}

	if s.spent[p.Index] {
		return false, fmt.Errorf("session: operator %d already spent its attempt", p.Index)
	}
	s.spent[p.Index] = true

	s.verifications++
	if !blsvrf.VerifyPartial(s.commits, p.Index, s.seed, p.Sig) {
		return false, fmt.Errorf("session: partial from operator %d does not verify", p.Index)
	}

	s.partials[p.Index] = p
	return true, nil
}

// Verifications is how many pairings this session has paid for. Exposed so the
// bound can be asserted rather than assumed.
func (s *Session) Verifications() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.verifications
}

func (s *Session) recordEquivocation(index uint32, first, second kyber.Point) {
	if s.equivocation != nil {
		return
	}
	s.equivocation = &Equivocation{Index: index, Seed: s.seed, First: first, Second: second}
}

// Collected is how many distinct verified partials are in hand.
func (s *Session) Collected() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.partials)
}

// Ready reports whether the threshold has been reached.
func (s *Session) Ready() bool { return s.Collected() >= s.threshold }

// Signature aggregates the collected partials into the group signature, encoded
// exactly as VRFCoordinator.fulfillRandomWords takes it.
func (s *Session) Signature() ([]byte, error) {
	s.mu.Lock()
	partials := make([]threshold.Partial, 0, len(s.partials))
	for _, p := range s.partials {
		partials = append(partials, p)
	}
	s.mu.Unlock()

	if len(partials) < s.threshold {
		return nil, fmt.Errorf("session: %d of %d partials", len(partials), s.threshold)
	}

	sig, err := threshold.Aggregate(partials, s.threshold, s.operators)
	if err != nil {
		return nil, err
	}
	return blsvrf.SignatureBytes(sig)
}

// Equivocation returns evidence against a double-signing operator, if any.
func (s *Session) Equivocation() (Equivocation, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.equivocation == nil {
		return Equivocation{}, false
	}
	return *s.equivocation, true
}

// Seed is the value being signed.
func (s *Session) Seed() [32]byte { return s.seed }
