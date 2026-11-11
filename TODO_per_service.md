# Lab 4: what each service still has to do

The gateway, the broker, Discovery, Base and Crafting are done. Player, Game, Exam, World, Zombie
and Resource still work the Lab 3 way. This is what each of them has to provide for the whole system
to work through the broker. Full contract: [`docs/communication.md`](docs/communication.md).

## For every service

1. **Call other services through the broker**, not the gateway: `ANY http://broker:8091/call/{service}/{path}`
   (or `Broker.Call` over gRPC on `broker:8092`) with `X-Internal-Key`, `X-Request-Id` and, when
   acting for a player, `X-Player-Id`. Name the service, never an instance; no circuit breaker or
   load balancer of your own.
2. **Publish events to the broker**: `POST http://broker:8091/topics/{type}/events` with the standard
   envelope; mark the outbox row sent after the `202`. The `/events` WebSocket goes away.
3. **Consume events from the broker**: list the topics in the Discovery registration
   (`"topics": [...]`) and serve `POST /internal/events` at the root. `200` acks
   (`{"eventId", "status": "processed" | "duplicate" | "ignored"}`), a `4xx` refuses the event for
   good, a `5xx` has it retried. Deduplicate on `eventId`.
4. **Honour `X-Caller: client`**: the broker always sends its own `X-Internal-Key`, so a request
   carrying `X-Caller: client` came from a player through the gateway. Treat it as the player's:
   owner checks apply, internal-only routes answer `403`, even though the key is valid.
5. **gRPC**: serve `broker.v1.Endpoint` (`Handle` runs the request like the HTTP API, `Deliver` like
   `POST /internal/events`) on a port of its own and register it as `grpc_url`. The contract is
   `proto/broker/v1/broker.proto` in the broker repository.
6. **`GET /metrics`** in the Prometheus format (public, outside the task limits), and a scrape job in
   `monitoring/prometheus/prometheus.yml`.
7. **`GET /internal/logs`**, so the gateway's `GET /logs` includes the service:
   - every line written to stdout is also kept, as is, in memory: the last `LOG_BUFFER_LINES` (default 5000);
   - served at the root `/internal/logs` (not under the service prefix), outside the task limits,
     its own request logged only at `DEBUG`;
   - `X-Internal-Key` required (`401` without), `403` with `X-Caller: client`;
   - query, all optional: `since` / `until` (RFC 3339, inclusive), `level` (minimum: `debug`, `info`,
     `warn`, `error`), `request_id`, `limit` (default 1000, max 5000, the newest lines are kept);
     a bad value is `400 VALIDATION_ERROR`;
   - answer `200`, `Content-Type: application/x-ndjson`, the matching lines oldest first, one per
     line exactly as logged, with `X-Log-Oldest` (time of the oldest line kept) and `X-Log-Buffered`
     (lines kept).

   Done when the gateway's `GET /logs` lists every instance of the service in `X-Logs-Sources`
   instead of `X-Logs-Missing`.

When every service is done, the gateway's `LEGACY_SERVICE_ROUTES` goes back to `false`.

## Per service

### Player

- [ ] publish `player.registered` and `player.leveled_up` (Base, Resource and Crafting wait for them on the broker)
- [ ] consume `game.presence_changed`
- [ ] `X-Caller`, gRPC `Endpoint`, `/metrics`, `/internal/logs` (it answers that path with an empty `200` today)

### Game

- [ ] call World, Zombie, Exam, Player, Resource and Base through the broker
- [ ] publish `game.action_completed` and `game.presence_changed`
- [ ] consume `resource.gathered`, `exam.completed` and `world.wing_unlocked`
- [ ] `X-Caller`, gRPC `Endpoint`, `/metrics`, `/internal/logs` (it answers that path with an empty `200` today)

### Exam

- [ ] call Zombie and Player through the broker
- [ ] publish `exam.completed` (World, Game and Crafting wait for it on the broker)
- [ ] `X-Caller`, gRPC `Endpoint`, `/metrics`, `/internal/logs`

### World

- [ ] publish `world.wing_unlocked`
- [ ] consume `exam.completed` (`EXAM_EVENTS_URL` goes away)
- [ ] `X-Caller`, gRPC `Endpoint`, `/metrics`, `/internal/logs`

### Zombie

- [ ] `X-Caller` (Game and Exam call it through the broker), gRPC `Endpoint`, `/metrics`, `/internal/logs`

### Resource

- [ ] call World through the broker (`WORLD_SERVICE_URL` goes away)
- [ ] publish `resource.gathered`
- [ ] consume `player.registered` and `game.action_completed` (`PLAYER_EVENTS_URL`, `GAME_EVENTS_URL` go away)
- [ ] `X-Caller`, gRPC `Endpoint`, `/metrics`, `/internal/logs`
