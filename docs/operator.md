# The operator node

An operator is one `vrfnode` process holding a share of the group key. It
listens to the coordinator, signs the seed with its share, exchanges shares with
the others, and publishes whichever signature it managed to assemble first.

## The aggregation model: every node is its own aggregator

There is no separate aggregator service. Every node broadcasts its share
directly to all the others over HTTP and collects theirs. With nine operators
that is 72 requests per VRF request — nothing.

This gives you the simplicity of an aggregator and the resilience of p2p at
once, without a gossip layer: there is no node whose failure stops the service,
and no node that has to be trusted.

**Shares do not need a separate signature.** A partial signature is verified
against the public key of the share it claims to be, before it enters
aggregation. A share cannot be forged under someone else's index, so TLS and
rate limiting here are about denial of service, not authenticity.

An unverified share must never enter aggregation: it corrupts the result
silently, and the node finds out only after paying for a transaction that
reverts.

### The publication queue

If everyone who assembled a quorum sent a transaction at once, eight of nine
would be paying for a revert. So publication order is deterministic:

```
rank = (operator_index − requestId) mod n
```

Rank 0 publishes immediately; the others wait `rank × publish-delay` and usually
find the request already closed. The leader changes from request to request, so
the gas cost is shared evenly.

This is an optimisation, not a rule: anyone may still publish at any moment,
including the consumer itself.

## The seed comes from the contract, not from the event

The node reads `seedOf(requestId)` and signs only what the contract returned.
The event is a hint; the contract is the authority. A node that signs whatever
it is handed will sign anything for anyone who can reach its inbound port.

## Keys

An operator has two keys, and they are unrelated:

| Key | What it grants | If compromised |
|---|---|---|
| DKG share (`operator-N.json`) | the right to take part in signing | the attacker is one of nine; the threshold still holds |
| ETH key (`VRF_ETH_PRIVATE_KEY`) | the right to pay for publication gas | the balance is lost, and nothing more |

The share is stored encrypted (scrypt + AES-GCM), the file is `0600`, and it is
written through a temporary file and renamed — a crash mid-write cannot leave
half a share behind.

## Two ports, with different purposes

| Port | Who connects | Can it be firewalled off |
|---|---|---|
| `-listen` (8080) | other operators only, signature shares | **yes**, narrow it to the nine addresses |
| `-metrics-listen` (8081) | anyone, including a browser | **no**, that is what it is for |

The share port is exposed of necessity, so it will be found. Verifying one share
is a pairing, ~1.6 ms, hence:

- **`-allow`** — a list of IPs or CIDRs to accept shares from. An empty list
  means "from anyone", and then only the rate limit protects you. Fill it in for
  production.
- **`-share-rate`** — how many shares per second to accept from one source,
  20 by default. Nine operators send one share each per request, so that is a
  wide margin.
- A share for a request the node has not heard of yet **does not turn into an
  RPC call**: it is parked in a bounded buffer and replayed when the node's own
  watcher sees the request. Otherwise anyone could burn an operator's RPC quota
  just by sending random ids.
- The number of verifications one request can provoke is bounded by the number
  of operators: one per index. Past that, a flood meets a map lookup.

## Running it

```sh
export VRF_KEYSTORE_PASSPHRASE=...
export VRF_ETH_PRIVATE_KEY=0x...

vrfnode \
  -rpc https://rpc.mainnet.chain.robinhood.com \
  -coordinator 0x... \
  -keystore /var/lib/vrf/operator-3.json \
  -listen 0.0.0.0:8080 \
  -metrics-listen 0.0.0.0:8081 \
  -peers https://op1.example:8080,https://op2.example:8080,... \
  -allow 203.0.113.4,198.51.100.0/24 \
  -threshold 5 -operators 9
```

The whole stand — chain, ceremony, contracts and three nodes — comes up with one
command:

```sh
./script/localnet.sh
```

## Running continuously on one machine

For testing, while the operators are just you. Nine processes under `launchd`,
each restarting itself, surviving reboots.

```sh
./script/operators.sh install    # keys and binary from the repo into ~/.vrf-operators
./script/operators.sh start      # bring them up and enable autostart
./script/operators.sh status     # who is alive, how far behind, how much gas is left
./script/operators.sh logs 3     # watch one of them
./script/operators.sh stop
VRF_DEPLOYER_KEY=0x... ./script/operators.sh fund   # top the publishers up
```

`status` shows what reveals a fault before a user does:

```
  id  up     behind      gas(ETH)  published/lost
  3   yes    0           0.000082  1/0
  4   yes    0           0.000087  0/1
```

`behind` is how far the node trails the head of the chain. Zero is normal; a
rising number means the node is alive but has stopped scanning, which is a
different problem from "the process died". `lost` counts publication races lost,
and that is normal too: with nine operators, eight times out of nine somebody
else is faster.

The keys and the passphrase sit in plaintext in plist files with `600`
permissions. That is acceptable for testnet keys worth fractions of a cent and
**unacceptable** for anything else.

**This is not the production shape.** Nine processes on one host under one
person give you a working service, but not the property the whole thing was
built for: in production, nine operators means nine independent organisations on
nine machines, and none of them can be told what to sign.

## Exposing status to the outside

Everything the operators run listens on `127.0.0.1` only — both the share
exchange port and the metrics. The machine as a whole must never be exposed: it
holds key shares, the passphrase and the publishing keys.

```sh
./script/operators.sh share      # a public URL for the metrics only
./script/operators.sh unshare
```

One separate `vrfstatus` process faces outward, and it is built so that it
cannot reach anything but the metrics:

- the addresses it talks to are **fixed at startup** and never taken from a
  request — there is no target parameter and no redirect following, so there is
  nowhere to lead it;
- upstream, it requests **only the `/metrics` path**;
- it answers **GET only**, and neither reads nor forwards a request body.

Verified from outside, through a live tunnel:

```
/op/3/metrics                                → 200, operator 3's metrics
/op/99/metrics                               → 404
/op/0/../../etc                              → 404
/op/3/healthz                                → 404
/v1/shares                                   → 404
/proxy?url=http://127.0.0.1:9100/v1/shares   → 404
POST /op/3/metrics                           → 405
```

### What it serves

| | |
|---|---|
| `/operators.json` | what is available at all |
| `/op/N/metrics` | one operator, Prometheus format |
| `/status.json` | all nine at once, answers **not merged** |

`/status.json` is a convenience, not a replacement for polling. It returns each
operator's answer separately and averages nothing: one node's word about another
proves nothing, and the page has to compare the nine answers itself. When the
operators become nine real hosts, a front end moves from nine paths to nine
domains without changing its logic.

The tunnel is raised with `ngrok` if it is configured, otherwise with
`cloudflared`. The URL changes on every run; a permanent one needs a named
tunnel on your own domain. The script prints the URL only once it has actually
answered — a quick tunnel hands out a name before the route is up, and on some
networks the route never comes up at all.

## Server requirements

| Parameter | Minimum |
|---|---|
| CPU / RAM | 2 cores / 2 GB |
| Disk | 20 GB SSD |
| Network | static IP, an inbound port for shares |
| Time | NTP required |

The bottleneck is uptime, not horsepower: signing a share takes milliseconds.

## The key ceremony

There are two programs, and the difference between them is fundamental.

**`vrfdkg` — for localnet and testnet.** It runs the DKG in a single process, so
the full group secret momentarily exists on one machine. It warns about this on
startup.

```sh
vrfdkg -operators 9 -threshold 5 -epoch 1 -out ./keys
```

**`vrfceremony` — the production one.** One process per operator, on that
operator's own machine. No machine ever sees anything but its own share.

Step 1, each operator on their own machine:

```sh
vrfceremony -generate-identity -index 3 -identity identity.json
```

The program prints a line with a public key — publish that to the others. Those
nine lines are assembled into a shared `ceremony.json`:

```json
{
  "epoch": 1,
  "threshold": 5,
  "members": [
    {"index": 0, "public": "0x...", "url": "https://op0.example:8090"},
    ...
  ]
}
```

Step 2, all nine at the same time:

```sh
export VRF_KEYSTORE_PASSPHRASE=...
vrfceremony -config ceremony.json -identity identity.json -index 3 \
            -listen 0.0.0.0:8090 -out /var/lib/vrf/operator-3.json
```

Each participant prints the group public key. **All nine must print the same
thing.** If anyone's differs, the ceremony did not converge and nothing may be
deployed.

The config must be byte-identical for everyone: the session nonce is derived
from it, and a disagreement about the group's membership will collapse the
ceremony rather than quietly produce two different ones.

### Rotation

The same command with an `old` block in the config, and the previous keystore in
place of the identity file:

```sh
vrfceremony -config ceremony-epoch2.json -old-keystore operator-3.json \
            -index 3 -out operator-3-epoch2.json
```

```json
{
  "epoch": 2,
  "threshold": 5,
  "members": [ ... the new set ... ],
  "old": {
    "threshold": 5,
    "members": [ ... the previous set ... ],
    "commits": ["0x...", ...]
  }
}
```

The `old` block is entirely public, and everyone needs it — including a newcomer
who has no previous share. Without it a newcomer can neither verify the shares
they receive nor derive the same session nonce as everyone else, and will
silently end up with nothing.

## Key rotation

Resharing **preserves the group public key** — verified by the test
`TestResharingKeepsTheGroupPublicKeyUnchanged`, including the case where one
operator leaves and a new one takes their place
(`TestRotationCanReplaceAnOperatorAndKeepTheKey`). So the deployed
`VRFVerifier` stays valid, integrations notice nothing, and the verifier needs
no epoch registry.

A share left in the hands of a departed operator is useless after rotation: it
does not combine with the new ones into a valid signature. That is under test
too.

## Slashing: what is provable

`session` records **equivocation** — two different shares for the same seed from
the same index — as self-contained evidence: anyone holding the DKG commitments
can verify it without trusting whoever brought it.

An invalid share is rejected on arrival and logged.

Downtime is not a provable offence and is not slashed automatically: RPCs and
networks fail. It feeds the uptime metric and affects revenue distribution.

## Metrics, and why they are built this way

`GET /metrics` in Prometheus format, no authentication, with
`Access-Control-Allow-Origin: *`. There are no secrets there — only counters.

The openness is a necessity, not carelessness. **Operator uptime cannot be
derived from the blockchain**: a threshold signature is identical whichever five
assembled it, so the chain shows who *published* and never who *signed*. The
only place that knowledge exists is the other operators: each one knows who sent
it a share.

So every node publishes its own counters, and a monitor polls all nine and
compares. One node's word about another proves nothing; eight nodes agreeing
that the ninth is silent is proof. And that is exactly why the endpoint is
CORS-open: the page that does the comparing runs in the visitor's browser and
talks to each operator directly, so there is no aggregator anyone has to trust.

The key counters:

```
vrf_operator_index                     who is answering
vrf_uptime_seconds                     how long this process has been alive
vrf_last_seen_block                    how far the chain has been scanned
vrf_requests_seen_total                how many requests it has seen
vrf_shares_received_total{peer="N"}    how many VERIFIED shares it got from N
vrf_shares_rejected_total{peer="N"}    how many it rejected
vrf_equivocations_total{peer="N"}      how many times N sent two different shares
vrf_fulfilments_published_total        how many times it published itself
vrf_fulfilments_lost_total             how many times it was too late (this is normal)
```

One subtlety that would otherwise cost the monitor its truthfulness: a share
that arrives **after** quorum has already been reached is not needed for the
signature — but it is the only evidence that its sender is alive. So such shares
are verified and counted anyway. Otherwise a slow but healthy operator would be
indistinguishable from a dead one.

## What is left

- Alerting on top of the metrics.
- Session persistence: an unfinished session is lost on restart. Not critical —
  on startup a node rescans the last `-lookback` blocks (20,000 by default) and
  re-signs everything still open, skipping requests that have closed.
