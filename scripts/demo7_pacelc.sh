#!/usr/bin/env bash
set -Eeuo pipefail

source /demo/scripts/lib.sh

section "Demo 7: PACELC через primary vs replica"

replica="$(
    patronictl -c "$PATRONICTL_CONFIG" list -f json \
        | jq -r '.[] | select((.Role == "Replica") or (.Role == "Standby Leader")) | .Member' \
        | head -n 1
)"

if [[ -z "$replica" || "$replica" == "null" ]]; then
    echo "Не нашел replica в patronictl list." >&2
    exit 1
fi

marker="pacelc-$(date +%s)"
replica_url="postgresql://postgres:postgres@${replica}:5432/demo"

step "Используем replica: ${replica}"
psql -X -v ON_ERROR_STOP=1 "$replica_url" -c "SELECT pg_wal_replay_pause();"
pause_step

step "Пишем строку на primary"
psql_demo_write -c "INSERT INTO ha_demo(value) VALUES ('$marker') RETURNING id, value, created_at;"
pause_step

step "Primary видит свежую запись"
psql_demo_write -c "SELECT count(*) AS rows_on_primary FROM ha_demo WHERE value = '$marker';"

step "Paused replica может не видеть свежую запись"
psql -X -v ON_ERROR_STOP=1 "$replica_url" -c "SELECT count(*) AS rows_on_paused_replica FROM ha_demo WHERE value = '$marker';"
pause_step

step "Возобновляем replay и ждем catch-up"
psql -X -v ON_ERROR_STOP=1 "$replica_url" -c "SELECT pg_wal_replay_resume();"

for attempt in $(seq 1 30); do
    rows="$(psql -X -qAt "$replica_url" -c "SELECT count(*) FROM ha_demo WHERE value = '$marker';")"
    if [[ "$rows" == "1" ]]; then
        break
    fi
    sleep 1
done

psql -X -v ON_ERROR_STOP=1 "$replica_url" -c "SELECT count(*) AS rows_after_resume FROM ha_demo WHERE value = '$marker';"

section "Вывод"
echo "В штатном режиме чтение с replica уменьшает нагрузку и задержку для primary, но может уступать чтению с primary по свежести данных."
