#!/usr/bin/env bash
# Phase-1 blocking benchmark: what does one on-chain verification actually cost,
# on the chain we are shipping to?
#
# Nothing is deployed and nothing is spent: the verifier and a measurement probe
# are injected into an `eth_call` via state override, so the gas is metered by
# the target chain's own node.
#
#   ./script/bench.sh <rpc-url> [<rpc-url> ...]
set -euo pipefail
cd "$(dirname "$0")/.."

VECTORS=test/vectors/bls.json
VERIFIER_ADDR=0x00000000000000000000000000000000000000f1
PROBE_ADDR=0x00000000000000000000000000000000000000f2

PK=($(jq -r '.groupPubKey[]' $VECTORS))
SEED=$(jq -r '.message' $VECTORS)
SIG=$(jq -r '.signature[0] + .signature[1]' $VECTORS | sed 's/0x//g')
SIG="0x$(echo $SIG | sed 's/0x//g')"

echo "building runtime bytecode..."
forge build >/dev/null

# Immutables are baked into runtime code, so the verifier has to be really
# deployed once (on a throwaway local chain) to get the bytecode we inject.
anvil --silent --port 8599 &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
sleep 2

DEPLOY=$(forge create src/VRFVerifier.sol:VRFVerifier \
    --rpc-url http://127.0.0.1:8599 \
    --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
    --broadcast \
    --constructor-args "[${PK[0]},${PK[1]},${PK[2]},${PK[3]}]" 1 2>&1 | grep "Deployed to:" | awk '{print $3}')
VERIFIER_CODE=$(cast code "$DEPLOY" --rpc-url http://127.0.0.1:8599)
PROBE_CODE=$(forge inspect GasProbe deployedBytecode)
kill $ANVIL_PID 2>/dev/null || true

CALLDATA=$(cast calldata "probe(address,bytes32,bytes)" $VERIFIER_ADDR $SEED $SIG)

for RPC in "$@"; do
    CHAIN_ID=$(cast chain-id --rpc-url "$RPC" 2>/dev/null || echo "?")
    echo
    echo "=== $RPC (chain $CHAIN_ID) ==="

    jq -n --arg probe "$PROBE_ADDR" --arg verifier "$VERIFIER_ADDR" \
        --arg data "$CALLDATA" --arg pcode "$PROBE_CODE" --arg vcode "$VERIFIER_CODE" \
        '{jsonrpc:"2.0",id:1,method:"eth_call",params:[
            {to:$probe,data:$data,gas:"0x2faf080"},
            "latest",
            {($probe):{code:$pcode},($verifier):{code:$vcode}}]}' > /tmp/vrf_bench_req.json
    RESULT=$(curl -s --max-time 30 -X POST -H 'content-type: application/json' \
        --data @/tmp/vrf_bench_req.json "$RPC")

    if echo "$RESULT" | jq -e '.error' >/dev/null; then
        echo "  RPC error: $(echo "$RESULT" | jq -c '.error')"
        continue
    fi
    RAW=$(echo "$RESULT" | jq -r '.result')
    DEC=$(cast abi-decode "probe()(uint256,uint256,uint256,bool)" "$RAW")
    VERIFY=$(echo "$DEC" | sed -n 1p); HASH=$(echo "$DEC" | sed -n 2p)
    PAIRING=$(echo "$DEC" | sed -n 3p); OK=$(echo "$DEC" | sed -n 4p)
    echo "  signature verified : $OK"
    echo "  verify()           : $VERIFY gas"
    echo "  hashSeedToPoint()  : $HASH gas"
    echo "  ecPairing k=2 raw  : $PAIRING gas"

    # Full fulfillRandomWords, built and measured inside the call itself
    SK=$(jq -r '.groupSecretKey' $VECTORS)
    for N in 1 10 100; do
        FCALL=$(cast calldata "probeFulfill(uint256[4],uint256,uint32)" \
            "[${PK[0]},${PK[1]},${PK[2]},${PK[3]}]" "$SK" "$N")
        jq -n --arg probe "$PROBE_ADDR" --arg data "$FCALL" --arg pcode "$PROBE_CODE" \
            '{jsonrpc:"2.0",id:1,method:"eth_call",params:[
                {to:$probe,data:$data,gas:"0x5f5e100"},
                "latest",
                {($probe):{code:$pcode,balance:"0xde0b6b3a7640000"}}]}' > /tmp/vrf_bench_req.json
        R=$(curl -s --max-time 60 -X POST -H 'content-type: application/json' \
            --data @/tmp/vrf_bench_req.json "$RPC")
        if echo "$R" | jq -e '.error' >/dev/null; then
            echo "  fulfillRandomWords($N): $(echo "$R" | jq -r '.error.message')"
        else
            D=$(cast abi-decode "probeFulfill()(uint256,uint256,uint256)" "$(echo "$R" | jq -r '.result')")
            echo "  $N words: request $(echo "$D" | sed -n 1p) | fulfill cold $(echo "$D" | sed -n 2p) | fulfill warm $(echo "$D" | sed -n 3p)"
        fi
    done

    # L1 data component, charged on top of execution on any Arbitrum Orbit chain
    NI=0x00000000000000000000000000000000000000C8
    COMP=$(cast call $NI "gasEstimateComponents(address,bool,bytes)(uint64,uint64,uint256,uint256)" \
        $VERIFIER_ADDR false "$(cast calldata 'verify(bytes32,bytes)' $SEED $SIG)" \
        --rpc-url "$RPC" 2>/dev/null || echo "unavailable")
    echo "  NodeInterface gasEstimateComponents (against an empty address, L1 part only):"
    echo "$COMP" | sed 's/^/    /'
done
