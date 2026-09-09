package blsvrf_test

import (
	"encoding/json"
	"math/big"
	"os"
	"testing"

	"threshold-vrf/node/internal/blsvrf"
)

// vectors mirrors test/vectors/bls.json, which is produced by the TypeScript
// stack (mcl-wasm) and consumed by the Solidity tests. If Go agrees with it,
// all three implementations agree.
type vectors struct {
	DST            string   `json:"dst"`
	GroupSecretKey string   `json:"groupSecretKey"`
	GroupPubKey    []string `json:"groupPubKey"`
	Message        string   `json:"message"`
	MessagePoint   []string `json:"messagePoint"`
	Signature      []string `json:"signature"`
}

func load(t *testing.T) vectors {
	t.Helper()
	raw, err := os.ReadFile("../../../test/vectors/bls.json")
	if err != nil {
		t.Fatalf("read vectors: %v", err)
	}
	var v vectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("parse vectors: %v", err)
	}
	return v
}

func hexToInt(t *testing.T, s string) *big.Int {
	t.Helper()
	n, ok := new(big.Int).SetString(s[2:], 16)
	if !ok {
		t.Fatalf("bad hex %q", s)
	}
	return n
}

func seedOf(t *testing.T, v vectors) [32]byte {
	t.Helper()
	var seed [32]byte
	hexToInt(t, v.Message).FillBytes(seed[:])
	return seed
}

// The DST is part of the on-chain interface. A mismatch here means every
// signature this node ever produces is rejected.
func TestDomainSeparationTagMatchesTheContract(t *testing.T) {
	v := load(t)
	if blsvrf.DST != v.DST {
		t.Fatalf("DST mismatch:\n go: %s\n ts: %s", blsvrf.DST, v.DST)
	}
}

func TestHashToPointMatchesTheOtherImplementations(t *testing.T) {
	v := load(t)
	point, err := blsvrf.SerializeG1(blsvrf.HashSeedToPoint(seedOf(t, v)))
	if err != nil {
		t.Fatal(err)
	}
	for i, want := range v.MessagePoint {
		if point[i].Cmp(hexToInt(t, want)) != 0 {
			t.Fatalf("hashToPoint[%d]:\n got  %s\n want %s", i, point[i].Text(16), want[2:])
		}
	}
}

func TestSignReproducesTheReferenceSignature(t *testing.T) {
	v := load(t)
	secret := blsvrf.ScalarFromBytes(hexToInt(t, v.GroupSecretKey).FillBytes(make([]byte, 32)))

	sig, err := blsvrf.SerializeG1(blsvrf.Sign(secret, seedOf(t, v)))
	if err != nil {
		t.Fatal(err)
	}
	for i, want := range v.Signature {
		if sig[i].Cmp(hexToInt(t, want)) != 0 {
			t.Fatalf("signature[%d]:\n got  %s\n want %s", i, sig[i].Text(16), want[2:])
		}
	}
}

func TestPublicKeySerializationMatchesTheEvmOrdering(t *testing.T) {
	v := load(t)
	secret := blsvrf.ScalarFromBytes(hexToInt(t, v.GroupSecretKey).FillBytes(make([]byte, 32)))

	pk, err := blsvrf.SerializeG2(blsvrf.PublicKey(secret))
	if err != nil {
		t.Fatal(err)
	}
	for i, want := range v.GroupPubKey {
		if pk[i].Cmp(hexToInt(t, want)) != 0 {
			t.Fatalf("pubKey[%d]:\n got  %s\n want %s", i, pk[i].Text(16), want[2:])
		}
	}
}

func TestSignatureBytesAreExactlyWhatTheCoordinatorExpects(t *testing.T) {
	v := load(t)
	secret := blsvrf.ScalarFromBytes(hexToInt(t, v.GroupSecretKey).FillBytes(make([]byte, 32)))

	raw, err := blsvrf.SignatureBytes(blsvrf.Sign(secret, seedOf(t, v)))
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) != 64 {
		t.Fatalf("signature must be 64 bytes, got %d", len(raw))
	}

	want := make([]byte, 0, 64)
	for _, s := range v.Signature {
		want = append(want, hexToInt(t, s).FillBytes(make([]byte, 32))...)
	}
	if string(raw) != string(want) {
		t.Fatalf("serialised signature does not match the vector")
	}
}

func TestVerifyAcceptsAValidSignatureAndRejectsEverythingElse(t *testing.T) {
	v := load(t)
	secret := blsvrf.ScalarFromBytes(hexToInt(t, v.GroupSecretKey).FillBytes(make([]byte, 32)))
	seed := seedOf(t, v)
	pub := blsvrf.PublicKey(secret)

	if !blsvrf.Verify(pub, seed, blsvrf.Sign(secret, seed)) {
		t.Fatal("valid signature rejected")
	}

	other := blsvrf.ScalarFromBytes(hexToInt(t, "0x02").FillBytes(make([]byte, 32)))
	if blsvrf.Verify(pub, seed, blsvrf.Sign(other, seed)) {
		t.Fatal("signature from the wrong key accepted")
	}

	var otherSeed [32]byte
	otherSeed[31] = 0x42
	if blsvrf.Verify(pub, seed, blsvrf.Sign(secret, otherSeed)) {
		t.Fatal("signature for a different seed accepted")
	}
}
