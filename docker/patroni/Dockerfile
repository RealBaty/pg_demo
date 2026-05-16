FROM postgres:16-bookworm

ENV PATH="/usr/lib/postgresql/16/bin:${PATH}" \
    PIP_BREAK_SYSTEM_PACKAGES=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        jq \
        procps \
        python3-pip \
        python3-psycopg2 \
        tmux \
    && pip3 install --no-cache-dir "patroni[etcd]==3.3.7" \
    && rm -rf /var/lib/apt/lists/*

COPY patroni-entrypoint.sh /usr/local/bin/patroni-entrypoint.sh
RUN chmod +x /usr/local/bin/patroni-entrypoint.sh
