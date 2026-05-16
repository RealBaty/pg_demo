#!/usr/bin/env bash
set -Eeuo pipefail

source /demo/scripts/lib.sh

section "Bootstrap demo databases"

step "Waiting for write endpoint"
for attempt in $(seq 1 90); do
    if psql -X "$ADMIN_URL" -qAt -c "SELECT 1" >/dev/null 2>&1; then
        break
    fi
    if [[ "$attempt" == "90" ]]; then
        echo "Write endpoint did not become ready in time." >&2
        exit 1
    fi
    sleep 2
done

step "Creating demo role and databases"
psql_admin <<'SQL'
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'demo') THEN
        CREATE ROLE demo LOGIN PASSWORD 'demo';
    ELSE
        ALTER ROLE demo WITH LOGIN PASSWORD 'demo';
    END IF;
END
$$;

SELECT 'CREATE DATABASE demo OWNER demo'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'demo')\gexec

SELECT 'CREATE DATABASE bench OWNER demo'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'bench')\gexec

ALTER DATABASE demo OWNER TO demo;
ALTER DATABASE bench OWNER TO demo;
SQL

step "Applying demo schema"
psql_demo_direct -f /demo/sql/bootstrap_demo.sql

step "Preparing pgbench database"
if psql -X "$BENCH_DIRECT_URL" -qAt -c "SELECT to_regclass('public.pgbench_accounts') IS NOT NULL" | grep -q '^t$'; then
    echo "pgbench schema already exists."
else
    pgbench -i -s "$PGBENCH_SCALE" "$BENCH_DIRECT_URL"
fi

section "Bootstrap complete"
