-- v5_flow_saga_state.sql — Exeris Flow durable saga-state store.
--
-- Backing table for the durable JdbcFlowSnapshotStore used by the
-- exeris-spring-runtime-flow targets when exeris.runtime.flow.persistence-enabled=true
-- (ADR-022). Without it the flow engine's "load flow snapshot" SELECT fails with
--   relation "exeris_saga_state" does not exist
-- and POST /api/v1/orders returns 500 (FlowEngineException: Failed to load flow snapshot).
--
-- DDL lifted VERBATIM from exeris-kernel-community db/migration/V0.7.0__create_saga_state.sql
-- (ADR-013 / FLOW-103) so the benchmark seed matches the runtime's own schema exactly.
-- Idempotent (CREATE TABLE/INDEX IF NOT EXISTS) — safe to re-apply.
--
-- Note: the Axon event-store tables in v3_outbox_axon.sql are legacy; the saga workload
-- now runs on the Flow engine, which persists here instead of in snapshot_entry/token_entry.

BEGIN;

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

-- ---------------------------------------------------------------------------
-- Kernel migrations V0.11.0 / V0.11.1 / V0.11.2, lifted VERBATIM from
-- exeris-kernel-community db/migration/. Added 2026-08-19 with the 0.10.2 -> 0.11.0 bump.
--
-- WHY THIS BLOCK EXISTS AND WHY IT IS DANGEROUS TO FORGET
--
-- The CREATE TABLE above is a copy of the kernel's own V0.7.0 migration, taken so the seed
-- matches the runtime's schema exactly. A copy of an upstream schema has to track upstream,
-- and this one did not: the kernel added three columns across 0.11.0-0.11.2 and the seed
-- stayed at the 0.7.0 shape.
--
-- The failure that produced was silent and expensive to chase. On 0.11.0 the saga simply
-- never started: POST /api/v1/orders persisted the order row with a saga_id allocated, and
-- then NOTHING -- no exeris_saga_state row, no outbox event, inventory never reserved, no
-- request to the payment gateway, and not one exception or warning in the target log. The
-- §3.1 preflight saw SAGA_INITIATED for 30 s and failed closed. It looked like a kernel
-- regression; it was this table missing three columns that the store's INSERT/UPDATE names.
--
-- When bumping the kernel again, diff db/migration/ inside exeris-kernel-community against
-- this file. Every ALTER is IF NOT EXISTS, so re-applying is free and skipping is not.
-- The better fix is to let CommunityPersistenceMigrationRunner own this table outright;
-- until then, this copy is load-bearing.
-- ---------------------------------------------------------------------------

-- V0.11.0__add_saga_step_name.sql (ADR-062, flow step identity on resume)
ALTER TABLE exeris_saga_state
    ADD COLUMN IF NOT EXISTS step_name VARCHAR(255);

-- V0.11.1__add_saga_definition_version.sql (ADR-064, flow definition versioning)
ALTER TABLE exeris_saga_state
    ADD COLUMN IF NOT EXISTS definition_version INTEGER NOT NULL DEFAULT 0;

-- V0.11.2__add_saga_compensation_step_names.sql (ADR-064 amendment A5). Nullable by
-- design: a row written before the column existed reads back as no identities recorded,
-- which resume treats as COMPENSATION_STACK_IDENTITY_ABSENT rather than trusting it.
ALTER TABLE exeris_saga_state
    ADD COLUMN IF NOT EXISTS compensation_step_names BYTEA;

COMMIT;
