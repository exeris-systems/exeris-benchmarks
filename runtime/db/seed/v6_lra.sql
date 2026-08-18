-- CONTRACT-v2 §4 (parking workload), quarkus MicroProfile LRA arm.
--
-- The LRA id is minted by the coordinator and is the ONLY handle the coordinator
-- gives back when it later calls @Compensate/@Complete — including after a restart,
-- which is the entire reason this arm has an engine at all. Keeping the mapping in a
-- heap map would work right up to the crash it exists to survive, so it lives on the
-- row.
--
-- Nullable and additive: every other stack ignores it, so this migration does not
-- change any other arm's schema surface.
ALTER TABLE orders ADD COLUMN IF NOT EXISTS lra_id VARCHAR(255);
CREATE INDEX IF NOT EXISTS idx_orders_lra ON orders(lra_id);
