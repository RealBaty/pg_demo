#!/usr/bin/env bash
set -euo pipefail

: "${PGBOUNCER_TARGET_HOST:=haproxy}"
: "${PGBOUNCER_TARGET_PORT:=5000}"
: "${PGBOUNCER_LISTEN_PORT:=6432}"

cat > /tmp/userlist.txt <<'EOF'
"postgres" "postgres"
"demo" "demo"
EOF

cat > /tmp/pgbouncer.ini <<EOF
[databases]
* = host=${PGBOUNCER_TARGET_HOST} port=${PGBOUNCER_TARGET_PORT}

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = ${PGBOUNCER_LISTEN_PORT}
auth_type = plain
auth_file = /tmp/userlist.txt
admin_users = postgres,demo
stats_users = postgres,demo
pool_mode = transaction
max_client_conn = 500
default_pool_size = 50
reserve_pool_size = 10
server_reset_query = DISCARD ALL
ignore_startup_parameters = extra_float_digits,options
pidfile = /tmp/pgbouncer.pid
log_connections = 1
log_disconnections = 1
EOF

exec pgbouncer /tmp/pgbouncer.ini
