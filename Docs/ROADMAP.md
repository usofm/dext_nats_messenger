# Roadmap / Implementation Status

This document separates **repository implementation** from **external validation**. A checked implementation item means the contract/code/scaffold exists on the feature branch; it does **not** imply that Delphi compilation, integration tests or a scale benchmark has already passed.

## Milestone 0 — Foundation — implementation complete

- [x] Architecture overview and protocol documentation
- [x] Architecture ADRs, including transactional acceptance/outbox
- [x] Core Delphi domain records
- [x] Versioned subject builder + validation
- [x] JSON codec abstraction
- [x] Deterministic conversation partitioning
- [x] Typed direct/group destinations
- [x] Permanent idempotency contract
- [x] Dext.Testing executable contract/unit test suite

## Milestone 1 — Core realtime — implementation complete

- [x] NATS transport adapter using `dext_nats`
- [x] Direct/personal online delivery
- [x] Group online delivery
- [x] Presence publisher/subscriber
- [x] Typing publisher/subscriber
- [x] Realtime delivered/read receipts
- [x] Multi-device connection abstraction
- [x] Gateway-local connection registry
- [x] Bounded outbound queue / slow-consumer policy

## Milestone 2 — Durable messaging — implementation complete

- [x] PostgreSQL canonical acceptance boundary
- [x] Atomic conversation sequence allocation
- [x] Atomic message + outbox transaction
- [x] JetStream accepted-message topology
- [x] Shared durable pull delivery consumer
- [x] Outbox leases with `FOR UPDATE SKIP LOCKED`
- [x] Retry/backoff rules
- [x] DLQ contract and stream
- [x] Fail-safe poison handling: DLQ before TERM
- [x] Canonical duplicate/retry contract tests
- [x] Composable outbox + delivery worker runtime

## Milestone 3 — Conversations and groups — implementation complete

- [x] Canonical direct pair schema
- [x] Concurrent/retry-safe direct conversation creation
- [x] Group creation with stable group identity
- [x] Member roles: member/moderator/admin/owner
- [x] Admin/owner member management rules
- [x] Conversation authorization for direct/group destinations
- [x] PostgreSQL membership adapter
- [x] Paged conversation list
- [x] Authenticated conversation/group Gateway APIs

## Milestone 4 — Gateway — implementation complete

- [x] Dext WebSocket Hub host
- [x] WebSocket-only production Hub profile
- [x] Hub payload-size limit and method allowlist
- [x] JWT authentication context
- [x] Sender/device/session identity derived from claims
- [x] Authenticated message-send API
- [x] Authenticated sync/cursor API
- [x] Authenticated receipt API
- [x] Authenticated conversation/group API
- [x] Authenticated media API
- [x] Per-user/per-operation rate limits
- [x] Slow-consumer/backpressure guard
- [x] Health/observability contracts
- [x] Single Gateway composition entrypoint

## Milestone 5 — Persistence and offline recovery — implementation complete

- [x] Versioned PostgreSQL schema/migrations
- [x] Dext Entity models and DbContext
- [x] Specialized PostgreSQL transactional acceptance adapter
- [x] PostgreSQL outbox implementation
- [x] Membership and device/push-target persistence
- [x] Conversation pagination/history
- [x] Paged conversation list
- [x] Durable delivered/read receipts
- [x] Monotonic delivered/read cursors
- [x] Offline/reconnect sync by conversation sequence
- [x] History access constrained by active membership

## Milestone 6 — Media and notifications — implementation complete

- [x] Media metadata contracts
- [x] S3/MinIO-style media store interface
- [x] Upload authorization/grant flow
- [x] Upload commit/hash/actual-size contract
- [x] Ready/quarantine/delete lifecycle states
- [x] Gateway upload/commit/resolve API
- [x] Privacy-safe push-notification contracts
- [x] Per-device push target storage contract
- [x] Media bytes explicitly kept outside NATS

## Milestone 7 — Delphi clients and developer experience — implementation complete

- [x] Platform-neutral Delphi HTTP Gateway client
- [x] Conversation/group client operations
- [x] Send/sync/cursor client operations
- [x] Media client operations
- [x] VCL client project
- [x] Secure production Gateway mode
- [x] Developer direct-NATS diagnostic mode
- [x] Reproducible PostgreSQL + 3-node NATS/JetStream + MinIO dev topology
- [x] PowerShell structural/optional-Delphi quality gate
- [x] GitHub Actions structural/Go job
- [x] Optional self-hosted Delphi CI job

## Milestone 8 — Scale/reliability tooling — implementation complete; execution pending

- [x] Distributed synthetic WebSocket load generator
- [x] Authenticated HTTP send load mode
- [x] Bounded latency sampling with p50/p95/p99/max output
- [x] Failure-injection matrix
- [x] 100k/300k distributed test methodology
- [x] Required benchmark evidence format

## External validation — Codex / lab phase

These items are intentionally **not** marked complete in chat because they require an actual Delphi/toolchain/runtime or multi-node lab run:

- [ ] Compile all Delphi units with the repository's pinned Dext + `dext_nats` versions
- [ ] Execute `Tests/Dext.Messenger.Tests.dpr`
- [ ] Run PostgreSQL integration tests against all migrations
- [ ] Run NATS/JetStream integration/replay/DLQ tests
- [ ] Build and exercise VCL client against a real Gateway
- [ ] Run `go test`, `go vet`, and build the load generator in CI
- [ ] Execute direct-message throughput benchmark
- [ ] Execute large-group fan-out benchmark
- [ ] Execute 100k concurrent WebSocket test
- [ ] Execute distributed 300k concurrent WebSocket test
- [ ] Execute NATS node-loss and JetStream quorum scenarios
- [ ] Execute Gateway rolling-restart/reconnect-storm scenario
- [ ] Execute PostgreSQL outage/slow-storage scenarios
- [ ] Execute outbox/delivery-worker crash recovery scenarios
- [ ] Profile CPU, allocation, locks, queues, network and storage
- [ ] Fix/optimize findings and repeat until SLOs are met
- [ ] Publish reproducible capacity report

## Definition of done for a scale claim

A concurrency/throughput claim must include the exact repository SHAs, hardware, OS, NATS topology, JetStream replicas, PostgreSQL topology, gateway count, TLS mode/termination, payload size/distribution, test duration/ramp, CPU, RAM, network, storage, outbox backlog, consumer lag, p50/p95/p99 latency, failure counts, reconnect success and remaining capacity headroom.
