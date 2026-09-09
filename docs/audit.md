# Internal audit

**Date:** 2026-09-04 · for the commit under review, see the git log
**Scope:** `src/*.sol` (2,387 lines), `node/` (Go), and the deployment and
operations process. This is **no substitute** for an external audit: there is
no independence here.

The review was not a top-to-bottom read but a series of attempts to break
things. Every finding that could be expressed as a test is expressed as a test:
`test/attacks/` holds 16 checks across four files, and each one fails if you
remove the defence it was written for. Below, each entry says where that was
verified.

---

## Summary

| # | What | Severity | Status |
|---|---|---|---|
| 1 | The "deliver once" invariant holds, but not for the stated reason | medium | closed by tests and a comment |
| 2 | The free tier lets a consumer bill the operators | **high** | mitigated: `perCallbackGasFee` is non-zero. Still present above a gas price of 0.47 gwei |
| 3 | The fulfilment fee can be stolen by copying the signature | medium | accepted risk, pinned by a test |
| 4 | A deposit larger than `uint96` was silently truncated | low | **fixed** |
| 5 | Unclosed requests hold an account hostage | informational | by design; the exit is open to everyone |
| 6 | Publication does not back off when the RPC fails | medium | open |
| 7 | ~40% of fulfilment transactions under a burst are wasted | medium | open |
| 8 | An empty publisher account was indistinguishable from a healthy node | **high** | **fixed** |
| 9 | The publication counter was labelled wrongly | low | **fixed** |
| 10 | The group key was born in a single process | **blocking** | **closed** — networked ceremony |
| 11 | Six of nine nodes at one provider | **blocking** | open |
| 12 | All operator shares live on one machine | high | closed by the ceremony, then deliberately weakened by a backup |

---

## 1. The "deliver once" invariant holds, but not for the stated reason

`retryCallback` exists to re-deliver the words to a consumer whose callback
reverted. A comment in the contract claimed that the `callbackSucceeded` flag
is what prevents a second delivery.

That is wrong **inside a reentrant call**. Both delivery paths write the flag
only after the callback returns, so a consumer still holding control sees its
own request as "fulfilled, not delivered" — precisely the state that
`retryCallback` serves.

The attack is not hypothetical in shape: the realistic form is a consumer that
pays someone from inside its callback (a lottery paying the winner, a game
paying the player), and the payee reenters. The callback runs twice on one
request, and a consumer that counts the payout as delivery pays twice.

**The invariant does hold nonetheless** — but for a different reason, one that
was written down nowhere. Delivery runs with at most `callbackGasLimit` gas,
while `retryCallback` demands that entire budget again on entry plus
`POST_CALLBACK_GAS`; the 64/63 rule only widens the gap. The callee physically
cannot satisfy the entry condition of the function that would deliver to it a
second time.

In other words the gas check carries a double load, and relaxing it to "enough
for the callback" would open a door that looks unrelated.

**Closed:** the dependency is written down in `src/VRFCoordinator.sol` and
pinned by `test/attacks/Delivery.t.sol`. The tests were checked to catch a
regression: replacing the condition with `gasleft() < POST_CALLBACK_GAS` makes
two of the three fail with "the re-entered retry was allowed through".

## 2. The free tier lets a consumer bill the operators

**High. Open — this needs your decision.**

With `baseFee = perWordFee = perCallbackGasFee = 0`, a request costs its author
nothing. The cost of fulfilling it is chosen by **that same author**:

- `callbackGasLimit` up to `maxCallbackGasLimit` = 2,500,000;
- `numWords` up to `MAX_WORDS` = 500.

The callback budget is only a ceiling in itself — an operator pays for gas
used, not gas allowed. But a consumer that **burns** the budget turns the
ceiling into an invoice. Measured in `test/attacks/Economics.t.sol`: at one and
the same zero price, the difference in operator spend exceeds 2,000,000 gas. A
500-word request is free for the requester and costs the operator over 300,000
gas.

The operator cannot refuse: it does not know how much of the budget the
callback will eat until it has paid for it.

This is not theory. The live testnet fleet stopped exactly this way **twice in
one day**: the publisher accounts ran dry, delivery fell from 100% to 8%, and
all the while the nodes kept scanning the chain, verifying and broadcasting
shares — every counter rising just as in a healthy run. A failure
indistinguishable from normal operation when seen from outside.

**Options:**

1. A non-zero `perCallbackGasFee` — the consumer pays for the budget it asks
   for. The direct fix; it makes requests more expensive.
2. Lower `maxCallbackGasLimit` and `MAX_WORDS` — reduces the lever, does not
   remove it.
3. Reimburse operators for gas through a separate mechanism — more complex, but
   the price to the consumer does not change.

Option 1 takes one line in the constructor and a decision about the price.
Launching a mainnet without one of the three is not viable: the operators will
run at a loss, and the only question is how many fulfilments it takes for the
fleet to stop.

## 3. The fulfilment fee can be stolen by copying the signature

Fulfilment is permissionless by design, and the proof travels in calldata.
Anyone who sees an operator's transaction before it lands in a block can send
the same bytes and take the fee without doing the work.

There is no defence in the contract and there cannot be: the signature has to
be public, or fulfilment is unverifiable. The defence lies in the sequencer's
ordering: Arbitrum Orbit serves transactions first-come, first-served, with no
priority auction, so there is nothing to outbid an in-flight transaction with.

**Accepted risk, pinned by the test**
`test_a_bystander_can_take_the_fee_by_copying_the_proof`. The value of the test
is that moving to any chain with a priority auction reopens this hole, and that
will be visible.

## 4. A deposit larger than `uint96` was silently truncated

`fundSubscriptionWithNative` cast `msg.value` to `uint96` without a check. An
amount above 2⁹⁶−1 wei would have been credited truncated, and the coin would
have stayed in the contract — with nothing on chain to say so.

Only reachable at unrealistic amounts (≈7.9·10¹⁰ ETH), hence low. But the
difference between an expensive mistake and an unrecoverable one is exactly
here.

**Fixed:** `DepositTooLarge`, with tests in `test/attacks/Accounting.t.sol`,
including the boundary and overflow across several deposits.

## 5. Unclosed requests hold an account hostage

A request nobody fulfilled is not a lost transaction: it holds a reservation,
and the reservation holds the account. The available balance is the balance
minus what is reserved, so a subscription starts refusing with
`InsufficientBalance` while its balance is untouched.

Observed live: an incident left **341** such requests, with 3.751e14 wei locked
up. The account cannot be closed either — `cancelSubscription` refuses while
requests are open, and rightly so: an owner must not walk away from work that
has been paid for.

The exit is `refund`, open to **anyone** after `TIMEOUT_BLOCKS`. That is
correct: the party that most needs the cleanup is the account owner, and it is
exactly a permissioned version that would let requests be held hostage.

The economics of a refund run backwards: one transaction returns 1.1e-6 ETH and
costs about 2.3e-6 ETH in gas. People refund to unlock the deposit, not for the
money itself.

**By design.** Pinned by five tests in `test/attacks/Starvation.t.sol`.

## 6. Publication does not back off when the RPC fails

`node/internal/node/node.go:447`. Before publishing, a node asks the chain
whether the request is still open:

```go
open, err := n.cfg.Chain.IsOpen(ctx, id)
if err == nil && !open { ... do not publish ... }
```

When the endpoint fails (429), `err != nil` and the node falls through — into
publishing. The logic is right by design: an endpoint failure is not the same
thing as another operator winning, and giving up there would abandon the
request forever.

But there is no backoff. Polling has one (`Watch`, tested in
`backoff_test.go`); publication does not. Under a 429, nine nodes hammer their
way into publishing in unison, which does not help the endpoint.

**Open.** The candidate fix is the same exponential backoff used in `Watch`.

## 7. Wasted fulfilment transactions under a burst

Measured: **70 sends for 50 fulfilments**, i.e. 40% of transactions revert.
Under a burst the publication delay (`PublishRank`) expires for several
operators at once, and they all send a transaction for the same request.

The behaviour is expected — the race is inherent to permissionless fulfilment.
But on mainnet it is money straight out of the operators' pockets.

**Open.** Candidates: stretch `-publish-delay` as the queue grows; wait for a
receipt before the next send.

## 8. An empty publisher account was indistinguishable from a healthy node

**Fixed.** For the details, see finding 2 and `docs/loadtest.md`.

A node exports `vrf_publisher_balance_wei` and logs a warning when it falls
below `-min-balance`. The value is cached and refreshed at most once a minute:
`/metrics` is open to the world without authentication, and a live read would
turn every scrape into an RPC call. A failed refresh keeps the previous value.
Until the balance has been read even once the metric is **absent** rather than
zero — otherwise "could not read it" is indistinguishable from "there is no
money". Seven tests.

## 9. The publication counter was labelled wrongly

**Fixed.** It was called "transactions this node **landed**" while counting the
ones it sent. On a transparency page that would have overstated an operator's
contribution.

## 10–12. Operational, blocking for mainnet

**10. The group key was born in a single process.** The current key was made by
`vrfdkg` on one machine: at the moment of its birth the whole secret sat in one
process's memory. Resharing does not cure this — it changes the shares, not the
secret. What is needed is a networked ceremony (`vrfceremony`) across nine
hosts.

**11. Six of nine nodes at one provider.** The threshold is 5. Google Cloud
holds 6, which is **above the threshold**: one provider could gather the shares
and sign any number it liked, and the contract would accept it. With that
layout the security model is decorative. The limit should be 4 nodes per
provider.

**12. All operator shares live on one machine.** Nine keystores in
`.testnet/keys` on a working laptop, passphrase `testnet`. Acceptable for a
testnet, not for mainnet: every operator must generate its own share, and that
share must never leave its server.

---

## What was checked and found sound

Not every check yields a finding; here is what was attacked and held.

**The verifier.** An immutable key, no owner, no proxy, no delegatecall; the
bytecode contains no state-changing opcodes, and that is checked by a test which
is itself checked against a decoy contract. The G2 subgroup is verified in the
constructor through the pairing precompile (EIP-197). G1 has cofactor 1, so the
only small-order point is infinity, and it is rejected. `verify` returns
`false` rather than reverting, on any garbage.

**Signature binding.** The seed is `keccak(requestId, consumer, address(this),
chainid)`. All four fields were attacked: a signature does not transfer between
coordinators, between chains, between consumers, or between requests. Negating
the point does not yield a second valid signature. Appended bytes are not
accepted.

**Nothing from the consumer in the seed.** Not the time, not the block hash,
not its calldata, not the amount paid. That is why
`minimumRequestConfirmations` is honestly zero: there is nothing to wait for.

**Money.** Reserved at creation, charged at fulfilment, paid out as **credit**
rather than a transfer — paying inside fulfilment would hand a reentrancy point
to whoever relays the transaction. An owner cannot withdraw what is reserved,
cannot close an account with open requests, and cannot immobilise a paid
request by removing the consumer. Account ownership transfer takes two steps.

**Price.** The ceilings are immutable and set at deploy time. A price change is
announced `FEE_TIMELOCK_BLOCKS` (~7 days) ahead, re-announcing restarts the
clock, anyone may apply it, and **a request already made keeps its price** —
`paid` is recorded in the request. The owner can renounce the power for good.

**The node.** Rate limiting on inbound shares, an allow-list of sources,
rejection of garbage bodies, refusal to sign a seed that disagrees with the
contract, a bounded store for early shares, and equivocation proofs. Re-sending
a share until quorum is reached. Publisher rotation.
