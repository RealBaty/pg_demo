FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates pgbouncer \
    && useradd -r -g nogroup pgbouncer-runner \
    && rm -rf /var/lib/apt/lists/*

COPY pgbouncer-entrypoint.sh /usr/local/bin/pgbouncer-entrypoint.sh
RUN chmod +x /usr/local/bin/pgbouncer-entrypoint.sh

USER pgbouncer-runner
ENTRYPOINT ["/usr/local/bin/pgbouncer-entrypoint.sh"]
