-- migration: v2_shop
-- tables: products, inventory, product_relationships, user_purchase_history,
--         carts, cart_items, user_principals, orders, order_items
-- idempotency: CREATE TABLE IF NOT EXISTS + ON CONFLICT DO NOTHING / DO UPDATE

BEGIN;

CREATE TABLE IF NOT EXISTS products (
  id          BIGSERIAL    PRIMARY KEY,
  name        VARCHAR(255) NOT NULL,
  description TEXT,
  price       DECIMAL(10, 2) NOT NULL,
  category    VARCHAR(100) NOT NULL,
  created_at  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_products_category ON products(category);

INSERT INTO products (id, name, description, price, category, created_at)
SELECT
  i,
  'Product_' || i,
  'Description for product ' || i,
  ROUND(CAST(9.99 + (random() * 990) AS NUMERIC), 2),
  CASE (i - 1) % 5
    WHEN 0 THEN 'Electronics'
    WHEN 1 THEN 'Books'
    WHEN 2 THEN 'Clothing'
    WHEN 3 THEN 'Home'
    ELSE         'Sports'
  END,
  CURRENT_TIMESTAMP - (random() * interval '90 days')
FROM generate_series(1, 500) AS i
ON CONFLICT (id) DO UPDATE SET
  name        = EXCLUDED.name,
  description = EXCLUDED.description,
  price       = EXCLUDED.price,
  category    = EXCLUDED.category,
  created_at  = EXCLUDED.created_at;

CREATE TABLE IF NOT EXISTS inventory (
  product_id         BIGINT PRIMARY KEY REFERENCES products(id) ON DELETE CASCADE,
  quantity_available INT    NOT NULL DEFAULT 100,
  reserved           INT    NOT NULL DEFAULT 0,
  last_updated       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_inventory_available ON inventory(quantity_available);

INSERT INTO inventory (product_id, quantity_available, reserved, last_updated)
SELECT p.id, CAST(50 + (random() * 450) AS INT), 0, CURRENT_TIMESTAMP
FROM products p
ON CONFLICT (product_id) DO UPDATE SET
  quantity_available = EXCLUDED.quantity_available,
  reserved           = EXCLUDED.reserved,
  last_updated       = EXCLUDED.last_updated;

CREATE TABLE IF NOT EXISTS product_relationships (
  source_product_id BIGINT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  target_product_id BIGINT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  similarity_score  DECIMAL(3, 2) NOT NULL CHECK (similarity_score >= 0 AND similarity_score <= 1),
  created_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (source_product_id, target_product_id)
);

CREATE INDEX IF NOT EXISTS idx_product_relationships_source ON product_relationships(source_product_id);
CREATE INDEX IF NOT EXISTS idx_product_relationships_target ON product_relationships(target_product_id);
CREATE INDEX IF NOT EXISTS idx_product_relationships_score  ON product_relationships(similarity_score DESC);

INSERT INTO product_relationships (source_product_id, target_product_id, similarity_score, created_at)
SELECT
  p1.id,
  p2.id,
  ROUND(CAST(0.5 + (random() * 0.5) AS NUMERIC), 2),
  CURRENT_TIMESTAMP
FROM products p1, products p2
WHERE p1.id < p2.id
  AND p1.category = p2.category
  AND MOD((p1.id * 7 + p2.id * 11), (p2.id - p1.id + 1)) < 2
LIMIT 1200
ON CONFLICT (source_product_id, target_product_id) DO UPDATE SET
  similarity_score = EXCLUDED.similarity_score,
  created_at       = EXCLUDED.created_at;

CREATE TABLE IF NOT EXISTS user_purchase_history (
  id           BIGSERIAL PRIMARY KEY,
  user_id      BIGINT NOT NULL REFERENCES users(id)     ON DELETE CASCADE,
  product_id   BIGINT NOT NULL REFERENCES products(id)  ON DELETE CASCADE,
  purchased_at TIMESTAMP NOT NULL,
  created_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_user_purchase_history_user    ON user_purchase_history(user_id);
CREATE INDEX IF NOT EXISTS idx_user_purchase_history_product ON user_purchase_history(product_id);
CREATE INDEX IF NOT EXISTS idx_user_purchase_history_date    ON user_purchase_history(purchased_at DESC);

INSERT INTO user_purchase_history (id, user_id, product_id, purchased_at, created_at)
SELECT
  ROW_NUMBER() OVER (ORDER BY u.id, p.id),
  u.id,
  p.id,
  CURRENT_TIMESTAMP - (random() * interval '60 days'),
  CURRENT_TIMESTAMP
FROM users u
CROSS JOIN LATERAL (
  SELECT p.id
  FROM products p
  WHERE MOD((u.id * 13 + p.id * 17), 500) < (1 + (u.id % 3))
  LIMIT 3
) p
ON CONFLICT (id) DO UPDATE SET
  user_id      = EXCLUDED.user_id,
  product_id   = EXCLUDED.product_id,
  purchased_at = EXCLUDED.purchased_at,
  created_at   = EXCLUDED.created_at;

CREATE TABLE IF NOT EXISTS carts (
  id         BIGSERIAL    PRIMARY KEY,
  user_id    BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status     VARCHAR(32)  NOT NULL DEFAULT 'ACTIVE',
  created_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_carts_user        ON carts(user_id);
CREATE INDEX IF NOT EXISTS idx_carts_user_status ON carts(user_id, status);

CREATE TABLE IF NOT EXISTS cart_items (
  id         BIGSERIAL      PRIMARY KEY,
  cart_id    BIGINT         NOT NULL REFERENCES carts(id)    ON DELETE CASCADE,
  product_id BIGINT         NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  quantity   INT            NOT NULL CHECK (quantity > 0),
  price      DECIMAL(10, 2) NOT NULL,
  created_at TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (cart_id, product_id)
);

CREATE INDEX IF NOT EXISTS idx_cart_items_cart    ON cart_items(cart_id);
CREATE INDEX IF NOT EXISTS idx_cart_items_product ON cart_items(product_id);

CREATE TABLE IF NOT EXISTS user_principals (
  principal_uuid UUID   PRIMARY KEY,
  user_id        BIGINT UNIQUE NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_user_principals_user_id ON user_principals(user_id);

CREATE TABLE IF NOT EXISTS orders (
  id         BIGSERIAL    PRIMARY KEY,
  user_id    BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status     VARCHAR(50)  NOT NULL DEFAULT 'PENDING',
  saga_id    VARCHAR(255),
  created_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_orders_user   ON orders(user_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status);
CREATE INDEX IF NOT EXISTS idx_orders_saga   ON orders(saga_id);

CREATE TABLE IF NOT EXISTS order_items (
  id         BIGSERIAL      PRIMARY KEY,
  order_id   BIGINT         NOT NULL REFERENCES orders(id)   ON DELETE CASCADE,
  product_id BIGINT         NOT NULL REFERENCES products(id),
  quantity   INT            NOT NULL DEFAULT 1,
  price      DECIMAL(10, 2) NOT NULL,
  created_at TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_order_items_order   ON order_items(order_id);
CREATE INDEX IF NOT EXISTS idx_order_items_product ON order_items(product_id);

COMMIT;
