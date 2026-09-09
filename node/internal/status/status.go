// Package status exposes operator metrics to the outside world, and nothing else.
//
// The operators run on one machine during testing, and that machine also holds
// the share ports, the keystores and the publishing keys. This process is the
// only thing on it meant to be reachable from outside, so it is built to be
// incapable of reaching anything but the metrics endpoints it was given:
//
//   - the upstreams are a fixed list, decided at start-up and never influenced
//     by a request. There is no target parameter, no redirect following, no way
//     to point it somewhere else;
//   - only the path `/metrics` is ever requested upstream;
//   - only GET is answered, and no request body is read or forwarded.
//
// What it serves is public by design: counters, no secrets. The browser reading
// them is meant to ask every operator separately and compare, so the combined
// snapshot here keeps the answers apart rather than averaging them into a
// number someone has to trust.
package status

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

const maxUpstreamBody = 256 << 10

// NewServer serves the metrics of the given operators, in order.
func NewServer(upstreams []string) http.Handler {
	targets := make([]string, len(upstreams))
	for i, u := range upstreams {
		targets[i] = strings.TrimSuffix(u, "/") + "/metrics"
	}
	client := &http.Client{Timeout: 3 * time.Second}

	// Deliberately not a ServeMux: it rewrites paths and answers with redirects
	// before any of our checks run, which turns a request we mean to refuse
	// outright into a 307 pointing somewhere else.
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cors(w)
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "read only", http.StatusMethodNotAllowed)
			return
		}

		switch {
		case r.URL.Path == "/healthz":
			_, _ = w.Write([]byte("ok"))
		case r.URL.Path == "/operators.json":
			listing(w, len(targets))
		case r.URL.Path == "/status.json":
			snapshot(r.Context(), w, client, targets)
		default:
			index, ok := operatorIndex(r.URL.Path, len(targets))
			if !ok {
				http.NotFound(w, r)
				return
			}
			proxy(r.Context(), w, client, targets[index])
		}
	})
}

// operatorIndex accepts exactly "/op/<n>/metrics" and nothing else. The index is
// then a position in a fixed list, so no request can name a destination.
func operatorIndex(path string, count int) (int, bool) {
	parts := strings.Split(path, "/")
	if len(parts) != 4 || parts[0] != "" || parts[1] != "op" || parts[3] != "metrics" {
		return 0, false
	}
	index, err := strconv.Atoi(parts[2])
	if err != nil || index < 0 || index >= count {
		return 0, false
	}
	return index, true
}

func proxy(ctx context.Context, w http.ResponseWriter, client *http.Client, target string) {
	body, err := fetch(ctx, client, target)
	if err != nil {
		http.Error(w, "operator unreachable", http.StatusBadGateway)
		return
	}
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(body)
}

type operatorStatus struct {
	Index   int    `json:"index"`
	Up      bool   `json:"up"`
	Metrics string `json:"metrics,omitempty"`
	Error   string `json:"error,omitempty"`
}

func snapshot(ctx context.Context, w http.ResponseWriter, client *http.Client, targets []string) {
	out := make([]operatorStatus, len(targets))
	var wg sync.WaitGroup
	for i, target := range targets {
		wg.Add(1)
		go func(i int, target string) {
			defer wg.Done()
			out[i] = operatorStatus{Index: i}
			body, err := fetch(ctx, client, target)
			if err != nil {
				out[i].Error = err.Error()
				return
			}
			out[i].Up = true
			out[i].Metrics = string(body)
		}(i, target)
	}
	wg.Wait()

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"note": "one answer per operator, deliberately not combined: " +
			"a single operator's word about another proves nothing",
		"fetchedAt": time.Now().UTC().Format(time.RFC3339),
		"operators": out,
	})
}

func listing(w http.ResponseWriter, count int) {
	paths := make([]string, count)
	for i := range paths {
		paths[i] = fmt.Sprintf("/op/%d/metrics", i)
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"count": count, "paths": paths})
}

func fetch(ctx context.Context, client *http.Client, target string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("operator answered %d", resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, maxUpstreamBody))
}

func cors(w http.ResponseWriter) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
	// Both tunnels show a browser an interstitial and take a header to skip it —
	// ngrok its own, localtunnel another. A browser may only send either on a
	// cross-origin request if the preflight allows it by name, so both are
	// listed regardless of which tunnel happens to be in front today.
	w.Header().Set("Access-Control-Allow-Headers",
		"ngrok-skip-browser-warning, bypass-tunnel-reminder, Content-Type")
	w.Header().Set("Access-Control-Max-Age", "86400")
}
