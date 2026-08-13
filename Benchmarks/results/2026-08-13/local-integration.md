# Local PostgreSQL/NATS integration and failover result

Date: 2026-08-13

Decision: **PASS for the scenarios listed below**

Capacity claim: **none**

## Tested source

- `dext_nats_messenger`: `072830e68d41e22e551aec414c61b8156f36761c`
- `dext_nats`: `ed6c27769904783308fdb0e85f5bbece959523c4`
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
| Win64 integration assertions | 27 passed, 0 failed | 27 passed, 0 failed |
| PostgreSQL schema application | passed | passed |
| NATS Core publish/subscribe | passed | passed |
| JetStream three-replica topology | passed | passed |
| JetStream publish deduplication | passed | passed |
| Pull fetch, headers, decode and ACK | passed | passed |
| Connected NATS node termination | passed | passed |
| Automatic reconnect and resubscribe | passed | passed |
| JetStream availability with one node down | passed | passed |

The Go load-generator package passed `go test`, `go vet`, and `go build`.

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

For an outbox batch of `N` rows, the claim phase therefore changes from
`1 + N` database commands to one database command. With the default batch size
of 100 this removes 100 per-row update round trips (101 commands down to 1).
This is a structural round-trip reduction; this run did not publish a timing or
messages-per-second claim.

## Remaining validation

- full Gateway/VCL end-to-end execution;
- JetStream replay, poison event and DLQ-unavailable behavior;
- PostgreSQL outage and slow-storage injection;
- outbox/delivery-worker crash recovery;
- Gateway rolling restart and reconnect storm;
- direct, group-fanout, 100k and distributed 300k load tests;
- CPU/allocation/lock/queue/network/storage profiling with p95/p99 latency.

Those scenarios must be measured before any production capacity statement.
