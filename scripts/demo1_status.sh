#!/usr/bin/env bash
set -Eeuo pipefail

source /demo/scripts/lib.sh

section "Demo 1: состояние кластера и маршрутизация"
patroni_list
pause_step

step "Write endpoint должен вести на primary"
psql_demo_write -c "SELECT inet_server_addr() AS server_addr, pg_is_in_recovery() AS is_replica;"
pause_step

step "Read endpoint должен вести на replica"
psql_demo_read -c "SELECT inet_server_addr() AS server_addr, pg_is_in_recovery() AS is_replica;"

section "Вывод"
echo "Приложение подключается к стабильным endpoint'ам, а HAProxy выбирает узел по текущей роли Patroni."
