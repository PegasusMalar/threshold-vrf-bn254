// Command vrfceremony takes part in a key ceremony across the network.
//
// Unlike vrfdkg, which runs every participant in one process, this is the real
// thing: one process per operator, on that operator's own machine, and no
// machine ever holds more than its own share.
//
// A first ceremony:
//
//	vrfceremony -generate-identity -identity identity.json   # each operator
//	                                                          # publishes the
//	                                                          # printed key
//	vrfceremony -config ceremony.json -identity identity.json \
//	            -index 3 -listen 0.0.0.0:8090 -out keys/operator-3.json
//
// A rotation is the same command with an "old" block in the config and the
// previous keystore instead of an identity file.
package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/drand/kyber"

	"threshold-vrf/node/internal/blsvrf"
	"threshold-vrf/node/internal/dkg"
	"threshold-vrf/node/internal/dkgnet"
	"threshold-vrf/node/internal/keystore"
)

// ceremonyConfig is shared verbatim by every participant. Any disagreement
// about its contents changes the session nonce and the ceremony fails rather
// than quietly producing two different groups.
type ceremonyConfig struct {
	Epoch     uint64       `json:"epoch"`
	Threshold int          `json:"threshold"`
	Members   []memberJSON `json:"members"`
	Old       *oldGroup    `json:"old,omitempty"`
}

type memberJSON struct {
	Index  uint32 `json:"index"`
	Public string `json:"public"`
	URL    string `json:"url"`
}

type oldGroup struct {
	Threshold int          `json:"threshold"`
	Members   []memberJSON `json:"members"`
	Commits   []string     `json:"commits"`
}

type identityFile struct {
	Index   uint32 `json:"index"`
	Public  string `json:"public"`
	Private string `json:"private"`
}

func main() {
	var (
		generate   = flag.Bool("generate-identity", false, "create an identity and exit")
		identity   = flag.String("identity", "identity.json", "this operator's ceremony identity")
		configPath = flag.String("config", "", "shared ceremony configuration")
		index      = flag.Uint("index", 0, "this operator's index")
		listen     = flag.String("listen", ":8090", "address to receive ceremony bundles on")
		out        = flag.String("out", "", "where to write the resulting keystore")
		oldKey     = flag.String("old-keystore", "", "previous keystore, when rotating")
		phase      = flag.Duration("phase", 30*time.Second, "how long to wait for stragglers each round")
		timeout    = flag.Duration("timeout", 10*time.Minute, "give up after this long")
	)
	flag.Parse()

	log := slog.New(slog.NewTextHandler(os.Stderr, nil))

	if *generate {
		if err := writeIdentity(*identity, uint32(*index)); err != nil {
			fail(log, err)
		}
		return
	}
	if *configPath == "" || *out == "" {
		fail(log, fmt.Errorf("-config and -out are required"))
	}
	passphrase := os.Getenv("VRF_KEYSTORE_PASSPHRASE")
	if passphrase == "" {
		fail(log, fmt.Errorf("VRF_KEYSTORE_PASSPHRASE is not set"))
	}

	cfg, err := readConfig(*configPath)
	if err != nil {
		fail(log, err)
	}

	self, old, err := loadSelf(*identity, *oldKey, passphrase, uint32(*index))
	if err != nil {
		fail(log, err)
	}

	members, err := toMembers(cfg.Members)
	if err != nil {
		fail(log, err)
	}
	params := dkgnet.Params{
		Self:        self,
		Members:     members,
		Threshold:   cfg.Threshold,
		Epoch:       cfg.Epoch,
		PhasePeriod: *phase,
		Old:         old,
	}
	peers := peerURLs(cfg, uint32(*index))

	if cfg.Old != nil {
		if params.OldMembers, err = toMembers(cfg.Old.Members); err != nil {
			fail(log, err)
		}
		params.OldThreshold = cfg.Old.Threshold
		if params.OldCommits, err = toPoints(cfg.Old.Commits); err != nil {
			fail(log, err)
		}
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithTimeout(ctx, *timeout)
	defer cancel()

	board := dkgnet.NewBoard(peers, 4*len(members)+16, log)
	// Tied to the phase period rather than left at the default: an operator who
	// says "wait two minutes for stragglers" means it about the people starting
	// late, and delivery has to be as patient as the round it belongs to.
	if *phase > dkgnet.DefaultRetryWindow {
		board.SetRetryWindow(*phase)
	}
	server := &http.Server{Addr: *listen, Handler: board.Handler(), ReadHeaderTimeout: 5 * time.Second}
	go func() {
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Error("ceremony server stopped", "err", err)
			stop()
		}
	}()
	defer func() {
		shutdown, c := context.WithTimeout(context.Background(), 5*time.Second)
		defer c()
		_ = server.Shutdown(shutdown)
	}()

	log.Info("ceremony starting",
		"index", *index, "epoch", cfg.Epoch,
		"threshold", fmt.Sprintf("%d of %d", cfg.Threshold, len(members)),
		"resharing", cfg.Old != nil, "listen", *listen, "peers", len(peers))

	share, err := dkgnet.Run(ctx, params, board)
	board.Close()
	if err != nil {
		fail(log, err)
	}

	if err := keystore.Save(*out, passphrase, share); err != nil {
		fail(log, err)
	}
	pk, err := blsvrf.SerializeG2(share.GroupPublic)
	if err != nil {
		fail(log, err)
	}

	log.Info("ceremony complete", "keystore", *out)
	fmt.Printf("group public key (constructor argument for VRFVerifier):\n")
	fmt.Printf("  [%s,%s,%s,%s] %d\n", pk[0], pk[1], pk[2], pk[3], cfg.Epoch)
	fmt.Printf("\nEvery operator must print the same key. If yours differs, the ceremony\n")
	fmt.Printf("did not converge and nothing here should be deployed.\n")
}

func writeIdentity(path string, index uint32) error {
	member := dkg.NewMember(index)
	secret, err := member.Longterm.MarshalBinary()
	if err != nil {
		return err
	}
	public, err := member.Public.MarshalBinary()
	if err != nil {
		return err
	}
	body, err := json.MarshalIndent(identityFile{
		Index:   index,
		Public:  "0x" + hex.EncodeToString(public),
		Private: "0x" + hex.EncodeToString(secret),
	}, "", "    ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(path, append(body, '\n'), 0o600); err != nil {
		return err
	}
	fmt.Printf("wrote %s\n\nPublish this line to the other operators:\n", path)
	fmt.Printf("  {\"index\": %d, \"public\": \"0x%s\", \"url\": \"https://YOUR-HOST:8090\"}\n",
		index, hex.EncodeToString(public))
	return nil
}

func readConfig(path string) (ceremonyConfig, error) {
	var cfg ceremonyConfig
	raw, err := os.ReadFile(path)
	if err != nil {
		return cfg, err
	}
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return cfg, err
	}
	if cfg.Threshold < 1 || cfg.Threshold > len(cfg.Members) {
		return cfg, fmt.Errorf("threshold %d of %d makes no sense", cfg.Threshold, len(cfg.Members))
	}
	return cfg, nil
}

// loadSelf takes the identity from the previous keystore when rotating, so an
// operator keeps the same identity across epochs, and from the identity file
// only for a first ceremony.
func loadSelf(identityPath, oldKeystore, passphrase string, index uint32) (dkg.Member, *dkg.Share, error) {
	if oldKeystore != "" {
		share, err := keystore.Load(oldKeystore, passphrase)
		if err != nil {
			return dkg.Member{}, nil, err
		}
		if share.Longterm == nil {
			return dkg.Member{}, nil, fmt.Errorf("keystore %s has no ceremony identity in it", oldKeystore)
		}
		return share.Member, &share, nil
	}

	raw, err := os.ReadFile(identityPath)
	if err != nil {
		return dkg.Member{}, nil, err
	}
	var f identityFile
	if err := json.Unmarshal(raw, &f); err != nil {
		return dkg.Member{}, nil, err
	}
	secret, err := hex.DecodeString(strings.TrimPrefix(f.Private, "0x"))
	if err != nil {
		return dkg.Member{}, nil, err
	}
	longterm := dkg.Suite().G2().Scalar()
	if err := longterm.UnmarshalBinary(secret); err != nil {
		return dkg.Member{}, nil, err
	}
	return dkg.Member{
		Index:    index,
		Longterm: longterm,
		Public:   dkg.Suite().G2().Point().Mul(longterm, nil),
	}, nil, nil
}

func toMembers(in []memberJSON) ([]dkg.Member, error) {
	out := make([]dkg.Member, len(in))
	for i, m := range in {
		point, err := decodePoint(m.Public)
		if err != nil {
			return nil, fmt.Errorf("member %d: %w", m.Index, err)
		}
		out[i] = dkg.Member{Index: m.Index, Public: point}
	}
	return out, nil
}

func toPoints(in []string) ([]kyber.Point, error) {
	out := make([]kyber.Point, len(in))
	for i, s := range in {
		p, err := decodePoint(s)
		if err != nil {
			return nil, err
		}
		out[i] = p
	}
	return out, nil
}

func decodePoint(s string) (kyber.Point, error) {
	raw, err := hex.DecodeString(strings.TrimPrefix(s, "0x"))
	if err != nil {
		return nil, err
	}
	p := dkg.Suite().G2().Point()
	return p, p.UnmarshalBinary(raw)
}

func peerURLs(cfg ceremonyConfig, self uint32) []string {
	seen := map[string]bool{}
	var out []string
	add := func(members []memberJSON) {
		for _, m := range members {
			if m.Index == self || m.URL == "" || seen[m.URL] {
				continue
			}
			seen[m.URL] = true
			out = append(out, m.URL)
		}
	}
	add(cfg.Members)
	if cfg.Old != nil {
		add(cfg.Old.Members)
	}
	return out
}

func fail(log *slog.Logger, err error) {
	log.Error("fatal", "err", err)
	os.Exit(1)
}
