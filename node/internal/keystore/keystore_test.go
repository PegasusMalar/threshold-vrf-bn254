package keystore_test

import (
	"os"
	"path/filepath"
	"testing"

	"threshold-vrf/node/internal/blsvrf"
	"threshold-vrf/node/internal/dkg"
	"threshold-vrf/node/internal/keystore"
)

func TestAShareSurvivesASaveAndLoadIntact(t *testing.T) {
	shares, err := dkg.RunLocal(3, 2, 1)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "share.json")

	if err := keystore.Save(path, "correct horse", shares[1]); err != nil {
		t.Fatal(err)
	}
	loaded, err := keystore.Load(path, "correct horse")
	if err != nil {
		t.Fatal(err)
	}

	if loaded.Index != shares[1].Index {
		t.Fatal("index changed")
	}
	if !loaded.Secret.Equal(shares[1].Secret) {
		t.Fatal("secret changed")
	}
	if !loaded.GroupPublic.Equal(shares[1].GroupPublic) {
		t.Fatal("group key changed")
	}
	if len(loaded.Commits) != len(shares[1].Commits) {
		t.Fatal("commitments lost")
	}

	// and it is still a working share
	var seed [32]byte
	seed[0] = 3
	if !blsvrf.VerifyPartial(loaded.Commits, loaded.Index, seed,
		blsvrf.Sign(loaded.Secret, seed)) {
		t.Fatal("the restored share cannot sign")
	}
}

func TestTheWrongPassphraseDoesNotOpenTheFile(t *testing.T) {
	shares, err := dkg.RunLocal(3, 2, 1)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "share.json")
	if err := keystore.Save(path, "right", shares[0]); err != nil {
		t.Fatal(err)
	}
	if _, err := keystore.Load(path, "wrong"); err == nil {
		t.Fatal("the wrong passphrase opened the keystore")
	}
}

func TestTheSecretIsNotSittingInTheFileInTheClear(t *testing.T) {
	shares, err := dkg.RunLocal(3, 2, 1)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "share.json")
	if err := keystore.Save(path, "pass", shares[0]); err != nil {
		t.Fatal(err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	secret, err := shares[0].Secret.MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	if containsBytes(raw, secret) {
		t.Fatal("the share secret is readable in the keystore file")
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("keystore is mode %v, expected 0600", info.Mode().Perm())
	}
}

func containsBytes(haystack, needle []byte) bool {
	if len(needle) == 0 {
		return false
	}
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if string(haystack[i:i+len(needle)]) == string(needle) {
			return true
		}
	}
	return false
}
