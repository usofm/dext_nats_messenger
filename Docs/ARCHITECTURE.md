# Architecture

## Goals

Dext NATS Messenger is designed as a distributed messaging platform for personal and group chat with a target architecture capable of scaling toward 300,000 concurrent client connections.

The system must provide:

- low-latency personal and group delivery
- horizontal gateway scaling
- multi-device sessions
- presence and typing
- durable/offline message processing
- delivery/read state
- replay after temporary failures
- clear ordering boundaries
- idempotent processing
- observability and capacity testing
- isolation of transport from domain/business logic

## Component model

### Client

Mobile, web and desktop clients connect to a Dext Gateway using WebSocket for realtime traffic and HTTPS for conventional APIs where appropriate.

Clients do not need direct NATS credentials in the default architecture.

### Dext Gateway

Gateway responsibilities:

- authenticate client/session/device
- authorize conversation/group access
- validate incoming envelopes
- enforce size/rate limits
- maintain WebSocket connections
- route commands into NATS
- subscribe to delivery subjects needed by its locally connected sessions
- fan out one logical user delivery to all of that user's connected devices on that gateway
- expose health/metrics

Gateways should be stateless with respect to durable chat history. A process restart must not destroy durable message state.

### NATS Core

Core NATS is the realtime distribution fabric.

Good Core NATS workloads:

- online message delivery
- presence
- typing
- transient service notifications
- service request/reply

These paths favor latency and do not necessarily need storage.

### JetStream

JetStream handles workflows where persistence and acknowledgements matter:

- accepted message events
- persistence pipeline
- offline/retry delivery
- selected receipts
- membership/control events
- replay after worker failure

JetStream is a delivery/event log layer, not the primary searchable conversation database.

### Persistence database

The database owns durable product state, including:

- users and devices
- conversations
- group membership
- message history
- message metadata
- receipt state as required
- moderation/audit records as required

The initial architecture remains database-agnostic at the core library boundary. A PostgreSQL adapter is a likely production implementation, but business contracts must not require PostgreSQL-specific code.

### Object storage

Large files are stored externally (for example S3 or MinIO). Messages carry media references and metadata only.

## Connection scaling

300,000 concurrent users must not imply one monolithic Delphi process.

Example capacity model (illustrative, benchmark required):

```text
                  Load Balancer
                       |
       +---------------+---------------+
       |               |               |
   Gateway 01      Gateway 02      Gateway NN
   WebSockets      WebSockets      WebSockets
       |               |               |
       +---------------+---------------+
                       |
                  NATS Cluster
```

A capacity target such as 15k-30k WebSocket connections per gateway may be used for initial engineering tests, but no production number is considered valid until measured using the actual Dext WebSocket implementation, TLS configuration, message rate and hardware.

The gateway count must include headroom for rolling deploys and failures.

## User and device routing

A user can have multiple online devices. We model identity separately:

```text
User
  +- Device A / Session 1
  +- Device B / Session 2
  +- Web / Session 3
```

Logical user delivery is therefore distinct from a socket connection.

A later implementation may maintain ephemeral routing information such as:

```text
user_id -> gateway_ids / active device sessions
```

This routing state can be reconstructed and must never be the only source of durable product data.

## Conversation ordering

Global ordering for the entire platform is neither needed nor desirable.

The useful ordering boundary is normally a conversation.

All durable processing for one conversation should map to a deterministic partition:

```text
partition = StableHash(conversation_id) mod partition_count
```

The partition count is configuration and must not be silently changed after production data exists without a migration/repartition strategy.

## Personal message flow

A simplified send path:

```text
Sender Client
    |
    v
Dext Gateway
    |  validate/auth/idempotency key
    v
message command/event
    |
    v
NATS / JetStream
    |
    +--> persistence worker --> database
    |
    +--> online delivery path --> recipient gateway(s)
                                  |
                                  +--> device 1
                                  +--> device 2
```

The sender receives a server-generated/accepted message identity once the message has passed the defined acceptance boundary.

## Group message flow

The producer must not perform a separate durable write for every member merely because the group contains many users.

One logical group message is persisted once. Online distribution is handled through routing/fan-out services.

For very large groups, fan-out strategy may evolve independently from message persistence. The protocol must therefore avoid coupling a message record to a fixed list of recipient deliveries.

## Presence

Presence is ephemeral.

Recommended semantics:

- gateway publishes online/heartbeat/offline events
- presence service aggregates state
- abrupt disconnect is detected through session timeout/lease expiration
- presence events are not written into chat history

Exact-online state is inherently time-sensitive. Consumers should treat it as a hint, not financial-grade durable state.

## Typing

Typing events use Core NATS only, include a short logical TTL in their application semantics and are never replayed after reconnect.

## Delivery states

The project distinguishes multiple boundaries:

1. **client-sent** — sender generated the request locally
2. **server-accepted** — server accepted/idempotently recognized the message
3. **persisted** — durable database write succeeded
4. **delivered** — at least one target device/session acknowledged delivery, according to configured product semantics
5. **read** — user/device reported visibility/read according to product semantics

These terms must not be conflated.

## Idempotency

Every client message command must carry a client-generated idempotency key (`client_message_id`).

Server processing maps it to a canonical message id. Retries after timeout must not create duplicates.

Suggested uniqueness boundary:

```text
(sender_user_id, client_message_id)
```

The exact database constraint belongs to the persistence adapter.

## Retry and dead-letter handling

Durable workers must use explicit acknowledgement.

General policy:

```text
success       -> ACK
transient     -> NAK / retry with backoff
poison/fatal  -> TERM or move to DLQ policy
```

Retries must remain idempotent.

A DLQ entry must preserve enough metadata to diagnose and replay safely.

## Backpressure

No layer may silently buffer without bound.

We require bounded queues for:

- gateway outgoing socket queues
- worker dispatch queues
- persistence batches
- retry paths

When capacity is exhausted, the system must apply a deliberate policy: throttle, reject, disconnect slow consumer, or defer durable processing. Silent memory growth is not acceptable.

## Security boundary

Clients are untrusted.

The gateway validates:

- authenticated user
- device/session validity
- conversation/group membership
- message type
- payload size
- allowed metadata
- rate limits

Internal NATS subjects are not a client authorization mechanism. Authorization must be enforced before a client command becomes an internal trusted event.

## Observability

At minimum we will measure:

- active gateway connections
- messages accepted/sec
- messages delivered/sec
- NATS publish/receive counts
- JetStream pending/ack latency
- persistence latency
- retries and DLQ count
- socket send queue depth
- slow consumer disconnects
- end-to-end p50/p95/p99 delivery latency
- reconnects
- memory/CPU per gateway

## Failure scenarios that must be tested

- gateway process killed with active users
- one NATS node unavailable
- JetStream leader change
- database unavailable temporarily
- persistence worker crash before ACK
- duplicate client send after timeout
- recipient offline then reconnects
- slow recipient connection
- large group burst
- rolling deployment
- NATS reconnect while gateway is active

## Scale rule

The architecture is considered ready for a claimed concurrency level only after load tests demonstrate it with documented:

- hardware
- operating system
- TLS configuration
- connection count
- message mix
- message size
- group distribution
- CPU/memory
- p95/p99 latency
- failure headroom

Architecture targets are not benchmark results.
