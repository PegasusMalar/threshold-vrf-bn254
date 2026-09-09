package node_test

import (
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"testing"

	"threshold-vrf/node/internal/blsvrf"
	"threshold-vrf/node/internal/dkg"
	"threshold-vrf/node/internal/mesh"
	"threshold-vrf/node/internal/metrics"
)

func envelopeFor(t *testing.T, s dkg.Share, seed [32]byte, requestID string) mesh.Envelope {
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

func scrapeMetrics(t *testing.T, r *metrics.Registry) string {
	t.Helper()
	rec := httptest.NewRecorder()
	r.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, metrics.Path, nil))
	return rec.Body.String()
}
