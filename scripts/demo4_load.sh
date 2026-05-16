#!/usr/bin/env bash
set -Eeuo pipefail

source /demo/scripts/lib.sh

section "Demo 4: масштабируемость и нагрузка"

step "PgBouncer SHOW POOLS"
psql -X "postgresql://demo:demo@pgbouncer-write:6432/pgbouncer" -c "SHOW POOLS;"
pause_step

step "pgbench: 1 client"
pgbench -n -c 1 -T "$PGBENCH_TIME" "$BENCH_URL"
pause_step

step "pgbench: 20 clients"
pgbench -n -c 20 -T "$PGBENCH_TIME" "$BENCH_URL"
pause_step

step "pgbench: 80 clients"
pgbench -n -c 80 -T "$PGBENCH_TIME" "$BENCH_URL"
pause_step

step "Hot row contention: все клиенты обновляют одну строку"
psql_demo_direct -c "UPDATE hot_rows SET counter = 0;"
pgbench -n -c 20 -T "$PGBENCH_TIME" -f /demo/sql/pgbench_hot_row.sql "$DEMO_WRITE_URL"
pause_step

step "Random row updates: клиенты распределены по 1000 строкам"
psql_demo_direct -c "UPDATE hot_rows SET counter = 0;"
pgbench -n -c 20 -T "$PGBENCH_TIME" -f /demo/sql/pgbench_random_row.sql "$DEMO_WRITE_URL"

section "Вывод"
echo "Пул соединений помогает пережить много клиентов, но модель данных может создать узкое место на одной часто обновляемой строке."
