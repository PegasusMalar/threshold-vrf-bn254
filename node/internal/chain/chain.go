// Package chain is the node's only contact with the blockchain: it watches for
// requests and publishes finished signatures.
//
// Publishing is deliberately a race that anyone may enter. The signature for a
// seed is unique, so a second publisher cannot change the outcome — the loser
// simply sees the request already closed and drops its transaction. That is why
// no leader election lives here.
package chain

import (
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
)

// Request is a RequestCreated event, decoded.
type Request struct {
	ID               *big.Int
	KeyHash          common.Hash
	SubID            uint64
	Consumer         common.Address
	Seed             [32]byte
	NumWords         uint32
	CallbackGasLimit uint32
	Block            uint64
	TxHash           common.Hash
}

// Client talks to one coordinator on one chain.
type Client struct {
	eth         *ethclient.Client
	abi         abi.ABI
	subsABI     abi.ABI
	coordinator common.Address
	// Read from the coordinator on first use, not configured: one address in
	// the node's flags, and no way for the two to disagree.
	subscription common.Address
	key          *ecdsa.PrivateKey
	from         common.Address
	chainID      *big.Int
	gasLimit     uint64
	// Widest block range this endpoint will accept in one eth_getLogs. Providers
	// cap it and the caps differ by orders of magnitude — Alchemy's free tier
	// allows ten, others tens of thousands. Zero means no limit.
	maxLogRange uint64
	// Pause between those calls. Splitting a wide scan into many small ones
	// trades a range limit for a rate limit: two thousand blocks at ten per
	// call is two hundred requests, and a free tier answers a burst like that
	// with 429 instead.
	logChunkPause time.Duration

	feeMu         sync.Mutex
	feeAt         time.Time
	cachedTip     *big.Int
	cachedBaseFee *big.Int

	// Nonces are handed out here, not read from the chain per transaction.
	// The chain reports the same pending nonce for every fulfilment prepared
	// before any of them is mined, so a burst would sign them all with one
	// number and lose all but the first to "nonce too low".
	nonceMu   sync.Mutex
	nextNonce uint64
	haveNonce bool
}

// DefaultGasLimit covers fulfillRandomWords with the full callback budget
// available. Unused gas is not charged.
const DefaultGasLimit = 750_000

// FulfilOverhead is what a fulfilment costs before the consumer's callback: the
// pairing, the hash-to-curve, the settlement and the event, measured cold at
// about 200,000 with a trivial callback. Rounded up, because a limit that is
// slightly too large costs nothing and one that is slightly too small costs the
// whole transaction.
const FulfilOverhead = 240_000

// FulfilGasLimit is the transaction limit for fulfilling one request.
//
// Unused gas is not charged, so a generous limit looks free — and is not. The
// balance has to cover limit × fee cap before the chain will accept the
// transaction at all, so sending every request under the limit the largest
// possible callback would need freezes several times the float an ordinary
// request requires. At a 100,000-gas callback that is the difference between
// holding 0.00022 ETH and holding 0.00056.
//
// The 64/63 rule is why the callback budget is scaled up rather than added
// as-is: a callee only ever receives 63/64 of what is left, and the coordinator
// refuses to start unless the whole budget is available to it.
func FulfilGasLimit(callbackGasLimit uint32) uint64 {
	return uint64(callbackGasLimit)*64/63 + FulfilOverhead
}

// Dial connects and checks that the coordinator address actually holds code —
// a misconfigured address would otherwise look like a chain that never emits
// any requests.
func Dial(ctx context.Context, rpcURL string, coordinator common.Address, key *ecdsa.PrivateKey) (*Client, error) {
	eth, err := ethclient.DialContext(ctx, rpcURL)
	if err != nil {
		return nil, fmt.Errorf("chain: dial: %w", err)
	}
	parsed, err := parsedABI()
	if err != nil {
		return nil, err
	}
	subsParsed, err := parsedSubscriptionABI()
	if err != nil {
		return nil, err
	}
	chainID, err := eth.ChainID(ctx)
	if err != nil {
		return nil, fmt.Errorf("chain: chain id: %w", err)
	}
	code, err := eth.CodeAt(ctx, coordinator, nil)
	if err != nil {
		return nil, fmt.Errorf("chain: code at coordinator: %w", err)
	}
	if len(code) == 0 {
		return nil, fmt.Errorf("chain: no contract at %s", coordinator)
	}

	c := &Client{
		eth: eth, abi: parsed, subsABI: subsParsed, coordinator: coordinator,
		key: key, chainID: chainID, gasLimit: DefaultGasLimit,
	}
	if key != nil {
		c.from = crypto.PubkeyToAddress(key.PublicKey)
	}
	return c, nil
}

func (c *Client) Close()                  { c.eth.Close() }
func (c *Client) ChainID() *big.Int       { return c.chainID }
func (c *Client) Address() common.Address { return c.from }

// BlockNumber is the chain head. On an Orbit chain this is the L2 height, which
// is what log filtering uses — note it is not what `block.number` returns
// inside the EVM there.
func (c *Client) BlockNumber(ctx context.Context) (uint64, error) {
	return c.eth.BlockNumber(ctx)
}

// RequestsBetween returns every request created in the given block range.
func (c *Client) RequestsBetween(ctx context.Context, from, to uint64) ([]Request, error) {
	requests, _, err := c.eventsBetween(ctx, from, to)
	return requests, err
}

// eventsBetween reads new requests and settled ones in a single filter call.
//
// Both in one call on purpose: an operator that has just seen a request
// fulfilled does not have to ask the chain whether it still needs publishing,
// and with nine operators and a burst of fifty that one saved call per operator
// per request is the difference between a working service and a throttled one.
func (c *Client) eventsBetween(ctx context.Context, from, to uint64) ([]Request, []*big.Int, error) {
	requested := c.abi.Events["RandomWordsRequested"].ID
	fulfilled := c.abi.Events["RandomWordsFulfilled"].ID

	var logs []types.Log
	for i, chunk := range chunkRange(from, to, c.maxLogRange) {
		if i > 0 && c.logChunkPause > 0 {
			select {
			case <-ctx.Done():
				return nil, nil, ctx.Err()
			case <-time.After(c.logChunkPause):
			}
		}
		part, err := c.eth.FilterLogs(ctx, ethereum.FilterQuery{
			FromBlock: new(big.Int).SetUint64(chunk[0]),
			ToBlock:   new(big.Int).SetUint64(chunk[1]),
			Addresses: []common.Address{c.coordinator},
			Topics:    [][]common.Hash{{requested, fulfilled}},
		})
		if err != nil {
			return nil, nil, fmt.Errorf("chain: filter logs: %w", err)
		}
		logs = append(logs, part...)
	}

	out := make([]Request, 0, len(logs))
	var settled []*big.Int
	for _, l := range logs {
		if len(l.Topics) == 0 {
			continue
		}
		switch l.Topics[0] {
		case requested:
			req, err := c.decodeRequest(l)
			if err != nil {
				return nil, nil, err
			}
			out = append(out, req)
		case fulfilled:
			// requestId is the first indexed field
			if len(l.Topics) > 1 {
				settled = append(settled, new(big.Int).SetBytes(l.Topics[1][:]))
			}
		}
	}
	return out, settled, nil
}

// reserveNonce returns the number to sign the next transaction with. Callers
// must hold nonceMu.
//
// The chain is consulted only when this client has no counter it can trust:
// asking per transaction is what produced a burst of identical nonces, since
// none of them is mined by the time the next is prepared.
func (c *Client) reserveNonce(ctx context.Context) (uint64, error) {
	if !c.haveNonce {
		nonce, err := c.eth.PendingNonceAt(ctx, c.from)
		if err != nil {
			return 0, err
		}
		c.nextNonce = nonce
		c.haveNonce = true
		return nonce, nil
	}
	return c.nextNonce, nil
}

// WatchOptions configures the polling loop.
type WatchOptions struct {
	// From is the first block to scan.
	From uint64
	// Interval between polls.
	Interval time.Duration
	// OnRequest receives every request found, in order.
	OnRequest func(Request)
	// OnFulfilled reports every request seen settled on chain. Knowing this
	// locally is what saves an operator from asking the chain, one call per
	// request, whether it still has work to do.
	OnFulfilled func(id *big.Int)
	// OnScanned reports the highest block successfully scanned, whether or not
	// it held any requests. Without it, a node that has stopped scanning is
	// indistinguishable from one on a quiet chain.
	OnScanned func(head uint64)
	// MaxInterval caps how far the loop backs off when polls keep failing.
	// Defaults to 30x Interval.
	MaxInterval time.Duration
	// OnError sees every failed poll. The loop keeps going — a chain that is
	// briefly unreachable is not a reason to stop — but a failure that repeats
	// forever must not do so in silence.
	OnError func(error)
	// Nudge cuts the wait short. Anything arriving on it means "there may be
	// something now", and the loop scans instead of sitting out its interval.
	//
	// It is an accelerator and never a source of truth. Correctness belongs to
	// the poll: a nudge that never comes costs latency and nothing else, which
	// is what makes it safe to feed from a websocket subscription — the thing
	// this loop deliberately avoided depending on.
	Nudge <-chan struct{}
}

// Watch polls for new requests.
//
// Polling rather than a subscription on purpose: Orbit RPC endpoints do not
// reliably offer websockets, and a dropped subscription that silently stops
// delivering is worse than a poll that is a second late.
func (c *Client) Watch(ctx context.Context, o WatchOptions) error {
	next := o.From
	report := func(err error) {
		if o.OnError != nil && err != nil {
			o.OnError(err)
		}
	}

	maxWait := o.MaxInterval
	if maxWait <= 0 {
		maxWait = 30 * o.Interval
	}
	wait := o.Interval

	for {
		failed := false
		head, err := c.BlockNumber(ctx)
		if err != nil {
			failed = true
			report(fmt.Errorf("chain: reading the head: %w", err))
		} else if head >= next {
			requests, settled, err := c.eventsBetween(ctx, next, head)
			if err != nil {
				failed = true
				report(err)
			} else {
				// settled first: a request that arrived and was fulfilled
				// inside the same scan needs no work at all
				if o.OnFulfilled != nil {
					for _, id := range settled {
						o.OnFulfilled(id)
					}
				}
				for _, r := range requests {
					o.OnRequest(r)
				}
				next = head + 1
				if o.OnScanned != nil {
					o.OnScanned(head)
				}
			}
		}

		// A shared RPC endpoint answering nine operators pushes back by
		// refusing. Polling it at the same rate is then not merely useless, it
		// is what keeps it refusing — so slow down while it hurts, and come
		// straight back to full speed once it does not.
		if failed {
			wait *= 2
			if wait > maxWait {
				wait = maxWait
			}
		} else {
			wait = o.Interval
		}

		if err := c.waitOrNudge(ctx, jitter(wait), o.Nudge); err != nil {
			return err
		}
	}
}

// waitOrNudge sleeps out the interval, or returns early when something says
// there is work now.
//
// The floor is what keeps a broken subscription from being worse than none. A
// closed channel is always ready to receive, so a subscription that dies would
// otherwise turn this loop into a scan as fast as the endpoint can answer —
// nine nodes doing that is how an endpoint starts refusing. Under load the same
// floor is what coalesces a burst of logs into one scan: they arrive per
// request, and one scan collects all of them.
func (c *Client) waitOrNudge(ctx context.Context, wait time.Duration, nudge <-chan struct{}) error {
	const floor = 25 * time.Millisecond

	timer := time.NewTimer(wait)
	defer timer.Stop()

	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	case <-nudge:
		// A nil channel blocks for ever, which is exactly right when no
		// subscription is feeding this loop.
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(floor):
			return nil
		}
	}
}

// jitter spreads the next poll over the last fifth of the interval. Nine
// operators started by the same script would otherwise poll in lockstep for
// ever, turning every one of their polls into a burst of nine.
func jitter(d time.Duration) time.Duration {
	if d <= 0 {
		return d
	}
	spread := d / 5
	if spread <= 0 {
		return d
	}
	n, err := rand.Int(rand.Reader, big.NewInt(int64(spread)))
	if err != nil {
		return d
	}
	return d + time.Duration(n.Int64())
}

// decodeRequest reads a RandomWordsRequested log.
//
// Field order and indexing follow Chainlink's event of the same name, so the
// request id lives in the data rather than in a topic: the indexed slots are
// spent on keyHash, subId and sender, which is what an integrator's existing
// indexer expects to filter on.
func (c *Client) decodeRequest(l types.Log) (Request, error) {
	if len(l.Topics) != 4 {
		return Request{}, errors.New("chain: RandomWordsRequested with unexpected topics")
	}
	var body struct {
		RequestId            *big.Int
		Seed                 *big.Int
		RequestConfirmations uint16
		CallbackGasLimit     uint32
		NumWords             uint32
		ExtraArgs            []byte
	}
	if err := c.abi.UnpackIntoInterface(&body, "RandomWordsRequested", l.Data); err != nil {
		return Request{}, fmt.Errorf("chain: decode RandomWordsRequested: %w", err)
	}
	var seed [32]byte
	body.Seed.FillBytes(seed[:])

	return Request{
		ID:               body.RequestId,
		KeyHash:          l.Topics[1],
		SubID:            new(big.Int).SetBytes(l.Topics[2].Bytes()).Uint64(),
		Consumer:         common.BytesToAddress(l.Topics[3].Bytes()),
		Seed:             seed,
		NumWords:         body.NumWords,
		CallbackGasLimit: body.CallbackGasLimit,
		Block:            l.BlockNumber,
		TxHash:           l.TxHash,
	}, nil
}

// SeedOf asks the contract what it expects to be signed. The node computes the
// seed from the event as well; disagreement means the node is out of step with
// the deployed coordinator and must not sign.
func (c *Client) SeedOf(ctx context.Context, requestID *big.Int) ([32]byte, error) {
	var out [32]byte
	data, err := c.abi.Pack("seedOf", requestID)
	if err != nil {
		return out, err
	}
	res, err := c.call(ctx, data)
	if err != nil {
		return out, err
	}
	values, err := c.abi.Unpack("seedOf", res)
	if err != nil {
		return out, err
	}
	return values[0].([32]byte), nil
}

// IsOpen reports whether a request still needs a signature.
func (c *Client) IsOpen(ctx context.Context, requestID *big.Int) (bool, error) {
	data, err := c.abi.Pack("requests", requestID)
	if err != nil {
		return false, err
	}
	res, err := c.call(ctx, data)
	if err != nil {
		return false, err
	}
	values, err := c.abi.Unpack("requests", res)
	if err != nil {
		return false, err
	}
	consumer := values[0].(common.Address)
	fulfilled := values[4].(bool)
	refunded := values[5].(bool)
	return consumer != (common.Address{}) && !fulfilled && !refunded, nil
}

// Fulfill publishes the group signature.
func (c *Client) Fulfill(
	ctx context.Context, requestID *big.Int, signature []byte, callbackGasLimit uint32,
) (common.Hash, error) {
	if c.key == nil {
		return common.Hash{}, errors.New("chain: no key configured, this node cannot publish")
	}
	data, err := c.abi.Pack("fulfillRandomWords", requestID, signature)
	if err != nil {
		return common.Hash{}, err
	}

	// Sized for this request rather than for the largest one the coordinator
	// would accept. An explicit -gas-limit still wins, for an operator with a
	// reason to distrust the arithmetic.
	limit := FulfilGasLimit(callbackGasLimit)
	if c.gasLimit != DefaultGasLimit {
		limit = c.gasLimit
	}
	return c.send(ctx, c.coordinator, data, limit)
}

// send signs and broadcasts one transaction to `to`.
//
// Shared by every call the node makes, because the nonce discipline is the
// part that must not be reimplemented: two transactions signed with the same
// number is the failure this exists to prevent, and a second copy of the logic
// is a second chance to get it wrong.
func (c *Client) send(ctx context.Context, to common.Address, data []byte, gas uint64) (common.Hash, error) {
	if c.key == nil {
		return common.Hash{}, errors.New("chain: no key configured, this node cannot publish")
	}
	tip, baseFee, err := c.fees(ctx)
	if err != nil {
		return common.Hash{}, err
	}

	// Held across the send: two transactions signed with the same number is
	// exactly the failure this replaces, and releasing before the send would
	// reintroduce it.
	c.nonceMu.Lock()
	defer c.nonceMu.Unlock()

	nonce, err := c.reserveNonce(ctx)
	if err != nil {
		return common.Hash{}, err
	}

	tx := types.NewTx(&types.DynamicFeeTx{
		ChainID:   c.chainID,
		Nonce:     nonce,
		GasTipCap: tip,
		GasFeeCap: new(big.Int).Add(tip, new(big.Int).Mul(baseFee, big.NewInt(2))),
		// A fixed limit rather than an estimate: eth_estimateGas is a round
		// trip on the hot path, and the answer is knowable in advance. Per
		// call, though, not per client: only what is spent is charged, but the
		// whole limit has to be *covered* by the balance before the chain will
		// accept the transaction at all. Sending a 60k-gas claim under a
		// fulfilment's 560k limit therefore demands ten times what the claim
		// can spend — and an operator poor enough to need its earnings would
		// be too poor to go and collect them.
		Gas:  gas,
		To:   &to,
		Data: data,
	})
	signed, err := types.SignTx(tx, types.LatestSignerForChainID(c.chainID), c.key)
	if err != nil {
		return common.Hash{}, err
	}
	if err := c.eth.SendTransaction(ctx, signed); err != nil {
		// The counter is only trustworthy while every transaction it issued was
		// accepted. A rejection means the chain's view and ours have parted
		// company — including the ordinary case of another operator having
		// published first — so drop it and read the truth next time.
		c.haveNonce = false
		return common.Hash{}, fmt.Errorf("chain: send: %w", err)
	}
	c.nextNonce = nonce + 1
	return signed.Hash(), nil
}

// WaitMined blocks until the transaction lands in a block.
func (c *Client) WaitMined(ctx context.Context, hash common.Hash) (*types.Receipt, error) {
	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()
	for {
		receipt, err := c.eth.TransactionReceipt(ctx, hash)
		if err == nil {
			return receipt, nil
		}
		if !errors.Is(err, ethereum.NotFound) {
			return nil, err
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-ticker.C:
		}
	}
}

// SetMaxLogRange caps how wide a single eth_getLogs may be. Wider scans are
// split into consecutive calls rather than failing, which is what lets a node
// sit behind a range-limited endpoint at all.
func (c *Client) SetMaxLogRange(blocks uint64) { c.maxLogRange = blocks }

// SetLogChunkPause spaces out the calls a split scan makes.
func (c *Client) SetLogChunkPause(d time.Duration) { c.logChunkPause = d }

// chunkRange splits [from, to] into consecutive spans of at most max blocks,
// covering every block exactly once. A gap here loses requests silently; an
// overlap makes the node sign the same seed twice.
func chunkRange(from, to, max uint64) [][2]uint64 {
	if max == 0 || to < from || to-from+1 <= max {
		return [][2]uint64{{from, to}}
	}
	var out [][2]uint64
	for start := from; start <= to; start += max {
		end := start + max - 1
		if end > to {
			end = to
		}
		out = append(out, [2]uint64{start, end})
	}
	return out
}

// SetGasLimit overrides the fixed limit used when publishing.
func (c *Client) SetGasLimit(limit uint64) {
	if limit > 0 {
		c.gasLimit = limit
	}
}

// fees returns the tip and base fee, refreshed at most once a second. Fee data
// moves far more slowly than requests arrive, and a stale second of it costs
// nothing next to a round trip on the publishing path.
func (c *Client) fees(ctx context.Context) (tip, baseFee *big.Int, err error) {
	c.feeMu.Lock()
	defer c.feeMu.Unlock()
	if c.cachedBaseFee != nil && time.Since(c.feeAt) < time.Second {
		return c.cachedTip, c.cachedBaseFee, nil
	}

	head, err := c.eth.HeaderByNumber(ctx, nil)
	if err != nil {
		return nil, nil, err
	}
	tip, err = c.eth.SuggestGasTipCap(ctx)
	if err != nil {
		tip = big.NewInt(0)
	}
	c.cachedTip, c.cachedBaseFee, c.feeAt = tip, head.BaseFee, time.Now()
	return tip, head.BaseFee, nil
}

func (c *Client) call(ctx context.Context, data []byte) ([]byte, error) {
	return c.callTo(ctx, c.coordinator, data)
}

func (c *Client) callTo(ctx context.Context, to common.Address, data []byte) ([]byte, error) {
	return c.eth.CallContract(ctx, ethereum.CallMsg{To: &to, Data: data}, nil)
}

// DeriveSeed computes what the coordinator will hash for a request, without
// asking anyone.
//
// It is the same formula as VRFCoordinator._seedOf, and every input is already
// in the event. Deriving it locally removes a round trip from the hot path and,
// more to the point, removes the RPC endpoint from the trust boundary: a node
// that asks a server what to sign will sign whatever that server says.
func (c *Client) DeriveSeed(requestID *big.Int, consumer common.Address) [32]byte {
	packed := make([]byte, 0, 32+20+20+32)
	packed = append(packed, common.LeftPadBytes(requestID.Bytes(), 32)...)
	packed = append(packed, consumer.Bytes()...)
	packed = append(packed, c.coordinator.Bytes()...)
	packed = append(packed, common.LeftPadBytes(c.chainID.Bytes(), 32)...)
	return crypto.Keccak256Hash(packed)
}
