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
