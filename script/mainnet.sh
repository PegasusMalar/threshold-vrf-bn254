#!/usr/bin/env bash
# Deploys the stack to Robinhood Chain mainnet (4663).
#
#   VRF_DEPLOYER_KEY=0x... VRF_GROUP_KEY='[a,b,c,d]' VRF_EPOCH=1 \
#   VRF_PER_CALLBACK_GAS_FEE=<wei> ./script/mainnet.sh
#
# Deliberately not the testnet script with a different RPC. Three things are
# true on mainnet that are not true on testnet, and each one is a refusal here
# rather than a paragraph in a document nobody re-reads at 3am.
#
#   1. The group key may not come from a file. `vrfdkg` builds a key in one
#      process, which means one machine held the whole secret; no amount of
#      resharing afterwards changes which secret it is. Only `vrfceremony`
#      produces a key that never existed anywhere in full, and it deliberately
#      writes no group file — every operator prints the key and they must
#      match. So the key is passed in by hand, from what the operators
#      reported, and this script refuses the testnet key outright.
#
#   2. Operators must be paid for the gas they burn. At a zero
#      `perCallbackGasFee` the consumer picks how much gas fulfilment costs —
#      up to maxCallbackGasLimit, and it can burn all of it — while paying
#      nothing for it. The testnet fleet stopped twice in one day that way,
#      with every health counter green. See docs/audit.md, finding 2.
#
#   3. Nothing is reused. There is no --fresh here and no recorded deployment
#      to fall back on: a mainnet address that appears by accident is worse
#      than one that fails to appear.
set -euo pipefail
cd "$(dirname "$0")/.."

RPC=${VRF_RPC:-https://rpc.mainnet.chain.robinhood.com}
CHAIN_ID=4663
RECORD=deployments/mainnet.json
THRESHOLD=9
OPERATORS=9
QUORUM=5

# Ceilings, immutable once deployed. These are the only fee promise an
# integrator has to take on trust, so they are set wide enough never to need
# raising and low enough to mean something.
MAX_BASE_FEE=${VRF_MAX_BASE_FEE:-1000000000000000}          # 0.001 ETH
MAX_PER_WORD_FEE=${VRF_MAX_PER_WORD_FEE:-100000000000000}   # 0.0001 ETH
MAX_PER_GAS_FEE=${VRF_MAX_PER_GAS_FEE:-1000000000}          # 1 gwei per gas unit

# Prices, derived from measurement rather than taste. On Robinhood Chain at
# 0.392 gwei a fulfilment costs the operator about 190,000 gas of verification
# and bookkeeping — 0.0000745 ETH — plus whatever the consumer's callback burns.
#
#   baseFee            covers the 190,000 with ~34% margin
#   perWordFee         500 words cost ~230,000 extra gas, so ~460 gas a word
#   perCallbackGasFee  just above the chain's gas price, so the consumer pays
#                      for the budget it asks for
#
# That last one is the whole point. It is what turns the subscription deposit
# into a reimbursement instead of a decoration: without it the consumer picks
# how much gas fulfilment costs — up to maxCallbackGasLimit, which it is free
# to burn — and the operators pay for it. See docs/audit.md, finding 2.
#
# Charging for the budget *requested* rather than used over-charges a consumer
# that asks for more than it needs. That is deliberate: the price has to be
# fixed when the request is made, and it gives consumers a reason to ask for
# tight budgets, which is the same thing as closing the griefing lever.
BASE_FEE=${VRF_BASE_FEE:-100000000000000}                   # 0.0001 ETH
PER_WORD_FEE=${VRF_PER_WORD_FEE:-200000000}                 # ~460 gas a word
PER_CALLBACK_GAS_FEE=${VRF_PER_CALLBACK_GAS_FEE:-400000000} # 0.4 gwei per gas

die () { echo "!! $*" >&2; exit 1; }

: "${VRF_DEPLOYER_KEY:?set VRF_DEPLOYER_KEY}"
: "${VRF_GROUP_KEY:?set VRF_GROUP_KEY to [x0,x1,y0,y1] as the operators printed it}"
: "${VRF_EPOCH:?set VRF_EPOCH}"

# --- refusal 1: a key that one machine once held in full ---------------------
if [ -f .testnet/keys/group.json ]; then
    TESTNET_KEY=$(jq -r '.constructorArgs' .testnet/keys/group.json)
    if [ "$(echo "$VRF_GROUP_KEY" | tr -d ' ')" = "$(echo "$TESTNET_KEY" | tr -d ' ')" ]; then
        die "that is the testnet key, built by vrfdkg in a single process.
   One machine held the whole secret. Run script/ceremony.md across the
   operator hosts and use the key every one of them prints."
    fi
fi
[ -f .mainnet/keys/group.json ] && die "delete .mainnet/keys/group.json — a group
   file on one machine is exactly what a networked ceremony exists to avoid"

# --- refusal 2: operators working for free -----------------------------------
if [ "$PER_CALLBACK_GAS_FEE" = "0" ] && [ "${I_ACCEPT_UNPAID_OPERATORS:-}" != "yes" ]; then
    die "VRF_PER_CALLBACK_GAS_FEE=0 leaves operators paying for consumers' gas.
   Set I_ACCEPT_UNPAID_OPERATORS=yes if that is really the intent."
fi

# --- refusal 3: wrong chain ---------------------------------------------------
ON_CHAIN=$(cast chain-id --rpc-url "$RPC")
[ "$ON_CHAIN" = "$CHAIN_ID" ] || die "$RPC is chain $ON_CHAIN, expected $CHAIN_ID"
[ -f "$RECORD" ] && die "$RECORD already exists — mainnet is deployed once"

DEPLOYER=$(cast wallet address --private-key "$VRF_DEPLOYER_KEY")
send() { cast send --rpc-url "$RPC" --private-key "$VRF_DEPLOYER_KEY" --json "$@" | jq -r '.status'; }

echo "==> chain $ON_CHAIN, deployer $DEPLOYER"
echo "    balance $(cast from-wei "$(cast balance "$DEPLOYER" --rpc-url "$RPC")") ETH"
echo "    group key $VRF_GROUP_KEY epoch $VRF_EPOCH"
echo "    fees: base $BASE_FEE, per word $PER_WORD_FEE, per callback gas $PER_CALLBACK_GAS_FEE"
echo
printf 'deploy to MAINNET with these? type "deploy" to go ahead: '
read -r confirm
[ "$confirm" = "deploy" ] || die "not confirmed"

echo "==> building"
forge build >/dev/null

echo "==> verifier"
VERIFIER=$(forge create src/VRFVerifier.sol:VRFVerifier --rpc-url "$RPC" \
    --private-key "$VRF_DEPLOYER_KEY" --broadcast \
    --constructor-args "$VRF_GROUP_KEY" "$VRF_EPOCH" \
    | grep "Deployed to:" | awk '{print $3}')
[ -n "$VERIFIER" ] || die "verifier did not deploy"
echo "    $VERIFIER"

echo "==> coordinator"
COORDINATOR=$(forge create src/VRFCoordinator.sol:VRFCoordinator --rpc-url "$RPC" \
    --private-key "$VRF_DEPLOYER_KEY" --broadcast \
    --constructor-args "$VERIFIER" "$BASE_FEE" "$PER_WORD_FEE" "$PER_CALLBACK_GAS_FEE" \
    "$MAX_BASE_FEE" "$MAX_PER_WORD_FEE" "$MAX_PER_GAS_FEE" \
    | grep "Deployed to:" | awk '{print $3}')
[ -n "$COORDINATOR" ] || die "coordinator did not deploy"
SUBS=$(cast call "$COORDINATOR" "subscriptions()(address)" --rpc-url "$RPC")
echo "    $COORDINATOR"
echo "    $SUBS"

# The key the verifier ended up with, read back off the chain rather than
# echoed from the argument: if the constructor took something else, the record
# must say what is actually deployed.
KEY_HASH=$(cast call "$VERIFIER" "keyHash()(bytes32)" --rpc-url "$RPC")
FROM_BLOCK=$(cast block-number --rpc-url "$RPC")

jq -n --arg c "$COORDINATOR" --arg s "$SUBS" --arg v "$VERIFIER" \
      --arg k "$KEY_HASH" --arg d "$(date +%Y-%m-%d)" \
      --argjson e "$VRF_EPOCH" --argjson b "$FROM_BLOCK" \
      --argjson base "$BASE_FEE" --argjson word "$PER_WORD_FEE" \
      --argjson gas "$PER_CALLBACK_GAS_FEE" \
    '{network:"Robinhood Chain", chainId:4663,
      rpc:"https://rpc.mainnet.chain.robinhood.com",
      explorer:"https://robinhoodchain.blockscout.com",
      deployedAt:$d, deployedAtBlock:$b,
      coordinator:$c, subscription:$s, verifier:$v,
      keyHash:$k, keyEpoch:$e, threshold:5, operators:9,
      fees:{baseFee:$base, perWordFee:$word, perCallbackGasFee:$gas}}' > "$RECORD"

echo
echo "==> recorded in $RECORD"
echo
echo "next:"
echo "  1. every operator confirms $KEY_HASH matches the key it printed"
echo "  2. RECORD=$RECORD KEYS=.mainnet/keys ./script/deploy-node.sh <i>  for each"
echo "  3. fund each publishing account — they pay gas before they earn anything"
