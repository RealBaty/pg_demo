#!/usr/bin/env bash
set -Eeuo pipefail

source /demo/scripts/lib.sh

SESSION_NAME="${LIVE_SESSION_NAME:-demo2-live}"
LEFT="${LIVE_LEFT_PANE:-${SESSION_NAME}:0.0}"
RIGHT="${LIVE_RIGHT_PANE:-${SESSION_NAME}:0.1}"
CONTROL="${LIVE_CONTROL_PANE:-${SESSION_NAME}:0.2}"

usage() {
    cat <<'EOF'
Live Demo 2: две реальные psql-сессии + пульт преподавателя.

Управление:
  Enter  выполнить следующий подготовленный шаг
  s      показать SQL следующего шага
  r      reset данных для текущей темы
  q      выйти из live demo

Верхняя левая панель  - SESSION A.
Верхняя правая панель - SESSION B.
Нижняя панель         - пульт с подсказками.
EOF
}

tmux_send_sql() {
    local target="$1"
    local sql="$2"
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s' "$line" | tmux load-buffer -b demo2-live-line -
        tmux paste-buffer -t "$target" -b demo2-live-line
        tmux send-keys -t "$target" Enter
    done <<< "$sql"
}

tmux_send_clear() {
    local target="$1"
    tmux send-keys -t "$target" C-l
}

reset_read_data() {
    psql_demo_direct -qAt -c "UPDATE demo_kv SET value = 'initial value', updated_at = now() WHERE key = 'isolation';" >/dev/null
}

reset_doctors_data() {
    psql_demo_direct -qAt -c "UPDATE doctors SET on_call = true;" >/dev/null
}

print_next() {
    local idx="$1"
    local total="$2"
    local title="$3"
    local target="$4"
    local note="$5"
    local sql="$6"

    clear
    printf 'Live Demo 2: Isolation Levels\n'
    printf 'Step %s/%s\n\n' "$idx" "$total"
    printf '%s\n\n' "$title"
    printf 'Куда отправим: %s\n\n' "$target"
    printf 'Что показать: %s\n\n' "$note"
    printf 'SQL следующего шага:\n'
    printf '%s\n' "$sql" | sed 's/^/    /'
    printf '\nEnter - выполнить | s - SQL | r - reset | q - выйти\n'
}

show_sql_only() {
    local sql="$1"
    printf '\nSQL:\n'
    printf '%s\n' "$sql" | sed 's/^/    /'
}

wait_for_enter() {
    local idx="$1"
    local total="$2"
    local title="$3"
    local target_label="$4"
    local note="$5"
    local sql="$6"
    local reset_kind="$7"
    local answer

    while true; do
        print_next "$idx" "$total" "$title" "$target_label" "$note" "$sql"
        IFS= read -rsn1 answer || answer=""
        case "$answer" in
            "")
                return 0
                ;;
            s|S)
                show_sql_only "$sql"
                printf '\nНажмите любую клавишу...'
                IFS= read -rsn1 _ || true
                ;;
            r|R)
                if [[ "$reset_kind" == "read" ]]; then
                    reset_read_data
                    tmux_send_clear "$LEFT"
                    tmux_send_clear "$RIGHT"
                    tmux_send_sql "$LEFT" "\\echo 'SESSION A готова. Данные сброшены.'"
                    tmux_send_sql "$RIGHT" "\\echo 'SESSION B готова. Данные сброшены.'"
                elif [[ "$reset_kind" == "doctors" ]]; then
                    reset_doctors_data
                    tmux_send_clear "$LEFT"
                    tmux_send_clear "$RIGHT"
                    tmux_send_sql "$LEFT" "\\echo 'SESSION A готова. Doctors reset.'"
                    tmux_send_sql "$RIGHT" "\\echo 'SESSION B готова. Doctors reset.'"
                fi
                ;;
            q|Q)
                tmux kill-session -t "$SESSION_NAME"
                exit 0
                ;;
        esac
    done
}

execute_step() {
    local idx="$1"
    local total="$2"
    local title="$3"
    local target_label="$4"
    local target="$5"
    local note="$6"
    local sql="$7"
    local reset_kind="$8"

    wait_for_enter "$idx" "$total" "$title" "$target_label" "$note" "$sql" "$reset_kind"
    tmux_send_sql "$target" "$sql"
}

run_controller() {
    local total=23
    local n=1

    usage
    printf '\nНажмите Enter, чтобы начать, или q чтобы выйти...'
    IFS= read -rsn1 answer || answer=""
    if [[ "$answer" == "q" || "$answer" == "Q" ]]; then
        tmux kill-session -t "$SESSION_NAME"
        exit 0
    fi

    execute_step "$((n++))" "$total" \
        "READ COMMITTED: подготовка" "SESSION A (служебный reset)" "$LEFT" \
        "Сбросим строку и покажем начальное значение." \
        "UPDATE demo_kv SET value = 'initial value', updated_at = now() WHERE key = 'isolation';
SELECT key, value FROM demo_kv WHERE key = 'isolation';" \
        "read"

    execute_step "$((n++))" "$total" \
        "READ COMMITTED: SESSION A открывает транзакцию" "SESSION A" "$LEFT" \
        "SESSION A начинает транзакцию на READ COMMITTED." \
        "BEGIN ISOLATION LEVEL READ COMMITTED;" \
        "read"

    execute_step "$((n++))" "$total" \
        "READ COMMITTED: первое чтение" "SESSION A" "$LEFT" \
        "SESSION A видит initial value." \
        "SELECT 'A1 first read' AS step, value FROM demo_kv WHERE key = 'isolation';" \
        "read"

    execute_step "$((n++))" "$total" \
        "READ COMMITTED: конкурентное изменение" "SESSION B" "$RIGHT" \
        "SESSION B меняет строку и сразу фиксирует изменение автокоммитом." \
        "UPDATE demo_kv
SET value = 'committed by session B',
    updated_at = now()
WHERE key = 'isolation'
RETURNING 'B update committed' AS step, key, value;" \
        "read"

    execute_step "$((n++))" "$total" \
        "READ COMMITTED: повторное чтение" "SESSION A" "$LEFT" \
        "В READ COMMITTED новый SELECT получает новый committed snapshot." \
        "SELECT 'A2 second read after B commit' AS step, value FROM demo_kv WHERE key = 'isolation';" \
        "read"

    execute_step "$((n++))" "$total" \
        "READ COMMITTED: завершение" "SESSION A" "$LEFT" \
        "Закрываем транзакцию." \
        "COMMIT;" \
        "read"

    execute_step "$((n++))" "$total" \
        "REPEATABLE READ: подготовка" "SESSION A (служебный reset)" "$LEFT" \
        "Возвращаем initial value перед новым сценарием." \
        "UPDATE demo_kv SET value = 'initial value', updated_at = now() WHERE key = 'isolation';
SELECT key, value FROM demo_kv WHERE key = 'isolation';" \
        "read"

    execute_step "$((n++))" "$total" \
        "REPEATABLE READ: SESSION A открывает транзакцию" "SESSION A" "$LEFT" \
        "SESSION A начинает транзакцию на REPEATABLE READ." \
        "BEGIN ISOLATION LEVEL REPEATABLE READ;" \
        "read"

    execute_step "$((n++))" "$total" \
        "REPEATABLE READ: первое чтение" "SESSION A" "$LEFT" \
        "SESSION A видит initial value и фиксирует snapshot транзакции." \
        "SELECT 'A1 first read' AS step, value FROM demo_kv WHERE key = 'isolation';" \
        "read"

    execute_step "$((n++))" "$total" \
        "REPEATABLE READ: конкурентное изменение" "SESSION B" "$RIGHT" \
        "SESSION B меняет строку и фиксирует изменение." \
        "UPDATE demo_kv
SET value = 'committed by session B',
    updated_at = now()
WHERE key = 'isolation'
RETURNING 'B update committed' AS step, key, value;" \
        "read"

    execute_step "$((n++))" "$total" \
        "REPEATABLE READ: повторное чтение" "SESSION A" "$LEFT" \
        "SESSION A продолжает видеть initial value, потому что snapshot транзакции не меняется." \
        "SELECT 'A2 second read after B commit' AS step, value FROM demo_kv WHERE key = 'isolation';" \
        "read"

    execute_step "$((n++))" "$total" \
        "REPEATABLE READ: проверка из SESSION B" "SESSION B" "$RIGHT" \
        "SESSION B вне транзакции видит новое committed value." \
        "SELECT 'B sees current committed value' AS step, value FROM demo_kv WHERE key = 'isolation';" \
        "read"

    execute_step "$((n++))" "$total" \
        "REPEATABLE READ: завершение" "SESSION A" "$LEFT" \
        "Закрываем транзакцию." \
        "COMMIT;" \
        "read"

    execute_step "$((n++))" "$total" \
        "SERIALIZABLE: подготовка" "SESSION A" "$LEFT" \
        "Сбрасываем doctors: Alice и Bob оба дежурят." \
        "UPDATE doctors SET on_call = true;
SELECT id, name, on_call FROM doctors ORDER BY id;" \
        "doctors"

    execute_step "$((n++))" "$total" \
        "SERIALIZABLE: SESSION A начинает транзакцию" "SESSION A" "$LEFT" \
        "Alice будет пытаться снять себя с дежурства." \
        "BEGIN ISOLATION LEVEL SERIALIZABLE;" \
        "doctors"

    execute_step "$((n++))" "$total" \
        "SERIALIZABLE: SESSION B начинает транзакцию" "SESSION B" "$RIGHT" \
        "Bob будет пытаться снять себя с дежурства." \
        "BEGIN ISOLATION LEVEL SERIALIZABLE;" \
        "doctors"

    execute_step "$((n++))" "$total" \
        "SERIALIZABLE: SESSION A проверяет правило" "SESSION A" "$LEFT" \
        "SESSION A видит двух дежурных врачей." \
        "SELECT 'A sees on_call doctors' AS step, count(*) AS on_call_count FROM doctors WHERE on_call;" \
        "doctors"

    execute_step "$((n++))" "$total" \
        "SERIALIZABLE: SESSION B проверяет правило" "SESSION B" "$RIGHT" \
        "SESSION B тоже видит двух дежурных врачей." \
        "SELECT 'B sees on_call doctors' AS step, count(*) AS on_call_count FROM doctors WHERE on_call;" \
        "doctors"

    execute_step "$((n++))" "$total" \
        "SERIALIZABLE: Alice снимает себя" "SESSION A" "$LEFT" \
        "SESSION A меняет Alice, но пока не коммитит." \
        "UPDATE doctors
SET on_call = false
WHERE name = 'alice'
RETURNING 'A sets alice off call' AS step, name, on_call;" \
        "doctors"

    execute_step "$((n++))" "$total" \
        "SERIALIZABLE: Bob снимает себя" "SESSION B" "$RIGHT" \
        "SESSION B меняет Bob, но пока не коммитит." \
        "UPDATE doctors
SET on_call = false
WHERE name = 'bob'
RETURNING 'B sets bob off call' AS step, name, on_call;" \
        "doctors"

    execute_step "$((n++))" "$total" \
        "SERIALIZABLE: первый COMMIT" "SESSION A" "$LEFT" \
        "Одна транзакция обычно коммитится успешно." \
        "COMMIT;" \
        "doctors"

    execute_step "$((n++))" "$total" \
        "SERIALIZABLE: второй COMMIT" "SESSION B" "$RIGHT" \
        "Вторая транзакция должна получить serialization failure. Это ожидаемый результат." \
        "COMMIT;" \
        "doctors"

    execute_step "$((n++))" "$total" \
        "SERIALIZABLE: финальное состояние" "SESSION A" "$LEFT" \
        "Проверяем, что минимум один врач остался дежурить." \
        "SELECT id, name, on_call FROM doctors ORDER BY id;" \
        "doctors"

    clear
    cat <<'EOF'
Live Demo 2 завершена.

Главные выводы:
  READ COMMITTED  - каждый SELECT внутри транзакции берет новый committed snapshot.
  REPEATABLE READ - транзакция держит один snapshot до COMMIT.
  SERIALIZABLE    - PostgreSQL может отменить транзакцию, чтобы сохранить корректность конкурентного выполнения.

Нажмите q, чтобы закрыть tmux session.
EOF
    while true; do
        IFS= read -rsn1 answer || answer=""
        [[ "$answer" == "q" || "$answer" == "Q" ]] && break
    done
    tmux kill-session -t "$SESSION_NAME"
}

if [[ -z "${TMUX:-}" ]]; then
    command -v tmux >/dev/null 2>&1 || {
        echo "tmux не найден внутри client-контейнера. Выполните: ./demo.sh up" >&2
        exit 1
    }

    tmux kill-session -t "$SESSION_NAME" >/dev/null 2>&1 || true
    reset_read_data
    reset_doctors_data

    tmux new-session -d -s "$SESSION_NAME" -n demo2 "psql -X '$DEMO_DIRECT_URL'"
    left_id="$(tmux display-message -p -t "$SESSION_NAME:0" '#{pane_id}')"

    tmux split-window -v -t "$left_id" -l 15 "bash"
    control_id="$(tmux display-message -p -t "$SESSION_NAME:0" '#{pane_id}')"

    tmux select-pane -t "$left_id"
    tmux split-window -h -t "$left_id" "psql -X '$DEMO_DIRECT_URL'"
    right_id="$(tmux display-message -p -t "$SESSION_NAME:0" '#{pane_id}')"

    tmux select-pane -t "$left_id" -T "SESSION A"
    tmux select-pane -t "$right_id" -T "SESSION B"
    tmux select-pane -t "$control_id" -T "Пульт"
    tmux set-option -t "$SESSION_NAME" pane-border-status top >/dev/null
    tmux set-option -t "$SESSION_NAME" pane-border-format " #{pane_title} " >/dev/null
    tmux resize-pane -t "$control_id" -y 15
    tmux send-keys -t "$control_id" \
        "LIVE_LEFT_PANE='$left_id' LIVE_RIGHT_PANE='$right_id' LIVE_CONTROL_PANE='$control_id' bash /demo/scripts/live2_tmux.sh controller" C-m
    tmux select-pane -t "$control_id"
    tmux attach-session -t "$SESSION_NAME"
    exit 0
fi

case "${1:-}" in
    controller) run_controller ;;
    *) run_controller ;;
esac
