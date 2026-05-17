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

cmd_demo_session() {
    check_docker
    if [[ ! -t 0 ]]; then
        die "Demo нужен интерактивный терминал."
    fi

    [[ "${1:-}" =~ ^[1-7]$ ]] || die "Unknown demo: ${1:-}. Use 1..7."

    local flags=()
    while IFS= read -r flag; do
        [[ -n "$flag" ]] && flags+=("$flag")
    done < <(client_env_args)
    "${COMPOSE[@]}" exec "${flags[@]}" client bash /demo/scripts/tmux_demo.sh "$1"
}

run_demo() {
    cmd_demo_session "${1:-}"
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
  ./demo.sh all             run all demos one by one
  ./demo.sh down            stop containers, keep volumes
  ./demo.sh reset           stop containers and delete volumes

Useful env:
  DEMO_YES=1                auto-confirm reset prompt
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
    live) cmd_demo_session "${2:-}" ;;
    all) cmd_all ;;
    down) cmd_down ;;
    reset) cmd_reset ;;
    help|-h|--help) print_help ;;
    *) print_help; exit 1 ;;
esac
