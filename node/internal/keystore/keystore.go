// Package keystore keeps an operator's DKG share on disk.
//
// The share is the operator's entire stake in the protocol: lose it and the
// group drops below its threshold that much sooner, leak it and an attacker is
// one of nine. It is encrypted at rest with a passphrase and written 0600.
//
// The commitments and the group public key are stored alongside it. They are
// public, but without them the node cannot check anyone else's share, and a
// node that cannot check shares must not aggregate.
package keystore

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"golang.org/x/crypto/scrypt"

	"github.com/drand/kyber"
	"github.com/drand/kyber/pairing/bn254"

	"threshold-vrf/node/internal/dkg"
)

const (
	scryptN = 1 << 17
	scryptR = 8
	scryptP = 1
	keyLen  = 32
)

type file struct {
	Version     int      `json:"version"`
	Index       uint32   `json:"index"`
	GroupPublic string   `json:"groupPublic"`
	Commits     []string `json:"commits"`
	Salt        string   `json:"kdfSalt"`
	Nonce       string   `json:"nonce"`
	Ciphertext  string   `json:"ciphertext"`
}

// Save encrypts a share and writes it atomically.
func Save(path, passphrase string, share dkg.Share) error {
	if passphrase == "" {
		return errors.New("keystore: refusing to write an unprotected share")
	}

	plaintext, err := marshalSecrets(share)
	if err != nil {
		return err
	}

	salt := make([]byte, 32)
	if _, err := rand.Read(salt); err != nil {
		return err
	}
	aead, err := aeadFor(passphrase, salt)
	if err != nil {
		return err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return err
	}

	groupPublic, err := share.GroupPublic.MarshalBinary()
	if err != nil {
		return err
	}
	commits := make([]string, len(share.Commits))
	for i, c := range share.Commits {
		raw, err := c.MarshalBinary()
		if err != nil {
			return err
		}
		commits[i] = hex.EncodeToString(raw)
	}

	body, err := json.MarshalIndent(file{
		Version:     1,
		Index:       share.Index,
		GroupPublic: hex.EncodeToString(groupPublic),
		Commits:     commits,
		Salt:        hex.EncodeToString(salt),
		Nonce:       hex.EncodeToString(nonce),
		Ciphertext:  hex.EncodeToString(aead.Seal(nil, nonce, plaintext, nil)),
	}, "", "    ")
	if err != nil {
		return err
	}

	// write-then-rename, so a crash mid-write cannot leave a half share behind
	tmp := path + ".tmp"
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	if err := os.WriteFile(tmp, append(body, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Load decrypts a share.
func Load(path, passphrase string) (dkg.Share, error) {
	var share dkg.Share

	raw, err := os.ReadFile(path)
	if err != nil {
		return share, err
	}
	var f file
	if err := json.Unmarshal(raw, &f); err != nil {
		return share, fmt.Errorf("keystore: %w", err)
	}
	if f.Version != 1 {
		return share, fmt.Errorf("keystore: unsupported version %d", f.Version)
	}

	salt, err := hex.DecodeString(f.Salt)
	if err != nil {
		return share, err
	}
	nonce, err := hex.DecodeString(f.Nonce)
	if err != nil {
		return share, err
	}
	ciphertext, err := hex.DecodeString(f.Ciphertext)
	if err != nil {
		return share, err
	}
	aead, err := aeadFor(passphrase, salt)
	if err != nil {
		return share, err
	}
	plaintext, err := aead.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return share, errors.New("keystore: wrong passphrase or corrupted file")
	}

	suite := bn254.NewSuiteG2()
	share.Index = f.Index
	if err := unmarshalSecrets(plaintext, &share); err != nil {
		return share, err
	}

	groupPublic, err := hex.DecodeString(f.GroupPublic)
	if err != nil {
		return share, err
	}
	share.GroupPublic = suite.G2().Point()
	if err := share.GroupPublic.UnmarshalBinary(groupPublic); err != nil {
		return share, err
	}

	share.Commits = make([]kyber.Point, len(f.Commits))
	for i, c := range f.Commits {
		raw, err := hex.DecodeString(c)
		if err != nil {
			return share, err
		}
		share.Commits[i] = suite.G2().Point()
		if err := share.Commits[i].UnmarshalBinary(raw); err != nil {
			return share, err
		}
	}
	return share, nil
}

type secrets struct {
	Share    string `json:"share"`
	Longterm string `json:"longterm"`
}

func marshalSecrets(share dkg.Share) ([]byte, error) {
	s, err := share.Secret.MarshalBinary()
	if err != nil {
		return nil, err
	}
	out := secrets{Share: hex.EncodeToString(s)}
	if share.Longterm != nil {
		l, err := share.Longterm.MarshalBinary()
		if err != nil {
			return nil, err
		}
		out.Longterm = hex.EncodeToString(l)
	}
	return json.Marshal(out)
}

func unmarshalSecrets(plaintext []byte, share *dkg.Share) error {
	var s secrets
	if err := json.Unmarshal(plaintext, &s); err != nil {
		return err
	}
	suite := bn254.NewSuiteG2()

	raw, err := hex.DecodeString(s.Share)
	if err != nil {
		return err
	}
	share.Secret = suite.G2().Scalar()
	if err := share.Secret.UnmarshalBinary(raw); err != nil {
		return err
	}

	if s.Longterm != "" {
		raw, err := hex.DecodeString(s.Longterm)
		if err != nil {
			return err
		}
		share.Longterm = suite.G2().Scalar()
		if err := share.Longterm.UnmarshalBinary(raw); err != nil {
			return err
		}
		share.Public = suite.G2().Point().Mul(share.Longterm, nil)
	}
	return nil
}

func aeadFor(passphrase string, salt []byte) (cipher.AEAD, error) {
	key, err := scrypt.Key([]byte(passphrase), salt, scryptN, scryptR, scryptP, keyLen)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}
