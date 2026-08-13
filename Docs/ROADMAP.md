# Roadmap

## Milestone 0 — Foundation

- [x] Architecture overview
- [x] Foundational ADR
- [x] Initial subject namespace
- [x] Initial wire envelope semantics
- [ ] Core Delphi domain records
- [ ] Subject builder + validation
- [ ] JSON codec abstraction
- [ ] Idempotency contract
- [ ] Unit tests for protocol primitives

## Milestone 1 — Core realtime

- [ ] NATS transport adapter using `dext_nats`
- [ ] Direct/personal delivery
- [ ] Group realtime delivery
- [ ] Presence publisher/subscriber
- [ ] Typing publisher/subscriber
- [ ] Multi-device delivery abstraction
- [ ] Gateway-local connection registry

## Milestone 2 — Durable messaging

- [ ] JetStream topology bootstrap
- [ ] Deterministic conversation partitioning
- [ ] Durable message accepted event
- [ ] Persistence worker interface
- [ ] Retry/backoff rules
- [ ] DLQ contract
- [ ] Duplicate/replay tests

## Milestone 3 — Gateway

- [ ] Dext WebSocket host
- [ ] Authentication context
- [ ] Public client command protocol
- [ ] Authorization hooks
- [ ] Rate limits
- [ ] Slow-consumer policy
- [ ] Health endpoints
- [ ] Metrics

## Milestone 4 — Persistence

- [ ] Storage interfaces
- [ ] PostgreSQL reference adapter
- [ ] Conversation pagination
- [ ] Group membership storage
- [ ] Receipt aggregation
- [ ] Offline inbox/recovery

## Milestone 5 — Media

- [ ] Media metadata contracts
- [ ] S3/MinIO adapter interface
- [ ] Upload authorization flow
- [ ] Attachment lifecycle policy

## Milestone 6 — Scale and reliability

- [ ] Synthetic WebSocket load generator
- [ ] Direct-message throughput benchmark
- [ ] Large-group fan-out benchmark
- [ ] 100k connection test
- [ ] 300k distributed connection test
- [ ] NATS node failure test
- [ ] Gateway rolling restart test
- [ ] Database outage/recovery test
- [ ] Publish documented capacity results

## Definition of done for scale claims

A concurrency/throughput claim must include hardware, NATS topology, gateway count, TLS mode, payload size, message distribution, CPU, RAM, p50/p95/p99 latency and failure headroom.
