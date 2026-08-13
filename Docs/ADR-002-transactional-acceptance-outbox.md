# ADR-002 — Transactional Acceptance and Outbox

**Status:** Accepted  
**Decision date:** 2026-08-13

## Context

An early implementation used a JetStream-first acceptance boundary: create a proposed message, publish it durably to JetStream, then remember the accepted result for idempotency.

That shape has a concurrency flaw. Two simultaneous retries carrying the same `(sender_user_id, client_message_id)` can both pass the pre-publish lookup and construct different server message IDs. JetStream `Nats-Msg-Id` can deduplicate the broker write, but it cannot make the two application responses converge on the same canonical message ID/sequence. The broker is not the authority for application identity.

## Decision

PostgreSQL is the canonical acceptance authority.

One database transaction must:

1. resolve an existing `(sender_user_id, client_message_id)` if present;
2. verify that a retry represents the same immutable logical command;
3. atomically allocate the next sequence for the conversation;
4. insert the canonical message row;
5. insert one `message.accepted.v1` outbox row;
6. commit.

Only a committed row may be returned as `accepted`.

A separate outbox dispatcher leases pending rows with `FOR UPDATE SKIP LOCKED`, publishes the canonical event to JetStream, and marks the outbox row published. Failure releases/reschedules the row with bounded exponential backoff.

JetStream `Nats-Msg-Id` remains a transport-level duplicate safety net. It is not the permanent product idempotency authority.

## Consequences

### Positive

- concurrent retries converge on one canonical message identity and sequence;
- a crash between database commit and broker publish does not lose the accepted event;
- JetStream outages can create backlog without corrupting durable acceptance state;
- multiple outbox workers can scale horizontally using leases and `SKIP LOCKED`;
- replay and operational recovery become explicit.

### Costs

- the write path contains a PostgreSQL transaction and therefore must be capacity-tested;
- outbox lag becomes a first-class operational metric;
- accepted-in-DB and delivered-online are intentionally separate states;
- production deployment requires disciplined database HA and connection pooling.

## Invariants

- `uq_messenger_sender_client` is mandatory.
- `(conversation_id, sequence_no)` is unique and monotonic.
- message row and outbox row are committed atomically.
- an outbox event may be published more than once physically, but has one logical identity.
- no client-provided message ID becomes the canonical server message ID.
- no application response reports acceptance for an uncommitted proposal.

## Rejected alternatives

**JetStream-first acceptance:** rejected because broker dedup does not solve application-response identity races.

**Dual write DB + JetStream in request transaction:** rejected because there is no distributed transaction spanning PostgreSQL and NATS, leaving an unavoidable crash window.

**One durable consumer per user:** rejected because consumer cardinality would scale with users/devices rather than bounded worker roles.
