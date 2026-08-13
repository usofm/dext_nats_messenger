# AGENTS.md — Dext NATS Messenger

Read this file before changing the repository.

## Purpose

This project is a production-oriented distributed messenger/chat framework for Delphi built around Dext and `usofm/dext_nats`.

It is not a monolithic demo application. Keep domain contracts independent from WebSocket hosts, NATS transport details and database adapters.

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

## Delphi conventions

- Target modern Delphi (Delphi 12+).
- Prefer records for immutable/lightweight wire/domain DTOs where ownership is clear.
- Use `const` parameters for strings/records when mutation is not required.
- Avoid hidden ownership. Document who creates/frees objects and who owns interfaces.
- Avoid global mutable state.
- Avoid blocking network/database work in message callbacks unless explicitly isolated in a worker.
- Keep hot-path allocation visible and benchmark before introducing complex micro-optimizations.

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

## Scale claims

Never claim that a specific number of concurrent connections or messages/sec is supported merely because the architecture targets it. Publish benchmark claims only with hardware, topology, payload/message mix, TLS mode, resource usage and p95/p99 latency.
