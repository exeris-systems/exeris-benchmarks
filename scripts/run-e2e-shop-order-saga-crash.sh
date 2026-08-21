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
GRAPH_TRACK="none"       # v2.1 removed the graph from this scenario entirely (§2)

PG_CONTAINER="exeris-e2e-saga-postgres"
AXON_CONTAINER="exeris-e2e-saga-axonserver"
LRA_CONTAINER="exeris-e2e-saga-lra-coordinator"
RESTATE_CONTAINER="exeris-e2e-saga-restate-server"
CRASHED_COORDINATORS=""

usage() {
  cat <<'EOF'
Usage: run-e2e-shop-order-saga-crash.sh --target-app <id> --contract-id <id> [options]

  --crash-scope app|stack   app  = SIGKILL target JVM only (W3a, comparable)
                            stack= SIGKILL target + Postgres + Axon Server (W3b)
  --crash-at-seconds <n>    when to crash, measured from TARGET READINESS (default 45).
                            Not from k6 start: the clock starts when the target's port
                            listens, which precedes seeding and the warmup window. Add
                            the seed time and K6_WARMUP_DURATION to land inside the
                            measurement window, and check the pre-crash order count to
                            confirm the crash happened under load.
  --drain-seconds <n>       wait after restart before judging (default 120)
  --output-dir <path>       required
  --graph-track <name>      default none (v2.1 removed the graph from this scenario)
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

# CONTRACT-v2 §3.1 discipline, applied to the DOMAIN ROW rather than the HTTP response.
# The two are different vocabularies and must not be swapped: terminal_vocabulary describes
# the polled/inline status field, where COMPENSATED is terminal and never appears in the
# orders table, while CANCELLED appears in the table and is unknown to that field. The
# 2026-08-21 W3a run hardcoded a guess here and got quarkus-lra wrong (it writes FAILED,
# the guess said FAILED_UNRECOVERED). Declared, verified, never inferred.
_SCENARIO_JSON="scenarios/e2e-shop-order-saga/scenario.json"
_vocab() {
  jq -r --arg c "$CONTRACT_ID" --arg k "$1"     '.fixed_contracts[$c].domain_row_vocabulary[$k] // [] | .[]' "$_SCENARIO_JSON" 2>/dev/null
}
_sql_list() { sed "s/.*/'&'/" | paste -sd',' - ; }
TERMINAL_SQL="$(_vocab terminal_tokens    | _sql_list)"
NONTERM_SQL="$( _vocab non_terminal_tokens | _sql_list)"
if [[ -z "$TERMINAL_SQL" ]]; then
  echo "ERROR: contract ${CONTRACT_ID} declares no domain_row_vocabulary.terminal_tokens in" >&2
  echo "ERROR:   ${_SCENARIO_JSON}" >&2
  echo "ERROR: this census will not guess a terminal set. Declare it, verified against the" >&2
  echo "ERROR: target's status write sites, exactly as §3.1 requires for the response field." >&2
  exit 65
fi
[[ -z "$NONTERM_SQL" ]] && NONTERM_SQL="''"

# One round trip, so the breakdown and the counts describe the SAME instant. Two separate
# queries under load disagreed by 3 orders in the 2026-08-21 run, which made every printed
# pre/post pair internally inconsistent with its own breakdown.
# Emits: breakdown|total|nonterminal|undeclared_tokens
_census() {
  _psql "select coalesce(string_agg(status||'='||n, ',' order by status),'')
         ||'|'|| coalesce(sum(n),0)
         ||'|'|| coalesce(sum(n) filter (where status not in (${TERMINAL_SQL})),0)
         ||'|'|| coalesce(string_agg(status, ',' order by status) filter (
                   where status not in (${TERMINAL_SQL})
                     and status not in (${NONTERM_SQL})),'')
         from (select status, count(*) n from orders group by status) s"
}

# Engine-side saga state, as distinct from the domain row. exeris-kernel Community selects a
# durable JdbcFlowSnapshotStore over exeris_saga_state when a PersistenceEngine is bootstrapped
# and flow.persistenceEnabled is true, and falls back to the heap CommunityFlowSnapshotStore
# when it is not (ADR-022; kernel docs/subsystems/flow.md). Those two are indistinguishable
# from the orders table alone, and they are completely different claims about the arm: one is
# "the engine cannot resume", the other is "we did not bind the store". PARKED rows here at
# the crash decide which. Other arms keep their engine state elsewhere and simply read zero.
_saga_state_census() {
  _psql "select coalesce(string_agg(state||'='||n, ',' order by state),'')
         from (select state, count(*) n from exeris_saga_state group by state) s"
}

# The identities of the sagas that were in flight at the crash. Counting non-terminal rows
# before and after answers "how many are stuck NOW", which is not the question: k6 keeps
# submitting through the restart, so a post-drain count is a mix of sagas that failed to
# resume and sagas that merely arrived late. On 2026-08-21 exeris went 3 -> 3, which reads
# as "resumed nothing" and is equally consistent with "resumed all three and stranded three
# new ones". Only the id list distinguishes those.
_nonterminal_ids() {
  _psql "select id from orders where status not in (${TERMINAL_SQL})" | tr -d ''
}

# Per-arm write census on the domain table. exeris/restate persist four status transitions
# per successful saga, spring/quarkus five (they also persist the authorization outcome),
# and §2 declares no required sequence — so the difference gets measured here rather than
# argued from source. n_tup_hot_upd separates the HOT-updatable share.
_orders_write_counters() {
  _psql "select coalesce(n_tup_ins,0)||'|'||coalesce(n_tup_upd,0)||'|'||coalesce(n_tup_hot_upd,0)
         from pg_stat_user_tables where relname='orders'"
}

# Duplicated PAYMENT_REQUESTED for one order == the step was re-executed rather
# than resumed (an O1 duplicate-execution signal, not a resumption).
#
# The table name reads exeris-specific and is not: verified 2026-08-21 that all 8232 outbox
# rows present after a restate run joined to that run's orders, with event counts tracking
# its order counts (PAYMENT_REQUESTED 4120 / ORDER_CONFIRMED 3992 / ORDER_COMPENSATED 120).
# exeris_outbox is the shared domain-persistence table §2 requires of every arm, so this is
# a cross-arm signal. Do not "fix" it by scoping it to the exeris arm.
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

WRITES_BEFORE="$(_orders_write_counters)"

# The baseline drives seed + target start + k6. Run it in the background so the
# crash can be injected mid-flight.
# Tell the baseline a fault is coming, so its no-fault §4.1 exact-equality leg reports
# "not applicable" instead of marking the run compensation_mismatch for doing what we asked.
BENCH_SAGA_FAULT_INJECTION="crash-scope-${CRASH_SCOPE}" \
bash "$SCRIPT_DIR/run-e2e-shop-order-saga-baseline.sh" \
  --target-app "$TARGET_APP" --contract-id "$CONTRACT_ID" \
  --graph-track "$GRAPH_TRACK" --fault-mode terminal \
  --output-dir "$OUTPUT_DIR/run" --force-restart-target > "$BASELINE_LOG" 2>&1 &
BASELINE_PID=$!

# Wait for the target to be serving before starting the crash clock. NOTE this is target
# readiness, NOT load start — seeding and the warmup window still follow. The pre-crash
# order count in the report is the check that the crash landed under load.
for _ in $(seq 1 180); do
  [[ -n "$(_target_pid)" ]] && break
  sleep 2
done
TARGET_PID="$(_target_pid)"
[[ -z "$TARGET_PID" ]] && { echo "ERROR: target never came up; aborting crash run." >&2; kill "$BASELINE_PID" 2>/dev/null || true; exit 1; }
echo "Target up as pid ${TARGET_PID}; waiting ${CRASH_AT_SECONDS}s before crashing."
sleep "$CRASH_AT_SECONDS"

IFS='|' read -r PRE_BREAKDOWN PRE_TOTAL PRE_NONTERMINAL PRE_UNKNOWN <<< "$(_census)"
PRE_NONTERM_IDS="$(_nonterminal_ids | paste -sd',' -)"
PRE_SAGA_STATE="$(_saga_state_census)"
echo "Pre-crash: orders=${PRE_TOTAL:-0} non-terminal=${PRE_NONTERMINAL:-0} (${PRE_BREAKDOWN})"
[[ -n "${PRE_UNKNOWN:-}" ]] && echo "  WARNING: undeclared status token(s) present: ${PRE_UNKNOWN}"

echo "=== CRASH (scope=${CRASH_SCOPE}) ==="
kill -9 "$TARGET_PID" 2>/dev/null || true
if [[ "$CRASH_SCOPE" == "stack" ]]; then
  # SIGKILL the stores too — no graceful shutdown, no flush.
  # Kill whichever coordinator this arm actually runs, not only Axon Server. The roster now has
  # three different ones (Axon Server, the LRA coordinator, restate-server) and two arms with
  # none at all; killing a container the arm does not use tests nothing, and NOT killing the one
  # it does use turns a W3b into a W3a wearing the wrong label.
  docker kill "$PG_CONTAINER" >/dev/null 2>&1 || true
  for _coord in "$AXON_CONTAINER" "$LRA_CONTAINER" "$RESTATE_CONTAINER"; do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$_coord" 2>/dev/null || true)" == "true" ]]; then
      echo "  killing coordinator: $_coord"
      docker kill "$_coord" >/dev/null 2>&1 || true
      CRASHED_COORDINATORS="${CRASHED_COORDINATORS:+$CRASHED_COORDINATORS,}$_coord"
    fi
  done
fi
CRASH_EPOCH="$(date +%s)"
sleep 5

if [[ "$CRASH_SCOPE" == "stack" ]]; then
  echo "Restarting stores..."
  docker start "$PG_CONTAINER" >/dev/null 2>&1 || true
  IFS="," read -ra _cc <<< "${CRASHED_COORDINATORS:-}"
  for _coord in "${_cc[@]:-}"; do
    [[ -n "$_coord" ]] && docker start "$_coord" >/dev/null 2>&1 || true
  done
  for _ in $(seq 1 60); do
    docker exec "$PG_CONTAINER" pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 2
  done
fi

# The baseline owns the k6 run; let it finish or fail, then restart the target
# for recovery. Recovery is what is under test, so the target must come back.
wait "$BASELINE_PID" 2>/dev/null || true
echo "Restarting target for recovery..."
# Recovery must bring back the SAME deployment that crashed, so it goes through the very
# starter the baseline used rather than a hand-rolled `eval` of the env file. That eval
# saw neither SERVER_CPU_AFFINITY nor EXTERNAL_PID_FILE, both of which the baseline
# injects: on 2026-08-21 every recovered target came back on all 16 threads instead of
# its 6-thread set (measured 0-15 on the live process), and none could be stopped
# afterwards, so five target JVMs leaked into every following arm.
"$REPO_ROOT/runtime/drivers/start-target.sh" "$TARGET_APP" >> "$BASELINE_LOG" 2>&1 || true

# "Sagas did not resume" only means anything if the process that should have resumed them
# actually came back. Record it rather than assuming it.
RECOVERED_HEALTHY=false
RECOVERED_AFFINITY=""
_health_url="$(jq -r --arg id "$TARGET_APP" '.targets[]|select(.target_id==$id)|.health_url'   runtime/drivers/target-asset-matrix.json 2>/dev/null)"
for _ in $(seq 1 60); do
  if [[ -n "$_health_url" ]] && curl -fsS --max-time 3 "$_health_url" >/dev/null 2>&1; then
    RECOVERED_HEALTHY=true; break
  fi
  sleep 2
done
_rpid="$(_target_pid)"
[[ -n "$_rpid" ]] && RECOVERED_AFFINITY="$(taskset -pc "$_rpid" 2>/dev/null | sed 's/.*list: //' || true)"
echo "Recovered target: healthy=${RECOVERED_HEALTHY} pid=${_rpid:-none} affinity=${RECOVERED_AFFINITY:-unknown}"
if [[ "$RECOVERED_HEALTHY" != "true" ]]; then
  echo "  WARNING: the recovered target never became healthy; a non-zero stranded count below" >&2
  echo "  WARNING: says nothing about resumption and must not be read as one." >&2
fi

echo "Draining ${DRAIN_SECONDS}s for saga recovery..."
sleep "$DRAIN_SECONDS"

IFS='|' read -r POST_BREAKDOWN POST_TOTAL POST_NONTERMINAL POST_UNKNOWN <<< "$(_census)"
DUP_STEPS="$(_duplicate_payment_steps)"
WRITES_AFTER="$(_orders_write_counters)"
# Of the sagas that were in flight at the crash, how many reached a terminal state?
COHORT_SIZE=0; COHORT_RESOLVED=""; COHORT_STILL=""
if [[ -n "$PRE_NONTERM_IDS" ]]; then
  COHORT_SIZE="$(printf '%s' "$PRE_NONTERM_IDS" | tr ',' '
' | grep -c .)"
  COHORT_RESOLVED="$(_psql "select count(*) from orders where id in (${PRE_NONTERM_IDS}) and status in (${TERMINAL_SQL})")"
  COHORT_STILL="$(   _psql "select count(*) from orders where id in (${PRE_NONTERM_IDS}) and status not in (${TERMINAL_SQL})")"
fi
POST_SAGA_STATE="$(_saga_state_census)"
echo "Post-recovery: orders=${POST_TOTAL:-0} non-terminal=${POST_NONTERMINAL:-0} (${POST_BREAKDOWN})"
echo "In-flight cohort at crash: ${COHORT_SIZE} sagas -> resolved=${COHORT_RESOLVED:-n/a} still-stuck=${COHORT_STILL:-n/a}"
echo "Engine saga-state rows: pre=[${PRE_SAGA_STATE:-none}] post=[${POST_SAGA_STATE:-none}]"
[[ -n "${POST_UNKNOWN:-}" ]] && echo "  WARNING: undeclared status token(s) present: ${POST_UNKNOWN}"
echo "Orders with duplicated PAYMENT_REQUESTED (re-execution signal): ${DUP_STEPS}"

# The census has read the store, so the recovered target has no further job. Leaving it up
# is what contaminated the 2026-08-21 campaign: each arm's recovered JVM ran through every
# arm that followed it.
"$REPO_ROOT/runtime/drivers/stop-target.sh" "$TARGET_APP" >> "$BASELINE_LOG" 2>&1 || true
_left="$(_target_pid)"
if [[ -n "$_left" ]]; then
  echo "  WARNING: recovered target still listening as pid ${_left} after stop-target.sh; killing." >&2
  kill "$_left" 2>/dev/null || true
  # Wait for the port to actually free rather than sleeping a fixed 3s: the 2026-08-21 rerun
  # reported a leak on the last arm that was gone moments later, i.e. shutdown latency read
  # as contamination. A campaign checking between arms sees the same race for real.
  for _ in $(seq 1 20); do [[ -z "$(_target_pid)" ]] && break; sleep 1; done
  _left="$(_target_pid)"
  [[ -n "$_left" ]] && { kill -9 "$_left" 2>/dev/null || true; sleep 2; }
fi

jq -n \
  --arg target "$TARGET_APP" --arg contract "$CONTRACT_ID" --arg scope "$CRASH_SCOPE" \
  --arg pre "$PRE_NONTERMINAL" --arg post "$POST_NONTERMINAL" \
  --arg pre_b "$PRE_BREAKDOWN" --arg post_b "$POST_BREAKDOWN" \
  --arg dup "$DUP_STEPS" --argjson crash_epoch "${CRASH_EPOCH:-0}" \
  --arg pre_total "${PRE_TOTAL:-0}" --arg post_total "${POST_TOTAL:-0}" \
  --arg pre_unknown "${PRE_UNKNOWN:-}" --arg post_unknown "${POST_UNKNOWN:-}" \
  --arg term_tokens "$(_vocab terminal_tokens | paste -sd',' -)" \
  --arg healthy "${RECOVERED_HEALTHY:-false}" --arg raff "${RECOVERED_AFFINITY:-}" \
  --arg w_before "${WRITES_BEFORE:-}" --arg w_after "${WRITES_AFTER:-}" \
  --arg coh_n "${COHORT_SIZE:-0}" --arg coh_res "${COHORT_RESOLVED:-}" --arg coh_still "${COHORT_STILL:-}" \
  --arg ss_pre "${PRE_SAGA_STATE:-}" --arg ss_post "${POST_SAGA_STATE:-}" \
  --argjson drain "$DRAIN_SECONDS" \
  --arg coords "${CRASHED_COORDINATORS:-}" \
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
     coordinators_crashed: ($coords | split(",") | map(select(. != ""))),
     total_orders_pre_crash:  ($pre_total  | tonumber? // null),
     total_orders_post_drain: ($post_total | tonumber? // null),
     nonterminal_orders_pre_crash:  ($pre  | tonumber? // null),
     nonterminal_orders_post_drain: ($post | tonumber? // null),
     order_status_pre_crash:  $pre_b,
     order_status_post_drain: $post_b,
     declared_terminal_tokens: ($term_tokens | split(",") | map(select(. != ""))),
     undeclared_status_tokens: (($pre_unknown + "," + $post_unknown) | split(",")
                                 | map(select(. != "")) | unique),
     recovered_target_healthy: ($healthy == "true"),
     recovered_target_affinity: (if $raff == "" then null else $raff end),
     orders_write_counters: {
       note: "pg_stat_user_tables on orders: n_tup_ins|n_tup_upd|n_tup_hot_upd. Counters are not reset, so only the after-minus-before delta is meaningful. exeris/restate persist four status transitions per successful saga, spring/quarkus five; §2 declares no required sequence, so this measures the difference instead of arguing it from source.",
       before: (if $w_before == "" then null else $w_before end),
       after:  (if $w_after  == "" then null else $w_after  end)
     },
     in_flight_cohort_at_crash: {
       note: "The sagas non-terminal at the pre-crash census, tracked BY ID. This is the resumption question; the raw post-drain count is not, because load continues through the restart and mixes late arrivals into it.",
       size:              ($coh_n    | tonumber? // 0),
       resolved_by_drain: ($coh_res  | tonumber? // null),
       still_nonterminal: ($coh_still| tonumber? // null)
     },
     engine_saga_state: {
       note: "Rows in exeris_saga_state by state. Non-empty means a durable FlowSnapshotStore is bound (JdbcFlowSnapshotStore, ADR-022); empty on the exeris arm means the heap CommunityFlowSnapshotStore was selected instead, which is a wiring fact about this deployment, not a statement about what the engine can do. Other arms hold engine state elsewhere and read empty by design.",
       pre_crash:  (if $ss_pre  == "" then null else $ss_pre  end),
       post_drain: (if $ss_post == "" then null else $ss_post end)
     },
     orders_with_duplicate_payment_step: ($dup | tonumber? // null),
     verdict:
       (if (($post_total | tonumber? // 0) == 0)
          then "inconclusive_no_orders_observed"
        elif ((($pre_unknown + $post_unknown) | length) > 0)
          then "inconclusive_undeclared_status_token"
        elif ($healthy != "true")
          then "inconclusive_recovered_target_unhealthy"
        elif (($post | tonumber? // 1) == 0)
          then "all_sagas_reached_terminal_state"
        else "sagas_stranded_after_recovery" end),
     verdict_guards: "An empty orders table is NOT a pass: the 2026-08-21 run reported all_sagas_reached_terminal_state for an arm whose 3.1 preflight had aborted before a single order was issued. A status token in neither declared list is NOT bucketed as terminal. A recovered target that never became healthy cannot evidence non-resumption.",
     interpretation: "nonterminal_orders_post_drain > 0 means in-flight sagas did NOT resume after the crash. orders_with_duplicate_payment_step > 0 means a step was RE-EXECUTED rather than resumed, which is a duplicate-execution (O1) signal, not recovery.",
     claim_limits: "CORRECTNESS ONLY. Never cite in a latency or throughput table. Not a full §7 oracle: no per-(orderId,stepId,direction) ledger, so LIFO ordering stays unverified.",
     generated_at_utc: $generated_at_utc
   }' > "$REPORT_JSON"

echo "Crash-recovery report: $REPORT_JSON"
jq -c '{crash_scope, total_orders_post_drain, nonterminal_orders_pre_crash, nonterminal_orders_post_drain, orders_with_duplicate_payment_step, recovered_target_healthy, verdict}' "$REPORT_JSON"
