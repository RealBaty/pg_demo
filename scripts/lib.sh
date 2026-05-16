#!/usr/bin/env bash
set -Eeuo pipefail

PATRONICTL_CONFIG="${PATRONICTL_CONFIG:-/demo/config/patronictl.yml}"
ADMIN_URL="${ADMIN_URL:-postgresql://postgres:postgres@haproxy:5000/postgres}"
DEMO_DIRECT_URL="${DEMO_DIRECT_URL:-postgresql://demo:demo@haproxy:5000/demo}"
DEMO_WRITE_URL="${DEMO_WRITE_URL:-postgresql://demo:demo@pgbouncer-write:6432/demo}"
DEMO_READ_URL="${DEMO_READ_URL:-postgresql://demo:demo@pgbouncer-read:6432/demo}"
BENCH_DIRECT_URL="${BENCH_DIRECT_URL:-postgresql://demo:demo@haproxy:5000/bench}"
BENCH_URL="${BENCH_URL:-postgresql://demo:demo@pgbouncer-write:6432/bench}"
PGBENCH_TIME="${PGBENCH_TIME:-20}"
PGBENCH_SCALE="${PGBENCH_SCALE:-5}"
DEMO_PAUSE="${DEMO_PAUSE:-1}"

section() {
    printf '\n== %s ==\n' "$1"
}

step() {
    printf '\n-- %s --\n' "$1"
}

pause_step() {
    if [[ "$DEMO_PAUSE" == "1" && -t 0 ]]; then
        printf '\n'
        read -r -p "Нажмите Enter для продолжения..." _
    fi
}

psql_admin() {
    psql -X -v ON_ERROR_STOP=1 "$ADMIN_URL" "$@"
}

psql_demo_direct() {
    psql -X -v ON_ERROR_STOP=1 "$DEMO_DIRECT_URL" "$@"
}

psql_demo_write() {
    psql -X -v ON_ERROR_STOP=1 "$DEMO_WRITE_URL" "$@"
}

psql_demo_read() {
    psql -X -v ON_ERROR_STOP=1 "$DEMO_READ_URL" "$@"
}

patroni_list() {
    patronictl -c "$PATRONICTL_CONFIG" list
}

reset_core_demo_data() {
    psql_demo_direct <<'SQL'
TRUNCATE ha_demo RESTART IDENTITY;
UPDATE demo_kv
SET value = 'initial value',
    updated_at = now()
WHERE key = 'isolation';
UPDATE accounts
SET balance = 100
WHERE id IN (1, 2);
UPDATE doctors
SET on_call = true
WHERE id IN (1, 2);
UPDATE hot_rows
SET counter = 0;
SQL
}

prefix_file() {
    local label="$1"
    local file="$2"
    sed "s/^/[${label}] /" "$file"
}
