# Lab 4 – Breaking and Brokering: what is implemented, how and where

Every requirement of the Lab 4 grading table, with the repository, branch or PR, and the files that
implement it. The `/internal/logs` and `/metrics` endpoints the other team services still have to
add are described in [`TODO_per_service.md`](TODO_per_service.md).

**Where the code is**

| Repository | Where | State |
|---|---|---|
| [CamusMessageBroker](https://github.com/TimurCravtov/CamusMessageBroker) (broker, Dart) | `dev`, plus PR [#115](https://github.com/TimurCravtov/CamusMessageBroker/pull/115) | open PR into `dev` |
| [KahootWithUndeadGateway](https://github.com/TimurCravtov/KahootWithUndeadGateway) (gateway, Python) | PR [#16](https://github.com/TimurCravtov/KahootWithUndeadGateway/pull/16) `feature/broker-routing` | open PR into `dev` |
| [KahootWithUndeadDiscovery](https://github.com/inercaso/KahootWithUndeadDiscovery) (Python) | PR [#5](https://github.com/inercaso/KahootWithUndeadDiscovery/pull/5) `feature/topics-grpc-logs-metrics` | open PR into `dev` |
| [kahoots-base-service](https://github.com/M1XaM/kahoots-base-service), [kahoots-crafting-service](https://github.com/M1XaM/kahoots-crafting-service) (Go) | `main`, tag `lab4` | released: `mixam052/kahoots-base-service:4`, `mixam052/kahoots-crafting-service:4` |
| this repository (compose, monitoring, docs, Postman) | PR [#74](https://github.com/M1XaM/in-kahoots-with-the-undead/pull/74) `feature/broker-monitoring` | open PR into `dev` |

---

## Grade 2

| Requirement | How | Where |
|---|---|---|
| Message Broker in a language not used before | Camus Message Broker in **Dart** (gateway and Discovery are Python, services Go and NestJS). HTTP on 8091, gRPC on 8092, registers with Discovery like a service. | CamusMessageBroker `bin/broker.dart`, `lib/src/` (domain / application / infrastructure / presentation); [`docs/architecture.md`](https://github.com/TimurCravtov/CamusMessageBroker/blob/dev/docs/architecture.md) |
| GitHub repository and workflow like the gateway and Discovery | Feature branches into `dev`, Conventional Commits; CI: tests with an 80% line coverage gate, proto-vs-generated-code check, commit message check, PR title check, auto draft PR, lab release to Docker Hub on a `lab*` tag. | CamusMessageBroker `.github/workflows/` (`test.yml`, `commit-message-check.yml`, `pr-title-check.yml`, `auto-draft-pr.yml`, `lab-release.yml`), `.github/pull_request_template.md` |

## Grade 3

| Requirement | How | Where |
|---|---|---|
| README and architecture diagram show the new component | The README describes the broker (role, request and event contracts, gRPC, endpoints, configuration) and every service's Lab 4 status; the diagram has the broker with its four parts, every path through it, topics per service, Discovery with `topics` / `grpc_url`, and the monitoring stack. | [`README.md`](README.md) (Architecture, Message Broker, Gateway, Base, Crafting, Monitoring, Logs), [`docs/architecture.drawio`](docs/architecture.drawio) → [`docs/architecture.png`](docs/architecture.png), [`docs/communication.md`](docs/communication.md) rewritten for the broker (Gateway, Message broker, Authentication, Scaling, Operations) |
| Postman collections up to date | Broker collection (requests, topics, dead letters; `/call` paths fixed to `/call/{service}/{original path}`), a new **Operations** collection (`GET /logs` and its filters, every `/internal/logs`, every `/metrics`, Prometheus, Grafana, Discovery `topics` / `grpc_url`), and all of them in the All Services collection. All 40 requests of the broker and Operations collections run green against the compose stack with Newman. | [`docs/postman/broker`](docs/postman/broker), [`docs/postman/operations`](docs/postman/operations), [`docs/postman/all-services`](docs/postman/all-services) (folders Broker, Operations) |

## Grade 4

| Requirement | How | Where |
|---|---|---|
| Endpoint to download logs from the system | **`GET /logs` on the gateway** (`X-Internal-Key`). No extra container: every instance keeps its last `LOG_BUFFER_LINES` (5000) log lines in memory and serves them on **`GET /internal/logs`** (NDJSON, `since` / `until` / `level` / `request_id` / `limit`). The gateway asks every instance Discovery lists, Discovery itself and its own buffer in parallel, merges the lines by time and returns the newest `limit` (max 10000) as an `.ndjson` attachment. `since` / `until` take RFC 3339 or durations (`15m`); `service` / `instance` choose the sources; `request_id` follows one request through every service. `X-Logs-Sources` / `X-Logs-Missing` say who answered. | Gateway (#16): `app/routers/logs.py`, `app/logbuffer.py`, `app/logs.py`. `/internal/logs` in the broker (#115) `lib/src/shared/logging/log_buffer.dart`, `lib/src/presentation/http/handlers/logs_handler.dart`; Discovery (#5) `app/logbuffer.py`, `app/routers/internal.py`; Base and Crafting (`main`) `internal/logging/buffer.go`, `internal/handlers/logs_handler.go`. Contract: [`docs/communication.md`](docs/communication.md#log-collection-get-internallogs-and-get-logs). Other services: [`TODO_per_service.md`](TODO_per_service.md) |

## Grade 5

| Requirement | How | Where |
|---|---|---|
| Message Broker dockerized and published | Multi-stage Dockerfile: native executable on `scratch`, non-root, under 50 MB. The lab release workflow publishes `timurcravtov/broker:<lab>`; compose runs it with the `broker-data` volume. Fixed in #115: the image now ships `/data` owned by its user (with `STORAGE=log` the root-owned volume made it crash in a restart loop). | CamusMessageBroker `Dockerfile`, `.github/workflows/lab-release.yml`; [`docker-compose.yml`](docker-compose.yml) service `broker` |
| Service-to-service communication through the broker | Base and Crafting call Resource, World and Player only through the broker (`Broker.Call` over gRPC, or `/call/{service}/...`), naming the service, never an instance. The gateway sends every client request through it too. | Base / Crafting `internal/broker/broker.go` (transports), `internal/clients/caller.go`; gateway (#16) `app/broker.py`, `app/proxy.py`; compose `BROKER_*` settings |
| Load balancing and circuit breakers moved from the gateway to the broker | The broker balances (round-robin or least load) and keeps a breaker per instance (3 failures within `TASK_TIMEOUT_MS` × 3.5, reported to Discovery). The gateway's `breaker.py` and round-robin `Directory` are deleted (#16); Base and Crafting dropped their own breakers. | CamusMessageBroker `lib/src/application/load_balancing/load_balancer.dart`, `lib/src/application/resilience/circuit_breaker.dart`; gateway #16 (removed `app/breaker.py`, `Directory` in `app/discovery.py`) |

## Grade 6

| Requirement | How | Where |
|---|---|---|
| Subscriber-based queues, gateway to service | One bounded FIFO per target service in the broker; a call leaves it when an instance has room; `429` when full, `504` when its deadline passes while queued. The gateway names the service. | CamusMessageBroker `lib/src/application/calls/request_dispatcher.dart`, `forward_call.dart`; gateway #16 `app/proxy.py` |
| Topic-based queues, service to service | A producer publishes `POST /topics/{topic}/events` without knowing the consumers; the broker keeps one durable queue per (topic, subscriber service) and delivers to one instance of each, at least once, in order per queue. Base consumes `player.registered`; Crafting consumes `player.leveled_up`, `exam.completed`, `world.wing_unlocked`, both at `POST /internal/events` or `Endpoint.Deliver`. | CamusMessageBroker `lib/src/application/events/event_broker.dart`, `delivery_queue.dart`, `forwarding_deliverer.dart`; Base / Crafting `internal/handlers/event_handler.go`, `internal/broker/endpoint.go` |
| Registration with Discovery includes the topics | Instances register `"topics": [...]` (and `"grpc_url"`); Discovery stores and lists them (before #5 they were silently dropped); the broker builds subscriptions from them. | Discovery #5 `app/registry.py`, `app/routers/registry.py`; Base / Crafting `internal/discovery/discovery.go`, `cmd/server/main.go`; broker `lib/src/application/discovery/instance_cache.dart` |

## Grade 7

| Requirement | How | Where |
|---|---|---|
| Thread-per-request in the broker | `CONCURRENCY_MODEL=isolate_per_request` (default): every upstream call and every delivery attempt runs on its own Dart isolate (thread) with its own HTTP client; queues, breakers and counters stay on the main isolate. Benchmarked against `inline` in the README. | CamusMessageBroker `lib/src/infrastructure/concurrency/isolate_executor.dart`, `lib/src/application/execution/executor.dart`, `tool/bench_executors.dart` |
| Endpoint listing the topics | `GET /topics`: every topic with producers seen, subscribers, queue depth, in flight, delivered and dead-lettered totals. | CamusMessageBroker `lib/src/presentation/http/handlers/event_handlers.dart` |

## Grade 8

| Requirement | How | Where |
|---|---|---|
| Service-to-service communication over gRPC | One contract, `broker.v1`: `Broker.Call` / `Broker.Publish` served by the broker, `Endpoint.Handle` / `Endpoint.Deliver` served by the services. Base and Crafting call the broker over gRPC and are called back over gRPC (they register a `grpc_url`; `Handle` runs the request through the service's own router, so auth, limits and idempotency are the same as HTTP). The gateway calls the broker over gRPC too. | CamusMessageBroker `proto/broker/v1/broker.proto`, `lib/src/presentation/grpc/`, `lib/src/infrastructure/grpc/grpc_upstream.dart`; Base / Crafting `proto/`, `internal/broker/` (generated `brokerpb`, `broker.go`, `endpoint.go`); gateway #16 `app/broker.py`, `app/brokerpb/` |
| Remove the routes users must not reach from the gateway | The gateway serves only client routes: `/<prefix>/internal/...` and the event stream negotiation `GET /ws/{producer}` answer `404`. `LEGACY_SERVICE_ROUTES=true` (the compose default until every service uses the broker) lets callers with the key reach them again, never clients. Since the broker sends its own key on every call, the gateway marks requests from outside with **`X-Caller: client`** and the broker forwards it (#115), so services still apply owner checks and refuse internal routes to players. | Gateway #16 `app/routers/proxy.py`, `app/routers/ws.py`, `app/config.py`; broker #115 `lib/src/application/calls/outgoing_headers.dart`; Base / Crafting `internal/middleware/auth.go` |

## Grade 9

| Requirement | How | Where |
|---|---|---|
| Reliable delivery through durable queues | `STORAGE=log` (compose default): every event is appended to `events.log` and fsynced before the `202`; acks and dead letters are journaled; queues and dead letters are rebuilt on restart; a repeated `eventId` within 24 h is not enqueued again. Fixed in #115: a subscriber whose instances are all stopped keeps its subscriptions (journaled as `sub` lines, so a restart keeps them) and its events wait in its queue without using up attempts, instead of being dead-lettered. | CamusMessageBroker `lib/src/infrastructure/storage/log_journal.dart`, `lib/src/application/events/event_broker.dart`, `delivery_queue.dart`; compose `BROKER_STORAGE=log`, volume `broker-data` |
| Dead letter channel | A `4xx` refusal (other than 408/429), more than `MAX_DELIVERY_ATTEMPTS` (5) failed attempts, or a topic with no subscriber move the event to the dead letter channel with the reason and the last attempt. | CamusMessageBroker `lib/src/domain/dead_letter.dart`, `event_broker.dart` |
| Endpoint listing the dead letters | `GET /dead-letters?topic=&subscriber=&reason=&limit=&after=`, newest first, with a cursor. | CamusMessageBroker `lib/src/presentation/http/handlers/event_handlers.dart` |

## Grade 10

| Requirement | How | Where |
|---|---|---|
| High availability: after a breaker trips on an instance, reroute to another | A failed call goes to the next healthy instance within its deadline when repeating it cannot write twice (connection failed before sending, `GET`/`HEAD`/`OPTIONS`, or an `Idempotency-Key`); a tripped instance is skipped and reported to Discovery. | CamusMessageBroker `lib/src/application/calls/forward_call.dart`, `routing_upstream.dart`, `circuit_breaker.dart` |
| Load balancing by service load | `LB_STRATEGY=least_load` (now the compose default): the instance with the lowest `(broker in-flight + active_tasks reported to Discovery) / max_concurrent_tasks`. | CamusMessageBroker `lib/src/application/load_balancing/load_balancer.dart`; [`docker-compose.yml`](docker-compose.yml) `BROKER_LB_STRATEGY` |
| Grafana + Prometheus, meaningful data and logs | Prometheus scrapes every 5 s the gateway, Discovery, the broker and every Base and Crafting replica (DNS service discovery). Grafana is provisioned with the data source and the **Kahoot With Undead** dashboard (28 panels in 6 rows): calls/s, failed calls, open breakers, unhealthy instances, dead letters, broker load; calls by service and outcome, latency, queues, reroutes, 429s; instance load and health; events published / delivered / dead-lettered and queue depth; Base and Crafting requests, events consumed, calls out; gateway traffic by service; Discovery's registry and topic subscribers. Logs: `GET /logs` (grade 4). | [`monitoring/prometheus/prometheus.yml`](monitoring/prometheus/prometheus.yml), [`monitoring/grafana/`](monitoring/grafana) (data source, dashboard JSON), compose services `prometheus` (:9090) and `grafana` (:3001); `/metrics` in the gateway (#16) `app/metrics.py`, Discovery (#5) `app/metrics.py`, Base / Crafting `internal/metrics/metrics.go`, broker `lib/src/shared/metrics/metrics.dart` |

---

## How it was tested

**Unit tests** (all passing): broker 320 tests, line coverage 94.9%; gateway 106 tests, 93%;
Discovery 76 tests, 90%; Base and Crafting `go test ./...` (buffer, logs endpoint, broker transports,
gRPC endpoint, `X-Caller` auth, Discovery registration).

**End to end**, the whole compose of this branch (every service, Base and Crafting with 2 replicas)
with local builds of the broker (#115), Discovery (#5), the gateway (#16), Base and Crafting; the
other services from their `:3` images. 31 checks, all passing:

- Discovery lists both Base instances with `grpc_url` and `player.registered`, Crafting with its three topics; `GET /topics` shows the subscriptions
- register and log in through gateway → broker (gRPC) → Player, cookie set; JWKS fetched through the broker
- `player.registered` published to the broker → delivered to Base over gRPC → the player's base exists
- a player reads their own base (`200`), not another player's (`403`), cannot list every base (`403`), `/base/internal/...` is `404`, no token is `401`
- Base → broker (gRPC) → Resource spends resources; Crafting → broker → Player for availability and → Resource for a reservation
- `exam.completed` published twice with one `eventId` → Crafting processes it once
- an invalid `player.registered` is refused by Base and dead-lettered (`rejected`)
- 20 requests spread 10/10 over the two Base replicas (least load)
- `GET /logs` merges the gateway, broker, Discovery, both Base and both Crafting replicas, sorted by time, as an NDJSON attachment; the services without `/internal/logs` are listed as missing; one `request_id` is traced through gateway, broker and Base; without the key it is `404`
- Lab 3 services still get event stream URLs (`LEGACY_SERVICE_ROUTES=true`)
- every Prometheus target is up, Prometheus has gateway traffic, Grafana has the dashboard
- a Base replica stopped gracefully: every read still `200`; a Base replica killed: its breaker trips and every later read is rerouted (`200`)
- an event published while Crafting was stopped, then a broker restart: delivered when Crafting came back

**Postman**: the broker and Operations collections (40 requests) run against the stack with Newman.

---

## Releasing it

1. Merge the PRs into `dev`: broker #115, Discovery #5, gateway #16, this repository #74.
2. Release the broker: merge `dev` into `main` and move its `lab4` tag (it points at the first
   commit, `bc11e77`), so `timurcravtov/broker:4` is this code.
3. Release Discovery (version `4.0.0` publishes `:4`) and the gateway (`lab4` tag publishes `:4`),
   then set `DISCOVERY_SERVICE_TAG=4` and `GATEWAY_SERVICE_TAG=4` in `docker-compose.yml`
   (still `3`, the only images published today).
4. Once the other services call each other and publish their events through the broker, turn
   `GATEWAY_LEGACY_SERVICE_ROUTES` off.

## Known limits

- Player, Game, Exam, World, Zombie and Resource still publish on their Lab 3 `/events` WebSockets
  and call each other through the gateway; Base and Crafting take events only from broker topics, so
  until the producers publish to the broker, Base and Crafting do not receive their events (the
  end-to-end test published them to the broker directly). They also do not serve `/internal/logs`
  or `/metrics` yet ([`TODO_per_service.md`](TODO_per_service.md)) and do not honour `X-Caller`.
- A replica that disappears without closing its connections (a hard kill) costs a few `504`s until
  its breaker trips (3 failures); a graceful stop costs none.
- Over gRPC, `CallResponse.headers` is a map, so a response carries one value per header name (two
  `Set-Cookie` lines cannot both pass). Player sets a single cookie, so login works;
  `GATEWAY_BROKER_TRANSPORT=http` avoids it if a service ever needs more.
