# Reliability / Failure Test Matrix

The architecture is considered production-ready only after these scenarios are executed against a realistic multi-node environment. The repository provides the code paths; execution results belong in dated benchmark reports.

| Scenario | Injection | Expected behavior | Pass criteria |
|---|---|---|---|
| Gateway process kill | terminate one gateway with active sockets | clients reconnect; no durable message loss | reconnect rate and recovery cursor within SLO |
| Gateway rolling restart | restart gateways sequentially | capacity remains available | no global outage, bounded reconnect storm |
| NATS node loss | stop one node of a 3-node cluster | Core NATS routes around failure; JetStream elects leader | no accepted DB message lost; outbox drains after recovery |
| JetStream unavailable | stop/partition JS quorum | DB acceptance still commits; outbox backlog grows | gateway acceptance follows configured degraded policy; backlog drains later |
| PostgreSQL unavailable | stop primary/network | new durable acceptance fails closed | no false `accepted` response and no partial message/outbox row |
| PostgreSQL slow | inject latency/IO pressure | gateway backpressure/rate limits protect system | bounded queues and stable memory |
| Outbox worker kill | terminate worker after DB claim | lease expires; another worker reclaims | event eventually published once logically |
| Delivery worker kill before ACK | terminate after fetch | JetStream redelivers | online duplicate remains tolerable/idempotent, no loss |
| Poison accepted event | corrupt header/payload | event copied to DLQ before TERM | diagnostic preserved; source event stops redelivery only after DLQ success |
| DLQ unavailable | block DLQ publish | poison message is NAKed, not silently TERM'd | no silent loss |
| Slow WebSocket consumer | stop reading client socket | bounded outbound queue rejects/disconnects | per-connection memory does not grow without bound |
| 100k reconnect storm | reconnect all clients in a short window | connection admission remains controlled | gateway CPU/RAM/network within limits; no cascading failure |
| Large group fanout | publish to large group | one logical event, local gateway fanout | no per-member JetStream consumer/message explosion |
| Duplicate client retry | same sender/client_message_id concurrently | one canonical DB message/sequence | every response resolves to the same canonical message ID/sequence |
| Multi-device receipt disorder | delayed read/delivered receipts | cursor remains monotonic | cursor never moves backward; read implies delivered |
| Media store unavailable | object store timeout | text messaging stays available; media flow fails separately | no broker payload inflation or stuck message worker |

## Evidence format

For every run store a report under `Benchmarks/results/YYYY-MM-DD/<scenario>.md` containing topology, exact commands, commit SHAs, graphs/metrics, observed errors, and pass/fail decision. Never overwrite previous reports.
