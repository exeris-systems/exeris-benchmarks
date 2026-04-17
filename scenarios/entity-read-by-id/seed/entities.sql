-- schema_migration_version: V1 | seed_manifest_version: 1 | entity_count: 1000 | user_count: 1000
-- idempotency: ON CONFLICT (...) DO UPDATE / DO NOTHING (safe to re-run)

CREATE TABLE IF NOT EXISTS users (
    id         BIGINT PRIMARY KEY,
    username   TEXT NOT NULL,
    bio        TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS interests (
    id       BIGINT PRIMARY KEY,
    name     TEXT NOT NULL,
    category TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS friendships (
    user_id        BIGINT NOT NULL,
    friend_user_id BIGINT NOT NULL,
    PRIMARY KEY (user_id, friend_user_id),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (friend_user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS user_interests (
    user_id     BIGINT NOT NULL,
    interest_id BIGINT NOT NULL,
    PRIMARY KEY (user_id, interest_id),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (interest_id) REFERENCES interests(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS entities (
    id         BIGINT PRIMARY KEY,
    name       TEXT NOT NULL,
    type       TEXT NOT NULL,
    payload    TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO users (id, username, bio, created_at)
SELECT
    gs,
    'benchmark-user-' || gs,
    'seed-bio-' || gs,
    '2026-01-01T00:00:00Z'::timestamptz + make_interval(secs => gs)
FROM generate_series(1, 1000) AS gs
ON CONFLICT (id) DO UPDATE SET
    username = EXCLUDED.username,
    bio = EXCLUDED.bio,
    created_at = EXCLUDED.created_at;

INSERT INTO interests (id, name, category)
SELECT
    gs,
    'interest-' || gs,
    CASE (gs % 5)
      WHEN 0 THEN 'tech'
      WHEN 1 THEN 'sport'
      WHEN 2 THEN 'music'
      WHEN 3 THEN 'travel'
      ELSE 'science'
    END
FROM generate_series(1, 200) AS gs
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    category = EXCLUDED.category;

INSERT INTO friendships (user_id, friend_user_id)
SELECT
    u.id,
    ((u.id + rel.offset - 1) % 1000) + 1 AS friend_user_id
FROM users u
CROSS JOIN (SELECT generate_series(1, 10) AS offset) rel
WHERE u.id BETWEEN 1 AND 1000
ON CONFLICT (user_id, friend_user_id) DO NOTHING;

INSERT INTO user_interests (user_id, interest_id)
SELECT
    u.id,
    ((u.id * 13 + rel.offset - 1) % 200) + 1 AS interest_id
FROM users u
CROSS JOIN (SELECT generate_series(1, 10) AS offset) rel
WHERE u.id BETWEEN 1 AND 1000
ON CONFLICT (user_id, interest_id) DO NOTHING;

INSERT INTO entities (id, name, type, payload, created_at)
SELECT
    u.id,
    u.username,
    'user',
    u.bio,
    u.created_at
FROM users u
WHERE u.id BETWEEN 1 AND 1000
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    type = EXCLUDED.type,
    payload = EXCLUDED.payload,
    created_at = EXCLUDED.created_at;
