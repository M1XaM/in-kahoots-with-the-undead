#!/bin/sh
# Patroni runs this once, on the node that bootstraps the cluster, before it takes the leader
# lock: nothing can connect through HAProxy yet. It plays the part of the official image's
# POSTGRES_DB and /docker-entrypoint-initdb.d, which Patroni's own initdb skips.
set -eu
psql_local() { psql -h /var/run/postgresql -v ON_ERROR_STOP=1 -q "$@"; }

if [ -n "${APP_DB:-}" ] && [ -z "$(psql_local -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$APP_DB'")" ]; then
  psql_local -d postgres -c "CREATE DATABASE \"$APP_DB\""
fi
for f in /docker-entrypoint-initdb.d/*.sql; do
  [ -f "$f" ] || continue
  echo "post_init: running $f on ${APP_DB:-postgres}"
  psql_local -d "${APP_DB:-postgres}" -f "$f"
done
