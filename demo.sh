#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

load_env_defaults() {
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" == *"="* ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        if [[ -z "${!key+x}" ]]; then
            export "${key}=${value}"
        fi
    done < .env
}

if [[ -f .env ]]; then
    load_env_defaults
fi

COMPOSE=(docker compose)
if [[ -f .env ]]; then
    COMPOSE+=(--env-file .env)
fi

section() {
    printf '\n== %s ==\n' "$1"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

check_docker() {
    command -v docker >/dev/null 2>&1 || die "Docker CLI не найден. Для стенда нужен Docker/Docker Compose."
    docker compose version >/dev/null 2>&1 || die "Docker Compose v2 не найден."
    docker info >/dev/null 2>&1 || die "Docker daemon недоступен. Запустите Docker Desktop и повторите команду."
}

confirm() {
    local prompt="$1"
    if [[ "${DEMO_YES:-0}" == "1" ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        die "Нужно подтверждение: ${prompt}. Запустите интерактивно или задайте DEMO_YES=1."
    fi
    local answer
    read -r -p "${prompt} [y/N] " answer
    case "$answer" in
        y|Y|yes|YES|Yes|д|да|Да|ДА) return 0 ;;
        *) return 1 ;;
    esac
}

compose_exec_flags() {
    if [[ -t 0 && "${DEMO_TTY:-1}" == "1" ]]; then
        return 0
    fi
    printf '%s\n' "-T"
}

client_env_args() {
    printf '%s\n' \
        "-e" "PGBENCH_TIME=${PGBENCH_TIME:-20}" \
        "-e" "PGBENCH_SCALE=${PGBENCH_SCALE:-5}" \
        "-e" "DEMO_PAUSE=${DEMO_PAUSE:-1}"
}

run_client_script() {
    local flags=()
    while IFS= read -r flag; do
        [[ -n "$flag" ]] && flags+=("$flag")
    done < <(compose_exec_flags)
    while IFS= read -r flag; do
        [[ -n "$flag" ]] && flags+=("$flag")
    done < <(client_env_args)
    "${COMPOSE[@]}" exec "${flags[@]}" client bash "/demo/$1"
}

run_client_cmd() {
    local flags=("-T")
    while IFS= read -r flag; do
        [[ -n "$flag" ]] && flags+=("$flag")
    done < <(client_env_args)
    "${COMPOSE[@]}" exec "${flags[@]}" client bash -lc "$1"
}

current_primary() {
    run_client_cmd "patronictl -c /demo/config/patronictl.yml list -f json 2>/dev/null | jq -r '.[] | select(((.Role // \"\") | ascii_downcase) == \"leader\" or ((.Role // \"\") | ascii_downcase) == \"primary\") | .Member' | head -n 1" \
        | tr -d '\r'
}

wait_for_primary() {
    local primary=""
    for _ in $(seq 1 90); do
        primary="$(current_primary || true)"
        if [[ -n "$primary" && "$primary" != "null" ]]; then
            echo "$primary"
            return 0
        fi
        sleep 2
    done
    return 1
}

wait_for_primary_change() {
    local old_primary="$1"
    local primary=""
    for _ in $(seq 1 60); do
        primary="$(current_primary || true)"
        if [[ -n "$primary" && "$primary" != "null" && "$primary" != "$old_primary" ]]; then
            echo "$primary"
            return 0
        fi
        sleep 2
    done
    return 1
}

wait_for_write_endpoint() {
    for _ in $(seq 1 60); do
        if run_client_cmd "psql -X -qAt \"\$DEMO_WRITE_URL\" -c 'SELECT pg_is_in_recovery();' | grep -qx f" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

start_ha_writer() {
    run_client_cmd "if [ -f /tmp/ha_writer.pid ]; then kill \"\$(cat /tmp/ha_writer.pid)\" >/dev/null 2>&1 || true; fi; rm -f /tmp/ha_writer.log /tmp/ha_writer.pid; nohup bash /demo/scripts/ha_writer_loop.sh >/tmp/ha_writer.log 2>&1 & echo \$! >/tmp/ha_writer.pid"
}

stop_ha_writer() {
    run_client_cmd "if [ -f /tmp/ha_writer.pid ]; then kill \"\$(cat /tmp/ha_writer.pid)\" >/dev/null 2>&1 || true; rm -f /tmp/ha_writer.pid; fi; pkill -f '[h]a_writer_loop.sh' >/dev/null 2>&1 || true"
}

tail_ha_writer() {
    run_client_cmd "test -f /tmp/ha_writer.log && tail -n ${1:-12} /tmp/ha_writer.log || true"
}

cmd_up() {
    check_docker
    section "Starting fully containerized demo stack"
    "${COMPOSE[@]}" up -d --build

    section "Waiting for Patroni primary"
    local primary
    primary="$(wait_for_primary)" || die "Patroni primary did not appear in time."
    echo "Current primary: ${primary}"

    run_client_script scripts/bootstrap.sh
    run_client_script scripts/status.sh

    section "Endpoints"
    echo "Write HAProxy:      localhost:${WRITE_PORT:-15000}"
    echo "Read HAProxy:       localhost:${READ_PORT:-15001}"
    echo "HAProxy stats:      http://localhost:${HAPROXY_STATS_PORT:-17000}/"
    echo "PgBouncer write:    localhost:${PGBOUNCER_WRITE_PORT:-16432}"
    echo "PgBouncer read:     localhost:${PGBOUNCER_READ_PORT:-16433}"
}

cmd_down() {
    check_docker
    section "Stopping demo stack"
    "${COMPOSE[@]}" down
}

cmd_reset() {
    check_docker
    confirm "Остановить стенд и удалить Docker volumes с данными demo-кластера?" || die "Reset отменен."
    section "Resetting demo stack and volumes"
    "${COMPOSE[@]}" down -v --remove-orphans
}

cmd_status() {
    check_docker
    run_client_script scripts/status.sh
}

cmd_live() {
    check_docker
    if [[ ! -t 0 ]]; then
        die "Live demo нужен интерактивный терминал."
    fi

    case "${1:-}" in
        2)
            local flags=()
            while IFS= read -r flag; do
                [[ -n "$flag" ]] && flags+=("$flag")
            done < <(client_env_args)
            "${COMPOSE[@]}" exec "${flags[@]}" client bash /demo/scripts/live2_tmux.sh
            ;;
        *)
            die "Unknown live demo: ${1:-}. Сейчас доступно только: ./demo.sh live 2"
            ;;
    esac
}

demo_failover() {
    check_docker
    section "Demo 5: высокая доступность и failover"

    local old_primary="" new_primary=""
    cleanup_failover() {
        stop_ha_writer >/dev/null 2>&1 || true
        if [[ -n "$old_primary" ]]; then
            "${COMPOSE[@]}" start "$old_primary" >/dev/null 2>&1 || true
        fi
    }
    trap cleanup_failover EXIT

    old_primary="$(wait_for_primary)" || die "Не найден текущий primary."
    echo "Current primary: ${old_primary}"

    section "Starting write-loop through common endpoint"
    start_ha_writer
    sleep 4
    tail_ha_writer 10

    confirm "Остановить текущий primary ${old_primary} для демонстрации failover?" || die "Failover demo отменена."

    section "Stopping ${old_primary}"
    "${COMPOSE[@]}" stop "$old_primary"

    section "Waiting for new primary"
    new_primary="$(wait_for_primary_change "$old_primary")" || die "Новый primary не появился в ожидаемое время."
    echo "New primary: ${new_primary}"

    section "Waiting for write endpoint to recover"
    wait_for_write_endpoint || die "Write endpoint не восстановился после failover."

    section "Cluster status after failover"
    run_client_script scripts/status.sh

    section "Writer log around failover"
    tail_ha_writer 20

    section "Recent HA writes"
    run_client_cmd "psql -X -v ON_ERROR_STOP=1 \"\$DEMO_WRITE_URL\" -c \"SELECT id, value, created_at FROM ha_demo ORDER BY id DESC LIMIT 5;\""

    section "Starting old primary back as a replica"
    "${COMPOSE[@]}" start "$old_primary"
    sleep 8
    run_client_script scripts/status.sh

    stop_ha_writer
    trap - EXIT

    section "Вывод"
    echo "После короткого разрыва Patroni выбрал новый primary, а запись продолжилась через тот же endpoint."
}

demo_cap() {
    check_docker
    section "Demo 6: CAP через потерю quorum в etcd"

    wait_for_primary >/dev/null || die "Не найден primary перед CAP demo."
    run_client_script scripts/status.sh

    confirm "Остановить etcd-2 и etcd-3, чтобы потерять quorum?" || die "CAP demo отменена."

    restore_etcd() {
        "${COMPOSE[@]}" start etcd-2 etcd-3 >/dev/null 2>&1 || true
    }
    trap 'restore_etcd' EXIT

    section "Stopping two etcd nodes"
    "${COMPOSE[@]}" stop etcd-2 etcd-3

    section "Patroni view after quorum loss"
    set +e
    run_client_script scripts/status.sh
    set -e

    section "Waiting past Patroni TTL"
    sleep 14

    section "Trying write through common endpoint"
    set +e
    run_client_cmd "PGCONNECT_TIMEOUT=3 timeout 10s psql -X -v ON_ERROR_STOP=1 \"\$DEMO_WRITE_URL\" -c \"INSERT INTO ha_demo(value) VALUES ('after etcd quorum loss');\""
    local write_rc=$?
    set -e
    if (( write_rc == 0 )); then
        echo "Запись прошла: фиксируем фактическое поведение стенда до истечения/после восстановления lock."
    else
        echo "Запись недоступна: кластер ограничил availability, чтобы не рисковать split-brain."
    fi

    section "Restoring etcd quorum"
    restore_etcd
    trap - EXIT
    wait_for_primary >/dev/null || die "Primary не восстановился после возврата quorum."
    section "Waiting for write endpoint to recover"
    wait_for_write_endpoint || die "Write endpoint не восстановился после возврата quorum."
    sleep 8
    run_client_script scripts/status.sh

    section "Вывод"
    echo "При проблемах с quorum система выбирает консистентность лидерства, даже если запись временно теряет доступность."
}

run_demo() {
    case "${1:-}" in
        1) run_client_script scripts/demo1_status.sh ;;
        2) run_client_script scripts/demo2_isolation.sh ;;
        3) run_client_script scripts/demo3_locks.sh ;;
        4) run_client_script scripts/demo4_load.sh ;;
        5) demo_failover ;;
        6) demo_cap ;;
        7) run_client_script scripts/demo7_pacelc.sh ;;
        *) die "Unknown demo number: ${1:-}. Use 1..7." ;;
    esac
}

cmd_all() {
    cmd_up
    for demo in 1 2 3 4 5 6 7; do
        run_demo "$demo"
    done
}

print_help() {
    cat <<'EOF'
PostgreSQL HA Demo

Usage:
  ./demo.sh                 interactive menu
  ./demo.sh up              build/start stack, bootstrap demo DB
  ./demo.sh status          Patroni, endpoints, PgBouncer pools
  ./demo.sh demo <1..7>     run a single demo
  ./demo.sh live 2          run interactive two-session isolation demo
  ./demo.sh all             run full class flow
  ./demo.sh down            stop containers, keep volumes
  ./demo.sh reset           stop containers and delete volumes

Useful env:
  DEMO_PAUSE=0              skip step pauses
  DEMO_YES=1                auto-confirm failover/CAP/reset prompts
  PGBENCH_TIME=5            shorten load tests
EOF
}

menu() {
    while true; do
        cat <<'EOF'

PostgreSQL HA Demo
1) up
2) status
3) demo 1: cluster state and routing
4) demo 2: isolation levels
L) live 2: interactive isolation demo
5) demo 3: locks and consistency
6) demo 4: scale and load
7) demo 5: HA failover
8) demo 6: CAP quorum loss
9) demo 7: PACELC replica freshness
a) all
d) down
r) reset
q) quit
EOF
        read -r -p "Выбор: " choice
        case "$choice" in
            1) cmd_up ;;
            2) cmd_status ;;
            3) run_demo 1 ;;
            4) run_demo 2 ;;
            l|L) cmd_live 2 ;;
            5) run_demo 3 ;;
            6) run_demo 4 ;;
            7) run_demo 5 ;;
            8) run_demo 6 ;;
            9) run_demo 7 ;;
            a|A) cmd_all ;;
            d|D) cmd_down ;;
            r|R) cmd_reset ;;
            q|Q) exit 0 ;;
            *) echo "Неизвестный пункт." ;;
        esac
    done
}

case "${1:-}" in
    "") menu ;;
    up) cmd_up ;;
    status) cmd_status ;;
    demo) run_demo "${2:-}" ;;
    live) cmd_live "${2:-}" ;;
    all) cmd_all ;;
    down) cmd_down ;;
    reset) cmd_reset ;;
    help|-h|--help) print_help ;;
    *) print_help; exit 1 ;;
esac
