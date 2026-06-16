-- PostgreSQL 16.2 seed script for e2e-shop-order-saga benchmark
-- Schema: V3_E2E_SAGA
-- Idempotency: INSERT ... ON CONFLICT (id) DO UPDATE

BEGIN;

-- ============================================================================
-- USERS TABLE
-- ============================================================================
CREATE TABLE IF NOT EXISTS users (
  id BIGSERIAL PRIMARY KEY,
  username VARCHAR(255) UNIQUE NOT NULL,
  email VARCHAR(255) UNIQUE NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);
CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);

-- Insert 1000 test users (idempotent)
INSERT INTO users (id, username, email, password_hash, created_at)
SELECT 
  i,
  'user_' || i::TEXT,
  'user_' || i::TEXT || '@shop.local',
  'hashed_password_' || i::TEXT,
  CURRENT_TIMESTAMP - (random() * interval '30 days')
FROM generate_series(1, 1000) AS i
ON CONFLICT (id) DO UPDATE SET
  username = EXCLUDED.username,
  email = EXCLUDED.email,
  password_hash = EXCLUDED.password_hash,
  created_at = EXCLUDED.created_at
WHERE users.username = EXCLUDED.username;

-- ============================================================================
-- PRODUCTS TABLE
-- ============================================================================
CREATE TABLE IF NOT EXISTS products (
  id BIGSERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  description TEXT,
  price DECIMAL(10, 2) NOT NULL,
  category VARCHAR(100) NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_products_category ON products(category);

-- Insert 500 test products (idempotent)
INSERT INTO products (id, name, description, price, category, created_at)
SELECT 
  i,
  'Product_' || i::TEXT,
  'Description for product ' || i::TEXT,
  ROUND(CAST(9.99 + (random() * 990) AS NUMERIC), 2),
  CASE (i - 1) % 5
    WHEN 0 THEN 'Electronics'
    WHEN 1 THEN 'Books'
    WHEN 2 THEN 'Clothing'
    WHEN 3 THEN 'Home'
    ELSE 'Sports'
  END AS category,
  CURRENT_TIMESTAMP - (random() * interval '90 days')
FROM generate_series(1, 500) AS i
ON CONFLICT (id) DO UPDATE SET
  name = EXCLUDED.name,
  description = EXCLUDED.description,
  price = EXCLUDED.price,
  category = EXCLUDED.category,
  created_at = EXCLUDED.created_at;

-- ============================================================================
-- INVENTORY TABLE
-- ============================================================================
CREATE TABLE IF NOT EXISTS inventory (
  product_id BIGINT PRIMARY KEY REFERENCES products(id) ON DELETE CASCADE,
  quantity_available INT NOT NULL DEFAULT 100,
  reserved INT NOT NULL DEFAULT 0,
  last_updated TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_inventory_available ON inventory(quantity_available);

-- Insert 500 inventory records (one per product, idempotent)
INSERT INTO inventory (product_id, quantity_available, reserved, last_updated)
SELECT 
  p.id,
  CAST(50 + (random() * 450) AS INT),
  0,
  CURRENT_TIMESTAMP
FROM products p
ON CONFLICT (product_id) DO UPDATE SET
  quantity_available = EXCLUDED.quantity_available,
  reserved = EXCLUDED.reserved,
  last_updated = EXCLUDED.last_updated;

-- ============================================================================
-- PRODUCT_RELATIONSHIPS TABLE (Product similarity for recommendations)
-- ============================================================================
CREATE TABLE IF NOT EXISTS product_relationships (
  source_product_id BIGINT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  target_product_id BIGINT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  similarity_score DECIMAL(3, 2) NOT NULL CHECK (similarity_score >= 0 AND similarity_score <= 1),
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (source_product_id, target_product_id)
);

CREATE INDEX IF NOT EXISTS idx_product_relationships_source ON product_relationships(source_product_id);
CREATE INDEX IF NOT EXISTS idx_product_relationships_target ON product_relationships(target_product_id);
CREATE INDEX IF NOT EXISTS idx_product_relationships_score ON product_relationships(similarity_score DESC);

-- Insert product similarity relationships (>1000 rows, idempotent)
-- Each product gets 2-5 similar products
INSERT INTO product_relationships (source_product_id, target_product_id, similarity_score, created_at)
SELECT 
  p1.id AS source_product_id,
  p2.id AS target_product_id,
  ROUND(CAST(0.5 + (random() * 0.5) AS NUMERIC), 2) AS similarity_score,
  CURRENT_TIMESTAMP
FROM products p1, products p2
WHERE p1.id < p2.id 
  AND p1.category = p2.category
  AND MOD((p1.id * 7 + p2.id * 11), (p2.id - p1.id + 1)) < 2
LIMIT 1200
ON CONFLICT (source_product_id, target_product_id) DO UPDATE SET
  similarity_score = EXCLUDED.similarity_score,
  created_at = EXCLUDED.created_at;

-- ============================================================================
-- USER_PURCHASE_HISTORY TABLE
-- ============================================================================
CREATE TABLE IF NOT EXISTS user_purchase_history (
  id BIGSERIAL PRIMARY KEY,
  user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  product_id BIGINT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  purchased_at TIMESTAMP NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_user_purchase_history_user ON user_purchase_history(user_id);
CREATE INDEX IF NOT EXISTS idx_user_purchase_history_product ON user_purchase_history(product_id);
CREATE INDEX IF NOT EXISTS idx_user_purchase_history_date ON user_purchase_history(purchased_at DESC);

-- Insert >1000 purchase history records (idempotent)
-- Each user gets 1-3 historical purchases
INSERT INTO user_purchase_history (id, user_id, product_id, purchased_at, created_at)
SELECT 
  ROW_NUMBER() OVER (ORDER BY u.id, p.id) AS id,
  u.id AS user_id,
  p.id AS product_id,
  CURRENT_TIMESTAMP - (random() * interval '60 days') AS purchased_at,
  CURRENT_TIMESTAMP
FROM users u
CROSS JOIN LATERAL (
  SELECT DISTINCT
    p.id
  FROM products p
  WHERE MOD((u.id * 13 + p.id * 17), 500) < (1 + (u.id % 3))
  LIMIT 3
) p
ON CONFLICT (id) DO UPDATE SET
  user_id = EXCLUDED.user_id,
  product_id = EXCLUDED.product_id,
  purchased_at = EXCLUDED.purchased_at,
  created_at = EXCLUDED.created_at;

-- ============================================================================
-- ORDERS TABLE (Empty initially, populated during benchmark)
-- ============================================================================
CREATE TABLE IF NOT EXISTS carts (
  id BIGSERIAL PRIMARY KEY,
  user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status VARCHAR(32) NOT NULL DEFAULT 'ACTIVE',
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_carts_user ON carts(user_id);
CREATE INDEX IF NOT EXISTS idx_carts_user_status ON carts(user_id, status);

CREATE TABLE IF NOT EXISTS cart_items (
  id BIGSERIAL PRIMARY KEY,
  cart_id BIGINT NOT NULL REFERENCES carts(id) ON DELETE CASCADE,
  product_id BIGINT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  quantity INT NOT NULL CHECK (quantity > 0),
  price DECIMAL(10, 2) NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (cart_id, product_id)
);

CREATE INDEX IF NOT EXISTS idx_cart_items_cart ON cart_items(cart_id);
CREATE INDEX IF NOT EXISTS idx_cart_items_product ON cart_items(product_id);

CREATE TABLE IF NOT EXISTS user_principals (
  principal_uuid UUID PRIMARY KEY,
  user_id BIGINT UNIQUE NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_user_principals_user_id ON user_principals(user_id);

CREATE TABLE IF NOT EXISTS orders (
  id BIGSERIAL PRIMARY KEY,
  user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status VARCHAR(50) NOT NULL DEFAULT 'PENDING',
  saga_id VARCHAR(255),
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_orders_user ON orders(user_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status);
CREATE INDEX IF NOT EXISTS idx_orders_saga ON orders(saga_id);

-- ============================================================================
-- ORDER_ITEMS TABLE (Empty initially, populated during benchmark)
-- ============================================================================
CREATE TABLE IF NOT EXISTS order_items (
  id BIGSERIAL PRIMARY KEY,
  order_id BIGINT NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  product_id BIGINT NOT NULL REFERENCES products(id),
  quantity INT NOT NULL DEFAULT 1,
  price DECIMAL(10, 2) NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_order_items_order ON order_items(order_id);
CREATE INDEX IF NOT EXISTS idx_order_items_product ON order_items(product_id);

-- Kernel-native outbox table — matches CommunityJdbcEventStore SQL_APPEND / SQL_POLL_PENDING / SQL_MARK_PUBLISHED
-- Migration: V3_E2E_SAGA_KERNEL_OUTBOX — replaces V2_E2E_SAGA schema (id BIGSERIAL/BIGINT aggregate_id/JSONB payload incompatible)
-- V3 migration guard: drop stale V2 schema if payload column is missing
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'exeris_outbox'
  ) AND NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'exeris_outbox' AND column_name = 'payload'
  ) THEN
    DROP TABLE IF EXISTS exeris_outbox CASCADE;
  END IF;
END;
$$;
CREATE TABLE IF NOT EXISTS exeris_outbox (
  outbox_seq     BIGSERIAL     NOT NULL,
  id             UUID          NOT NULL,
  aggregate_id   VARCHAR(255)  NOT NULL,
  aggregate_type VARCHAR(64)   NOT NULL,
  event_type     VARCHAR(128)  NOT NULL,
  payload        BYTEA         NOT NULL,
  occurred_at    BIGINT        NOT NULL,
  published_at   BIGINT        NULL,
  CONSTRAINT pk_exeris_outbox PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_exeris_outbox_pending
  ON exeris_outbox (outbox_seq ASC)
  WHERE published_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_exeris_outbox_aggregate
  ON exeris_outbox (aggregate_type, aggregate_id);

-- Kernel DLQ table — matches CommunityJdbcOutboxEventStoreAdapter SQL_INSERT_DLQ
-- V3 migration guard: drop stale V2 schema if payload column is missing
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'exeris_outbox_dlq'
  ) AND NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'exeris_outbox_dlq' AND column_name = 'payload'
  ) THEN
    DROP TABLE IF EXISTS exeris_outbox_dlq CASCADE;
  END IF;
END;
$$;
CREATE TABLE IF NOT EXISTS exeris_outbox_dlq (
  id             UUID          NOT NULL,
  stream_id      UUID          NOT NULL,
  event_type     VARCHAR(128)  NOT NULL,
  payload        BYTEA         NOT NULL,
  occurred_at    BIGINT        NOT NULL,
  failure_reason TEXT,
  CONSTRAINT pk_exeris_outbox_dlq PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_exeris_outbox_dlq_stream
  ON exeris_outbox_dlq (stream_id);

-- ============================================================================
-- EXERIS FLOW DURABLE SAGA STATE (used by exeris-spring-runtime-flow targets)
-- Durable JdbcFlowSnapshotStore backing table (ADR-013 / FLOW-103). Lifted
-- verbatim from exeris-kernel-community db/migration/V0.7.0__create_saga_state.sql
-- so the flow engine's snapshot store matches the runtime's own schema exactly.
-- Required when exeris.runtime.flow.persistence-enabled=true (ADR-022); without
-- it the flow engine's "load flow snapshot" SELECT fails with
-- relation "exeris_saga_state" does not exist → POST /orders 500.
-- ============================================================================
CREATE TABLE IF NOT EXISTS exeris_saga_state (
    instance_id_most    BIGINT       NOT NULL,
    instance_id_least   BIGINT       NOT NULL,
    definition_name     TEXT         NOT NULL,
    current_step        INT          NOT NULL,
    state               TEXT         NOT NULL,
    last_update         TIMESTAMP WITH TIME ZONE NOT NULL,
    timeout_at          TIMESTAMP WITH TIME ZONE,
    compensation_stack  BYTEA        NOT NULL,
    stack_pointer       INT          NOT NULL,
    opaque_state        BYTEA,
    schema_version      BIGINT       NOT NULL DEFAULT 1,
    PRIMARY KEY (instance_id_most, instance_id_least)
);

CREATE INDEX IF NOT EXISTS idx_exeris_saga_state_parked
    ON exeris_saga_state (state, last_update);

-- ============================================================================
-- AXON FRAMEWORK JPA EVENT STORE (used by spring-app-axon and quarkus-app-axon)
-- Tables match Axon Framework 4.x JPA schema for PostgreSQL / Hibernate 6
-- ============================================================================
CREATE TABLE IF NOT EXISTS domain_event_entry (
  global_index         BIGSERIAL    NOT NULL,
  event_identifier     VARCHAR(255) NOT NULL,
  meta_data            BYTEA,
  payload              BYTEA        NOT NULL,
  payload_revision     VARCHAR(255),
  payload_type         VARCHAR(255) NOT NULL,
  time_stamp           VARCHAR(255) NOT NULL,
  aggregate_identifier VARCHAR(255) NOT NULL,
  sequence_number      BIGINT       NOT NULL,
  type                 VARCHAR(255),
  CONSTRAINT pk_domain_event_entry          PRIMARY KEY (global_index),
  CONSTRAINT ux_domain_event_entry_event_id UNIQUE (event_identifier),
  CONSTRAINT ux_domain_event_entry_agg_seq  UNIQUE (aggregate_identifier, sequence_number, type)
);

CREATE INDEX IF NOT EXISTS idx_domain_event_entry_agg ON domain_event_entry(aggregate_identifier, type);

CREATE TABLE IF NOT EXISTS snapshot_entry (
  aggregate_identifier VARCHAR(255) NOT NULL,
  sequence_number      BIGINT       NOT NULL,
  type                 VARCHAR(255) NOT NULL,
  event_identifier     VARCHAR(255) NOT NULL,
  meta_data            BYTEA,
  payload              BYTEA        NOT NULL,
  payload_revision     VARCHAR(255),
  payload_type         VARCHAR(255) NOT NULL,
  time_stamp           VARCHAR(255) NOT NULL,
  CONSTRAINT pk_snapshot_entry          PRIMARY KEY (aggregate_identifier, sequence_number, type),
  CONSTRAINT ux_snapshot_entry_event_id UNIQUE (event_identifier)
);

CREATE TABLE IF NOT EXISTS token_entry (
  processor_name VARCHAR(255) NOT NULL,
  segment        INT          NOT NULL,
  token          BYTEA,
  token_type     VARCHAR(255),
  timestamp      VARCHAR(255),
  owner          VARCHAR(255),
  CONSTRAINT pk_token_entry PRIMARY KEY (processor_name, segment)
);

-- ============================================================================
-- FRIENDSHIPS TABLE
-- ============================================================================
CREATE TABLE IF NOT EXISTS friendships (
  user_id        BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  friend_user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  CONSTRAINT pk_friendships PRIMARY KEY (user_id, friend_user_id),
  CONSTRAINT chk_no_self_friendship CHECK (user_id <> friend_user_id)
);

CREATE INDEX IF NOT EXISTS idx_friendships_user_id        ON friendships(user_id);
CREATE INDEX IF NOT EXISTS idx_friendships_friend_user_id ON friendships(friend_user_id);

-- ~5000 friendship pairs (5 friends per user via prime-offset wraparound, idempotent)
INSERT INTO friendships (user_id, friend_user_id)
SELECT u.i AS user_id, f.friend_id AS friend_user_id
FROM generate_series(1, 1000) AS u(i)
CROSS JOIN LATERAL (
  SELECT UNNEST(ARRAY[
    ((u.i - 1 + 97)  % 1000) + 1,
    ((u.i - 1 + 199) % 1000) + 1,
    ((u.i - 1 + 307) % 1000) + 1,
    ((u.i - 1 + 401) % 1000) + 1,
    ((u.i - 1 + 503) % 1000) + 1
  ]) AS friend_id
) f
WHERE u.i <> f.friend_id
ON CONFLICT DO NOTHING;

-- ============================================================================
-- INTERESTS TABLE
-- ============================================================================
CREATE TABLE IF NOT EXISTS interests (
  id       BIGSERIAL    PRIMARY KEY,
  name     VARCHAR(255) NOT NULL,
  category VARCHAR(100) NOT NULL
);

-- 20 interests across 5 categories (idempotent)
INSERT INTO interests (id, name, category) VALUES
  (1,  'Smartphones',    'Electronics'),
  (2,  'Laptops',        'Electronics'),
  (3,  'Audio',          'Electronics'),
  (4,  'Cameras',        'Electronics'),
  (5,  'Science Fiction','Books'),
  (6,  'Non-Fiction',    'Books'),
  (7,  'Fantasy',        'Books'),
  (8,  'Biographies',    'Books'),
  (9,  'Casual Wear',    'Clothing'),
  (10, 'Sportswear',     'Clothing'),
  (11, 'Formal Wear',    'Clothing'),
  (12, 'Outerwear',      'Clothing'),
  (13, 'Kitchen',        'Home'),
  (14, 'Garden',         'Home'),
  (15, 'Decor',          'Home'),
  (16, 'Furniture',      'Home'),
  (17, 'Cycling',        'Sports'),
  (18, 'Running',        'Sports'),
  (19, 'Swimming',       'Sports'),
  (20, 'Team Sports',    'Sports')
ON CONFLICT (id) DO NOTHING;
SELECT setval('interests_id_seq', 20, true);

-- ============================================================================
-- USER_INTERESTS TABLE
-- ============================================================================
CREATE TABLE IF NOT EXISTS user_interests (
  user_id     BIGINT NOT NULL REFERENCES users(id)     ON DELETE CASCADE,
  interest_id BIGINT NOT NULL REFERENCES interests(id) ON DELETE CASCADE,
  CONSTRAINT pk_user_interests PRIMARY KEY (user_id, interest_id)
);

CREATE INDEX IF NOT EXISTS idx_user_interests_user_id     ON user_interests(user_id);
CREATE INDEX IF NOT EXISTS idx_user_interests_interest_id ON user_interests(interest_id);

-- ~3000 user-interest pairs (3 per user, idempotent)
INSERT INTO user_interests (user_id, interest_id)
SELECT i AS user_id, ((i - 1 + offset_val) % 20) + 1 AS interest_id
FROM generate_series(1, 1000) AS i
CROSS JOIN (VALUES (0), (7), (13)) AS offsets(offset_val)
ON CONFLICT DO NOTHING;

-- ============================================================================
-- SCHEMA VERIFICATION
-- ============================================================================

-- Verify row counts
DO $$
DECLARE
  users_count                 INT;
  products_count              INT;
  inventory_count             INT;
  product_relationships_count INT;
  user_purchase_history_count INT;
  carts_count                 INT;
  cart_items_count            INT;
  user_principals_count       INT;
  outbox_count                INT;
  dlq_count                   INT;
  friendships_count           INT;
  interests_count             INT;
  user_interests_count        INT;
BEGIN
  SELECT COUNT(*) INTO users_count                 FROM users;
  SELECT COUNT(*) INTO products_count              FROM products;
  SELECT COUNT(*) INTO inventory_count             FROM inventory;
  SELECT COUNT(*) INTO product_relationships_count FROM product_relationships;
  SELECT COUNT(*) INTO user_purchase_history_count FROM user_purchase_history;
  SELECT COUNT(*) INTO carts_count                 FROM carts;
  SELECT COUNT(*) INTO cart_items_count            FROM cart_items;
  SELECT COUNT(*) INTO user_principals_count       FROM user_principals;
  SELECT COUNT(*) INTO outbox_count                FROM exeris_outbox;
  SELECT COUNT(*) INTO dlq_count                   FROM exeris_outbox_dlq;
  SELECT COUNT(*) INTO friendships_count           FROM friendships;
  SELECT COUNT(*) INTO interests_count             FROM interests;
  SELECT COUNT(*) INTO user_interests_count        FROM user_interests;

  RAISE NOTICE 'Seed verification:
    - users: %
    - products: %
    - inventory: %
    - product_relationships: %
    - user_purchase_history: %
    - carts: %
    - cart_items: %
    - user_principals: %
    - exeris_outbox: %
    - exeris_outbox_dlq: %
    - friendships: %
    - interests: %
    - user_interests: %',
    users_count, products_count, inventory_count,
    product_relationships_count, user_purchase_history_count,
    carts_count, cart_items_count, user_principals_count,
    outbox_count, dlq_count,
    friendships_count, interests_count, user_interests_count;
END $$;

COMMIT;
