# AGENTS.md — Dext NATS Messenger

Read this file before changing the repository.

## Purpose

This project is a production-oriented distributed messenger/chat framework for Delphi built around Dext and `usofm/dext_nats`.

It is not a monolithic demo application. Keep domain contracts independent from WebSocket hosts, NATS transport details and database adapters.

## Canonical references and source priority

Before changing architecture or generating Dext-facing code, use this priority order:

1. Current Dext source at the compatibility SHA pinned by `usofm/DEXT_AI_CODING_PACK`.
2. Official Dext skills/docs/examples referenced by the Coding Pack.
3. `usofm/DEXT_AI_CODING_PACK`.
4. `usofm/DEXT_ENTERPRISE_STARTER` as the practical Golden Sample for Dext-native enterprise composition.
5. `usofm/dext_nats` for the exact NATS/JetStream Delphi API.
6. Local messenger conventions in this repository.

Current Coding Pack release observed when this contract was written:

```text
v2026.08.12-r3-dext-412ed292
compatibility anchor: cesarliws/dext@412ed29207d2d1dc5d4a259a7739a615aed0c626
```

Do not assume a future Dext `main` is compatible without refreshing the evidence.

For realtime work, inspect at minimum:

```text
DEXT_AI_CODING_PACK/DEXT_DECISION_TREE.md
DEXT_AI_CODING_PACK/DEXT_ANTI_PATTERNS.md
DEXT_AI_CODING_PACK/skills/dext-realtime/SKILL.md
DEXT_AI_CODING_PACK/prompts/create-realtime-feature.md
```

For persistence/auth/web composition, inspect the corresponding Coding Pack skill plus `DEXT_ENTERPRISE_STARTER` before coding.

## Dext-native first

Do not hide Dext behind generic framework wrappers merely because a pattern is familiar.

Preferred examples:

- application startup via `IStartup` / `App.UseStartup(...)` when appropriate;
- typed Dext DI;
- native Dext JWT/auth middleware and authorization metadata;
- Dext Entity (`TDbContext`, `IDbSet<T>`) for ordinary database persistence;
- Dext realtime abstractions (Hub/WebSocket/SSE) selected deliberately from the actual requirement;
- Dext Testing for unit/integration tests.

A custom abstraction is allowed only when it represents a real domain/integration seam. `IMessengerTransport` is such a seam: it keeps messenger application logic independent from NATS and allows deterministic tests. Do not expand it into a generic framework that duplicates Dext.Nats.

## Realtime selection

For the client-facing transport:

- SSE: server-to-client only;
- raw WebSocket: custom bidirectional wire protocol;
- Dext Hub: groups/broadcast/application realtime when its semantics fit.

For this project, NATS is the internal distributed messaging backbone. It is not a replacement for the client authentication/authorization boundary.

Incoming frame sizes must be bounded. Connection lifetime, shutdown, slow-consumer behavior and backpressure must be explicit.

## Dependency direction

The intended dependency direction is:

```text
Models / Protocol / Subjects / Validation
                 ^
                 |
              Services
                 ^
                 |
     +-----------+-----------+
     |           |           |
   NATS       Gateway    Persistence
 adapter      adapter       adapter
```

Rules:

- `Dext.Messenger.Models` must not depend on NATS, WebSocket or a database.
- `Dext.Messenger.Subjects` must be pure and deterministic.
- protocol/validation code must be unit-testable without network I/O.
- NATS adapters may depend on `Dext.Net.Nats`; core domain units may not.
- JetStream-specific code must remain outside the basic realtime Core NATS adapter.
- persistence interfaces live above concrete PostgreSQL/other implementations.
- no UI framework dependencies in core/server business logic.
- Web/Hub endpoint units must remain thin transport adapters; Domain/Application code must not depend on Dext Web transport concerns.

## Persistence direction

The initial production persistence target is PostgreSQL, following `DEXT_ENTERPRISE_STARTER` conventions unless a messenger-specific requirement proves otherwise.

For ordinary persistence:

```text
Application Service
  -> scoped TDbContext
      -> IDbSet<TEntity>
          -> Dext Entity ORM
```

Do not add a ceremonial `IRepository -> TFDQuery/TUniQuery -> connection factory` stack around ordinary CRUD.

Specialized persistence components are acceptable for verified high-throughput bulk ingestion, provider-specific SQL, partition maintenance, archival, or another explicit capability not cleanly modeled through normal Dext Entity operations.

## Architecture invariants

1. NATS Core is used for ephemeral realtime distribution.
2. JetStream is used only where durable delivery/replay is required.
3. Long-term searchable message history belongs to a database.
4. Large media belongs to object storage.
5. Do not create one durable JetStream consumer per user.
6. Conversation is the normal ordering boundary; global ordering is not required.
7. Every retryable client send must carry a stable client message id.
8. Workers must be idempotent.
9. Queues must be bounded; silent unbounded memory growth is forbidden.
10. Client identity fields are untrusted until derived/verified by the gateway authentication context.
11. Core NATS realtime and JetStream durability must remain separate concerns in code and deployment topology.
12. Do not make 300k-concurrent claims without reproducible benchmarks.

## Delphi conventions

- Target modern Delphi (Delphi 12+).
- Prefer records for immutable/lightweight wire/domain DTOs where ownership is clear.
- Use `const` parameters for strings/records when mutation is not required.
- Avoid hidden ownership. Document who creates/frees objects and who owns interfaces.
- Avoid global mutable state.
- Avoid blocking network/database work in message callbacks unless explicitly isolated in a worker.
- Prefer bounded Dext channels for producer/consumer pipelines when a channel is needed.
- Keep hot-path allocation visible and benchmark before introducing complex micro-optimizations.
- Use `ILogger`/Dext observability facilities; never log secrets, auth tokens, or private message bodies by default.

## Namespace

Public units use the `Dext.Messenger.*` namespace.

Initial examples:

```text
Dext.Messenger.Models
Dext.Messenger.Subjects
Dext.Messenger.Validation
Dext.Messenger.Transport
Dext.Messenger.Nats
Dext.Messenger.JetStream
```

## Protocol compatibility

Internal subjects and wire envelopes are versioned. Breaking changes require a new major protocol/subject version rather than silently changing `v1` semantics.

See `Docs/PROTOCOL.md` and `Docs/ARCHITECTURE.md` before altering contracts.

## Evidence required before framework-facing changes

Before changing any of these areas, verify exact APIs from the canonical references:

- Dext WebSocket/Hub API;
- DI registration/lifetimes;
- JWT/auth middleware;
- Dext Entity persistence;
- NATS/JetStream calls;
- health checks/metrics;
- Dext Testing APIs.

Never invent an API from memory or from another ecosystem.

## Scale claims

Never claim that a specific number of concurrent connections or messages/sec is supported merely because the architecture targets it. Publish benchmark claims only with hardware, topology, payload/message mix, TLS mode, resource usage and p95/p99 latency.
