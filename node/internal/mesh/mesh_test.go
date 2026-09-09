package mesh_test

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"threshold-vrf/node/internal/blsvrf"
	"threshold-vrf/node/internal/dkg"
	"threshold-vrf/node/internal/mesh"
)

func fixture(t *testing.T) ([]dkg.Share, [32]byte) {
	t.Helper()
	shares, err := dkg.RunLocal(3, 2, 1)
	if err != nil {
		t.Fatal(err)
	}
	var seed [32]byte
	seed[31] = 9
	return shares, seed
}

func envelope(t *testing.T, s dkg.Share, seed [32]byte, requestID string) mesh.Envelope {
	t.Helper()
	raw, err := blsvrf.SignatureBytes(blsvrf.Sign(s.Secret, seed))
	if err != nil {
		t.Fatal(err)
	}
	return mesh.Envelope{
		RequestID: requestID,
		Seed:      "0x" + hex.EncodeToString(seed[:]),
		Index:     s.Index,
		Partial:   "0x" + hex.EncodeToString(raw),
	}
}

func TestAPartialFromAPeerReachesTheHandler(t *testing.T) {
	shares, seed := fixture(t)
	var got mesh.Envelope
	server := httptest.NewServer(mesh.NewServer(func(_ context.Context, e mesh.Envelope) error {
		got = e
		return nil
	}, nil))
	defer server.Close()

	client := mesh.NewClient([]string{server.URL}, time.Second)
	sent := envelope(t, shares[0], seed, "0x01")
	if err := client.Broadcast(context.Background(), sent); err != nil {
		t.Fatal(err)
	}
	if got.Index != sent.Index || got.Partial != sent.Partial {
		t.Fatal("the handler did not receive what was sent")
	}
}

// A rejected partial must come back as a client error, not a silent 200: the
// sender needs to learn that its share was refused.
func TestARefusedPartialIsReportedToTheSender(t *testing.T) {
	shares, seed := fixture(t)
	server := httptest.NewServer(mesh.NewServer(func(context.Context, mesh.Envelope) error {
		return mesh.ErrRejected
	}, nil))
	defer server.Close()

	client := mesh.NewClient([]string{server.URL}, time.Second)
	if err := client.Broadcast(context.Background(), envelope(t, shares[0], seed, "0x01")); err == nil {
		t.Fatal("a rejected partial looked like a success")
	}
}

func TestMalformedBodiesAreRejectedWithoutReachingTheHandler(t *testing.T) {
	called := false
	handler := mesh.NewServer(func(context.Context, mesh.Envelope) error {
		called = true
		return nil
	}, nil)

	for _, body := range []string{"", "{", `{"requestId":"0x1"}`, `{"requestId":"0x1","partial":"zz"}`} {
		req := httptest.NewRequest(http.MethodPost, mesh.SharePath, stringReader(body))
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code < 400 {
			t.Fatalf("body %q was accepted with %d", body, rec.Code)
		}
	}
	if called {
		t.Fatal("a malformed body reached the handler")
	}
}

// One peer being down must not stop the share from reaching the others: with
// t of n there is no single peer whose absence matters.
func TestBroadcastKeepsGoingWhenAPeerIsUnreachable(t *testing.T) {
	shares, seed := fixture(t)
	delivered := 0
	up := httptest.NewServer(mesh.NewServer(func(context.Context, mesh.Envelope) error {
		delivered++
		return nil
	}, nil))
	defer up.Close()

	client := mesh.NewClient([]string{"http://127.0.0.1:1", up.URL}, 300*time.Millisecond)
	err := client.Broadcast(context.Background(), envelope(t, shares[0], seed, "0x01"))
	if err == nil {
		t.Fatal("the unreachable peer should be reported")
	}
	if delivered != 1 {
		t.Fatalf("the reachable peer got %d deliveries", delivered)
	}
}

func TestEnvelopeDecodesBackIntoAUsablePartial(t *testing.T) {
	shares, seed := fixture(t)
	e := envelope(t, shares[1], seed, "0x2a")

	gotSeed, partial, err := e.Decode()
	if err != nil {
		t.Fatal(err)
	}
	if gotSeed != seed {
		t.Fatal("seed did not survive the round trip")
	}
	if partial.Index != shares[1].Index {
		t.Fatal("index did not survive the round trip")
	}
	if !blsvrf.VerifyPartial(shares[0].Commits, partial.Index, gotSeed, partial.Sig) {
		t.Fatal("the decoded partial no longer verifies")
	}
}

// The share endpoint has to be reachable from the internet, so it has to
// survive being found. Verifying a share costs a pairing; without a limit, a
// stranger with the URL sets the operator's CPU budget.
func TestAFloodFromOneSourceIsThrottled(t *testing.T) {
	shares, seed := fixture(t)
	handled := 0
	server := mesh.NewServer(func(context.Context, mesh.Envelope) error {
		handled++
		return nil
	}, &mesh.ServerOptions{RatePerSecond: 5, Burst: 5})

	body, err := json.Marshal(envelope(t, shares[0], seed, "0x01"))
	if err != nil {
		t.Fatal(err)
	}

	throttled := 0
	for i := 0; i < 40; i++ {
		req := httptest.NewRequest(http.MethodPost, mesh.SharePath, bytes.NewReader(body))
		req.RemoteAddr = "203.0.113.7:5000"
		rec := httptest.NewRecorder()
		server.ServeHTTP(rec, req)
		if rec.Code == http.StatusTooManyRequests {
			throttled++
		}
	}

	if throttled == 0 {
		t.Fatal("40 requests in an instant and nothing was throttled")
	}
	if handled > 10 {
		t.Fatalf("%d of 40 reached the handler despite a burst of 5", handled)
	}
}

// One noisy source must not throttle the other operators.
func TestThrottlingIsPerSource(t *testing.T) {
	shares, seed := fixture(t)
	server := mesh.NewServer(func(context.Context, mesh.Envelope) error { return nil },
		&mesh.ServerOptions{RatePerSecond: 2, Burst: 2})

	body, _ := json.Marshal(envelope(t, shares[0], seed, "0x01"))
	post := func(ip string) int {
		req := httptest.NewRequest(http.MethodPost, mesh.SharePath, bytes.NewReader(body))
		req.RemoteAddr = ip + ":5000"
		rec := httptest.NewRecorder()
		server.ServeHTTP(rec, req)
		return rec.Code
	}

	for i := 0; i < 20; i++ {
		post("198.51.100.1")
	}
	if code := post("198.51.100.2"); code == http.StatusTooManyRequests {
		t.Fatal("a quiet peer was throttled because of a noisy one")
	}
}

// The per-source table is itself keyed by something the attacker chooses, so it
// needs a ceiling of its own.
func TestTheThrottleTableIsBounded(t *testing.T) {
	shares, seed := fixture(t)
	server := mesh.NewServer(func(context.Context, mesh.Envelope) error { return nil },
		&mesh.ServerOptions{RatePerSecond: 100, Burst: 100})

	body, _ := json.Marshal(envelope(t, shares[0], seed, "0x01"))
	for i := 0; i < mesh.MaxTrackedSources*3; i++ {
		req := httptest.NewRequest(http.MethodPost, mesh.SharePath, bytes.NewReader(body))
		req.RemoteAddr = fmt.Sprintf("10.%d.%d.%d:5000", i>>16&0xff, i>>8&0xff, i&0xff)
		server.ServeHTTP(httptest.NewRecorder(), req)
	}
	if tracked := mesh.TrackedSources(server); tracked > mesh.MaxTrackedSources {
		t.Fatalf("tracking %d sources, cap is %d", tracked, mesh.MaxTrackedSources)
	}
}

func TestAnAllowlistKeepsStrangersOut(t *testing.T) {
	shares, seed := fixture(t)
	reached := false
	server := mesh.NewServer(func(context.Context, mesh.Envelope) error {
		reached = true
		return nil
	}, &mesh.ServerOptions{AllowedSources: []string{"192.0.2.0/24"}})

	body, _ := json.Marshal(envelope(t, shares[0], seed, "0x01"))
	post := func(ip string) int {
		req := httptest.NewRequest(http.MethodPost, mesh.SharePath, bytes.NewReader(body))
		req.RemoteAddr = ip + ":5000"
		rec := httptest.NewRecorder()
		server.ServeHTTP(rec, req)
		return rec.Code
	}

	if code := post("203.0.113.9"); code != http.StatusForbidden {
		t.Fatalf("a stranger got %d, expected 403", code)
	}
	if reached {
		t.Fatal("a stranger reached the handler")
	}
	if code := post("192.0.2.10"); code >= 400 {
		t.Fatalf("an allowed peer got %d", code)
	}
}
