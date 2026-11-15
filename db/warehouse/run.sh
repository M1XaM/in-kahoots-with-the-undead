#!/bin/sh
# ETL loop of the data warehouse (warehouse-etl container). Every ETL_INTERVAL_S seconds it
# applies etl.sql, points one postgres_fdw server at each line of ETL_SOURCES and runs
# CALL etl.run(). A failed run is logged and retried on the next tick.
#
# ETL_SOURCES: one source per line, "name host port dbname user password" (no spaces inside a value)
# WAREHOUSE_URL: libpq URL of the warehouse database
set -u
: "${WAREHOUSE_URL:?}" "${ETL_SOURCES:?}"
INTERVAL="${ETL_INTERVAL_S:-60}"
export PGCONNECT_TIMEOUT=5
# only warnings and errors reach the log, not the NOTICEs of every DROP ... IF EXISTS
export PGOPTIONS="-c client_min_messages=warning"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) etl $*"; }

until psql "$WAREHOUSE_URL" -qAtc 'SELECT 1' >/dev/null 2>&1; do log "waiting for the warehouse"; sleep 2; done

while true; do
  if psql "$WAREHOUSE_URL" -q -v ON_ERROR_STOP=1 -f /etl/etl.sql >/dev/null; then
    echo "$ETL_SOURCES" | while read -r name host port db user password; do
      [ -n "$name" ] || continue
      psql "$WAREHOUSE_URL" -q -v ON_ERROR_STOP=1 -v name="$name" -v host="$host" -v port="$port" \
        -v db="$db" -v user="$user" -v password="$password" >/dev/null <<'SQL'
SELECT etl.register_source(:'name', :'host', :'port'::int, :'db', :'user', :'password');
SQL
    done
    if psql "$WAREHOUSE_URL" -q -v ON_ERROR_STOP=1 -c 'CALL etl.run()'; then
      # one line per run: steps that failed are named with their error
      psql "$WAREHOUSE_URL" -qAt -F ' ' -c "SELECT 'run ' || max(run_id) || ': ' || count(*) FILTER (WHERE status = 'ok') || ' steps ok, ' || count(*) FILTER (WHERE status = 'failed') || ' failed, ' || coalesce(sum(rows), 0) || ' rows' || coalesce('; ' || string_agg(step || ': ' || error, '; ') FILTER (WHERE status = 'failed'), '') FROM etl.runs WHERE run_id = (SELECT max(run_id) FROM etl.runs)" | while read -r line; do log "$line"; done
    else
      log "run failed"
    fi
  else
    log "could not apply etl.sql"
  fi
  sleep "$INTERVAL"
done
