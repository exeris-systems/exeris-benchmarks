-- migration: v4_pgq_graph
-- purpose: Create PostgreSQL graph tables for the SQL/PGQ graph backend.
--   These tables are provisioned by the Exeris Kernel when EXERIS_GRAPH_BACKEND_TYPE=postgresql.
--   They must exist independently so that Spring and Quarkus benchmark targets can
--   execute equivalent graph operations without requiring the Exeris app to have run first.
-- idempotency: All CREATE TABLE/INDEX use IF NOT EXISTS — safe to re-run.
-- run: after v3_outbox_axon.sql
-- dependency: none (no FK references to other tables)

-- Node table: used by graph_nodes upsert/sync operations.
-- The Exeris Kernel always names this table 'graph_nodes' regardless of graphName.
CREATE TABLE IF NOT EXISTS graph_nodes (
    id         UUID         PRIMARY KEY,
    label      VARCHAR(64)  NOT NULL    DEFAULT '',
    properties JSONB        NOT NULL    DEFAULT '{}'
);

-- IN_CART edges: User→Product cart projection.
-- Table name derived by Kernel: toSnakeCase("IN_CART") + "_edges" = "in_cart_edges"
CREATE TABLE IF NOT EXISTS in_cart_edges (
    source_id  UUID              NOT NULL,
    target_id  UUID              NOT NULL,
    weight     DOUBLE PRECISION  NOT NULL  DEFAULT 1.0,
    properties JSONB             NOT NULL  DEFAULT '{}',
    tenant_id  UUID              NOT NULL  DEFAULT '00000000-0000-0000-0000-000000000000',
    created_at TIMESTAMPTZ       NOT NULL  DEFAULT NOW(),
    PRIMARY KEY (source_id, target_id, tenant_id)
);
CREATE INDEX IF NOT EXISTS idx_in_cart_edges_source ON in_cart_edges (source_id);

-- BOUGHT edges: User→Product purchase history (used in Phase 2 recommend traversal).
-- Table name: "bought_edges"
CREATE TABLE IF NOT EXISTS bought_edges (
    source_id  UUID              NOT NULL,
    target_id  UUID              NOT NULL,
    weight     DOUBLE PRECISION  NOT NULL  DEFAULT 1.0,
    properties JSONB             NOT NULL  DEFAULT '{}',
    tenant_id  UUID              NOT NULL  DEFAULT '00000000-0000-0000-0000-000000000000',
    created_at TIMESTAMPTZ       NOT NULL  DEFAULT NOW(),
    PRIMARY KEY (source_id, target_id, tenant_id)
);
CREATE INDEX IF NOT EXISTS idx_bought_edges_source ON bought_edges (source_id);

-- SIMILAR_TO edges: Product→Product similarity (used in Phase 2 recommend traversal).
-- Table name: "similar_to_edges"
CREATE TABLE IF NOT EXISTS similar_to_edges (
    source_id  UUID              NOT NULL,
    target_id  UUID              NOT NULL,
    weight     DOUBLE PRECISION  NOT NULL  DEFAULT 1.0,
    properties JSONB             NOT NULL  DEFAULT '{}',
    tenant_id  UUID              NOT NULL  DEFAULT '00000000-0000-0000-0000-000000000000',
    created_at TIMESTAMPTZ       NOT NULL  DEFAULT NOW(),
    PRIMARY KEY (source_id, target_id, tenant_id)
);
CREATE INDEX IF NOT EXISTS idx_similar_to_edges_source ON similar_to_edges (source_id);

-- ============================================================
-- Phase 2: name_uuid_v3 helper
-- ============================================================
-- Replicates Java: UUID.nameUUIDFromBytes(input.getBytes(StandardCharsets.UTF_8))
-- UUID version 3 (MD5-based, no namespace). Byte operations match Java exactly:
--   byte[6] = (byte[6] & 0x0f) | 0x30  (version 3)
--   byte[8] = (byte[8] & 0x3f) | 0x80  (RFC 4122 variant)
-- For ASCII-only inputs (e.g. "user-1", "product-42") PostgreSQL md5(text)
-- produces identical bytes to Java's md5.digest(text.getBytes(UTF_8)).
CREATE OR REPLACE FUNCTION name_uuid_v3(input_text TEXT) RETURNS UUID AS $$
DECLARE
    h  TEXT    := md5(input_text);
    b6 INTEGER;
    b8 INTEGER;
BEGIN
    b6 := ('x' || substring(h, 13, 2))::bit(8)::integer;
    b8 := ('x' || substring(h, 17, 2))::bit(8)::integer;
    b6 := (b6 & 15)  | 48;   -- version 3: 0x3X
    b8 := (b8 & 63)  | 128;  -- RFC 4122 variant: 0x8X–0xBX
    RETURN (
        substring(h,  1, 8) || '-' ||
        substring(h,  9, 4) || '-' ||
        to_hex(b6) || substring(h, 15, 2) || '-' ||
        to_hex(b8) || substring(h, 19, 2) || '-' ||
        substring(h, 21, 12)
    )::uuid;
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;

-- ============================================================
-- Phase 2: Seed graph_nodes (users)
-- ============================================================
-- One node per distinct user referenced in purchase history.
-- properties stores numeric user_id for UUID → Long resolution.
INSERT INTO graph_nodes (id, label, properties)
SELECT DISTINCT
    name_uuid_v3('user-' || uph.user_id),
    'User',
    jsonb_build_object('user_id', uph.user_id)
FROM user_purchase_history uph
ON CONFLICT (id) DO NOTHING;

-- ============================================================
-- Phase 2: Seed graph_nodes (products)
-- ============================================================
-- One node per product appearing in purchase history or product_relationships.
-- properties stores numeric product_id for UUID → Long resolution.
INSERT INTO graph_nodes (id, label, properties)
SELECT DISTINCT
    name_uuid_v3('product-' || p.id),
    'Product',
    jsonb_build_object('product_id', p.id)
FROM products p
WHERE p.id IN (
    SELECT product_id       FROM user_purchase_history
    UNION
    SELECT source_product_id FROM product_relationships
    UNION
    SELECT target_product_id FROM product_relationships
)
ON CONFLICT (id) DO NOTHING;

-- ============================================================
-- Phase 2: Seed bought_edges from user_purchase_history
-- ============================================================
-- Edge direction: User → Product (same as Kernel USER_BOUGHT_PRODUCT descriptor).
-- Multiple purchases of the same product collapse to one edge (DISTINCT).
INSERT INTO bought_edges (source_id, target_id, weight, properties)
SELECT DISTINCT
    name_uuid_v3('user-'    || uph.user_id),
    name_uuid_v3('product-' || uph.product_id),
    1.0,
    '{}'
FROM user_purchase_history uph
ON CONFLICT (source_id, target_id, tenant_id) DO NOTHING;

-- ============================================================
-- Phase 2: Seed similar_to_edges from product_relationships
-- ============================================================
-- Edge direction: Product → Product (Kernel PRODUCT_SIMILAR_TO_PRODUCT descriptor).
-- Weight from similarity_score; stored in properties for traceability.
INSERT INTO similar_to_edges (source_id, target_id, weight, properties)
SELECT
    name_uuid_v3('product-' || pr.source_product_id),
    name_uuid_v3('product-' || pr.target_product_id),
    pr.similarity_score::DOUBLE PRECISION,
    jsonb_build_object('similarity_score', pr.similarity_score)
FROM product_relationships pr
ON CONFLICT (source_id, target_id, tenant_id) DO NOTHING;
