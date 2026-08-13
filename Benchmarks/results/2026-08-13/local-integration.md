# Local PostgreSQL/NATS integration and failover result

Date: 2026-08-13

Decision: **PASS for the scenarios listed below**

Capacity claim: **none**

## Tested source

- `dext_nats_messenger`: `347a62375d939ce676c47440909d50ee60185587`
- `dext_nats`: `3d04a71083b0e10e3a3a7edc3bd78e89393ced5b`
- Dext compatibility worktree: `412ed29207d2d1dc5d4a259a7739a615aed0c626`

## Host and topology

- OS: Microsoft Windows 10 Pro 10.0.19045, 64-bit
- CPU: Intel Core i9-9880H, 8 cores / 16 logical processors
- RAM: 17,068,896,256 bytes (approximately 15.9 GiB visible)
- Delphi 12 Win64 compiler: 36.0
- Delphi 13 Win64 compiler: 37.0
- PostgreSQL: 18.2, isolated temporary cluster on `127.0.0.1:55432`
- NATS Server: 2.14.5, three local processes
- NATS client ports: 4522, 4523, 4524
- NATS route ports: 6522, 6523, 6524
- NATS monitoring ports: 8522, 8523, 8524
- JetStream accepted and DLQ streams: file storage, three replicas
- TLS: disabled for this local functional run

The gate created new temporary PostgreSQL and NATS data directories and stopped
only the exact processes it started. Existing services on ports 5432 and
4222-4224 were not used or modified.

## Commands

```powershell
./scripts/integration-gate.ps1

cd Benchmarks/loadgen
go test ./...
go vet ./...
go build ./...
```

The Dext.Testing console suite was also compiled and executed separately with
the Delphi 12 and Delphi 13 Win32 compilers against the same pinned Dext source.

## Results

| Gate | Delphi 12 | Delphi 13 |
|---|---:|---:|
| Dext.Testing contract/unit suite | 17 passed, 0 failed | 17 passed, 0 failed |
| Win64 integration assertions | 48 passed, 0 failed | 48 passed, 0 failed |
| PostgreSQL schema application | passed | passed |
| PostgreSQL transaction rollback after failed insert | passed | passed |
| PostgreSQL unavailable/fail-closed behavior | passed | passed |
| Outbox lease exclusion and reclaim after worker loss | passed | passed |
| NATS Core publish/subscribe | passed | passed |
| JetStream three-replica topology | passed | passed |
| JetStream publish deduplication | passed | passed |
| Pull fetch, headers, decode and ACK | passed | passed |
| Replay from a consumer created after publication | passed | passed |
| Poison event copied to durable DLQ before TERM | passed | passed |
| DLQ outage causes NAK and source redelivery | passed | passed |
| Connected NATS node termination | passed | passed |
| Automatic reconnect and resubscribe | passed | passed |
| JetStream leader election and availability with one node down | passed | passed |

The Go load-generator package passed `go test`, `go vet`, and `go build`.
The full `dext_nats` Win32 suite also passed 290/290 tests on both Delphi 12
and Delphi 13, including the live `Nak_ShouldRedeliver` integration test.

## Defects found and corrected

1. `Published` was used as a record field name and failed modern Win64 Delphi
   parsing. It is now `PublishedCount`.
2. The PostgreSQL unit exposed `TMessengerMessageKind` in its interface without
   importing `Dext.Messenger.Models` there.
3. Two record methods named `Default` shadowed Delphi's `Default(...)`
   intrinsic. They now call `System.Default(...)` explicitly.
4. The old outbox batch claim performed one select plus one update command per
   claimed row while the reader remained open. It now uses one atomic
   `WITH candidates ... UPDATE ... RETURNING` command.
5. `dext_nats` emitted `+NAK`, which is not a valid JetStream negative
   acknowledgement. The server kept the message ack-pending until `AckWait`
   expired. The wire payload and its contract test now use `-NAK`; the live
   DLQ-outage test confirms delayed redelivery on a three-node cluster.

For an outbox batch of `N` rows, the claim phase therefore changes from
`1 + N` database commands to one database command. With the default batch size
of 100 this removes 100 per-row update round trips (101 commands down to 1).
This is a structural round-trip reduction; this run did not publish a timing or
messages-per-second claim.

## Remaining validation

- full Gateway/VCL end-to-end execution;
- PostgreSQL slow-storage injection;
- delivery-worker process crash recovery beyond the validated outbox lease reclaim;
- Gateway rolling restart and reconnect storm;
- direct, group-fanout, 100k and distributed 300k load tests;
- CPU/allocation/lock/queue/network/storage profiling with p95/p99 latency.

Those scenarios must be measured before any production capacity statement.
