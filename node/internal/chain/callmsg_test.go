//go:build integration

package chain_test

import (
	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
)

func ethereumCallMsg(from, to common.Address, data []byte) ethereum.CallMsg {
	return ethereum.CallMsg{From: from, To: &to, Data: data}
}
