// Command vrfstatus publishes the operators' metrics, and nothing else.
//
// During testing the whole operator set runs on one machine — the same machine
// that holds the share ports, the keystores and the publishing keys. Exposing
// that machine's ports directly would expose all of them. This process is the
// one thing meant to face outward, and it can reach nothing but the metrics
// endpoints it was started with.
//
//	vrfstatus -operators 9 -metrics-base 9600 -listen 127.0.0.1:9700
//
// Then put a tunnel in front of the one port, not in front of the machine.
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"threshold-vrf/node/internal/status"
)

func main() {
	var (
		operators   = flag.Int("operators", 9, "how many operators run locally")
		metricsBase = flag.Int("metrics-base", 9600, "port of operator 0's metrics endpoint")
		listen      = flag.String("listen", "127.0.0.1:9700", "address to serve on")
		upstreams   = flag.String("upstreams", "",
			"comma-separated metrics URLs, when the operators are not local; "+
				"overrides -operators and -metrics-base")
	)
	flag.Parse()

	log := slog.New(slog.NewTextHandler(os.Stderr, nil))

	var targets []string
	if strings.TrimSpace(*upstreams) != "" {
		for _, u := range strings.Split(*upstreams, ",") {
			if u = strings.TrimSpace(u); u != "" {
				targets = append(targets, u)
			}
		}
	} else {
		for i := 0; i < *operators; i++ {
			targets = append(targets, fmt.Sprintf("http://127.0.0.1:%d", *metricsBase+i))
		}
	}
	if len(targets) == 0 {
		log.Error("no operators to serve")
		os.Exit(1)
	}

	server := &http.Server{
		Addr:              *listen,
		Handler:           status.NewServer(targets),
		ReadHeaderTimeout: 5 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		<-ctx.Done()
		_ = server.Close()
	}()

	log.Info("status endpoint up",
		"listen", *listen, "operators", len(targets),
		"paths", "/op/N/metrics, /status.json, /operators.json")

	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Error("stopped", "err", err)
		os.Exit(1)
	}
}
