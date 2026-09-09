#!/usr/bin/env bash
# Measures fulfilment latency against operators that run somewhere else.
#
#   VRF_DEPLOYER_KEY=0x... ./script/remote-latency.sh [request-count]
#
# script/testnet.sh answers the same question but starts the nine operators on
# this machine, which quietly excludes the one thing a distributed fleet adds:
# the round trip between hosts on the share exchange. This script starts nothing
# and assumes the fleet in deployments/operators.json is already serving, so the
# number it prints is the one a real consumer would see.
#
# It also reports which operator published each fulfilment, read from the nodes'
# own counters rather than from the chain — a threshold signature does not say
# who produced it, so the chain cannot answer that question.
set -euo pipefail
cd "$(dirname "$0")/.."

RECORD=${RECORD:-deployments/testnet.json}
FLEET=${FLEET:-deployments/operators.json}
REQUESTS=${1:-10}
# What an ordinary consumer asks for, not what the coordinator allows. The
# budget decides both the price of the request and the float its publisher must
# hold to send the fulfilment, so measuring with the maximum measures a fleet
# nobody runs — and reports a latency caused by operators that could not afford
# to publish rather than by the service.
CALLBACK_GAS=${CALLBACK_GAS:-100000}
RPC=$(jq -r '.rpc' "$RECORD")
COORDINATOR=$(jq -r '.coordinator' "$RECORD")
SUBS=$(jq -r '.subscription' "$RECORD")
SUB_ID=$(jq -r '.subscriptionId // 1' "$RECORD")
METRICS_PORT=$(jq -r '.metricsPort // 9600' "$FLEET")
# Named after the record and the moment, not a fixed path. It used to be
# .testnet/remote-latency.txt whatever chain the run was against, so a mainnet
# run wrote into the testnet directory — and two runs overlapping appended to
# the same file, which is how one summary came to report samples from a run
# that was not its own.
NETWORK=$(basename "$RECORD" .json)
OUT=${OUT:-.$NETWORK/latency-$(date +%Y%m%d-%H%M%S).txt}

: "${VRF_DEPLOYER_KEY:?set VRF_DEPLOYER_KEY to the funded testnet key}"
DEPLOYER=$(cast wallet address --private-key "$VRF_DEPLOYER_KEY")
send() { cast send --rpc-url "$RPC" --private-key "$VRF_DEPLOYER_KEY" --json "$@" | jq -r '.status'; }

# Counters before and after, so the tally covers this run and not the node's
# whole life.
published () {
    jq -r '.operators[] | "\(.index) \(.host)"' "$FLEET" | while read -r i h; do
        n=$(curl -s --max-time 8 "http://$h:$METRICS_PORT/metrics" \
            | awk '$1=="vrf_fulfilments_published_total"{print $2}')
        echo "$i ${n:-0}"
    done
}

echo "==> chain $(cast chain-id --rpc-url "$RPC"), deployer $DEPLOYER"
echo "    balance $(cast from-wei "$(cast balance "$DEPLOYER" --rpc-url "$RPC")") ETH"
echo "    coordinator $COORDINATOR"

AVAILABLE=$(cast call "$SUBS" "availableOf(uint256)(uint96)" "$SUB_ID" --rpc-url "$RPC" | awk '{print $1}')
echo "    subscription $SUB_ID has $(cast from-wei "$AVAILABLE") ETH"

BEFORE=$(published)
CHAIN_ID=$(cast chain-id --rpc-url "$RPC")
mkdir -p "$(dirname "$OUT")"; : > "$OUT"

echo "==> $REQUESTS requests"
for n in $(seq 1 "$REQUESTS"); do
    NONCE=$(cast call "$COORDINATOR" "nonces(address)(uint256)" "$DEPLOYER" --rpc-url "$RPC" | awk '{print $1}')
    PACKED="0x$(printf '%s' "${DEPLOYER:2}" | tr 'A-Z' 'a-z')$(printf '%064x' "$NONCE")$(printf '%s' "${COORDINATOR:2}" | tr 'A-Z' 'a-z')$(printf '%064x' "$CHAIN_ID")"
    REQUEST_ID=$(cast keccak "$PACKED")

    START=$(python3 -c 'import time;print(time.time())')
    send "$COORDINATOR" "requestRandomWords((bytes32,uint256,uint16,uint32,uint32,bytes))" \
        "(0x0000000000000000000000000000000000000000000000000000000000000000,$SUB_ID,0,$CALLBACK_GAS,1,0x)" >/dev/null

    FULFILLED=false
    for _ in $(seq 1 300); do
        state=$(cast call "$COORDINATOR" "requests(uint256)(address,uint256,uint32,uint32,bool,bool,bool)" \
            "$REQUEST_ID" --rpc-url "$RPC" | sed -n 5p)
        [ "$state" = "true" ] && { FULFILLED=true; break; }
        sleep 0.2
    done
    END=$(python3 -c 'import time;print(time.time())')

    if [ "$FULFILLED" = true ]; then
        python3 -c "print(f'{$END-$START:.3f}')" >> "$OUT"
        printf "  %2d/%s  %ss\n" "$n" "$REQUESTS" "$(tail -1 "$OUT")"
    else
        printf "  %2d/%s  TIMED OUT (%s)\n" "$n" "$REQUESTS" "$REQUEST_ID"
    fi
done

echo
echo "==> latency, request submitted -> fulfilled, seconds"
python3 - "$OUT" <<'PY'
import statistics, sys
xs = sorted(float(x) for x in open(sys.argv[1]) if x.strip())
if not xs:
    raise SystemExit('    no samples — nothing was fulfilled')
pct = lambda p: xs[min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1))))]
print(f"    samples {len(xs)}  min {xs[0]:.2f}  P50 {pct(50):.2f}  "
      f"P95 {pct(95):.2f}  P99 {pct(99):.2f}  max {xs[-1]:.2f}  mean {statistics.mean(xs):.2f}")
PY

echo
echo "==> who published, this run"
join <(echo "$BEFORE") <(published) | awk '{d=$3-$2; if (d>0) printf "  operator %s  %d\n", $1, d}'
