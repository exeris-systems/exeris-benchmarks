#!/usr/bin/env bash
set -euo pipefail

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

export PGPASSWORD="${POSTGRES_PASSWORD}"
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-3}"

PG_MODE=""
NEO4J_MODE=""
READY_MAX_ATTEMPTS="${READY_MAX_ATTEMPTS:-30}"
READY_RETRY_SLEEP_SECONDS="${READY_RETRY_SLEEP_SECONDS:-2}"
PG_FALLBACK_AFTER_ATTEMPTS="${PG_FALLBACK_AFTER_ATTEMPTS:-3}"
SEED_PROGRESS_EVERY="${SEED_PROGRESS_EVERY:-100}"
SEED_BATCH_SIZE="${SEED_BATCH_SIZE:-200}"

if ! [[ "$SEED_BATCH_SIZE" =~ ^[1-9][0-9]*$ ]]; then
  echo "SEED_BATCH_SIZE must be a positive integer (got: ${SEED_BATCH_SIZE})." >&2
  exit 1
fi

pg_scalar() {
  local sql="$1"
  local raw

  if [[ "$PG_MODE" == "host" ]]; then
    raw="$(psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
      -t -A -v ON_ERROR_STOP=1 -c "$sql")"
  elif [[ "$PG_MODE" == "docker" ]]; then
    raw="$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$POSTGRES_CONTAINER_NAME" \
      psql -h localhost -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
      -t -A -v ON_ERROR_STOP=1 -c "$sql")"
  else
    echo "PostgreSQL mode not initialized" >&2
    return 1
  fi

  printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

pg_query_stream() {
  local sql="$1"

  if [[ "$PG_MODE" == "host" ]]; then
    psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
      -t -A -F $'\t' -v ON_ERROR_STOP=1 -c "$sql"
  elif [[ "$PG_MODE" == "docker" ]]; then
    docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$POSTGRES_CONTAINER_NAME" \
      psql -h localhost -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
      -t -A -F $'\t' -v ON_ERROR_STOP=1 -c "$sql"
  else
    echo "PostgreSQL mode not initialized" >&2
    return 1
  fi
}

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

cypher_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\'/\\\'}"
  value="${value//$'\n'/ }"
  value="${value//$'\r'/ }"
  printf "'%s'" "$value"
}

detect_pg_mode() {
  if command -v psql >/dev/null 2>&1; then
    PG_MODE="host"
    return 0
  fi

  if command -v docker >/dev/null 2>&1 && \
    docker inspect "$POSTGRES_CONTAINER_NAME" >/dev/null 2>&1 && \
    [[ "$(docker inspect -f '{{.State.Running}}' "$POSTGRES_CONTAINER_NAME" 2>/dev/null)" == "true" ]]; then
    PG_MODE="docker"
    return 0
  fi

  echo "Unable to access PostgreSQL: local psql unavailable and docker fallback container is not running (${POSTGRES_CONTAINER_NAME})." >&2
  return 1
}

pg_docker_available() {
  command -v docker >/dev/null 2>&1 && \
    docker inspect "$POSTGRES_CONTAINER_NAME" >/dev/null 2>&1 && \
    [[ "$(docker inspect -f '{{.State.Running}}' "$POSTGRES_CONTAINER_NAME" 2>/dev/null)" == "true" ]]
}

detect_neo4j_mode() {
  if command -v cypher-shell >/dev/null 2>&1; then
    NEO4J_MODE="host"
    return 0
  fi

  if command -v docker >/dev/null 2>&1 && \
    docker inspect "$NEO4J_CONTAINER_NAME" >/dev/null 2>&1 && \
    [[ "$(docker inspect -f '{{.State.Running}}' "$NEO4J_CONTAINER_NAME" 2>/dev/null)" == "true" ]]; then
    NEO4J_MODE="docker"
    return 0
  fi

  echo "Unable to access Neo4j: local cypher-shell unavailable and docker fallback container is not running (${NEO4J_CONTAINER_NAME})." >&2
  return 1
}

wait_for_pg() {
  local attempt err
  for ((attempt=1; attempt<=READY_MAX_ATTEMPTS; attempt++)); do
    if err="$(pg_scalar "SELECT 1" 2>&1 >/dev/null)"; then
      echo "PostgreSQL ready (mode=${PG_MODE}, attempt=${attempt}/${READY_MAX_ATTEMPTS})."
      return 0
    fi

    if [[ "$PG_MODE" == "host" && "$attempt" -ge "$PG_FALLBACK_AFTER_ATTEMPTS" ]] && pg_docker_available; then
      echo "PostgreSQL host probe failed after ${attempt} attempts; switching to docker mode (${POSTGRES_CONTAINER_NAME})." >&2
      PG_MODE="docker"
      continue
    fi

    echo "PostgreSQL not ready yet (mode=${PG_MODE}, attempt=${attempt}/${READY_MAX_ATTEMPTS}): ${err:-no output}" >&2
    sleep "$READY_RETRY_SLEEP_SECONDS"
  done
  echo "PostgreSQL not reachable after ${READY_MAX_ATTEMPTS} attempts (mode=${PG_MODE}, sleep=${READY_RETRY_SLEEP_SECONDS}s, PGCONNECT_TIMEOUT=${PGCONNECT_TIMEOUT}s)." >&2
  return 1
}

wait_for_neo4j() {
  local attempt err
  for ((attempt=1; attempt<=READY_MAX_ATTEMPTS; attempt++)); do
    if err="$(neo4j_exec "RETURN 1;" 2>&1 >/dev/null)"; then
      echo "Neo4j ready (mode=${NEO4J_MODE}, attempt=${attempt}/${READY_MAX_ATTEMPTS})."
      return 0
    fi
    echo "Neo4j not ready yet (mode=${NEO4J_MODE}, attempt=${attempt}/${READY_MAX_ATTEMPTS}): ${err:-no output}" >&2
    sleep "$READY_RETRY_SLEEP_SECONDS"
  done
  echo "Neo4j not reachable after ${READY_MAX_ATTEMPTS} attempts (mode=${NEO4J_MODE}, sleep=${READY_RETRY_SLEEP_SECONDS}s)." >&2
  return 1
}

echo "== Neo4j seed from PostgreSQL (e2e-shop-order-saga) =="

detect_pg_mode
detect_neo4j_mode

echo "PostgreSQL mode: ${PG_MODE}"
echo "Neo4j mode: ${NEO4J_MODE}"

wait_for_pg
wait_for_neo4j

echo "[neo4j-seed] Clearing existing graph data (MATCH (n) DETACH DELETE n)..."
neo4j_exec "MATCH (n) CALL { WITH n DETACH DELETE n } IN TRANSACTIONS OF 50000 ROWS;" >/dev/null
echo "[neo4j-seed] Graph cleared."

neo4j_exec "CREATE CONSTRAINT product_id_unique IF NOT EXISTS FOR (p:Product) REQUIRE p.id IS UNIQUE;" >/dev/null
neo4j_exec "CREATE CONSTRAINT user_id_unique IF NOT EXISTS FOR (u:User) REQUIRE u.id IS UNIQUE;" >/dev/null

product_rows=0
product_batch_rows=0
product_batch_number=0
product_batch_items=""
echo "Seeding Product nodes from PostgreSQL..."
while IFS=$'\t' read -r product_id product_name product_category product_price; do
  [[ -z "${product_id//[[:space:]]/}" ]] && continue

  product_item="{id: ${product_id}, name: $(cypher_quote "$product_name"), category: $(cypher_quote "$product_category"), price: ${product_price}}"
  if [[ -z "$product_batch_items" ]]; then
    product_batch_items="$product_item"
  else
    product_batch_items+="${product_batch_items:+, }${product_item}"
  fi

  product_batch_rows=$((product_batch_rows + 1))
  product_rows=$((product_rows + 1))
  if (( product_batch_rows >= SEED_BATCH_SIZE )); then
    product_batch_number=$((product_batch_number + 1))
    neo4j_exec "UNWIND [${product_batch_items}] AS row MERGE (p:Product {id: toInteger(row.id)}) SET p.name = row.name, p.category = row.category, p.price = toFloat(row.price);" >/dev/null
    echo "  Product batch ${product_batch_number}: ${product_batch_rows} rows written (total ${product_rows})"
    product_batch_items=""
    product_batch_rows=0
  fi
  if (( product_rows % SEED_PROGRESS_EVERY == 0 )); then
    echo "  Product progress: ${product_rows} rows processed"
  fi
done < <(pg_query_stream "SELECT id, name, category, COALESCE(price, 0)::text FROM products ORDER BY id")

if (( product_batch_rows > 0 )); then
  product_batch_number=$((product_batch_number + 1))
  neo4j_exec "UNWIND [${product_batch_items}] AS row MERGE (p:Product {id: toInteger(row.id)}) SET p.name = row.name, p.category = row.category, p.price = toFloat(row.price);" >/dev/null
  echo "  Product batch ${product_batch_number}: ${product_batch_rows} rows written (final, total ${product_rows})"
fi

user_rows=0
user_batch_rows=0
user_batch_number=0
user_batch_items=""
echo "Seeding User nodes from PostgreSQL purchase history..."
while IFS=$'\t' read -r user_id; do
  [[ -z "${user_id//[[:space:]]/}" ]] && continue

  user_item="{id: ${user_id}}"
  if [[ -z "$user_batch_items" ]]; then
    user_batch_items="$user_item"
  else
    user_batch_items+="${user_batch_items:+, }${user_item}"
  fi

  user_batch_rows=$((user_batch_rows + 1))
  user_rows=$((user_rows + 1))
  if (( user_batch_rows >= SEED_BATCH_SIZE )); then
    user_batch_number=$((user_batch_number + 1))
    neo4j_exec "UNWIND [${user_batch_items}] AS row MERGE (u:User {id: toInteger(row.id)});" >/dev/null
    echo "  User batch ${user_batch_number}: ${user_batch_rows} rows written (total ${user_rows})"
    user_batch_items=""
    user_batch_rows=0
  fi
  if (( user_rows % SEED_PROGRESS_EVERY == 0 )); then
    echo "  User progress: ${user_rows} rows processed"
  fi
done < <(pg_query_stream "SELECT DISTINCT user_id FROM user_purchase_history ORDER BY user_id")

if (( user_batch_rows > 0 )); then
  user_batch_number=$((user_batch_number + 1))
  neo4j_exec "UNWIND [${user_batch_items}] AS row MERGE (u:User {id: toInteger(row.id)});" >/dev/null
  echo "  User batch ${user_batch_number}: ${user_batch_rows} rows written (final, total ${user_rows})"
fi

similar_rows=0
similar_batch_rows=0
similar_batch_number=0
similar_batch_items=""
echo "Seeding SIMILAR_TO relationships..."
while IFS=$'\t' read -r source_product_id target_product_id similarity_score; do
  [[ -z "${source_product_id//[[:space:]]/}" ]] && continue
  [[ -z "${target_product_id//[[:space:]]/}" ]] && continue

  similar_item="{source_product_id: ${source_product_id}, target_product_id: ${target_product_id}, similarity_score: ${similarity_score}}"
  if [[ -z "$similar_batch_items" ]]; then
    similar_batch_items="$similar_item"
  else
    similar_batch_items+="${similar_batch_items:+, }${similar_item}"
  fi

  similar_batch_rows=$((similar_batch_rows + 1))
  similar_rows=$((similar_rows + 1))
  if (( similar_batch_rows >= SEED_BATCH_SIZE )); then
    similar_batch_number=$((similar_batch_number + 1))
    neo4j_exec "UNWIND [${similar_batch_items}] AS row MERGE (source:Product {id: toInteger(row.source_product_id)}) MERGE (target:Product {id: toInteger(row.target_product_id)}) MERGE (source)-[r:SIMILAR_TO]->(target) SET r.similarity_score = toFloat(row.similarity_score);" >/dev/null
    echo "  SIMILAR_TO batch ${similar_batch_number}: ${similar_batch_rows} rows written (total ${similar_rows})"
    similar_batch_items=""
    similar_batch_rows=0
  fi
  if (( similar_rows % SEED_PROGRESS_EVERY == 0 )); then
    echo "  SIMILAR_TO progress: ${similar_rows} rows processed"
  fi
done < <(pg_query_stream "SELECT source_product_id, target_product_id, COALESCE(similarity_score, 0)::text FROM product_relationships ORDER BY source_product_id, target_product_id")

if (( similar_batch_rows > 0 )); then
  similar_batch_number=$((similar_batch_number + 1))
  neo4j_exec "UNWIND [${similar_batch_items}] AS row MERGE (source:Product {id: toInteger(row.source_product_id)}) MERGE (target:Product {id: toInteger(row.target_product_id)}) MERGE (source)-[r:SIMILAR_TO]->(target) SET r.similarity_score = toFloat(row.similarity_score);" >/dev/null
  echo "  SIMILAR_TO batch ${similar_batch_number}: ${similar_batch_rows} rows written (final, total ${similar_rows})"
fi

purchased_rows=0
purchased_batch_rows=0
purchased_batch_number=0
purchased_batch_items=""
echo "Seeding PURCHASED_BY relationships..."
while IFS=$'\t' read -r history_user_id history_product_id purchased_at; do
  [[ -z "${history_user_id//[[:space:]]/}" ]] && continue
  [[ -z "${history_product_id//[[:space:]]/}" ]] && continue

  purchased_item="{user_id: ${history_user_id}, product_id: ${history_product_id}, purchase_date: $(cypher_quote "$purchased_at")}"
  if [[ -z "$purchased_batch_items" ]]; then
    purchased_batch_items="$purchased_item"
  else
    purchased_batch_items+="${purchased_batch_items:+, }${purchased_item}"
  fi

  purchased_batch_rows=$((purchased_batch_rows + 1))
  purchased_rows=$((purchased_rows + 1))
  if (( purchased_batch_rows >= SEED_BATCH_SIZE )); then
    purchased_batch_number=$((purchased_batch_number + 1))
    neo4j_exec "UNWIND [${purchased_batch_items}] AS row MERGE (p:Product {id: toInteger(row.product_id)}) MERGE (u:User {id: toInteger(row.user_id)}) MERGE (p)-[r:PURCHASED_BY]->(u) SET r.purchase_date = row.purchase_date;" >/dev/null
    echo "  PURCHASED_BY batch ${purchased_batch_number}: ${purchased_batch_rows} rows written (total ${purchased_rows})"
    purchased_batch_items=""
    purchased_batch_rows=0
  fi
  if (( purchased_rows % SEED_PROGRESS_EVERY == 0 )); then
    echo "  PURCHASED_BY progress: ${purchased_rows} rows processed"
  fi
done < <(pg_query_stream "SELECT user_id, product_id, purchased_at::text FROM user_purchase_history ORDER BY user_id, product_id")

if (( purchased_batch_rows > 0 )); then
  purchased_batch_number=$((purchased_batch_number + 1))
  neo4j_exec "UNWIND [${purchased_batch_items}] AS row MERGE (p:Product {id: toInteger(row.product_id)}) MERGE (u:User {id: toInteger(row.user_id)}) MERGE (p)-[r:PURCHASED_BY]->(u) SET r.purchase_date = row.purchase_date;" >/dev/null
  echo "  PURCHASED_BY batch ${purchased_batch_number}: ${purchased_batch_rows} rows written (final, total ${purchased_rows})"
fi

neo4j_product_count="$(neo4j_exec "MATCH (p:Product) RETURN count(p);" | tail -n 1 | tr -d '[:space:]')"
neo4j_user_count="$(neo4j_exec "MATCH (u:User) RETURN count(u);" | tail -n 1 | tr -d '[:space:]')"
neo4j_similar_count="$(neo4j_exec "MATCH (:Product)-[r:SIMILAR_TO]->(:Product) RETURN count(r);" | tail -n 1 | tr -d '[:space:]')"
neo4j_purchased_count="$(neo4j_exec "MATCH (:Product)-[r:PURCHASED_BY]->(:User) RETURN count(r);" | tail -n 1 | tr -d '[:space:]')"

echo "Seeded from PostgreSQL rows:"
echo "  products: ${product_rows}"
echo "  users(from purchase history): ${user_rows}"
echo "  SIMILAR_TO relationships: ${similar_rows}"
echo "  PURCHASED_BY relationships: ${purchased_rows}"
echo ""
echo "Neo4j graph summary after seeding:"
echo "  Product nodes: ${neo4j_product_count}"
echo "  User nodes: ${neo4j_user_count}"
echo "  SIMILAR_TO edges: ${neo4j_similar_count}"
echo "  PURCHASED_BY edges: ${neo4j_purchased_count}"

echo "Neo4j seeding completed successfully."