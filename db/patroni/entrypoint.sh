#!/bin/sh
# NODE (the compose service name, e.g. player-db-1) names the member; the other nodes and HAProxy
# reach it under that hostname, so both addresses derive from it. PATRONI_SCOPE (the cluster,
# e.g. player) comes from compose, so `patronictl list` inside a node needs no argument.
set -eu
: "${NODE:?set NODE to this node's hostname}" "${PATRONI_SCOPE:?set PATRONI_SCOPE to the cluster name}"
export PATRONI_NAME="$NODE"
export PATRONI_RESTAPI_CONNECT_ADDRESS="$NODE:8008"
export PATRONI_POSTGRESQL_CONNECT_ADDRESS="$NODE:5432"
# Patroni hides PATRONI_* from the scripts it runs; post_init.sh connects as PGUSER
export PGUSER="${PATRONI_SUPERUSER_USERNAME:-postgres}"
exec patroni /etc/patroni/patroni.yml
