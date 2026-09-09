// Command vrfdkg runs a distributed key generation ceremony in one process and
// writes one encrypted keystore per operator.
//
// This is the local and testnet path: three nodes on a laptop, nine on a
// staging network. It is NOT how a production group is created, and it says so
// loudly when it runs — here the full group secret does exist, briefly, in one
// machine's memory, which is exactly the thing the whole design exists to avoid.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"threshold-vrf/node/internal/blsvrf"
	"threshold-vrf/node/internal/dkg"
	"threshold-vrf/node/internal/keystore"
)

func main() {
	operators := flag.Int("operators", 3, "number of operators")
	quorum := flag.Int("threshold", 2, "signatures required to produce a group signature")
	epoch := flag.Uint64("epoch", 1, "key epoch, bound into the ceremony nonce")
	dir := flag.String("out", "./keys", "directory for the keystores")
	passphrase := flag.String("passphrase", "", "keystore passphrase (or $VRF_KEYSTORE_PASSPHRASE)")
	flag.Parse()

	pass := *passphrase
	if pass == "" {
		pass = os.Getenv("VRF_KEYSTORE_PASSPHRASE")
	}
	if pass == "" {
		fail(fmt.Errorf("a keystore passphrase is required"))
	}

	fmt.Fprintln(os.Stderr,
		"WARNING: this ceremony runs every participant in one process, so the group\n"+
			"secret briefly exists on this machine. Use it for local and testnet setups\n"+
			"only; a production group must run the same protocol across real hosts.")

	shares, err := dkg.RunLocal(*operators, *quorum, *epoch)
	if err != nil {
		fail(err)
	}

	if err := os.MkdirAll(*dir, 0o700); err != nil {
		fail(err)
	}
	for _, s := range shares {
		path := filepath.Join(*dir, fmt.Sprintf("operator-%d.json", s.Index))
		if err := keystore.Save(path, pass, s); err != nil {
			fail(err)
		}
		fmt.Printf("wrote %s\n", path)
	}

	pk, err := blsvrf.SerializeG2(shares[0].GroupPublic)
	if err != nil {
		fail(err)
	}

	// machine-readable, so deployment scripts do not have to scrape stdout
	group := map[string]any{
		"epoch":     *epoch,
		"threshold": *quorum,
		"operators": *operators,
		"groupPublicKey": []string{
			"0x" + pk[0].Text(16), "0x" + pk[1].Text(16),
			"0x" + pk[2].Text(16), "0x" + pk[3].Text(16),
		},
		"constructorArgs": fmt.Sprintf("[%s,%s,%s,%s]", pk[0], pk[1], pk[2], pk[3]),
	}
	body, err := json.MarshalIndent(group, "", "    ")
	if err != nil {
		fail(err)
	}
	groupPath := filepath.Join(*dir, "group.json")
	if err := os.WriteFile(groupPath, append(body, '\n'), 0o644); err != nil {
		fail(err)
	}
	fmt.Printf("wrote %s\n", groupPath)

	fmt.Printf("\n%d of %d, epoch %d\n", *quorum, *operators, *epoch)
	fmt.Printf("group public key (constructor argument for VRFVerifier):\n")
	fmt.Printf("  [%s,%s,%s,%s] %d\n", pk[0], pk[1], pk[2], pk[3], *epoch)
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}
