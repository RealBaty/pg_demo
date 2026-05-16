#!/usr/bin/env bash
set -Eeuo pipefail

source /demo/scripts/lib.sh

say() {
    printf '\n%s\n' "$1"
}

show_sql() {
    local label="$1"
    local sql="$2"
    printf '\n[%s] SQL:\n' "$label"
    printf '%s\n' "$sql" | sed 's/^/    /'
}

run_sql_file() {
    local label="$1"
    local sql_file="$2"
    local out_file="$3"
    local on_error_stop="${4:-1}"

    if [[ "$on_error_stop" == "1" ]]; then
        psql -X -v ON_ERROR_STOP=1 "$DEMO_DIRECT_URL" -f "$sql_file" >"$out_file" 2>&1
    else
        psql -X "$DEMO_DIRECT_URL" -f "$sql_file" >"$out_file" 2>&1
    fi
}

print_result() {
    local label="$1"
    local out_file="$2"
    printf '\n[%s] Результат:\n' "$label"
    sed "s/^/    /" "$out_file"
}

run_read_scenario() {
    local isolation="$1"
    local title="$2"
    local expected="$3"
    local tmpdir
    tmpdir="$(mktemp -d)"

    cat >"$tmpdir/session_a.sql" <<SQL
BEGIN ISOLATION LEVEL ${isolation};
SELECT 'A1: первое чтение' AS step, value
FROM demo_kv
WHERE key = 'isolation';
SELECT pg_sleep(2);
SELECT 'A2: повторное чтение после COMMIT B' AS step, value
FROM demo_kv
WHERE key = 'isolation';
COMMIT;
SQL

    cat >"$tmpdir/session_b.sql" <<'SQL'
UPDATE demo_kv
SET value = 'committed by session B',
    updated_at = now()
WHERE key = 'isolation'
RETURNING 'B: UPDATE + COMMIT' AS step, key, value;
SQL

    step "$title"
    say "Начальное состояние: demo_kv['isolation'] = 'initial value'."
    psql_demo_direct -qAt -c "UPDATE demo_kv SET value = 'initial value', updated_at = now() WHERE key = 'isolation';"

    say "Идея: session A открывает транзакцию и читает строку. Пока A ждет, session B меняет эту же строку и фиксирует изменение."
    say "Наблюдение: ${expected}"
    show_sql "SESSION A" "$(cat "$tmpdir/session_a.sql")"
    show_sql "SESSION B, стартует через 1 секунду" "$(cat "$tmpdir/session_b.sql")"

    run_sql_file "SESSION A" "$tmpdir/session_a.sql" "$tmpdir/a.out" &
    local pid_a=$!
    (
        sleep 1
        run_sql_file "SESSION B" "$tmpdir/session_b.sql" "$tmpdir/b.out"
    ) &
    local pid_b=$!

    wait "$pid_a"
    wait "$pid_b"

    print_result "SESSION A" "$tmpdir/a.out"
    print_result "SESSION B" "$tmpdir/b.out"
    rm -rf "$tmpdir"
}

run_serializable_scenario() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    cat >"$tmpdir/session_a.sql" <<'SQL'
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT 'A1: Alice видит дежурных врачей' AS step, count(*) AS on_call_count
FROM doctors
WHERE on_call;
SELECT pg_sleep(1);
UPDATE doctors
SET on_call = false
WHERE name = 'alice'
RETURNING 'A2: Alice снимает себя с дежурства' AS step, name, on_call;
COMMIT;
SQL

    cat >"$tmpdir/session_b.sql" <<'SQL'
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT 'B1: Bob видит дежурных врачей' AS step, count(*) AS on_call_count
FROM doctors
WHERE on_call;
SELECT pg_sleep(1);
UPDATE doctors
SET on_call = false
WHERE name = 'bob'
RETURNING 'B2: Bob снимает себя с дежурства' AS step, name, on_call;
COMMIT;
SQL

    step "SERIALIZABLE: защита бизнес-инварианта"
    say "Бизнес-правило: хотя бы один врач должен остаться дежурным."
    say "Начальное состояние: Alice и Bob оба on_call = true."
    psql_demo_direct -qAt -c "UPDATE doctors SET on_call = true;"
    psql_demo_direct -c "SELECT id, name, on_call FROM doctors ORDER BY id;"

    say "Идея: обе транзакции одновременно видят двух дежурных врачей и пытаются снять с дежурства разных людей."
    say "Наблюдение: на SERIALIZABLE PostgreSQL должен отменить одну транзакцию с serialization failure."
    show_sql "SESSION A" "$(cat "$tmpdir/session_a.sql")"
    show_sql "SESSION B" "$(cat "$tmpdir/session_b.sql")"

    set +e
    run_sql_file "SESSION A" "$tmpdir/session_a.sql" "$tmpdir/a.out" &
    local pid_a=$!
    run_sql_file "SESSION B" "$tmpdir/session_b.sql" "$tmpdir/b.out" &
    local pid_b=$!
    wait "$pid_a"
    local rc_a=$?
    wait "$pid_b"
    local rc_b=$?
    set -e

    print_result "SESSION A" "$tmpdir/a.out"
    print_result "SESSION B" "$tmpdir/b.out"

    if (( rc_a != 0 || rc_b != 0 )); then
        say "Итог: это ожидаемо. Одна транзакция получила serialization failure, приложение должно повторить ее целиком."
    else
        say "Итог: обе транзакции прошли без конфликта. Для наглядности можно повторить demo 2: SERIALIZABLE-конфликт зависит от расписания параллельных транзакций."
    fi

    say "Финальное состояние doctors:"
    psql_demo_direct -c "SELECT id, name, on_call FROM doctors ORDER BY id;"
    rm -rf "$tmpdir"
}

section "Demo 2: транзакции и уровни изоляции"

say "В этой демонстрации есть две параллельные SQL-сессии:"
say "SESSION A - длинная транзакция, в которой мы наблюдаем snapshot."
say "SESSION B - конкурентная транзакция, которая меняет данные и делает COMMIT."

run_read_scenario \
    "READ COMMITTED" \
    "READ COMMITTED: каждый SELECT видит новый committed snapshot" \
    "второе чтение SESSION A должно увидеть значение, зафиксированное SESSION B."
pause_step

run_read_scenario \
    "REPEATABLE READ" \
    "REPEATABLE READ: транзакция держит один snapshot" \
    "второе чтение SESSION A должно увидеть старое значение, несмотря на COMMIT SESSION B."
pause_step

run_serializable_scenario

section "Вывод"
say "READ COMMITTED: snapshot обновляется на каждый SQL-запрос внутри транзакции."
say "REPEATABLE READ: snapshot фиксируется на уровне всей транзакции."
say "SERIALIZABLE: PostgreSQL предотвращает опасные конкурентные расписания, но приложение должно уметь retry."
