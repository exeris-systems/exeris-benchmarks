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

COMMIT;
