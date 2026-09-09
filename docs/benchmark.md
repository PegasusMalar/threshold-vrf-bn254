# Gas measurements on Robinhood Chain

**Date:** 2026-08-27 · networks 4663 (mainnet) and 46630 (testnet), both on
ArbOS 61.

Every number was taken on the target networks themselves. No deployment and no
funds: the contracts are created inside an `eth_call` with a state override, so
the gas is counted by the network's own node, on its own EVM, on its own ArbOS
version.

```
./script/bench.sh https://rpc.mainnet.chain.robinhood.com \
                  https://rpc.testnet.chain.robinhood.com/rpc
```

## Phase 1 — the blocking question: what does a pairing cost

**Verdict: passed.** Pairing is billed at the standard EIP-1108 rate, with no
ArbOS surcharge. The economics need no revision, and BN254 is confirmed.

| | Mainnet | Testnet | Reference EVM |
|---|---|---|---|
| `ecPairing`, k=2, bare precompile | 113,131 | 113,131 | 113,131 |
| `hashSeedToPoint()` (SvdW hash-to-curve) | 48,688 | 48,688 | 47,416 |
| **`verify()` in full** | **165,564** | 165,564 | 161,729 |

113,131 = 45,000 + 2 × 34,000 per EIP-1108, plus 131 for the `staticcall`
itself. Agreement down to the gas unit means the precompile is not repriced.

The signature in the measurement is not synthetic: it is an aggregated 5-of-9
threshold signature from `test/vectors/bls.json`, and both networks accepted it.

## Phase 2 — the full request path

The consumer callback is empty, so this is the cost of the protocol itself. How
much your callback adds is up to you; the ceiling is 500,000 (see
[integration.md](integration.md)).

| | Mainnet | Testnet |
|---|---|---|
| `requestRandomWords` | 55,846 | — |
| `fulfillRandomWords`, 1 word — first time | 200,317 | — |
| `fulfillRandomWords`, 1 word — **steady state** | **178,516** | — |
| 10 words | 182,218 | — |
| 100 words | 219,688 | — |
| `retryCallback`, 1 word | ~248,000 | — |

`retryCallback` costs more than a fulfilment because it is a pairing plus a
callback which, in the measurement, writes the words to storage. Whoever pressed
"retry" pays for it; the subscription is untouched.

"First time" means cold slots and cold addresses: the very first fulfilment for
that subscription and that relayer. Subsequent calls are ~22,000 cheaper. For
the economics, take the steady state and the mainnet figure, which is the
higher one.

### What the changes after the first measurement cost

Every number here was measured on mainnet, not estimated.

| Change | Request | Fulfilment |
|---|---|---|
| the `callbackSucceeded` flag (which enables `retryCallback`) | +111 | +213 |
| capped fees with a timelock | +2,183 | −167 |
| the compatible interface shape | +4,487 | +1,384 |

That last row is `keyHash` read from the verifier, `callbackGasLimit` in the
request, an honest open-request counter, and the third component of the price.
+2.5% on the full cycle so that an integrator can port their contract with
almost no edits.

The flag shares a slot with `fulfilled`, so the write lands in an
already-warmed slot — 0.12% for a failed callback no longer being
unrecoverable.

Fees made the request more expensive because they moved out of code (immutable)
and into storage: a cold SLOAD of the slot holding `baseFee` and `perWordFee`.
Fulfilment got slightly cheaper in exchange — the price recorded in the request
itself is charged, rather than recomputed. Net: +2,016 gas on the full cycle,
about 0.9%, for the ability to ever start charging at all without migrating
every integration.

Mainnet is consistently ~9,400 gas more expensive than testnet on identical
bytecode. The cause is unconfirmed; most likely a difference in how storage
growth is billed (`ArbGasInfo.perStorageAllocation` versus the current base
fee). The measurement reproduces byte for byte across repeated runs.

A hundred words instead of one costs only +41,000 — deriving words from the
signature is nearly free; what we pay for is the pairing.

### The price in ETH

At a mainnet `gasPrice` of ≈ 0.0395 gwei:

| | gas | ETH |
|---|---|---|
| request | 53,552 + 21,000 intrinsic | ≈ 3.0 × 10⁻⁶ |
| fulfilment (1 word) | 178,470 + 21,000 intrinsic | ≈ 7.9 × 10⁻⁶ |
| **full cycle** | | **≈ 1.1 × 10⁻⁵ ETH** |
| deploying `VRFVerifier` | 2,112,743 | ≈ 8.3 × 10⁻⁵ |

The L1 component on mainnet hovers around zero (`perL1CalldataByte` was 0 in one
measurement and ~1,200 gas per transaction in another). On testnet it is a
steady ~11,000 gas. If the L1 charge is switched on permanently on mainnet, add
roughly 10,000 gas to every transaction — budget for it in the margin.

**It is too early to announce final prices**: there is no latency data yet and
no operator reward model.

## What this means for BLS12-381

The question is settled in favour of BN254 and is not open for revision until a
BLS12-381 precompile appears in ArbOS. Without a precompile, verification would
cost hundreds of thousands of gas for the pairing alone — against 113k here.

## The ArbOS version, and funds on testnet

`ArbSys.arbOSVersion()` returns 116 on both networks, i.e. **ArbOS 61**. `PUSH0`
and `MCOPY` were checked live through `eth_call` and work. So `evm_version` was
raised from `paris` to `cancun`, which gave 1,147 gas away for free.

The testnet is **not free**: a transaction from a zero balance is rejected
(`insufficient funds for gas * price + value: have 0 want 420000021000`), and
`gasPrice = 0` is not accepted (`max fee per gas less than block base fee`).
Only ArbOS's internal system transactions (type `0x6a`) pay zero. The amounts
are nominal: 0.01 ETH on testnet is ~3,300 fulfilments. Bridge:
portal.arbitrum.io from Sepolia.

## What `block.number` means on this network

`NUMBER` returns the **L1** block number, not L2: 25,847,970 versus 47,610,908
on the same call. An L2 block comes every 0.101 s, an L1 block roughly every
12 s.

`TIMEOUT_BLOCKS = 7200` is counted in L1 blocks, i.e. ≈ one day. That is a
deliberate choice: the sequencer can fall behind on this counter, which only
delays refunds, but it cannot run the counter forward to trigger a refund early.

## Verified along the way

- The `0x06`, `0x07` and `0x08` precompiles are present and behave as on L1.
- Pairing **rejects a G2 point outside the order-r subgroup** — both networks
  answer `point is not in correct subgroup`. That is exactly what the
  `VRFVerifier` constructor relies on when checking the group key: there is no
  G2 scalar multiplication on the EVM, and no other way to check the subgroup on
  chain.

## Phase 3 — off chain, the cost of the cryptography

`go test ./internal/blsvrf -bench .`, Apple M-series, single-threaded:

| Operation | Time |
|---|---|
| sign a share | 97 µs |
| verify someone else's share | 1.59 ms |
| combine 5 of 9 | 252 µs |
| a full DKG across 9 participants | 111 ms |

Verifying a share is a pairing, hence the order-of-magnitude difference. A node
verifies eight incoming shares in about 13 ms. So the cryptography is nowhere
near the bottleneck: latency is determined entirely by network exchanges and
block time.

## Phase 5 — latency on the live testnet

Deployed on 46630, a group of **5 of 9**, nine daemons, 25 consecutive requests.
What is measured is what a consumer feels: from sending `requestRandomWords` to
the moment `requests(id).fulfilled` turns `true`.

| | seconds |
|---|---|
| min | 4.22 |
| **P50** | **5.06** |
| **P95** | **5.76** |
| **P99** | **5.79** |
| max | 5.79 |
| mean | 4.97 |

Broken down (medians):

| | |
|---|---|
| node saw the request → sent the transaction | 1.64 s |
| inclusion of both transactions + polling | 3.42 s |

There is no cryptography in this at all: signing a share is 97 µs, verifying
eight is 13 ms. **The latency is entirely RPC round-trips plus transaction
inclusion time.**

Publication rotated across all nine operators (between 1 and 6 times each over
25 requests) — the deterministic queue works, and the gas cost is shared.

### What the first optimisation pass gave

The first measurement gave P50 5.80 / P95 7.02 / P99 7.12. Three changes in the
node:

- **the seed is computed locally** rather than asked of the contract. It is a
  pure function of data already present in the event. One fewer round-trip and,
  more importantly, one fewer trusted party: a node that asks a server what to
  sign will sign whatever the server answers.
- **a fixed gas limit instead of `eth_estimateGas`.** The answer is known in
  advance, and on Arbitrum you pay for gas used, not for the limit. The limit
  must be at least ~560k, because the coordinator refuses to start without a
  budget for the callback — against an actual spend of 240k.
- **a one-second fee cache** instead of a query per publication.

A side effect of the second point: the node no longer learns in advance that a
request is already closed, so a lost race costs a revert instead of a free
refusal. With the deterministic queue this is rare, and a revert costs ~25k gas.

### Caveats

The nine operators ran on one machine, so the RTT between real hosts is not in
this number. It lands on the share exchange — one parallel round, tens of
milliseconds against seconds of waiting on the chain.

The RPC was a public endpoint and requests came from a laptop. An operator with
its own node will see noticeably less: the 1.64 s on the node's side is mostly
round-trip, not work.

The measurement was taken on contracts
`0x23e5C5D218c4c5b6fe72703078491D384E4B82D3` (verifier) and
`0xeD8086F5394E021b3B771b9767f0AC0B09d2f68C` (coordinator), network 46630.

To reproduce: `VRF_DEPLOYER_KEY=0x... ./script/testnet.sh 25`.

## Still to measure

- The same thing on mainnet, once the group is assembled.
- Latency with the operators genuinely spread across hosts.

---

## Phase 4 — one verification per batch

More than half the cost of a fulfilment is the pairing, and it is the one thing
nothing reduces: 107,805 gas for one word and for five hundred alike.

Signatures under one group key add up, and the verification equation adds up
with them:

```
e(Σσᵢ, g₂) == e(ΣH(mᵢ), pk)
```

So a batch of any size costs **one** pairing plus a hash-to-curve and one point
addition per member. The hash stays on chain: the seed a publisher brings is a
seed the publisher chooses.

### Signature verification

| in a batch | total gas | per request |
|---|---|---|
| 1 | 157,759 | 157,759 |
| 7 | 400,895 | 57,270 |
| 13 | 640,611 | 49,277 |
| 19 | 883,170 | 46,482 |
| 25 | 1,126,513 | **45,060** |

### The full fulfilment path

The callback is minimal, so this is the cost of the protocol itself.

| in a batch | gas per request | saving |
|---|---|---|
| 1 | 219,590 | — |
| 5 | 80,334 | 64% |
| 9 | 68,797 | 69% |
| 17 | 61,580 | 72% |
| 25 | 58,547 | **74%** |

A batch of one costs more than the single path (219,590 against ~190,000): the
array and the memory handling do not pay for themselves when there is nothing to
divide by. A lone request should be fulfilled through `fulfillRandomWords`, not
through a batch of length one.

Past 25 the curve is nearly flat — the pairing is spread thin, and what remains
does not depend on batch size.

### What that does to the price

At 0.5 gwei and ETH at $2,450, with a 30% operator margin:

| | gas | cost | price |
|---|---|---|---|
| single path | 190,000 | $0.233 | $0.30 |
| batch of 9 | 68,797 | $0.084 | **$0.11** |
| batch of 25 | 58,547 | $0.072 | $0.09 |

### What it cost in security

Batching adds two ways to get it wrong, and both are closed in
`test/attacks/Batch.t.sol`.

**A repeated request inside a batch.** Two copies of one seed sum to 2·H(s), and
2·σ can be computed by anyone holding a single published signature. The
aggregate then passes verification — the equation genuinely holds — and the
request would be charged twice. So identifiers are accepted in strictly
increasing order: that makes a duplicate impossible even to express, and it
costs one comparison per member instead of a quadratic search.

**Early delivery to later members.** A single fulfilment is protected against
double delivery by the gas check: delivery runs with at most its own budget,
while `retryCallback` demands the whole budget again. Inside a batch that
argument stops working — the member being delivered to and the member being
targeted need not have the same budget. A consumer whose first request carries a
large budget has headroom precisely when a request with a small one is processed
later in the same transaction.

The defence is the order of operations: each member is carried through to the
end before the next begins, and a member not yet reached is simply not marked
fulfilled. The obvious optimisation — marking the whole batch up front in one
pass — yields a third delivery across two requests. The test checks for this and
fails if you do it.

---

## Phase 5 — what a single request actually costs

The Phase 2 numbers were measured wrongly, and the error is systematic.

The warm address and slot lists are reset at a transaction boundary. In
production every fulfilment is its own transaction, and it **always** begins
with a cold touch of the accounting contract, cold subscription balance slots
and a cold publisher credit slot. Two fulfilments measured inside one test share
those slots warm and produce a number that never occurs on chain.

`vm.cool` returns the contracts to the state a new transaction would find them
in.

| | gas |
|---|---|
| the Phase 2 "steady state", warm | 171,509 |
| **cold, steady state — as in production** | **≈ 200,000** |
| cold, right after an operator withdrew their earnings | 236,500 |

So our price was built on a figure roughly 15% too low. The separate line is a
fulfilment right after a `withdraw`: zeroing the credit slot makes the next
write a transition out of zero, and that is 20,000 gas instead of 2,900.

## What makes up those 200,000

| | gas | share |
|---|---|---|
| `ecPairing`, k=2 | 113,189 | 57% |
| hash-to-curve of the seed | 45,489 | 23% |
| **cryptography, total** | **157,295** | **79%** |
| cold accesses, accounting, event, callback invocation | ≈ 43,000 | 21% |

Reference points for comparison: `ecPairing` with k=1 costs 79,188, so each
additional pair is exactly 34,000 per EIP-1108. One modexp for a square root is
1,527, so what is expensive inside hash-to-curve is not the root extraction but
the SvdW field arithmetic, performed twice.

## What of this can be reduced

**The pairing — no.** A BLS check is `e(σ, g₂) == e(H(m), pk)`, two pairs by
definition. There is no precompile for a cheaper curve on this network.

**Hash-to-curve — only at the cost of the standard.** In the random-oracle
construction, RFC 9380 maps to the curve twice and adds; the non-uniform
`encode_to_curve` construction maps once and would save on the order of 20,000
gas. That is a departure from the standard and from what every other BLS
implementation does. We are not doing it.

**The remaining 21% — possible, but there is nothing there to take.** A perfect
optimisation of everything that is not cryptography would yield at most about
43,000 gas, i.e. roughly $0.05 per request at current prices. Merging the
accounting contract into the coordinator removes one cold account touch — 2,600.
Leaving 1 wei in the credit account instead of zero removes the
transition-out-of-zero — 17,100, but once per collection cycle, which is single
digits of gas per request.

## Conclusion

**79% of the price of a single request is cryptography, priced by the network.**
A lone call cannot be made materially cheaper without changing the scheme.

It only gets cheaper in three ways, and none of them is a code optimisation:

1. **Volume.** A batch divides the pairing among everyone: 200,000 → 68,797 at
   nine to a batch. It starts working from roughly one request per second;
   below that it is useless (Phase 4).
2. **A different curve.** That needs a precompile this network does not have.
3. **The network's gas price.** Not ours.

---

## Phase 6 — latency on mainnet

**Date:** 2026-09-06 · network 4663 · 9 operators on nine hosts, threshold 5,
60,000-gas callback, 30 consecutive requests.

| | seconds |
|---|---|
| min | 3.42 |
| **P50** | **4.08** |
| **P95** | **7.86** |
| P99 | 8.04 |
| max | 8.04 |
| mean | 4.98 |

30 of 30 delivered. All nine published.

Faster than testnet, where it was P50 5.06 with nine operators on one machine
and 5.84 across nine hosts. The difference comes from event hints — a node
learns of a request within a fraction of a second instead of at the end of a
three-second polling interval.

### Two earlier measurements were spoiled, and both by us

**A 500,000 callback in the measuring script.** The script asked for the
coordinator's ceiling rather than what a game asks for. That inflated both the
price of a request and the reserve a publisher must hold: such a reserve needs
0.00056 ETH, and eight operators out of nine did not have it. The result was a
16-second latency attributed to the service, when the cause was an insolvent
fleet. The script now asks for 100,000 and accepts an override.

**A balance check on a timer.** After publishing, an operator drops below the
reserve but only learns of it on the next tick, once a minute — and for all that
time the rotation has to route around it. Six consecutive requests on a
thinly-funded fleet gave P50 9.75 against 3.93 for a single one. The check now
runs immediately after publication: that is the one event which moves the
balance and the credit at the same time, and the node knows about it first.

### Wasted transactions

34 sends for 30 fulfilments — 13% wasted, against the 40% measured on testnet
before the hints existed. A fresher log stream lets a loser see someone else's
fulfilment sooner and not send its own.
