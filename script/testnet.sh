#!/usr/bin/env bash
# Deploys the stack to Robinhood Chain testnet (46630), runs a 5-of-9 operator
# group against it, and measures what the spec still has no number for: how long a
# consumer waits between asking for randomness and getting it.
#
#   VRF_DEPLOYER_KEY=0x... ./script/testnet.sh [request-count]
#   VRF_DEPLOYER_KEY=0x... ./script/testnet.sh [request-count] --fresh
#
# By default it reuses whatever is recorded in deployments/testnet.json, so the
# addresses integrators are pointed at stay put and the run costs only the
# requests. `--fresh` deploys a new set and rewrites that file — which
# invalidates every address anyone has already integrated, so it is opt-in.
#
# The nine operators run on this machine, so the numbers exclude the RTT between
# real hosts. That RTT lands on the share exchange, which happens once per
# request and in parallel — tens of milliseconds against a chain that takes
# seconds. Everything else here is real.
set -euo pipefail
cd "$(dirname "$0")/.."

RPC=${VRF_RPC:-https://rpc.testnet.chain.robinhood.com/rpc}
OPERATORS=9
THRESHOLD=5
REQUESTS=${1:-20}
FRESH=false
for arg in "$@"; do [ "$arg" = "--fresh" ] && FRESH=true; done
RECORD=deployments/testnet.json
BASE_FEE=1000000000000              # 1e-6 ETH
PER_WORD_FEE=100000000000           # 1e-7 ETH
MAX_BASE_FEE=1000000000000000       # 0.001 ETH, the ceiling nobody can exceed
MAX_PER_WORD_FEE=100000000000000    # 0.0001 ETH
MAX_PER_GAS_FEE=1000000000          # 1 gwei per unit of callback gas
SUB_FUNDING=200000000000000 # 0.0002 ETH - the testnet balance is not unlimited
DIR=.testnet
export VRF_KEYSTORE_PASSPHRASE=${VRF_KEYSTORE_PASSPHRASE:-testnet}

: "${VRF_DEPLOYER_KEY:?set VRF_DEPLOYER_KEY to the funded testnet key}"
DEPLOYER=$(cast wallet address --private-key "$VRF_DEPLOYER_KEY")

mkdir -p $DIR/logs
LOGS=$(cd $DIR/logs && pwd)
PIDS=()
cleanup() { for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done; }
trap cleanup EXIT

send() { cast send --rpc-url $RPC --private-key "$VRF_DEPLOYER_KEY" --json "$@" | jq -r '.status'; }

echo "==> chain $(cast chain-id --rpc-url $RPC), deployer $DEPLOYER"
echo "    balance $(cast from-wei "$(cast balance $DEPLOYER --rpc-url $RPC)") ETH"

echo "==> building"
BIN=$(mkdir -p $DIR/bin && cd $DIR/bin && pwd)
(cd node && go build -o "$BIN/vrfdkg" ./cmd/vrfdkg && go build -o "$BIN/vrfnode" ./cmd/vrfnode)
forge build >/dev/null

if [ ! -f "$DIR/keys/group.json" ]; then
    echo "==> key ceremony ($THRESHOLD of $OPERATORS)"
    "$BIN/vrfdkg" -operators $OPERATORS -threshold $THRESHOLD -out $DIR/keys 2>/dev/null | tail -1
fi
ARGS=$(jq -r '.constructorArgs' $DIR/keys/group.json)
EPOCH=$(jq -r '.epoch' $DIR/keys/group.json)

# One publishing key per operator: they take turns going first, and a shared
# key would turn that rotation into nonce collisions.
if [ ! -f "$DIR/keys/eth.json" ]; then
    echo "==> publishing keys"
    cast wallet new --json --number $OPERATORS > "$DIR/keys/eth.json"
    for i in $(seq 0 $((OPERATORS - 1))); do
        addr=$(jq -r ".[$i].address" "$DIR/keys/eth.json")
        send --value 100000000000000 "$addr" >/dev/null   # 0.0001 ETH each
    done
fi

FROM_BLOCK=$(cast block-number --rpc-url $RPC)

if [ "$FRESH" = false ] && [ -f "$RECORD" ]; then
    COORDINATOR=$(jq -r '.coordinator' $RECORD)
    SUBS=$(jq -r '.subscription' $RECORD)
    VERIFIER=$(jq -r '.verifier' $RECORD)
    if [ "$(cast code "$COORDINATOR" --rpc-url $RPC | wc -c)" -lt 10 ]; then
        echo "!! $RECORD points at $COORDINATOR, which has no code on this chain."
        echo "   Re-run with --fresh to deploy a new set."
        exit 1
    fi
    echo "==> reusing the recorded deployment (--fresh to replace it)"
else
    echo "==> contracts (fresh)"
    VERIFIER=$(forge create src/VRFVerifier.sol:VRFVerifier --rpc-url $RPC \
        --private-key "$VRF_DEPLOYER_KEY" --broadcast --constructor-args "$ARGS" "$EPOCH" \
        | grep "Deployed to:" | awk '{print $3}')
    COORDINATOR=$(forge create src/VRFCoordinator.sol:VRFCoordinator --rpc-url $RPC \
        --private-key "$VRF_DEPLOYER_KEY" --broadcast \
        --constructor-args "$VERIFIER" $BASE_FEE $PER_WORD_FEE 0 $MAX_BASE_FEE $MAX_PER_WORD_FEE $MAX_PER_GAS_FEE \
        | grep "Deployed to:" | awk '{print $3}')
    SUBS=$(cast call "$COORDINATOR" "subscriptions()(address)" --rpc-url $RPC)

    send "$SUBS" "createSubscription()" >/dev/null
    send "$SUBS" "fundSubscriptionWithNative(uint256)" 1 --value $SUB_FUNDING >/dev/null
    send "$SUBS" "addConsumer(uint256,address)" 1 "$DEPLOYER" >/dev/null

    jq -n --arg c "$COORDINATOR" --arg s "$SUBS" --arg v "$VERIFIER" \
        --arg d "$(date +%Y-%m-%d)" --argjson e "$EPOCH" \
        '{_comment:"The live deployment. Scripts reuse it; a fresh one is only deployed with --fresh.",
          network:"Robinhood Chain Testnet", chainId:46630,
          rpc:"https://rpc.testnet.chain.robinhood.com/rpc",
          explorer:"https://explorer.testnet.chain.robinhood.com",
          deployedAt:$d, coordinator:$c, subscription:$s, verifier:$v,
          keyEpoch:$e, threshold:5, operators:9, subscriptionId:1}' > $RECORD
    echo "    recorded in $RECORD"
fi
echo "    verifier     $VERIFIER"
echo "    coordinator  $COORDINATOR"
echo "    subscription $SUBS"

# top up only if the account has run dry, so repeated runs do not drain the key
# Who owns it, before putting anything into it. Funding is open to anyone and
# withdrawal is not, so topping up a subscription owned by someone else is a
# one-way donation — 0.014 ETH went that way once, into subscription 1 of this
# very deployment, which a previous deployer key owns.
SUB_OWNER=$(cast call "$SUBS" "ownerOf(uint256)(address)" 1 --rpc-url $RPC)
if [ "$(echo "$SUB_OWNER" | tr 'A-Z' 'a-z')" != "$(echo "$DEPLOYER" | tr 'A-Z' 'a-z')" ]; then
    echo "!! subscription 1 belongs to $SUB_OWNER, not to $DEPLOYER" >&2
    echo "   funding it would be unrecoverable; deploy fresh or use one you own" >&2
    exit 1
fi

AVAILABLE=$(cast call "$SUBS" "availableOf(uint256)(uint96)" 1 --rpc-url $RPC | awk '{print $1}')
if [ "$AVAILABLE" -lt "$SUB_FUNDING" ]; then
    echo "==> topping the account back up"
    send "$SUBS" "fundSubscriptionWithNative(uint256)" 1 --value $SUB_FUNDING >/dev/null
fi

echo "==> starting $OPERATORS operators"
PEERS=()
for i in $(seq 0 $((OPERATORS - 1))); do PEERS+=("http://127.0.0.1:$((9100 + i))"); done
KEYS=$(cd $DIR/keys && pwd)
for i in $(seq 0 $((OPERATORS - 1))); do
    others=""
    for j in $(seq 0 $((OPERATORS - 1))); do
        [ "$i" = "$j" ] && continue
        others="${others:+$others,}${PEERS[$j]}"
    done
    VRF_ETH_PRIVATE_KEY=$(jq -r ".[$i].private_key" "$KEYS/eth.json") \
    "$BIN/vrfnode" -rpc $RPC -coordinator "$COORDINATOR" \
        -keystore "$KEYS/operator-$i.json" \
        -listen "127.0.0.1:$((9100 + i))" -peers "$others" \
        -metrics-listen "127.0.0.1:$((9600 + i))" -allow 127.0.0.1/32 \
        -threshold $THRESHOLD -operators $OPERATORS \
        -from-block "$FROM_BLOCK" -poll 300ms -publish-delay 2s \
        > "$LOGS/operator-$i.log" 2>&1 & PIDS+=($!)
done
sleep 6

CHAIN_ID=$(cast chain-id --rpc-url $RPC)
echo "==> $REQUESTS requests"
: > $DIR/latency.txt
for n in $(seq 1 $REQUESTS); do
    NONCE=$(cast call "$COORDINATOR" "nonces(address)(uint256)" "$DEPLOYER" --rpc-url $RPC | awk '{print $1}')
    PACKED="0x$(printf '%s' "${DEPLOYER:2}" | tr 'A-Z' 'a-z')$(printf '%064x' "$NONCE")$(printf '%s' "${COORDINATOR:2}" | tr 'A-Z' 'a-z')$(printf '%064x' "$CHAIN_ID")"
    REQUEST_ID=$(cast keccak "$PACKED")

    START=$(python3 -c 'import time;print(time.time())')
    send "$COORDINATOR" "requestRandomWords((bytes32,uint256,uint16,uint32,uint32,bytes))" \
        "(0x0000000000000000000000000000000000000000000000000000000000000000,1,0,500000,2,0x)" >/dev/null

    FULFILLED=false
    for _ in $(seq 1 300); do
        state=$(cast call "$COORDINATOR" "requests(uint256)(address,uint256,uint32,uint32,bool,bool,bool)" \
            "$REQUEST_ID" --rpc-url $RPC | sed -n 5p)
        if [ "$state" = "true" ]; then FULFILLED=true; break; fi
        sleep 0.2
    done
    END=$(python3 -c 'import time;print(time.time())')

    if [ "$FULFILLED" = true ]; then
        python3 -c "print(f'{$END-$START:.3f}')" >> $DIR/latency.txt
        printf "  %2d/%d  %ss\n" "$n" "$REQUESTS" "$(tail -1 $DIR/latency.txt)"
    else
        echo "  $n/$REQUESTS  TIMED OUT ($REQUEST_ID)"
    fi
done

echo
echo "==> latency, request submitted -> fulfilled, seconds"
python3 - <<'PY'
import statistics
xs = sorted(float(x) for x in open('.testnet/latency.txt') if x.strip())
if not xs:
    raise SystemExit('no samples')
def pct(p):
    return xs[min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1))))]
print(f"    samples {len(xs)}  min {xs[0]:.2f}  P50 {pct(50):.2f}  "
      f"P95 {pct(95):.2f}  P99 {pct(99):.2f}  max {xs[-1]:.2f}  mean {statistics.mean(xs):.2f}")
PY
echo
echo "==> who published"
grep -h "msg=published" "$LOGS"/*.log | sed 's/.*operator=\([0-9]*\).*/operator \1/' | sort | uniq -c
echo "    deployer balance now $(cast from-wei "$(cast balance $DEPLOYER --rpc-url $RPC)") ETH"
echo "    contracts: verifier $VERIFIER  coordinator $COORDINATOR"
