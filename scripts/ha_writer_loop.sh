#!/usr/bin/env bash
set -Eeuo pipefail

source /demo/scripts/lib.sh

echo "HA writer loop started at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
while true; do
    if psql -X -P pager=off -v ON_ERROR_STOP=1 "$DEMO_WRITE_URL" -qAt -c "INSERT INTO ha_demo(value) VALUES ('tick ' || clock_timestamp()) RETURNING id, created_at;" 2>&1; then
        echo "write ok"
    else
        echo "write failed; retrying"
    fi
    sleep 1
done
