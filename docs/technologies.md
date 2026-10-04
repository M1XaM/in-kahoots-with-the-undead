# Technologies & Communication Patterns

## Language split

| Language | Stack | Used for services that are... |
|---|---|---|
| **Go** | Gin, GORM, PostgreSQL | CRUD-heavy, relational, transactional — "system of record" |
| **TypeScript** | Node.js, NestJS, Socket.IO | Real-time, event-driven, I/O-bound — "live gameplay" |
| **Python** | FastAPI, httpx, PyJWT | The API Gateway only — the lab's "banned" language, kept out of the services |

## Per-service breakdown

| # | Service | Stack | Communication | Why |
|---|---|---|---|---|
| 1 | **Player** | Go / Gin | REST + Kafka (`player.leveled_up`) | Identity/inventory needs strong consistency; GORM transactions cover atomic trades. |
| 2 | **Game** | TS / NestJS | WebSockets (Socket.IO) + REST/events | Live progress updates and many concurrent timers — Node's event loop and NestJS gateways fit natively. |
| 3 | **Exam** | TS / NestJS | REST (sync) + publishes `exam.completed` (service events, WebSocket) | Simple CRUD/validation; the result is written to an outbox in the grading transaction and streamed async, so World isn't blocked. |
| 4 | **World** | TS / NestJS | REST (sync) + consumes `exam.completed`, publishes `world.wing_unlocked` (service events, WebSocket) | Relational map data queried every cycle by Game, plus an event consumer and producer next to the REST controllers. |
| 5 | **Zombie** | Go / Gin | REST (sync) | Low-write config/definition store — plain cacheable REST is enough. |
| 6 | **Resource** | TS / NestJS | Kafka (gather/consume completion) + REST (balance) | Async, reconnect-prone completions need idempotent event handling — NestJS's queue/event tooling covers this natively. |
| 7 | **Base** | Go / Gin | REST + calls Resource (reserve/commit) | Spend-then-build; reservation on Resource makes the spend reversible if the local write fails. |
| 0 | **Gateway** | Python / FastAPI | REST in, REST out (async httpx pool) + WebSocket negotiation | Thin, I/O-bound proxy: an async framework handles many concurrent upstream calls on one event loop, and authorization, task timeout and the concurrent task limit live in one place instead of in every client. |
| 8 | **Crafting** | Go / Gin | REST + calls Resource (reserve/commit), Player (deliver) | Multi-step workflow across services; reserve → deliver → commit, release on failure. |

## Trade-offs

- **Go:** explicit transactions and error handling keep atomic operations (trades, crafting, spends)
  easy to reason about, at the cost of more manual wiring than a batteries-included framework.
- **NestJS:** built-in WebSocket/event scaffolding matches the traffic shape of Game and Resource
  (many timers, many async completions) better than hand-rolling the same in Go. Exam and World use
  it too: DTO validation and dependency injection keep their REST surface small, and their event
  producer/consumer live as providers next to the controllers.

## Communication conventions

- **REST (sync)** — caller needs an immediate answer (e.g. Game → World for rooms). Every REST
  call, from clients and between services, goes through the Gateway.
- **Kafka (async)** — producer shouldn't block on the reaction (e.g. `exam.completed`, resource
  completions); consumers dedupe on `eventId`.
- **WebSockets** — client-facing live push (Game Service sessions) and the services' `/events`
  streams. The Gateway only negotiates the URL (`GET /ws/{service}`); the socket connects
  directly to the service.
