-- migration: v0_clean
-- purpose: Truncate all benchmark application tables before re-seeding.
-- idempotency: Truncates only tables that exist; safe on empty/fresh DB.
-- run: always first, before v1_core/v2_shop/v3_outbox_axon
-- dependency order: cascade handles FK-dependent tables automatically.

DO $$
DECLARE
  tbl text;
  tables_to_clean text[] := ARRAY[
    'order_items', 'orders',
    'cart_items', 'carts',
    'user_purchase_history',
    'product_relationships',
    'inventory',
    'user_interests',
    'friendships',
    'user_principals',
    'products',
    'interests',
    'users',
    'entities',
    'exeris_outbox',
    'exeris_outbox_dlq',
    'domain_event_entry',
    'snapshot_entry',
    -- Axon's real snapshot table name, plus the JPA saga store's two tables. Empty while
    -- Axon Server held the stores; the embedded arm (CONTRACT-v2 s9(e)) writes all three,
    -- and a saga row surviving into the next rep would let a previous run's saga resume
    -- inside a measurement window. Same reason the Axon Server volume is force-recreated.
    'snapshot_event_entry',
    'saga_entry',
    'association_value_entry',
    'token_entry',
    'in_cart_edges',
    'bought_edges',
    'similar_to_edges',
    'graph_nodes'
  ];
  existing_tables text[];
BEGIN
  SELECT array_agg(table_name::text ORDER BY table_name)
    INTO existing_tables
    FROM information_schema.tables
   WHERE table_schema = 'public'
     AND table_name = ANY(tables_to_clean);

  IF existing_tables IS NOT NULL AND array_length(existing_tables, 1) > 0 THEN
    EXECUTE format(
      'TRUNCATE %s RESTART IDENTITY CASCADE',
      array_to_string(existing_tables, ', ')
    );
    RAISE NOTICE '[v0_clean] Truncated % table(s): %',
      array_length(existing_tables, 1),
      array_to_string(existing_tables, ', ');
  ELSE
    RAISE NOTICE '[v0_clean] No benchmark tables found — skipping truncate (fresh DB).';
  END IF;
END $$;

-- ---------------------------------------------------------------------------------------
-- Orphaned large objects.
--
-- Axon's @Lob columns are large-object OIDs on PostgreSQL, and TRUNCATE removes the
-- REFERENCES while leaving the objects themselves in pg_largeobject. Across a campaign
-- that writes an event per saga step, that is unbounded growth in a table nothing in the
-- benchmark ever reads — measured as disk, attributed to nothing.
--
-- Unconditional unlink is safe here: this database exists only for the benchmark seed and
-- has no other large-object user. It runs AFTER the truncate above, so nothing live is
-- pointed at what it removes.
-- ---------------------------------------------------------------------------------------
DO $lo_cleanup$
DECLARE
  removed bigint := 0;
BEGIN
  SELECT count(*) INTO removed FROM pg_largeobject_metadata;
  IF removed > 0 THEN
    PERFORM lo_unlink(oid) FROM pg_largeobject_metadata;
    RAISE NOTICE '[v0_clean] Unlinked % orphaned large object(s) left by Axon @Lob columns.', removed;
  END IF;
END
$lo_cleanup$;
