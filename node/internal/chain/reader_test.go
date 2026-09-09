package chain

import (
	"bytes"
	"io"
)

func newReader(b []byte) io.Reader { return bytes.NewReader(b) }
