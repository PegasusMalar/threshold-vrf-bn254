#!/usr/bin/env bash
# Puts the operator status host on one server, behind a Cloudflare tunnel.
#
#   HOSTNAME=status.rh-vrf.com ./script/deploy-status.sh <operator-index-of-host>
#
# What this serves is a directory and a proxy, not an aggregator: it hands the
# browser nine addresses and forwards each one unchanged. The comparing happens
# in the visitor's browser, because a service that averaged the nine would be
# one source again, and one source is the thing the page argues against.
#
# It needs to be reachable over HTTPS — the site is served over HTTPS and a
# browser will not let it read plain-HTTP endpoints — and the nodes speak plain
# HTTP on port 9600. That gap is what the tunnel closes. It also means the
# status host is the one part of this that must not live on a laptop.
set -euo pipefail
cd "$(dirname "$0")/.."

FLEET=${FLEET:-deployments/operators.json}
TUNNEL=${TUNNEL:-vrf-status}
HOSTNAME=${HOSTNAME:-status.rh-vrf.com}
CRED_DIR=${CRED_DIR:-$HOME/.cloudflared}
PORT=${PORT:-9700}

die () { echo "!! $*" >&2; exit 1; }
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20"

INDEX=${1:-}
[ -n "$INDEX" ] || die "usage: HOSTNAME=… $0 <operator-index whose server hosts this>"
[ -f "$FLEET" ] || die "no $FLEET"

TARGET=$(jq -r --argjson i "$INDEX" '.operators[] | select(.index==$i) | .ssh' "$FLEET")
[ -n "$TARGET" ] || die "operator $INDEX is not in $FLEET"

METRICS_PORT=$(jq -r '.metricsPort // 9600' "$FLEET")
# Every node in the fleet, in index order: the directory the page reads is
# derived from the same file the nodes were deployed from, so it cannot list a
# host that was never deployed or miss one that was.
UPSTREAMS=$(jq -r --argjson p "$METRICS_PORT" \
    '[.operators | sort_by(.index)[] | "http://" + .host + ":" + ($p|tostring) + "/metrics"] | join(",")' \
    "$FLEET")
COUNT=$(jq -r '.operators | length' "$FLEET")
echo "==> $COUNT upstreams"

TUNNEL_ID=$(cloudflared --config /dev/null tunnel list --output json 2>/dev/null \
    | jq -r --arg n "$TUNNEL" '.[] | select(.name==$n) | .id')
[ -n "$TUNNEL_ID" ] || die "no Cloudflare tunnel named $TUNNEL — create it with:
   cloudflared tunnel create $TUNNEL"
CRED="$CRED_DIR/$TUNNEL_ID.json"
[ -f "$CRED" ] || die "no credentials at $CRED"
echo "==> tunnel $TUNNEL ($TUNNEL_ID) -> $HOSTNAME"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "==> building vrfstatus for linux/amd64"
(cd node && GOOS=linux GOARCH=amd64 go build -trimpath -o "$STAGE/vrfstatus" ./cmd/vrfstatus) \
    || die "build failed"

cp "$CRED" "$STAGE/tunnel.json"
cat > "$STAGE/tunnel.yml" <<YAML
tunnel: $TUNNEL_ID
credentials-file: /etc/vrfstatus/tunnel.json
# No ingress beyond the one hostname: this tunnel reaches exactly one local
# port and answers 404 to anything else that arrives through it.
ingress:
  - hostname: $HOSTNAME
    service: http://127.0.0.1:$PORT
  - service: http_status:404
YAML

cat > "$STAGE/install.sh" <<'INSTALL'
#!/usr/bin/env bash
set -euo pipefail
STAGE=/tmp/vrf-status-install
id -u vrfstatus >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin vrfstatus
install -d -m 755 /etc/vrfstatus
install -m 755 "$STAGE/vrfstatus" /usr/local/bin/vrfstatus
install -m 640 -o root -g vrfstatus "$STAGE/tunnel.json" /etc/vrfstatus/tunnel.json
install -m 644 "$STAGE/tunnel.yml" /etc/vrfstatus/tunnel.yml
. "$STAGE/config.env"

if ! command -v cloudflared >/dev/null; then
    arch=$(dpkg --print-architecture)
    curl -fsSL -o /tmp/cloudflared.deb \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.deb"
    dpkg -i /tmp/cloudflared.deb
fi

cat > /etc/systemd/system/vrfstatus.service <<UNIT
[Unit]
Description=VRF operator status host
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
User=vrfstatus
ExecStart=/usr/local/bin/vrfstatus -listen 127.0.0.1:$PORT -upstreams $UPSTREAMS
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/vrfstatus-tunnel.service <<UNIT
[Unit]
Description=Cloudflare tunnel for the VRF status host
After=network-online.target vrfstatus.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
User=vrfstatus
ExecStart=/usr/bin/cloudflared --no-autoupdate --config /etc/vrfstatus/tunnel.yml tunnel run
Restart=always
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now vrfstatus vrfstatus-tunnel
systemctl restart vrfstatus vrfstatus-tunnel
sleep 3
systemctl is-active vrfstatus vrfstatus-tunnel
INSTALL

cat > "$STAGE/config.env" <<ENV
PORT=$PORT
UPSTREAMS=$UPSTREAMS
ENV

echo "==> copying to $TARGET"
$SSH "$TARGET" 'rm -rf /tmp/vrf-status-install && mkdir -p /tmp/vrf-status-install && chmod 700 /tmp/vrf-status-install'
scp -q -o StrictHostKeyChecking=accept-new "$STAGE"/* "$TARGET:/tmp/vrf-status-install/"

echo "==> installing"
$SSH "$TARGET" 'sudo -n bash /tmp/vrf-status-install/install.sh' || die "install failed on $TARGET"
$SSH "$TARGET" 'rm -rf /tmp/vrf-status-install'

echo
echo "==> point DNS at it (once):"
echo "     cloudflared --config /dev/null tunnel route dns $TUNNEL $HOSTNAME"
echo "==> then check:  curl -s https://$HOSTNAME/operators.json"
