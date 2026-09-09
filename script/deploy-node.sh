#!/usr/bin/env bash
# Puts one operator on one Linux server, over SSH.
#
#   ./script/deploy-node.sh <operator-index>
#
# Who sits where, which RPC each one uses and how they reach each other all come
# from deployments/operators.json, so the peer list and the allow-list cannot
# drift out of step with reality by being retyped on every invocation.
#
#   ./script/deploy-node.sh 0
#
# Moving to mainnet does not touch that file: point RECORD at the mainnet record
# and KEYS at the keystores from the real ceremony, and re-run for each index.
#
#   RECORD=deployments/mainnet.json KEYS=.mainnet/keys ./script/deploy-node.sh 0
#
# Re-run it to upgrade: the binary is replaced and the service restarted, and
# nothing else is touched.
set -euo pipefail
cd "$(dirname "$0")/.."

RECORD=${RECORD:-deployments/testnet.json}
FLEET=${FLEET:-deployments/operators.json}
KEYS=${KEYS:-.testnet/keys}
THRESHOLD=${THRESHOLD:-5}
OPERATORS=${OPERATORS:-9}

LOOKBACK=${LOOKBACK:-2000}
POLL=${POLL:-3s}
# Per-operator, because the cap belongs to the endpoint, not to the network.
MAX_LOG_RANGE=${MAX_LOG_RANGE:-0}
LOG_CHUNK_PAUSE=${LOG_CHUNK_PAUSE:-250ms}
PUBLISH_DELAY=${PUBLISH_DELAY:-2s}
SHARE_RATE=${SHARE_RATE:-500}


die () { echo "!! $*" >&2; exit 1; }

# accept-new, not "no": a first contact with a fresh server should not need a
# manual yes, but a key that changes underneath us still stops everything.
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20"

INDEX=${1:-}
[ -n "$INDEX" ] || die "usage: $0 <operator-index>   (see $FLEET)"

[ -f "$RECORD" ] || die "no $RECORD"
[ -f "$FLEET" ] || die "no $FLEET"
COORDINATOR=$(jq -r '.coordinator' "$RECORD")

SHARE_PORT=$(jq -r '.sharePort // 9100' "$FLEET")
METRICS_PORT=$(jq -r '.metricsPort // 9600' "$FLEET")

me () { jq -r --argjson i "$INDEX" '.operators[] | select(.index==$i) | '"$1"' // empty' "$FLEET"; }
TARGET=$(me .ssh)
[ -n "$TARGET" ] || die "operator $INDEX is not described in $FLEET"

# Its own endpoint, falling back to the network-wide one. Nine nodes leaning on
# a single RPC was the bottleneck behind nearly every failure in the load test,
# so this is per-operator on purpose.
RPC=$(me .rpc); [ -n "$RPC" ] || RPC=$(jq -r '.rpc' "$RECORD")

# Endpoint-shaped limits, per operator: the cap belongs to the provider, not to
# the network. Splitting a wide scan to fit a range cap turns it into many small
# calls, so the pause is what keeps that from tripping a rate limit instead.
# Event hints, when the endpoint offers a websocket. Purely an accelerator:
# what a node signs still comes from its own eth_getLogs, so a hint endpoint
# that lies or dies costs latency and nothing else. That is also why it may be
# a different provider from the one doing the finding.
WS_URL=$(me .ws)

v=$(me .maxLogRange);   [ -n "$v" ] && MAX_LOG_RANGE=$v
v=$(me .logChunkPause); [ -n "$v" ] && LOG_CHUNK_PAUSE=$v
v=$(me .lookback);      [ -n "$v" ] && LOOKBACK=$v

# Peers and the allow-list are derived, never typed: every other operator in the
# file, and nothing else.
PEERS=$(jq -r --argjson i "$INDEX" --argjson p "$SHARE_PORT" \
    '[.operators[] | select(.index != $i) | "http://" + .host + ":" + ($p|tostring)] | join(",")' "$FLEET")
ALLOW=$(jq -r --argjson i "$INDEX" \
    '[.operators[] | select(.index != $i) | .host] | join(",")' "$FLEET")
[ -n "$ALLOW" ] || ALLOW=0.0.0.0/0
# Two ways a node can come by its share, and mainnet may only use the second.
#
#   KEYSTORE_ON_SERVER=1  the share was produced on that server by the
#                         ceremony and has never left it. Nothing is shipped,
#                         and the passphrase is read from the server too.
#   otherwise             the share is here and gets copied out. Fine for a
#                         testnet whose key was built in one process anyway;
#                         for mainnet it would put all nine shares on one
#                         laptop, which is the thing the ceremony exists to
#                         prevent.
KEYSTORE_ON_SERVER=${KEYSTORE_ON_SERVER:-0}
if [ "$KEYSTORE_ON_SERVER" = "1" ]; then
    CEREMONY_DIR=${CEREMONY_DIR:-/tmp/vrf-ceremony}
    $SSH "$TARGET" "test -f $CEREMONY_DIR/keystore.json" \
        || die "operator $INDEX has no share at $CEREMONY_DIR/keystore.json on $TARGET"
else
    KEYSTORE="$KEYS/operator-$INDEX.json"
    [ -f "$KEYSTORE" ] || die "no keystore at $KEYSTORE"
    : "${VRF_KEYSTORE_PASSPHRASE:?set VRF_KEYSTORE_PASSPHRASE}"
fi

# The account this operator publishes from. Same choice as the share above,
# for a smaller stake: a leaked publishing key cannot forge randomness — anyone
# may publish a valid fulfilment, that is the design — but it can spend the
# operator's gas and impersonate it in the metrics. On mainnet it is generated
# on the server and only the address comes back.
if [ "$KEYSTORE_ON_SERVER" = "1" ]; then
    ETH_KEY=""
    ADDRESS=$($SSH "$TARGET" 'sudo -n cat /etc/vrfnode/address 2>/dev/null || true')
    if [ -z "$ADDRESS" ]; then
        echo "==> generating a publishing key on $TARGET"
        ADDRESS=$($SSH "$TARGET" 'command -v cast >/dev/null || {
                curl -fsSL https://foundry.paradigm.xyz | bash >/dev/null 2>&1
                ~/.foundry/bin/foundryup >/dev/null 2>&1
            }
            CAST=$(command -v cast || echo ~/.foundry/bin/cast)
            umask 077
            [ -s /tmp/vrf-ethkey.json ] || "$CAST" wallet new --json > /tmp/vrf-ethkey.json
            jq -r "(.data // .) | if type==\"array\" then .[0] else . end | .address" /tmp/vrf-ethkey.json')
        [ -n "$ADDRESS" ] || die "could not generate a publishing key on $TARGET"
    fi
    echo "    publishes from $ADDRESS"
else
    ETH_KEY=$(jq -r ".[$INDEX].private_key" "$KEYS/eth.json")
    [ "$ETH_KEY" != "null" ] || die "no publishing key for operator $INDEX in $KEYS/eth.json"
fi

# Hetzner and friends sell arm64 for less, so ask rather than assume.
ARCH=$($SSH "$TARGET" 'uname -m') || die "cannot reach $TARGET over ssh"
case "$ARCH" in
    x86_64|amd64) GOARCH=amd64 ;;
    aarch64|arm64) GOARCH=arm64 ;;
    *) die "unsupported architecture $ARCH" ;;
esac

echo "==> building for linux/$GOARCH"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
(cd node && GOOS=linux GOARCH=$GOARCH go build -trimpath -o "$STAGE/vrfnode" ./cmd/vrfnode) \
    || die "build failed"

if [ "$KEYSTORE_ON_SERVER" != "1" ]; then
    cp "$KEYSTORE" "$STAGE/keystore.json"
fi
cp deploy/install.sh "$STAGE/install.sh"

# Secrets go in a file, never on a command line: arguments are visible in ps to
# every account on the box, and they end up in shell history on this one.
umask 077
if [ "$KEYSTORE_ON_SERVER" = "1" ]; then
    # Left empty here and filled in on the server: both secrets already exist
    # there — the share's passphrase from the ceremony, the publishing key from
    # the step above — and reading them back to write them out again would put
    # every operator's secret through this machine, which is the whole thing
    # a networked ceremony exists to avoid.
    : > "$STAGE/secrets.env"
else
    cat > "$STAGE/secrets.env" <<ENV
VRF_KEYSTORE_PASSPHRASE=$VRF_KEYSTORE_PASSPHRASE
VRF_ETH_PRIVATE_KEY=$ETH_KEY
ENV
fi
cat > "$STAGE/config.env" <<ENV
OPERATOR_INDEX=$INDEX
RPC_URL=$RPC
COORDINATOR=$COORDINATOR
SHARE_LISTEN=0.0.0.0:$SHARE_PORT
METRICS_LISTEN=0.0.0.0:$METRICS_PORT
PEERS=$PEERS
ALLOW=$ALLOW
THRESHOLD=$THRESHOLD
OPERATORS=$OPERATORS
LOOKBACK=$LOOKBACK
POLL=$POLL
MAX_LOG_RANGE=$MAX_LOG_RANGE
LOG_CHUNK_PAUSE=$LOG_CHUNK_PAUSE
PUBLISH_DELAY=$PUBLISH_DELAY
SHARE_RATE=$SHARE_RATE
WS_URL=$WS_URL
ENV
umask 022

echo "==> copying to $TARGET"
$SSH "$TARGET" 'rm -rf /tmp/vrf-install && mkdir -p /tmp/vrf-install && chmod 700 /tmp/vrf-install'
scp -q -o StrictHostKeyChecking=accept-new "$STAGE"/* "$TARGET:/tmp/vrf-install/"

if [ "$KEYSTORE_ON_SERVER" = "1" ]; then
    echo "==> taking the share the ceremony left on $TARGET"
    # Both secrets are assembled on the server, from files that are already
    # there. Neither passes through this machine.
    $SSH "$TARGET" "cp $CEREMONY_DIR/keystore.json /tmp/vrf-install/keystore.json && \
        printf 'VRF_KEYSTORE_PASSPHRASE=%s\n' \"\$(cat $CEREMONY_DIR/passphrase)\" \
            >> /tmp/vrf-install/secrets.env && \
        if [ -f /tmp/vrf-ethkey.json ]; then
            printf 'VRF_ETH_PRIVATE_KEY=%s\n' \"\$(jq -r '(.data // .) | if type==\"array\" then .[0] else . end | .private_key' /tmp/vrf-ethkey.json)\" \
                >> /tmp/vrf-install/secrets.env
        else
            sudo -n grep '^VRF_ETH_PRIVATE_KEY=' /etc/vrfnode/secrets.env >> /tmp/vrf-install/secrets.env
        fi" \
        || die "could not assemble secrets on $TARGET"
    # Recorded so a re-run finds the same account instead of making a new one.
    $SSH "$TARGET" "sudo -n install -d -m 755 /etc/vrfnode && \
        printf '%s\n' '$ADDRESS' | sudo -n tee /etc/vrfnode/address >/dev/null && \
        rm -f /tmp/vrf-ethkey.json"
fi

echo "==> installing"
# Providers hand out an unprivileged account as often as root, and the installer
# needs root either way.
if $SSH "$TARGET" 'test "$(id -u)" = 0'; then
    $SSH "$TARGET" 'bash /tmp/vrf-install/install.sh'
else
    $SSH "$TARGET" 'sudo -n bash /tmp/vrf-install/install.sh' \
        || die "sudo failed on $TARGET; the account needs passwordless sudo or root"
fi

echo
echo "==> checking it answers"
HOST=${TARGET#*@}
if curl -sf --max-time 10 "http://$HOST:$METRICS_PORT/metrics" | grep -q "vrf_operator_index $INDEX"; then
    echo "  metrics reachable at http://$HOST:$METRICS_PORT/metrics"
else
    echo "  metrics NOT reachable from here — check the provider's firewall for port $METRICS_PORT"
fi
