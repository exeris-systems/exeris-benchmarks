-- migration: v1_core
-- tables: users, interests, friendships, user_interests, entities
-- idempotency: CREATE TABLE IF NOT EXISTS + ON CONFLICT DO NOTHING / DO UPDATE

BEGIN;

CREATE TABLE IF NOT EXISTS users (
  id            BIGSERIAL    PRIMARY KEY,
  username      VARCHAR(255) UNIQUE NOT NULL,
  email         VARCHAR(255) UNIQUE,
  password_hash VARCHAR(255),
  bio           TEXT,
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);
CREATE INDEX IF NOT EXISTS idx_users_email    ON users(email) WHERE email IS NOT NULL;

INSERT INTO users (id, username, email, password_hash, bio, created_at)
SELECT
  i,
  'user_' || i,
  'user_' || i || '@shop.local',
  'hashed_password_' || i,
  'seed-bio-' || i,
  '2026-01-01T00:00:00Z'::timestamptz + make_interval(secs => i)
FROM generate_series(1, 1000) AS i
ON CONFLICT (id) DO UPDATE SET
  username      = EXCLUDED.username,
  email         = EXCLUDED.email,
  password_hash = EXCLUDED.password_hash,
  bio           = EXCLUDED.bio,
  created_at    = EXCLUDED.created_at;
SELECT setval('users_id_seq', 1000, true);

CREATE TABLE IF NOT EXISTS interests (
  id       BIGSERIAL PRIMARY KEY,
  name     VARCHAR(255) NOT NULL,
  category VARCHAR(100) NOT NULL
);

INSERT INTO interests (id, name, category)
SELECT
  gs,
  'interest-' || gs,
  CASE (gs % 5)
    WHEN 0 THEN 'tech'
    WHEN 1 THEN 'sport'
    WHEN 2 THEN 'music'
    WHEN 3 THEN 'travel'
    ELSE        'science'
  END
FROM generate_series(1, 200) AS gs
ON CONFLICT (id) DO UPDATE SET
  name     = EXCLUDED.name,
  category = EXCLUDED.category;
SELECT setval('interests_id_seq', 200, true);

CREATE TABLE IF NOT EXISTS friendships (
  user_id        BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  friend_user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  CONSTRAINT pk_friendships          PRIMARY KEY (user_id, friend_user_id),
  CONSTRAINT chk_no_self_friendship  CHECK (user_id <> friend_user_id)
);

CREATE INDEX IF NOT EXISTS idx_friendships_user_id        ON friendships(user_id);
CREATE INDEX IF NOT EXISTS idx_friendships_friend_user_id ON friendships(friend_user_id);

-- 10 friends per user (deterministic, idempotent)
INSERT INTO friendships (user_id, friend_user_id)
SELECT
  u.id,
  ((u.id + rel.offset - 1) % 1000) + 1 AS friend_user_id
FROM users u
CROSS JOIN (SELECT generate_series(1, 10) AS offset) rel
WHERE u.id BETWEEN 1 AND 1000
  AND u.id <> ((u.id + rel.offset - 1) % 1000) + 1
ON CONFLICT (user_id, friend_user_id) DO NOTHING;

CREATE TABLE IF NOT EXISTS user_interests (
  user_id     BIGINT NOT NULL REFERENCES users(id)     ON DELETE CASCADE,
  interest_id BIGINT NOT NULL REFERENCES interests(id) ON DELETE CASCADE,
  CONSTRAINT pk_user_interests PRIMARY KEY (user_id, interest_id)
);

CREATE INDEX IF NOT EXISTS idx_user_interests_user_id     ON user_interests(user_id);
CREATE INDEX IF NOT EXISTS idx_user_interests_interest_id ON user_interests(interest_id);

-- 10 interests per user (deterministic, idempotent)
INSERT INTO user_interests (user_id, interest_id)
SELECT
  u.id,
  ((u.id * 13 + rel.offset - 1) % 200) + 1 AS interest_id
FROM users u
CROSS JOIN (SELECT generate_series(1, 10) AS offset) rel
WHERE u.id BETWEEN 1 AND 1000
ON CONFLICT (user_id, interest_id) DO NOTHING;

CREATE TABLE IF NOT EXISTS entities (
  id         BIGINT PRIMARY KEY,
  name       TEXT NOT NULL,
  type       TEXT NOT NULL,
  payload    TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO entities (id, name, type, payload, created_at)
SELECT u.id, u.username, 'user', u.bio, u.created_at
FROM users u
WHERE u.id BETWEEN 1 AND 1000
ON CONFLICT (id) DO UPDATE SET
  name       = EXCLUDED.name,
  type       = EXCLUDED.type,
  payload    = EXCLUDED.payload,
  created_at = EXCLUDED.created_at;

COMMIT;
