package chain

import (
	"context"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
)

// ClaimMargin is how many times over the earnings must exceed the cost of
// collecting them before it is worth a transaction.
//
// Three, not one. At one the operator breaks even and has spent a block's
// worth of everyone's time to do it; worse, nine operators each claiming the
// moment it is barely worthwhile is a self-inflicted load on the very
// endpoints that are the fleet's tightest limit.
const ClaimMargin = 3

// ShouldClaim decides whether an operator should collect what it has earned.
//
// The fee for a fulfilment is not paid into the operator's wallet. It is
// credited inside the subscription contract and stays there until somebody
// calls withdraw, so an operator that never claims watches its gas balance
// fall to nothing while its earnings sit a call away. That is not a
// hypothetical: it is how the testnet fleet stopped twice in one day, and
// setting a non-zero fee does not fix it on its own — the money is earned
// either way, and uncollected either way.
//
// Two conditions, and both matter. Only when the balance has fallen to the
// floor, because a claim is a transaction and an operator that sweeps after
// every fulfilment spends a slice of each fee on the sweeping. And only when
// the earnings are worth several times that transaction, because collecting
// less than it costs makes the operator poorer, not richer.
//
// A nil for either figure means "not known", which is not the same as zero: a
// node that could not read its balance must not conclude it is broke and start
// sending transactions about it.
func ShouldClaim(balance, earnings, floor, claimCost *big.Int) bool {
	if balance == nil || earnings == nil || floor == nil || claimCost == nil {
		return false
	}
	if balance.Cmp(floor) >= 0 {
		return false
	}
	worthwhile := new(big.Int).Mul(claimCost, big.NewInt(ClaimMargin))
	return earnings.Cmp(worthwhile) > 0
}

// WithdrawableOf is what the subscription has credited to an address and not
// yet paid out.
func (c *Client) WithdrawableOf(ctx context.Context, who common.Address) (*big.Int, error) {
	subs, err := c.Subscription(ctx)
	if err != nil {
		return nil, err
	}
	data, err := c.subsABI.Pack("withdrawableOf", who)
	if err != nil {
		return nil, err
	}
	res, err := c.callTo(ctx, subs, data)
	if err != nil {
		return nil, err
	}
	values, err := c.subsABI.Unpack("withdrawableOf", res)
	if err != nil || len(values) != 1 {
		return nil, fmt.Errorf("chain: decoding withdrawableOf: %w", err)
	}
	amount, ok := values[0].(*big.Int)
	if !ok {
		return nil, fmt.Errorf("chain: withdrawableOf returned %T", values[0])
	}
	return amount, nil
}

// Claim collects this operator's earnings into its own account.
func (c *Client) Claim(ctx context.Context) (common.Hash, error) {
	subs, err := c.Subscription(ctx)
	if err != nil {
		return common.Hash{}, err
	}
	data, err := c.subsABI.Pack("withdraw", c.from)
	if err != nil {
		return common.Hash{}, err
	}
	return c.send(ctx, subs, data, ClaimGas)
}

// Subscription is where the money lives, read from the coordinator rather than
// configured: one address in the node's flags, and no way for the two to
// disagree about which subscription contract belongs to which coordinator.
func (c *Client) Subscription(ctx context.Context) (common.Address, error) {
	if c.subscription != (common.Address{}) {
		return c.subscription, nil
	}
	data, err := c.abi.Pack("subscriptions")
	if err != nil {
		return common.Address{}, err
	}
	res, err := c.call(ctx, data)
	if err != nil {
		return common.Address{}, err
	}
	values, err := c.abi.Unpack("subscriptions", res)
	if err != nil || len(values) != 1 {
		return common.Address{}, fmt.Errorf("chain: decoding subscriptions: %w", err)
	}
	addr, ok := values[0].(common.Address)
	if !ok {
		return common.Address{}, fmt.Errorf("chain: subscriptions returned %T", values[0])
	}
	c.subscription = addr
	return addr, nil
}

// ClaimGas is what collecting earnings costs in gas, and the limit a claim is
// sent under. A fixed figure rather than an estimate: it is one storage write
// and one transfer, it does not vary with anything, and asking the endpoint
// would spend a round trip to learn a constant.
//
// It has to be its own limit rather than the fulfilment's. Only gas spent is
// charged, but the *whole* limit must be covered by the balance before the
// chain accepts the transaction, so a claim sent under a fulfilment's limit
// would demand ten times what it can possibly spend — from an account whose
// being nearly empty is the reason the claim is happening.
const ClaimGas = 60_000

// ClaimCost is what a claim would cost at the moment, in wei.
func (c *Client) ClaimCost(ctx context.Context) (*big.Int, error) {
	tip, baseFee, err := c.fees(ctx)
	if err != nil {
		return nil, err
	}
	perGas := new(big.Int).Add(tip, new(big.Int).Mul(baseFee, big.NewInt(2)))
	return perGas.Mul(perGas, big.NewInt(ClaimGas)), nil
}
