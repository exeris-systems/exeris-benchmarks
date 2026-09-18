-- migration: v3_outbox_axon
-- tables: exeris_outbox, exeris_outbox_dlq, domain_event_entry, snapshot_entry, token_entry
-- migration guard: drops stale V2 exeris_outbox/exeris_outbox_dlq if payload column missing
-- idempotency: CREATE TABLE IF NOT EXISTS

BEGIN;

-- V3 migration guard: drop stale V2 exeris_outbox if payload column is missing
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

-- UUID type guard: drop if id column is uuid (kernel bindString requires VARCHAR)
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'exeris_outbox'
      AND column_name = 'id'
      AND data_type = 'uuid'
  ) THEN
    DROP TABLE IF EXISTS exeris_outbox CASCADE;
  END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS exeris_outbox (
  outbox_seq     BIGSERIAL    NOT NULL,
  id             VARCHAR(255) NOT NULL,
  aggregate_id   VARCHAR(255) NOT NULL,
  aggregate_type VARCHAR(64)  NOT NULL,
  event_type     VARCHAR(128) NOT NULL,
  payload        BYTEA        NOT NULL,
  occurred_at    BIGINT       NOT NULL,
  published_at   BIGINT       NULL,
  CONSTRAINT pk_exeris_outbox PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_exeris_outbox_pending
  ON exeris_outbox (outbox_seq ASC)
  WHERE published_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_exeris_outbox_aggregate
  ON exeris_outbox (aggregate_type, aggregate_id);

-- V3 migration guard: drop stale V2 exeris_outbox_dlq if payload column is missing
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

-- UUID type guard: drop if id column is uuid (kernel bindString requires VARCHAR)
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'exeris_outbox_dlq'
      AND column_name = 'id'
      AND data_type = 'uuid'
  ) THEN
    DROP TABLE IF EXISTS exeris_outbox_dlq CASCADE;
  END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS exeris_outbox_dlq (
  id             VARCHAR(255) NOT NULL,
  stream_id      VARCHAR(255) NOT NULL,
  event_type     VARCHAR(128) NOT NULL,
  payload        BYTEA        NOT NULL,
  occurred_at    BIGINT       NOT NULL,
  failure_reason TEXT,
  CONSTRAINT pk_exeris_outbox_dlq PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_exeris_outbox_dlq_stream ON exeris_outbox_dlq (stream_id);

-- Axon Framework 4.x JPA event store tables
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

-- Kept for the JPA path only: Hibernate resolves Axon's @GeneratedValue on global_index to
-- a sequence of this name rather than to the BIGSERIAL column's implicit one. Axon's JDBC
-- engine uses the BIGSERIAL identity directly and never touches this. Harmless either way,
-- and cheaper to keep than to re-derive if the JPA shape is ever revisited.
CREATE SEQUENCE IF NOT EXISTS domain_event_entry_seq START WITH 1 INCREMENT BY 50;

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

-- Axon's SnapshotEventEntry maps to snapshot_event_entry, NOT to snapshot_entry above.
-- Nothing wrote either while Axon Server held the event store, but JpaEventStorageEngine
-- READS the snapshot table on every aggregate load, so the embedded arm needs the name
-- Hibernate actually resolves. snapshot_entry is kept as-is: dropping a table that a
-- published run may have referenced buys nothing.
CREATE TABLE IF NOT EXISTS snapshot_event_entry (
  aggregate_identifier VARCHAR(255) NOT NULL,
  sequence_number      BIGINT       NOT NULL,
  type                 VARCHAR(255) NOT NULL,
  event_identifier     VARCHAR(255) NOT NULL,
  meta_data            BYTEA,
  payload              BYTEA        NOT NULL,
  payload_revision     VARCHAR(255),
  payload_type         VARCHAR(255) NOT NULL,
  time_stamp           VARCHAR(255) NOT NULL,
  CONSTRAINT pk_snapshot_event_entry          PRIMARY KEY (aggregate_identifier, sequence_number, type),
  CONSTRAINT ux_snapshot_event_entry_event_id UNIQUE (event_identifier)
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

-- Axon Framework 4.x saga-store tables. These were dead DDL until CONTRACT-v2 §9(e)'s
-- embedded arm arrived: a live probe (2026-07-17, Axon Server 2024.2.22 + Postgres 16.2,
-- spring-benchmark-app) found the Axon Server arm running IN-MEMORY saga and token stores
-- (pg_stat n_tup_ins = 0 across two completed sagas), because Axon's starter falls back to
-- in-memory when no store bean is declared and Axon Server supplies neither. The embedded
-- arm declares JDBC stores explicitly, so it is the first arm to write here — over Axon's
-- own JdbcSagaStore, not Hibernate.
--
-- That changes what these definitions must match. They now follow Axon's PostgreSQL JDBC
-- schema (PostgresSagaSqlSchema), NOT Hibernate 6:
--   * serialized_saga is BYTEA. Hibernate would have mapped @Lob byte[] to a large-object
--     OID; Axon's JDBC schema declares bytea and binds bytes directly.
--   * id is an IDENTITY column. Axon's association-value INSERT names only
--     (association_key, association_value, saga_type, saga_id) — SagaSchema has no id
--     column at all — so the database must generate it or every association write fails
--     on a NOT NULL violation. Axon's own DDL for this table is `id bigserial NOT NULL`.
-- association_value_entry_seq below is retained for the Hibernate shape only.
CREATE TABLE IF NOT EXISTS saga_entry (
  saga_id         VARCHAR(255) NOT NULL,
  revision        VARCHAR(255),
  saga_type       VARCHAR(255),
  serialized_saga BYTEA,
  CONSTRAINT pk_saga_entry PRIMARY KEY (saga_id)
);

CREATE TABLE IF NOT EXISTS association_value_entry (
  id                BIGINT       GENERATED BY DEFAULT AS IDENTITY NOT NULL,
  association_key   VARCHAR(255) NOT NULL,
  association_value VARCHAR(255),
  saga_id           VARCHAR(255) NOT NULL,
  saga_type         VARCHAR(255),
  CONSTRAINT pk_association_value_entry PRIMARY KEY (id)
);

CREATE SEQUENCE IF NOT EXISTS association_value_entry_seq START WITH 1 INCREMENT BY 50;

CREATE INDEX IF NOT EXISTS idx_ave_type_key_value
  ON association_value_entry (saga_type, association_key, association_value);
CREATE INDEX IF NOT EXISTS idx_ave_saga_id_type
  ON association_value_entry (saga_id, saga_type);

COMMIT;

-- ---------------------------------------------------------------------------------------
-- Axon's JDBC schema is BYTEA, and databases converted to OID must be converted back.
--
-- CONTRACT-v2 §9(e)'s embedded arm briefly ran on Axon's JPA stores, where Hibernate maps
-- `@Lob byte[]` to a PostgreSQL large-object OID. That arm now uses Axon's JDBC storage
-- engines instead - every arm in this scenario is measured on JDBC because Exeris is - and
-- Axon's own JDBC table factories declare these columns BYTEA. BYTEA is also simply the
-- right type here: large objects survive TRUNCATE as orphans, so the OID shape grew the
-- database by one object per event with nothing reading them.
--
-- CREATE TABLE IF NOT EXISTS cannot fix a table that already exists, so convert in place.
-- Safe because v0_clean truncates these tables immediately before this runs: the columns
-- are empty, so drop-and-re-add loses nothing.
DO $axon_lob$
DECLARE
  col RECORD;
BEGIN
  FOR col IN
    SELECT table_name, column_name, is_nullable
      FROM information_schema.columns
     WHERE table_schema = 'public'
       AND data_type = 'oid'
       AND (table_name, column_name) IN (
             ('token_entry','token'),               ('saga_entry','serialized_saga'),
             ('domain_event_entry','payload'),      ('domain_event_entry','meta_data'),
             ('snapshot_event_entry','payload'),    ('snapshot_event_entry','meta_data'))
  LOOP
    EXECUTE format('ALTER TABLE %I DROP COLUMN %I', col.table_name, col.column_name);
    EXECUTE format('ALTER TABLE %I ADD COLUMN %I BYTEA%s', col.table_name, col.column_name,
                   CASE WHEN col.is_nullable = 'NO' THEN ' NOT NULL' ELSE '' END);
    RAISE NOTICE '[v3] %.% converted oid -> bytea (Axon JDBC schema)', col.table_name, col.column_name;
  END LOOP;
END
$axon_lob$;

-- ---------------------------------------------------------------------------------------
-- The association-value key must be database-generated, and existing tables predate that.
--
-- association_value_entry was created for the Hibernate shape, which fed `id` from
-- association_value_entry_seq and so declared the column as a plain BIGINT NOT NULL with
-- no default. Axon's JdbcSagaStore never names `id` in its INSERT — SagaSchema has no id
-- column — so on a table created before the definition above, the first association write
-- fails with a NOT NULL violation and the saga dies on its very first event.
--
-- CREATE TABLE IF NOT EXISTS cannot repair a table that already exists, so attach the
-- identity in place. Guarded on there being no default and no identity already, which
-- makes it a no-op on a table created from the definition above.
DO $ave_identity$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name   = 'association_value_entry'
       AND column_name  = 'id'
       AND column_default IS NULL
       AND is_identity = 'NO'
  ) THEN
    EXECUTE 'ALTER TABLE association_value_entry ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY';
    RAISE NOTICE '[v3] association_value_entry.id -> GENERATED BY DEFAULT AS IDENTITY (Axon JDBC saga store)';
  END IF;
END
$ave_identity$;
