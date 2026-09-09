package dkg

import (
	"github.com/drand/kyber/pairing/bn254"
	"github.com/drand/kyber/share"
	"github.com/drand/kyber/sign"
	"github.com/drand/kyber/sign/schnorr"
)

// scheme authenticates DKG packets with Schnorr over the same curve, so a
// participant cannot be impersonated during the ceremony.
func scheme(s *bn254.Suite) sign.Scheme {
	return schnorr.NewScheme(s)
}

func priShare(sh Share) *share.PriShare {
	return &share.PriShare{I: int(sh.Index), V: sh.Secret}
}

// PriShare is this operator's share in the form kyber's resharing expects.
func (sh Share) PriShare() *share.PriShare { return priShare(sh) }
