# Codex Validation and Improvement Handoff

This repository branch is intentionally implementation-complete but not runtime-certified. Codex should validate and improve it in the order below. Preserve the architectural invariants in ADR-002 unless a replacement is justified with equivalent or stronger failure guarantees.

## 1. Establish exact dependency SHAs

Record the checked-out SHAs for:

- `usofm/dext_nats_messenger`
- `usofm/dext_nats`
- the Dext framework source used by the Delphi compiler

Do not validate against silently different Dext/dext_nats APIs.

## 2. Compile-first pass

Compile `Tests/Dext.Messenger.Tests.dpr` with Delphi 12 before making behavioral changes.

Recommended order for fixing errors:

1. type visibility / `uses` ordering;
2. Dext generic endpoint signatures;
3. Dext Entity raw-command parameter binding;
4. `System.Net.HttpClient` request API differences;
5. JSON casing/serialization assumptions;
6. VCL form/component binding;
7. warnings indicating lifetime/threading hazards.

Do not replace Dext abstractions with ad-hoc FireDAC/WebSocket code merely to make compilation easier. Fix the integration at the intended abstraction boundary.

## 3. Unit/contract suite

Run `Tests/Dext.Messenger.Tests.dpr` and expand coverage around:

- concurrent `(sender_user_id, client_message_id)` acceptance;
- logical-command mismatch on duplicate idempotency key;
- direct conversation concurrent creation;
- conversation authorization;
- delivery envelope malformed JSON/headers;
- DLQ publish failure before TERM;
- rate-limit shard isolation/cleanup;
- slow-consumer accounting;
- monotonic receipt/cursor updates;
- media ready/quarantine policy.

## 4. PostgreSQL integration

Start with `deploy/docker-compose.dev.yml` and apply migrations in numeric order.

Required integration tests:

- atomic message + sequence + outbox commit;
- transaction rollback on failure at each statement boundary;
- concurrent acceptance winner/loser convergence;
- `FOR UPDATE SKIP LOCKED` outbox leasing with multiple workers;
- lease expiration and reclaim after worker death;
- direct-pair unique race convergence;
- active-membership history security;
- read/delivered cursor monotonicity;
- receipt idempotency;
- group owner/admin role rules.

## 5. NATS / JetStream integration

Validate against the pinned `dext_nats` API:

- stream bootstrap and compatible existing-stream behavior;
- accepted-event headers and `Nats-Msg-Id`;
- shared durable pull consumer;
- ACK only after Core NATS fan-out succeeds;
- NAK/backoff on transient errors;
- poison event -> DLQ publish -> TERM;
- DLQ failure -> NAK, never silent TERM;
- redelivery after delivery-worker death;
- JetStream leader/node failure.

## 6. Gateway validation

Validate JWT claim extraction for `NameIdentifier`, `device_id` and `session_id`.

Exercise every route:

- conversation direct/group creation and listing;
- group add/remove member;
- message send;
- sync/history;
- delivered/read cursors and receipts;
- media upload/commit/resolve;
- WebSocket Hub negotiate/connect/push.

Security tests must attempt sender spoofing, conversation-ID guessing, unauthorized group routing, oversized Hub payloads, invalid subject tokens and malformed JSON.

## 7. VCL client

Compile and run both modes:

- **Production Gateway mode:** JWT + HTTP commands + sync cursor.
- **Developer NATS mode:** diagnostics only; never use privileged NATS credentials as the production desktop architecture.

Improve UI/group support as needed without moving business rules into the form.

## 8. Go load generator

From `Benchmarks/loadgen`:

```bash
go mod tidy
go test ./...
go vet ./...
go build ./...
```

Commit the resulting `go.sum` once dependency resolution is validated.

## 9. Failure injection

Execute every scenario in `Benchmarks/FAILURE_MATRIX.md`. Store immutable reports under:

```text
Benchmarks/results/YYYY-MM-DD/<scenario>.md
```

The report must include exact SHAs and topology.

## 10. Performance campaign

Run separate campaigns for:

1. idle WebSocket connection memory/cpu;
2. connection ramp and reconnect storm;
3. direct message steady state;
4. direct message burst;
5. small group fan-out;
6. large group/channel fan-out;
7. outbox backlog drain;
8. JetStream redelivery;
9. database latency degradation;
10. 100k then distributed 300k connections.

Do not jump directly to 300k. Establish the saturation curve and bottleneck at each stage.

## Architectural invariants Codex must preserve

- PostgreSQL commit is the canonical acceptance boundary.
- Message row + conversation sequence + outbox row are atomic.
- A duplicate idempotency key resolves to the original canonical message/sequence or fails as a conflict if immutable command data differs.
- No durable consumer per user/device/conversation.
- Core NATS is online/transient delivery; offline recovery is DB sequence/cursor based.
- Client sender identity comes from authenticated context, never message body.
- Large media bytes stay outside NATS.
- DLQ write succeeds before poison source message is terminated.
- Per-connection outbound queues are bounded.
- 100k/300k are targets until reproducibly measured.

## Optimization priorities after correctness

Prefer evidence-driven optimization in this order:

1. allocations/copies in JSON/delivery codecs;
2. contention in connection/rate-limit registries;
3. PostgreSQL sequence hot rows and index/write amplification;
4. outbox claim batch sizing and lease duration;
5. JetStream batch/fetch/ack tuning;
6. Gateway socket write queues and TLS overhead;
7. group fan-out locality;
8. metrics cardinality and logging overhead.

Never trade correctness of idempotency, authorization, ordering or recovery semantics for a microbenchmark win.
