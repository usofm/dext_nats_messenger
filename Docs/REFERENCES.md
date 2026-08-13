# Canonical References

This repository is developed against three project references maintained by the same owner. Contributors and coding agents should inspect these before framework-facing changes.

## 1. DEXT AI CODING PACK

Repository: `usofm/DEXT_AI_CODING_PACK`

Purpose:

- architecture/API decision guidance for Dext;
- anti-patterns and drift guards;
- exact symbol lookup guidance;
- task-focused skills for realtime, testing, web, ORM, security and performance;
- review and implementation prompts.

Observed release when this document was written:

```text
v2026.08.12-r3-dext-412ed292
```

Compatibility anchor:

```text
cesarliws/dext@412ed29207d2d1dc5d4a259a7739a615aed0c626
```

For Messenger realtime changes, start with:

```text
DEXT_DECISION_TREE.md
DEXT_ANTI_PATTERNS.md
skills/dext-realtime/SKILL.md
prompts/create-realtime-feature.md
prompts/review-dext-code.md
prompts/create-test-suite.md
```

Important guidance applied here:

- use WebSocket for a raw bidirectional client protocol;
- use Dext Hubs when groups/broadcast semantics fit;
- Event Bus is not a client realtime transport;
- bound incoming message size;
- define connection/shutdown lifetime;
- make backpressure and reconnect/error behavior explicit;
- prefer native Dext APIs before adding generic wrappers.

## 2. DEXT ENTERPRISE STARTER

Repository: `usofm/DEXT_ENTERPRISE_STARTER`

Purpose:

- practical Golden Sample for the Coding Pack;
- demonstrates Dext-native application composition;
- provides conventions for startup, DI, JWT, PostgreSQL, feature organization and thin endpoint adapters.

Key conventions adopted by Messenger server applications:

```text
IStartup / App.UseStartup
Typed Dext DI
Dext-native JWT/auth
Domain/Application independent from Dext Web transport
Thin HTTP/WebSocket/Hub adapters
PostgreSQL + Dext Entity for ordinary persistence
Scoped TDbContext
IDbSet<T>
WithPooling(True)
```

Messenger is not required to copy the Starter directory tree literally. The important requirement is preserving its dependency direction and Dext-native composition style.

## 3. DEXT NATS

Repository: `usofm/dext_nats`

Purpose:

- canonical native NATS transport for this project;
- Core NATS pub/sub and request/reply;
- TLS/auth/reconnect/drain;
- bounded subscription handler dispatch;
- JetStream, KeyValue, ObjectStore and Services API support.

Messenger code must verify exact NATS APIs against this repository before use.

Dependency direction:

```text
Dext Messenger Application/Core
            |
            | integration port
            v
Dext.Messenger.Nats
            |
            v
Dext.Net.Nats
            |
            v
NATS Server / JetStream
```

`Dext.Messenger.Nats` must remain a small integration adapter. It must not reimplement the NATS client, reconnect machinery, JetStream protocol or other functionality already supplied by `dext_nats`.

## Source priority

When references disagree or may have drifted, use this order:

1. Dext source at the Coding Pack compatibility anchor.
2. Official Dext skill/docs/example referenced by the Pack.
3. DEXT AI CODING PACK.
4. DEXT ENTERPRISE STARTER.
5. DEXT NATS for NATS-specific APIs.
6. Messenger-local conventions.

For NATS-specific behavior, the current `dext_nats` source is authoritative over Messenger-local assumptions.

## Why these references matter

This Messenger is intended to become a real production and benchmark workload for Dext. Consistency with the ecosystem is therefore a design requirement, not just a style preference.

The project should demonstrate:

- how Dext handles large client realtime workloads;
- how Dext.Nats provides distributed messaging between stateless gateway instances and workers;
- how JetStream is used selectively for durable workflows;
- how Dext Entity/PostgreSQL stores durable product state;
- how Dext observability/testing/performance tooling validates the result.
