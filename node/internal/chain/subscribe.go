package chain

import (
	"context"
	"log/slog"
	"math/rand"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/ethclient"
)

// Source opens a subscription and writes one value per event until it fails.
// Separated from the websocket that normally provides it so the reconnection
// behaviour can be tested without one.
type Source func(ctx context.Context, out chan<- struct{}) error

// Nudges turns a stream of chain events into hints for the poll loop.
//
// What this is not: a replacement for polling. On a chain with 0.1s blocks a
// three-second poll is most of the delay a consumer sees, but a subscription
// that silently stops delivering is a worse failure than a poll that is late —
// which is why this node polled and nothing else for so long. So the
// subscription is wired to speed the loop up and to nothing else. If it dies,
// or never connects, or delivers half of what it should, the only cost is the
// latency we had before it.
//
// Reconnection backs off for the same reason polling does: a websocket that a
// provider is refusing must not be reopened as fast as the refusals arrive.
func Nudges(ctx context.Context, open Source, log *slog.Logger) <-chan struct{} {
	if log == nil {
		log = slog.Default()
	}
	// Depth one. A pending nudge already says "there may be something now", and
	// a second one says nothing the first did not — so the sender drops rather
	// than queues, and a burst of logs under load becomes one scan.
	out := make(chan struct{}, 1)

	go func() {
		wait := 500 * time.Millisecond
		for {
			if ctx.Err() != nil {
				return
			}
			err := open(ctx, out)
			if ctx.Err() != nil {
				return
			}
			log.Warn("event subscription dropped, falling back to polling until it is back",
				"err", err, "retry_in", wait)

			select {
			case <-ctx.Done():
				return
			case <-time.After(jitterAround(wait)):
			}
			if wait < 30*time.Second {
				wait *= 2
			}
		}
	}()
	return out
}

// WebsocketNudges subscribes to the coordinator's logs over a websocket.
//
// Any log from the coordinator counts, and the payload is thrown away: this
// only ever means "look now", and what is actually there comes from the poll's
// own eth_getLogs. Decoding here would put the subscription on the path that
// decides what gets signed, which is the one place it must not be — an endpoint
// that can choose what a node signs is an endpoint that can forge randomness.
func (c *Client) WebsocketNudges(ctx context.Context, wsURL string, log *slog.Logger) <-chan struct{} {
	coordinator := c.coordinator
	return Nudges(ctx, func(ctx context.Context, out chan<- struct{}) error {
		client, err := ethclient.DialContext(ctx, wsURL)
		if err != nil {
			return err
		}
		defer client.Close()

		logs := make(chan types.Log, 64)
		sub, err := client.SubscribeFilterLogs(ctx,
			ethereum.FilterQuery{Addresses: []common.Address{coordinator}}, logs)
		if err != nil {
			return err
		}
		defer sub.Unsubscribe()

		for {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case err := <-sub.Err():
				return err
			case <-logs:
				select {
				case out <- struct{}{}:
				default:
				}
			}
		}
	}, log)
}

// jitterAround spreads a delay over ±20%, so nine operators that lost the same
// endpoint at the same moment do not all come back at the same moment.
func jitterAround(d time.Duration) time.Duration {
	if d <= 0 {
		return d
	}
	spread := int64(d) / 5
	return d + time.Duration(rand.Int63n(2*spread+1)-spread)
}
