#!/usr/bin/env bash
set -Eeuo pipefail

source /demo/scripts/lib.sh

section "Patroni cluster"
patroni_list

section "Endpoint routing"
printf 'write endpoint pg_is_in_recovery(): '
psql_demo_write -qAt -c "SELECT pg_is_in_recovery();"

printf 'read endpoint pg_is_in_recovery():  '
psql_demo_read -qAt -c "SELECT pg_is_in_recovery();"

section "PgBouncer pools"
pgbouncer_pools_compact
