// Command vrfnode is the operator daemon.
//
// It watches the coordinator for requests, signs each seed with its DKG share,
// exchanges shares with the other operators, and publishes whichever signature
// it manages to assemble first. Losing that race is the normal outcome and
// costs nothing.
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"math/big"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"threshold-vrf/node/internal/chain"
	"threshold-vrf/node/internal/keystore"
	"threshold-vrf/node/internal/mesh"
	"threshold-vrf/node/internal/metrics"
	"threshold-vrf/node/internal/node"
)

func main() {
	var (
		rpcURL = flag.String("rpc", "", "chain RPC endpoint")
		// Optional, and deliberately so. With it, a request is noticed in
		// milliseconds instead of at the end of the poll interval — most of the
		// latency a consumer sees on a chain with 0.1s blocks. Without it,
		// nothing changes: the poll is still what finds requests, and the
		// subscription only ever tells it to look sooner.
		wsURL = flag.String("ws", "",
			"websocket endpoint for event hints; polling still does the finding")
		coordinator  = flag.String("coordinator", "", "VRFCoordinator address")
		keystorePath = flag.String("keystore", "", "path to this operator's encrypted share")
		listen       = flag.String("listen", ":8080", "address to receive peer shares on")
		metricsAddr  = flag.String("metrics-listen", ":8081",
			"address to serve /metrics on; keep this one publicly reachable")
		allow = flag.String("allow", "",
			"comma-separated IPs or CIDRs allowed to post shares; empty accepts from anywhere")
		shareRate = flag.Float64("share-rate", 500,
			"sustained shares per second accepted from one source")
		peers     = flag.String("peers", "", "comma-separated base URLs of the other operators")
		quorum    = flag.Int("threshold", 5, "signatures required")
		operators = flag.Int("operators", 9, "size of the group")
		fromBlock = flag.Uint64("from-block", 0, "block to start watching from (0 = head minus -lookback)")
		lookback  = flag.Uint64("lookback", 20_000,
			"blocks to rescan on startup, so a restart picks up requests missed while down")
		poll      = flag.Duration("poll", time.Second, "how often to look for new requests")
		sendRetry = flag.Duration("send-retry", 2*time.Second,
			"how long to wait before trying a refused fulfillment transaction again")
		sendRetries = flag.Int("send-retries", 3,
			"how many times to retry a refused fulfillment transaction")
		rebroadcast = flag.Duration("rebroadcast", 3*time.Second,
			"how long to wait before offering a share again while the quorum is short")
		rebroadcastTries = flag.Int("rebroadcast-attempts", 4,
			"how many times to re-offer a share before giving up on a request")
		// Roughly five hundred fulfilments at testnet prices: far enough above
		// empty that there is time to react, low enough that it does not cry
		// wolf on a freshly funded node.
		minBalance = flag.String("min-balance", "1000000000000000",
			"warn in the log once the publishing account falls below this many wei")

		maxLogRange = flag.Uint64("max-log-range", 0,
			"widest block range one eth_getLogs may cover; 0 = no limit. "+
				"Alchemy's free tier allows 10, most others far more")
		logChunkPause = flag.Duration("log-chunk-pause", 250*time.Millisecond,
			"pause between the calls a split log scan makes; only used when "+
				"-max-log-range is set. Guards against trading a range limit for a rate limit")
		publishDelay = flag.Duration("publish-delay", 3*time.Second,
			"stagger between operators when publishing; 0 makes everyone publish at once")
	)
	flag.Parse()

	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))

	if *rpcURL == "" || *coordinator == "" || *keystorePath == "" {
		fail(log, fmt.Errorf("-rpc, -coordinator and -keystore are all required"))
	}
	passphrase := os.Getenv("VRF_KEYSTORE_PASSPHRASE")
	if passphrase == "" {
		fail(log, fmt.Errorf("VRF_KEYSTORE_PASSPHRASE is not set"))
	}
	// The publishing key pays gas and nothing else: it has no authority over
	// the protocol, so a compromised one costs its balance and no more.
	ethKeyHex := strings.TrimPrefix(os.Getenv("VRF_ETH_PRIVATE_KEY"), "0x")
	if ethKeyHex == "" {
		fail(log, fmt.Errorf("VRF_ETH_PRIVATE_KEY is not set"))
	}
	ethKey, err := crypto.HexToECDSA(ethKeyHex)
	if err != nil {
		fail(log, fmt.Errorf("VRF_ETH_PRIVATE_KEY: %w", err))
	}

	share, err := keystore.Load(*keystorePath, passphrase)
	if err != nil {
		fail(log, err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	client, err := chain.Dial(ctx, *rpcURL, common.HexToAddress(*coordinator), ethKey)
	if err != nil {
		fail(log, err)
	}
	defer client.Close()

	counters := metrics.New(share.Index, *quorum, *operators)

	// What the operator publishes from, watched as a gauge. An account that has
	// run dry stops fulfilments and nothing else: the node keeps scanning,
	// verifying and broadcasting shares, so without this every signal it emits
	// stays green while it delivers nothing.
	floor, ok := new(big.Int).SetString(*minBalance, 10)
	if !ok {
		fail(log, fmt.Errorf("-min-balance %q is not a number of wei", *minBalance))
	}
	balance := chain.NewBalanceCache(client.Balance, time.Minute)
	counters.SetBalanceGauge(balance.Last)

	var nudges <-chan struct{}
	if *wsURL != "" {
		nudges = client.WebsocketNudges(ctx, *wsURL, log)
	}

	client.SetMaxLogRange(*maxLogRange)
	client.SetLogChunkPause(*logChunkPause)

	operator := node.New(node.Config{
		Share:               share,
		Threshold:           *quorum,
		Operators:           *operators,
		Chain:               client,
		Logger:              log,
		Metrics:             counters,
		SendRetryInterval:   *sendRetry,
		SendRetries:         *sendRetries,
		RebroadcastInterval: *rebroadcast,
		RebroadcastAttempts: *rebroadcastTries,
		PublishDelay:        *publishDelay,
		AfterPublish:        func() { checkBalance(ctx, client, balance, floor, log, true) },
	})
	operator.SetPeers(mesh.NewClient(splitPeers(*peers), 5*time.Second))

	// Two ports on purpose. Shares come only from the other operators and the
	// port can be firewalled down to them; the counters are meant to be read by
	// anyone, from a browser, so that the operator set is checkable from
	// outside rather than on our word.
	shareServer := &http.Server{
		Addr: *listen,
		Handler: mesh.NewServer(operator.OnPeerShare, &mesh.ServerOptions{
			RatePerSecond:  *shareRate,
			Burst:          int(*shareRate) * 2,
			AllowedSources: splitPeers(*allow),
		}),
		ReadHeaderTimeout: 5 * time.Second,
	}
	metricsServer := &http.Server{
		Addr:              *metricsAddr,
		Handler:           counters.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
	}
	for _, srv := range []*http.Server{shareServer, metricsServer} {
		go func(srv *http.Server) {
			if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
				log.Error("server stopped", "addr", srv.Addr, "err", err)
				stop()
			}
		}(srv)
	}
	defer func() {
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = shareServer.Shutdown(shutdown)
		_ = metricsServer.Shutdown(shutdown)
	}()

	start := *fromBlock
	if start == 0 {
		head, err := client.BlockNumber(ctx)
		if err != nil {
			fail(log, err)
		}
		if head > *lookback {
			start = head - *lookback
		}
	}

	log.Info("operator up",
		"index", share.Index,
		"chain", client.ChainID(),
		"coordinator", *coordinator,
		"publisher", client.Address(),
		"listen", *listen,
		"metrics", *metricsAddr,
		"allowlist", len(splitPeers(*allow)),
		"peers", len(splitPeers(*peers)),
		"threshold", fmt.Sprintf("%d of %d", *quorum, *operators),
		"from_block", start,
		"publish_delay", *publishDelay,
		"event_hints", *wsURL != "",
	)

	err = client.Watch(ctx, chain.WatchOptions{
		From:     start,
		Interval: *poll,
		OnRequest: func(req chain.Request) {
			log.Info("request", "id", req.ID, "words", req.NumWords, "block", req.Block)
			go operator.OnRequest(ctx, req)
		},
		// What spares this operator from asking the chain, once per request,
		// whether there is still anything to do.
		OnFulfilled: operator.OnFulfilled,
		Nudge:       nudges,
		// Reported every poll, not only when something turns up: this is what
		// tells a monitor the difference between "quiet chain" and "stopped".
		OnScanned: func(block uint64) {
			counters.BlockSeen(block)
			// Piggy-backed on the poll timer rather than given a goroutine of
			// its own, and rate-limited inside the cache.
			checkBalance(ctx, client, balance, floor, log, false)
		},
		OnError: func(err error) {
			log.Warn("poll failed, retrying", "err", err)
		},
	})
	if err != nil && ctx.Err() == nil {
		fail(log, err)
	}
	log.Info("shutting down")
}

func splitPeers(s string) []string {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func fail(log *slog.Logger, err error) {
	log.Error("fatal", "err", err)
	os.Exit(1)
}

// checkBalance warns when the publishing account is running low and collects
// what this operator has earned if that is worth a transaction.
//
// `justPublished` forces the read. Publishing is the one event that moves both
// the balance and the earnings, and it is also the moment the operator most
// needs to know: below its floor it cannot publish again, and the group has to
// walk the rotation past it until it notices.
func checkBalance(
	ctx context.Context,
	client *chain.Client,
	balance *chain.BalanceCache,
	floor *big.Int,
	log *slog.Logger,
	justPublished bool,
) {
	if justPublished {
		balance.Invalidate()
	} else if !balance.Refresh(ctx) {
		// Nothing new to say: the held value is still fresh.
		return
	}
	if justPublished {
		balance.Refresh(ctx)
	}

	left := balance.Last()
	if left == nil || left.Cmp(floor) >= 0 {
		return
	}
	log.Warn("publishing account is running low", "address", client.Address(), "wei", left)

	// Collect what this operator has already earned before asking anyone to top
	// it up. The fee for a fulfilment is credited inside the subscription
	// contract, not paid into the wallet, so an operator that never claims runs
	// down to nothing with its earnings sitting one call away.
	earned, err := client.WithdrawableOf(ctx, client.Address())
	if err != nil {
		log.Warn("could not read earnings", "err", err)
		return
	}
	cost, err := client.ClaimCost(ctx)
	if err != nil {
		log.Warn("could not price a claim", "err", err)
		return
	}
	if !chain.ShouldClaim(left, earned, floor, cost) {
		log.Info("earnings not yet worth collecting", "wei", earned, "claim_costs", cost)
		return
	}
	hash, err := client.Claim(ctx)
	if err != nil {
		log.Warn("claiming earnings failed", "err", err)
		return
	}
	log.Info("claimed earnings", "wei", earned, "tx", hash)
	balance.Invalidate()
}
