#!/usr/bin/env bash
set -Eeuo pipefail

source /demo/scripts/lib.sh

export PAGER=cat
export PSQL_PAGER=cat
export LESS=-FRX

DEMO_ID="${1:-}"
[[ "$DEMO_ID" =~ ^[1-7]$ ]] || {
    echo "Usage: tmux_demo.sh <1..7>" >&2
    exit 1
}

SESSION_NAME="${DEMO_SESSION_NAME:-demo${DEMO_ID}}"
LEFT="${DEMO_LEFT_PANE:-${SESSION_NAME}:0.0}"
RIGHT="${DEMO_RIGHT_PANE:-${SESSION_NAME}:0.1}"
CONTROL="${DEMO_CONTROL_PANE:-${SESSION_NAME}:0.2}"

declare -a STEP_TITLE STEP_LABEL STEP_TARGET STEP_NOTE STEP_CMD
LEFT_CMD="env PAGER=cat PSQL_PAGER=cat LESS=-FRX bash"
RIGHT_CMD="env PAGER=cat PSQL_PAGER=cat LESS=-FRX bash"
LEFT_TITLE="CONSOLE"
RIGHT_TITLE="CONSOLE"
DEMO_TITLE=""
RESET_KIND="none"
TWO_PANES=0
SQL_PANES=0
CONTROL_HEIGHT=13

add_step() {
    STEP_TITLE+=("$1")
    STEP_LABEL+=("$2")
    STEP_TARGET+=("$3")
    STEP_NOTE+=("$4")
    STEP_CMD+=("$5")
}

send_text() {
    local target="$1"
    local text="$2"
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s' "$line" | tmux load-buffer -b demo-line -
        tmux paste-buffer -t "$target" -b demo-line
        tmux send-keys -t "$target" Enter
    done <<< "$text"
}

clear_panes() {
    tmux send-keys -t "$LEFT" C-l
    if [[ "$TWO_PANES" == "1" ]]; then
        tmux send-keys -t "$RIGHT" C-l
    fi
}

release_sql_sessions() {
    if [[ "$SQL_PANES" == "1" ]]; then
        send_text "$LEFT" "ROLLBACK;"
        send_text "$RIGHT" "ROLLBACK;"
        sleep 0.5
    fi
}

reset_demo_data() {
    case "$RESET_KIND" in
        isolation)
            psql_demo_direct -qAt <<'SQL' >/dev/null
UPDATE demo_kv SET value = 'initial value', updated_at = now() WHERE key = 'isolation';
UPDATE doctors SET on_call = true;
SQL
            ;;
        locks)
            psql_demo_direct -qAt <<'SQL' >/dev/null
UPDATE accounts SET balance = 100 WHERE id IN (1, 2);
SQL
            ;;
        load)
            psql_demo_direct -qAt -c "UPDATE hot_rows SET counter = 0;" >/dev/null
            ;;
        ha)
            /demo/scripts/demo_ops.sh stop-writer >/dev/null 2>&1 || true
            ;;
        pacelc)
            for replica in pg-node-1 pg-node-2 pg-node-3; do
                psql -X -P pager=off -v ON_ERROR_STOP=0 \
                    "postgresql://postgres:postgres@${replica}:5432/demo" \
                    -c "SELECT pg_wal_replay_resume() WHERE pg_is_in_recovery();" >/dev/null 2>&1 || true
            done
            patronictl -c /demo/config/patronictl.yml resume --wait pg-ha-demo >/dev/null 2>&1 || true
            rm -f /tmp/demo_marker
            ;;
    esac
}

print_screen() {
    local idx="$1"
    local total="$2"
    local title="$3"
    local label="$4"
    local note="$5"
    local cmd="$6"

    clear
    printf 'Demo %s: %s\n' "$DEMO_ID" "$DEMO_TITLE"
    printf 'Шаг %s/%s\n\n' "$idx" "$total"
    printf '%s\n\n' "$title"
    printf 'Куда отправим: %s\n\n' "$label"
    printf 'Что показать: %s\n\n' "$note"
    printf 'Команда следующего шага:\n'
    printf '%s\n' "$cmd" | sed 's/^/    /'
    printf '\nEnter - выполнить | r - reset темы | q - выйти\n'
}

wait_action() {
    local idx="$1"
    local total="$2"
    local title="$3"
    local label="$4"
    local note="$5"
    local cmd="$6"
    local answer

    while true; do
        print_screen "$idx" "$total" "$title" "$label" "$note" "$cmd"
        IFS= read -rsn1 answer || answer=""
        case "$answer" in
            "")
                return 0
                ;;
            r|R)
                release_sql_sessions
                reset_demo_data
                clear_panes
                send_text "$LEFT" "echo 'Reset for demo ${DEMO_ID} done'"
                ;;
            q|Q)
                release_sql_sessions
                reset_demo_data
                tmux kill-session -t "$SESSION_NAME"
                exit 0
                ;;
        esac
    done
}

run_controller() {
    local total="${#STEP_TITLE[@]}"
    local i

    clear
    cat <<EOF
Demo ${DEMO_ID}: ${DEMO_TITLE}

Управление:
  Enter  выполнить следующий подготовленный шаг
  r      сбросить данные текущей темы
  q      выйти из demo

EOF
    if [[ "$TWO_PANES" == "1" ]]; then
        cat <<EOF
Панель слева:  ${LEFT_TITLE}
Панель справа: ${RIGHT_TITLE}
EOF
    else
        cat <<EOF
Рабочая панель: ${LEFT_TITLE}
EOF
    fi
    cat <<EOF
Нижняя панель: управление

Нажмите Enter, чтобы начать, или q чтобы выйти...
EOF
    local answer
    IFS= read -rsn1 answer || answer=""
    if [[ "$answer" == "q" || "$answer" == "Q" ]]; then
        tmux kill-session -t "$SESSION_NAME"
        exit 0
    fi

    for i in "${!STEP_TITLE[@]}"; do
        wait_action "$((i + 1))" "$total" "${STEP_TITLE[$i]}" "${STEP_LABEL[$i]}" "${STEP_NOTE[$i]}" "${STEP_CMD[$i]}"
        send_text "${STEP_TARGET[$i]}" "${STEP_CMD[$i]}"
    done

    clear
    cat <<EOF
Demo ${DEMO_ID} завершено.

Нажмите q, чтобы закрыть demo.
EOF
    while true; do
        IFS= read -rsn1 answer || answer=""
        [[ "$answer" == "q" || "$answer" == "Q" ]] && break
    done
    release_sql_sessions
    reset_demo_data
    tmux kill-session -t "$SESSION_NAME"
}

build_demo_1() {
    DEMO_TITLE="состояние кластера и маршрутизация"
    LEFT_TITLE="CONSOLE"
    add_step "Patroni видит роли узлов" "CONSOLE" "$LEFT" \
        "Показываем leader и replicas, timeline и lag." \
        "patronictl -c /demo/config/patronictl.yml list"
    add_step "Write endpoint ведет на primary" "CONSOLE" "$LEFT" \
        "Ожидаем pg_is_in_recovery() = false." \
        "psql -X -P pager=off \"\$DEMO_WRITE_URL\" -c \"SELECT inet_server_addr() AS server_addr, pg_is_in_recovery() AS is_replica;\""
    add_step "Read endpoint ведет на replica" "CONSOLE" "$LEFT" \
        "Ожидаем pg_is_in_recovery() = true." \
        "psql -X -P pager=off \"\$DEMO_READ_URL\" -c \"SELECT inet_server_addr() AS server_addr, pg_is_in_recovery() AS is_replica;\""
    add_step "PgBouncer pools" "CONSOLE" "$LEFT" \
        "Показываем, что приложение может ходить через pooler." \
        "/demo/scripts/pgbouncer_pools.sh"
}

build_demo_2() {
    DEMO_TITLE="транзакции и уровни изоляции"
    TWO_PANES=1
    SQL_PANES=1
    CONTROL_HEIGHT=16
    LEFT_CMD="psql -X -P pager=off -v ON_ERROR_STOP=0 -v VERBOSITY=terse -v PROMPT1='A%R%# ' -v PROMPT2='A%R%# ' '$DEMO_DIRECT_URL'"
    RIGHT_CMD="psql -X -P pager=off -v ON_ERROR_STOP=0 -v VERBOSITY=terse -v PROMPT1='B%R%# ' -v PROMPT2='B%R%# ' '$DEMO_DIRECT_URL'"
    LEFT_TITLE="SESSION A"
    RIGHT_TITLE="SESSION B"
    RESET_KIND="isolation"
    add_step "2.1 READ COMMITTED - подготовка" "SESSION A" "$LEFT" \
        "Сбросим строку к initial value." \
        "UPDATE demo_kv SET value = 'initial value', updated_at = now() WHERE key = 'isolation';
SELECT key, value FROM demo_kv WHERE key = 'isolation';"
    add_step "2.1 READ COMMITTED - A открывает транзакцию" "SESSION A" "$LEFT" \
        "A начинает READ COMMITTED." \
        "BEGIN ISOLATION LEVEL READ COMMITTED;"
    add_step "2.1 READ COMMITTED - A читает первый раз" "SESSION A" "$LEFT" \
        "A видит initial value." \
        "SELECT key, value FROM demo_kv WHERE key = 'isolation';"
    add_step "2.1 READ COMMITTED - B меняет и коммитит" "SESSION B" "$RIGHT" \
        "B меняет строку автокоммитом." \
        "UPDATE demo_kv
SET value = 'committed by session B',
    updated_at = now()
WHERE key = 'isolation'
RETURNING key, value;"
    add_step "2.1 READ COMMITTED - A читает второй раз" "SESSION A" "$LEFT" \
        "A должен увидеть новое committed value." \
        "SELECT key, value FROM demo_kv WHERE key = 'isolation';"
    add_step "2.1 READ COMMITTED - COMMIT" "SESSION A" "$LEFT" "Закрываем транзакцию." "COMMIT;"
    add_step "2.2 REPEATABLE READ - подготовка" "SESSION A" "$LEFT" \
        "Возвращаем initial value." \
        "UPDATE demo_kv SET value = 'initial value', updated_at = now() WHERE key = 'isolation';
SELECT key, value FROM demo_kv WHERE key = 'isolation';"
    add_step "2.2 REPEATABLE READ - A открывает транзакцию" "SESSION A" "$LEFT" \
        "A фиксирует snapshot транзакции." \
        "BEGIN ISOLATION LEVEL REPEATABLE READ;"
    add_step "2.2 REPEATABLE READ - A читает первый раз" "SESSION A" "$LEFT" \
        "A видит initial value." \
        "SELECT key, value FROM demo_kv WHERE key = 'isolation';"
    add_step "2.2 REPEATABLE READ - B меняет и коммитит" "SESSION B" "$RIGHT" \
        "B снаружи меняет строку." \
        "UPDATE demo_kv
SET value = 'committed by session B',
    updated_at = now()
WHERE key = 'isolation'
RETURNING key, value;"
    add_step "2.2 REPEATABLE READ - A читает второй раз" "SESSION A" "$LEFT" \
        "A продолжает видеть initial value." \
        "SELECT key, value FROM demo_kv WHERE key = 'isolation';"
    add_step "2.2 REPEATABLE READ - B видит текущее значение" "SESSION B" "$RIGHT" \
        "B вне транзакции видит новое committed value." \
        "SELECT key, value FROM demo_kv WHERE key = 'isolation';"
    add_step "2.2 REPEATABLE READ - COMMIT" "SESSION A" "$LEFT" "Закрываем транзакцию." "COMMIT;"
    add_step "2.3 SERIALIZABLE - подготовка doctors" "SESSION A" "$LEFT" \
        "Alice и Bob оба дежурят." \
        "UPDATE doctors SET on_call = true;
SELECT id, name, on_call FROM doctors ORDER BY id;"
    add_step "2.3 SERIALIZABLE - A начинает" "SESSION A" "$LEFT" "Alice-транзакция." "BEGIN ISOLATION LEVEL SERIALIZABLE;"
    add_step "2.3 SERIALIZABLE - B начинает" "SESSION B" "$RIGHT" "Bob-транзакция." "BEGIN ISOLATION LEVEL SERIALIZABLE;"
    add_step "2.3 SERIALIZABLE - A проверяет правило" "SESSION A" "$LEFT" "A видит двух дежурных." "SELECT count(*) AS on_call_count FROM doctors WHERE on_call;"
    add_step "2.3 SERIALIZABLE - B проверяет правило" "SESSION B" "$RIGHT" "B тоже видит двух дежурных." "SELECT count(*) AS on_call_count FROM doctors WHERE on_call;"
    add_step "2.3 SERIALIZABLE - A снимает Alice" "SESSION A" "$LEFT" "A меняет Alice, но пока не коммитит." "UPDATE doctors SET on_call = false WHERE name = 'alice' RETURNING name, on_call;"
    add_step "2.3 SERIALIZABLE - B снимает Bob" "SESSION B" "$RIGHT" "B меняет Bob, но пока не коммитит." "UPDATE doctors SET on_call = false WHERE name = 'bob' RETURNING name, on_call;"
    add_step "2.3 SERIALIZABLE - первый COMMIT" "SESSION A" "$LEFT" "Один COMMIT обычно проходит." "COMMIT;"
    add_step "2.3 SERIALIZABLE - второй COMMIT" "SESSION B" "$RIGHT" "Ожидаем serialization failure." "COMMIT;"
    add_step "2.3 SERIALIZABLE - итог" "SESSION A" "$LEFT" "Проверяем финальное состояние." "SELECT id, name, on_call FROM doctors ORDER BY id;"
}

build_demo_3() {
    DEMO_TITLE="блокировки и консистентность"
    TWO_PANES=1
    SQL_PANES=1
    CONTROL_HEIGHT=16
    LEFT_CMD="psql -X -P pager=off -v ON_ERROR_STOP=0 -v VERBOSITY=terse -v PROMPT1='A%R%# ' -v PROMPT2='A%R%# ' '$DEMO_DIRECT_URL'"
    RIGHT_CMD="psql -X -P pager=off -v ON_ERROR_STOP=0 -v VERBOSITY=terse -v PROMPT1='B%R%# ' -v PROMPT2='B%R%# ' '$DEMO_DIRECT_URL'"
    LEFT_TITLE="SESSION A"
    RIGHT_TITLE="SESSION B"
    RESET_KIND="locks"
    add_step "Подготовка accounts" "SESSION A" "$LEFT" "Баланс Alice и Bob снова 100." "UPDATE accounts SET balance = 100 WHERE id IN (1, 2);
SELECT id, owner, balance FROM accounts ORDER BY id;"
    add_step "A открывает транзакцию" "SESSION A" "$LEFT" "A будет держать row lock." "BEGIN;"
    add_step "A обновляет Alice без COMMIT" "SESSION A" "$LEFT" "Эта строка теперь заблокирована до COMMIT/ROLLBACK." "UPDATE accounts SET balance = balance + 10 WHERE id = 1 RETURNING id, owner, balance;"
    add_step "B пытается обновить ту же строку" "SESSION B" "$RIGHT" "B зависнет в ожидании lock. Это нормально, следующий шаг покажет wait_event." "SET lock_timeout = '5min';
UPDATE accounts SET balance = balance + 20 WHERE id = 1 RETURNING id, owner, balance;"
    add_step "A смотрит pg_stat_activity" "SESSION A" "$LEFT" "Видим, что B ждет Lock." "SELECT wait_event_type, left(regexp_replace(query, '\s+', ' ', 'g'), 52) AS query
FROM pg_stat_activity
WHERE datname = current_database()
  AND wait_event_type = 'Lock'
  AND pid <> pg_backend_pid()
ORDER BY pid;"
    add_step "A делает COMMIT" "SESSION A" "$LEFT" "Lock освобождается, B должен завершить UPDATE." "COMMIT;"
    add_step "CHECK constraint" "SESSION A" "$LEFT" "Отрицательный balance запрещен ограничением." "UPDATE accounts SET balance = -1 WHERE id = 2;"
    add_step "ROLLBACK атомарности" "SESSION A" "$LEFT" "Одна успешная операция внутри транзакции откатывается вместе с ошибкой." "BEGIN;
UPDATE accounts SET balance = balance + 50 WHERE id = 2 RETURNING id, owner, balance;
UPDATE accounts SET balance = -1 WHERE id = 2;
ROLLBACK;"
    add_step "Итог accounts" "SESSION A" "$LEFT" "Bob не получил +50 после ROLLBACK." "SELECT id, owner, balance FROM accounts ORDER BY id;"
}

build_demo_4() {
    DEMO_TITLE="масштабируемость и нагрузка"
    LEFT_TITLE="CONSOLE"
    RESET_KIND="load"
    add_step "PgBouncer pools" "CONSOLE" "$LEFT" "Показываем pooler перед нагрузкой." "/demo/scripts/pgbouncer_pools.sh"
    add_step "pgbench: 1 client" "CONSOLE" "$LEFT" "Базовая latency/TPS при одном клиенте." "pgbench -n -c 1 -T \"\$PGBENCH_TIME\" \"\$BENCH_URL\""
    add_step "pgbench: 20 clients" "CONSOLE" "$LEFT" "Смотрим рост конкуренции." "pgbench -n -c 20 -T \"\$PGBENCH_TIME\" \"\$BENCH_URL\""
    add_step "pgbench: 80 clients" "CONSOLE" "$LEFT" "Смотрим latency и saturation." "pgbench -n -c 80 -T \"\$PGBENCH_TIME\" \"\$BENCH_URL\""
    add_step "Hot row contention" "CONSOLE" "$LEFT" "Все клиенты обновляют одну строку, появляется очередь блокировок." "psql -X -P pager=off \"\$DEMO_DIRECT_URL\" -c \"UPDATE hot_rows SET counter = 0;\"
pgbench -n -c 20 -T \"\$PGBENCH_TIME\" -f /demo/sql/pgbench_hot_row.sql \"\$DEMO_WRITE_URL\""
    add_step "Random row updates" "CONSOLE" "$LEFT" "Обновления распределяются по 1000 строкам, contention меньше." "psql -X -P pager=off \"\$DEMO_DIRECT_URL\" -c \"UPDATE hot_rows SET counter = 0;\"
pgbench -n -c 20 -T \"\$PGBENCH_TIME\" -f /demo/sql/pgbench_random_row.sql \"\$DEMO_WRITE_URL\""
}

build_demo_5() {
    DEMO_TITLE="высокая доступность и failover"
    TWO_PANES=1
    CONTROL_HEIGHT=16
    LEFT_TITLE="WRITER"
    RIGHT_TITLE="CONSOLE"
    RESET_KIND="ha"
    add_step "Стартовое состояние" "CONSOLE" "$RIGHT" "Показываем текущий primary и replicas." "patronictl -c /demo/config/patronictl.yml list"
    add_step "Запускаем постоянную запись" "WRITER" "$LEFT" "Слева будет непрерывный writer через PgBouncer write endpoint." "/demo/scripts/demo_ops.sh start-writer && /demo/scripts/demo_ops.sh tail-writer-follow"
    add_step "Останавливаем текущий primary" "CONSOLE" "$RIGHT" "Это реальная остановка контейнера текущего leader. Слева будет видно паузу/ошибки записи." "/demo/scripts/demo_ops.sh stop-current-primary"
    add_step "Ждем нового primary" "CONSOLE" "$RIGHT" "Patroni выбирает нового leader, write endpoint восстанавливается." "/demo/scripts/demo_ops.sh wait-new-primary"
    add_step "Смотрим кластер после failover" "CONSOLE" "$RIGHT" "Новый leader должен быть running." "patronictl -c /demo/config/patronictl.yml list"
    add_step "Последние записи" "CONSOLE" "$RIGHT" "Проверяем, что записи продолжают появляться." "psql -X -P pager=off \"\$DEMO_WRITE_URL\" -c \"SELECT id, created_at FROM ha_demo ORDER BY id DESC LIMIT 5;\""
    add_step "Возвращаем старый primary" "CONSOLE" "$RIGHT" "Старый узел возвращается как replica, writer останавливается." "/demo/scripts/demo_ops.sh restore-old-primary
sleep 8
patronictl -c /demo/config/patronictl.yml list
/demo/scripts/demo_ops.sh stop-writer"
}

build_demo_6() {
    DEMO_TITLE="CAP и потеря quorum etcd"
    LEFT_TITLE="CONSOLE"
    RESET_KIND="ha"
    add_step "Стартовое состояние" "CONSOLE" "$LEFT" "Есть leader и две replicas." "patronictl -c /demo/config/patronictl.yml list"
    add_step "Останавливаем два etcd" "CONSOLE" "$LEFT" "Теряем quorum: etcd-2 и etcd-3 остановлены." "/demo/scripts/demo_ops.sh stop-etcd-quorum"
    add_step "Patroni без quorum" "CONSOLE" "$LEFT" "patronictl может показать ошибки etcd; затем ждем TTL, чтобы кластер осознал потерю leader lock." "patronictl -c /demo/config/patronictl.yml list || true
sleep 14"
    add_step "Пробуем запись" "CONSOLE" "$LEFT" "Ожидаем недоступность или ограничение записи ради защиты от split-brain." "/demo/scripts/demo_ops.sh try-write-after-quorum-loss"
    add_step "Восстанавливаем quorum" "CONSOLE" "$LEFT" "Возвращаем etcd-2 и etcd-3, ждем write endpoint." "/demo/scripts/demo_ops.sh restore-etcd-quorum"
    add_step "Итог после восстановления" "CONSOLE" "$LEFT" "Кластер должен вернуться к leader + replicas." "patronictl -c /demo/config/patronictl.yml list"
}

build_demo_7() {
    DEMO_TITLE="PACELC и свежесть чтения с replica"
    TWO_PANES=1
    CONTROL_HEIGHT=16
    LEFT_TITLE="PRIMARY"
    RIGHT_TITLE="READ / REPLICAS"
    RESET_KIND="pacelc"
    add_step "Стартовое состояние" "PRIMARY" "$LEFT" \
        "Показываем роли узлов." \
        "patronictl -c /demo/config/patronictl.yml list"
    add_step "Patroni maintenance pause" "PRIMARY" "$LEFT" \
        "Отключаем автоматическое управление Patroni на время опыта, чтобы он не снимал WAL replay pause." \
        "patronictl -c /demo/config/patronictl.yml pause --wait pg-ha-demo"
    add_step "Ставим replay на паузу" "PRIMARY" "$LEFT" \
        "На primary WHERE false, на replicas replay ставится на паузу; короткая probe-запись заставляет pause реально зафиксироваться." \
        "for NODE in pg-node-1 pg-node-2 pg-node-3; do
  echo
  echo \"== \$NODE ==\"
  psql -X -P pager=off \"postgresql://postgres:postgres@\${NODE}:5432/demo\" \\
    -c \"SELECT pg_wal_replay_pause() WHERE pg_is_in_recovery();\"
done
psql -X -P pager=off \"\$DEMO_WRITE_URL\" \\
  -c \"INSERT INTO ha_demo(value) VALUES ('pause-probe ' || clock_timestamp());\"
sleep 2"
    add_step "Проверяем replay state" "READ / REPLICAS" "$RIGHT" \
        "Replicas должны быть paused, primary останется primary." \
        "for NODE in pg-node-1 pg-node-2 pg-node-3; do
  echo
  echo \"== \$NODE ==\"
  psql -X -P pager=off \"postgresql://postgres:postgres@\${NODE}:5432/demo\" \\
    -c \"SELECT pg_is_in_recovery() AS is_replica, CASE WHEN pg_is_in_recovery() THEN pg_get_wal_replay_pause_state() ELSE 'primary' END AS replay_state;\"
done"
    add_step "Primary пишет и читает marker" "PRIMARY" "$LEFT" \
        "Создаем marker, пишем через write endpoint и сразу читаем на primary." \
        "MARKER=\"pacelc-\$(date +%s%N)\"
echo \"\$MARKER\" >/tmp/demo_marker
echo \"marker: \$MARKER\"
psql -X -P pager=off \"\$DEMO_WRITE_URL\" \\
  -c \"INSERT INTO ha_demo(value) VALUES ('\$MARKER') RETURNING id, created_at;\" \\
  -c \"SELECT count(*) AS rows_on_primary FROM ha_demo WHERE value = '\$MARKER';\""
    add_step "Read endpoint при paused replay" "READ / REPLICAS" "$RIGHT" \
        "Все replicas на паузе, поэтому read endpoint пока не видит свежую запись." \
        "MARKER=\"\$(cat /tmp/demo_marker)\"
psql -X -P pager=off \"\$DEMO_READ_URL\" \\
  -c \"SELECT inet_server_addr() AS server_addr, pg_is_in_recovery() AS is_replica;\" \\
  -c \"SELECT count(*) AS rows_visible FROM ha_demo WHERE value = '\$MARKER';\""
    add_step "Возобновляем replay" "PRIMARY" "$LEFT" \
        "На primary WHERE false, на replicas replay возобновляется; затем возвращаем Patroni в обычный режим." \
        "for NODE in pg-node-1 pg-node-2 pg-node-3; do
  echo
  echo \"== \$NODE ==\"
  psql -X -P pager=off \"postgresql://postgres:postgres@\${NODE}:5432/demo\" \\
    -c \"SELECT pg_wal_replay_resume() WHERE pg_is_in_recovery();\"
done
sleep 2
patronictl -c /demo/config/patronictl.yml resume --wait pg-ha-demo"
    add_step "Read endpoint после catch-up" "READ / REPLICAS" "$RIGHT" \
        "После resume read endpoint видит marker." \
        "MARKER=\"\$(cat /tmp/demo_marker)\"
psql -X -P pager=off \"\$DEMO_READ_URL\" \\
  -c \"SELECT inet_server_addr() AS server_addr, pg_is_in_recovery() AS is_replica;\" \\
  -c \"SELECT count(*) AS rows_visible FROM ha_demo WHERE value = '\$MARKER';\""
}

"build_demo_${DEMO_ID}"

if [[ -z "${TMUX:-}" ]]; then
    command -v tmux >/dev/null 2>&1 || {
        echo "tmux не найден внутри client-контейнера. Выполните: ./demo.sh up" >&2
        exit 1
    }

    tmux kill-session -t "$SESSION_NAME" >/dev/null 2>&1 || true
    tmux kill-session -t "demo${DEMO_ID}-live" >/dev/null 2>&1 || true
    reset_demo_data

    tmux new-session -d -s "$SESSION_NAME" -n "demo${DEMO_ID}" "$LEFT_CMD"
    left_id="$(tmux display-message -p -t "$SESSION_NAME:0" '#{pane_id}')"

    tmux split-window -v -t "$left_id" -l "$CONTROL_HEIGHT" "bash"
    control_id="$(tmux display-message -p -t "$SESSION_NAME:0" '#{pane_id}')"

    right_id="$left_id"
    if [[ "$TWO_PANES" == "1" ]]; then
        tmux select-pane -t "$left_id"
        tmux split-window -h -t "$left_id" "$RIGHT_CMD"
        right_id="$(tmux display-message -p -t "$SESSION_NAME:0" '#{pane_id}')"
    fi

    tmux select-pane -t "$left_id" -T "$LEFT_TITLE"
    if [[ "$TWO_PANES" == "1" ]]; then
        tmux select-pane -t "$right_id" -T "$RIGHT_TITLE"
    fi
    tmux select-pane -t "$control_id" -T "Управление"
    tmux set-option -t "$SESSION_NAME" mouse on >/dev/null
    tmux set-option -t "$SESSION_NAME" pane-border-status top >/dev/null
    tmux set-option -t "$SESSION_NAME" pane-border-format " #{pane_title} " >/dev/null
    tmux resize-pane -t "$control_id" -y "$CONTROL_HEIGHT"
    tmux send-keys -t "$control_id" \
        "DEMO_LEFT_PANE='$left_id' DEMO_RIGHT_PANE='$right_id' DEMO_CONTROL_PANE='$control_id' bash /demo/scripts/tmux_demo.sh '$DEMO_ID' controller" Enter
    tmux select-pane -t "$control_id"
    tmux attach-session -t "$SESSION_NAME"
    exit 0
fi

case "${2:-}" in
    controller) run_controller ;;
    *) run_controller ;;
esac
