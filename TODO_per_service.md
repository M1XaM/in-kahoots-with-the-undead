# Lab 4: `/internal/logs` and `/metrics` in every service

The gateway, the broker, Discovery, Base and Crafting serve both endpoints. **Player, Game, Exam,
World, Zombie and Resource** still have to add them:

- `GET /internal/logs`, so the gateway's `GET /logs` (one download of the logs of the whole system)
  includes the service;
- `GET /metrics`, so Prometheus and the Grafana dashboard cover the service.

## `GET /internal/logs`

Every instance keeps its recent log lines in memory and serves them; the gateway asks every instance
Discovery lists and merges the lines by time.

- **Keep the lines:** every line written to stdout (the shared JSON log format) is also kept, as is,
  in memory: the last `LOG_BUFFER_LINES` lines (default `5000`, oldest dropped first).
- **Path:** `/internal/logs` at the root, not under the service prefix: the gateway calls
  `<url registered with Discovery>/internal/logs`.
- **Auth:** `X-Internal-Key` must match `INTERNAL_KEY` (`401 UNAUTHENTICATED` otherwise); a request
  with `X-Caller: client` gets `403 FORBIDDEN`.
- **Outside the task limits** (like `/health` and `/status`), and its own request is logged only at
  `DEBUG`, since it is polled.
- **Query**, all optional:

  | Parameter | Meaning |
  |---|---|
  | `since`, `until` | RFC 3339 times, inclusive, compared with each line's `time` |
  | `level` | minimum level: `debug` (default), `info`, `warn`, `error` |
  | `request_id` | only the lines of that request |
  | `limit` | default `1000`, max `5000`; the newest matching lines are kept |

  A value that does not parse is `400 VALIDATION_ERROR` in the shared error body.
- **Answer:** `200`, `Content-Type: application/x-ndjson`, the matching lines **oldest first**, one
  per line, exactly as written to stdout, with the headers `X-Log-Oldest` (time of the oldest line
  kept, empty if none) and `X-Log-Buffered` (number of lines kept). The gateway only counts a `200`
  with that content type.

Done when the gateway's `GET /logs` (`X-Internal-Key`) lists every instance of the service in
`X-Logs-Sources` instead of `X-Logs-Missing`.

## `GET /metrics`

- **Format:** the Prometheus text exposition format.
- **Public** (no key; the port is only reachable inside the compose network), outside the task
  limits, its own request logged only at `DEBUG` (it is scraped every 5 s).
- **At least**, with the names the other services use so the dashboard can show them together:

  | Metric | Type | Labels |
  |---|---|---|
  | `http_requests_total` | counter | `method`, `route` (the route template, e.g. `/exams/:id`, not the raw path), `status` |
  | `http_request_duration_seconds` | histogram | `method`, `route` |
  | `active_tasks` | gauge | — requests being handled now |
  | `max_concurrent_tasks` | gauge | — the concurrent task limit |

  Useful on top: `events_consumed_total{type,outcome}` for a service that consumes events,
  `upstream_calls_total{target,status}` for calls to other services, plus the runtime metrics your
  client library adds.
- **Scrape job:** add the service to [`monitoring/prometheus/prometheus.yml`](monitoring/prometheus/prometheus.yml),
  with `dns_sd_configs` on the compose service name so every replica is scraped, like `base`:

  ```yaml
  - job_name: exam
    dns_sd_configs:
      - names: ["exam"]
        type: A
        port: 8083
        refresh_interval: 15s
  ```

Done when the service's job shows `up` for every replica on http://localhost:9090/targets.

## Checklist

| Service | `GET /internal/logs` | `GET /metrics` + scrape job |
|---|---|---|
| Player | [ ] (it answers the path with an empty `200` today) | [ ] |
| Game | [ ] (it answers the path with an empty `200` today) | [ ] |
| Exam | [ ] | [ ] |
| World | [ ] | [ ] |
| Zombie | [ ] | [ ] |
| Resource | [ ] | [ ] |
