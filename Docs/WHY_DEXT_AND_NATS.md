# Why Dext + NATS Instead of Dext Alone?

## Purpose

This document explains a deliberate architectural decision in `dext_nats_messenger`:

> **Dext is used for the client-facing application and realtime gateway layer, while NATS is used as the distributed messaging backbone between gateways, workers, and internal services.**

The decision is not based on a limitation in Dext's ability to serve HTTP or WebSocket clients. Dext is fully capable of handling the edge/application side of the system. NATS is added because the project is designed as a horizontally scalable distributed messenger, not as a single-process or single-node chat server.

The target architecture must support large numbers of concurrent connections, multiple gateway instances, group fan-out, multi-device delivery, durable workflows, retries, failure recovery, rolling restarts, background workers, and service-to-service messaging.

---

## Executive Summary

Dext and NATS solve different problems.

- **Dext** is the application edge: HTTP APIs, WebSocket/Hub connections, authentication, authorization, validation, rate limiting, protocol handling, and client session management.
- **NATS Core** is the low-latency distributed event bus: gateway-to-gateway delivery, worker messaging, realtime fan-out, presence, typing, and internal service communication.
- **JetStream** is used where broker-level durability, acknowledgements, replay, retry, and shared worker consumption are useful.
- **PostgreSQL** remains the source of truth for messages, conversations, memberships, cursors, receipts, idempotency, and the transactional outbox.

The design intentionally does **not** make NATS the application database.

```text
Clients
  |
  | HTTPS / WebSocket
  v
Dext Gateway Cluster
  |
  | internal distributed messaging
  v
NATS Core / JetStream
  |
  +--> Delivery Workers
  +--> Notification Workers
  +--> Presence / Realtime Services
  +--> Other Gateway Nodes

PostgreSQL
  ^
  |
  +-- canonical messages
  +-- conversations and membership
  +-- cursors and receipts
  +-- transactional outbox
```

---

## Why Dext Alone Was Not Chosen

A Dext-only messenger is technically possible.

A smaller deployment could be implemented as:

```text
Clients
  |
  v
Dext Gateway
  |
  v
PostgreSQL
```

This is a valid architecture for a small or moderate deployment, especially when there is only one gateway process or when cross-node realtime routing is minimal.

The difficulty appears when the system is horizontally scaled.

Assume the deployment has many Dext gateway instances:

```text
Gateway 1 -> User A
Gateway 2 -> User B
Gateway 3 -> User C
...
Gateway N -> more users
```

If User A sends a message to User B, Gateway 1 must deliver that event to the node currently hosting User B's live connection.

Without a distributed messaging backbone, the application would need to build and maintain its own mechanism for:

- gateway discovery;
- cross-node routing;
- distributed publish/subscribe;
- group fan-out;
- worker distribution;
- node failure handling;
- retry queues;
- backpressure;
- durable event delivery;
- replay;
- service-to-service communication;
- rolling restart coordination;
- reconnect routing.

At that point, the messenger application would effectively begin implementing its own message broker.

That is intentionally avoided.

---

## What Dext Is Responsible For

Dext is the client-facing platform and application boundary.

### HTTP APIs

Dext handles authenticated application APIs such as:

- send message;
- conversation creation;
- group membership operations;
- conversation history;
- offline synchronization;
- delivered/read cursors;
- receipt submission;
- media upload authorization;
- media commit/resolve operations.

### WebSocket / Hub Connections

Dext owns the live client connection lifecycle.

Responsibilities include:

- WebSocket connection establishment;
- authentication;
- user/device/session identity;
- connection registry;
- client protocol handling;
- message-size enforcement;
- slow-consumer protection;
- server push;
- connection cleanup;
- reconnect behavior.

### Security Boundary

The client never controls trusted identity fields such as `sender_user_id`.

The Dext gateway derives trusted identity from the authenticated context and applies:

- authorization;
- conversation membership checks;
- rate limits;
- payload validation;
- anti-abuse policy;
- protocol versioning.

NATS is therefore kept behind the application boundary rather than exposed as the default client protocol.

---

## What NATS Is Responsible For

NATS is the distributed realtime backbone.

### Cross-Gateway Routing

Consider:

```text
User A -> Gateway 1
User B -> Gateway 7
```

Gateway 1 does not need a hard-coded connection to Gateway 7.

Instead:

```text
Gateway 1
   |
   | publish internal delivery event
   v
 NATS
   |
   v
Gateway 7
   |
   v
User B
```

This removes direct gateway-to-gateway coupling.

### Horizontal Scaling

New gateway and worker instances can join the system without requiring every existing node to know about every new node directly.

The application can scale by role:

```text
Gateway x N
Delivery Worker x M
Notification Worker x K
Persistence/Outbox Worker x P
```

The distributed bus remains the communication layer between those roles.

### Group Fan-Out

For a large group, online members may be spread across many gateway instances.

The system should not persist or create one broker consumer per group member.

Instead, one logical event can be distributed through the broker and each interested gateway performs local fan-out to its own connected sessions.

This keeps connection ownership local to the gateway while keeping event distribution global.

### Realtime Ephemeral Events

Some events should not become permanent database records.

Examples:

- typing started/stopped;
- presence heartbeat;
- transient online status;
- realtime delivery hints.

Core NATS is well suited to these low-latency transient events.

---

## Why JetStream Is Used Selectively

JetStream is not used as the permanent chat history database.

It is used for distributed workflows where broker durability is useful, such as:

- accepted message delivery events;
- shared durable consumers;
- retries;
- acknowledgements;
- replay after worker restart;
- poison-message handling;
- DLQ workflows.

The permanent message record remains in PostgreSQL.

This distinction is important.

```text
PostgreSQL = source of truth
JetStream   = durable distributed delivery mechanism
NATS Core   = transient realtime distribution
Dext        = application/gateway edge
```

---

## Why PostgreSQL Is Still the Source of Truth

The architecture uses **Transactional Acceptance + Transactional Outbox**.

A message is not considered accepted merely because it was published to NATS or JetStream.

The canonical acceptance transaction writes:

1. the canonical message;
2. the conversation sequence;
3. permanent idempotency state;
4. the outbox event;

inside the same PostgreSQL transaction.

After commit, an outbox worker publishes the event to NATS/JetStream.

```text
Client
  |
  v
Dext Gateway
  |
  v
PostgreSQL Transaction
  |
  +-- Message
  +-- Sequence
  +-- Idempotency
  +-- Outbox
  |
 COMMIT
  |
  v
Outbox Worker
  |
  v
NATS / JetStream
```

This means a temporary NATS outage does not automatically mean the accepted message is lost.

The outbox remains available for retry after the broker returns.

This is a deliberate reliability property.

---

## Why PostgreSQL LISTEN/NOTIFY Was Not Used as the Main Realtime Bus

PostgreSQL can provide `LISTEN/NOTIFY`, and a Dext + PostgreSQL-only implementation could use it for smaller installations.

However, this project intentionally avoids turning the primary database into all of the following at once:

- long-term message storage;
- transactional coordinator;
- history/search database;
- realtime pub/sub bus;
- worker queue;
- retry engine;
- gateway coordination layer.

Keeping realtime distribution in NATS reduces coupling between transactional storage workloads and realtime messaging workloads.

PostgreSQL remains optimized around durable application state, while NATS handles distributed messaging.

---

## Why Not Direct Server-to-Server HTTP Between Gateways?

A gateway mesh based on direct HTTP calls would require every node to know where users are connected and where every peer is located.

It would also require custom handling for:

- topology changes;
- node discovery;
- retry;
- duplicate delivery;
- timeout policy;
- dead nodes;
- reconnects;
- large group fan-out;
- queueing during temporary failures.

NATS removes most of this explicit peer-to-peer coupling.

Gateways communicate through subjects rather than directly depending on other gateway addresses.

---

## Why Not One Durable Consumer Per User?

Even though JetStream supports durable consumers, the architecture does not create one durable consumer for every registered user.

At very large user counts that would create unnecessary broker metadata and operational overhead.

Instead the design uses:

- shared durable consumers for workers;
- deterministic conversation partitioning;
- PostgreSQL message history;
- per-user/per-conversation cursors;
- gateway-local live connection state.

Offline recovery therefore uses conversation history plus cursors rather than hundreds of thousands of durable user queues.

---

## Separation of Responsibilities

| Concern | Dext | NATS Core | JetStream | PostgreSQL |
|---|---:|---:|---:|---:|
| HTTP API | Yes | No | No | No |
| WebSocket / Hub clients | Yes | No | No | No |
| Authentication / authorization | Yes | No | No | Supporting data |
| Rate limiting / protocol validation | Yes | No | No | No |
| Gateway-local connection state | Yes | No | No | Optional durable metadata |
| Cross-gateway realtime routing | Adapter | Yes | Optional | No |
| Presence / typing distribution | Adapter | Yes | No | Usually no |
| Durable distributed worker delivery | Adapter | No | Yes | Outbox/source data |
| Retry / replay / broker ACK | No | No | Yes | Outbox retry state |
| Canonical message history | No | No | No | Yes |
| Permanent idempotency | Application | No | Transport safety only | Yes |
| Conversation ordering sequence | Application | No | Carries sequence | Yes |
| Offline sync / search | API | No | No | Yes |
| Large media blobs | API metadata only | No | No | Metadata only; object storage holds bytes |

---

## Benefits of the Dext + NATS Architecture

### 1. Clear Separation of Concerns

Dext handles application and client concerns. NATS handles distributed messaging. PostgreSQL handles durable state.

No single component is forced to solve every problem.

### 2. Horizontal Scalability

Gateways and workers can scale independently.

### 3. Loose Coupling

Gateway nodes do not need hard-coded peer knowledge.

Workers and services communicate using message contracts instead of direct process references.

### 4. Failure Isolation

A temporary failure in one worker or gateway does not require the entire system to stop.

### 5. Better Realtime Fan-Out

Cross-node delivery and group distribution are natural pub/sub workloads.

### 6. Durable Workflows Without Making the Broker the Database

JetStream provides distributed delivery guarantees while PostgreSQL remains authoritative.

### 7. Easier Future Service Decomposition

Notification, moderation, analytics, audit, AI, media processing, and other future services can subscribe to internal events without making the primary gateway tightly coupled to those services.

---

## Costs and Trade-offs

Using NATS is not free.

The architecture has additional operational complexity:

- another clustered infrastructure component;
- NATS authentication and authorization;
- JetStream storage planning;
- broker monitoring;
- stream and consumer configuration;
- network policies;
- additional failure modes;
- operational knowledge for the engineering team.

A Dext-only architecture would be simpler to deploy and debug for a small installation.

The decision to use NATS is therefore justified by the expected distributed scale and feature set, not because every messenger application requires a broker.

---

## When Dext Alone Would Be Reasonable

A Dext-only architecture can be a good choice when most of the following are true:

- deployment is single-node or very small;
- concurrent connection count is moderate;
- cross-node group fan-out is limited;
- few background services exist;
- no strong need exists for distributed replay/worker delivery;
- operational simplicity is more important than independent horizontal scaling.

This project intentionally targets a different operating envelope.

---

## Project Decision

For `dext_nats_messenger`, the chosen architecture remains:

```text
Dext
  = client gateway + HTTP + WebSocket/Hub + security + application boundary

NATS Core
  = distributed low-latency realtime backbone

JetStream
  = durable distributed event delivery where appropriate

PostgreSQL
  = canonical application state and source of truth

S3 / MinIO-style storage
  = large media bytes
```

The most important principle is:

> **Dext and NATS are not competing technologies in this system. They operate at different layers. Dext owns the edge; NATS owns the distributed messaging fabric.**

The architecture was selected so that client handling, distributed messaging, and permanent state can scale independently without requiring the messenger application to implement a custom message broker itself.

---

## Related Documents

- `Docs/ARCHITECTURE.md`
- `Docs/PROTOCOL.md`
- `Docs/ADR-001-architecture.md`
- `Docs/ADR-002-transactional-acceptance-outbox.md`
- `Docs/ROADMAP.md`
- `Docs/CODEX_HANDOFF.md`
