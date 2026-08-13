# VCL Messenger Client

This is the engineering VCL client for `dext_nats_messenger`.

## Current mode: Developer / Direct NATS

The first bootstrap version connects directly to a local/dev NATS server and uses:

```text
VCL UI
  -> TMessengerMessageService
      -> IMessengerTransport
          -> TDextMessengerNatsTransport
              -> TDextNatsClient
```

This mode exists to validate the messenger core, subject contracts, codec, delivery callbacks and NATS behavior quickly.

It is **not** the intended production security topology for end users.

## Planned production mode: Dext Gateway

The production client mode will be:

```text
VCL UI
  -> Messenger Client API
      -> Dext WebSocket / Hub Gateway
          -> authenticated application service
              -> NATS Core / JetStream
```

The form must not embed NATS-specific business logic so that the transport can be replaced without rewriting the chat UI.

## Quick test

1. Start a local NATS server on `127.0.0.1:4222`.
2. Run two VCL client instances.
3. Connect the first as `user-a`.
4. Connect the second as `user-b`.
5. Set the target user to the other user and send a text message.

The client subscribes to `msg.v1.user.<user_id>` through `TMessengerMessageService`.

## Next UI capabilities

- conversation list
- personal chat tabs
- group chat
- online/presence indicator
- typing indicator
- delivered/read markers
- connection/reconnect status
- message timestamps
- history load through Gateway HTTP API
- attachment metadata/upload flow
- developer diagnostics panel
- load/burst test helpers
