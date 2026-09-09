package dkg

import (
	"encoding/binary"
	"sort"

	"golang.org/x/crypto/sha3"
)

// SessionNonce binds a ceremony to one particular run.
//
// Without it, deals from an earlier DKG could be replayed into a later one.
// Every participant must arrive at the same value without talking to anyone, so
// it is derived from what they all already know: the epoch number and the exact
// set of identities taking part.
func SessionNonce(epoch uint64, members []Member) ([]byte, error) {
	encoded := make([][]byte, 0, len(members))
	for _, m := range members {
		raw, err := m.Public.MarshalBinary()
		if err != nil {
			return nil, err
		}
		idx := make([]byte, 4)
		binary.BigEndian.PutUint32(idx, m.Index)
		encoded = append(encoded, append(idx, raw...))
	}
	// order must not depend on who is asking
	sort.Slice(encoded, func(i, j int) bool { return string(encoded[i]) < string(encoded[j]) })

	h := sha3.NewLegacyKeccak256()
	var epochBytes [8]byte
	binary.BigEndian.PutUint64(epochBytes[:], epoch)
	h.Write([]byte("RH-VRF-DKG-V1"))
	h.Write(epochBytes[:])
	for _, e := range encoded {
		h.Write(e)
	}
	return h.Sum(nil), nil
}
