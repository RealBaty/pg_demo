CREATE TABLE IF NOT EXISTS demo_kv (
    key text PRIMARY KEY,
    value text NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS accounts (
    id integer PRIMARY KEY,
    owner text NOT NULL,
    balance integer NOT NULL CHECK (balance >= 0)
);

CREATE TABLE IF NOT EXISTS doctors (
    id integer PRIMARY KEY,
    name text NOT NULL UNIQUE,
    on_call boolean NOT NULL
);

CREATE TABLE IF NOT EXISTS ha_demo (
    id bigserial PRIMARY KEY,
    value text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS hot_rows (
    id integer PRIMARY KEY,
    counter bigint NOT NULL DEFAULT 0
);

INSERT INTO demo_kv(key, value)
VALUES ('isolation', 'initial value')
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value,
    updated_at = now();

INSERT INTO accounts(id, owner, balance)
VALUES
    (1, 'alice', 100),
    (2, 'bob', 100)
ON CONFLICT (id) DO UPDATE
SET owner = EXCLUDED.owner,
    balance = EXCLUDED.balance;

INSERT INTO doctors(id, name, on_call)
VALUES
    (1, 'alice', true),
    (2, 'bob', true)
ON CONFLICT (id) DO UPDATE
SET name = EXCLUDED.name,
    on_call = EXCLUDED.on_call;

INSERT INTO hot_rows(id, counter)
SELECT id, 0
FROM generate_series(1, 1000) AS id
ON CONFLICT (id) DO NOTHING;
