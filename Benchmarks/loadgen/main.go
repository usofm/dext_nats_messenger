package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/coder/websocket"
)

type counters struct {
	attempted atomic.Int64
	succeeded atomic.Int64
	failed    atomic.Int64
	active    atomic.Int64
}

type latencyRecorder struct {
	mu      sync.Mutex
	samples []time.Duration
	max     int
}

func (r *latencyRecorder) add(d time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.samples) < r.max {
		r.samples = append(r.samples, d)
	}
}

func (r *latencyRecorder) snapshot() []time.Duration {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := append([]time.Duration(nil), r.samples...)
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

func percentile(v []time.Duration, p float64) time.Duration {
	if len(v) == 0 {
		return 0
	}
	idx := int(float64(len(v)-1) * p)
	return v[idx]
}

type config struct {
	mode         string
	url          string
	token        string
	connections  int
	concurrency  int
	duration     time.Duration
	rate         int
	insecureTLS  bool
	conversation string
	target       string
}

func main() {
	var cfg config
	flag.StringVar(&cfg.mode, "mode", "ws", "ws or http")
	flag.StringVar(&cfg.url, "url", "ws://127.0.0.1:8080/hubs/messenger", "WebSocket URL or HTTP gateway base URL")
	flag.StringVar(&cfg.token, "token", "", "Bearer JWT (or LOADGEN_TOKEN env)")
	flag.IntVar(&cfg.connections, "connections", 1000, "WebSocket connections to hold")
	flag.IntVar(&cfg.concurrency, "concurrency", 64, "HTTP worker count")
	flag.DurationVar(&cfg.duration, "duration", 60*time.Second, "test duration")
	flag.IntVar(&cfg.rate, "rate", 1000, "target HTTP requests/sec, 0 = unlimited")
	flag.BoolVar(&cfg.insecureTLS, "insecure-tls", false, "skip TLS verification (test labs only)")
	flag.StringVar(&cfg.conversation, "conversation", "load-conv", "conversation id for HTTP sends")
	flag.StringVar(&cfg.target, "target", "load-target", "destination user for HTTP sends")
	flag.Parse()

	if cfg.token == "" {
		cfg.token = os.Getenv("LOADGEN_TOKEN")
	}
	if cfg.duration <= 0 {
		fatal("duration must be positive")
	}
	if cfg.mode == "ws" && cfg.connections <= 0 {
		fatal("connections must be positive")
	}
	if cfg.mode == "http" && cfg.concurrency <= 0 {
		fatal("concurrency must be positive")
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	ctx, timeoutCancel := context.WithTimeout(ctx, cfg.duration)
	defer timeoutCancel()

	var c counters
	lat := &latencyRecorder{max: 1_000_000}
	started := time.Now()

	switch cfg.mode {
	case "ws":
		runWebSockets(ctx, cfg, &c, lat)
	case "http":
		runHTTP(ctx, cfg, &c, lat)
	default:
		fatal("mode must be ws or http")
	}

	elapsed := time.Since(started)
	samples := lat.snapshot()
	fmt.Println("--- loadgen summary ---")
	fmt.Printf("mode=%s elapsed=%s attempted=%d succeeded=%d failed=%d active=%d\n",
		cfg.mode, elapsed.Round(time.Millisecond), c.attempted.Load(), c.succeeded.Load(),
		c.failed.Load(), c.active.Load())
	if elapsed > 0 {
		fmt.Printf("throughput=%.2f ops/s\n", float64(c.succeeded.Load())/elapsed.Seconds())
	}
	fmt.Printf("latency samples=%d p50=%s p95=%s p99=%s max=%s\n",
		len(samples), percentile(samples, .50), percentile(samples, .95),
		percentile(samples, .99), maxDuration(samples))
}

func runWebSockets(ctx context.Context, cfg config, c *counters, lat *latencyRecorder) {
	var wg sync.WaitGroup
	sem := make(chan struct{}, 256)
	connections := make(chan *websocket.Conn, cfg.connections)

connectLoop:
	for i := 0; i < cfg.connections; i++ {
		select {
		case <-ctx.Done():
			break connectLoop
		default:
		}

		select {
		case sem <- struct{}{}:
		case <-ctx.Done():
			break connectLoop
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			defer func() { <-sem }()
			c.attempted.Add(1)
			headers := http.Header{}
			if cfg.token != "" {
				headers.Set("Authorization", "Bearer "+cfg.token)
			}
			hc := &http.Client{Transport: &http.Transport{
				TLSClientConfig: &tls.Config{InsecureSkipVerify: cfg.insecureTLS},
			}}
			start := time.Now()
			conn, _, err := websocket.Dial(ctx, cfg.url, &websocket.DialOptions{
				HTTPClient: hc,
				HTTPHeader: headers,
			})
			lat.add(time.Since(start))
			if err != nil {
				c.failed.Add(1)
				return
			}
			c.succeeded.Add(1)
			c.active.Add(1)
			select {
			case connections <- conn:
			case <-ctx.Done():
				_ = conn.Close(websocket.StatusNormalClosure, "load test cancelled")
				c.active.Add(-1)
			}
		}()
	}

	wg.Wait()
	fmt.Printf("opened %d websocket connections; holding until test deadline\n", c.active.Load())
	<-ctx.Done()
	close(connections)
	for conn := range connections {
		_ = conn.Close(websocket.StatusNormalClosure, "load test complete")
		c.active.Add(-1)
	}
}

func runHTTP(ctx context.Context, cfg config, c *counters, lat *latencyRecorder) {
	transport := &http.Transport{
		MaxIdleConns:        cfg.concurrency * 4,
		MaxIdleConnsPerHost: cfg.concurrency * 2,
		TLSClientConfig:     &tls.Config{InsecureSkipVerify: cfg.insecureTLS},
	}
	client := &http.Client{Transport: transport, Timeout: 15 * time.Second}
	jobs := make(chan int, cfg.concurrency*4)
	var wg sync.WaitGroup

	for w := 0; w < cfg.concurrency; w++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			for i := range jobs {
				sendHTTP(ctx, client, cfg, worker, i, c, lat)
			}
		}(w)
	}

	var ticker *time.Ticker
	if cfg.rate > 0 {
		interval := time.Second / time.Duration(cfg.rate)
		if interval < time.Microsecond {
			interval = time.Microsecond
		}
		ticker = time.NewTicker(interval)
		defer ticker.Stop()
	}

	for i := 0; ; i++ {
		if ticker != nil {
			select {
			case <-ctx.Done():
				close(jobs)
				wg.Wait()
				return
			case <-ticker.C:
			}
		} else {
			select {
			case <-ctx.Done():
				close(jobs)
				wg.Wait()
				return
			default:
			}
		}

		select {
		case jobs <- i:
		case <-ctx.Done():
			close(jobs)
			wg.Wait()
			return
		}
	}
}

func sendHTTP(ctx context.Context, client *http.Client, cfg config, worker, seq int, c *counters, lat *latencyRecorder) {
	payload := map[string]any{
		"ClientMessageId": fmt.Sprintf("load-%d-%d-%d", os.Getpid(), worker, seq),
		"ConversationId":  cfg.conversation,
		"DestinationType": "user",
		"DestinationId":   cfg.target,
		"Kind":            "text",
		"PayloadJson":     `{"text":"load"}`,
	}
	body, _ := json.Marshal(payload)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		cfg.url+"/api/messenger/messages", bytes.NewReader(body))
	if err != nil {
		c.failed.Add(1)
		return
	}
	req.Header.Set("Content-Type", "application/json")
	if cfg.token != "" {
		req.Header.Set("Authorization", "Bearer "+cfg.token)
	}
	c.attempted.Add(1)
	start := time.Now()
	resp, err := client.Do(req)
	lat.add(time.Since(start))
	if err != nil {
		c.failed.Add(1)
		return
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		c.succeeded.Add(1)
	} else {
		c.failed.Add(1)
		if c.failed.Load() <= 10 {
			fmt.Fprintf(os.Stderr, "HTTP failure status=%s seq=%s\n", resp.Status, strconv.Itoa(seq))
		}
	}
}

func maxDuration(v []time.Duration) time.Duration {
	if len(v) == 0 {
		return 0
	}
	return v[len(v)-1]
}

func fatal(msg string) {
	fmt.Fprintln(os.Stderr, msg)
	os.Exit(2)
}
