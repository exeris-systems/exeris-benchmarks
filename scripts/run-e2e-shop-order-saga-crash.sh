#!/usr/bin/env bash
# CONTRACT-v2 §6 G1 / W3 crash injection.
#
# See scenarios/e2e-shop-order-saga/CRASH-INJECTION.md for the design and for
# what each variant does and does not prove. In short:
#
#   --crash-scope app    (W3a) SIGKILL the target JVM only; stores stay up.
#                        Tests whether saga state is externalised and an
#                        in-flight saga resumes. Cross-stack comparable.
#   --crash-scope stack  (W3b) SIGKILL the target AND its state stores.
#                        Tests store durability (the durability_tier label).
#
# CORRECTNESS ONLY. A crashed run must never feed a latency or throughput table.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

TARGET_APP=""
CONTRACT_ID=""
CRASH_SCOPE="app"
CRASH_AT_SECONDS=45      # into the run, i.e. inside the measurement window
DRAIN_SECONDS=120        # after restart, before judging "stuck"
OUTPUT_DIR=""
GRAPH_TRACK="neo4j"

PG_CONTAINER="exeris-e2e-saga-postgres"
AXON_CONTAINER="exeris-e2e-saga-axonserver"
NEO4J_CONTAINER="exeris-e2e-saga-neo4j"

usage() {
  cat <<'EOF'
Usage: run-e2e-shop-order-saga-crash.sh --target-app <id> --contract-id <id> [options]

  --crash-scope app|stack   app  = SIGKILL target JVM only (W3a, comparable)
                            stack= SIGKILL target + Postgres + Axon Server (W3b)
  --crash-at-seconds <n>    when to crash, measured from k6 start (default 45)
  --drain-seconds <n>       wait after restart before judging (default 120)
  --output-dir <path>       required
  --graph-track <name>      default neo4j
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-app)       TARGET_APP="$2"; shift 2 ;;
    --contract-id)      CONTRACT_ID="$2"; shift 2 ;;
    --crash-scope)      CRASH_SCOPE="$2"; shift 2 ;;
    --crash-at-seconds) CRASH_AT_SECONDS="$2"; shift 2 ;;
    --drain-seconds)    DRAIN_SECONDS="$2"; shift 2 ;;
    --output-dir)       OUTPUT_DIR="$2"; shift 2 ;;
    --graph-track)      GRAPH_TRACK="$2"; shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -z "$TARGET_APP"  ]] && { echo "ERROR: --target-app is required" >&2; exit 1; }
[[ -z "$CONTRACT_ID" ]] && { echo "ERROR: --contract-id is required" >&2; exit 1; }
[[ -z "$OUTPUT_DIR"  ]] && { echo "ERROR: --output-dir is required" >&2; exit 1; }
case "$CRASH_SCOPE" in app|stack) ;; *) echo "ERROR: --crash-scope must be app|stack" >&2; exit 1 ;; esac

mkdir -p "$OUTPUT_DIR"
REPORT_JSON="$OUTPUT_DIR/crash-recovery.json"
BASELINE_LOG="$OUTPUT_DIR/baseline.log"

_psql() { docker exec "$PG_CONTAINER" psql -U postgres -tAF'|' -c "$1" 2>/dev/null || true; }

# Order rows not in a terminal state. Every stack writes orders to Postgres, so
# this is observable without stack-specific instrumentation. A durable saga
# drives every in-flight order to a terminal status after recovery.
_nonterminal_orders() {
  _psql "select coalesce(sum(case when status not in ('COMPLETED','CANCELLED','FAILED_UNRECOVERED') then 1 else 0 end),0) from orders"
}
_status_breakdown() {
  _psql "select status||'='||count(*) from orders group by status order by status" | paste -sd',' -
}
# Duplicated PAYMENT_REQUESTED for one order == the step was re-executed rather
# than resumed (an O1 duplicate-execution signal, not a resumption).
_duplicate_payment_steps() {
  _psql "select coalesce(count(*),0) from (select aggregate_id from exeris_outbox where event_type='PAYMENT_REQUESTED' group by aggregate_id having count(*) > 1) d"
}

_target_pid() {
  local port
  port="$(jq -r --arg id "$TARGET_APP" '.targets[]|select(.target_id==$id)|.health_url' \
    runtime/drivers/target-asset-matrix.json 2>/dev/null | grep -oE ':[0-9]+' | tr -d ':' | head -1)"
  [[ -z "$port" ]] && return 0
  ss -ltnp 2>/dev/null | grep ":${port} " | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2 || true
}

echo "=== CONTRACT-v2 §6 G1 / W3 crash injection ==="
echo "  target=${TARGET_APP} contract=${CONTRACT_ID} scope=${CRASH_SCOPE}"
echo "  crash at t+${CRASH_AT_SECONDS}s, drain ${DRAIN_SECONDS}s"
echo "  CORRECTNESS ONLY — these numbers must never enter a latency or throughput table."

# The baseline drives seed + target start + k6. Run it in the background so the
# crash can be injected mid-flight.
bash "$SCRIPT_DIR/run-e2e-shop-order-saga-baseline.sh" \
  --target-app "$TARGET_APP" --contract-id "$CONTRACT_ID" \
  --graph-track "$GRAPH_TRACK" --fault-mode terminal \
  --output-dir "$OUTPUT_DIR/run" --force-restart-target > "$BASELINE_LOG" 2>&1 &
BASELINE_PID=$!

# Wait for the target to be serving before starting the crash clock, so
# crash_at is measured from load start rather than from seeding.
for _ in $(seq 1 180); do
  [[ -n "$(_target_pid)" ]] && break
  sleep 2
done
TARGET_PID="$(_target_pid)"
[[ -z "$TARGET_PID" ]] && { echo "ERROR: target never came up; aborting crash run." >&2; kill "$BASELINE_PID" 2>/dev/null || true; exit 1; }
echo "Target up as pid ${TARGET_PID}; waiting ${CRASH_AT_SECONDS}s before crashing."
sleep "$CRASH_AT_SECONDS"

PRE_NONTERMINAL="$(_nonterminal_orders)"
PRE_BREAKDOWN="$(_status_breakdown)"
echo "Pre-crash: non-terminal orders=${PRE_NONTERMINAL} (${PRE_BREAKDOWN})"

echo "=== CRASH (scope=${CRASH_SCOPE}) ==="
kill -9 "$TARGET_PID" 2>/dev/null || true
if [[ "$CRASH_SCOPE" == "stack" ]]; then
  # SIGKILL the stores too — no graceful shutdown, no flush.
  docker kill "$PG_CONTAINER" >/dev/null 2>&1 || true
  docker kill "$AXON_CONTAINER" >/dev/null 2>&1 || true
fi
CRASH_EPOCH="$(date +%s)"
sleep 5

if [[ "$CRASH_SCOPE" == "stack" ]]; then
  echo "Restarting stores..."
  docker start "$PG_CONTAINER" >/dev/null 2>&1 || true
  docker start "$AXON_CONTAINER" >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do
    docker exec "$PG_CONTAINER" pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 2
  done
fi

# The baseline owns the k6 run; let it finish or fail, then restart the target
# for recovery. Recovery is what is under test, so the target must come back.
wait "$BASELINE_PID" 2>/dev/null || true
echo "Restarting target for recovery..."
( set -a; . "runtime/drivers/env/$(jq -r --arg id "$TARGET_APP" '.targets[]|select(.target_id==$id)|.env_file' runtime/drivers/target-asset-matrix.json | xargs basename)"; set +a
  export EXERIS_SUBSYSTEMS="http,persistence,graph,flow,events,crypto"
  export EXERIS_GRAPH_BACKEND_TYPE=neo4j
  export EXERIS_GRAPH_NEO4J_URI=bolt://localhost:7687 EXERIS_GRAPH_NEO4J_USER=neo4j
  export EXERIS_GRAPH_NEO4J_PASSWORD=password EXERIS_GRAPH_NEO4J_DATABASE=neo4j
  eval "$EXTERNAL_START_CMD" ) >> "$BASELINE_LOG" 2>&1 || true

echo "Draining ${DRAIN_SECONDS}s for saga recovery..."
sleep "$DRAIN_SECONDS"

POST_NONTERMINAL="$(_nonterminal_orders)"
POST_BREAKDOWN="$(_status_breakdown)"
DUP_STEPS="$(_duplicate_payment_steps)"
echo "Post-recovery: non-terminal orders=${POST_NONTERMINAL} (${POST_BREAKDOWN})"
echo "Orders with duplicated PAYMENT_REQUESTED (re-execution signal): ${DUP_STEPS}"

jq -n \
  --arg target "$TARGET_APP" --arg contract "$CONTRACT_ID" --arg scope "$CRASH_SCOPE" \
  --arg pre "$PRE_NONTERMINAL" --arg post "$POST_NONTERMINAL" \
  --arg pre_b "$PRE_BREAKDOWN" --arg post_b "$POST_BREAKDOWN" \
  --arg dup "$DUP_STEPS" --argjson crash_epoch "${CRASH_EPOCH:-0}" \
  --argjson drain "$DRAIN_SECONDS" \
  --arg generated_at_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
     schema_version: "1",
     contract_ref: "scenarios/e2e-shop-order-saga/CONTRACT-v2.md#6",
     design_ref: "scenarios/e2e-shop-order-saga/CRASH-INJECTION.md",
     fault_class: "crash",
     crash_scope: $scope,
     scope_meaning: (if $scope == "app"
       then "SIGKILL of the target JVM only; Postgres/Neo4j/Axon Server stayed up. Tests whether saga state is externalised and an in-flight saga resumes. Cross-stack comparable."
       else "SIGKILL of the target JVM AND Postgres/Axon Server. Tests STORE durability, i.e. the durability_tier label. Says nothing about application-level resumption."
       end),
     target_app: $target, contract_id: $contract,
     crash_epoch_s: $crash_epoch, drain_seconds: $drain,
     nonterminal_orders_pre_crash:  ($pre  | tonumber? // null),
     nonterminal_orders_post_drain: ($post | tonumber? // null),
     order_status_pre_crash:  $pre_b,
     order_status_post_drain: $post_b,
     orders_with_duplicate_payment_step: ($dup | tonumber? // null),
     verdict:
       (if ($post | tonumber? // 1) == 0 then "all_sagas_reached_terminal_state"
        else "sagas_stranded_after_recovery" end),
     interpretation: "nonterminal_orders_post_drain > 0 means in-flight sagas did NOT resume after the crash. orders_with_duplicate_payment_step > 0 means a step was RE-EXECUTED rather than resumed, which is a duplicate-execution (O1) signal, not recovery.",
     claim_limits: "CORRECTNESS ONLY. Never cite in a latency or throughput table. Not a full §7 oracle: no per-(orderId,stepId,direction) ledger, so LIFO ordering stays unverified.",
     generated_at_utc: $generated_at_utc
   }' > "$REPORT_JSON"

echo "Crash-recovery report: $REPORT_JSON"
jq -c '{crash_scope, nonterminal_orders_pre_crash, nonterminal_orders_post_drain, orders_with_duplicate_payment_step, verdict}' "$REPORT_JSON"
