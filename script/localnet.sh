#!/usr/bin/env bash
# Stands the whole thing up locally: a chain, a key ceremony, the contracts and
# three operator nodes talking to each other. Then it asks for a random number
# and waits for the operators to deliver it.
#
#   ./script/localnet.sh
#
# Everything lands in .localnet/ and is thrown away on the next run.
set -euo pipefail
cd "$(dirname "$0")/.."

OPERATORS=3
THRESHOLD=2
PORT=8545
DIR=.localnet
DEV_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
DEV_ADDR=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
# launch shape: free now, with a ceiling nobody can ever exceed
MAX_BASE_FEE=1000000000000000      # 0.001 ETH
MAX_PER_WORD_FEE=100000000000000   # 0.0001 ETH
MAX_PER_GAS_FEE=1000000000         # 1 gwei per unit of callback gas
RPC=http://127.0.0.1:$PORT
export VRF_KEYSTORE_PASSPHRASE=localnet

# One publishing key per operator, as in production: they race each other for
# the fulfillment, and a shared key would make that race look like a nonce
# collision instead of what it is.
OPERATOR_KEYS=(
    0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
    0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
    0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
)

rm -rf $DIR && mkdir -p $DIR/logs
LOGS=$(cd $DIR/logs && pwd)
PIDS=()
cleanup() {
    for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT

echo "==> building"
BIN=$(cd $DIR && mkdir -p bin && cd bin && pwd)
# built rather than `go run`: go run spawns a child the trap cannot reach, and
# a leftover node from the previous run holds the mesh port
(cd node && go build -o "$BIN/vrfdkg" ./cmd/vrfdkg && go build -o "$BIN/vrfnode" ./cmd/vrfnode)

echo "==> chain"
anvil --silent --port $PORT --block-time 1 & PIDS+=($!)
until cast chain-id --rpc-url $RPC >/dev/null 2>&1; do sleep 0.2; done

echo "==> key ceremony ($THRESHOLD of $OPERATORS)"
"$BIN/vrfdkg" -operators $OPERATORS -threshold $THRESHOLD -out $DIR/keys | tail -3
ARGS=$(jq -r '.constructorArgs' $DIR/keys/group.json)
EPOCH=$(jq -r '.epoch' $DIR/keys/group.json)

echo "==> contracts"
VERIFIER=$(forge create src/VRFVerifier.sol:VRFVerifier --rpc-url $RPC \
    --private-key $DEV_KEY --broadcast --constructor-args "$ARGS" "$EPOCH" \
    | grep "Deployed to:" | awk '{print $3}')
COORDINATOR=$(forge create src/VRFCoordinator.sol:VRFCoordinator --rpc-url $RPC \
    --private-key $DEV_KEY --broadcast \
    --constructor-args "$VERIFIER" 0 0 0 $MAX_BASE_FEE $MAX_PER_WORD_FEE $MAX_PER_GAS_FEE \
    | grep "Deployed to:" | awk '{print $3}')
SUBS=$(cast call "$COORDINATOR" "subscriptions()(address)" --rpc-url $RPC)
echo "    verifier    $VERIFIER"
echo "    coordinator $COORDINATOR"
echo "    subscription $SUBS"

echo "==> subscription"
cast send "$SUBS" "createSubscription()" --rpc-url $RPC --private-key $DEV_KEY >/dev/null
# the sender is its own consumer here: a callback to an account with no code
# just succeeds, which keeps this script about the protocol and not about a
# sample game contract
cast send "$SUBS" "addConsumer(uint256,address)" 1 $DEV_ADDR \
    --rpc-url $RPC --private-key $DEV_KEY >/dev/null

echo "==> operators"
PEERS=()
for i in $(seq 0 $((OPERATORS - 1))); do PEERS+=("http://127.0.0.1:$((9000 + i))"); done
KEYS=$(cd $DIR/keys && pwd)
for i in $(seq 0 $((OPERATORS - 1))); do
    others=""
    for j in $(seq 0 $((OPERATORS - 1))); do
        [ "$i" = "$j" ] && continue
        others="${others:+$others,}${PEERS[$j]}"
    done
    export VRF_ETH_PRIVATE_KEY="${OPERATOR_KEYS[$i]}"
    ("$BIN/vrfnode" \
        -rpc $RPC -coordinator "$COORDINATOR" \
        -keystore "$KEYS/operator-$i.json" \
        -listen "127.0.0.1:$((9000 + i))" -peers "$others" \
        -metrics-listen "127.0.0.1:$((9500 + i))" \
        -allow 127.0.0.1/32 \
        -threshold $THRESHOLD -operators $OPERATORS \
        > "$LOGS/operator-$i.log" 2>&1) & PIDS+=($!)
    unset VRF_ETH_PRIVATE_KEY
done
sleep 8

echo "==> requesting 3 random words"
cast send "$COORDINATOR" "requestRandomWords((bytes32,uint256,uint16,uint32,uint32,bytes))" \
    "(0x0000000000000000000000000000000000000000000000000000000000000000,1,0,500000,3,0x)" \
    --rpc-url $RPC --private-key $DEV_KEY >/dev/null
# Computed rather than scraped: the id is a pure function of who asked and
# their nonce, and since RandomWordsRequested follows Chainlink's indexing the
# id now lives in the log data rather than in a topic.
CHAIN_ID=$(cast chain-id --rpc-url $RPC)
NONCE=$(cast call "$COORDINATOR" "nonces(address)(uint256)" $DEV_ADDR --rpc-url $RPC | awk '{print $1}')
REQUEST_ID=$(cast keccak "0x$(printf '%s' "${DEV_ADDR:2}" | tr 'A-Z' 'a-z')$(printf '%064x' $((NONCE - 1)))$(printf '%s' "${COORDINATOR:2}" | tr 'A-Z' 'a-z')$(printf '%064x' "$CHAIN_ID")")
echo "    request $REQUEST_ID"

echo "==> waiting for the operators"
for _ in $(seq 1 40); do
    FULFILLED=$(cast call "$COORDINATOR" \
        "requests(uint256)(address,uint256,uint32,uint32,bool,bool,bool)" "$REQUEST_ID" \
        --rpc-url $RPC | sed -n 5p)
    if [ "$FULFILLED" = "true" ]; then
        echo
        echo "    fulfilled"
        grep -h "published" "$LOGS"/*.log | head -1
        echo
        echo "==> counters from operator 0 (the monitor reads all of these)"
        curl -s http://127.0.0.1:9500/metrics | grep -vE "^#" | grep -vE " 0$" | sed 's/^/    /'
        exit 0
    fi
    sleep 1
done

echo
echo "    NOT fulfilled — operator logs:"
tail -n 20 $DIR/logs/*.log
exit 1
