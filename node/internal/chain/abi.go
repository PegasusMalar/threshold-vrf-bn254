package chain

import (
	"strings"

	"github.com/ethereum/go-ethereum/accounts/abi"
)

// Only the pieces of VRFCoordinator the node actually touches. Kept as a
// literal rather than generated bindings so there is no build step between
// editing the contract and noticing that the node no longer matches it — the
// tests in this package compare it against the compiled artifact.
const coordinatorABI = `[
  {"type":"event","name":"RandomWordsRequested","anonymous":false,"inputs":[
    {"name":"keyHash","type":"bytes32","indexed":true},
    {"name":"requestId","type":"uint256","indexed":false},
    {"name":"seed","type":"uint256","indexed":false},
    {"name":"subId","type":"uint256","indexed":true},
    {"name":"requestConfirmations","type":"uint16","indexed":false},
    {"name":"callbackGasLimit","type":"uint32","indexed":false},
    {"name":"numWords","type":"uint32","indexed":false},
    {"name":"extraArgs","type":"bytes","indexed":false},
    {"name":"sender","type":"address","indexed":true}]},
  {"type":"event","name":"RandomWordsFulfilled","anonymous":false,"inputs":[
    {"name":"requestId","type":"uint256","indexed":true},
    {"name":"outputSeed","type":"uint256","indexed":false},
    {"name":"subId","type":"uint256","indexed":true},
    {"name":"payment","type":"uint96","indexed":false},
    {"name":"nativePayment","type":"bool","indexed":false},
    {"name":"success","type":"bool","indexed":false},
    {"name":"onlyPremium","type":"bool","indexed":false}]},
  {"type":"function","name":"fulfillRandomWords","stateMutability":"nonpayable","inputs":[
    {"name":"requestId","type":"uint256"},{"name":"signature","type":"bytes"}],"outputs":[]},
  {"type":"function","name":"subscriptions","stateMutability":"view","inputs":[],
    "outputs":[{"name":"","type":"address"}]},
  {"type":"function","name":"seedOf","stateMutability":"view","inputs":[
    {"name":"requestId","type":"uint256"}],"outputs":[{"name":"","type":"bytes32"}]},
  {"type":"function","name":"requests","stateMutability":"view","inputs":[
    {"name":"requestId","type":"uint256"}],"outputs":[
    {"name":"consumer","type":"address"},{"name":"subId","type":"uint256"},
    {"name":"numWords","type":"uint32"},
    {"name":"callbackGasLimit","type":"uint32"},{"name":"fulfilled","type":"bool"},
    {"name":"refunded","type":"bool"},{"name":"callbackSucceeded","type":"bool"}]}
]`

// The two pieces of Subscription an operator needs: what it has earned, and
// how to collect it. Nothing else — the node never moves anyone else's money.
const subscriptionABI = `[
  {"type":"function","name":"withdrawableOf","stateMutability":"view","inputs":[
    {"name":"payee","type":"address"}],"outputs":[{"name":"","type":"uint96"}]},
  {"type":"function","name":"withdraw","stateMutability":"nonpayable","inputs":[
    {"name":"to","type":"address"}],"outputs":[]}
]`

func parsedSubscriptionABI() (abi.ABI, error) {
	return abi.JSON(strings.NewReader(subscriptionABI))
}

func parsedABI() (abi.ABI, error) {
	return abi.JSON(strings.NewReader(coordinatorABI))
}
