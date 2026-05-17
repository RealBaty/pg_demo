# PostgreSQL HA Demo

Полностью контейнеризированный стенд для демонстрации PostgreSQL в HA-кластере: Patroni, etcd, HAProxy, PgBouncer, транзакции, уровни изоляции, блокировки, нагрузка, failover, CAP и PACELC.

На хост не нужно ставить `psql`, `pgbench`, `patronictl`, Python, Ansible или PostgreSQL packages. Нужны только Docker и Docker Compose v2.

## Быстрый старт

```bash
./demo.sh up
./demo.sh
```

`reset` удаляет Docker volumes стенда. Это полный сброс данных кластера.

## Endpoints

| Назначение | Endpoint |
| --- | --- |
| HAProxy write/primary | `localhost:15000` |
| HAProxy read/replicas | `localhost:15001` |
| HAProxy stats | `http://localhost:17000/` |
| PgBouncer write | `localhost:16432` |
| PgBouncer read | `localhost:16433` |

Порты можно поменять в `.env`, если на хосте они заняты.

Демо-пользователи:

| User | Password | Databases |
| --- | --- | --- |
| `postgres` | `postgres` | admin |
| `demo` | `demo` | `demo`, `bench` |

## Состав стенда

- 3 PostgreSQL 16 узла под Patroni: `pg-node-1`, `pg-node-2`, `pg-node-3`.
- 3 etcd узла: `etcd-1`, `etcd-2`, `etcd-3`.
- HAProxy для role-based routing.
- Два PgBouncer endpoint'а: write и read.
- `client` контейнер со всеми утилитами: `psql`, `pgbench`, `patronictl`, `jq`, `tmux`.

Runtime-данные лежат в Docker volumes. Конфиги, SQL и demo-скрипты лежат в проекте.

Для сценариев failover/CAP `client`-контейнер получает доступ к Docker socket и управляет только контейнерами этого demo-стенда через Docker API. Docker CLI внутри контейнера и дополнительные зависимости на хосте не нужны.


## Полезные настройки

Сократить нагрузочные тесты:

```bash
PGBENCH_TIME=5 ./demo.sh demo 4
```

Автоматически подтверждать reset:

```bash
DEMO_YES=1 ./demo.sh reset
```

## Troubleshooting

Если Docker daemon не запущен:

```text
ERROR: Docker daemon недоступен. Запустите Docker Desktop и повторите команду.
```

Если заняты порты `15000`, `15001`, `17000`, `16432` или `16433`, поменяйте значения в `.env` и выполните:

```bash
./demo.sh down
./demo.sh up
```

Если кластер хочется полностью пересоздать:

```bash
./demo.sh reset
./demo.sh up
```

Первый запуск скачивает Docker-образы и собирает два локальных образа. Это может занять несколько минут.
