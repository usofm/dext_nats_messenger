# Dext NATS Messenger Load Generator

This tool is intentionally external to the Delphi server process so one load generator never becomes the bottleneck or hides server behavior.

## Modes

### WebSocket connection load

```bash
go run . -mode ws \
  -url wss://gateway.example.com/hubs/messenger \
  -connections 25000 \
  -duration 10m \
  -token "$LOADGEN_TOKEN"
```

Run multiple load-generator hosts for 100k/300k tests. For example, 12 hosts x 25k connections gives a 300k connection target. Do not claim 300k capacity from a single-host synthetic test.

### HTTP command load

```bash
go run . -mode http \
  -url https://gateway.example.com \
  -concurrency 256 \
  -rate 20000 \
  -duration 10m \
  -token "$LOADGEN_TOKEN" \
  -conversation load-conv-001 \
  -target load-target-001
```

The load generator reports attempted/succeeded/failed operations plus p50/p95/p99/max latency from a bounded in-memory sample.

## Required benchmark metadata

Every published result must include:

- commit SHA for `dext_nats_messenger`, `dext_nats`, and Dext;
- OS and kernel/Windows build;
- CPU model/count, RAM, NIC speed, storage model;
- gateway count and process model;
- NATS cluster topology and JetStream replicas;
- PostgreSQL topology/storage;
- TLS mode/cipher termination point;
- average payload size and direct/group message distribution;
- test duration and connection ramp rate;
- CPU/RAM/network/disk metrics for every server role;
- p50/p95/p99 application latency;
- failure count, reconnect success, JetStream consumer lag and outbox backlog.

## Important

The presence of this harness means the repository is ready to *measure* 100k/300k targets. It is not itself evidence that a specific deployment sustains those targets.
