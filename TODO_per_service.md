# Lab 4: what each service still has to do

The gateway's `GET /logs` downloads the logs of the whole system in one file. It works without any
extra container: **every instance keeps its recent log lines in memory and serves them on
`GET /internal/logs`**, and the gateway asks every instance Service Discovery lists, merges the
lines by time and returns them. The gateway, the broker, Discovery, Base and Crafting already serve
it. Player, Game, Exam, World, Zombie and Resource do not yet: `GET /logs` currently lists them in
`X-Logs-Missing` (`404`, or `not_ndjson` for a service that answers the path with something else).

Part 1 is the endpoint, the same for everyone. Part 2 is a ready-to-copy implementation per stack.
Part 3 lists, per service, what else is still open for Lab 4 (the broker migration).

---

## 1. The contract of `GET /internal/logs`

Also in [`docs/communication.md`](docs/communication.md#log-collection-get-internallogs-and-get-logs).

**Keep the lines.** Every line your logger writes to stdout (the shared JSON format: `time`,
`level`, `service`, `instance`, `msg`, `request_id`, …) is also kept, as the same text, in an
in-memory buffer of the last `LOG_BUFFER_LINES` lines (default `5000`; oldest dropped first). Only
the lines that were actually written (at `LOG_LEVEL` or above). Nothing is stored on disk; the buffer
starts empty when the instance starts.

**Serve them.**

```
GET /internal/logs?since=&until=&level=&request_id=&limit=
```

| | Rule |
|---|---|
| Path | `/internal/logs` at the root, **not** under your prefix (`/exams/internal/logs` is wrong): the gateway calls `http://<instance url>/internal/logs`, with the `url` the instance registered with Discovery. With a NestJS global prefix, exclude it. |
| Auth | `X-Internal-Key` must equal `INTERNAL_KEY`, else `401 UNAUTHENTICATED`. A request with `X-Caller: client` gets `403 FORBIDDEN` (it came from a player through the gateway). |
| Limits | Outside the task timeout and concurrent task limit, like `/health` and `/status`, so a saturated instance can still be read. |
| Request log | Log its `request finished` line at `DEBUG` only (it is polled), like `/health`, `/status` and `/metrics`. |
| `since`, `until` | RFC 3339 (`2026-11-11T10:00:00Z`), inclusive, optional. Compare against each line's `time`. Normalised to the log format (`2026-11-11T10:00:00.000Z`), the strings compare like the times. |
| `level` | Minimum level, optional: `debug` (default, everything), `info`, `warn`, `error`. `WARNING` counts as `WARN`. |
| `request_id` | Optional: only the lines whose `request_id` equals it. |
| `limit` | Optional, default `1000`, max `5000` (larger values are capped): keep the **newest** matching lines. |
| Bad query | `400 VALIDATION_ERROR` in the shared error body (a time that does not parse, an unknown level, a `limit` that is not a positive integer). |
| Answer | `200`, `Content-Type: application/x-ndjson`, the matching lines **oldest first**, one per line, **exactly as written to stdout**, each ending with `\n`. An empty body when nothing matches. |
| Headers | `X-Log-Oldest`: the `time` of the oldest line still kept (empty if none). `X-Log-Buffered`: how many lines are kept. |

The gateway only counts an answer that is `200` with `Content-Type: application/x-ndjson`.

**Check it.**

```
# straight to one instance, inside the compose network
docker compose exec gateway python -c "import urllib.request as u; r=u.urlopen(u.Request('http://exam:8083/internal/logs?limit=5', headers={'X-Internal-Key':'changeme'})); print(r.headers['Content-Type'], r.headers['X-Log-Buffered']); print(r.read().decode())"

# through the gateway: your instances move from X-Logs-Missing to X-Logs-Sources
curl -s -D - -o /dev/null -H 'X-Internal-Key: changeme' 'localhost:8080/logs?service=exam'
curl -s -H 'X-Internal-Key: changeme' 'localhost:8080/logs?service=exam&level=warn&since=1h'
```

The Postman collection [`docs/postman/operations`](docs/postman/operations) has the same requests.

Acceptance:
- [ ] `GET /internal/logs` with the key → `200`, `application/x-ndjson`, your recent lines oldest first
- [ ] without the key → `401`; with `X-Caller: client` → `403`; `?limit=0` → `400`
- [ ] `?level=warn`, `?request_id=…`, `?since=…&until=…`, `?limit=…` filter as above
- [ ] the gateway's `GET /logs` lists every one of your instances in `X-Logs-Sources`
- [ ] polling it does not add `INFO` lines to your log

---

## 2. Implementations to copy

### Go (Player)

Copy from Base (`services/base-service`, same layout as Player):

- [`internal/logging/buffer.go`](services/base-service/internal/logging/buffer.go): the buffer, an
  `io.Writer` (the JSON handler writes one line per `Write`), with `Query` and `LevelRank`.
- [`internal/handlers/logs_handler.go`](services/base-service/internal/handlers/logs_handler.go): the
  Gin handler (query parsing, `400`s, headers, NDJSON).
- Tests: `internal/logging/buffer_test.go`, `internal/handlers/logs_handler_test.go`.

Wiring (Base's `cmd/server/main.go`):

```go
recentLogs := logging.NewBuffer(cfg.LogBufferLines)          // LOG_BUFFER_LINES, default 5000
logging.Setup(cfg.LogLevel, cfg.ServiceName, cfg.InstanceID, recentLogs)
// Setup writes to io.MultiWriter(os.Stdout, recentLogs)

// on the root router, outside the task limits, with your internal-key auth
handlers.NewLogsHandler(recentLogs).Register(r, cfg.InternalKey)
```

and in the request-log middleware: `quietPaths["/internal/logs"] = true` (logged at `DEBUG`).
Player already answers `/internal/logs` with an empty `200` from a catch-all route: register the
real route before it.

### NestJS / TypeScript (Game, Exam, World, Zombie, Resource)

`src/logs/log-buffer.ts`:

```ts
const RANK: Record<string, number> = { debug: 0, info: 1, warn: 2, warning: 2, error: 3 };

export interface LogQuery {
  since?: string;      // normalised: 2026-11-11T10:00:00.000Z
  until?: string;
  minLevel: number;
  requestId?: string;
  limit: number;
}

interface Entry { time: string; level: number; requestId: string; line: string }

/** The last `capacity` lines this instance logged, for GET /internal/logs. */
export class LogBuffer {
  private readonly entries: Entry[] = [];
  private next = 0;

  constructor(private readonly capacity = Number(process.env.LOG_BUFFER_LINES ?? 5000)) {}

  add(line: string): void {
    let fields: Record<string, unknown> = {};
    try { fields = JSON.parse(line); } catch { /* kept as it is */ }
    const entry: Entry = {
      time: String(fields.time ?? ''),
      level: RANK[String(fields.level ?? '').toLowerCase()] ?? 0,
      requestId: String(fields.request_id ?? ''),
      line,
    };
    if (this.entries.length < this.capacity) this.entries.push(entry);
    else this.entries[this.next] = entry;
    this.next = (this.next + 1) % this.capacity;
  }

  get size(): number { return this.entries.length; }

  /** The newest lines matching q, oldest first, and the time of the oldest line kept. */
  query(q: LogQuery): { lines: string[]; oldest: string } {
    const ordered = this.entries.length < this.capacity
      ? this.entries
      : [...this.entries.slice(this.next), ...this.entries.slice(0, this.next)];
    const found: string[] = [];
    for (let i = ordered.length - 1; i >= 0 && found.length < q.limit; i--) {
      const e = ordered[i];
      if (q.since && e.time < q.since) continue;
      if (q.until && e.time > q.until) continue;
      if (e.level < q.minLevel) continue;
      if (q.requestId && e.requestId !== q.requestId) continue;
      found.push(e.line);
    }
    return { lines: found.reverse(), oldest: ordered[0]?.time ?? '' };
  }
}

export const recentLogs = new LogBuffer();

/** Reads the query parameters; throws Error(message) for a 400. */
export function parseLogQuery(p: Record<string, string | undefined>): LogQuery {
  const time = (name: string) => {
    const raw = p[name];
    if (!raw) return undefined;
    const at = new Date(raw);
    if (Number.isNaN(at.getTime())) throw new Error(`${name} must be an RFC 3339 time`);
    return at.toISOString();                       // 2026-11-11T10:00:00.000Z
  };
  const level = (p.level ?? '').toLowerCase();
  if (level && !(level in RANK)) throw new Error('level must be debug, info, warn or error');
  let limit = 1000;
  if (p.limit) {
    limit = Number(p.limit);
    if (!Number.isInteger(limit) || limit < 1) throw new Error('limit must be a positive integer');
  }
  return { since: time('since'), until: time('until'), minLevel: RANK[level] ?? 0,
           requestId: p.request_id || undefined, limit: Math.min(limit, 5000) };
}
```

**Feed it** from the one place your logger writes a line, next to the stdout write:

```ts
// a custom JSON logger (LoggerService implementation)
const line = JSON.stringify(record);
process.stdout.write(line + '\n');
recentLogs.add(line);

// pino
const logger = pino({ /* … */ }, pino.multistream([
  { stream: process.stdout },
  { stream: { write: (chunk: string) => recentLogs.add(chunk.trimEnd()) } },
]));
```

`src/logs/logs.controller.ts`:

```ts
import { Controller, Get, Headers, Query, Res, HttpStatus } from '@nestjs/common';
import { Response } from 'express';
import { recentLogs, parseLogQuery } from './log-buffer';

const error = (res: Response, status: number, code: string, message: string) =>
  res.status(status).json({ error: { code, message } });

@Controller('internal')
export class LogsController {
  @Get('logs')
  logs(
    @Headers('x-internal-key') key: string | undefined,
    @Headers('x-caller') caller: string | undefined,
    @Query() params: Record<string, string>,
    @Res() res: Response,
  ) {
    if (!key || key !== process.env.INTERNAL_KEY) {
      return error(res, HttpStatus.UNAUTHORIZED, 'UNAUTHENTICATED', 'Send a valid X-Internal-Key');
    }
    if (caller === 'client') return error(res, HttpStatus.FORBIDDEN, 'FORBIDDEN', 'Internal endpoint');
    let query;
    try { query = parseLogQuery(params); }
    catch (e) { return error(res, HttpStatus.BAD_REQUEST, 'VALIDATION_ERROR', (e as Error).message); }
    const { lines, oldest } = recentLogs.query(query);
    res
      .status(200)
      .set('Content-Type', 'application/x-ndjson')
      .set('X-Log-Oldest', oldest)
      .set('X-Log-Buffered', String(recentLogs.size))
      .send(lines.map((l) => l + '\n').join(''));
  }
}
```

Register `LogsController` in a module, and if `main.ts` sets a global prefix keep the path at the
root:

```ts
app.setGlobalPrefix('exams', { exclude: ['health', 'status', 'metrics', 'internal/logs'] });
```

Skip it in your task-limit / timeout interceptor and log its request at `debug`, the same way you
treat `/health` and `/status`. If your auth guard is global, make sure it lets this route through to
its own key check (or reuse the guard, as long as `X-Caller: client` is refused).

### Python (reference)

Discovery and the gateway: `app/logbuffer.py` (a `logging.Handler` added next to the stdout
handler) and the route in `app/routers/internal.py`, on the branch
[`feature/topics-grpc-logs-metrics`](https://github.com/inercaso/KahootWithUndeadDiscovery/pull/5)
of Discovery.

---

## 3. Per service

The common rules for the broker migration (details in [`docs/communication.md`](docs/communication.md#message-broker)):

- **Calls to other services** go to the broker, not the gateway: `ANY http://broker:8091/call/{service}/{path}`
  with `X-Internal-Key`, `X-Request-Id`, `X-Player-Id` when acting for a player (or `Broker.Call`
  over gRPC on `broker:8092`). No circuit breaker or instance choice of your own.
- **Publishing** an event: `POST http://broker:8091/topics/{type}/events` with the envelope; mark the
  outbox row sent after the `202`. Stop serving `/events` once no consumer uses it.
- **Consuming**: list the topics in the Discovery registration (`"topics": [...]`) and serve
  `POST /internal/events` at the root (`200` = ack with `{"eventId","status":"processed|duplicate|ignored"}`,
  `4xx` = refuse for good, `5xx` = retry; deduplicate on `eventId`).
- **`X-Caller: client`**: the broker always sends its own `X-Internal-Key`, so a request carrying
  `X-Caller: client` is a player's: apply owner checks and refuse internal-only routes (`403`) even
  though the key is valid. Until you do, a player can reach your internal routes through the gateway.
- **gRPC** (grade 8): serve `broker.v1.Endpoint` (`Handle` feeds the request into your router,
  `Deliver` runs `POST /internal/events`) on a port of its own and register it as `grpc_url`.
  Base's `internal/broker/endpoint.go` is a working example (~150 lines).
- **`GET /metrics`** (Prometheus format) so the dashboard covers you, then add your job to
  `monitoring/prometheus/prometheus.yml`.
- When every service is done, the gateway's `LEGACY_SERVICE_ROUTES` goes back to `false`.

### Player (Go)

- [ ] `GET /internal/logs` (Go, section 2) — replaces the empty `200` it answers today
- [ ] publish `player.registered` and `player.leveled_up` to the broker (Base, Resource and
      Crafting now only take them from broker topics)
- [ ] consume `game.presence_changed`: register `"topics": ["game.presence_changed"]`, serve `POST /internal/events`
- [ ] honour `X-Caller: client`
- [ ] gRPC `Endpoint` + `grpc_url`; `GET /metrics`

### Game (NestJS)

- [ ] `GET /internal/logs` (NestJS, section 2) — replaces the empty `200` it answers today
- [ ] call World, Zombie, Exam, Player, Resource and Base through the broker
- [ ] publish `game.action_completed` and `game.presence_changed`
- [ ] consume `resource.gathered`, `exam.completed`, `world.wing_unlocked`
- [ ] honour `X-Caller: client`; gRPC `Endpoint` + `grpc_url`; `GET /metrics`

### Exam (NestJS)

- [ ] `GET /internal/logs` (NestJS, section 2)
- [ ] call Zombie and Player through the broker
- [ ] publish `exam.completed` (World, Game and Crafting wait for it on the broker)
- [ ] honour `X-Caller: client`; gRPC `Endpoint` + `grpc_url`; `GET /metrics`

### World (NestJS)

- [ ] `GET /internal/logs` (NestJS, section 2)
- [ ] publish `world.wing_unlocked`; consume `exam.completed` (`EXAM_EVENTS_URL` goes away)
- [ ] honour `X-Caller: client`; gRPC `Endpoint` + `grpc_url`; `GET /metrics`

### Zombie (NestJS)

- [ ] `GET /internal/logs` (NestJS, section 2)
- [ ] honour `X-Caller: client` (it is called by Game and Exam through the broker)
- [ ] gRPC `Endpoint` + `grpc_url`; `GET /metrics`

### Resource (NestJS)

- [ ] `GET /internal/logs` (NestJS, section 2)
- [ ] call World through the broker (`WORLD_SERVICE_URL` goes away)
- [ ] publish `resource.gathered`; consume `player.registered` and `game.action_completed`
      (`PLAYER_EVENTS_URL`, `GAME_EVENTS_URL` go away)
- [ ] honour `X-Caller: client` (commit and release keep working while breakers are open: the broker
      lets `CB_BYPASS_PATHS` through)
- [ ] gRPC `Endpoint` + `grpc_url`; `GET /metrics`
