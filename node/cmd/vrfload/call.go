package main

import (
	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
)

func ethereumCall(to common.Address, data []byte) ethereum.CallMsg {
	return ethereum.CallMsg{To: &to, Data: data}
}

func ethereumCallFrom(from, to common.Address, data []byte) ethereum.CallMsg {
	return ethereum.CallMsg{From: from, To: &to, Data: data}
}
