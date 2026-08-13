# Protocol

This document defines the initial internal messaging contracts for Dext NATS Messenger.

The protocol is intentionally versioned from the first implementation. Breaking changes create a new versioned namespace rather than silently changing the meaning of existing subjects or envelopes.

## Naming rules

- subjects are lowercase
- tokens are separated with `.`
- version appears near the root (`v1`)
- opaque IDs are preferred over display names
- user supplied text is never embedded directly into a subject
- IDs used in subjects must be normalized to an allowed NATS-safe representation

## Subject families

### Online direct delivery

```text
msg.v1.user.<user_id>
```

Used for transient delivery to currently connected sessions of a logical user.

### Group realtime distribution

```text
msg.v1.group.<group_id>
```

Used for realtime group distribution. Durable persistence remains a separate concern.

### Conversation routing

```text
msg.v1.conv.<conversation_id>
```

Used when a service needs to route work based on a conversation identity.

### Presence

```text
presence.v1.user.<user_id>
```

Core NATS only. No replay semantics.

### Typing

```text
typing.v1.user.<user_id>
typing.v1.group.<group_id>
```

Core NATS only. Consumers should expire stale typing state locally.

### Receipts

```text
receipt.v1.delivered.<conversation_id>
receipt.v1.read.<conversation_id>
```

Receipt durability is product-policy dependent. A read receipt is not equivalent to persistence of the original message.

### Domain events

```text
event.v1.message.created
event.v1.group.member_added
event.v1.group.member_removed
```

As the protocol grows, high-volume domain events may be partitioned under a more specific subject hierarchy.

## Message envelope

The first implementation uses an explicit envelope rather than passing arbitrary application JSON directly through the transport boundary.

Conceptual representation:

```json
{
  "version": 1,
  "message_id": "01K...",
  "client_message_id": "device-generated-id",
  "conversation_id": "conv-id",
  "sender_user_id": "user-id",
  "kind": "text",
  "created_at_unix_ms": 1786590000000,
  "payload": {
    "text": "hello"
  }
}
```

Required design properties:

- `version` makes schema evolution explicit
- `message_id` is canonical server identity after acceptance
- `client_message_id` provides sender idempotency
- `conversation_id` defines the main ordering boundary
- `sender_user_id` is derived/validated by the trusted gateway, never blindly trusted from the socket payload
- `kind` controls payload interpretation
- timestamp uses UTC epoch milliseconds at the wire boundary

## Message ID

The library exposes message IDs as strings and does not initially hard-code the application to a database-specific integer identity.

A time-sortable identifier such as UUIDv7 or ULID is appropriate. The concrete generator can evolve, but IDs must be globally safe across multiple gateway processes without a central sequence bottleneck.

## Client message ID

Clients MUST generate a stable ID before the first send attempt.

Retry example:

```text
attempt 1 -> timeout
attempt 2 -> same client_message_id
```

The server must recognize the second request as the same logical message rather than persist a duplicate.

## Message kinds

Initial reserved kinds:

```text
text
image
audio
video
file
system
```

Media kinds carry metadata/reference only. Binary media content is not embedded in the normal chat envelope.

## Presence event

Conceptual representation:

```json
{
  "version": 1,
  "user_id": "user-id",
  "device_id": "device-id",
  "gateway_id": "gateway-03",
  "state": "online",
  "at_unix_ms": 1786590000000
}
```

Allowed initial states:

```text
online
offline
heartbeat
```

Consumers must tolerate missing explicit `offline` events after crashes by using lease/timeout semantics.

## Typing event

Conceptual representation:

```json
{
  "version": 1,
  "conversation_id": "conv-id",
  "user_id": "user-id",
  "is_typing": true,
  "at_unix_ms": 1786590000000
}
```

Typing events are ephemeral and must never be replayed as historical activity.

## Delivery receipt

Conceptual representation:

```json
{
  "version": 1,
  "message_id": "01K...",
  "conversation_id": "conv-id",
  "user_id": "recipient-user",
  "device_id": "device-id",
  "state": "delivered",
  "at_unix_ms": 1786590000000
}
```

Receipt aggregation policy (per-device vs per-user) belongs to the application service and persistence layer, not to the transport record itself.

## Encoding

The bootstrap implementation uses UTF-8 JSON for debuggability and interoperability.

This is a deliberate first step, not a permanent performance constraint. The transport abstraction must allow a later codec such as MessagePack/Protobuf without changing domain service interfaces.

## Payload limits

Every gateway must enforce application payload limits below the configured NATS server maximum. This leaves protocol/headroom and prevents clients from using the broker's absolute limit as an application contract.

Exact defaults will be introduced with configuration and benchmark data.

## Trusted vs untrusted fields

The client may propose:

- client_message_id
- destination/conversation intent
- message kind
- message payload

The gateway owns or verifies:

- sender_user_id
- authenticated device/session
- canonical message_id
- server acceptance timestamp
- membership/authorization
- normalized subject destination

A client-provided sender identity must never override authenticated context.

## Compatibility

Consumers must ignore unknown optional fields when possible.

A consumer must reject an unsupported major `version` explicitly instead of attempting to interpret it as the current schema.
