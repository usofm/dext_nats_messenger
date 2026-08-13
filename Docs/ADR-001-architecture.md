# ADR-001: Dext Gateway + NATS Core + JetStream + Durable Database

- Status: Accepted
- Date: 2026-08-13

## Context

The platform must support personal and group realtime messaging and be able to scale horizontally toward hundreds of thousands of concurrent users.

A single technology can technically perform more than one responsibility, but combining connection management, authorization, ephemeral fan-out, durable delivery and long-term searchable history into one subsystem would make scaling and failure recovery unnecessarily coupled.

## Decision

We separate the system into four primary responsibility boundaries:

1. Dext gateways terminate external client connections and enforce trust/security policy.
2. NATS Core provides low-latency ephemeral routing and realtime fan-out.
3. JetStream provides durable asynchronous workflows, acknowledgement, retries and replay.
4. A persistent database owns long-term application state and searchable message history.

Large media is stored in external object storage and referenced by messages.

We do not create one JetStream durable consumer per user. Durable processing is partitioned and consumed by scalable worker groups.

We do not require clients to connect directly to NATS in the default architecture.

## Why NATS

NATS matches the communication topology required by chat:

- subject-based routing
- pub/sub fan-out
- request/reply for internal services
- queue groups for horizontally scaled workers
- JetStream for persistence/replay
- clustering and reconnect-oriented operation

The existing `dext_nats` project gives the Delphi/Dext ecosystem a native transport implementation and avoids introducing a second language runtime merely for the messaging client.

## Why Dext gateways

The gateway creates an explicit trust boundary. It can authenticate once, normalize all incoming commands and prevent external clients from receiving internal broker permissions.

It also lets us evolve the public WebSocket protocol independently from internal NATS subjects.

## Why not JetStream as the chat database

Chat history needs application-level queries such as pagination, conversation search, membership joins, moderation, reporting and retention policies. A database is a better ownership boundary for that product state.

JetStream remains extremely valuable as the reliable transport/event log between services.

## Consequences

Positive:

- horizontal scale by adding gateways/workers
- transport and persistence can scale independently
- domain logic remains testable without sockets or a database
- transient traffic does not create unnecessary durable storage
- workers can recover through replay/retry
- public protocol is isolated from internal routing

Costs:

- more components than a monolith
- requires idempotency across asynchronous boundaries
- requires observability and operational discipline
- database persistence and online delivery may complete at different times, so message states must be explicit

## Rejected alternatives

### Direct client-to-NATS as the default

Technically possible, but it makes client authorization, subject permissions, device policy and protocol evolution more tightly coupled to broker credentials and configuration.

### One durable consumer per user

Rejected because user count should not directly translate into a permanent broker resource count. We prefer shared partitioned workers plus realtime subscription interest.

### Store media directly as ordinary NATS messages

Rejected because large images/video/audio should use storage designed for blob delivery and lifecycle management.

### Single gateway process

Rejected because it creates a connection and deployment failure domain inconsistent with the concurrency target.
