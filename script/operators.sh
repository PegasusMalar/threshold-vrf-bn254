#!/usr/bin/env bash
# Runs the operator set as a permanent local service.
#
#   ./script/operators.sh install    copy keys and binary out of the repo, write launchd jobs
#   ./script/operators.sh start      bring them up (and on every login)
#   ./script/operators.sh stop       take them down
#   ./script/operators.sh status     who is up, how far behind, how much gas is left
#   ./script/operators.sh logs [n]   follow one operator, or all
#   ./script/operators.sh fund       top the publisher keys back up from the deployer
#   ./script/operators.sh share      publish the metrics on a public URL
#   ./script/operators.sh unshare    take that URL down
#
# This is a single-machine setup for testing: nine processes, nine keys, one
# host. It is NOT the production shape — there the whole point is that the nine
# operators are nine independent organisations on nine machines, and no one of
# them can be told what to sign.
set -uo pipefail
cd "$(dirname "$0")/.."

HOME_DIR="$HOME/.vrf-operators"
BIN="$HOME_DIR/bin/vrfnode"
KEYS="$HOME_DIR/keys"
LOGS="$HOME_DIR/logs"
AGENTS="$HOME/Library/LaunchAgents"
LABEL=com.vrf.operator
RECORD=deployments/testnet.json

OPERATORS=9
THRESHOLD=5
# One public RPC endpoint serves all nine operators, so the baseline is nine
# times whatever this is. At 1s the endpoint starts answering 429, and a node
# that cannot ask "is this request still open?" falls through to publishing it
# anyway — which asks the endpoint even more. Keep it slack.
POLL=${POLL:-3s}
# Re-scanned from scratch every time a node restarts, and launchd restarts them
# on every boot. Passed as -lookback rather than a fixed -from-block so the
# window is measured from the head at startup: a machine that was off for a day
# otherwise wakes up and re-grinds a day of already-settled requests.
LOOKBACK=${LOOKBACK:-2000}
SHARE_PORT_BASE=9100
METRICS_PORT_BASE=9600
STATUS_PORT=9700
# Requested from localtunnel when the other two fail. A fixed name means the
# frontend does not have to be handed a new address after every restart.
LT_SUBDOMAIN=${LT_SUBDOMAIN:-rh-vrf-status}
PASSPHRASE=${VRF_KEYSTORE_PASSPHRASE:-testnet}

RPC=$(jq -r '.rpc' $RECORD)
COORDINATOR=$(jq -r '.coordinator' $RECORD)

die () { echo "!! $*" >&2; exit 1; }

peers_for () { # index -> comma-separated peer urls
    local self=$1 out=""
    for j in $(seq 0 $((OPERATORS - 1))); do
        [ "$j" = "$self" ] && continue
        out="${out:+$out,}http://127.0.0.1:$((SHARE_PORT_BASE + j))"
    done
    echo "$out"
}

cmd_install () {
    [ -f .testnet/keys/eth.json ] || die "no .testnet/keys — run script/testnet.sh --fresh first"
    ls .testnet/keys/operator-*.json >/dev/null 2>&1 || die "no operator keystores in .testnet/keys"

    mkdir -p "$HOME_DIR/bin" "$KEYS" "$LOGS" "$AGENTS"
    (cd node && go build -o "$BIN" ./cmd/vrfnode) || die "build failed"
    cp .testnet/keys/operator-*.json .testnet/keys/eth.json "$KEYS"/
    cp $RECORD "$HOME_DIR/deployment.json"
    chmod 700 "$KEYS"; chmod 600 "$KEYS"/*

    for i in $(seq 0 $((OPERATORS - 1))); do
        local key; key=$(jq -r ".[$i].private_key" "$KEYS/eth.json")
        cat > "$AGENTS/$LABEL.$i.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL.$i</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <string>-rpc</string><string>$RPC</string>
    <string>-coordinator</string><string>$COORDINATOR</string>
    <string>-keystore</string><string>$KEYS/operator-$i.json</string>
    <string>-listen</string><string>127.0.0.1:$((SHARE_PORT_BASE + i))</string>
    <string>-metrics-listen</string><string>127.0.0.1:$((METRICS_PORT_BASE + i))</string>
    <string>-peers</string><string>$(peers_for "$i")</string>
    <string>-allow</string><string>127.0.0.1/32</string>
    <string>-threshold</string><string>$THRESHOLD</string>
    <string>-operators</string><string>$OPERATORS</string>
    <string>-lookback</string><string>$LOOKBACK</string>
    <string>-poll</string><string>$POLL</string>
    <string>-publish-delay</string><string>2s</string>
    <!-- A share a peer refused is otherwise lost for good, and that request can
         never reach a quorum. Under burst load that is the common case. -->
    <!-- A refusal from the endpoint is not another operator winning the race:
         nobody published it, so giving up there strands the request. -->
    <string>-send-retry</string><string>2s</string>
    <string>-send-retries</string><string>3</string>
    <string>-rebroadcast</string><string>2s</string>
    <string>-rebroadcast-attempts</string><string>5</string>
    <!-- Sized for a burst: one transaction can open fifty requests at once and
         every peer then sends fifty shares back to back. -->
    <string>-share-rate</string><string>500</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>VRF_KEYSTORE_PASSPHRASE</key><string>$PASSPHRASE</string>
    <key>VRF_ETH_PRIVATE_KEY</key><string>$key</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOGS/operator-$i.log</string>
  <key>StandardErrorPath</key><string>$LOGS/operator-$i.log</string>
</dict>
</plist>
PLIST
        chmod 600 "$AGENTS/$LABEL.$i.plist"
    done

    echo "installed $OPERATORS operators in $HOME_DIR"
    echo "  coordinator $COORDINATOR"
    echo "  scanning the last $LOOKBACK blocks at each start"
    echo
    echo "The keystore passphrase and the publishing keys sit in plain text inside"
    echo "$AGENTS/$LABEL.*.plist (mode 600). Fine for testnet keys that hold"
    echo "fractions of a cent; do not reuse this shape for anything that matters."
    echo
    echo "now: ./script/operators.sh start"
}

cmd_start () {
    for i in $(seq 0 $((OPERATORS - 1))); do
        launchctl unload "$AGENTS/$LABEL.$i.plist" 2>/dev/null
        launchctl load "$AGENTS/$LABEL.$i.plist" || die "could not load operator $i"
    done
    sleep 3
    echo "started"; cmd_status
}

cmd_stop () {
    for i in $(seq 0 $((OPERATORS - 1))); do
        launchctl unload "$AGENTS/$LABEL.$i.plist" 2>/dev/null
    done
    echo "stopped"
}

cmd_status () {
    local head; head=$(cast block-number --rpc-url "$RPC" 2>/dev/null || echo 0)
    echo "chain head $head, coordinator $COORDINATOR"
    printf "  %-3s %-6s %-11s %-9s %s\n" "id" "up" "behind" "gas(ETH)" "published/lost"
    for i in $(seq 0 $((OPERATORS - 1))); do
        local port=$((METRICS_PORT_BASE + i)) up="no" behind="-" pub="-" lost="-"
        local m; m=$(curl -s --max-time 2 "http://127.0.0.1:$port/metrics" 2>/dev/null)
        if [ -n "$m" ]; then
            up="yes"
            local seen; seen=$(echo "$m" | awk '/^vrf_last_seen_block /{print $2}')
            # the chain moves between the two reads, so a small negative is
            # noise, not a node running ahead of the network
            [ -n "$seen" ] && { behind=$((head - seen)); [ "$behind" -lt 0 ] && behind=0; }
            pub=$(echo "$m" | awk '/^vrf_fulfilments_published_total /{print $2}')
            lost=$(echo "$m" | awk '/^vrf_fulfilments_lost_total /{print $2}')
        fi
        local addr; addr=$(jq -r ".[$i].address" "$KEYS/eth.json" 2>/dev/null)
        local bal="-"
        [ -n "$addr" ] && bal=$(cast from-wei "$(cast balance "$addr" --rpc-url "$RPC" 2>/dev/null || echo 0)" | cut -c1-8)
        printf "  %-3s %-6s %-11s %-9s %s/%s\n" "$i" "$up" "$behind" "$bal" "$pub" "$lost"
    done
}

# Everything the operators run binds to 127.0.0.1: the share ports, the metrics,
# all of it. `share` puts a tunnel in front of one read-only process — never in
# front of the machine — so what reaches the internet is counters and nothing
# else. The share ports, the keystores and the publishing keys stay unreachable.
cmd_share () {
    pkill -f "vrfstatus -listen" 2>/dev/null
    pkill -f "ngrok http $STATUS_PORT" 2>/dev/null
    pkill -f "cloudflared tunnel --url http://127.0.0.1:$STATUS_PORT" 2>/dev/null
    pkill -f "localtunnel --port $STATUS_PORT" 2>/dev/null
    sleep 1

    (cd node && go build -o "$HOME_DIR/bin/vrfstatus" ./cmd/vrfstatus) || die "build failed"
    "$HOME_DIR/bin/vrfstatus" -operators $OPERATORS -metrics-base $METRICS_PORT_BASE \
        -listen "127.0.0.1:$STATUS_PORT" >> "$LOGS/status.log" 2>&1 &
    sleep 2
    curl -sf "http://127.0.0.1:$STATUS_PORT/healthz" >/dev/null || die "the status endpoint did not come up"

    local url=""
    if command -v ngrok >/dev/null && ngrok config check >/dev/null 2>&1; then
        ngrok http $STATUS_PORT --log stdout > "$LOGS/tunnel.log" 2>&1 &
        # A URL is not the same as a working route: ngrok hands one out and can
        # still refuse the traffic, so it counts only once it answers.
        for _ in $(seq 1 20); do
            local candidate
            candidate=$(curl -s --max-time 3 http://127.0.0.1:4040/api/tunnels 2>/dev/null \
                | jq -r '.tunnels[0].public_url // empty')
            if [ -n "$candidate" ] && curl -sf --max-time 5 "$candidate/healthz" >/dev/null 2>&1; then
                url=$candidate; break
            fi
            sleep 1
        done
        [ -n "$url" ] || { echo "ngrok gave no working route, trying cloudflared"; pkill -f "ngrok http $STATUS_PORT" 2>/dev/null; }
    fi
    if [ -z "$url" ] && command -v cloudflared >/dev/null; then
        # Quick tunnels hand out a hostname before the route is live, and on some
        # networks the route never comes up at all — so the URL is only accepted
        # once it actually answers.
        # --config on purpose: without it cloudflared picks up ~/.cloudflared/
        # config.yml, registers as whatever named tunnel is described there, and
        # the quick hostname is never bound — which looks exactly like "the
        # tunnel is broken" and cost an afternoon to find.
        echo "{}" > "$HOME_DIR/cloudflared-empty.yml"
        cloudflared --config "$HOME_DIR/cloudflared-empty.yml" \
            tunnel --url "http://127.0.0.1:$STATUS_PORT" --no-autoupdate \
            > "$LOGS/tunnel.log" 2>&1 &
        for _ in $(seq 1 30); do
            local candidate
            candidate=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOGS/tunnel.log" | head -1)
            if [ -n "$candidate" ] && curl -sf --max-time 5 "$candidate/healthz" >/dev/null 2>&1; then
                url=$candidate; break
            fi
            sleep 2
        done
    fi
    # localtunnel last: no account, no quota, and it will hand out the same
    # hostname every time if it is free — which matters more than it sounds,
    # because the frontend has to be told the address by hand otherwise.
    if [ -z "$url" ] && command -v npx >/dev/null; then
        npx -y localtunnel --port $STATUS_PORT --subdomain "$LT_SUBDOMAIN" \
            > "$LOGS/tunnel.log" 2>&1 &
        for _ in $(seq 1 20); do
            local candidate
            candidate=$(grep -oE 'https://[a-z0-9-]+\.loca\.lt' "$LOGS/tunnel.log" | head -1)
            if [ -n "$candidate" ] && curl -sf --max-time 5 "$candidate/healthz" >/dev/null 2>&1; then
                url=$candidate; break
            fi
            sleep 2
        done
    fi
    [ -n "$url" ] || die "no tunnel came up; see $LOGS/tunnel.log"

    curl -sf --max-time 10 "$url/healthz" >/dev/null || die "$url does not answer; see $LOGS/tunnel.log"

    echo
    echo "  $url"
    echo
    echo "  $url/operators.json    what is available"
    echo "  $url/op/0/metrics      one operator, Prometheus text"
    echo "  $url/status.json       all nine at once, answers kept apart"
    echo
    echo "Read-only, GET only, CORS open — a browser can query it directly."
    echo "$url" > "$HOME_DIR/tunnel-url.txt"
    echo
    echo "./script/operators.sh unshare  to take it down"
}

cmd_unshare () {
    pkill -f "ngrok http $STATUS_PORT" 2>/dev/null
    pkill -f "cloudflared tunnel --url http://127.0.0.1:$STATUS_PORT" 2>/dev/null
    pkill -f "localtunnel --port $STATUS_PORT" 2>/dev/null
    pkill -f "vrfstatus -listen" 2>/dev/null
    rm -f "$HOME_DIR/tunnel-url.txt"
    echo "the public URL is down; the operators keep running"
}

cmd_logs () {
    if [ $# -gt 0 ]; then tail -f "$LOGS/operator-$1.log"; else tail -f "$LOGS"/*.log; fi
}

cmd_fund () {
    : "${VRF_DEPLOYER_KEY:?set VRF_DEPLOYER_KEY}"
    local amount=${1:-100000000000000}   # 0.0001 ETH
    for i in $(seq 0 $((OPERATORS - 1))); do
        local addr; addr=$(jq -r ".[$i].address" "$KEYS/eth.json")
        cast send --rpc-url "$RPC" --private-key "$VRF_DEPLOYER_KEY" \
            --value "$amount" "$addr" >/dev/null && echo "  funded operator $i"
    done
}

case "${1:-status}" in
    install) cmd_install ;;
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    status)  cmd_status ;;
    logs)    shift; cmd_logs "$@" ;;
    fund)    shift; cmd_fund "$@" ;;
    share)   cmd_share ;;
    unshare) cmd_unshare ;;
    *)       die "usage: $0 {install|start|stop|status|logs|fund|share|unshare}" ;;
esac
