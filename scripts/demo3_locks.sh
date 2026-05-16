#!/usr/bin/env bash
set -Eeuo pipefail

source /demo/scripts/lib.sh

section "Demo 3: блокировки и консистентность"

step "Reset accounts"
psql_demo_direct -c "UPDATE accounts SET balance = 100 WHERE id IN (1, 2);"

tmpdir="$(mktemp -d)"
cleanup() {
    rm -rf "$tmpdir"
}
trap cleanup EXIT

step "Session A держит row lock, session B ожидает"
psql -X -v ON_ERROR_STOP=1 "$DEMO_DIRECT_URL" >"$tmpdir/a.out" 2>&1 <<'SQL' &
BEGIN;
UPDATE accounts
SET balance = balance + 10
WHERE id = 1
RETURNING id, owner, balance;
SELECT pg_sleep(6);
COMMIT;
SQL
pid_a=$!

sleep 1
psql -X -v ON_ERROR_STOP=1 "$DEMO_DIRECT_URL" >"$tmpdir/b.out" 2>&1 <<'SQL' &
SET lock_timeout = '10s';
UPDATE accounts
SET balance = balance + 20
WHERE id = 1
RETURNING id, owner, balance;
SQL
pid_b=$!

sleep 2
step "pg_stat_activity показывает ожидание блокировки"
psql_demo_direct <<'SQL'
SELECT
    pid,
    state,
    wait_event_type,
    wait_event,
    left(query, 80) AS query
FROM pg_stat_activity
WHERE datname = current_database()
  AND pid <> pg_backend_pid()
ORDER BY pid;
SQL

wait "$pid_a"
wait "$pid_b"
prefix_file "session A" "$tmpdir/a.out"
prefix_file "session B" "$tmpdir/b.out"
pause_step

step "CHECK constraint + ROLLBACK"
set +e
psql -X "$DEMO_DIRECT_URL" <<'SQL'
BEGIN;
UPDATE accounts
SET balance = balance + 50
WHERE id = 2
RETURNING id, owner, balance;
UPDATE accounts
SET balance = -1
WHERE id = 2;
ROLLBACK;
SQL
set -e

step "После ошибки и ROLLBACK первая операция тоже не сохранена"
psql_demo_direct -c "SELECT id, owner, balance FROM accounts ORDER BY id;"

section "Вывод"
echo "Консистентность держится на сочетании транзакций, блокировок, ограничений и корректной обработки ошибок."
