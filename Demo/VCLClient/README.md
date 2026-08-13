# VCL Messenger Client

The VCL demo now has two explicit operating modes.

## Production Gateway mode

This is the default mode. The desktop client does **not** receive privileged NATS credentials.

```text
VCL UI
  -> TMessengerHttpClient
      -> authenticated Dext Gateway HTTPS APIs
          -> acceptance / sync / cursor services
              -> PostgreSQL + NATS/JetStream backend
```

The form accepts a Gateway base URL, JWT and conversation ID. Message sends go through `/api/messenger/messages`; reconnect/history recovery uses `/api/messenger/sync`; successfully processed history advances the delivered cursor.

The shared Delphi HTTP client also exposes direct/group conversation creation/listing, group member management, read/delivered cursor operations and media upload/commit/resolve APIs.

The current VCL form uses a one-second sync timer as a simple production-safe delivery/recovery path. A future UI optimization may attach a Dext Hub-compatible Delphi WebSocket client for immediate push while retaining cursor sync as the correctness/recovery mechanism. The server-side Hub is already implemented at `/hubs/messenger`.

## Developer direct-NATS mode

This optional diagnostic mode connects directly to a development NATS server:

```text
VCL UI
  -> TMessengerMessageService
      -> IMessengerTransport
          -> TDextMessengerNatsTransport
              -> TDextNatsClient
```

It is useful for codec/subject/NATS diagnostics but is **not** the intended production end-user security topology.

## Production quick test

1. Start the Gateway/backend stack and create/authenticate two users.
2. Ensure JWTs contain the required user, `device_id` and `session_id` claims.
3. Create or identify a direct conversation through the Gateway API.
4. Run two VCL instances in Production Gateway mode.
5. Enter each user's Gateway URL, JWT and the shared conversation ID.
6. Send a message to the other user.
7. The other instance obtains the canonical message through sync and advances its delivered cursor.

## Developer quick test

1. Start a local NATS server on `127.0.0.1:4222`.
2. Uncheck Production Gateway mode.
3. Run two VCL instances as `user-a` and `user-b`.
4. Send direct test messages between the users.

## UI boundary

Business rules remain outside the form. The VCL project consumes the shared client/domain services so the same backend contracts can be reused by FGX Native, UniGUI or other Delphi clients.
