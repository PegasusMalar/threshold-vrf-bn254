package metrics_test

import (
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"threshold-vrf/node/internal/metrics"
)

func scrape(t *testing.T, r *metrics.Registry) string {
	t.Helper()
	rec := httptest.NewRecorder()
	r.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, metrics.Path, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("scrape returned %d", rec.Code)
	}
	return rec.Body.String()
}

func mustContain(t *testing.T, body string, lines ...string) {
	t.Helper()
	for _, line := range lines {
		if !strings.Contains(body, line) {
			t.Fatalf("missing %q in:\n%s", line, body)
		}
	}
}

func TestReportsWhoIsAnswering(t *testing.T) {
	r := metrics.New(3, 5, 9)
	mustContain(t, scrape(t, r),
		"vrf_operator_index 3",
		"vrf_threshold 5",
		"vrf_operators 9",
	)
}

// The number the monitor is built on: each node reports how many shares it got
// from each peer. One node's word proves nothing; eight nodes agreeing that a
// ninth sends nothing is evidence.
func TestCountsSharesPerPeer(t *testing.T) {
	r := metrics.New(0, 5, 9)
	r.ShareReceived(4)
	r.ShareReceived(4)
	r.ShareReceived(7)
	r.ShareRejected(7)

	mustContain(t, scrape(t, r),
		`vrf_shares_received_total{peer="4"} 2`,
		`vrf_shares_received_total{peer="7"} 1`,
		`vrf_shares_rejected_total{peer="7"} 1`,
	)
}

func TestCountsWhatTheNodeItselfDid(t *testing.T) {
	r := metrics.New(0, 5, 9)
	r.RequestSeen()
	r.RequestSeen()
	r.ShareSent()
	r.Published()
	r.RaceLost()
	r.RaceLost()
	r.BlockSeen(1234)

	mustContain(t, scrape(t, r),
		"vrf_requests_seen_total 2",
		"vrf_shares_sent_total 1",
		"vrf_fulfilments_published_total 1",
		"vrf_fulfilments_lost_total 2",
		"vrf_last_seen_block 1234",
	)
}

func TestEquivocationIsCountedPerPeer(t *testing.T) {
	r := metrics.New(0, 5, 9)
	r.Equivocation(2)
	mustContain(t, scrape(t, r), `vrf_equivocations_total{peer="2"} 1`)
}

func TestLiveGaugesComeFromTheNode(t *testing.T) {
	r := metrics.New(0, 5, 9)
	r.SetGauges(func() int { return 3 }, func() int { return 11 })
	mustContain(t, scrape(t, r), "vrf_sessions_active 3", "vrf_parked_requests 11")
}

func TestUptimeIsReported(t *testing.T) {
	mustContain(t, scrape(t, metrics.New(0, 5, 9)), "vrf_uptime_seconds")
}

// The monitor is a static page in someone's browser querying all nine operators
// directly, so that nobody has to be trusted to aggregate. That only works if
// the browser is allowed to read the response.
func TestTheEndpointIsReadableFromABrowser(t *testing.T) {
	rec := httptest.NewRecorder()
	metrics.New(0, 5, 9).Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, metrics.Path, nil))
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "*" {
		t.Fatalf("Access-Control-Allow-Origin is %q", got)
	}
}

func TestEveryMetricIsDeclared(t *testing.T) {
	body := scrape(t, metrics.New(0, 5, 9))
	for _, line := range strings.Split(body, "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		name := strings.SplitN(strings.SplitN(line, "{", 2)[0], " ", 2)[0]
		if !strings.Contains(body, "# HELP "+name+" ") {
			t.Fatalf("%s is exposed without a HELP line", name)
		}
		if !strings.Contains(body, "# TYPE "+name+" ") {
			t.Fatalf("%s is exposed without a TYPE line", name)
		}
	}
}

// An operator whose publishing account is empty looks perfectly healthy: it
// scans, signs and broadcasts shares, and only the step that costs gas stops.
// A load test found the whole fleet in that state, delivering 8% with every
// other counter moving, so the balance is reported too.
func TestReportsThePublishingBalanceWhenItIsKnown(t *testing.T) {
	r := metrics.New(0, 5, 9)
	r.SetBalanceGauge(func() *big.Int { return big.NewInt(1234) })
	mustContain(t, scrape(t, r), "vrf_publisher_balance_wei 1234")
}

// Omitted rather than zero: a monitor must be able to tell "this node has not
// managed to read its balance" from "this node has nothing left".
func TestOmitsThePublishingBalanceWhenItIsNotKnown(t *testing.T) {
	r := metrics.New(0, 5, 9)
	if body := scrape(t, r); strings.Contains(body, "vrf_publisher_balance_wei") {
		t.Fatalf("expected no balance line before one is known:\n%s", body)
	}
	r.SetBalanceGauge(func() *big.Int { return nil })
	if body := scrape(t, r); strings.Contains(body, "vrf_publisher_balance_wei") {
		t.Fatalf("expected no balance line while the value is unknown:\n%s", body)
	}
}
