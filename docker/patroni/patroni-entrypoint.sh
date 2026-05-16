#!/usr/bin/env bash
set -euo pipefail

: "${PATRONI_NAME:?PATRONI_NAME is required}"
: "${PATRONI_SCOPE:=pg-ha-demo}"
: "${PATRONI_ETCD_HOSTS:=etcd-1:2379,etcd-2:2379,etcd-3:2379}"
: "${PGDATA:=/var/lib/postgresql/data}"

mkdir -p "$PGDATA" /var/run/postgresql
chown -R postgres:postgres "$PGDATA" /var/run/postgresql
chmod 700 "$PGDATA"

cat > /tmp/patroni.yml <<EOF
scope: ${PATRONI_SCOPE}
namespace: /service/
name: ${PATRONI_NAME}

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${PATRONI_NAME}:8008

etcd:
  hosts: ${PATRONI_ETCD_HOSTS}

bootstrap:
  dcs:
    ttl: 10
    loop_wait: 2
    retry_timeout: 5
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        hot_standby: "on"
        max_connections: 200
        max_locks_per_transaction: 128
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 128MB
        wal_level: replica
        wal_log_hints: "on"
  initdb:
    - encoding: UTF8
    - locale: C.UTF-8
    - data-checksums
  pg_hba:
    - local all all trust
    - host all all 0.0.0.0/0 md5
    - host replication replicator 0.0.0.0/0 md5
  users:
    admin:
      password: admin
      options:
        - createrole
        - createdb

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${PATRONI_NAME}:5432
  data_dir: ${PGDATA}
  bin_dir: /usr/lib/postgresql/16/bin
  pgpass: /tmp/pgpass
  authentication:
    superuser:
      username: postgres
      password: postgres
    replication:
      username: replicator
      password: replicator
    rewind:
      username: postgres
      password: postgres
  parameters:
    unix_socket_directories: /var/run/postgresql

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
EOF

chown postgres:postgres /tmp/patroni.yml
exec gosu postgres patroni /tmp/patroni.yml
