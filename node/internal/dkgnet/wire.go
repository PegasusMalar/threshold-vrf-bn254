// Package dkgnet runs the key ceremony across the network instead of inside one
// process.
//
// The protocol is unchanged — it is still drand/kyber's Pedersen DKG — and so
// is the result. What changes is that no machine ever sees more than its own
// share, which is the entire point and the one thing the single-process
// ceremony in `vrfdkg` cannot offer.
package dkgnet

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/drand/kyber"
	kdkg "github.com/drand/kyber/share/dkg"

	"threshold-vrf/node/internal/dkg"
)

// Bundles cross the wire as JSON with hex-encoded group elements. Deliberately
// self-describing rather than compact: a ceremony happens once a month, is
// operated by hand, and the thing that matters when it goes wrong is being able
// to read what was sent.
type wireDeal struct {
	ShareIndex     uint32 `json:"shareIndex"`
	EncryptedShare string `json:"encryptedShare"`
}

type wireDealBundle struct {
	Kind        string     `json:"kind"`
	DealerIndex uint32     `json:"dealerIndex"`
	Deals       []wireDeal `json:"deals"`
	Public      []string   `json:"public"`
	SessionID   string     `json:"sessionId"`
	Signature   string     `json:"signature"`
}

type wireResponse struct {
	DealerIndex uint32 `json:"dealerIndex"`
	Status      bool   `json:"status"`
}

type wireResponseBundle struct {
	Kind       string         `json:"kind"`
	ShareIndex uint32         `json:"shareIndex"`
	Responses  []wireResponse `json:"responses"`
	SessionID  string         `json:"sessionId"`
	Signature  string         `json:"signature"`
}

type wireJustification struct {
	ShareIndex uint32 `json:"shareIndex"`
	Share      string `json:"share"`
}

type wireJustificationBundle struct {
	Kind           string              `json:"kind"`
	DealerIndex    uint32              `json:"dealerIndex"`
	Justifications []wireJustification `json:"justifications"`
	SessionID      string              `json:"sessionId"`
	Signature      string              `json:"signature"`
}

// EncodeDeals serialises a deal bundle.
func EncodeDeals(b *kdkg.DealBundle) ([]byte, error) {
	out := wireDealBundle{
		Kind:        "deals",
		DealerIndex: b.DealerIndex,
		SessionID:   toHex(b.SessionID),
		Signature:   toHex(b.Signature),
	}
	for _, d := range b.Deals {
		out.Deals = append(out.Deals, wireDeal{d.ShareIndex, toHex(d.EncryptedShare)})
	}
	for _, p := range b.Public {
		raw, err := p.MarshalBinary()
		if err != nil {
			return nil, err
		}
		out.Public = append(out.Public, toHex(raw))
	}
	return json.Marshal(out)
}

// DecodeDeals parses a deal bundle.
func DecodeDeals(raw []byte) (*kdkg.DealBundle, error) {
	var in wireDealBundle
	if err := json.Unmarshal(raw, &in); err != nil {
		return nil, err
	}
	out := &kdkg.DealBundle{DealerIndex: in.DealerIndex}
	var err error
	if out.SessionID, err = fromHex(in.SessionID); err != nil {
		return nil, err
	}
	if out.Signature, err = fromHex(in.Signature); err != nil {
		return nil, err
	}
	for _, d := range in.Deals {
		share, err := fromHex(d.EncryptedShare)
		if err != nil {
			return nil, err
		}
		out.Deals = append(out.Deals, kdkg.Deal{ShareIndex: d.ShareIndex, EncryptedShare: share})
	}
	for _, p := range in.Public {
		point, err := decodePoint(p)
		if err != nil {
			return nil, err
		}
		out.Public = append(out.Public, point)
	}
	return out, nil
}

// EncodeResponses serialises a response bundle.
func EncodeResponses(b *kdkg.ResponseBundle) ([]byte, error) {
	out := wireResponseBundle{
		Kind:       "responses",
		ShareIndex: b.ShareIndex,
		SessionID:  toHex(b.SessionID),
		Signature:  toHex(b.Signature),
	}
	for _, r := range b.Responses {
		out.Responses = append(out.Responses, wireResponse{r.DealerIndex, r.Status})
	}
	return json.Marshal(out)
}

// DecodeResponses parses a response bundle.
func DecodeResponses(raw []byte) (*kdkg.ResponseBundle, error) {
	var in wireResponseBundle
	if err := json.Unmarshal(raw, &in); err != nil {
		return nil, err
	}
	out := &kdkg.ResponseBundle{ShareIndex: in.ShareIndex}
	var err error
	if out.SessionID, err = fromHex(in.SessionID); err != nil {
		return nil, err
	}
	if out.Signature, err = fromHex(in.Signature); err != nil {
		return nil, err
	}
	for _, r := range in.Responses {
		out.Responses = append(out.Responses,
			kdkg.Response{DealerIndex: r.DealerIndex, Status: r.Status})
	}
	return out, nil
}

// EncodeJustifications serialises a justification bundle.
func EncodeJustifications(b *kdkg.JustificationBundle) ([]byte, error) {
	out := wireJustificationBundle{
		Kind:        "justifications",
		DealerIndex: b.DealerIndex,
		SessionID:   toHex(b.SessionID),
		Signature:   toHex(b.Signature),
	}
	for _, j := range b.Justifications {
		raw, err := j.Share.MarshalBinary()
		if err != nil {
			return nil, err
		}
		out.Justifications = append(out.Justifications,
			wireJustification{j.ShareIndex, toHex(raw)})
	}
	return json.Marshal(out)
}

// DecodeJustifications parses a justification bundle.
func DecodeJustifications(raw []byte) (*kdkg.JustificationBundle, error) {
	var in wireJustificationBundle
	if err := json.Unmarshal(raw, &in); err != nil {
		return nil, err
	}
	out := &kdkg.JustificationBundle{DealerIndex: in.DealerIndex}
	var err error
	if out.SessionID, err = fromHex(in.SessionID); err != nil {
		return nil, err
	}
	if out.Signature, err = fromHex(in.Signature); err != nil {
		return nil, err
	}
	for _, j := range in.Justifications {
		raw, err := fromHex(j.Share)
		if err != nil {
			return nil, err
		}
		scalar := dkg.Suite().G2().Scalar()
		if err := scalar.UnmarshalBinary(raw); err != nil {
			return nil, err
		}
		out.Justifications = append(out.Justifications,
			kdkg.Justification{ShareIndex: j.ShareIndex, Share: scalar})
	}
	return out, nil
}

// KindOf reports which bundle a payload holds, without fully decoding it.
func KindOf(raw []byte) (string, error) {
	var probe struct {
		Kind string `json:"kind"`
	}
	if err := json.Unmarshal(raw, &probe); err != nil {
		return "", err
	}
	switch probe.Kind {
	case "deals", "responses", "justifications":
		return probe.Kind, nil
	default:
		return "", fmt.Errorf("dkgnet: unknown bundle kind %q", probe.Kind)
	}
}

func decodePoint(s string) (kyber.Point, error) {
	raw, err := fromHex(s)
	if err != nil {
		return nil, err
	}
	point := dkg.Suite().G2().Point()
	if err := point.UnmarshalBinary(raw); err != nil {
		return nil, err
	}
	return point, nil
}

func toHex(b []byte) string {
	if len(b) == 0 {
		return ""
	}
	return "0x" + hex.EncodeToString(b)
}

func fromHex(s string) ([]byte, error) {
	if s == "" {
		return nil, nil
	}
	return hex.DecodeString(strings.TrimPrefix(s, "0x"))
}
