# Dext NATS Messenger

High-performance distributed personal/group messaging infrastructure for Delphi, built on **Dext**, **dext_nats**, **NATS/JetStream**, PostgreSQL, and object storage.

> **Implementation status:** the repository contains the planned implementation building blocks. Delphi compilation, integration testing, failure-injection testing, and large-scale capacity validation are expected to continue in the Codex/lab phase. No 100k/300k capacity claim is made until it is measured and reproducible.

## Why Dext + NATS?

This project deliberately uses **Dext and NATS together** instead of implementing the entire messaging platform with Dext alone.

The two technologies solve different problems:

- **Dext owns the application edge**: HTTP APIs, WebSocket/Hub connections, authentication, authorization, DI, validation, rate limiting, backpressure, and client protocol handling.
- **NATS owns the distributed messaging fabric**: cross-gateway routing, service-to-service pub/sub, low-latency fan-out, worker distribution, and realtime event propagation.
- **JetStream owns durable transport workflows**: replay, retries, acknowledged delivery, shared pull consumers, and DLQ processing where broker-level durability is useful.
- **PostgreSQL remains the source of truth**: canonical messages, permanent idempotency, conversation ordering, memberships, receipts, cursors, and the transactional outbox.

Dext alone could run a smaller single-node or low-node-count chat system. The challenge appears when the system is horizontally scaled across many gateway instances. If User A is connected to Gateway 1 and User B is connected to Gateway 7, the platform needs an efficient distributed routing layer. Without NATS, that layer would have to be built using direct server-to-server calls, database notifications, custom TCP/WebSocket meshes, polling, or another broker.

NATS provides that distributed backbone without turning PostgreSQL into a realtime coordination bus and without coupling gateways directly to each other.

In short:

```text
Dext        = client-facing realtime/application layer
NATS Core   = distributed realtime messaging backbone
JetStream   = durable broker workflows
PostgreSQL  = canonical application state and history
S3/MinIO    = large media blobs
```

Dext and NATS are **complementary, not competing technologies** in this architecture.

For the full rationale, trade-offs, rejected alternatives, and scaling discussion, see:

- [`Docs/WHY_DEXT_AND_NATS.md`](Docs/WHY_DEXT_AND_NATS.md)

## What is implemented

The repository contains the application building blocks for:

- personal/direct conversations with canonical pair creation;
- group conversations, roles, and member management;
- transactional message acceptance and permanent idempotency;
- per-conversation canonical sequence allocation;
- PostgreSQL transactional outbox;
- JetStream durable accepted-message pipeline;
- horizontally scalable pull delivery workers;
- Core NATS online user/group fan-out;
- presence, typing, and realtime receipts;
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

## Why not Dext-only?

A Dext-only architecture is technically possible and can be attractive for smaller deployments because it reduces infrastructure and operational complexity. However, at large horizontal scale it creates several problems that must then be solved inside the application platform itself:

- cross-gateway user routing;
- distributed group fan-out;
- gateway discovery and node coordination;
- service-to-service event delivery;
- worker distribution and failover;
- retry/replay infrastructure;
- distributed backpressure;
- durable broker-style delivery semantics;
- avoiding direct coupling between gateway nodes.

Using PostgreSQL `LISTEN/NOTIFY`, polling, or direct HTTP calls between gateways can solve some of these problems, but it pushes realtime coordination responsibilities into components that are better used for application state or client-facing transport.

NATS lets Dext gateways remain stateless and horizontally scalable while PostgreSQL remains focused on durable business state.

## Why not one durable consumer per user?

The system is designed so durable infrastructure cardinality follows bounded worker roles and partitions, not registered users/devices. Backend delivery instances share durable pull consumers. Offline recovery uses the conversation log plus per-user cursors rather than hundreds of thousands of durable consumers.

## Storage and infrastructure responsibilities

| Layer | Responsibility |
|---|---|
| Dext Gateway | authentication, API/WebSocket surface, validation, authorization, rate limits, backpressure |
| Core NATS | transient online delivery, gateway-to-gateway distribution, presence, typing, realtime fan-out |
| JetStream | durable transport events, retry/replay, pull workers, DLQ pipeline |
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

`sender_user_id`, device, and session identity are derived from authenticated claims; they are not trusted from message bodies.

## Repository layout

```text
Source/                 Core/domain/transport/gateway/client units
Source/Persistence/     Dext Entity + PostgreSQL reference adapters
Tests/                  Dext.Testing contract/unit test suite
Demo/VCLClient/         VCL production/developer client
Benchmarks/loadgen/     Distributed Go WebSocket/HTTP load generator
Benchmarks/             Failure matrix and measured results
Database/               Versioned PostgreSQL migrations
Deploy/                 Development NATS/PostgreSQL/MinIO topology
Scripts/                Quality and integration gates
Docs/                   Architecture, protocol, ADRs, roadmap, design rationale
```

## Development environment

`deploy/docker-compose.dev.yml` starts a development-only three-node NATS/JetStream cluster, PostgreSQL, and MinIO. The included credentials are explicitly for local development and must not be reused in production.

Apply database migrations in numeric order. Production PostgreSQL should use connection pooling and HA appropriate to the deployment.

## Tests and quality gates

The repository includes `Tests/Dext.Messenger.Tests.dpr` with contract tests for protocol primitives, transactional acceptance semantics, delivery envelopes, backpressure, media policy, connection registry, rate-limit isolation, and conversation lifecycle.

On a machine with Delphi configured:

```powershell
$env:DELPHI_UNIT_PATH = '<Dext Sources>;<dext_nats Source>'
./scripts/quality-gate.ps1
./Tests/Dext.Messenger.Tests.exe
```

For the isolated Win64 integration matrix:

```powershell
./scripts/integration-gate.ps1
```

The integration gate validates Delphi 12/13, PostgreSQL transactional rollback,
outbox lease recovery, unavailable-database behavior, JetStream dedup/replay,
poison-to-DLQ-before-TERM, DLQ-outage redelivery, and one-node NATS/JetStream
failover in an isolated test environment.

The GitHub workflow builds and vets the Go load generator and runs structural checks. A self-hosted Windows/Delphi runner can enable Delphi CI through the `DELPHI_SELF_HOSTED` repository variable.

## Scale validation

`Benchmarks/loadgen` can generate WebSocket connection load and authenticated HTTP send load from multiple hosts. `Benchmarks/FAILURE_MATRIX.md` defines node loss, database outage, reconnect storm, slow consumer, poison event, worker crash, and other reliability scenarios.

A 300,000-connection target must be established by distributed measurement. Every published result must record hardware, topology, TLS mode, payload distribution, gateway count, NATS/JetStream layout, PostgreSQL layout, CPU/RAM/network/storage, p50/p95/p99 latency, failures, outbox backlog, and consumer lag.

## Important design rules

- Do not place large media bytes in NATS messages.
- Do not use JetStream as the permanent searchable chat database.
- Do not create one durable consumer, thread, or stream per user/conversation.
- Do not trust sender identity supplied by a client payload.
- Do not report an uncommitted message proposal as accepted.
- Do not turn PostgreSQL into the primary realtime message bus.
- Do not directly couple gateway nodes when NATS can provide distributed routing.
- Do not publish a 100k/300k capacity claim without reproducible benchmark evidence.

## Documentation

Recommended reading order:

1. [`README.md`](README.md) — project overview
2. [`Docs/WHY_DEXT_AND_NATS.md`](Docs/WHY_DEXT_AND_NATS.md) — why this architecture uses both Dext and NATS
3. [`Docs/ARCHITECTURE.md`](Docs/ARCHITECTURE.md) — full system architecture
4. [`Docs/PROTOCOL.md`](Docs/PROTOCOL.md) — subjects and wire contracts
5. [`Docs/ADR-001-architecture.md`](Docs/ADR-001-architecture.md) — foundational architecture decision
6. [`Docs/ADR-002-transactional-acceptance-outbox.md`](Docs/ADR-002-transactional-acceptance-outbox.md) — source-of-truth and outbox decision
7. [`Docs/ROADMAP.md`](Docs/ROADMAP.md) — implementation and validation status
8. [`Benchmarks/FAILURE_MATRIX.md`](Benchmarks/FAILURE_MATRIX.md) — reliability validation plan

## Dependencies

- **Dext** provides the web framework, Hubs/WebSocket layer, authentication, DI, JSON, testing, and Entity infrastructure.
- **`usofm/dext_nats`** provides the native Delphi NATS/JetStream transport integration.
- **NATS / JetStream** provides the distributed realtime and durable messaging backbone.
- **PostgreSQL** stores canonical durable application state.
- **S3/MinIO-compatible storage** stores media objects.

## License

Until a license file is committed, do not assume redistribution terms beyond GitHub repository visibility.
