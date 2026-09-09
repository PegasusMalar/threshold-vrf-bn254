# VRF integration: the full guide

For anyone wiring randomness into their own contract. The ABIs are in
[frontend/abi/](frontend/abi/).

---

## 1. How it works over time

```
your contract  →  requestRandomWords(...)        transaction 1, the player pays
                  ↓  event carrying the seed
operators         sign the seed with their shares (off chain, ~a second)
                  ↓  5 of 9 collected
anyone         →  fulfillRandomWords(...)        transaction 2, the account pays
                  ↓
your contract  ←  fulfillRandomWords(requestId, words)
```

About **5 seconds** pass between the two transactions (P50 5.1 s, P95 5.8 s —
measured over 25 requests in a 5-of-9 configuration). The player signs only the
first; your account pays for the second.

## 2. Quick start

```
1. create an account on the site        → get a subId
2. deploy your contract with (coordinator, subId)
3. addConsumer(subId, contract address)  ← without this, requests revert
4. fund the account (the price may be zero at launch)
5. check that a request goes through
```

You need the `subId` **before** deploying the contract — create the account
first.

## 3. A minimal contract

```solidity
import {VRFConsumerBase} from "vrf/VRFConsumerBase.sol";
import {IVRFCoordinator} from "vrf/interfaces/IVRFCoordinator.sol";

contract MyGame is VRFConsumerBase {
    uint256 public immutable subId;

    constructor(address _vrfCoordinator, uint256 _subId) VRFConsumerBase(_vrfCoordinator) {
        subId = _subId;
    }

    function play() external payable {
        // the bet is taken HERE
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            IVRFCoordinator.RandomWordsRequest({
                keyHash: bytes32(0),        // 0 = the current group key
                subId: subId,
                requestConfirmations: 0,    // accepted, always satisfied
                callbackGasLimit: 150_000,  // you pay for it either way
                numWords: 1,
                extraArgs: ""               // empty = pay in the native coin
            })
        );
        // ... remember the requestId and the player
    }

    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords)
        internal override
    {
        // ... decide the outcome and write it to storage
    }
}
```

## 4. A full example: Plinko

[`test/examples/Plinko.sol`](../test/examples/Plinko.sol) is a working game
under test: a ball falls through 16 rows of pegs, left or right at each one, and
lands in one of 17 buckets.

It is covered by [eleven tests](../test/examples/Plinko.t.sol), so it cannot
drift out of step with reality. Here is what is worth copying from it.

### The bet is taken at request time

```solidity
function drop(uint32 balls) external payable returns (uint256 requestId) {
    uint96 stakePerBall = uint96(msg.value / balls);
    ...
    requestId = s_vrfCoordinator.requestRandomWords(...);
    _rounds[requestId] = Round({player: msg.sender, stakePerBall: ..., settled: false});
}
```

The money, the move and the claim on a prize are all fixed here. If a player
still has a way to change their mind between the request and the callback, then
they have a way to change their mind knowing more than you do.

### Entropy is packed, not ordered in bulk

16 rows is 16 bits per ball. A word holds 256 bits, so that is **16 balls per
word**:

```solidity
uint32 numWords = (balls + BALLS_PER_WORD - 1) / BALLS_PER_WORD;  // 16 balls = 1 word
```

```solidity
function bucketOfBall(uint256[] memory randomWords, uint32 index) public pure returns (uint8) {
    uint256 word = randomWords[index / BALLS_PER_WORD];
    uint256 path = (word >> ((index % BALLS_PER_WORD) * ROWS)) & ((1 << ROWS) - 1);
    // the bucket is simply the number of rights taken
    uint8 rights = 0;
    for (uint8 row = 0; row < ROWS; row++) if ((path >> row) & 1 == 1) rights++;
    return rights;
}
```

Ordering a word per ball means paying sixteen times over for the same entropy.
One word is 256 honest bits; slice them as you need.

As a bonus the distribution comes out binomial by itself: the bucket is the
number of ones in 16 bits, so the middle is likelier than the edges.

### The callback only writes to storage, and is idempotent

```solidity
function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
    Round storage round = _rounds[requestId];
    if (round.settled || round.player == address(0)) return;   // ← idempotence
    round.settled = true;
    ...
    _winnings[round.player] += payout;   // credit, do not send
}
```

Two lines, both mandatory. The first because `retryCallback` may deliver the
same words a second time. The second because sending ETH inside the callback
hands an arbitrary external call to whoever publishes the signature.

### The bankroll is checked before the round opens

```solidity
uint256 worstCase = (uint256(stakePerBall) * _multipliersBps[0] * balls) / 10_000;
if (address(this).balance < owed + worstCase) revert HouseCannotCover();
```

Otherwise a lucky player discovers the money is gone only after the draw. `owed`
is what has been credited but not withdrawn, so the same coin is never promised
twice.

### The payout table is verified, not eyeballed

The test computes the exact expected value over the binomial distribution and
requires it to be below 100%:

```
RTP = 98.98%, house edge 1.02%
```

One typo in a multiplier is the whole bankroll. A test like this is mandatory
for any game played for money.

## 5. Three rules you must not break

**1. The result arrives in a different transaction.** This is not a shortcoming
of the implementation but the reason for all of it: if the result came back
immediately, a consumer could revert its own transaction on a bad outcome and
get a free reroll.

**2. The bet closes at request time**, not at callback time.

**3. `requestId` is not a source of entropy.** It is public and computable in
advance: `keccak256(you, your nonce, coordinator, chainid)`.

And a fourth, specific to this system: **the callback must be idempotent**,
because `retryCallback` may deliver the same words again.

## 6. What a callback must and must not do

`fulfillRandomWords` is called with the `callbackGasLimit` you specified (up to
2,500,000), and its failure **does not revert** the fulfilment: otherwise a
buggy contract would block its own request forever.

| Do | Do not |
|---|---|
| write to storage | call other people's contracts |
| compute the outcome | send ETH to a recipient (`push`) |
| emit events | loop over unbounded arrays |
| set a "handled" flag | `revert` on any doubtful condition |

Payouts are `pull` only.

## 7. What it costs

`price(numWords, callbackGasLimit)` gives the price in wei right now. You pay
for the callback gas you order whether or not it is used.

```
price = baseFee + perWordFee × numWords + perCallbackGasFee × callbackGasLimit
```

The price can change, but only within limits:

| | |
|---|---|
| ceiling | set at deploy time and immutable: `maxBaseFee`, `maxPerWordFee`, `maxPerCallbackGasFee` |
| notice | 50,400 L1 blocks ≈ 7 days between announcement and effect |
| a request you already made | never repriced — `priceOf(requestId)` |

An announced change is visible ahead of time:
`pendingFeesEffectiveAtBlock != 0` plus a `FeeChangeProposed` event. If
`owner() == address(0)`, the price is frozen forever.

## 8. The account

| Method | What it does |
|---|---|
| `createSubscription()` | create an account; you are the owner |
| `fundSubscriptionWithNative(subId)` | fund it — anyone may, not just the owner |
| `withdrawFromSubscription(subId, amount, to)` | take part of it back without closing |
| `addConsumer(subId, addr)` | allow a contract to spend |
| `removeConsumer(subId, addr)` | revoke that |
| `cancelSubscription(subId, to)` | close it and take the remainder |
| `getSubscription(subId)` | balance, request count, owner, consumer list |
| `pendingRequestCount(subId)` | how many requests are open right now |

This is a **prepaid account, not a subscription**: it is charged per request,
nothing expires with time, and whatever is unspent can be taken back.

The price is reserved at request time and charged at fulfilment. While a
reservation stands, the account cannot be closed — otherwise an owner could
withdraw the balance between request and fulfilment, and the operators would
work for nothing.

**An account has no address of its own.** An account is the number `subId`, and
funding always goes through `fundSubscriptionWithNative(subId)`. A plain ETH
transfer reverts: there is no `receive` in the contract, because a transfer
carries no `subId`.

## 9. The five states of a request

```
1. sent                      transaction in the mempool
2. awaiting the signature    ~5 seconds
3. fulfilled, delivered      fulfilled && callbackSucceeded
4. fulfilled, NOT delivered  fulfilled && !callbackSucceeded
5. refunded on timeout       refunded
```

Read them from `requests(requestId)`.

### State 4: the callback reverted

The request is **not lost**. Fix the contract and call:

```solidity
coordinator.retryCallback(requestId, signature);
```

The signature comes from the calldata of the transaction that carried
`RandomWordsFulfilled`: strip the 4-byte selector and decode as
`fulfillRandomWords(uint256,bytes)`. The coordinator verifies it again and
delivers **the very same words** — substituting others is impossible. Anyone may
call it, no money is charged a second time, and it can be repeated as often as
you like. Once delivery succeeds the function refuses with
`CallbackAlreadyDelivered`.

If there is nothing to fix, the words can be derived from `randomness` yourself:

```
words[i] = keccak256(abi.encodePacked(randomness, requestId, i))
```

### State 5: the signature never came

After `TIMEOUT_BLOCKS` (7,200 **L1** blocks ≈ one day) anyone may call
`refund(requestId)` and the reservation is released. After a refund the request
can no longer be fulfilled, even with a valid signature: otherwise an operator
could hold the signature back, wait out the refund, and publish only the outcome
that suited them.

**Your contract must survive the "the callback never came" scenario.** For a bet
that means refunding the player through a button of your own, opened on the same
timeout.

> `block.number` on Robinhood Chain is the **L1** block number (≈12 s), not L2
> (0.1 s). `TIMEOUT_BLOCKS` is counted in those. If you set a timeout of your
> own, count it in the same units or you will be off by a factor of 120.

## 10. How to test your integration

### Locally, with no network

`./script/localnet.sh` brings up everything: a local chain, the key ceremony,
the contracts and three operators. It takes about twenty seconds. After that,
connect to `http://127.0.0.1:8545` and work with it as with a real network.

### In Foundry, with no operators

See [`Plinko.t.sol`](../test/examples/Plinko.t.sol): the test signs the seed
with a test key inside the test and calls `fulfillRandomWords` itself. The words
are derived by the same formula as in the contract, so the outcome in the test
is deterministic and checkable.

### On mainnet

The addresses are below and in
[`../deployments/mainnet.json`](../deployments/mainnet.json). Create an account,
add your contract, and make requests.

## 11. Addresses and limits

Robinhood Chain **4663**, RPC `https://rpc.mainnet.chain.robinhood.com`:

```
VRFCoordinator  0x1637195a674630E475ACD18B3D27b13C0EefDac1
Subscription    0x3fbFE73935B729C6A30AE6060D5708215b3633f5
VRFVerifier     0x035299fe87211f35f5F36FBBa67919f9545dDd16
```

The contracts are verified and the sources match the bytecode byte for byte:
[sourcify.dev/4663](https://repo.sourcify.dev/4663/0x1637195a674630E475ACD18B3D27b13C0EefDac1).

The testnet deployment is no longer served: the operators that ran it now work
on mainnet, so a request there will reserve funds and never be fulfilled.

```
numWords                1 … 500
callbackGasLimit        1 … 2,500,000
requestConfirmations    0 … 200   (accepted, always satisfied)
TIMEOUT_BLOCKS          7,200 L1 blocks ≈ one day
```

Hard-code none of it — read it all from the contract.

## 12. Pre-launch checklist

- [ ] the bet or move is fixed in the same transaction as the request
- [ ] the callback only writes to storage, never reverts, calls no foreign contracts
- [ ] the callback is idempotent — a repeat delivery doubles nothing
- [ ] payouts are `pull`, not `push`
- [ ] `callbackGasLimit` is measured on the worst case, not guessed
- [ ] there is a path for the player if the callback failed (`retryCallback`) — and it is in the UI
- [ ] there is a path if the signature never comes (your own timeout refund)
- [ ] the bankroll is checked before the round opens
- [ ] the expected payout is computed by a test, not estimated
- [ ] `requestId` takes no part anywhere in computing the outcome
- [ ] your own timeout is counted in L1 blocks, not L2
- [ ] the contract is added as a consumer of the account, and the account is funded

## 13. What you must not do

```
❌ decide the outcome from blockhash / block.timestamp / block.number
❌ decide the outcome from requestId
❌ accept a bet after the request
❌ push payouts inside the callback
❌ revert inside the callback
❌ assume the callback arrives exactly once
```
