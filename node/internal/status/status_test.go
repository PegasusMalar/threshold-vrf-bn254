package status_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"threshold-vrf/node/internal/status"
)

// upstreams stands in for the local operators.
func upstreams(t *testing.T, n int) ([]string, func()) {
	t.Helper()
	urls := make([]string, n)
	servers := make([]*httptest.Server, n)
	for i := range urls {
		index := i
		servers[i] = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/metrics" {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			w.Header().Set("Content-Type", "text/plain")
			_, _ = w.Write([]byte("vrf_operator_index " + string(rune('0'+index)) + "\nvrf_uptime_seconds 42\n"))
		}))
		urls[i] = servers[i].URL
	}
	return urls, func() {
		for _, s := range servers {
			s.Close()
		}
	}
}

func get(h http.Handler, path string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec
}

func TestServesOneOperatorsMetrics(t *testing.T) {
	urls, done := upstreams(t, 3)
	defer done()

	rec := get(status.NewServer(urls), "/op/1/metrics")
	if rec.Code != http.StatusOK {
		t.Fatalf("got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "vrf_operator_index 1") {
		t.Fatalf("proxied the wrong operator:\n%s", rec.Body.String())
	}
}

// / The whole point of the design is that the page asks every operator itself.
// / A combined snapshot is a convenience on top, never a replacement — so it
// / reports each answer separately rather than averaging anything.
func TestSnapshotKeepsTheAnswersSeparate(t *testing.T) {
	urls, done := upstreams(t, 3)
	defer done()
	urls = append(urls, "http://127.0.0.1:1") // one that is down

	rec := get(status.NewServer(urls), "/status.json")
	if rec.Code != http.StatusOK {
		t.Fatalf("got %d", rec.Code)
	}
	var snapshot struct {
		Operators []struct {
			Index   int    `json:"index"`
			Up      bool   `json:"up"`
			Metrics string `json:"metrics"`
			Error   string `json:"error"`
		} `json:"operators"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &snapshot); err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Operators) != 4 {
		t.Fatalf("expected four entries, got %d", len(snapshot.Operators))
	}
	for i := 0; i < 3; i++ {
		if !snapshot.Operators[i].Up {
			t.Fatalf("operator %d reported down", i)
		}
	}
	if snapshot.Operators[3].Up {
		t.Fatal("an unreachable operator reported up")
	}
	if snapshot.Operators[3].Error == "" {
		t.Fatal("an unreachable operator gave no reason")
	}
}

// / This process sits on the same machine as the share ports, the keystores and
// / the publishing keys. It must be incapable of reaching any of them, whatever
// / it is asked for.
func TestCannotBeSteeredAtAnythingButTheOperators(t *testing.T) {
	urls, done := upstreams(t, 2)
	defer done()
	h := status.NewServer(urls)

	for _, path := range []string{
		"/op/2/metrics",   // past the end
		"/op/99/metrics",  // far past the end
		"/op/-1/metrics",  // negative
		"/op/0/../../etc", // traversal
		"/op/0/healthz",   // a different path upstream
		"/op/abc/metrics", // not a number
		"/proxy?url=http://127.0.0.1:9100/v1/shares",
		"/",
	} {
		if code := get(h, path).Code; code != http.StatusNotFound {
			t.Fatalf("%s returned %d, expected 404", path, code)
		}
	}
}

func TestOnlyReading(t *testing.T) {
	urls, done := upstreams(t, 1)
	defer done()
	h := status.NewServer(urls)

	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(method, "/op/0/metrics", strings.NewReader("x")))
		if rec.Code != http.StatusMethodNotAllowed {
			t.Fatalf("%s returned %d, expected 405", method, rec.Code)
		}
	}
}

func TestReadableFromABrowser(t *testing.T) {
	urls, done := upstreams(t, 1)
	defer done()
	for _, path := range []string{"/op/0/metrics", "/status.json"} {
		if origin := get(status.NewServer(urls), path).Header().Get("Access-Control-Allow-Origin"); origin != "*" {
			t.Fatalf("%s: Access-Control-Allow-Origin is %q", path, origin)
		}
	}
}

// Both tunnels put an interstitial in front of a browser and take a header to
// skip it. A browser may only send that header on a cross-origin request if the
// preflight says it is allowed, so leaving either name out of the list means the
// page cannot reach us at all — through that tunnel.
func TestTheTunnelSkipHeadersAreAllowed(t *testing.T) {
	urls, done := upstreams(t, 1)
	defer done()

	for _, path := range []string{"/op/0/metrics", "/status.json", "/operators.json"} {
		allowed := get(status.NewServer(urls), path).Header().Get("Access-Control-Allow-Headers")
		for _, header := range []string{
			"ngrok-skip-browser-warning", // ngrok
			"bypass-tunnel-reminder",     // localtunnel
			"Content-Type",
		} {
			if !strings.Contains(allowed, header) {
				t.Fatalf("%s: %q is not in Access-Control-Allow-Headers (%q)", path, header, allowed)
			}
		}
	}
}

func TestTheOperatorListIsAlsoServed(t *testing.T) {
	urls, done := upstreams(t, 3)
	defer done()
	rec := get(status.NewServer(urls), "/operators.json")
	if rec.Code != http.StatusOK {
		t.Fatalf("got %d", rec.Code)
	}
	var list struct {
		Count int      `json:"count"`
		Paths []string `json:"paths"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &list); err != nil {
		t.Fatal(err)
	}
	if list.Count != 3 || len(list.Paths) != 3 || list.Paths[0] != "/op/0/metrics" {
		t.Fatalf("unhelpful listing: %+v", list)
	}
}
