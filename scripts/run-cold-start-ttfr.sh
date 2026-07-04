#!/usr/bin/env bash
# scripts/run-cold-start-ttfr.sh — Measure application cold-start time and
# time-to-first-request (TTFR) for a benchmark target, harness-owned spawn.
#
# WHAT IT MEASURES (per iteration, fresh JVM each time):
#   startup_ms = t0 (process spawn) .......... first HTTP 200 from health endpoint
#   ttfr_ms    = ready (health 200) .......... first HTTP 2xx from business endpoint
#   spawn_to_first_request_ms = t0 ........... first business 2xx (startup + ttfr)
#
# t0 is captured by THIS runner immediately before it invokes the target's
# launch contract (EXTERNAL_START_CMD / jar spawn), so t0 includes shell fork +
# JVM exec identically across all targets. This is the fairest cross-runtime
# black-box cold-start definition. 'ready' semantics still differ per framework
# (Spring 'Started' vs Quarkus 'started' vs Exeris banner vs native-image) — the
# result artifact carries that caveat.
#
# PRECONDITION: the target's database and any backend deps (Postgres/Neo4j) must
# already be running. This script measures APPLICATION cold start only; it does
# not start or time the DB. The target jar must already be built.
#
# Usage:
#   ./scripts/run-cold-start-ttfr.sh \
#     --target <id|legacy> \
#     [--iterations 10] \
#     [--first-request-path /api/v1/users/1] \
#     [--ready-timeout-seconds 90] \
#     [--profile dev-laptop] \
#     [--output-dir results/cold-start-ttfr/<auto>]
#
# Exit: 0 if at least one iteration became ready and the result validated; 1 otherwise.
set -euo pipefail

# Force C locale so awk's "%.3f" always emits a '.' decimal separator. Under a
# comma-decimal locale (e.g. pl_PL) awk prints "476,731", which is invalid JSON
# and would break the jq --argjson assembly below. Benchmark scripts must format
# numbers deterministically regardless of the operator's locale.
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
TARGET_INPUT=""
ITERATIONS=10
HEALTH_URL_OVERRIDE=""
FIRST_REQUEST_PATH=""
READY_TIMEOUT_SECONDS=90
PROFILE="dev-laptop"
OUTPUT_DIR=""
HEALTH_POLL_MS=50
WARMUP_REQUESTS=50   # requests issued per launch to trace the TTFR decay curve

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)                 TARGET_INPUT="$2";            shift 2 ;;
    --iterations)             ITERATIONS="$2";              shift 2 ;;
    --health-url)             HEALTH_URL_OVERRIDE="$2";     shift 2 ;;
    --first-request-path)     FIRST_REQUEST_PATH="$2";      shift 2 ;;
    --warmup-requests)        WARMUP_REQUESTS="$2";         shift 2 ;;
    --ready-timeout-seconds)  READY_TIMEOUT_SECONDS="$2";   shift 2 ;;
    --profile)                PROFILE="$2";                 shift 2 ;;
    --output-dir)             OUTPUT_DIR="$2";              shift 2 ;;
    --health-poll-ms)         HEALTH_POLL_MS="$2";          shift 2 ;;
    -h|--help)                grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 64 ;;
  esac
done

[[ -z "$TARGET_INPUT" ]] && { echo "ERROR: --target is required" >&2; exit 64; }
if ! [[ "$ITERATIONS" =~ ^[0-9]+$ && "$ITERATIONS" -ge 1 ]]; then
  echo "ERROR: --iterations must be a positive integer (got: $ITERATIONS)" >&2; exit 64
fi
command -v jq   >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 67; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required" >&2; exit 67; }

# ---------------------------------------------------------------------------
# Resolve target contract (reuse the canonical registry)
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
source "${ROOT}/runtime/drivers/target-contract-registry.sh"
resolve_target_contract "$TARGET_INPUT" || { rc=$?; exit "$rc"; }
assert_target_contract_complete         || { rc=$?; exit "$rc"; }

TARGET_ID="$TARGET_CONTRACT_TARGET_ID"
TARGET_TIER="$TARGET_CONTRACT_TIER"
LAUNCHER_MODE="$TARGET_CONTRACT_LAUNCHER_MODE"
TARGET_ENV="$TARGET_CONTRACT_ENV_FILE"
HEALTH_URL="$TARGET_CONTRACT_HEALTH_URL"

case "$LAUNCHER_MODE" in
  external|jar) : ;;
  docker)
    echo "ERROR: launcher_mode=docker is unsupported for cold-start timing." >&2
    echo "       Compose scheduling time would contaminate t0; use a jar/external target." >&2
    exit 65 ;;
  *) echo "ERROR: unsupported launcher_mode '$LAUNCHER_MODE'" >&2; exit 65 ;;
esac

# Source the target env (exports EXTERNAL_START_CMD / EXTERNAL_STOP_CMD / DB vars).
if [[ -n "$TARGET_ENV" && -f "$TARGET_ENV" ]]; then
  set -a; # shellcheck source=/dev/null
  source "$TARGET_ENV"; set +a
fi

# Re-assert authoritative values from the resolved contract AFTER sourcing the env.
# Env files export their own TARGET_PROTOCOL (e.g. =h2c, the saga override label) and
# sometimes HEALTH_URL; `set -a; source` would clobber our locals. The contract is the
# source of truth for the fair baseline (protocol_mode=h1), so we restore it here.
TARGET_ID="$TARGET_CONTRACT_TARGET_ID"
TARGET_TIER="$TARGET_CONTRACT_TIER"
CONTRACT_PROTOCOL="$TARGET_CONTRACT_PROTOCOL_MODE"
HEALTH_URL="$TARGET_CONTRACT_HEALTH_URL"
# Optional override, e.g. to probe a target's cleartext port instead of its
# contract-default TLS health_url (quarkus-hibernate: --health-url http://localhost:19002/health).
if [[ -n "$HEALTH_URL_OVERRIDE" ]]; then
  echo "  NOTE: overriding contract health_url '${HEALTH_URL}' with '${HEALTH_URL_OVERRIDE}'"
  HEALTH_URL="$HEALTH_URL_OVERRIDE"
fi
export HEALTH_URL

# Mirror start-target.sh: Java 26 module access for Neo4j/Eclipse-Collections SPI.
export EXERIS_JAVA_OPTS="${EXERIS_JAVA_OPTS:-} --add-opens java.base/jdk.internal.module=ALL-UNNAMED"

# Auto-provision smoke TLS cert/key for HTTPS targets (mirrors start-target.sh).
if [[ "${HEALTH_URL}" == https://* && -z "${EXERIS_TRANSPORT_CERT_PATH:-}" ]]; then
  _smoke_cert="/tmp/exeris-bench-certs/smoke-cert.pem"
  _smoke_key="/tmp/exeris-bench-certs/smoke-key.pem"
  if [[ -f "${ROOT}/tools/bench/lib/certs.sh" ]] && command -v openssl >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${ROOT}/tools/bench/lib/certs.sh"
    if ensure_smoke_cert_key "$_smoke_cert" "$_smoke_key"; then
      export EXERIS_TRANSPORT_CERT_PATH="$_smoke_cert"
      export EXERIS_TRANSPORT_KEY_PATH="$_smoke_key"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Derive endpoints
# ---------------------------------------------------------------------------
_scheme="${HEALTH_URL%%://*}"
_rest="${HEALTH_URL#*://}"
_hostport="${_rest%%/*}"
BASE_URL="${_scheme}://${_hostport}"
HOST="${_hostport%%:*}"
PORT="${_hostport##*:}"
[[ "$PORT" == "$HOST" ]] && PORT=""   # no explicit port

if [[ -z "$FIRST_REQUEST_PATH" ]]; then
  # Default from the cold-start-ttfr scenario endpoint (read-by-id via query param).
  FIRST_REQUEST_PATH="/api/v1/users?id=1"
fi
[[ "$FIRST_REQUEST_PATH" != /* ]] && FIRST_REQUEST_PATH="/${FIRST_REQUEST_PATH}"
FIRST_REQUEST_URL="${BASE_URL}${FIRST_REQUEST_PATH}"

# ---------------------------------------------------------------------------
# Output dir / run metadata
# ---------------------------------------------------------------------------
RUN_TS_COMPACT="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_TS_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
COMMIT_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")"
COMMIT_SHA7="$(git -C "$ROOT" rev-parse --short=7 HEAD 2>/dev/null || echo "unknown")"

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="${ROOT}/results/cold-start-ttfr/${TARGET_ID}/${RUN_TS_COMPACT}"
fi
mkdir -p "$OUTPUT_DIR"

RESULT_FILE="${OUTPUT_DIR}/result.json"
TIMELINE_FILE="${OUTPUT_DIR}/cold-start-timeline.json"
ENV_FILE="${OUTPUT_DIR}/env.json"
SAMPLES_NDJSON="${OUTPUT_DIR}/.samples.ndjson"
: > "$SAMPLES_NDJSON"

RUN_ID="cold-start-ttfr-${RUN_TS_COMPACT}-${COMMIT_SHA7}"

# runtime_family mapping (descriptive; not collapsed for comparison here).
case "$TARGET_ID" in
  exeris-community)               RUNTIME_FAMILY="exeris" ;;
  spring-hibernate|spring-on-exeris) RUNTIME_FAMILY="spring-boot" ;;
  quarkus-hibernate|quarkus-tuned)   RUNTIME_FAMILY="quarkus" ;;
  *)                              RUNTIME_FAMILY="custom" ;;
esac

echo "=== cold-start-ttfr: ${TARGET_ID} ==="
echo "  health:        ${HEALTH_URL}"
echo "  first request: ${FIRST_REQUEST_URL}"
echo "  iterations:    ${ITERATIONS}"
echo "  output:        ${OUTPUT_DIR}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
now_ns() { date +%s%N; }
elapsed_ms() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", (b - a) / 1000000 }'; }

http_status() {
  # echo HTTP status for a URL, "000" on connect failure. -k for self-signed TLS.
  curl -s -o /dev/null -k -w "%{http_code}" --connect-timeout 2 --max-time 8 "$1" 2>/dev/null || echo "000"
}

CLK_TCK="$(getconf CLK_TCK 2>/dev/null || echo 100)"

resolve_target_pid() {
  # The launch reparents the JVM to init, so the pid file is unreliable. Once the
  # app is ready it owns the listening port, so resolve the real pid from there.
  local p=""
  if command -v lsof >/dev/null 2>&1; then
    p="$(lsof -ti "tcp:${PORT}" -sTCP:LISTEN 2>/dev/null | head -1)"
  fi
  [[ -z "$p" ]] && p="$(fuser "${PORT}/tcp" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | head -1)"
  printf '%s' "$p"
}

read_proc_metrics() {
  # echo "<peak_rss_mb> <cpu_seconds>" for a pid, or "null null" if unavailable.
  # peak RSS = VmHWM (kernel high-water mark); CPU = (utime+stime)/CLK_TCK.
  local pid="$1"
  if [[ -z "$pid" || ! -d "/proc/$pid" ]]; then printf 'null null\n'; return; fi
  local vmhwm stat rest utime stime
  local -a fields
  vmhwm="$(awk '/^VmHWM:/{print $2}' "/proc/$pid/status" 2>/dev/null)"
  stat="$(cat "/proc/$pid/stat" 2>/dev/null)"
  if [[ -z "$vmhwm" || -z "$stat" ]]; then printf 'null null\n'; return; fi
  rest="${stat#*) }"; read -r -a fields <<< "$rest"   # index 0 = state (field 3)
  utime="${fields[11]:-0}"; stime="${fields[12]:-0}"  # field 14/15 = utime/stime
  awk -v k="$vmhwm" -v u="$utime" -v s="$stime" -v t="$CLK_TCK" \
    'BEGIN { printf "%.1f %.3f\n", k/1024, (u+s)/t }'
}

port_open() {
  # True if HOST:PORT accepts a TCP connection. Runs in a subshell so the fd closes.
  [[ -z "$PORT" ]] && return 1
  ( exec 3<>"/dev/tcp/${HOST}/${PORT}" ) >/dev/null 2>&1
}

kill_on_port() {
  # The launch backgrounds an AND-list ('cd .. && java ..' &), so $! is the
  # subshell pid and the JVM is reparented to init — a pid-based kill misses it.
  # Killing by the listening port is the only reliable teardown.
  [[ -z "$PORT" ]] && return 0
  fuser -k -9 "${PORT}/tcp" >/dev/null 2>&1 || true
}

stop_target() {
  local pid=""
  [[ -f "${EXTERNAL_PID_FILE:-/dev/null}" ]] && pid="$(cat "$EXTERNAL_PID_FILE" 2>/dev/null || echo "")"
  if [[ -n "${EXTERNAL_STOP_CMD:-}" ]]; then
    bash -lc "cd '$ROOT' && ${EXTERNAL_STOP_CMD}" >/dev/null 2>&1 || true
  fi
  # Cold-start does NOT measure shutdown, so force-kill for fast, deterministic
  # teardown between iterations (graceful JVM shutdown can take many seconds and
  # would dominate wall-clock without affecting any startup/TTFR measurement).
  [[ -n "$pid" ]] && kill -9 "$pid" >/dev/null 2>&1 || true
  kill_on_port
}

wait_until_down() {
  # Block until the port refuses connections, i.e. the previous instance is truly
  # gone. Without this a stale instance answers the next iteration's health poll
  # and yields an impossible sub-100ms 'startup'.
  local deadline=$(( $(date +%s) + 30 ))
  while (( $(date +%s) < deadline )); do
    if ! port_open; then return 0; fi
    kill_on_port
    sleep 0.2
  done
  return 0
}

cleanup() { stop_target; rm -f "${EXTERNAL_PID_FILE:-}" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Measurement loop
# ---------------------------------------------------------------------------
HEALTH_POLL_S="$(awk -v ms="$HEALTH_POLL_MS" 'BEGIN { printf "%.3f", ms/1000 }')"
ready_count=0

for (( iter=1; iter<=ITERATIONS; iter++ )); do
  export EXTERNAL_PID_FILE="/tmp/exeris-cold-start-${TARGET_ID}-${iter}.pid"
  rm -f "$EXTERNAL_PID_FILE"

  # Ensure a clean slot before spawning a genuinely cold process.
  stop_target; wait_until_down

  echo "  [iter ${iter}/${ITERATIONS}] spawning ..."

  # ---- t0: harness-owned spawn instant -----------------------------------
  t0="$(now_ns)"
  if [[ "$LAUNCHER_MODE" == "external" ]]; then
    bash -lc "cd '$ROOT' && ${EXTERNAL_START_CMD}" >/dev/null 2>&1 || true
  else
    # jar mode: spawn directly so t0 is owned here.
    ( cd "$ROOT" && java ${JVM_FLAGS:-} -jar "$TARGET_CONTRACT_JAR_PATH" \
        >"/tmp/exeris-cold-start-${TARGET_ID}-${iter}.log" 2>&1 & echo $! > "$EXTERNAL_PID_FILE" )
  fi

  # ---- poll health until 200 (or timeout) --------------------------------
  ready_deadline=$(( $(date +%s) + READY_TIMEOUT_SECONDS ))
  health_attempts=0
  t_ready=""
  while true; do
    health_attempts=$(( health_attempts + 1 ))
    if [[ "$(http_status "$HEALTH_URL")" == "200" ]]; then
      t_ready="$(now_ns)"
      break
    fi
    if (( $(date +%s) >= ready_deadline )); then
      break
    fi
    sleep "$HEALTH_POLL_S"
  done

  if [[ -z "$t_ready" ]]; then
    echo "    NOT READY within ${READY_TIMEOUT_SECONDS}s (attempts=${health_attempts}) — excluded from aggregates"
    jq -cn --argjson it "$iter" --argjson ha "$health_attempts" \
      '{iteration:$it, startup_ms:null, ttfr_ms:null, spawn_to_first_request_ms:null, health_attempts:$ha, ready:false}' \
      >> "$SAMPLES_NDJSON"
    stop_target; wait_until_down
    continue
  fi

  # ---- TTFR decay curve: WARMUP_REQUESTS back-to-back requests on a reused
  # (keepalive) connection. Request #1 is the cold spike (connect + cold JIT +
  # lazy init + pool fill); the tail decays toward steady-state. Single curl
  # invocation reuses the connection and reports per-request time_total. ------
  req_urls=(); for (( r=0; r<WARMUP_REQUESTS; r++ )); do req_urls+=("$FIRST_REQUEST_URL"); done
  curl_out="$(curl -s -k -o /dev/null -w '%{http_code} %{time_total}\n' "${req_urls[@]}" 2>/dev/null || true)"
  first_status="$(awk 'NR==1{print $1}' <<<"$curl_out")"; [[ -z "$first_status" ]] && first_status="000"
  series_ms_json="[$(awk 'NF>=2{ printf "%s%.3f", (seen++?",":""), $2*1000 }' <<<"$curl_out")]"
  ttfr_ms="$(awk 'NR==1&&NF>=2{printf "%.3f", $2*1000}' <<<"$curl_out")"; [[ -z "$ttfr_ms" ]] && ttfr_ms="0"

  # ---- resource peak: VmHWM (peak RSS) + CPU ticks, read after the curve -----
  # VmHWM is a monotonic high-water mark, so this captures the peak over the
  # whole spawn -> ready -> warmup-series window.
  proc_pid="$(resolve_target_pid)"
  read -r peak_rss_mb cpu_to_first_s < <(read_proc_metrics "$proc_pid")

  startup_ms="$(elapsed_ms "$t0" "$t_ready")"
  s2f_ms="$(awk -v a="$startup_ms" -v b="$ttfr_ms" 'BEGIN{printf "%.3f", a+b}')"
  ready_count=$(( ready_count + 1 ))

  echo "    startup=${startup_ms}ms  ttfr(spike)=${ttfr_ms}ms  peak_rss=${peak_rss_mb}MB  cpu=${cpu_to_first_s}s  (first status=${first_status}, health attempts=${health_attempts})"

  jq -cn \
    --argjson it "$iter" \
    --argjson startup "$startup_ms" \
    --argjson ttfr "$ttfr_ms" \
    --argjson s2f "$s2f_ms" \
    --argjson rss "$peak_rss_mb" \
    --argjson cpu "$cpu_to_first_s" \
    --argjson ha "$health_attempts" \
    --argjson fs "$first_status" \
    --argjson series "$series_ms_json" \
    '{iteration:$it, startup_ms:$startup, ttfr_ms:$ttfr, spawn_to_first_request_ms:$s2f, peak_rss_mb:$rss, cpu_to_first_request_s:$cpu, latency_series_ms:$series, health_attempts:$ha, first_request_status:$fs, ready:true}' \
    >> "$SAMPLES_NDJSON"

  stop_target; wait_until_down
done

trap - EXIT INT TERM
cleanup

if (( ready_count == 0 )); then
  echo "ERROR: no iteration became ready; nothing to aggregate." >&2
  jq -s '.' "$SAMPLES_NDJSON" > "$TIMELINE_FILE" 2>/dev/null || true
  exit 1
fi

# ---------------------------------------------------------------------------
# Aggregate
# ---------------------------------------------------------------------------
SAMPLES_JSON="$(jq -s '.' "$SAMPLES_NDJSON")"

# stats over a numeric array; percentile uses nearest-rank on the sorted array.
read -r -d '' STATS_DEFS <<'JQ' || true
def pct(p): sort as $s | length as $n
  | if $n == 0 then null else $s[ ((p/100)*($n-1)) | floor ] end;
def stats: { n: length, min: min, max: max, median: pct(50), p90: pct(90), p99: pct(99),
  mean: (add/length),
  stdev: (if length < 2 then 0
          else (add/length) as $m | ((map(($m - .)*($m - .)) | add)/(length-1)) | sqrt end) };
JQ

STARTUP_STATS="$(jq "$STATS_DEFS"' [ .[] | select(.ready==true) | .startup_ms ] | stats' <<<"$SAMPLES_JSON")"
TTFR_STATS="$(jq    "$STATS_DEFS"' [ .[] | select(.ready==true) | .ttfr_ms ]    | stats' <<<"$SAMPLES_JSON")"
S2F_STATS="$(jq     "$STATS_DEFS"' [ .[] | select(.ready==true) | .spawn_to_first_request_ms ] | stats' <<<"$SAMPLES_JSON")"
# Resource stats skip null samples (pid not resolvable on some hosts); emit null block if none.
RSS_STATS="$(jq "$STATS_DEFS"' [ .[] | select(.ready==true) | .peak_rss_mb // empty ] | if length>0 then stats else null end' <<<"$SAMPLES_JSON")"
CPU_STATS="$(jq "$STATS_DEFS"' [ .[] | select(.ready==true) | .cpu_to_first_request_s // empty ] | if length>0 then stats else null end' <<<"$SAMPLES_JSON")"

# TTFR decay curve: spike (req#1) -> steady (median of last 25%) per launch,
# aggregated; plus position-wise p50 curve over launches of the modal length.
read -r -d '' CURVE_DEFS <<'JQ' || true
def pctl(p): sort as $s | length as $n | if $n==0 then null else $s[ ((p/100)*($n-1))|floor ] end;
def med: pctl(50);
def steady_of: .[ ((length*0.75)|floor) : ] | med;
JQ
TTFR_CURVE="$(jq -c "$CURVE_DEFS"'
  [ .[] | select(.ready==true) | .latency_series_ms | select(length>0) ] as $series
  | if ($series|length)==0 then null else
      ($series | map(steady_of)) as $steadies
      | ($series | map(.[0] / steady_of)) as $ratios
      | ($series | map(
          steady_of as $st | . as $s | ($s|length) as $n
          | ( first( range(0;$n) | select( ($s[.:]) | all(. <= 1.2*$st) ) ) // ($n-1) ) + 1
        )) as $settles
      | ($series | map(length) | group_by(.) | max_by(length) | .[0]) as $N
      | ($series | map(select(length==$N))) as $full
      | { requests: $N,
          steady_ms: ($steadies|{n:length,min:min,max:max,median:med,mean:(add/length)}),
          spike_ratio_median: ($ratios|med),
          settle_request_median: ($settles|med),
          curve_p50_ms: [ range(0;$N) as $k | ($full|map(.[$k])|med) ] }
    end' <<<"$SAMPLES_JSON")"

# ---------------------------------------------------------------------------
# Capture env
# ---------------------------------------------------------------------------
"${ROOT}/scripts/capture-env.sh" --profile "$PROFILE" --tool "startup-probe" > "$ENV_FILE" 2>/dev/null \
  || echo '{}' > "$ENV_FILE"

# ---------------------------------------------------------------------------
# Timeline artifact (raw per-iteration)
# ---------------------------------------------------------------------------
jq -n \
  --arg run_id "$RUN_ID" \
  --arg target "$TARGET_ID" \
  --arg health "$HEALTH_URL" \
  --arg first "$FIRST_REQUEST_URL" \
  --argjson samples "$SAMPLES_JSON" \
  '{run_id:$run_id, target:$target, health_endpoint:$health, first_request_endpoint:$first, samples:$samples}' \
  > "$TIMELINE_FILE"

# ---------------------------------------------------------------------------
# Result artifact
# ---------------------------------------------------------------------------
# TLS state of the measured traffic, derived from the health/first-request scheme.
# startup_ms is transport-independent (process boot -> port bind); ttfr_ms is NOT
# (a TLS handshake / h2 negotiation on the first request inflates it), so we record
# tls.enabled per target and caveat ttfr cross-target comparisons accordingly.
if [[ "$HEALTH_URL" == https://* ]]; then TLS_ENABLED="true"; else TLS_ENABLED="false"; fi

READINESS_NOTE="Black-box: first HTTP 200 from ${HEALTH_URL}. 'ready' semantics are framework-specific (${RUNTIME_FAMILY}); cross-runtime startup_ms rows must carry this caveat. First request over $([ "$TLS_ENABLED" = true ] && echo TLS || echo cleartext); startup_ms is transport-independent but ttfr_ms is not, so ttfr is only cross-target comparable between same-transport targets."

jq -n \
  --arg run_id "$RUN_ID" \
  --arg ts "$RUN_TS_ISO" \
  --arg env_ref "$ENV_FILE" \
  --arg sha "$COMMIT_SHA" \
  --arg target_id "$TARGET_ID" \
  --arg tier "$TARGET_TIER" \
  --arg protocol "$CONTRACT_PROTOCOL" \
  --argjson tls_enabled "$TLS_ENABLED" \
  --arg runtime_family "$RUNTIME_FAMILY" \
  --arg health "$HEALTH_URL" \
  --arg first "$FIRST_REQUEST_URL" \
  --arg readiness_note "$READINESS_NOTE" \
  --argjson iterations "$ITERATIONS" \
  --argjson startup_stats "$STARTUP_STATS" \
  --argjson ttfr_stats "$TTFR_STATS" \
  --argjson s2f_stats "$S2F_STATS" \
  --argjson rss_stats "$RSS_STATS" \
  --argjson cpu_stats "$CPU_STATS" \
  --argjson ttfr_curve "$TTFR_CURVE" \
  --argjson samples "$SAMPLES_JSON" \
  '{
    schema_version: "1",
    run_id: $run_id,
    timestamp: $ts,
    scenario: "cold-start-ttfr",
    tool: "startup-probe",
    env_ref: $env_ref,
    transport_mode: "loopback-h1",
    claim_scope: "exploratory",
    execution_class: "exploratory",
    comparison_axis: "within-tier",
    runner_status: "success",
    reproducibility_status: "complete",
    final_reason: "ok",
    tls: { enabled: $tls_enabled },
    target: {
      repo: "exeris-benchmarks",
      commit_sha: $sha,
      version: $target_id,
      tier: $tier,
      mode: "baseline-db",
      protocol: $protocol,
      runtime_family: $runtime_family,
      artifact_kind: "jvm-jar",
      execution_vm: "jvm",
      build_mode: "jit"
    },
    run_config: { startup_iterations: $iterations },
    metrics: {},
    startup: {
      iterations: $iterations,
      measure: "spawn-to-health",
      readiness_definition: $readiness_note,
      health_endpoint: $health,
      first_request_endpoint: $first,
      startup_ms: $startup_stats,
      ttfr_ms: $ttfr_stats,
      spawn_to_first_request_ms: $s2f_stats,
      samples: $samples
    }
    + (if $rss_stats != null then { peak_rss_mb: $rss_stats } else {} end)
    + (if $cpu_stats != null then { cpu_to_first_request_s: $cpu_stats } else {} end)
    + (if $ttfr_curve != null then { ttfr_curve: $ttfr_curve } else {} end),
    notes: "Cold-start + TTFR over independent JVM launches. t0 = harness-owned spawn instant. DB pre-running (app cold start only). Exploratory descriptive; not a guard/regression gate.",
    tags: ["cold-start", "ttfr", ("runtime-family:" + $runtime_family)]
  }' > "$RESULT_FILE"

rm -f "$SAMPLES_NDJSON"

# ---------------------------------------------------------------------------
# Schema validation (mirror run-entity-read-by-id.sh)
# ---------------------------------------------------------------------------
echo "Validating result artifact against schema ..."
SCHEMA_FILE="${ROOT}/schemas/benchmark-result.schema.json"
if command -v check-jsonschema >/dev/null 2>&1; then
  check-jsonschema --schemafile "$SCHEMA_FILE" "$RESULT_FILE" \
    || { echo "ERROR: result artifact failed schema validation" >&2; exit 1; }
elif command -v ajv >/dev/null 2>&1; then
  ajv validate -s "$SCHEMA_FILE" -d "$RESULT_FILE" \
    || { echo "ERROR: result artifact failed schema validation" >&2; exit 1; }
elif command -v python3 >/dev/null 2>&1; then
  python3 - "$SCHEMA_FILE" "$RESULT_FILE" <<'PY' || exit 1
import json, sys
schema_path, data_path = sys.argv[1], sys.argv[2]
try:
    import jsonschema
except Exception:
    print("WARN: python3 'jsonschema' module missing; skipping validation", file=sys.stderr)
    sys.exit(0)
with open(schema_path) as f: schema = json.load(f)
with open(data_path) as f: data = json.load(f)
try:
    jsonschema.validate(instance=data, schema=schema)
except jsonschema.exceptions.ValidationError as e:
    print(f"ERROR: Schema validation failed: {e.message}", file=sys.stderr)
    print("  instance path: " + ".".join(str(p) for p in e.path), file=sys.stderr)
    sys.exit(1)
print("Schema validation PASSED")
PY
else
  echo "WARN: no JSON schema validator found; skipping validation" >&2
fi

echo ""
echo "=== cold-start-ttfr complete: ${TARGET_ID} (${ready_count}/${ITERATIONS} ready) ==="
echo "  startup_ms : $(jq -c '{median,p90,p99,min,max}' <<<"$STARTUP_STATS")"
echo "  ttfr_ms    : $(jq -c '{median,p90,p99,min,max}' <<<"$TTFR_STATS")"
[[ "$RSS_STATS" != null ]] && echo "  peak_rss_mb: $(jq -c '{median,min,max}' <<<"$RSS_STATS")"
[[ "$CPU_STATS" != null ]] && echo "  cpu_to_first_request_s: $(jq -c '{median,min,max}' <<<"$CPU_STATS")"
[[ "$TTFR_CURVE" != null ]] && echo "  ttfr_curve : $(jq -c '{spike_ms:.curve_p50_ms[0], steady_ms:.steady_ms.median, spike_ratio:.spike_ratio_median, settle_req:.settle_request_median}' <<<"$TTFR_CURVE")"
echo "  result   : ${RESULT_FILE}"
echo "  timeline : ${TIMELINE_FILE}"
echo "  env      : ${ENV_FILE}"
