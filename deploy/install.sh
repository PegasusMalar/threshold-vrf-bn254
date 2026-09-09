#!/usr/bin/env bash
# Runs ON the operator's server. Idempotent: safe to re-run for an upgrade.
#
# Everything it needs is already in /tmp/vrf-install by the time it runs —
# script/deploy-node.sh puts it there. Nothing is fetched from the network, so
# a box with no outbound access except the chain RPC is fine.
set -euo pipefail

STAGE=/tmp/vrf-install
USER_NAME=vrf
BIN=/usr/local/bin/vrfnode
CONF_DIR=/etc/vrfnode
KEY_DIR=/var/lib/vrfnode
UNIT=/etc/systemd/system/vrfnode.service

[ "$(id -u)" = "0" ] || { echo "run as root" >&2; exit 1; }
[ -d "$STAGE" ] || { echo "no $STAGE — deploy-node.sh should have created it" >&2; exit 1; }
. "$STAGE/config.env"

# A system account with no shell and no home: the node reads one file and opens
# two ports, and there is no reason for anything logged in as it to do more.
id -u "$USER_NAME" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$USER_NAME"

install -d -m 755 "$CONF_DIR"
install -d -m 750 -o "$USER_NAME" -g "$USER_NAME" "$KEY_DIR"

install -m 755 "$STAGE/vrfnode" "$BIN"
install -m 640 -o root -g "$USER_NAME" "$STAGE/keystore.json" "$KEY_DIR/keystore.json"

# Read by systemd as root before it drops to the vrf user, so the account the
# node runs as cannot read its own secrets off disk.
install -m 600 -o root -g root "$STAGE/secrets.env" "$CONF_DIR/secrets.env"

# Assembled as one line rather than a continuation block, because an empty value
# must not reach the command line at all: Go's flag package takes the next
# argument as the value, then stops parsing at the first non-flag word it meets.
# A blank -peers therefore swallows -allow and everything after it silently
# reverts to defaults, while ps still shows the flags as though they applied.
ARGS="-rpc $RPC_URL -coordinator $COORDINATOR -keystore $KEY_DIR/keystore.json"
ARGS="$ARGS -listen $SHARE_LISTEN -metrics-listen $METRICS_LISTEN"
# The explicit return matters: under set -e a function whose last command is a
# false test returns non-zero and takes the whole script down with it, leaving
# the previous unit in place and nothing on stdout to say why.
add () { [ -n "$2" ] && ARGS="$ARGS $1 $2"; return 0; }
add -peers "$PEERS"
add -allow "$ALLOW"

# Every flag goes through the same guard: one whose value came out empty is left
# off entirely rather than emitted bare.
add -threshold "$THRESHOLD"
add -operators "$OPERATORS"
add -lookback "$LOOKBACK"
add -poll "$POLL"
add -max-log-range "$MAX_LOG_RANGE"
add -log-chunk-pause "$LOG_CHUNK_PAUSE"
add -publish-delay "$PUBLISH_DELAY"
add -share-rate "$SHARE_RATE"
add -ws "$WS_URL"

cat > "$UNIT" <<UNITFILE
[Unit]
Description=Threshold VRF operator $OPERATOR_INDEX
Documentation=https://github.com/robinhood-chain/vrf
# The node reads the chain the moment it starts, so waiting for a routable
# address rather than merely a configured one saves a restart on every boot.
After=network-online.target
Wants=network-online.target
# A node that cannot start is usually misconfigured, not unlucky. Without this
# systemd gives up after five tries and the operator silently leaves the group.
StartLimitIntervalSec=0

[Service]
Type=simple
User=$USER_NAME
Group=$USER_NAME
EnvironmentFile=$CONF_DIR/secrets.env
ExecStart=$BIN $ARGS

Restart=always
RestartSec=5

# It reads one file and opens two sockets. Nothing else should be reachable.
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictNamespaces=yes
LockPersonality=yes
RestrictAddressFamilies=AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
UNITFILE

chmod 644 "$UNIT"
systemctl daemon-reload
systemctl enable vrfnode >/dev/null
systemctl restart vrfnode

rm -rf "$STAGE"

sleep 2
if systemctl is-active --quiet vrfnode; then
    echo "operator $OPERATOR_INDEX is up"
    echo "  shares   $SHARE_LISTEN   (only the other operators need to reach this)"
    echo "  metrics  $METRICS_LISTEN (leave this one open: it is how the group is checked from outside)"
    echo "  logs     journalctl -u vrfnode -f"
else
    echo "vrfnode did not stay up:" >&2
    journalctl -u vrfnode -n 20 --no-pager >&2
    exit 1
fi
