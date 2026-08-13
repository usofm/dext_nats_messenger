# Dext NATS Messenger

High-performance distributed messaging and chat infrastructure for Delphi, built on **Dext** and **NATS / JetStream**.

> Status: early architecture and bootstrap phase. APIs are expected to evolve before the first stable release.

## Why this project exists

`dext_nats_messenger` is intended to provide the reusable server-side building blocks for personal chat, group chat, presence, typing indicators, delivery/read receipts, multi-device sessions, offline delivery, notifications, and later media metadata.

The design target is not a single-process chat demo. The target is a horizontally scalable system that can grow toward **hundreds of thousands of concurrent connections** without coupling application state to one server process.

The project deliberately separates four concerns:

1. **Dext Gateway / Application Layer** — client-facing HTTP/WebSocket endpoints, authentication, authorization, validation, rate limiting and protocol versioning.
2. **NATS Core** — low-latency ephemeral real-time distribution such as online delivery, presence and typing.
3. **JetStream** — durable event/delivery paths that require persistence, replay and acknowledgements.
4. **Database + Object Storage** — long-term conversation history and media blobs. JetStream is not treated as the permanent chat database.

## Architecture at a glance

```text
Clients (Mobile / Web / Desktop)
              |
         HTTPS/WebSocket
              |
     +--------v---------+
     | Dext Chat Gateway|   x N instances
     | Auth / ACL / RL  |
     +--------+---------+
              |
              | Dext.Nats
              v
     +------------------+
     |   NATS Cluster   |
     | Core + JetStream |
     +----+--------+----+
          |        |
          |        +------------------+
          v                           v
   Chat Workers                 Presence/Notify
          |
          v
   Persistence Workers
          |
          v
  PostgreSQL / other DB

Media: Client -> S3/MinIO -> message contains metadata/reference only
```

## Core design decisions

### 1. NATS is the real-time backbone, not the application database

NATS provides routing, fan-out and service-to-service messaging. JetStream adds durable delivery where needed. Conversation history, search, reporting and long-term retention belong in a database designed for those workloads.

### 2. Ephemeral events stay on Core NATS

Presence and typing indicators are transient. Persisting every `typing...` or online heartbeat would create unnecessary storage and consumer pressure.

Typical subjects:

```text
presence.user.<user_id>
typing.user.<user_id>
typing.group.<group_id>
```

### 3. Durable business events use JetStream

Examples include message accepted/created, delivery state changes, read receipts (when required by product semantics), group membership changes and offline-delivery workflows.

### 4. Do not create one durable JetStream consumer per user

The architecture must remain efficient at very large user counts. Durable processing will use shared/partitioned streams and worker consumers rather than hundreds of thousands of long-lived durable consumers.

Partitioning should be deterministic by conversation or another stable routing key, for example:

```text
partition = Hash(conversation_id) mod N
```

This preserves a path toward per-conversation ordering while allowing horizontal scale.

### 5. Client connections terminate at gateways

Although NATS can expose WebSocket connectivity, the default architecture keeps clients behind Dext gateways. This gives us one controlled place for authentication, authorization, bans, device/session rules, rate limiting, payload validation, anti-abuse controls, metrics and protocol upgrades.

### 6. Media is not transported as large NATS payloads

Images, videos and voice files go to object storage such as S3/MinIO. Chat messages contain file identifiers, URLs/tokens and metadata.

## Subject model (initial)

The subject namespace is versioned from day one:

```text
msg.v1.user.<user_id>                 # online/direct fan-out
msg.v1.group.<group_id>               # online group fan-out
msg.v1.conv.<conversation_id>         # conversation event routing

presence.v1.user.<user_id>
typing.v1.user.<user_id>
typing.v1.group.<group_id>

receipt.v1.delivered.<conversation_id>
receipt.v1.read.<conversation_id>

event.v1.message.created
event.v1.group.member_added
event.v1.group.member_removed
```

Exact subject contracts are documented in [`Docs/PROTOCOL.md`](Docs/PROTOCOL.md).

## Repository layout

```text
Source/                 Core Delphi units
Tests/                  Unit/integration tests
Demo/                   Runnable examples
Docs/
  ARCHITECTURE.md       System architecture and scaling model
  PROTOCOL.md           Subjects, envelopes and delivery semantics
  ADR-001-architecture.md
  ROADMAP.md
```

## Initial implementation phases

**Phase 0 — contracts and architecture**
- architecture documentation
- subject naming rules
- message envelope and IDs
- transport abstractions
- failure/idempotency rules

**Phase 1 — Core NATS messaging**
- personal message routing
- group message routing
- presence
- typing
- delivery callbacks
- multi-device fan-out model

**Phase 2 — JetStream durability**
- stream topology
- partition strategy
- persistence worker
- retry/backoff and DLQ policy
- deduplication/idempotency

**Phase 3 — Dext gateway**
- authentication/session model
- WebSocket protocol
- HTTP APIs for history/groups
- rate limiting
- observability

**Phase 4 — scale validation**
- load generator
- connection benchmarks
- message fan-out benchmarks
- failure/reconnect tests
- capacity planning for 300k concurrent users

## Dependency

The NATS transport layer is based on [`usofm/dext_nats`](https://github.com/usofm/dext_nats), which already provides a native Dext NATS client including publish/subscribe, request/reply, reconnect handling, TLS/authentication and JetStream-related APIs.

## Non-goals for the first release

- storing large media blobs inside NATS
- treating JetStream as the permanent searchable message database
- one dedicated server thread per user or conversation
- one durable JetStream consumer per registered user
- binding business logic directly to a specific UI framework

## License

License will follow the repository owner's chosen policy. Until a license file is committed, do not assume redistribution terms beyond GitHub's repository visibility.
