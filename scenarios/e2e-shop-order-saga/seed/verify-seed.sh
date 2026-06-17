#!/usr/bin/env bash
# Verification script for e2e-shop-order-saga benchmark seed
# Checks PostgreSQL row counts and Neo4j graph integrity
# Exit 0 on success, 1 on failure

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Defaults (can be overridden by env vars)
POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
POSTGRES_CONTAINER_NAME="${POSTGRES_CONTAINER_NAME:-exeris-e2e-saga-postgres}"

NEO4J_HOST="${NEO4J_HOST:-localhost}"
NEO4J_PORT="${NEO4J_PORT:-7687}"
NEO4J_USER="${NEO4J_USER:-neo4j}"
NEO4J_PASSWORD="${NEO4J_PASSWORD:-password}"
NEO4J_CONTAINER_NAME="${NEO4J_CONTAINER_NAME:-exeris-e2e-saga-neo4j}"

# Set PostgreSQL password
export PGPASSWORD="${POSTGRES_PASSWORD}"

failed=0
passed=0

echo -e "${YELLOW}=== E2E Saga Seed Verification ===${NC}"
echo ""

# ============================================================================
# PostgreSQL Checks
# ============================================================================

PG_MODE=""

pg_exec() {
  local sql="$1"

  if [[ "$PG_MODE" == "host" ]]; then
    psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
      -v ON_ERROR_STOP=1 -c "$sql"
  elif [[ "$PG_MODE" == "docker" ]]; then
    docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$POSTGRES_CONTAINER_NAME" \
      psql -h localhost -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
      -v ON_ERROR_STOP=1 -c "$sql"
  else
    echo "PostgreSQL mode not initialized" >&2
    return 1
  fi
}

pg_scalar() {
  local sql="$1"
  local raw_output

  if [[ "$PG_MODE" == "host" ]]; then
    raw_output=$(psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
      -t -A -v ON_ERROR_STOP=1 -c "$sql" 2>/dev/null) || return 1
  elif [[ "$PG_MODE" == "docker" ]]; then
    raw_output=$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$POSTGRES_CONTAINER_NAME" \
      psql -h localhost -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
      -t -A -v ON_ERROR_STOP=1 -c "$sql" 2>/dev/null) || return 1
  else
    echo "PostgreSQL mode not initialized" >&2
    return 1
  fi

  printf '%s' "$raw_output" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

if command -v psql &>/dev/null; then
  PG_MODE="host"
elif command -v docker &>/dev/null; then
  if docker inspect "$POSTGRES_CONTAINER_NAME" &>/dev/null && \
    [[ "$(docker inspect -f '{{.State.Running}}' "$POSTGRES_CONTAINER_NAME" 2>/dev/null)" == "true" ]]; then
    PG_MODE="docker"
  else
    echo -e "${RED}[FAIL] Local psql missing and PostgreSQL container '${POSTGRES_CONTAINER_NAME}' is not running${NC}"
    failed=$((failed + 1))
    exit 1
  fi
else
  echo -e "${RED}[FAIL] Local psql missing and docker is unavailable; cannot verify PostgreSQL${NC}"
  failed=$((failed + 1))
  exit 1
fi

echo -e "${YELLOW}Checking PostgreSQL connectivity...${NC}"
if [[ "$PG_MODE" == "host" ]]; then
  echo -e "Using PostgreSQL mode: host"
else
  echo -e "Using PostgreSQL mode: docker (${POSTGRES_CONTAINER_NAME})"
fi

PG_READY=0
for ((attempt=1; attempt<=30; attempt++)); do
  if pg_exec "SELECT 1" &>/dev/null; then
    PG_READY=1
    break
  fi
  sleep 2
done

if [[ "$PG_READY" -eq 1 ]]; then
  echo -e "${GREEN}[OK] PostgreSQL accessible${NC}"
  passed=$((passed + 1))
else
  echo -e "${RED}[FAIL] PostgreSQL not accessible${NC}"
  failed=$((failed + 1))
  exit 1
fi

# Check users table
echo -e "${YELLOW}Checking users table...${NC}"
USERS_COUNT=$(pg_scalar "SELECT COUNT(*) FROM users")

if [[ "$USERS_COUNT" -ge 1000 ]]; then
  echo -e "${GREEN}[OK] users: $USERS_COUNT rows (expected: 1000)${NC}"
  passed=$((passed + 1))
else
  echo -e "${RED}[FAIL] users: $USERS_COUNT rows (expected: >= 1000)${NC}"
  failed=$((failed + 1))
fi

# Check products table
echo -e "${YELLOW}Checking products table...${NC}"
PRODUCTS_COUNT=$(pg_scalar "SELECT COUNT(*) FROM products")

if [[ "$PRODUCTS_COUNT" -ge 500 ]]; then
  echo -e "${GREEN}[OK] products: $PRODUCTS_COUNT rows (expected: 500)${NC}"
  passed=$((passed + 1))
else
  echo -e "${RED}[FAIL] products: $PRODUCTS_COUNT rows (expected: >= 500)${NC}"
  failed=$((failed + 1))
fi

# Check inventory table
echo -e "${YELLOW}Checking inventory table...${NC}"
INVENTORY_COUNT=$(pg_scalar "SELECT COUNT(*) FROM inventory")

if [[ "$INVENTORY_COUNT" -ge 500 ]]; then
  echo -e "${GREEN}[OK] inventory: $INVENTORY_COUNT rows (expected: 500)${NC}"
  passed=$((passed + 1))
else
  echo -e "${RED}[FAIL] inventory: $INVENTORY_COUNT rows (expected: >= 500)${NC}"
  failed=$((failed + 1))
fi

# Check product_relationships table
echo -e "${YELLOW}Checking product_relationships table...${NC}"
RELATIONSHIPS_COUNT=$(pg_scalar "SELECT COUNT(*) FROM product_relationships")

if [[ "$RELATIONSHIPS_COUNT" -ge 1000 ]]; then
  echo -e "${GREEN}[OK] product_relationships: $RELATIONSHIPS_COUNT rows (expected: >= 1000)${NC}"
  passed=$((passed + 1))
else
  echo -e "${RED}[FAIL] product_relationships: $RELATIONSHIPS_COUNT rows (expected: >= 1000)${NC}"
  failed=$((failed + 1))
fi

# Check user_purchase_history table
echo -e "${YELLOW}Checking user_purchase_history table...${NC}"
HISTORY_COUNT=$(pg_scalar "SELECT COUNT(*) FROM user_purchase_history")

if [[ "$HISTORY_COUNT" -ge 1000 ]]; then
  echo -e "${GREEN}[OK] user_purchase_history: $HISTORY_COUNT rows (expected: >= 1000)${NC}"
  passed=$((passed + 1))
else
  echo -e "${RED}[FAIL] user_purchase_history: $HISTORY_COUNT rows (expected: >= 1000)${NC}"
  failed=$((failed + 1))
fi

# Check new e2e saga tables (existence + non-negative counts)
for TABLE_NAME in carts cart_items user_principals exeris_outbox exeris_outbox_dlq exeris_saga_state; do
  echo -e "${YELLOW}Checking ${TABLE_NAME} table...${NC}"
  TABLE_EXISTS=$(pg_scalar "SELECT COUNT(*) FROM information_schema.tables WHERE table_name='${TABLE_NAME}'")
  if [[ "$TABLE_EXISTS" -ge 1 ]]; then
    COUNT_VALUE=$(pg_scalar "SELECT COUNT(*) FROM ${TABLE_NAME}")
    echo -e "${GREEN}[OK] ${TABLE_NAME}: exists, rows=${COUNT_VALUE}${NC}"
    passed=$((passed + 1))
  else
    echo -e "${RED}[FAIL] ${TABLE_NAME}: table missing${NC}"
    failed=$((failed + 1))
  fi
done

# Compute PostgreSQL seed hash (for idempotency verification)
echo -e "${YELLOW}Computing PostgreSQL seed hash...${NC}"
PG_HASH=$(pg_scalar "SELECT md5(CONCAT(
    'users:', (SELECT COUNT(*) FROM users), '|',
    'products:', (SELECT COUNT(*) FROM products), '|',
    'inventory:', (SELECT COUNT(*) FROM inventory), '|',
    'product_relationships:', (SELECT COUNT(*) FROM product_relationships), '|',
    'user_purchase_history:', (SELECT COUNT(*) FROM user_purchase_history), '|',
    'carts:', (SELECT COUNT(*) FROM carts), '|',
    'cart_items:', (SELECT COUNT(*) FROM cart_items), '|',
    'user_principals:', (SELECT COUNT(*) FROM user_principals), '|',
    'exeris_outbox:', (SELECT COUNT(*) FROM exeris_outbox), '|',
    'exeris_outbox_dlq:', (SELECT COUNT(*) FROM exeris_outbox_dlq)
  ))")
echo -e "${GREEN}[OK] PostgreSQL seed hash: $PG_HASH${NC}"

# ============================================================================
# Neo4j Checks (optional, if available)
# ============================================================================

echo ""
echo -e "${YELLOW}Checking Neo4j connectivity...${NC}"

NEO4J_MODE=""

neo4j_exec() {
  local query="$1"

  if [[ "$NEO4J_MODE" == "host" ]]; then
    printf '%s\n' "$query" | cypher-shell -a "bolt://${NEO4J_HOST}:${NEO4J_PORT}" \
      -u "$NEO4J_USER" -p "$NEO4J_PASSWORD" --non-interactive
  elif [[ "$NEO4J_MODE" == "docker" ]]; then
    docker exec -i "$NEO4J_CONTAINER_NAME" \
      cypher-shell -a "bolt://localhost:${NEO4J_PORT}" \
      -u "$NEO4J_USER" -p "$NEO4J_PASSWORD" --non-interactive <<< "$query"
  else
    echo "Neo4j mode not initialized" >&2
    return 1
  fi
}

# Detect Neo4j execution mode
if command -v cypher-shell >/dev/null 2>&1; then
  NEO4J_MODE="host"
elif command -v docker >/dev/null 2>&1; then
  if docker inspect "$NEO4J_CONTAINER_NAME" >/dev/null 2>&1 && \
    [[ "$(docker inspect -f '{{.State.Running}}' "$NEO4J_CONTAINER_NAME" 2>/dev/null)" == "true" ]]; then
    NEO4J_MODE="docker"
  else
    NEO4J_MODE="none"
  fi
else
  NEO4J_MODE="none"
fi

if [[ "$NEO4J_MODE" == "none" ]]; then
  echo -e "${YELLOW}[WARN] Neo4j checks skipped: cypher-shell missing and docker Neo4j container unavailable${NC}"
else
  if [[ "$NEO4J_MODE" == "host" ]]; then
    echo -e "Using Neo4j mode: host"
  else
    echo -e "Using Neo4j mode: docker (${NEO4J_CONTAINER_NAME})"
  fi

  if neo4j_exec "RETURN 1;" &>/dev/null; then
    echo -e "${GREEN}[OK] Neo4j accessible${NC}"
    passed=$((passed + 1))

    # Check Product nodes
    echo -e "${YELLOW}Checking Neo4j Product nodes...${NC}"
    NEO4J_PRODUCT_COUNT=$(neo4j_exec "MATCH (n:Product) RETURN COUNT(n);" 2>/dev/null | tail -1 | tr -d '[:space:]')

    if [[ "$NEO4J_PRODUCT_COUNT" -ge 500 ]] 2>/dev/null; then
      echo -e "${GREEN}[OK] Neo4j Product nodes: $NEO4J_PRODUCT_COUNT (expected: >= 500)${NC}"
      passed=$((passed + 1))
    else
      echo -e "${YELLOW}[WARN] Neo4j Product nodes: $NEO4J_PRODUCT_COUNT (expected: >= 500)${NC}"
      # Neo4j is optional, don't fail on this
    fi
  else
    echo -e "${YELLOW}[WARN] Neo4j not accessible (optional)${NC}"
  fi
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo -e "${YELLOW}=== Seed Verification Summary ===${NC}"
echo -e "Passed: ${GREEN}$passed${NC}"
echo -e "Failed: ${RED}$failed${NC}"

if [[ $failed -eq 0 ]]; then
  echo -e "${GREEN}[OK] All checks passed${NC}"
  echo ""
  echo "Seed integrity verified. Ready for benchmark execution."
  exit 0
else
  echo -e "${RED}[FAIL] Some checks failed${NC}"
  echo ""
  echo "Seed verification failed. Check PostgreSQL and Neo4j connectivity."
  exit 1
fi
