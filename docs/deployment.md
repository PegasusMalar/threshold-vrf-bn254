# Deploying an operator on a server

One operator, one server. Everything needed for that lives in `deploy/` and
`script/deploy-node.sh`.

## Why bother

Today the nine nodes live on one machine and talk to one public RPC. The shared
endpoint was the cause of nearly every failure in the load test — which means
all the current numbers describe the endpoint, not us. Until the nodes spread
out, no SLA can be promised.

## The server

Measured on a running node: **9 MB RSS, ~0% CPU**. It does almost nothing —
signing a share takes 97 microseconds, verifying someone else's takes 1.6 ms.

| | Minimum | Comfortable |
|---|---|---|
| CPU / RAM | 1 vCPU / 1 GB | 2 vCPU / 2 GB |
| Disk | 10 GB | 20 GB SSD |
| Network | static IP, two inbound ports | |
| Time | NTP required | |

Around €4–6 a month. The bottleneck is uptime, not horsepower.

**There is no on-disk state.** Sessions live in memory; there is no database.
The one thing a node must survive is the keystore holding its share. The server
can be destroyed and rebuilt in a minute, as long as the share is backed up.

If an operator runs **its own Nitro node** instead of a public RPC, that is a
separate machine of a different class: 4–8 vCPU, 16 GB, NVMe from 500 GB and
growing. Not needed for the first stage.

## RPC

Checked 2026-09-01 on testnet:

| | `eth_getLogs` over 2000 blocks | 30 consecutive requests |
|---|---|---|
| `robinhood-sepolia-rpc.publicnode.com` | **0.12 s** | 30/30 |
| `rpc.testnet.chain.robinhood.com` | 0.28 s | 30/30 |

For mainnet: `robinhood-rpc.publicnode.com` and
`rpc.mainnet.chain.robinhood.com`; both also offer WebSocket.

**Alchemy will not work**, and the reason is not the plan: Robinhood Chain is an
Orbit network with its own sequencer, and providers support a fixed list of
networks. No registry lists an Alchemy endpoint for 4663 or 46630.

**Different operators, different RPCs.** This is not decoration: nine nodes on
one endpoint is one failure for all of them, and that is exactly what every
load-test finding looked like. Spread them across providers the same way you
spread them across clouds.

## Deployment

Who sits where is described once, in `deployments/operators.json`:

```json
{
  "sharePort": 9100,
  "metricsPort": 9600,
  "operators": [
    { "index": 0, "ssh": "root@203.0.113.4", "host": "203.0.113.4",
      "rpc": "https://your-own-endpoint-for-this-node" }
  ]
}
```

After that, deploying is an index and nothing else:

```sh
export VRF_KEYSTORE_PASSPHRASE=...
./script/deploy-node.sh 0
```

The peer list and the allowed share sources are **derived from that file**
rather than typed out on every run: otherwise they drift out of step with
reality sooner or later, and they drift silently.

Each operator has its own `rpc`. A shared endpoint was the bottleneck in almost
every load-test finding, which is why this field sits at the operator level and
not the network level. If it is omitted, the `rpc` from the deployment record is
used.

### Moving to mainnet

The fleet file is not touched for this — only the network record and the keys
that came out of the real ceremony change:

```sh
RECORD=deployments/mainnet.json KEYS=.mainnet/keys ./script/deploy-node.sh 0
```

What happens: the script asks the server for its architecture, cross-compiles a
static binary for it, copies that along with the keystore and the secrets,
installs a systemd unit and starts it. Then it checks that the metrics answer
from outside.

Running it again is an upgrade: the binary is replaced, the service is
restarted, nothing else is touched.

Parameters are overridden through the environment: `SHARE_PORT`,
`METRICS_PORT`, `THRESHOLD`, `OPERATORS`, `POLL`, `LOOKBACK`, `ALLOW`,
`RECORD`, `KEYS`.

## What ends up on the server

```
/usr/local/bin/vrfnode          static binary, no dependencies
/var/lib/vrfnode/keystore.json  the share, 640 root:vrf
/etc/vrfnode/secrets.env        keystore password and publishing key, 600 root:root
/etc/systemd/system/vrfnode.service
```

The service runs as the system user `vrf`, with no shell and no home directory.
systemd reads `secrets.env` **before** it drops privileges, so the account the
node runs under cannot read its own secrets off disk.

The unit forbids privilege escalation, mounts the system read-only, hides
`/home`, gives it a private `/tmp`, and allows only IPv4/IPv6 sockets. A
rendered example is in `deploy/vrfnode.service.example`.

Logs go to journald: `journalctl -u vrfnode -f`. No rotation needed.

## Ports

| Port | Who connects | Firewall |
|---|---|---|
| 9100 | other operators only | **narrow to the eight addresses** |
| 9600 | anyone, including a browser | **leave open** |

The second is open deliberately: it is the only way to check the group from
outside, and there is nothing there but counters.

Once the nine addresses are known, narrow share intake twice — at the
provider's firewall and with the node's own flag:

```sh
ALLOW=203.0.113.4,198.51.100.7,... ./script/deploy-node.sh root@... 3 --peers ...
```

While the list is empty the port is protected only by the rate limit (500
shares per second per source) and by the fact that a share cannot be forged —
it is verified against the public key of the share it claims to be.

## Checking after installation

```sh
systemctl status vrfnode
journalctl -u vrfnode -n 30
curl -s http://<server>:9600/metrics | grep vrf_operator_index
```

What you should see: `vrf_last_seen_block` rising, and
`vrf_shares_received_total` appearing for each peer. If the peer counters are
missing, shares are not arriving — check the firewall and `-peers`.

For the group as a whole, `vrfstatus` polls all nine and answers in one
response — `/operators.json`, `/op/N/metrics` and `/status.json`, GET only,
CORS open.

## What I did not verify

The unit was written to spec but has **never been started on a live Linux** —
the machine it was written on has neither systemd nor containers. Only what can
be checked without them was checked: the scripts are syntactically sound, the
unit renders with all three sections, and the binary cross-compiles statically
and accepts exactly the set of flags the unit passes it.

A first run on a real server may trip over small things — the path to `nologin`
on non-Debian systems, a missing `useradd` on Alpine, a sandbox directive that
is too strict. Diagnose with `journalctl -u vrfnode`.
