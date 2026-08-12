#!/usr/bin/env bash
# compare-results.sh — Compare a current result JSON against a baseline JSON.
# Outputs a Markdown summary table and exits non-zero if any blocking regression
# is detected (per docs/regression-policy.md).
#
# Usage:
#   ./scripts/compare-results.sh <baseline.json> <current.json>
#
# Both files must conform to schemas/benchmark-result.schema.json.
set -euo pipefail

# Pin the numeric locale. python3 emits "0.0" with a dot; printf "%+.2f" parses it through
# LC_NUMERIC, so under a comma-decimal locale (pl_PL, de_DE, fr_FR, ...) every delta raised
# `printf: 0.0: invalid number` and the script exited non-zero on IDENTICAL inputs — i.e. it
# reported failure for a run with no regression at all, on the developer machine but not in a
# C-locale CI. Same class as the LC_ALL=C rule already required for analysis awk.
export LC_ALL=C

BASELINE="${1:?Usage: compare-results.sh <baseline.json> <current.json>}"
CURRENT="${2:?Usage: compare-results.sh <baseline.json> <current.json>}"

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

comparison_constrained_contract_id() {
  local contract_id="${1:-}"
  [[ -n "$contract_id" && ( "$contract_id" == fixed_contract_runtime_h1_constrained* || "$contract_id" == *_constrained_* ) ]]
}

comparison_constrained_execution_profile_id() {
  local execution_profile_id="${1:-}"
  [[ -n "$execution_profile_id" && "$execution_profile_id" == runtime-constrained-* ]]
}

comparison_constrained_track_id() {
  local track_id="${1:-}"
  [[ -n "$track_id" && "$track_id" == track-c* ]]
}

comparison_constrained_path() {
  local path_value="${1:-}"
  [[ -n "$path_value" && ( "$path_value" == */results/constrained/* || "$path_value" == results/constrained/* ) ]]
}

comparison_constrained_reason() {
  local file="$1"
  local execution_profile_id=""
  local track_id=""
  local run_contract_id=""
  local top_contract_id=""
  local top_track_id=""

  if comparison_constrained_path "$file"; then
    echo "result_path=${file}"
    return 0
  fi

  execution_profile_id="$(jq -r '.run_config.execution_profile_id // empty' "$file" 2>/dev/null || true)"
  if comparison_constrained_execution_profile_id "$execution_profile_id"; then
    echo "run_config.execution_profile_id=${execution_profile_id}"
    return 0
  fi

  track_id="$(jq -r '.run_config.track_id // empty' "$file" 2>/dev/null || true)"
  if comparison_constrained_track_id "$track_id"; then
    echo "run_config.track_id=${track_id}"
    return 0
  fi

  top_track_id="$(jq -r '.track_id // empty' "$file" 2>/dev/null || true)"
  if comparison_constrained_track_id "$top_track_id"; then
    echo "track_id=${top_track_id}"
    return 0
  fi

  run_contract_id="$(jq -r '.run_config.contract_id // empty' "$file" 2>/dev/null || true)"
  if comparison_constrained_contract_id "$run_contract_id"; then
    echo "run_config.contract_id=${run_contract_id}"
    return 0
  fi

  top_contract_id="$(jq -r '.contract_id // empty' "$file" 2>/dev/null || true)"
  if comparison_constrained_contract_id "$top_contract_id"; then
    echo "contract_id=${top_contract_id}"
    return 0
  fi

  return 1
}

# --- Comparison eligibility pre-check ---
# Reads claim_scope and execution_class from each result JSON.
# Fails fast unless claim_scope is exactly comparison_eligible.
check_eligible() {
  local file="$1"
  local label="$2"
  local scope exec_class final_reason
  local constrained_reason

  if constrained_reason="$(comparison_constrained_reason "$file")"; then
    echo "EXCLUDED: comparative sections disabled for $label" >&2
    echo "EXCLUSION_REASON: constrained_execution_profile_forbidden" >&2
    echo "OBSERVED: ${constrained_reason}" >&2
    echo "ACTION: constrained exploratory artifacts are not valid for baseline or comparative workflows; use descriptive-only review outside compare-results.sh." >&2
    exit 1
  fi

  scope="$(jq -er '.claim_scope' "$file" 2>/dev/null)" || {
    echo "ERROR: Contract drift in $label: missing required field .claim_scope for comparison eligibility" >&2
    echo "ACTION: populate canonical classification fields (claim_scope, execution_class, final_reason) before comparing." >&2
    exit 1
  }
  exec_class="$(jq -er '.execution_class' "$file" 2>/dev/null)" || {
    echo "ERROR: Contract drift in $label: missing required field .execution_class for comparison eligibility" >&2
    exit 1
  }
  final_reason="$(jq -er '.final_reason' "$file" 2>/dev/null)" || {
    echo "ERROR: Contract drift in $label: missing required field .final_reason for comparison eligibility" >&2
    exit 1
  }

  if [[ "$final_reason" != "ok" ]]; then
    echo "EXCLUDED: comparative sections disabled for $label" >&2
    echo "EXCLUSION_REASON: final_reason_not_ok" >&2
    echo "OBSERVED: claim_scope=${scope}, execution_class=${exec_class}, final_reason=${final_reason}" >&2
    echo "ACTION: Only final_reason=ok is eligible for comparison." >&2
    exit 1
  fi

  if [[ "$scope" != "comparison_eligible" ]]; then
    echo "EXCLUDED: comparative sections disabled for $label" >&2
    echo "EXCLUSION_REASON: claim_scope_not_comparison_eligible" >&2
    echo "OBSERVED: claim_scope=${scope}, execution_class=${exec_class}, final_reason=${final_reason}" >&2
    echo "ACTION: Only claim_scope=comparison_eligible is allowed for comparisons. Produce a complete guard/regression run with final_reason=ok, then rerun compare-results.sh." >&2
    exit 1
  fi
}

# --- Environment fences ------------------------------------------------------
# A FENCE is different in kind from a regression threshold. A threshold assumes two runs are
# comparable and asks whether the delta is too large. A fence asks whether they are comparable
# at all. Crossing one silently does not produce a noisy result — it produces a confident,
# well-formed, wrong one.
#
# Two are enforced, both measured in this lab rather than assumed:
#
#   backend_network_mode  host vs bridge = +20.5% throughput on this perf box, at UNCHANGED
#                         application cpu/req (0.357 -> 0.358 ms) and target-thread %wait
#                         falling 265% -> 57%. That is twice the -10% blocking threshold, so
#                         the comparator would report a large regression or improvement and
#                         be certain about it.
#
#   db_cpuset             Unpinned, Postgres shares every core with the measured target
#                         (verified 2026-08-06: postmaster Cpus_allowed_list=0-15 against a
#                         target pinned to 0-1,8-9). It contends with the arm under
#                         measurement AND makes DB CPU unattributable. Confining it can also
#                         lower the DB's own ceiling. Absolute levels do not cross.
#
# Both are read from run_config.metadata first — where run-comparative.sh actually writes them
# — falling back to run_config.*, which is where the schema declared backend_network_mode and
# where nothing ever wrote it.
#
# Policy: a DIFFERENCE is never overridable, because the comparison is simply invalid. A
# MISSING value is overridable via BENCH_ALLOW_UNVERIFIED_FENCES=1, because artifacts written
# before 2026-08-08 carry no db_cpuset at all and refusing them outright would strand every
# existing result. That override stamps the output; it does not hide.
fence_value() {
  local file="$1"
  local key="$2"
  jq -r --arg k "$key" '
    (.run_config.metadata[$k] // .run_config[$k] // empty) | tostring
  ' "$file" 2>/dev/null || true
}

check_environment_fences() {
  local missing=0
  local key base cur

  for key in backend_network_mode db_cpuset; do
    base="$(fence_value "$BASELINE" "$key")"
    cur="$(fence_value "$CURRENT" "$key")"

    # Absent entirely (legacy artifact). db_cpuset is absent from everything written before
    # 2026-08-08. An EMPTY db_cpuset is NOT absent — it is the recorded fact "unpinned".
    if [[ -z "$base" && "$(jq -r --arg k "$key" 'has("run_config") and ((.run_config.metadata|type=="object" and has($k)) or (.run_config|has($k)))' "$BASELINE" 2>/dev/null)" != "true" ]]; then
      echo "FENCE UNVERIFIABLE: baseline does not record ${key}" >&2
      missing=1
      continue
    fi
    if [[ -z "$cur" && "$(jq -r --arg k "$key" 'has("run_config") and ((.run_config.metadata|type=="object" and has($k)) or (.run_config|has($k)))' "$CURRENT" 2>/dev/null)" != "true" ]]; then
      echo "FENCE UNVERIFIABLE: current does not record ${key}" >&2
      missing=1
      continue
    fi

    if [[ "$base" != "$cur" ]]; then
      echo "EXCLUDED: comparative sections disabled — environment fence crossed" >&2
      echo "EXCLUSION_REASON: environment_fence_mismatch" >&2
      echo "OBSERVED: ${key}: baseline='${base}' current='${cur}'" >&2
      case "$key" in
        backend_network_mode)
          echo "ACTION: host vs bridge is worth +20.5% throughput on this box at unchanged cpu/req — twice the blocking threshold. These two runs are not comparable. Re-measure the baseline under the current network mode, or compare against a baseline recorded under the same one." >&2
          ;;
        db_cpuset)
          echo "ACTION: a differently-pinned (or unpinned) database changes both contention with the measured arm and the DB's own ceiling. Absolute levels do not cross this boundary. Re-measure the baseline under the current cpuset." >&2
          ;;
      esac
      exit 1
    fi
  done

  if [[ "$missing" -eq 1 ]]; then
    if [[ "${BENCH_ALLOW_UNVERIFIED_FENCES:-0}" != "1" ]]; then
      echo "EXCLUDED: comparative sections disabled — environment fences unverifiable" >&2
      echo "EXCLUSION_REASON: environment_fence_metadata_missing" >&2
      echo "ACTION: one or both artifacts predate fence recording (db_cpuset was added 2026-08-08). Re-run the measurement so the fence is recorded, or set BENCH_ALLOW_UNVERIFIED_FENCES=1 to compare anyway — the output is then stamped as fence-unverified and must not be used to accept or reject a regression." >&2
      exit 1
    fi
    FENCE_STATUS="UNVERIFIED"
  else
    FENCE_STATUS="verified"
  fi
}

metric_present() {
  local file="$1"
  local key="$2"
  jq -e --arg k "$key" '.metrics | type == "object" and has($k)' "$file" >/dev/null 2>&1
}

metric_value() {
  local file="$1"
  local key="$2"
  local label="$3"
  jq -er --arg k "$key" '.metrics[$k] | select(type == "number")' "$file" 2>/dev/null || {
    echo "ERROR: Contract drift in $label: .metrics.$key is missing or non-numeric" >&2
    exit 1
  }
}

compare_metric_pair_if_present() {
  local label="$1"
  local key="$2"
  local warn="$3"
  local block="$4"
  local direction="$5"

  local base_has=0
  local cur_has=0
  metric_present "$BASELINE" "$key" && base_has=1
  metric_present "$CURRENT" "$key" && cur_has=1

  if [[ "$base_has" -ne "$cur_has" ]]; then
    echo "ERROR: Contract drift: metric presence mismatch for '$key' (baseline=$base_has, current=$cur_has)" >&2
    echo "ACTION: ensure both artifacts expose the same canonical metrics before comparison." >&2
    exit 1
  fi

  if [[ "$base_has" -eq 1 ]]; then
    local base_val cur_val
    base_val="$(metric_value "$BASELINE" "$key" "baseline ($BASELINE)")"
    cur_val="$(metric_value "$CURRENT" "$key" "current ($CURRENT)")"
    compare_metric "$label" "$base_val" "$cur_val" "$warn" "$block" "$direction"
  fi
}

check_eligible "$BASELINE" "baseline ($BASELINE)"
check_eligible "$CURRENT"  "current ($CURRENT)"

# Runs AFTER eligibility: eligibility asks whether each artifact may be used at all, fences ask
# whether these two may be used against EACH OTHER. Both must pass before any delta is computed,
# because a fence-crossed delta is not a weak signal — it is a confident wrong one.
FENCE_STATUS="verified"
check_environment_fences

# --- Regression thresholds (aligns with docs/regression-policy.md) ---
# The warn line sits above this box's measured non-regression spread: AB/BA within a pair
# <= 1.6%, repeats of the same target across pairs <= 2.7%, and a neighbour/slot effect of
# 2.3-3.9% (2026-08-06 ladder, n=12 per arm). The worst known non-regression effect is
# therefore ~1.1 points under the -5% warn line. Do not lower these without re-measuring that
# spread — and note the 3.9% is systematic (it depends on which arm shares the leaf), not
# random, so averaging more repeats does not shrink it.
WARN_THROUGHPUT_PCT=-5
BLOCK_THROUGHPUT_PCT=-10
WARN_LATENCY_MEAN_PCT=5
BLOCK_LATENCY_MEAN_PCT=10
WARN_LATENCY_P99_PCT=10
BLOCK_LATENCY_P99_PCT=20
WARN_LATENCY_P999_PCT=15
BLOCK_LATENCY_P999_PCT=30

pct_change() {
  local base="$1"
  local cur="$2"
  # Returns (cur - base) / base * 100
  echo "$(python3 -c "b=float('$base'); c=float('$cur'); print(0 if b==0 else round((c-b)/b*100,2))")"
}

echo "## Exeris Benchmark Comparison"
echo ""
if [[ "$FENCE_STATUS" == "verified" ]]; then
  echo "Environment fences: **verified** — \`backend_network_mode\` = \`$(fence_value "$CURRENT" backend_network_mode)\`, \`db_cpuset\` = \`$(fence_value "$CURRENT" db_cpuset)\` (identical on both sides)."
else
  echo "> **FENCE-UNVERIFIED COMPARISON.** One or both artifacts do not record \`backend_network_mode\` / \`db_cpuset\`, and \`BENCH_ALLOW_UNVERIFIED_FENCES=1\` was set. The deltas below may reflect an environment difference rather than a code change — on this box host-vs-bridge alone is +20.5% throughput, twice the blocking threshold. **Do not accept or reject a regression on this output.**"
fi
echo ""
echo "| Metric | Baseline | Current | Delta | Status |"
echo "|---|---|---|---|---|"

REGRESSION=0

compare_metric() {
  local label="$1"
  local base_val="$2"
  local cur_val="$3"
  local warn_threshold="$4"   # positive = "higher is worse"
  local block_threshold="$5"
  local direction="$6"        # "lower_is_better" or "higher_is_better"

  local delta
  delta="$(pct_change "$base_val" "$cur_val")"

  local status="✓"
  local effective_delta="$delta"

  if [[ "$direction" == "higher_is_better" ]]; then
    # throughput: negative delta is bad
    effective_delta="$(python3 -c "print(-1 * float('$delta'))")"
    if python3 -c "import sys; sys.exit(0 if float('$effective_delta') >= float('$block_threshold'.replace('-','')) else 1)" 2>/dev/null; then
      status="✗ BLOCKING REGRESSION"
      REGRESSION=1
    elif python3 -c "import sys; sys.exit(0 if float('$effective_delta') >= float('$warn_threshold'.replace('-','')) else 1)" 2>/dev/null; then
      status="⚠ WARNING"
    fi
  else
    # latency: positive delta is bad
    if python3 -c "import sys; sys.exit(0 if float('$delta') >= float('$block_threshold') else 1)" 2>/dev/null; then
      status="✗ BLOCKING REGRESSION"
      REGRESSION=1
    elif python3 -c "import sys; sys.exit(0 if float('$delta') >= float('$warn_threshold') else 1)" 2>/dev/null; then
      status="⚠ WARNING"
    fi
  fi

  printf "| %-35s | %12s | %12s | %+.2f%% | %s |\n" \
    "$label" "$base_val" "$cur_val" "$delta" "$status"
}

compare_metric_pair_if_present "Throughput (req/s)" "throughput_rps" "$WARN_THROUGHPUT_PCT" "$BLOCK_THROUGHPUT_PCT" higher_is_better
compare_metric_pair_if_present "Latency mean (µs)" "latency_mean_us" "$WARN_LATENCY_MEAN_PCT" "$BLOCK_LATENCY_MEAN_PCT" lower_is_better
compare_metric_pair_if_present "Latency p99 (µs)" "latency_p99_us" "$WARN_LATENCY_P99_PCT" "$BLOCK_LATENCY_P99_PCT" lower_is_better
compare_metric_pair_if_present "Latency p999 (µs)" "latency_p999_us" "$WARN_LATENCY_P999_PCT" "$BLOCK_LATENCY_P999_PCT" lower_is_better

BASE_ALLOC_PRESENT=0
CUR_ALLOC_PRESENT=0
metric_present "$BASELINE" "jmh_alloc_rate_norm_bytes" && BASE_ALLOC_PRESENT=1
metric_present "$CURRENT" "jmh_alloc_rate_norm_bytes" && CUR_ALLOC_PRESENT=1
if [[ "$BASE_ALLOC_PRESENT" -ne "$CUR_ALLOC_PRESENT" ]]; then
  echo "ERROR: Contract drift: metric presence mismatch for 'jmh_alloc_rate_norm_bytes' (baseline=$BASE_ALLOC_PRESENT, current=$CUR_ALLOC_PRESENT)" >&2
  exit 1
fi

if [[ "$BASE_ALLOC_PRESENT" -eq 1 ]]; then
  BASE_ALLOC="$(metric_value "$BASELINE" "jmh_alloc_rate_norm_bytes" "baseline ($BASELINE)")"
  CUR_ALLOC="$(metric_value "$CURRENT" "jmh_alloc_rate_norm_bytes" "current ($CURRENT)")"
  [[ "$BASE_ALLOC" == "0" && "$CUR_ALLOC" != "0" ]] && {
  echo "| zero-alloc path | 0 B/op | ${CUR_ALLOC} B/op | N/A | ✗ BLOCKING REGRESSION (zero-alloc violation) |"
  REGRESSION=1
}
fi

echo ""
if [[ "$REGRESSION" -eq 1 ]]; then
  echo "**RESULT: REGRESSION DETECTED** — see docs/regression-policy.md"
  exit 1
else
  echo "**RESULT: OK** — no blocking regressions detected"
fi
