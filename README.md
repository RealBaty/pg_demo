# PostgreSQL HA Demo

Полностью контейнеризированный стенд для демонстрации PostgreSQL в HA-кластере: Patroni, etcd, HAProxy, PgBouncer, транзакции, уровни изоляции, блокировки, нагрузка, failover, CAP и PACELC.

На хост не нужно ставить `psql`, `pgbench`, `patronictl`, Python, Ansible или PostgreSQL packages. Нужны только Docker и Docker Compose v2.

## Быстрый старт

```bash
./demo.sh up
./demo.sh demo 1
```

Основной режим:

```bash
./demo.sh
```

Команды:

```bash
./demo.sh status
./demo.sh demo 2
./demo.sh live 2
./demo.sh all
./demo.sh down
./demo.sh reset
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

## Демонстрации

```bash
./demo.sh demo 1
```

Состояние кластера, текущий primary, replicas, write/read routing через endpoints.

```bash
./demo.sh demo 2
```

READ COMMITTED, REPEATABLE READ и SERIALIZABLE. Скрипт показывает две параллельные сессии и ожидаемый serialization failure.

Для более живого показа есть интерактивный режим:

```bash
./demo.sh live 2
```

Он открывает `tmux` внутри `client`-контейнера: сверху две реальные `psql`-сессии `SESSION A` и `SESSION B`, снизу пульт преподавателя. Нажимайте `Enter`, чтобы выполнить следующий подготовленный SQL в нужной сессии; `s` показывает SQL еще раз, `r` сбрасывает данные текущей темы, `q` закрывает live demo.

```bash
./demo.sh demo 3
```

Row lock wait, `pg_stat_activity`, `CHECK` constraint и `ROLLBACK`.

```bash
./demo.sh demo 4
```

`SHOW POOLS`, затем `pgbench -c 1`, `-c 20`, `-c 80`, hot row contention и random row updates.

```bash
./demo.sh demo 5
```

Failover: запускается постоянная запись, затем с подтверждением останавливается текущий primary. Скрипт ждет нового leader, показывает последние записи и возвращает старый узел.

```bash
./demo.sh demo 6
```

CAP: с подтверждением останавливаются два etcd-узла, теряется quorum, проверяется состояние Patroni и возможность записи. Затем quorum восстанавливается.

```bash
./demo.sh demo 7
```

PACELC: replay на одной replica ставится на паузу, запись появляется на primary, но не сразу видна на paused replica. После resume replica догоняет primary.

## Полезные настройки

Сократить нагрузочные тесты:

```bash
PGBENCH_TIME=5 ./demo.sh demo 4
```

Запустить без пауз:

```bash
DEMO_PAUSE=0 ./demo.sh demo 2
```

Автоматически подтверждать failover/CAP/reset:

```bash
DEMO_YES=1 ./demo.sh all
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
