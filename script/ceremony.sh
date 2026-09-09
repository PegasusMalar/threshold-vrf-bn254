#!/usr/bin/env bash
# Runs a key ceremony across the operator fleet.
#
#   EPOCH=1 ./script/ceremony.sh
#
# This is the difference between a threshold key and a key that merely has
# shares. `vrfdkg` builds both in one process, which means one machine held the
# whole secret for an instant — and no amount of resharing afterwards changes
# which secret it is. Here every operator generates its own identity on its own
# server, the private half never leaves that server, and the share the ceremony
# produces is written there and read back by nobody.
#
# What this orchestrator sees is only what is meant to be public: each
# operator's identity public key, and the group public key each one prints at
# the end. It compares those nine and refuses to record anything unless all
# nine agree — a ceremony that did not converge produces different groups per
# operator, silently, and that is the failure to catch.
#
# Honest about its own limit: one person holding SSH to all nine servers is not
# nine independent parties, whatever the protocol guarantees. What this buys is
# the cryptographic property — no process ever held the whole secret — not the
# trust property. Real independence needs real operators.
set -euo pipefail
cd "$(dirname "$0")/.."

FLEET=${FLEET:-deployments/operators.json}
EPOCH=${EPOCH:-1}
THRESHOLD=${THRESHOLD:-5}
PORT=${PORT:-8090}
PHASE=${PHASE:-30s}
TIMEOUT=${TIMEOUT:-10m}
OUT=${OUT:-.mainnet}

die () { echo "!! $*" >&2; exit 1; }
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20"

[ -f "$FLEET" ] || die "no $FLEET"
INDICES=$(jq -r '.operators | sort_by(.index)[] | .index' "$FLEET")
COUNT=$(jq -r '.operators | length' "$FLEET")
[ "$COUNT" -ge "$THRESHOLD" ] || die "$COUNT operators cannot run a $THRESHOLD-of-n ceremony"
mkdir -p "$OUT"
[ -f "$OUT/ceremony.json" ] && die "$OUT/ceremony.json exists — a ceremony has already been run.
   Move it aside deliberately; re-running produces a different key and every
   share already on a server becomes useless."

target () { jq -r --argjson i "$1" '.operators[] | select(.index==$i) | .ssh' "$FLEET"; }
host ()   { jq -r --argjson i "$1" '.operators[] | select(.index==$i) | .host' "$FLEET"; }

echo "==> building vrfceremony for linux/amd64"
BIN=$(mktemp -d); trap 'rm -rf "$BIN"' EXIT
(cd node && GOOS=linux GOARCH=amd64 go build -trimpath -o "$BIN/vrfceremony" ./cmd/vrfceremony) \
    || die "build failed"

echo "==> staging on $COUNT servers"
for i in $INDICES; do
    t=$(target "$i")
    $SSH "$t" 'rm -rf /tmp/vrf-ceremony && mkdir -p /tmp/vrf-ceremony && chmod 700 /tmp/vrf-ceremony'
    scp -q "$BIN/vrfceremony" "$t:/tmp/vrf-ceremony/"
    printf '  %s ' "$i"
done
echo

# Phase 1 — identities. Generated on the server that will use them, and the
# private half is never asked for. Only the public line comes back.
echo "==> identities"
MEMBERS="[]"
for i in $INDICES; do
    t=$(target "$i"); h=$(host "$i")
    $SSH "$t" "cd /tmp/vrf-ceremony && ./vrfceremony -generate-identity -identity identity.json -index $i >/dev/null 2>&1"
    pub=$($SSH "$t" "jq -r .public /tmp/vrf-ceremony/identity.json")
    [ -n "$pub" ] || die "operator $i produced no identity"
    MEMBERS=$(jq -c --argjson i "$i" --arg p "$pub" --arg u "http://$h:$PORT" \
        '. + [{index:$i, public:$p, url:$u}]' <<<"$MEMBERS")
    printf '  %s %s…\n' "$i" "${pub:0:18}"
done

jq -n --argjson e "$EPOCH" --argjson t "$THRESHOLD" --argjson m "$MEMBERS" \
    '{epoch:$e, threshold:$t, members:$m}' > "$OUT/ceremony.json"
echo "==> $OUT/ceremony.json  ($THRESHOLD of $COUNT, epoch $EPOCH)"

# Phase 2 — the ceremony itself. Every participant needs the same config
# verbatim: any disagreement changes the session nonce and the run fails rather
# than quietly producing two groups.
echo "==> distributing the configuration"
for i in $INDICES; do
    scp -q "$OUT/ceremony.json" "$(target "$i"):/tmp/vrf-ceremony/ceremony.json"
done

# A passphrase per operator, generated on its own server and left there. It
# protects a share that is already only on that machine, so bringing it here
# would widen the blast radius for nothing. Losing a server loses that share,
# which is what 5-of-9 is for.
echo "==> running, all $COUNT at once"
for i in $INDICES; do
    t=$(target "$i")
    $SSH -n "$t" "cd /tmp/vrf-ceremony && \
        (umask 077; test -f passphrase || openssl rand -base64 32 > passphrase) && \
        VRF_KEYSTORE_PASSPHRASE=\$(cat passphrase) \
        nohup ./vrfceremony -config ceremony.json -identity identity.json \
            -index $i -listen 0.0.0.0:$PORT -out keystore.json \
            -phase $PHASE -timeout $TIMEOUT > ceremony.log 2>&1 &" &
done
wait
echo "    started; waiting for all $COUNT to finish"

for attempt in $(seq 1 60); do
    done_count=0
    for i in $INDICES; do
        $SSH "$(target "$i")" 'test -f /tmp/vrf-ceremony/keystore.json' 2>/dev/null && done_count=$((done_count + 1))
    done
    echo "    $done_count/$COUNT have a share"
    [ "$done_count" -eq "$COUNT" ] && break
    sleep 10
done
[ "$done_count" -eq "$COUNT" ] || die "only $done_count of $COUNT finished — see /tmp/vrf-ceremony/ceremony.log on the stragglers"

# Phase 3 — the check that matters. Nine operators that did not converge each
# hold a share of a different group, and every one of them thinks it succeeded.
echo "==> comparing the group key each operator printed"
KEYS=""
for i in $INDICES; do
    k=$($SSH "$(target "$i")" "grep -A1 'group public key' /tmp/vrf-ceremony/ceremony.log | tail -1 | tr -d ' '")
    [ -n "$k" ] || die "operator $i printed no group key"
    printf '  %s %s\n' "$i" "$k"
    KEYS="$KEYS$k\n"
done
UNIQUE=$(printf "$KEYS" | sort -u | grep -c . || true)
[ "$UNIQUE" = "1" ] || die "the operators printed $UNIQUE different group keys — the ceremony did not
   converge and nothing here may be deployed"

GROUP=$(printf "$KEYS" | head -1)
echo
echo "==> all $COUNT agree"
echo "    $GROUP"
printf '%s\n' "$GROUP" > "$OUT/group-key.txt"
echo "    recorded in $OUT/group-key.txt"
echo
echo "next:  VRF_GROUP_KEY='<the array part>' VRF_EPOCH=$EPOCH ./script/mainnet.sh"
