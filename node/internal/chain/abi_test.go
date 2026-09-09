package chain

import (
	"encoding/json"
	"fmt"
	"os"
	"testing"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/crypto"
)

// The node carries a hand-written ABI. If the contract changes shape, this test
// is what notices — otherwise the node would quietly stop seeing requests, or
// start sending calldata nobody can decode.
func TestHandWrittenAbiMatchesTheCompiledContract(t *testing.T) {
	for _, c := range []struct {
		artifact string
		parse    func() (abi.ABI, error)
	}{
		{"../../../out/VRFCoordinator.sol/VRFCoordinator.json", parsedABI},
		// The node's second hand-written ABI, and the one that moves money:
		// an operator collecting its earnings calls withdraw on this contract.
		{"../../../out/Subscription.sol/Subscription.json", parsedSubscriptionABI},
	} {
		t.Run(c.artifact, func(t *testing.T) { checkABI(t, c.artifact, c.parse) })
	}
}

func checkABI(t *testing.T, artifactPath string, parse func() (abi.ABI, error)) {
	t.Helper()
	raw, err := os.ReadFile(artifactPath)
	if err != nil {
		t.Skipf("run `forge build` first: %v", err)
	}
	var artifact struct {
		ABI json.RawMessage `json:"abi"`
	}
	if err := json.Unmarshal(raw, &artifact); err != nil {
		t.Fatal(err)
	}
	compiled, err := abi.JSON(newReader(artifact.ABI))
	if err != nil {
		t.Fatal(err)
	}
	ours, err := parse()
	if err != nil {
		t.Fatal(err)
	}

	for name := range ours.Events {
		got, ok := compiled.Events[name]
		if !ok {
			t.Fatalf("contract no longer emits %s", name)
		}
		if got.ID != ours.Events[name].ID {
			t.Fatalf("event %s changed shape: topic0 %s vs %s", name, got.ID, ours.Events[name].ID)
		}
	}
	for name, mine := range ours.Methods {
		got, ok := compiled.Methods[name]
		if !ok {
			t.Fatalf("contract no longer has %s", name)
		}
		if string(got.ID) != string(mine.ID) {
			t.Fatalf("selector for %s changed", name)
		}
		// A selector covers the inputs only. A changed *return* shape leaves it
		// alone and would silently mis-decode here — which is exactly what
		// happened when callbackSucceeded was added to requests().
		if err := sameArgs(got.Outputs, mine.Outputs); err != nil {
			t.Fatalf("return shape of %s changed: %v", name, err)
		}
		if err := sameArgs(got.Inputs, mine.Inputs); err != nil {
			t.Fatalf("arguments of %s changed: %v", name, err)
		}
	}

	for name, mine := range ours.Events {
		if err := sameArgs(compiled.Events[name].Inputs, mine.Inputs); err != nil {
			t.Fatalf("fields of event %s changed: %v", name, err)
		}
	}
}

func sameArgs(want, got abi.Arguments) error {
	if len(want) != len(got) {
		return fmt.Errorf("%d fields on chain, %d here", len(want), len(got))
	}
	for i := range want {
		if want[i].Type.String() != got[i].Type.String() {
			return fmt.Errorf("field %d is %s on chain, %s here",
				i, want[i].Type.String(), got[i].Type.String())
		}
		if want[i].Indexed != got[i].Indexed {
			return fmt.Errorf("field %d changed indexing", i)
		}
	}
	return nil
}

func TestRequestTopicIsWhatTheContractHashes(t *testing.T) {
	ours, err := parsedABI()
	if err != nil {
		t.Fatal(err)
	}
	// Byte for byte Chainlink's own signature, so an indexer written for their
	// coordinator decodes ours without a change.
	want := crypto.Keccak256Hash(
		[]byte("RandomWordsRequested(bytes32,uint256,uint256,uint256,uint16,uint32,uint32,bytes,address)"),
	)
	if ours.Events["RandomWordsRequested"].ID != want {
		t.Fatalf("topic0 %s != %s", ours.Events["RandomWordsRequested"].ID, want)
	}
}
