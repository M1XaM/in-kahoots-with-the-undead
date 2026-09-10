# Technologies & Communication Patterns

## Language split

| Language | Stack | Used for services that are... |
|---|---|---|
| **Go** | Gin, GORM, PostgreSQL | CRUD-heavy, relational, transactional — "system of record" |
| **TypeScript** | Node.js, NestJS, Socket.IO | Real-time, event-driven, I/O-bound — "live gameplay" |

## Per-service breakdown

| # | Service | Stack | Communication | Why |
|---|---|---|---|---|
| 1 | **Player** | Go / Gin | REST + Kafka (`player.leveled_up`) | Identity/inventory needs strong consistency; GORM transactions cover atomic trades. |
| 2 | **Game** | TS / NestJS | WebSockets (Socket.IO) + REST/events | Live progress updates and many concurrent timers — Node's event loop and NestJS gateways fit natively. |
| 3 | **Exam** | Go / Gin | REST (sync) + Kafka (`exam.completed`) | Simple CRUD/validation, fast and light. Event published async so World isn't blocked. |
| 4 | **World** | Go / Gin | REST (sync) + consumes `exam.completed` | Relational map data, queried every cycle by Game — low per-request overhead matters. |
| 5 | **Zombie** | Go / Gin | REST (sync) | Low-write config/definition store — plain cacheable REST is enough. |
| 6 | **Resource** | TS / NestJS | Kafka (gather/consume completion) + REST (balance) | Async, reconnect-prone completions need idempotent event handling — NestJS's queue/event tooling covers this natively. |
| 7 | **Base** | Go / Gin | REST + calls Resource (reserve/commit) | Spend-then-build; reservation on Resource makes the spend reversible if the local write fails. |
| 8 | **Crafting** | Go / Gin | REST + calls Resource (reserve/commit), Player (deliver) | Multi-step workflow across services; reserve → deliver → commit, release on failure. |

## Trade-offs

- **Go:** explicit transactions and error handling keep atomic operations (trades, crafting, spends)
  easy to reason about, at the cost of more manual wiring than a batteries-included framework.
- **NestJS:** built-in WebSocket/event scaffolding matches the traffic shape of Game and Resource
  (many timers, many async completions) better than hand-rolling the same in Go.

## Communication conventions

- **REST (sync)** — caller needs an immediate answer (e.g. Game → World for rooms).
- **Kafka (async)** — producer shouldn't block on the reaction (e.g. `exam.completed`, resource
  completions); consumers dedupe on `eventId`.
- **WebSockets** — client-facing live push only (Game Service sessions), never service-to-service.
