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

-- Axon Framework 4.x JpaSagaStore tables — schema-completeness insurance, like
-- domain_event_entry/snapshot_entry/token_entry above. A live probe (2026-07-17,
-- Axon Server 2024.2.22 + Postgres 16.2, spring-benchmark-app) confirmed the
-- Spring stack as wired today uses IN-MEMORY saga and token stores (zero JPA
-- writes to these tables; pg_stat n_tup_ins = 0 across two completed sagas), so
-- nothing exercises this DDL yet. If Axon's JPA autoconfiguration is ever
-- re-enabled, JpaSagaStore engages and these definitions must match Hibernate 6:
-- serialized_saga is OID (PostgreSQLDialect maps @Lob byte[] to oid, not bytea);
-- association_value_entry_seq is the Hibernate 6 default sequence for
-- @GeneratedValue AUTO (allocationSize 50 — INCREMENT must stay 50).
CREATE TABLE IF NOT EXISTS saga_entry (
  saga_id         VARCHAR(255) NOT NULL,
  revision        VARCHAR(255),
  saga_type       VARCHAR(255),
  serialized_saga OID,
  CONSTRAINT pk_saga_entry PRIMARY KEY (saga_id)
);

CREATE TABLE IF NOT EXISTS association_value_entry (
  id                BIGINT       NOT NULL,
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
