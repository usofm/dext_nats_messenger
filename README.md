# Dext NATS Messenger

High-performance distributed personal/group messaging infrastructure for Delphi, built on **Dext**, **dext_nats**, **NATS/JetStream**, PostgreSQL and object storage.

> **Implementation status:** feature-complete architecture branch. Compile, integration, failure-injection and capacity validation are intentionally left for the Codex/lab validation phase. No 100k/300k capacity claim is made until measured.

## What is implemented

The repository contains the complete application building blocks for:

- personal/direct conversations with canonical pair creation;
- group conversations, roles and member management;
- transactional message acceptance and permanent idempotency;
- per-conversation canonical sequence allocation;
- PostgreSQL transactional outbox;
- JetStream durable accepted-message pipeline;
- horizontally scalable pull delivery workers;
- Core NATS online user/group fan-out;
- presence, typing and realtime receipts;
- durable delivered/read receipts and monotonic user cursors;
- offline/reconnect synchronization and paged conversation history;
- paged conversation list queries;
- multi-device connection registry;
- JWT-authenticated Dext Gateway APIs;
- Dext WebSocket Hub hosting;
- per-user/per-operation rate limiting;
- bounded outbound queue / slow-consumer policy;
- DLQ with fail-safe poison-message handling;
- media upload/commit/resolve contracts for S3/MinIO-style storage;
- privacy-safe push-notification contracts;
- health/metrics contracts;
- Delphi HTTP client facade and VCL demo client;
- Dext.Testing test runner and contract tests;
- distributed Go WebSocket/HTTP load generator;
- three-node NATS/JetStream + PostgreSQL + MinIO development topology;
- failure-injection matrix and CI/quality-gate scaffolding.

## Canonical message flow

```text
Client
  |
  | HTTPS command (JWT)
  v
Dext Gateway
  |
  | authenticate + validate + authorize + rate limit
  v
Acceptance Service
  |
  | ONE PostgreSQL transaction
  |  - allocate conversation sequence
  |  - insert canonical message
  |  - enforce (sender, client_message_id) idempotency
  |  - insert outbox event
  v
PostgreSQL COMMIT
  |
  | response is now allowed to say "accepted"
  v
Outbox Dispatcher
  |
  v
JetStream: message.accepted.v1
  |
  v
Shared Pull Delivery Workers
  |
  v
Core NATS user/group subjects
  |
  v
Online Gateways / Clients

Offline client -> Gateway Sync API -> PostgreSQL history + cursor
```

The database is the authority for application identity and acceptance. JetStream `Nats-Msg-Id` is an additional transport deduplication safety net, not the permanent idempotency store. See [`Docs/ADR-002-transactional-acceptance-outbox.md`](Docs/ADR-002-transactional-acceptance-outbox.md).

## Why not one durable consumer per user?

The system is designed so durable infrastructure cardinality follows bounded worker roles and partitions, not registered users/devices. Backend delivery instances share a durable pull consumer. Offline recovery uses the conversation log plus per-user cursors rather than hundreds of thousands of durable consumers.

## Storage responsibilities

| Layer | Responsibility |
|---|---|
| Dext Gateway | authentication, API/WebSocket surface, validation, rate limits, backpressure |
| Core NATS | transient online delivery, presence, typing, realtime notification fan-out |
| JetStream | durable accepted-event delivery, retry/replay, DLQ pipeline |
| PostgreSQL | canonical messages, idempotency, ordering, conversations, members, receipts, cursors, outbox |
| S3/MinIO | image/audio/video/file bytes; NATS messages only carry references/metadata |

## Gateway surface

Representative authenticated routes:

```text
POST /api/messenger/conversations/direct
POST /api/messenger/conversations/group
POST /api/messenger/conversations/list
POST /api/messenger/groups/members
POST /api/messenger/groups/members/remove
POST /api/messenger/messages
POST /api/messenger/sync
POST /api/messenger/cursors/delivered
POST /api/messenger/cursors/read
POST /api/messenger/receipts
POST /api/messenger/media/uploads
POST /api/messenger/media/commit
POST /api/messenger/media/resolve

WS   /hubs/messenger
```

`sender_user_id`, device and session identity are derived from authenticated claims; they are not trusted from message bodies.

## Repository layout

```text
Source/                 Core/domain/transport/gateway/client units
Source/Persistence/     Dext Entity + PostgreSQL reference adapters
Tests/                  Dext.Testing contract/unit test suite
Demo/VCLClient/         VCL production/developer client
Benchmarks/loadgen/     Distributed Go WebSocket/HTTP load generator
Benchmarks/              Failure matrix and future measured results
database/               Versioned PostgreSQL migrations
deploy/                  Development NATS/PostgreSQL/MinIO topology
scripts/                 Quality gate
Docs/                    Architecture, protocol, ADRs, roadmap
```

## Development environment

`deploy/docker-compose.dev.yml` starts a development-only three-node NATS/JetStream cluster, PostgreSQL and MinIO. The included credentials are explicitly for local development and must not be reused in production.

Apply database migrations in numeric order. Production PostgreSQL should use connection pooling and HA appropriate to the deployment.

## Tests and quality gate

The repository includes `Tests/Dext.Messenger.Tests.dpr` with contract tests for protocol primitives, transactional acceptance semantics, delivery envelopes, backpressure, media policy, connection registry, rate-limit isolation and conversation lifecycle.

On a machine with Delphi configured:

```powershell
$env:DELPHI_UNIT_PATH = '<Dext Sources>;<dext_nats Source>'
./scripts/quality-gate.ps1
./Tests/Dext.Messenger.Tests.exe
```

For the isolated Win64 integration matrix (Delphi 12 and 13, PostgreSQL 18,
three-node NATS/JetStream, deduplication and one-node failover):

```powershell
./scripts/integration-gate.ps1
```

The integration gate uses separate local ports and temporary data directories;
it does not modify or stop an existing PostgreSQL or NATS service. Its current
Windows prerequisites and exact tested versions are recorded in the dated
reports under `Benchmarks/results/`.

The GitHub workflow always builds/vets the Go load generator and runs structural checks. A self-hosted Windows/Delphi runner can enable the Delphi job through the `DELPHI_SELF_HOSTED` repository variable.

## Scale validation

`Benchmarks/loadgen` can generate WebSocket connection load and authenticated HTTP send load from multiple hosts. `Benchmarks/FAILURE_MATRIX.md` defines node loss, database outage, reconnect storm, slow consumer, poison event, worker crash and other reliability scenarios.

A 300,000-connection target must be established by distributed measurement. Every published result must record hardware, topology, TLS mode, payload distribution, gateway count, NATS/JetStream layout, PostgreSQL layout, CPU/RAM/network/storage, p50/p95/p99 latency, failures, outbox backlog and consumer lag.

## Important design rules

- Do not place large media bytes in NATS messages.
- Do not use JetStream as the permanent searchable chat database.
- Do not create one durable consumer, thread or stream per user/conversation.
- Do not trust sender identity supplied by a client payload.
- Do not report an uncommitted message proposal as accepted.
- Do not publish a 100k/300k capacity claim without reproducible benchmark evidence.

## Documentation

- [`Docs/ARCHITECTURE.md`](Docs/ARCHITECTURE.md)
- [`Docs/PROTOCOL.md`](Docs/PROTOCOL.md)
- [`Docs/ADR-001-architecture.md`](Docs/ADR-001-architecture.md)
- [`Docs/ADR-002-transactional-acceptance-outbox.md`](Docs/ADR-002-transactional-acceptance-outbox.md)
- [`Docs/ROADMAP.md`](Docs/ROADMAP.md)
- [`Benchmarks/FAILURE_MATRIX.md`](Benchmarks/FAILURE_MATRIX.md)

## Dependency

The native NATS transport is provided by `usofm/dext_nats`. Dext provides the web/Hubs/authentication/DI/Entity infrastructure.

## License

Until a license file is committed, do not assume redistribution terms beyond GitHub repository visibility.
