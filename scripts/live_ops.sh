#!/usr/bin/env bash
set -Eeuo pipefail

source /demo/scripts/lib.sh

PROJECT="${COMPOSE_PROJECT_NAME:-pgha-demo}"
DOCKER_SOCK="${DOCKER_SOCK:-/var/run/docker.sock}"

container_name() {
    printf '%s-%s-1' "$PROJECT" "$1"
}

docker_post() {
    local path="$1"
    curl -fsS --unix-socket "$DOCKER_SOCK" -X POST "http://docker${path}" >/dev/null
}

docker_get() {
    local path="$1"
    curl -fsS --unix-socket "$DOCKER_SOCK" "http://docker${path}"
}

docker_stop_service() {
    local service="$1"
    echo "Stopping ${service}..."
    docker_post "/containers/$(container_name "$service")/stop?t=10" || true
}

docker_start_service() {
    local service="$1"
    echo "Starting ${service}..."
    docker_post "/containers/$(container_name "$service")/start" || true
}

current_primary() {
    patronictl -c "$PATRONICTL_CONFIG" list -f json 2>/dev/null \
        | jq -r '.[] | select(((.Role // "") | ascii_downcase) == "leader" or ((.Role // "") | ascii_downcase) == "primary") | .Member' \
        | head -n 1
}

wait_primary() {
    local primary=""
    for _ in $(seq 1 90); do
        primary="$(current_primary || true)"
        if [[ -n "$primary" && "$primary" != "null" ]]; then
            echo "$primary"
            return 0
        fi
        sleep 2
    done
    echo "Primary did not appear in time." >&2
    return 1
}

wait_write_endpoint() {
    for _ in $(seq 1 60); do
        if psql -X -P pager=off -qAt "$DEMO_WRITE_URL" -c "SELECT pg_is_in_recovery();" 2>/dev/null | grep -qx f; then
            echo "write endpoint is ready"
            return 0
        fi
        sleep 1
    done
    echo "write endpoint did not recover in time" >&2
    return 1
}

start_writer() {
    if [[ -f /tmp/ha_writer.pid ]]; then
        kill "$(cat /tmp/ha_writer.pid)" >/dev/null 2>&1 || true
        rm -f /tmp/ha_writer.pid
    fi
    rm -f /tmp/ha_writer.log
    nohup bash /demo/scripts/ha_writer_loop.sh >/tmp/ha_writer.log 2>&1 &
    echo "$!" >/tmp/ha_writer.pid
    echo "writer started; pid=$(cat /tmp/ha_writer.pid)"
}

stop_writer() {
    if [[ -f /tmp/ha_writer.pid ]]; then
        kill "$(cat /tmp/ha_writer.pid)" >/dev/null 2>&1 || true
        rm -f /tmp/ha_writer.pid
    fi
    pkill -f '[h]a_writer_loop.sh' >/dev/null 2>&1 || true
    echo "writer stopped"
}

tail_writer() {
    test -f /tmp/ha_writer.log && tail -n "${1:-20}" /tmp/ha_writer.log || echo "writer log is empty"
}

tail_writer_follow() {
    touch /tmp/ha_writer.log
    tail -n 20 -f /tmp/ha_writer.log
}

stop_current_primary() {
    local primary
    primary="$(wait_primary)"
    echo "$primary" >/tmp/demo_old_primary
    echo "current primary: $primary"
    docker_stop_service "$primary"
}

wait_new_primary() {
    local old primary
    old="$(cat /tmp/demo_old_primary 2>/dev/null || true)"
    for _ in $(seq 1 60); do
        primary="$(current_primary || true)"
        if [[ -n "$primary" && "$primary" != "null" && "$primary" != "$old" ]]; then
            echo "new primary: $primary"
            wait_write_endpoint
            return 0
        fi
        sleep 2
    done
    echo "new primary did not appear in time" >&2
    return 1
}

restore_old_primary() {
    local old
    old="$(cat /tmp/demo_old_primary 2>/dev/null || true)"
    if [[ -n "$old" ]]; then
        docker_start_service "$old"
    else
        echo "no old primary recorded"
    fi
}

stop_etcd_quorum() {
    docker_stop_service etcd-2
    docker_stop_service etcd-3
}

restore_etcd_quorum() {
    docker_start_service etcd-2
    docker_start_service etcd-3
    wait_primary
    wait_write_endpoint
}

try_write_after_quorum_loss() {
    if PGCONNECT_TIMEOUT=3 timeout 10s psql -X -P pager=off -v ON_ERROR_STOP=1 "$DEMO_WRITE_URL" \
        -c "INSERT INTO ha_demo(value) VALUES ('after etcd quorum loss');"; then
        echo "write passed: фиксируем фактическое поведение стенда"
    else
        echo "write unavailable: кластер ограничил availability ради защиты от split-brain"
    fi
}

case "${1:-}" in
    container-name) container_name "${2:?service required}" ;;
    current-primary) wait_primary ;;
    start-writer) start_writer ;;
    stop-writer) stop_writer ;;
    tail-writer) tail_writer "${2:-20}" ;;
    tail-writer-follow) tail_writer_follow ;;
    stop-current-primary) stop_current_primary ;;
    wait-new-primary) wait_new_primary ;;
    restore-old-primary) restore_old_primary ;;
    stop-etcd-quorum) stop_etcd_quorum ;;
    restore-etcd-quorum) restore_etcd_quorum ;;
    try-write-after-quorum-loss) try_write_after_quorum_loss ;;
    wait-write) wait_write_endpoint ;;
    docker-ping) docker_get "/_ping"; echo ;;
    *)
        echo "Usage: live_ops.sh <command>" >&2
        exit 1
        ;;
esac
