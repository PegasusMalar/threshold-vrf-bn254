# Load test: throughput, and what it uncovered

**Date:** 2026-08-31 · testnet 46630 · 9 operators, threshold 5, one machine.

Load is applied through the `LoadGenerator` contract
(`0xF4ab809f004F00c99f359Eb1c0Ad8978D758bc19`), which opens the whole batch of
requests **in one transaction**. Sending one transaction per request measures
the sender's nonce, not the operators.

```
./script/operators.sh status          # all nine on their feet
go build -o /tmp/vrfload ./node/cmd/vrfload
VRF_DEPLOYER_KEY=... /tmp/vrfload \
  -rpc https://rpc.testnet.chain.robinhood.com/rpc \
  -generator <LoadGenerator> -coordinator <VRFCoordinator> \
  -bursts 1 -size 100 -deadline 300s -json out.json
```

## Result

| Profile | Delivered | P50 | P95 | max | Rate |
|---|---|---|---|---|---|
| 10 in one block | 10 / 10 | 6.68 s | 8.23 s | 8.23 s | — |
| 50 in one block | **50 / 50** | 5.61 s | 6.55 s | 7.48 s | 6.7 /s |
| 100 in one block | **100 / 100** | 8.07 s | 9.90 s | 9.90 s | **10.1 /s** |
| 6 waves of 25, 5 s apart | **150 / 150** | 6.00 s | 7.77 s | 9.77 s | — |

Latency at 50 to a batch is the same as for a single request (P50 ≈ 5–6 s).
Under sustained load the queue does not build up: six consecutive waves gave
P50 5.5–6.8 s each, with no growth from wave to wave.

10.1 deliveries per second is not a ceiling but what a batch of a hundred
happened to show. The upper bound was not found: the test funds ran out first.

**What was not tested.** All nine operators live on one machine and talk to one
public RPC. A genuinely distributed layout was not measured, and it was that
shared endpoint which was the bottleneck in almost every finding below.
Stability was checked over tens of seconds, not hours.

## First run: 50 requests, and not one fulfilment

A batch of 50 produced **0 deliveries**. Not "slow" — nothing at all. Four
causes follow, each of which on its own lost requests permanently.

### 1. A refused share lost the request for good

`Broadcast` was fire-and-forget: if a peer did not accept a share — it was busy,
it hit the rate limit, the network blinked — the share was **never** re-sent.
After that the request could not reach quorum under any circumstances. Under a
burst this is not a rare case but the normal one.

Now a node offers its share again while quorum is missing and the request is
open, and stops as soon as quorum is reached. Tests:
`TestAShareIsResentUntilTheQuorumIsThere`,
`TestResendingStopsOnceTheQuorumIsMet`.

The mesh rate limit (`20/s`, burst 40) had also been sized for a steady stream,
and was raised to `500/s`. The expensive part is bounded elsewhere: one pairing
verification per operator per request.

### 2. Publication waited its turn inside the handler for someone else's share

`OnPeerShare` invoked publication synchronously, and publication waits for this
operator's turn — up to sixteen seconds with nine of them. The peer's POST
carrying the share stayed open for all of it. With a five-second client timeout,
peers began dropping each other with `context deadline exceeded`, and shares
stopped arriving.

Answering a peer and doing the work that answer triggers are different things.
Publication moved into its own goroutine. Test:
`TestTakingAShareDoesNotBlockOnThePublishTurn` (before the fix: 10.00 s for a
single reply to a peer).

### 3. Every transaction in a batch was signed with the same nonce

`Fulfill` read the pending nonce from the node for every transaction. When an
operator has several fulfilments ready at once, none of them is in a block yet —
and the node honestly answers with the same number every time. Every transaction
but one was dropped as `nonce too low`, and the requests behind them were lost.

In the logs it looked like this:

```
chain: send: nonce too low: address 0x81D7…E6bE, tx: 21 state: 22
```

The nonce is now issued by a local counter under a mutex held until the send.
The counter is reset on any refusal — including the ordinary case where another
operator published first — and re-read from the chain. Tests:
`TestConcurrentFulfilmentsGetDistinctNonces` (before the fix: 12 transactions,
1 unique nonce), `TestTheNonceCounterIsRebuiltAfterARejection`.

### 4. A 429 from the RPC counted as losing the race

Any send error marked the request as "somebody else published it" and forgot it.
But `429` is not a loss: **nobody** published the request. Telling the two apart
means asking the chain, not reading the error text. Now a refusal is retried
with backoff, and between attempts the node checks whether someone else has
closed the request. Tests:
`TestARefusedTransactionIsRetriedNotTreatedAsALostRace`,
`TestARequestAnotherOperatorPublishedIsNotRetried`.

## The main optimisation: 450 calls per batch down to zero

Eight operators out of nine lose every race. Each of them asked the chain about
every request — twice: on receipt and before publishing. For a batch of 50 with
nine operators that is **up to 900 calls** against the very endpoint the whole
group depends on. Hence the `429`s: 452 of 600 refusals were `eth_getLogs`,
throttled by that same burst.

But the operators already read logs. Now the same `eth_getLogs` also collects
`RandomWordsFulfilled` — in the same call, at no extra cost — and the node keeps
its own set of closed requests. A log stream can prove a request is closed, but
never that it is still open (it trails by one poll), so:

* known to be closed → no call and no transaction;
* nothing known about it → as before, one call before sending.

An error in that direction costs one extra signature, but never an extra
transaction: the check before sending happens regardless.

Tests: `TestARequestKnownSettledCostsNoChainCalls`,
`TestARequestNotYetSeenSettledIsStillChecked`.

Chain polling also gained exponential backoff on failure, plus jitter: nine
operators started by one script would otherwise poll in lockstep, and each of
their polls is a burst of nine. Tests:
`TestPollingBacksOffWhenTheRpcRefuses` (previously 100 hits on a choking
endpoint in 2 s), `TestPollingSpeedsBackUpOnceTheRpcRecovers`.

## The measuring instrument was lying, and that had to be fixed too

The first sustained run showed "degradation": wave 0 — 38.31 s, wave 1 —
31.68 s, wave 2 — 24.59 s… and every request within a wave identical to the
hundredth of a second. That does not happen.

The cause was in the measuring tool: it only started reading logs after **all**
the waves had fired, so everything that had been fulfilled earlier was seen in a
single scan and stamped with a single time. The numbers described the moment
measurement began, not the service's behaviour.

On top of that, the first version polled each request separately — 50 requests
four times a second is 200 calls per second against the shared endpoint, so the
instrument was choking the thing it measured. It got its own `429` for its
trouble.

The observer now starts before the first wave and reads the logs in one scan per
tick, regardless of batch size. After the fix, the same six waves: 5.54 / 6.82 /
5.46 / 6.00 / 5.28 / 5.74 — flat.

The moral is exactly the one in the working agreement: measure, then conclude.
The first conclusion ("the system degrades under load") was wrong, and what
refuted it was not logic but a repaired instrument.

## State after a clean run

Over the window of the last run (150 requests, 6 waves):

* nonce collisions — **0** (was 10+ per batch);
* undelivered shares — **0** (was 150+);
* fulfilment refusals — 8, all `insufficient funds`: one operator ran out of
  gas. The group delivered all 150 without it — precisely what a 5-of-9
  threshold is for;
* poll retries — 20, `429`s on the shared endpoint, absorbed by backoff.

## What next

* **The upper bound was not found.** Test funds ran out at 100 to a batch. The
  next step is a ladder of 200 / 400 / 800 up to the first failure.
* **Nine hosts instead of one machine.** The shared public RPC was the
  bottleneck in almost every finding; on a real layout the picture will differ.
* **Hours, not tens of seconds.** Leaks and memory growth over a long run have
  not been checked.

---

# Second run: a genuinely distributed fleet

**Date:** 2026-09-04 · testnet 46630 · 9 operators, threshold 5, **nine
different machines**, three providers, six countries, each node with its own RPC
endpoint.

The first run was honest about what it had not tested: all nine operators lived
on one machine and used one public RPC. Both caveats are closed here.

```
0  OVH France          Alchemy       span 10
1  OVH France          Tenderly      —
2  GCP Iowa            Tenderly      —
3  GCP South Carolina  Tenderly      —
4  GCP Oregon          Tenderly      —
5  GCP London          Alchemy       span 10
6  GCP Netherlands     public RH     —
7  GCP Madrid          publicnode    span 10000
8  GCP Frankfurt       Alchemy       span 10
```

`span` is the measured — not assumed — `eth_getLogs` limit of the endpoint.
Alchemy on the free plan returns **no more than 10 blocks per request**; that
was the cause of the 429 storms, and it is now written explicitly into the
config of every such node.

## Result

| Profile | Delivered | P50 | P95 | max | Rate |
|---|---|---|---|---|---|
| singles, 10 in a row | 10 / 10 | 5.84 s | 7.12 s | 7.12 s | — |
| 10 in one block | 10 / 10 | 5.67 s | 5.67 s | 7.65 s | 1.3 /s |
| 50 in one block | **50 / 50** | 7.55 s | 9.53 s | 10.45 s | 4.8 /s |
| 100 in one block | **100 / 100** | 8.54 s | 11.39 s | 13.34 s | **7.5 /s** |
| 6 waves of 25, 5 s apart | **150 / 150** | 7.36 s | 9.83 s | 18.19 s | — |

No losses in any profile: 320 requests, 320 deliveries, not one failed callback.

**What distribution costs.** Compared against the single-machine run:

| | one machine | nine machines |
|---|---|---|
| single request, P50 | 5.06 s | 5.84 s |
| 100 to a batch, rate | 10.1 /s | 7.5 /s |
| 100 to a batch, P50 | 8.07 s | 8.54 s |

About **0.8 seconds** on a single request and roughly a quarter of the
throughput — that is the price of a real round-trip between hosts during the
share exchange. A figure the local run could not have shown by construction.

Publication is still shared by everyone: all nine indices appeared over the run,
27–52 publications per operator.

## What this run uncovered: an empty account is indistinguishable from a healthy node

Between two batches of 100 the fleet fell from **100% delivery to 8%** — and not
one metric showed it. The nodes were scanning the chain, seeing all 100
requests, verifying and broadcasting shares: `vrf_requests_seen_total`,
`vrf_shares_sent_total` and `vrf_last_seen_block` all rose exactly as in a
successful run.

The cause: **the operators' publishing accounts had run out of funds**. All nine
had about 1.4e-5 ETH left — less than the cost of one fulfilment transaction.
Everything that costs no gas kept working flawlessly; exactly one step stopped —
the one that costs money.

This is the worst kind of failure: from outside it looks like a healthy system.
From the consumer's side requests simply stop being fulfilled, while the status
panel shows nine green nodes.

**Closed.** A node publishes `vrf_publisher_balance_wei` — the balance of the
account it sends fulfilments from — and logs a warning when that falls below
`-min-balance` (0.001 ETH by default, about five hundred fulfilments at testnet
prices).

The balance is cached and refreshed at most once a minute rather than read on
every metrics request: `/metrics` is open to the world without authentication,
and a live read would turn every scrape into an RPC call — against endpoints
whose free tier is already the fleet's tightest constraint. A failed refresh
keeps the previous value: a blinking endpoint must not extinguish the only
indicator that an operator cannot pay. Until the balance has been read even
once, the metric is **absent** rather than zero — otherwise "could not read it"
is indistinguishable from "there is no money".

Tests: `TestNothingIsKnownBeforeTheFirstRefresh`,
`TestAFreshValueIsNotFetchedAgain`, `TestAStaleValueIsFetchedAgain`,
`TestAFailedRefreshKeepsTheLastKnownValue`,
`TestRefreshReportsWhetherItFetched`,
`TestReportsThePublishingBalanceWhenItIsKnown`,
`TestOmitsThePublishingBalanceWhenItIsNotKnown`.

**What remains untested.** Stability was measured in tens of seconds, not hours.
The throughput ceiling was again not found — we ran into the supply of test ETH,
not into the operators.

## Another finding: the publication counter did not count what it was labelled

On a batch of 50 the fleet reported **70 publications for 50 fulfilments**.

A node counts a publication when the endpoint accepts the transaction, without
waiting for a receipt. Under a burst the publication delay (`PublishRank`)
expires for several operators at once, they all send a transaction for the same
request, and all but one revert. Hence 40% wasted sends.

The behaviour itself is expected — fulfilment is permissionless, and the race is
inherent. But the metric was called "Fulfilment transactions this node landed",
i.e. **landed**. On a transparency page, where an outsider judges an operator's
work, that would have overstated its contribution. The wording was corrected to
"sent", with a note that the fleet-wide sum is necessarily larger than the
number of fulfilments.

The overspend itself remains open: 40% of fulfilment transactions under a burst
waste gas. Candidates: stretch `-publish-delay` as the queue grows, or confirm
by receipt before sending the next. On the improvements list.

## Control run after topping the accounts up

2026-09-04, the same fleet, publishing accounts funded from the deposit account.

| Profile | Delivered | P50 | P95 | max | Rate |
|---|---|---|---|---|---|
| 10 in one block | 10 / 10 | 8.41 s | 9.41 s | 10.39 s | — |
| 50 in one block | **50 / 50** | 8.17 s | 10.22 s | 10.22 s | 4.9 /s |
| 100 in one block | **100 / 100** | 9.47 s | 12.93 s | 12.93 s | **7.7 /s** |
| 6 waves of 25, 5 s apart | **150 / 150** | 8.15 s | 10.02 s | 10.79 s | — |

No losses. Latencies are a second to a second and a half higher than in that
morning's run (P50 5.67 / 7.55 / 8.54 / 7.36) with an unchanged configuration,
so the difference comes from the state of the network, not the fleet.

### Three accounting traps this run uncovered

**1. Reservations hang on unclosed requests.** A subscription reserves the price
of a request at creation and releases it at fulfilment. An incident during which
92 of 100 requests went unfulfilled left **341 requests with a hanging
reservation** — 3.751e14 wei locked until a `refund` call, which is open to
anyone but only after `TIMEOUT_BLOCKS` (7,200). While they hang, the available
balance is understated and the subscription refuses with `InsufficientBalance`
on a perfectly live balance.

The economics of a refund run backwards: one `refund` transaction returns
1.1e-6 ETH and costs about 2.3e-6 ETH in gas. Refunding is worth it to unlock a
large deposit, not for the money itself.

**2. Funding is open to all; withdrawal is owner-only.** The deployment record
says `subscriptionId: 1`, but it is owned **not by the testnet deposit key** but
by the key from the previous deployment. Funding went through without a murmur
and turned out to be unrecoverable: 0.014 ETH went into someone else's
subscription. The load generator, meanwhile, works with subscription **4**,
which the deposit key does own.

Closed: `script/testnet.sh` now checks `ownerOf` against the deposit address
before funding and refuses to proceed on a mismatch, and
`deployments/testnet.json` names the owner and both subscriptions explicitly.

**3. The expensive part of a load run is the sender's gas, not the price of the
requests.** A batch of a hundred requests reserves 1.1e-4 ETH on the
subscription and costs **4.1e-4 ETH in gas** to whoever sends it: four times as
much. When planning a run, budget the sender's balance.
