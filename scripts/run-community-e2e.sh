#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/tools/bench/lib/k6.sh"
START_SCRIPT="$ROOT/runtime/drivers/start-target.sh"
STOP_SCRIPT="$ROOT/runtime/drivers/stop-target.sh"
COMMUNITY_ENV="$ROOT/runtime/drivers/env/exeris-e2e-runtime.env"
TARGET_REGISTRY_SCRIPT="$ROOT/runtime/drivers/target-contract-registry.sh"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-90}"
PROGRESS_HEARTBEAT_SECONDS="${PROGRESS_HEARTBEAT_SECONDS:-10}"

PROTOCOL="h2"
TOOLS_CSV="k6,h2load,wrk"
SCENARIO_REL="scenarios/health-probe"
TARGET_ALIAS="exeris-community-app"
DURATION="30s"
VUS="50"
CLIENTS="100"
STREAMS="10"
REQUESTS="100000"
BASELINE_RATE="200"
OVERLOAD_RATE="2000"
VUS_EXPLICIT="false"
CLIENTS_EXPLICIT="false"
STREAMS_EXPLICIT="false"
REQUESTS_EXPLICIT="false"
BASELINE_RATE_EXPLICIT="false"
OVERLOAD_RATE_EXPLICIT="false"

usage() {
  cat <<'USAGE'
Usage: bash scripts/run-community-e2e.sh [options]

Options:
  --protocol <h1|h2>              Protocol to benchmark (default: h2)
  --tools <k6,h2load,wrk>         Comma-separated tools list (default: k6,h2load,wrk)
  --scenario <repo-relative-path> Scenario directory (default: scenarios/health-probe)
  --target <target-alias>         Runtime target alias (default: exeris-community-app)
  --duration <duration>           Load duration (default: 30s)
  --vus <number>                  k6 virtual users (default: 50)
  --clients <number>              h2load clients (default: 100)
  --streams <number>              h2load max streams (default: 10)
  --requests <number>             h2load total requests (default: 100000)
  --baseline-rate <rps>           Arrival rate at baseline phase (default: 200 RPS; k6 scenarios only)
  --overload-rate <rps>           Arrival rate at overload peak (default: 2000 RPS; k6 scenarios only)
  --help                          Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --protocol)
      PROTOCOL="${2:-}"
      shift 2
      ;;
    --tools)
      TOOLS_CSV="${2:-}"
      shift 2
      ;;
    --scenario)
      SCENARIO_REL="${2:-}"
      shift 2
      ;;
    --target)
      TARGET_ALIAS="${2:-}"
      shift 2
      ;;
    --duration)
      DURATION="${2:-}"
      shift 2
      ;;
    --vus)
      VUS="${2:-}"
      VUS_EXPLICIT="true"
      shift 2
      ;;
    --clients)
      CLIENTS="${2:-}"
      CLIENTS_EXPLICIT="true"
      shift 2
      ;;
    --streams)
      STREAMS="${2:-}"
      STREAMS_EXPLICIT="true"
      shift 2
      ;;
    --requests)
      REQUESTS="${2:-}"
      REQUESTS_EXPLICIT="true"
      shift 2
      ;;
    --baseline-rate)
      BASELINE_RATE="${2:-}"
      BASELINE_RATE_EXPLICIT="true"
      shift 2
      ;;
    --overload-rate)
      OVERLOAD_RATE="${2:-}"
      OVERLOAD_RATE_EXPLICIT="true"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

case "$PROTOCOL" in
  h1|h2) ;;
  *)
    echo "ERROR: --protocol must be one of: h1, h2" >&2
    exit 2
    ;;
esac

if [[ ! -x "$START_SCRIPT" || ! -x "$STOP_SCRIPT" ]]; then
  echo "ERROR: target driver scripts not found or not executable" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

SCENARIO_DIR="$ROOT/$SCENARIO_REL"
if [[ ! -d "$SCENARIO_DIR" ]]; then
  echo "ERROR: scenario directory not found: $SCENARIO_DIR" >&2
  exit 1
fi

IFS=',' read -r -a RAW_TOOLS <<<"$TOOLS_CSV"
TOOLS=()
for t in "${RAW_TOOLS[@]}"; do
  trimmed="$(echo "$t" | tr -d '[:space:]')"
  [[ -z "$trimmed" ]] && continue
  case "$trimmed" in
    k6|h2load|wrk)
      TOOLS+=("$trimmed")
      ;;
    *)
      echo "ERROR: Unsupported tool '$trimmed'. Allowed: k6,h2load,wrk" >&2
      exit 2
      ;;
  esac
done

if [[ ${#TOOLS[@]} -eq 0 ]]; then
  echo "ERROR: --tools resolved to an empty tool list" >&2
  exit 2
fi

for tool in "${TOOLS[@]}"; do
  if [[ "$tool" == "wrk" && "$PROTOCOL" != "h1" ]]; then
    echo "ERROR: wrk is only allowed for --protocol h1" >&2
    exit 2
  fi
done

if [[ -f "$COMMUNITY_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$COMMUNITY_ENV"
fi

DEFAULT_HEALTH_URL="${HEALTH_URL:-http://localhost:8080/health}"
HEALTH_URL="$DEFAULT_HEALTH_URL"
if [[ -f "$TARGET_REGISTRY_SCRIPT" ]]; then
  # shellcheck disable=SC1090
  source "$TARGET_REGISTRY_SCRIPT"
  if resolve_target_contract "$TARGET_ALIAS" >/dev/null 2>&1 && [[ -n "${TARGET_CONTRACT_HEALTH_URL:-}" ]]; then
    HEALTH_URL="$TARGET_CONTRACT_HEALTH_URL"
  else
    echo "WARN: Could not resolve target contract for '$TARGET_ALIAS'; falling back to HEALTH_URL='$DEFAULT_HEALTH_URL'" >&2
  fi
else
  echo "WARN: target-contract-registry.sh not found; using HEALTH_URL='$DEFAULT_HEALTH_URL'" >&2
fi

BASE_URL="$(printf '%s' "$HEALTH_URL" | sed -E 's#^(https?://[^/]+).*$#\1#')"
if [[ -z "$BASE_URL" ]]; then
  echo "ERROR: Could not derive BASE_URL from HEALTH_URL='$HEALTH_URL'" >&2
  exit 1
fi

echo "[config] target_alias=$TARGET_ALIAS health_url=$HEALTH_URL base_url=$BASE_URL"

case "$PROTOCOL" in
  h1)
    export EXERIS_HTTP_MAX_VERSION="HTTP_1_1"
    export EXERIS_HTTP_H2C_UPGRADE_ENABLED="false"
    ;;
  h2)
    export EXERIS_HTTP_MAX_VERSION="HTTP_2"
    export EXERIS_HTTP_H2C_UPGRADE_ENABLED="true"
    ;;
esac

SCENARIO_JSON="$SCENARIO_DIR/scenario.json"
SCENARIO_ID="$(basename "$SCENARIO_DIR")"
CLAIM_SCOPE="exploratory"
MODE="pure"
MATURITY="guard"
if [[ -f "$SCENARIO_JSON" ]]; then
  if ! jq empty "$SCENARIO_JSON" >/dev/null 2>&1; then
    echo "ERROR: scenario.json is not valid JSON: $SCENARIO_JSON" >&2
    exit 1
  fi
  SCENARIO_ID="$(jq -r --arg d "$SCENARIO_ID" '(.scenario_id // $d) | if type=="string" and length>0 then . else $d end' "$SCENARIO_JSON")"
  CLAIM_SCOPE="$(jq -r --arg d "$CLAIM_SCOPE" '(.claim_scope // $d) | if type=="string" and length>0 then . else $d end' "$SCENARIO_JSON")"
  MODE="$(jq -r --arg d "$MODE" '(.mode // $d) | if type=="string" and length>0 then . else $d end' "$SCENARIO_JSON")"
  MATURITY="$(jq -r --arg d "$MATURITY" '(.maturity // $d) | if type=="string" and length>0 then . else $d end' "$SCENARIO_JSON")"
  [[ "$VUS_EXPLICIT"      == "false" ]] && VUS="$(jq -r --arg d "$VUS" '(.k6.vus // $d) | tostring' "$SCENARIO_JSON")"
  [[ "$CLIENTS_EXPLICIT"  == "false" ]] && CLIENTS="$(jq -r --arg d "$CLIENTS" '(.h2load.connections // .h2load.clients // $d) | tostring' "$SCENARIO_JSON")"
  [[ "$STREAMS_EXPLICIT"  == "false" ]] && STREAMS="$(jq -r --arg d "$STREAMS" '(.h2load.streams // $d) | tostring' "$SCENARIO_JSON")"
  [[ "$REQUESTS_EXPLICIT" == "false" ]] && REQUESTS="$(jq -r --arg d "$REQUESTS" '(.h2load.requests // $d) | tostring' "$SCENARIO_JSON")"
  [[ "$BASELINE_RATE_EXPLICIT" == "false" ]] && BASELINE_RATE="$(jq -r --arg d "$BASELINE_RATE" '(.k6.baseline_rate // $d) | tostring' "$SCENARIO_JSON")"
  [[ "$OVERLOAD_RATE_EXPLICIT" == "false" ]] && OVERLOAD_RATE="$(jq -r --arg d "$OVERLOAD_RATE" '(.k6.overload_rate // $d) | tostring' "$SCENARIO_JSON")"
fi

RESULTS_RAW_DIR="$ROOT/results/raw"
mkdir -p "$RESULTS_RAW_DIR"

SCENARIO_NAME="$(basename "$SCENARIO_DIR")"
TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
PREFIX="community-${PROTOCOL}-${SCENARIO_NAME}-${TIMESTAMP}"
RUN_DIR="$RESULTS_RAW_DIR/$PREFIX"
LOGS_DIR="$RUN_DIR/logs"
TOOLS_DIR="$RUN_DIR/tools"
mkdir -p "$LOGS_DIR" "$TOOLS_DIR/k6" "$TOOLS_DIR/h2load" "$TOOLS_DIR/wrk"
STARTED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

export REPO_ROOT="$ROOT"
export BASE_URL
export BASELINE_RATE
export OVERLOAD_RATE
export EXERIS_BASELINE_RATE="$BASELINE_RATE"
export EXERIS_OVERLOAD_RATE="$OVERLOAD_RATE"
K6_SCENARIO="$SCENARIO_DIR/k6.js"
H2LOAD_ENV="$SCENARIO_DIR/h2load.env"
WRK_ENV="$SCENARIO_DIR/wrk.env"

stop_target() {
  bash "$STOP_SCRIPT" "$TARGET_ALIAS" >/dev/null 2>&1 || true
}
trap stop_target EXIT

START_LOG="$LOGS_DIR/start-target.log"
echo "[startup] Starting target: $TARGET_ALIAS"
if ! bash "$START_SCRIPT" "$TARGET_ALIAS" 2>&1 | tee "$START_LOG"; then
  echo "ERROR: start-target.sh failed for '$TARGET_ALIAS'. See $START_LOG" >&2
  exit 1
fi

echo "[startup] Polling health: $HEALTH_URL (timeout: ${HEALTH_TIMEOUT_SECONDS}s)"
TARGET_READY="false"
for _poll_i in $(seq 1 "$HEALTH_TIMEOUT_SECONDS"); do
  if command -v curl >/dev/null 2>&1; then
    if curl -sf --max-time 2 -o /dev/null "$HEALTH_URL" 2>/dev/null; then
      TARGET_READY="true"
      break
    fi
  else
    # Fallback: TCP probe via bash /dev/tcp (h1 only)
    _hp="${HEALTH_URL#*://}"
    _host="${_hp%%/*}"
    _port="${_host##*:}"
    _host="${_host%%:*}"
    if (echo -n > "/dev/tcp/$_host/$_port") 2>/dev/null; then
      TARGET_READY="true"
      break
    fi
  fi
  sleep 1
done

if [[ "$TARGET_READY" != "true" ]]; then
  echo "ERROR: target '$TARGET_ALIAS' did not become healthy at $HEALTH_URL within ${HEALTH_TIMEOUT_SECONDS}s" >&2
  exit 1
fi
echo "[startup] Target ready."

PREFLIGHT_LOG="$LOGS_DIR/preflight.txt"
PREFLIGHT_STATUS="ok"
if command -v curl >/dev/null 2>&1; then
  if ! curl -sf --max-time 5 -o "$PREFLIGHT_LOG" "$HEALTH_URL" 2>/dev/null; then
    PREFLIGHT_STATUS="non_2xx_or_unreachable"
  fi
else
  echo "curl unavailable — skipping preflight response capture" > "$PREFLIGHT_LOG"
  PREFLIGHT_STATUS="tool_unavailable"
fi
echo "[preflight] status=$PREFLIGHT_STATUS url=$HEALTH_URL"

ARTIFACTS=()
ARTIFACTS+=("$START_LOG" "$PREFLIGHT_LOG")

run_with_heartbeat() {
  local label="$1"
  local log_path="$2"
  shift 2

  local start_ts now_ts elapsed rc
  start_ts="$(date +%s)"
  echo "[measurement] [$label] started (log: $log_path)"

  "$@" >"$log_path" 2>&1 &
  local cmd_pid=$!

  while kill -0 "$cmd_pid" 2>/dev/null; do
    now_ts="$(date +%s)"
    elapsed=$((now_ts - start_ts))
    echo "[measurement] [$label] running... ${elapsed}s elapsed"
    sleep "$PROGRESS_HEARTBEAT_SECONDS"
  done

  wait "$cmd_pid"
  rc=$?
  now_ts="$(date +%s)"
  elapsed=$((now_ts - start_ts))

  if [[ $rc -ne 0 ]]; then
    echo "[measurement] [$label] FAILED after ${elapsed}s (rc=$rc). Last log lines:" >&2
    tail -n 40 "$log_path" >&2 || true
    return "$rc"
  fi

  echo "[measurement] [$label] completed in ${elapsed}s"
}

print_k6_summary() {
  local summary_json="$1"
  [[ ! -f "$summary_json" ]] && { echo "[results] [k6] summary.json not found: $summary_json"; return; }
  echo ""
  echo "══════════════════════════════════════════════════════════"
  echo " k6 RESULTS"
  echo "══════════════════════════════════════════════════════════"
  jq -r '
    def pct(v): "\(v * 100 | . * 10 | round / 10)%";
    def icon(bad): if bad then "✗ FAIL" else "✓ pass" end;
    def any_violated(m): [(m.thresholds // {}) | to_entries[].value] | map(select(.)) | length > 0;
    (.metrics.errors.value          // 0) as $e_val |
    (.metrics.shed_rate.value       // 0) as $s_val |
    (.metrics.crash_failures.value  // 0) as $c_val |
    (.metrics.http_req_failed.value // 0) as $f_val |
    any_violated(.metrics.errors)           as $e_bad |
    any_violated(.metrics.shed_rate)        as $s_bad |
    any_violated(.metrics.crash_failures)   as $c_bad |
    any_violated(.metrics.http_req_failed)  as $f_bad |
    (.metrics.http_req_duration.avg         // 0) as $d_avg |
    (.metrics.http_req_duration["p(90)"]    // 0) as $d_p90 |
    (.metrics.http_req_duration["p(95)"]    // 0) as $d_p95 |
    (.metrics.http_reqs.rate                // 0) as $rps |
    (.metrics.iterations.count              // 0) as $total |
    " THRESHOLDS",
    "  \(icon($e_bad))  errors................. \(pct($e_val))",
    "  \(icon($s_bad))  shed_rate.............. \(pct($s_val))",
    "  \(icon($c_bad))  crash_failures......... \(pct($c_val))",
    "  \(icon($f_bad))  http_req_failed........ \(pct($f_val))",
    "",
    " LATENCY (ms)",
    "  avg \($d_avg | . * 100 | round / 100)   p90 \($d_p90 | . * 100 | round / 100)   p95 \($d_p95 | . * 100 | round / 100)",
    "",
    " THROUGHPUT",
    "  total_reqs: \($total)   avg_rps: \($rps | . * 10 | round / 10)"
  ' "$summary_json" 2>/dev/null || echo "[results] [k6] failed to parse summary.json"
  echo "══════════════════════════════════════════════════════════"
}

run_k6() {
  if [[ ! -f "$K6_SCENARIO" ]]; then
    echo "ERROR: k6 scenario not found: $K6_SCENARIO" >&2
    exit 1
  fi

  local out_stream="$TOOLS_DIR/k6/stream.json"
  local out_summary="$TOOLS_DIR/k6/summary.json"
  local out_log="$TOOLS_DIR/k6/k6.log"

  if [[ "$SCENARIO_ID" == "backpressure" ]]; then
    echo "[measurement] [k6] backpressure profile usually takes ~180s (30+30+60+30+30)"
  fi

  local k6_rc=0
  run_with_heartbeat "k6" "$out_log" bench_run_k6 "$K6_SCENARIO" "$out_stream" "$out_summary" || k6_rc=$?

  ARTIFACTS+=("$out_stream" "$out_summary" "$out_log")
  print_k6_summary "$out_summary"

  if [[ $k6_rc -ne 0 ]]; then
    echo "[measurement] [k6] WARNING: thresholds violated (k6 rc=$k6_rc) — results captured" >&2
  fi
}

run_h2load() {
  if ! command -v h2load >/dev/null 2>&1; then
    echo "ERROR: h2load is not installed or not in PATH" >&2
    exit 1
  fi

  local h2load_path="/health"
  if [[ -f "$H2LOAD_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$H2LOAD_ENV"
    h2load_path="${H2LOAD_PATH:-/health}"
  fi

  local target_url="${BASE_URL}${h2load_path}"
  local out_log="$TOOLS_DIR/h2load/h2load.log"
  local extra_args=()

  if [[ "$PROTOCOL" == "h1" ]]; then
    extra_args+=("--h1")
  fi

  run_with_heartbeat "h2load" "$out_log" \
    h2load \
      -n "$REQUESTS" \
      -c "$CLIENTS" \
      -m "$STREAMS" \
      "${extra_args[@]}" \
      "$target_url"

  ARTIFACTS+=("$out_log")
}

run_wrk() {
  if ! command -v wrk >/dev/null 2>&1; then
    echo "ERROR: wrk is not installed or not in PATH" >&2
    exit 1
  fi

  local wrk_path="/health"
  local wrk_threads="4"
  local wrk_connections="100"

  if [[ -f "$WRK_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$WRK_ENV"
    wrk_path="${WRK_PATH:-$wrk_path}"
    wrk_threads="${THREADS:-${WRK_THREADS:-$wrk_threads}}"
    wrk_connections="${CONNECTIONS:-${WRK_CONNECTIONS:-$wrk_connections}}"
  fi

  local target_url="${BASE_URL}${wrk_path}"
  local out_log="$TOOLS_DIR/wrk/wrk.log"

  run_with_heartbeat "wrk" "$out_log" \
    wrk \
      -t "$wrk_threads" \
      -c "$wrk_connections" \
      -d "$DURATION" \
      --latency \
      "$target_url"

  ARTIFACTS+=("$out_log")
}

# Capture reproducibility metadata before measurement
REPO_COMMIT_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo 'unknown')"
KERNEL_VERSION="$(uname -r)"
ARCHITECTURE="$(uname -m)"
K6_VERSION="$(k6 version 2>&1 | head -n1 || true)"
H2LOAD_VERSION="$(h2load --version 2>&1 | head -n1 || true)"
WRK_VERSION="$(wrk --version 2>&1 | head -n1 || true)"
JAVA_VERSION="$(java -version 2>&1 | head -n1 || true)"
REPRO_PATH="$LOGS_DIR/reproducibility-metadata.json"
jq -n \
  --arg commit_sha "$REPO_COMMIT_SHA" \
  --arg kernel_version "$KERNEL_VERSION" \
  --arg architecture "$ARCHITECTURE" \
  --arg k6_version "$K6_VERSION" \
  --arg h2load_version "$H2LOAD_VERSION" \
  --arg wrk_version "$WRK_VERSION" \
  --arg java_version "$JAVA_VERSION" \
  --arg captured_at_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    schema_version: 1,
    benchmark_commit_sha: $commit_sha,
    kernel_version: $kernel_version,
    architecture: $architecture,
    tool_versions: {
      k6: $k6_version,
      h2load: $h2load_version,
      wrk: $wrk_version,
      java: $java_version
    },
    captured_at_utc: $captured_at_utc
  }' > "$REPRO_PATH"
ARTIFACTS+=("$REPRO_PATH")

echo "[measurement] Stage start"
echo "[measurement] target=$TARGET_ALIAS scenario=$SCENARIO_ID protocol=$PROTOCOL tools=$TOOLS_CSV"
echo "[measurement] live logs: tail -f $TOOLS_DIR/k6/k6.log"

for tool in "${TOOLS[@]}"; do
  case "$tool" in
    k6)
      run_k6
      ;;
    h2load)
      run_h2load
      ;;
    wrk)
      run_wrk
      ;;
  esac
done

FINISHED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MANIFEST_PATH="$RUN_DIR/manifest.json"
TOOLS_JSON="$(printf '%s\n' "${TOOLS[@]}" | jq -R . | jq -s .)"

jq -n \
  --argjson schema_version 2 \
  --arg tier "community" \
  --arg protocol "$PROTOCOL" \
  --arg mode "$MODE" \
  --arg maturity "$MATURITY" \
  --arg scenario_rel "$SCENARIO_REL" \
  --arg scenario_id "$SCENARIO_ID" \
  --arg claim_scope "$CLAIM_SCOPE" \
  --arg target_alias "$TARGET_ALIAS" \
  --arg health_url "$HEALTH_URL" \
  --arg base_url "$BASE_URL" \
  --arg started_at_utc "$STARTED_AT_UTC" \
  --arg finished_at_utc "$FINISHED_AT_UTC" \
  --arg commit_sha "$REPO_COMMIT_SHA" \
  --arg kernel_version "$KERNEL_VERSION" \
  --arg architecture "$ARCHITECTURE" \
  --arg run_dir "$RUN_DIR" \
  --argjson tools "$TOOLS_JSON" \
  '{
    schema_version: $schema_version,
    tier: $tier,
    protocol: $protocol,
    mode: $mode,
    maturity: $maturity,
    scenario: $scenario_rel,
    scenario_id: $scenario_id,
    claim_scope: $claim_scope,
    tools: $tools,
    health_url: $health_url,
    base_url: $base_url,
    target_alias: $target_alias,
    started_at_utc: $started_at_utc,
    finished_at_utc: $finished_at_utc,
    commit_sha: $commit_sha,
    kernel_version: $kernel_version,
    architecture: $architecture,
    run_dir: $run_dir
  }' > "$MANIFEST_PATH"

ARTIFACTS+=("$MANIFEST_PATH")

echo ""
echo "Run completed. Artifacts:"
for artifact in "${ARTIFACTS[@]}"; do
  echo "- $artifact"
done

echo ""
echo "Run directory: $RUN_DIR"
echo "Manifest:      $MANIFEST_PATH"
echo "Next:          jq . \"$MANIFEST_PATH\""
