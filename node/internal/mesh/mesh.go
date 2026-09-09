// Package mesh carries signature shares between operators.
//
// Every node sends its share directly to every other node over plain HTTP, and
// whoever collects a quorum first publishes. There is no gossip protocol and no
// leader: with nine operators that is 72 requests per VRF request, which is
// nothing, and it buys the one property a central aggregator cannot offer —
// nobody whose absence stops the service.
//
// The shares need no signing scheme of their own. A partial signature is
// checked against the sender's DKG public key before it is counted, so an
// impostor cannot produce one for an index that is not theirs. Transport
// security and rate limiting are about denial of service, not authenticity.
package mesh

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"golang.org/x/time/rate"

	"threshold-vrf/node/internal/blsvrf"
	"threshold-vrf/node/internal/threshold"
)

// SharePath is where peers post their signature shares.
const SharePath = "/v1/shares"

// ErrRejected tells the sender its share was refused — wrong seed, bad index,
// or a signature that does not verify.
var ErrRejected = errors.New("mesh: share rejected")

// Envelope is one operator's share of one signature, on the wire.
type Envelope struct {
	RequestID string `json:"requestId"`
	Seed      string `json:"seed"`
	Index     uint32 `json:"index"`
	Partial   string `json:"partial"`
}

// Decode parses the hex fields into the values the session works with.
func (e Envelope) Decode() ([32]byte, threshold.Partial, error) {
	var seed [32]byte

	seedBytes, err := decodeHex(e.Seed)
	if err != nil {
		return seed, threshold.Partial{}, fmt.Errorf("mesh: seed: %w", err)
	}
	if len(seedBytes) != 32 {
		return seed, threshold.Partial{}, errors.New("mesh: seed must be 32 bytes")
	}
	copy(seed[:], seedBytes)

	sigBytes, err := decodeHex(e.Partial)
	if err != nil {
		return seed, threshold.Partial{}, fmt.Errorf("mesh: partial: %w", err)
	}
	point, err := blsvrf.PointFromSignature(sigBytes)
	if err != nil {
		return seed, threshold.Partial{}, fmt.Errorf("mesh: partial: %w", err)
	}
	return seed, threshold.Partial{Index: e.Index, Sig: point}, nil
}

func decodeHex(s string) ([]byte, error) {
	return hex.DecodeString(strings.TrimPrefix(s, "0x"))
}

// MaxTrackedSources caps the per-source throttle table. The key is an address
// the caller chooses, so the table needs a ceiling of its own; past it,
// newcomers share one limiter between them.
const MaxTrackedSources = 1024

// ServerOptions tune how much abuse the share endpoint absorbs before it starts
// saying no. Zero values mean "defaults", nil means "all defaults".
type ServerOptions struct {
	// RatePerSecond is the sustained share rate accepted from one source.
	// Nine operators produce one share each per request, so single digits are
	// generous.
	RatePerSecond float64
	Burst         int
	// AllowedSources, when set, is the only place shares are accepted from —
	// IPs or CIDRs. Leave empty to accept from anywhere and rely on the rate
	// limit alone.
	AllowedSources []string
}

// Handler receives one peer's share.
type Handler func(context.Context, Envelope) error

type meshServer struct {
	http.Handler
	mu       sync.Mutex
	limiters map[string]*rate.Limiter
	overflow *rate.Limiter
}

// TrackedSources is how many distinct sources the throttle currently remembers.
func TrackedSources(h http.Handler) int {
	s, ok := h.(*meshServer)
	if !ok {
		return 0
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.limiters)
}

// NewServer returns the HTTP surface a node exposes to its peers.
//
// This port has to be open to the internet for the protocol to work, which
// means it will be found. A share costs a pairing to check, so the endpoint is
// throttled per source and can be pinned to a list of known operators.
func NewServer(handle Handler, opts *ServerOptions) http.Handler {
	if opts == nil {
		opts = &ServerOptions{}
	}
	// Sized for a burst, not for a trickle: one transaction can open fifty
	// requests at once, and every peer then sends fifty shares back to back.
	// The expensive part is already capped elsewhere — one verification per
	// operator per request — so this limit only has to keep parsing and memory
	// in check.
	if opts.RatePerSecond <= 0 {
		opts.RatePerSecond = 500
	}
	if opts.Burst <= 0 {
		opts.Burst = 1000
	}
	allowed := parseCIDRs(opts.AllowedSources)

	srv := &meshServer{
		limiters: make(map[string]*rate.Limiter),
		overflow: rate.NewLimiter(rate.Limit(opts.RatePerSecond), opts.Burst),
	}

	mux := http.NewServeMux()
	mux.HandleFunc(SharePath, func(w http.ResponseWriter, r *http.Request) {
		source := sourceOf(r)
		if len(allowed) > 0 && !permitted(allowed, source) {
			http.Error(w, "not an operator of this group", http.StatusForbidden)
			return
		}
		if !srv.allow(source, opts) {
			http.Error(w, "too many shares", http.StatusTooManyRequests)
			return
		}
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		var e Envelope
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&e); err != nil {
			http.Error(w, "malformed body", http.StatusBadRequest)
			return
		}
		if e.RequestID == "" || e.Seed == "" || e.Partial == "" {
			http.Error(w, "incomplete share", http.StatusBadRequest)
			return
		}
		if _, _, err := e.Decode(); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if err := handle(r.Context(), e); err != nil {
			http.Error(w, err.Error(), http.StatusUnprocessableEntity)
			return
		}
		w.WriteHeader(http.StatusAccepted)
	})
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	srv.Handler = mux
	return srv
}

func (s *meshServer) allow(source string, opts *ServerOptions) bool {
	s.mu.Lock()
	limiter, known := s.limiters[source]
	if !known {
		if len(s.limiters) >= MaxTrackedSources {
			limiter = s.overflow
		} else {
			limiter = rate.NewLimiter(rate.Limit(opts.RatePerSecond), opts.Burst)
			s.limiters[source] = limiter
		}
	}
	s.mu.Unlock()
	return limiter.Allow()
}

func sourceOf(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func parseCIDRs(entries []string) []*net.IPNet {
	out := make([]*net.IPNet, 0, len(entries))
	for _, entry := range entries {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		if !strings.Contains(entry, "/") {
			if ip := net.ParseIP(entry); ip != nil {
				bits := 32
				if ip.To4() == nil {
					bits = 128
				}
				out = append(out, &net.IPNet{IP: ip, Mask: net.CIDRMask(bits, bits)})
			}
			continue
		}
		if _, network, err := net.ParseCIDR(entry); err == nil {
			out = append(out, network)
		}
	}
	return out
}

func permitted(allowed []*net.IPNet, source string) bool {
	ip := net.ParseIP(source)
	if ip == nil {
		return false
	}
	for _, network := range allowed {
		if network.Contains(ip) {
			return true
		}
	}
	return false
}

// Client fans a share out to every peer.
type Client struct {
	peers []string
	http  *http.Client
}

// NewClient addresses the given peers, which should be every other operator.
func NewClient(peers []string, timeout time.Duration) *Client {
	// The default transport keeps two idle connections per host. A burst sends
	// one share per request to every peer at once, so all but two would open a
	// fresh connection and close it again — handshakes on the hot path, and a
	// pile of sockets in TIME_WAIT.
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.MaxIdleConnsPerHost = 64
	transport.MaxConnsPerHost = 128
	return &Client{peers: peers, http: &http.Client{Timeout: timeout, Transport: transport}}
}

// Broadcast delivers the share to every peer and reports the ones that failed.
//
// A returned error does not mean the share went nowhere: delivery to the
// reachable peers has already happened. With a threshold of t out of n, several
// peers can be down without consequence, so the caller logs this rather than
// retrying the whole fan-out.
func (c *Client) Broadcast(ctx context.Context, e Envelope) error {
	body, err := json.Marshal(e)
	if err != nil {
		return err
	}

	var (
		wg     sync.WaitGroup
		mu     sync.Mutex
		failed []string
	)
	for _, peer := range c.peers {
		wg.Add(1)
		go func(peer string) {
			defer wg.Done()
			if err := c.post(ctx, peer, body); err != nil {
				mu.Lock()
				failed = append(failed, fmt.Sprintf("%s: %v", peer, err))
				mu.Unlock()
			}
		}(peer)
	}
	wg.Wait()

	if len(failed) > 0 {
		return fmt.Errorf("mesh: %d of %d peers did not take the share: %s",
			len(failed), len(c.peers), strings.Join(failed, "; "))
	}
	return nil
}

func (c *Client) post(ctx context.Context, peer string, body []byte) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		strings.TrimSuffix(peer, "/")+SharePath, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return fmt.Errorf("status %d", resp.StatusCode)
	}
	return nil
}
