# Threshold VRF for Robinhood Chain

On-demand VRF built on threshold BLS signatures (BN254). The signature for a
given seed is unique: an individual share reveals nothing, any `t` of `n`
operators produce the very same signature, and withholding is pointless.

**The interface is compatible with what integrators already have in their
code** — checked against the reference implementation's actual sources. The
`topic0` of the main events matches byte for byte, so an existing indexer works
unchanged. Where this design differs underneath is covered in
[docs/integration.md](docs/integration.md).

## Status

**Deployed on mainnet.** Robinhood Chain 4663, threshold 5 of 9, key from a
networked ceremony. The contracts are verified.

**Read this before taking the code to a mainnet of your own:**

- There has been no external audit. There is an internal review —
  [docs/audit.md](docs/audit.md) — written honestly, and it lists what is still
  open as well as what is closed.
- **Open blocking item (#11): six of the nine nodes sit with one provider.**
  A 5-of-9 threshold protects against five independent failures, not against
  one account at one cloud. Until the fleet spreads out, the real trust
  boundary is narrower than the scheme advertises.
- Operator shares were deliberately weakened by a backup after the ceremony
  (#12). Consider what that means in your own threat model.
- `deployments/operators.example.json` is a template. The real operator list,
  with server addresses and RPC keys, is not in this repository and must never
  be.

Deploying this as-is, without spreading the operators across independent
providers and without running your own ceremony, gives you a threshold scheme
on paper and a single point of failure in practice.

```
VRFCoordinator  0x1637195a674630E475ACD18B3D27b13C0EefDac1
Subscription    0x3fbFE73935B729C6A30AE6060D5708215b3633f5
VRFVerifier     0x035299fe87211f35f5F36FBBa67919f9545dDd16
```

The on-chain code is HEAD. The first deployment is tagged `mainnet-v1`; it does
not know `fulfillBatch`, so it does not verify against a fresh checkout — and
that is correct.

The whole path works end to end: a real DKG ceremony → deployed contracts →
three independent daemons exchanging shares → 5 of 9 aggregated → transaction
accepted. It comes up with one command:

```sh
./script/localnet.sh
```

| | mainnet 4663 |
|---|---|
| `verify()` | **165,564 gas** |
| of that, bare `ecPairing` k=2 | 113,131 — standard EIP-1108, no ArbOS surcharge |
| `requestRandomWords` | 53,552 |
| `fulfillRandomWords`, 1 word | 178,470 (empty callback) |
| full cycle in ETH | ≈ 1.1 × 10⁻⁵ |
| threshold | 5 of 9 (2 of 3 in debug) |

Latency on mainnet, nine operators on nine hosts, 30 consecutive requests:
**P50 4.08 s, P95 7.86 s**. None of that is cryptography — it is entirely RPC
round-trips plus the inclusion of two transactions.

## What is here

```
src/VRFVerifier.sol          threshold BLS signature check, immutable group key
src/VRFCoordinator.sol       requests, seed, permissionless fulfillment, timeout
src/Subscription.sol         balance, reservation, settlement (the only holder of ETH)
src/VRFConsumerBase.sol      what an integrator inherits
test/examples/CoinFlip.sol   a simple integration example, under test
test/examples/Plinko.sol     a full example: 16 rows, entropy packing, bankroll

node/cmd/vrfnode             the operator daemon
node/cmd/vrfceremony         networked key ceremony: one process per operator
node/cmd/vrfdkg              single-process ceremony for localnet and testnet
node/internal/blsvrf         BLS on BN254 in exactly the form the contract accepts
node/internal/dkg            Pedersen DKG and resharing (drand/kyber)
node/internal/dkgnet         the same ceremony over the network; nobody sees another's share
node/internal/session        share collection, per-share verification, equivocation evidence
node/internal/mesh           share exchange between operators over HTTP
node/internal/chain          reading events and publishing the signature

offchain/src/threshold.ts    independent TS implementation, for test vectors
script/bench.sh              gas measurement on the target network, no deploy, no funds
script/localnet.sh           the entire stand in one command
script/operators.sh          running the operators continuously, and publishing their status
node/cmd/vrfstatus           read-only metrics window for the outside world
script/testnet.sh            deploy to 46630 and measure latency
```

205 Solidity tests (attacks, 11 invariants under fuzzing, benchmarks) and 106 Go
tests, including an end-to-end run against a live chain and a networked ceremony
over real HTTP. Plus 4 TypeScript tests covering the independent implementation.

Not here yet: an operator registry, staking, slashing, metrics.

## How it works

```
Consumer.requestRandomWords()  →  funds reserved, event RequestCreated(requestId, seed)
operators sign the seed with their shares (off chain)
5 shares collected  →  ONE aggregated signature
anyone publishes it on chain  →  Verifier checks it  →  callback to the consumer
```

Anyone can publish, including the consumer itself: the signature for a given
seed is unique, so bringing "the wrong" result is impossible. This is
protection against your own relayer going down, not a convenience.

If the threshold is never reached, then after `TIMEOUT_BLOCKS` (≈ one day)
anyone may call `refund` and the reservation is released. After a refund the
request can no longer be fulfilled — otherwise an operator could hold the
signature back and publish only the outcome that suited them.

If the signature arrives but the consumer's callback reverts, the request is
not lost: anyone may call `retryCallback(requestId, signature)` — the same
signature is verified again and delivers the very same words. There is no
second charge, and once delivery succeeds the function refuses, so nothing can
be delivered twice.

## How a node is built

Every node is its own aggregator: it broadcasts its share to all the others
over HTTP and collects theirs. There is no central aggregator, no leader, and
no node whose failure stops the service. A share does not need a separate
signature — a partial signature is checked against the public key of the share
it claims to be, so it cannot be forged under someone else's index.

Publication order is deterministic: `rank = (index − requestId) mod n`. Rank 0
publishes immediately; the rest wait and usually find the request already
closed — otherwise eight of nine would be paying for a revert. The leader
changes from request to request.

Details: [docs/operator.md](docs/operator.md).
Server deployment: [docs/deployment.md](docs/deployment.md).

## For integrators

Read [docs/integration.md](docs/integration.md) — the full guide, with
[Plinko](test/examples/Plinko.sol) walked through as a working example and a
pre-launch checklist. Three rules from it, in brief:

1. The result arrives in **a different transaction** — that is what closes off
   revert farming.
2. The bet is closed **at request time**, not at callback time.
3. `requestId` is **not a source of entropy** — it is public and computable in
   advance.

The ABIs are in [docs/frontend/abi/](docs/frontend/abi/).

## Cryptography

- The **BN254** curve — the `ecAdd (0x06)`, `ecMul (0x07)` and
  `ecPairing (0x08)` precompiles exist for it.
- Pairing and hash-to-curve come from
  [kevincharm/bls-bn254](https://github.com/kevincharm/bls-bn254) v2.0.0
  (pinned at commit `9f70fb4`), SvdW mapping per RFC 9380 §6.6.1. There is no
  home-grown BLS cryptography in this project.
- DKG and resharing come from [drand/kyber](https://github.com/drand/kyber)
  `share/dkg` (Pedersen) over `pairing/bn254`. There is no home-grown DKG
  either.
- There are **three implementations and they are independent**: Solidity
  (kevincharm), Go (drand/kyber), TypeScript (mcl-wasm, noble-curves). All
  three must agree byte for byte on the shared vectors, so an identical bug
  would have to appear in all three at once for the tests to miss it. CI runs a
  fresh DKG ceremony on every run and requires the contract to accept its
  signature.
- The DST is fixed forever: `RH-VRF-BN254G1_XMD:KECCAK-256_SVDW_RO_V1_`. It is
  part of the on-chain interface, not configuration.

### Subgroups

G1 on BN254 has cofactor 1: any point on the curve other than infinity is
already in the order-r subgroup. So the entire small-subgroup defence on an
attacker-controlled input is rejecting the point (0, 0). That claim is pinned
by a test rather than left to trust.

G2 has a large cofactor, and there the subgroup is checked — once, in the
constructor, through the pairing precompile (per EIP-197 it fails the call on a
point outside the subgroup; there is no G2 scalar multiplication on the EVM).

## Key rotation

**Resharing preserves the group public key** — verified by test, including the
case where one operator leaves and a new one takes their place, and separately
for the networked ceremony over real HTTP. So the deployed `VRFVerifier` stays
valid, integrations notice nothing, and the verifier needs no epoch registry.
A departed operator's share does not combine with the new ones into a valid
signature after rotation — that is under test too.

If the scheme did change the key, rotation would mean deploying a new verifier
for the new epoch, and the old one would remain able to verify old signatures
forever. The `epoch` field in the verifier is kept for exactly that case.

## Contract boundaries

| Contract | Holds | Owner |
|---|---|---|
| `VRFVerifier` | nothing | **none**, and the bytecode proves it |
| `VRFCoordinator` | nothing | yes, but only for price — see below |
| `Subscription` | ETH | none; only the owner of a given subscription |

`VRFVerifier` has no owner, no proxy, no `delegatecall`, and no way to switch
the check off — and that claim is tested not by reading the source but by
scanning the bytecode for `SSTORE`, `CALL`, `DELEGATECALL`, `CREATE`,
`SELFDESTRUCT` and `LOG`. The scanner itself is under test as well: it is
required to catch a separate contract that does contain an `SSTORE`.

`verify()` never reverts on any garbage input; it returns `false`. A revert
would give a griefer something to work with, choosing between two different
failure modes of the coordinator.

### The only privilege in the whole system

The coordinator has an owner, and that owner can do exactly one thing: propose
a new price. Not touch requests, not touch funds, not touch the verifier. And
even that comes with three constraints:

- **The ceiling is set at deploy time and is immutable.** The price can never
  be raised above it. This is the single promise about fees that an integrator
  takes on trust, and it is given once.
- **A week of notice.** A change takes effect after `FEE_TIMELOCK_BLOCKS`
  (50,400 L1 blocks ≈ 7 days). Proposing again restarts the clock, so nobody
  can wait out the delay and then swap the number.
- **A request already made is never repriced.** The price is written into the
  request itself at creation, and exactly that price is charged. "We raised the
  price" never means "we raised the price on work you already ordered".

The owner may **give this up permanently** — `renounceOwnership()` freezes the
current price and removes the last privileged function from the system. That is
the intended end state, once pricing settles.

Launching free costs the contract nothing: `baseFee` and `perWordFee` are set to
zero. The free tier itself requires nothing special — anyone may fund anyone
else's account, so "the first thousand requests are on us" is just a transfer.

## Running it

```sh
forge test                                     # 205 tests
forge test --fuzz-runs 2000                    # deeper
FOUNDRY_INVARIANT_RUNS=256 forge test          # heavy invariant campaign
forge snapshot                                 # gas snapshot

cd node && go test ./...                       # operator node and ceremony
go test -tags integration ./...                # end-to-end run against anvil
go test ./internal/blsvrf -bench .             # cost of the cryptography

cd offchain && npm install && npm test         # independent TS implementation
npm run gen:vectors                            # regenerate test/vectors/bls.json

./script/localnet.sh                           # the whole stand: chain, keys, contracts, 3 nodes
VRF_DEPLOYER_KEY=0x... ./script/testnet.sh 25  # deploy to 46630 and measure latency
./script/bench.sh https://rpc.mainnet.chain.robinhood.com
```

Compiled for `evm_version = "cancun"`: both networks run ArbOS 61
(`ArbSys.arbOSVersion() == 116`), and `PUSH0` and `MCOPY` were checked live.

## License

MIT — see [LICENSE](LICENSE). Every contract in `src/` already carries
`SPDX-License-Identifier: MIT`.

## Building after cloning

`lib/` holds submodules; their contents are not in this repository:

```sh
git clone --recurse-submodules <url>
# or, if you have already cloned:
forge install
```
