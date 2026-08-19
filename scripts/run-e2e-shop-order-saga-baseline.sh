#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_ROOT/tools/bench/lib"

source "$LIB/readiness.sh"
source "$LIB/protocol.sh"
source "$LIB/resource-sampler.sh"
source "$LIB/os-sampler.sh"
source "$LIB/jfr.sh"
source "$LIB/jcmd.sh"
source "$LIB/perf.sh"
source "$LIB/k6.sh"
source "$LIB/run-summary.sh"

# Saga-order runs opt into Axon explicitly; generic runtime startup stays default-off.
export EXERIS_AXON_ENABLED="${EXERIS_AXON_ENABLED:-true}"

# ADR-035 admission equalization, carried over from the entity-read campaigns
# (results/reports/2026-07-22-entity-read-by-id-memory-cpu-sweep.md, build fence 1bf4767).
#
# The default queueDepthAllowanceRatio is 8, and under connection pressure Exeris SHEDS
# while HikariCP and Tomcat BLOCK. That is a policy difference, not a runtime property, and
# comparing a shedding stack against blocking ones measures the policy: it is what produced
# an 84 % error rate on the exeris arm in that report'"'"'s pool pre-runs, and raising the ratio
# to 32 took all 24 runs to zero errors. This scenario never applied the equalization, and
# its own rate-100 finding has been chasing an unexplained exeris-only connection drop ever
# since.
#
# The property string is the one those campaigns actually ran with. Recorded because the
# saga ledger'"'"'s earlier A/B of this knob is caveated as unverified - the class constant
# carries a LEADING DOT (the prefix is applied at runtime), so a wrong -D form is silently
# ignored and reads as "the knob has no effect".
if [[ "${TARGET_APP:-}" == exeris-* || "${TARGET_APP:-}" == *on-exeris* ]]; then
  export EXERIS_JAVA_OPTS="${EXERIS_JAVA_OPTS:-} -Dexeris.persistence.admission.queueDepthAllowanceRatio=${EXERIS_ADMISSION_QUEUE_RATIO:-32}"
fi

usage() {
  cat <<'EOF'
Usage: run-e2e-shop-order-saga-baseline.sh [options]

Options:
  --base-url <url>         Base URL for target app (default: https://localhost:8080)
  --contract-id <id>       Contract id (default: exeris_community_h1_v2).
                           Restate runs MUST pass this explicitly with a
                           restate-appropriate id: the h2c default is never
                           stamped onto a restate (h1 facade) run — the runner
                           aborts instead of mislabeling the artifacts.
  --target-app <name>      Target app label (default: exeris-community)
  --auto-start-infra       Auto-start benchmark infra (Postgres + Neo4j) via docker compose (default)
  --no-auto-start-infra    Do not auto-start benchmark infra
  --auto-start-target      Auto-start target app if health preflight fails (default)
  --no-auto-start-target   Do not auto-start target app if health preflight fails
  --force-restart-target      Kill and restart target even if already healthy (default: enabled)
  --no-force-restart-target   Reuse existing target process if already healthy
  --health-timeout-seconds <n>  Seconds to wait for target health (default: 60)
  --graph-track <name>     Graph track label (default: postgres)
  --fault-mode <mode>      Fault-class label per CONTRACT-v2 s4: terminal|transient (default: terminal).
                           Never mixed in one run; headline claims come from terminal runs only.
  --profile <name>         Capture profile for env metadata (default: dev-laptop)
  --k6-docker-image <image>  Docker image for fallback k6 run (default: grafana/k6:latest)
  --output-dir <path>      Output directory (default: results/raw/e2e-shop-order-saga/<utc>-baseline)
  --skip-seed-verify       Skip seed verification
  --enable-jfr             Enable JFR recording via jcmd (default: enabled)
  --no-jfr                 Disable JFR recording
  --jfr-settings <name>    JFR settings (default: profile)
  --jfr-max-size-mb <n>    JFR max file size hint in MB (default: 256)
  --enable-perf-stat       Enable perf stat collection during k6 run (default: disabled)
  --cgroup-memory-limit-mb <n>  Enforce OS-level memory limit on target (cgroup v2, MB). Empty = disabled.
  --cgroup-cpu-quota-pct <n>    Enforce OS-level CPU quota on target (cgroup v2, %). Empty = disabled.
  -h, --help               Show this help

Environment (durability-tier declaration, CONTRACT-v2 s8):
  The durability_tier stamped into run-metadata.json / result.json /
  correctness-gate.json is a LABEL only — it changes no target behavior.
  Cross-tier comparisons are forbidden (s8); relabel via these overrides when
  the actual durability configuration differs (e.g. WAL fsync disabled -> T1):
  RESTATE_DURABILITY_TIER_LABEL  Label for restate runs (default:
                                 T2-fsync-node-durable — restate-server 1.7
                                 default, RocksDB WAL fsync per commit batch).
  BENCH_DURABILITY_TIER_LABEL    Label for all other targets (default:
                                 T2-fsync-node-durable-postgres — Postgres-backed
                                 saga state at synchronous_commit=on).
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

require_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "Missing required file: $file" >&2
    exit 1
  fi
}

file_sha256_or_unknown() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "unknown"
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" 2>/dev/null | awk '{print $1}'
  else
    echo "unknown"
  fi
}

_ensure_docker_daemon() {
  # Check if the Docker daemon is reachable.
  if docker info >/dev/null 2>&1; then
    return 0
  fi

  # Daemon unreachable or iptables chains broken — attempt a restart.
  echo "Docker daemon is not reachable or has broken network chains; attempting 'sudo systemctl restart docker'..." >&2
  if sudo systemctl restart docker 2>&1; then
    echo "Docker daemon restarted. Waiting for daemon to become ready..." >&2
    local attempts=0
    while ! docker info >/dev/null 2>&1; do
      sleep 2
      attempts=$((attempts + 1))
      if [[ $attempts -ge 10 ]]; then
        echo "ERROR: Docker daemon did not become ready after restart." >&2
        return 1
      fi
    done
    echo "Docker daemon is ready." >&2
    return 0
  else
    echo "ERROR: 'sudo systemctl restart docker' failed. Start Docker manually and retry." >&2
    return 1
  fi
}

_ensure_bench_tls_cert() {
  local tls_dir="/tmp/exeris-bench-tls"
  local cert_path="$tls_dir/bench-cert.pem"
  local key_path="$tls_dir/bench-key.pem"

  if [[ -n "${EXERIS_TRANSPORT_CERT_PATH:-}" && -f "${EXERIS_TRANSPORT_CERT_PATH}" \
      && -n "${EXERIS_TRANSPORT_KEY_PATH:-}" && -f "${EXERIS_TRANSPORT_KEY_PATH}" ]]; then
    echo "TLS cert: using caller-provided cert at ${EXERIS_TRANSPORT_CERT_PATH}"
    return 0
  fi

  if ! command -v openssl >/dev/null 2>&1; then
    echo "Warning: openssl not found; TLS cert generation skipped. Set EXERIS_TRANSPORT_CERT_PATH/KEY_PATH manually." >&2
    return 1
  fi

  mkdir -p "$tls_dir"
  chmod 700 "$tls_dir"

  if [[ -f "$cert_path" && -f "$key_path" ]]; then
    echo "TLS cert: reusing existing bench cert at ${cert_path}"
  else
    echo "TLS cert: generating self-signed bench cert at ${cert_path}"
    openssl req -x509 -newkey rsa:2048 \
      -keyout "$key_path" -out "$cert_path" \
      -days 3650 -nodes \
      -subj '/CN=localhost/O=exeris-bench' \
      -addext 'subjectAltName=IP:127.0.0.1,DNS:localhost' \
      2>/dev/null
    chmod 600 "$key_path" "$cert_path"
  fi

  export EXERIS_TRANSPORT_CERT_PATH="$cert_path"
  export EXERIS_TRANSPORT_KEY_PATH="$key_path"
  echo "TLS cert exported: EXERIS_TRANSPORT_CERT_PATH=${cert_path}"
}

# Stop every container/backend sampler subshell started by this run.
#
# Split out of the end-of-run path on 2026-08-19 because that path is NOT the only
# way this script exits, and the samplers are `while true` loops: anything that
# skipped it leaked a per-second loop that outlives the run. Four of them were
# found alive four hours after their campaign died -- two `docker stats`, one
# `docker exec psql` against the shared Postgres once a second, all still
# appending to a run directory nothing would ever read again.
#
# Idempotent by blanking each pid as it is reaped, so the normal path and the
# EXIT trap can both call it. Every read is ${x:-} because the trap can fire
# before these are assigned and `set -u` is in effect.
_stop_container_samplers() {
  local _p _pid
  for _p in AXON RESTATE PAYMENT_GATEWAY POSTGRES NEO4J; do
    eval "_pid=\${${_p}_STATS_PID:-}"
    if [[ -n "$_pid" ]]; then
      kill "$_pid" >/dev/null 2>&1 || true
      wait "$_pid" 2>/dev/null || true
      eval "${_p}_STATS_PID=''"
    fi
  done
  if [[ -n "${PG_CONNECTIONS_PID:-}" ]]; then
    kill "$PG_CONNECTIONS_PID" >/dev/null 2>&1 || true
    wait "$PG_CONNECTIONS_PID" 2>/dev/null || true
    PG_CONNECTIONS_PID=""
  fi
}

cleanup_baseline() {
  # Guard: this runs from EXIT and from the INT/TERM/HUP handlers below, and a
  # signal arriving during cleanup would otherwise re-enter it.
  [[ -n "${_CLEANUP_BASELINE_DONE:-}" ]] && return 0
  _CLEANUP_BASELINE_DONE=1
  [[ -n "${PRE_TMP:-}" ]] && rm -f "$PRE_TMP"
  _stop_container_samplers
  bench_stop_resource_sampler
  bench_stop_perf_stat
  # Best-effort stop of OS sidecars on any exit path (guarded: trap may fire
  # before these vars are assigned, and set -u is in effect).
  if [[ -n "${TARGET_PIDSTAT_PID:-}" ]]; then
    bench_stop_pidstat_sampler "$TARGET_PIDSTAT_PID" "${TARGET_PIDSTAT_CSV:-/dev/null}" 2>/dev/null || true
    TARGET_PIDSTAT_PID=""
  fi
  if [[ -n "${HOST_MPSTAT_PID:-}" ]]; then
    bench_stop_mpstat_sampler "$HOST_MPSTAT_PID" "${HOST_MPSTAT_CSV:-/dev/null}" 2>/dev/null || true
    HOST_MPSTAT_PID=""
  fi
  # Stop the target process so it does not bleed into subsequent runs.
  if [[ -n "${STOP_TARGET_SCRIPT:-}" && -f "$STOP_TARGET_SCRIPT" && -n "${TARGET_APP:-}" ]]; then
    "$STOP_TARGET_SCRIPT" "$TARGET_APP" 2>/dev/null || true
  fi
  # Best-effort capture of the target process log into the run dir for post-mortem.
  if [[ -n "${TARGET_APP_LOG_FILE:-}" && -f "$TARGET_APP_LOG_FILE" && -n "${LOGS_DIR:-}" ]]; then
    mkdir -p "$LOGS_DIR"
    cp -f "$TARGET_APP_LOG_FILE" "$LOGS_DIR/target-runtime.log" 2>/dev/null || true
  fi
  # Stop the transient systemd scope used for cgroup limit enforcement (best-effort).
  if [[ -n "${_BENCH_CGROUP_SCOPE_UNIT:-}" ]]; then
    systemctl --user stop "${_BENCH_CGROUP_SCOPE_UNIT}.scope" 2>/dev/null || true
  fi
}

_pick_free_port() {
  local preferred="$1"
  local lo="${2:-9100}"
  local hi="${3:-9999}"
  if ! ss -tlnp 2>/dev/null | grep -qE ":${preferred}[ \t]"; then
    echo "$preferred"
    return 0
  fi
  local p
  for p in $(seq "$lo" "$hi"); do
    if ! ss -tlnp 2>/dev/null | grep -qE ":${p}[ \t]"; then
      echo "$p"
      return 0
    fi
  done
  echo "$preferred"
}

_apply_process_cgroup_limits() {
  local pid="$1"
  local cgroup_meta_json="${2:-}"

  if [[ -z "$BENCH_CGROUP_MEMORY_LIMIT_MB" && -z "$BENCH_CGROUP_CPU_QUOTA_PCT" ]]; then
    [[ -n "$cgroup_meta_json" ]] && printf '{"enabled":false,"reason":"no_limits_configured"}\n' > "$cgroup_meta_json"
    return 0
  fi
  if [[ -z "$pid" ]]; then
    echo "Warning: cgroup limits requested but target pid not known; skipping." >&2
    [[ -n "$cgroup_meta_json" ]] && printf '{"enabled":false,"reason":"pid_unknown"}\n' > "$cgroup_meta_json"
    return 0
  fi
  if ! command -v systemd-run >/dev/null 2>&1; then
    echo "Warning: systemd-run not available; cgroup limit enforcement skipped." >&2
    [[ -n "$cgroup_meta_json" ]] && printf '{"enabled":false,"reason":"systemd_run_unavailable"}\n' > "$cgroup_meta_json"
    return 0
  fi

  local scope_unit="bench-${TARGET_APP//[^a-zA-Z0-9_-]/_}-$$"
  local sdrun_args=()

  if [[ -n "$BENCH_CGROUP_MEMORY_LIMIT_MB" ]]; then
    sdrun_args+=(-p "MemoryMax=${BENCH_CGROUP_MEMORY_LIMIT_MB}M")
    # MemorySwapMax=0 makes MemoryMax a hard wall: no swap escape, cgroup OOM-kills
    # the process immediately rather than thrashing system-wide swap.
    sdrun_args+=(-p "MemorySwapMax=0")
  fi
  if [[ -n "$BENCH_CGROUP_CPU_QUOTA_PCT" ]]; then
    sdrun_args+=(-p "CPUQuota=${BENCH_CGROUP_CPU_QUOTA_PCT}%")
  fi

  # Start a placeholder process inside a new delegated transient scope.
  # The target PID will be moved into this scope before the placeholder is killed.
  local _ph_pid
  systemd-run --user --scope --unit="$scope_unit" \
    "${sdrun_args[@]}" -- sleep infinity >/dev/null 2>&1 &
  _ph_pid=$!

  # Poll until the scope cgroup path is available (typically <200ms).
  local _waited=0 scope_cgroup_rel=""
  while (( _waited < 30 )); do
    scope_cgroup_rel="$(systemctl --user show "${scope_unit}.scope" \
      --property=ControlGroup --value 2>/dev/null || true)"
    [[ -n "$scope_cgroup_rel" ]] && break
    sleep 0.1
    (( _waited++ ))
  done

  if [[ -z "$scope_cgroup_rel" ]]; then
    echo "Warning: timed out waiting for scope cgroup '${scope_unit}'; killing placeholder." >&2
    kill "$_ph_pid" 2>/dev/null || true; wait "$_ph_pid" 2>/dev/null || true
    [[ -n "$cgroup_meta_json" ]] && jq -n --arg u "$scope_unit" \
      '{"enabled":false,"reason":"scope_cgroup_unavailable","scope_unit":$u}' > "$cgroup_meta_json"
    return 0
  fi

  local scope_path="/sys/fs/cgroup${scope_cgroup_rel}"

  # Move target PID into the scope while the placeholder is still alive (scope non-empty).
  if ! printf '%s\n' "$pid" > "${scope_path}/cgroup.procs" 2>/dev/null; then
    echo "Warning: could not move pid $pid into ${scope_path}; killing placeholder." >&2
    kill "$_ph_pid" 2>/dev/null || true; wait "$_ph_pid" 2>/dev/null || true
    [[ -n "$cgroup_meta_json" ]] && jq -n --arg sp "$scope_path" --arg p "$pid" \
      '{"enabled":false,"reason":"cgroup_procs_write_failed","scope_path":$sp,"pid":($p|tonumber)}' > "$cgroup_meta_json"
    return 0
  fi

  # Placeholder no longer needed; the scope survives while the target PID is active.
  kill "$_ph_pid" 2>/dev/null || true; wait "$_ph_pid" 2>/dev/null || true
  _BENCH_CGROUP_SCOPE_UNIT="$scope_unit"
  echo "Process pid ${pid} moved to systemd scope ${scope_unit} (${scope_path})"

  local mem_applied=false cpu_applied=false
  local mem_limit_bytes="" cpu_max_str=""
  if [[ -n "$BENCH_CGROUP_MEMORY_LIMIT_MB" ]]; then
    mem_applied=true
    mem_limit_bytes=$(( BENCH_CGROUP_MEMORY_LIMIT_MB * 1024 * 1024 ))
    echo "  MemoryMax = ${BENCH_CGROUP_MEMORY_LIMIT_MB}M applied"
  fi
  if [[ -n "$BENCH_CGROUP_CPU_QUOTA_PCT" ]]; then
    cpu_applied=true
    cpu_max_str="$(( BENCH_CGROUP_CPU_QUOTA_PCT * 100000 / 100 )) 100000"
    echo "  CPUQuota  = ${BENCH_CGROUP_CPU_QUOTA_PCT}% applied"
  fi

  if [[ -n "$cgroup_meta_json" ]]; then
    jq -n \
      --arg  scope_path      "$scope_path" \
      --arg  pid             "$pid" \
      --argjson mem_applied  "$mem_applied" \
      --argjson cpu_applied  "$cpu_applied" \
      --arg  memory_limit_mb "${BENCH_CGROUP_MEMORY_LIMIT_MB:-}" \
      --arg  cpu_quota_pct   "${BENCH_CGROUP_CPU_QUOTA_PCT:-}" \
      --arg  mem_limit_bytes "${mem_limit_bytes:-}" \
      --arg  cpu_max_str     "${cpu_max_str:-}" \
      '{
        enabled:          true,
        scope_path:       $scope_path,
        pid:              ($pid | tonumber),
        memory_applied:   $mem_applied,
        cpu_applied:      $cpu_applied,
        memory_limit_mb:  (if $memory_limit_mb != "" then ($memory_limit_mb | tonumber) else null end),
        cpu_quota_pct:    (if $cpu_quota_pct   != "" then ($cpu_quota_pct   | tonumber) else null end),
        memory_max_bytes: (if $mem_limit_bytes  != "" then ($mem_limit_bytes | tonumber) else null end),
        cpu_max_raw:      (if $cpu_max_str      != "" then $cpu_max_str                  else null end)
      }' > "$cgroup_meta_json"
  fi
}

configure_target_runtime_overrides() {
  local declared_protocol_mode

  # shop-order-saga needs Flow (saga orchestration) and Events. Graph was removed
  # from this scenario on 2026-07-31 (CONTRACT-v2 §2): it confounded the only
  # comparison the scenario exists to make, and on the Exeris arm the traversal
  # matched nothing for an entire campaign. Booting the subsystem anyway would make
  # this stack pay RSS for a capability the workload no longer uses. The Exeris community target boots a lean
  # http,persistence,crypto set by default; opt the full set in here. (Ignored by the
  # Spring/Quarkus targets, which read this env var not at all.)
  export EXERIS_SUBSYSTEMS="http,persistence,flow,events,crypto"

  # CONTRACT-v2 fault-injection knobs, exported BEFORE target start so every stack
  # sees the same declared configuration (s4 fault-class label + s5 pinned retry
  # policy; defaults are not trusted). Targets that have not yet implemented the
  # v2 deterministic decline ignore these; the s4.1 correctness gate then fails
  # the run instead of letting a probabilistic population pass as deterministic.
  export EXERIS_SAGA_FAULT_MODE="$FAULT_MODE"
  export EXERIS_SAGA_RETRY_MAX_ATTEMPTS="3"
  export EXERIS_SAGA_RETRY_INITIAL_BACKOFF_MS="50"
  export EXERIS_SAGA_RETRY_BACKOFF_FACTOR="2"
  export EXERIS_SAGA_RETRY_JITTER="false"

  if [[ "$GRAPH_TRACK" == "neo4j" ]]; then
    export EXERIS_GRAPH_BACKEND_TYPE="neo4j"
    : "${EXERIS_GRAPH_NEO4J_URI:=bolt://localhost:7687}"
    : "${EXERIS_GRAPH_NEO4J_USER:=neo4j}"
    : "${EXERIS_GRAPH_NEO4J_PASSWORD:=password}"
    : "${EXERIS_GRAPH_NEO4J_DATABASE:=neo4j}"
    export EXERIS_GRAPH_NEO4J_URI
    export EXERIS_GRAPH_NEO4J_USER
    export EXERIS_GRAPH_NEO4J_PASSWORD
    export EXERIS_GRAPH_NEO4J_DATABASE
  else
    export EXERIS_GRAPH_BACKEND_TYPE="postgresql"
    unset EXERIS_GRAPH_NEO4J_URI
    unset EXERIS_GRAPH_NEO4J_USER
    unset EXERIS_GRAPH_NEO4J_PASSWORD
    unset EXERIS_GRAPH_NEO4J_DATABASE
  fi

  # Restate deployment-unit env (CONTRACT-v2 s1: target JVM + external
  # restate-server). Exported BEFORE target start so the app's startup
  # self-registration and the baseline's post-readiness force-registration
  # agree on the same endpoints. restate-server runs in Docker
  # (benchmark-restate-server) with host networking, so the host-side SDK
  # endpoint is 127.0.0.1:<port> from inside the container too.
  if [[ "$CONTRACT_ID" == *restate* || "$TARGET_APP" == *restate* ]]; then
    export RESTATE_SDK_PORT="${RESTATE_SDK_PORT:-9084}"
    export RESTATE_INGRESS_URL="${RESTATE_INGRESS_URL:-http://localhost:8080}"
    export RESTATE_ADMIN_URL="${RESTATE_ADMIN_URL:-http://localhost:9070}"
    export RESTATE_SDK_ADVERTISED_URL="${RESTATE_SDK_ADVERTISED_URL:-http://${BENCH_CONTAINER_HOST_ADDR}:${RESTATE_SDK_PORT}}"
    export RESTATE_AUTO_REGISTER="${RESTATE_AUTO_REGISTER:-true}"
  fi

  declared_protocol_mode="$(bench_derive_declared_protocol_mode "$TARGET_APP")"
  case "$declared_protocol_mode" in
    h1)
      export EXERIS_HTTP_MAX_VERSION="HTTP_1_1"
      export EXERIS_HTTP_H2C_UPGRADE_ENABLED="false"
      export EXERIS_HTTP2_ENABLED="false"
      export EXERIS_SSL_ENABLED="false"
      export EXERIS_INSECURE_REQUESTS="enabled"
      ;;
    https-h1)
      export EXERIS_HTTP_MAX_VERSION="HTTP_1_1"
      export EXERIS_HTTP_H2C_UPGRADE_ENABLED="false"
      export EXERIS_HTTP2_ENABLED="false"
      export EXERIS_SSL_ENABLED="true"
      export EXERIS_INSECURE_REQUESTS="disabled"
      _ensure_bench_tls_cert || echo "Warning: TLS cert generation failed; SSL startup may fail." >&2
      ;;
    h2)
      export EXERIS_HTTP_MAX_VERSION="HTTP_2"
      export EXERIS_HTTP_H2C_UPGRADE_ENABLED="false"
      export EXERIS_HTTP2_ENABLED="true"
      export EXERIS_SSL_ENABLED="true"
      export EXERIS_INSECURE_REQUESTS="disabled"
      _ensure_bench_tls_cert || echo "Warning: TLS cert generation failed; SSL startup may fail." >&2
      ;;
    h2c|*)
      export EXERIS_HTTP_MAX_VERSION="HTTP_2"
      export EXERIS_HTTP_H2C_UPGRADE_ENABLED="true"
      export EXERIS_HTTP2_ENABLED="true"
      export EXERIS_SSL_ENABLED="false"
      export EXERIS_INSECURE_REQUESTS="enabled"
      ;;
  esac

  # Enable NMT for off-heap capture (matching full-triad behavior).
  export SPRING_JAVA_OPTS="${SPRING_JAVA_OPTS:-} -XX:NativeMemoryTracking=summary"
  export EXERIS_JAVA_OPTS="${EXERIS_JAVA_OPTS:-} -XX:NativeMemoryTracking=summary"
  export QUARKUS_JAVA_OPTS="${QUARKUS_JAVA_OPTS:-} -XX:NativeMemoryTracking=summary"
  export RESTATE_JAVA_OPTS="${RESTATE_JAVA_OPTS:-} -XX:NativeMemoryTracking=summary"

  # Intentionally no -XX:MaxRAM / -XX:MaxRAMPercentage flags here.
  #
  # The cgroup is applied AFTER JVM startup (via _apply_process_cgroup_limits).
  # At startup the JVM sees the host RAM and reserves a large virtual heap (e.g. 8 GB).
  # cgroup v2 charges only pages that are actually faulted in, not virtual reservations,
  # so the process runs within the physical limit naturally.
  #
  # Setting -XX:MaxRAM=<cgroup_limit> would cap the virtual address space to that size,
  # forcing heap + metaspace + code cache + native buffers to compete for the same
  # tiny budget → OOM-kill immediately at load time. Empirically confirmed: without
  # the flag Exeris ran a full 3-minute run inside 256MB cgroup; with it the process
  # was OOM-killed within 30 seconds (k6 exit 141, 19 resource samples).
  # Derive port from BASE_URL so EXTERNAL_START_CMD uses the right port.
  local _base_port
  _base_port="$(bench_extract_port_from_url "$BASE_URL")"
  if [[ -n "$_base_port" && "$_base_port" =~ ^[0-9]+$ ]]; then
    export EXERIS_PORT="$_base_port"
    export SPRING_SERVER_PORT="$_base_port"
    export SERVER_PORT="$_base_port"
    # For Quarkus h2 mode: HTTP plain port must not collide with the SSL port.
    # EXERIS_HTTP_PORT controls quarkus.http.port (plain); EXERIS_PORT goes to quarkus.http.ssl-port.
    if [[ "${declared_protocol_mode:-}" == "h2" ]]; then
      export EXERIS_HTTP_PORT="$(( 10#${_base_port} + 10000 ))"
    else
      export EXERIS_HTTP_PORT="$_base_port"
    fi
  fi

  # CONTRACT-v2 §4 (parking workload): where the target dispatches a payment, and
  # where the gateway calls back to settle it.
  #
  # Exported explicitly rather than left to each target's compiled-in default. The
  # defaults necessarily differ per stack (different ports, and restate's callback
  # goes to the Restate ingress rather than to the target at all), and a wrong
  # default fails INVISIBLY: the saga dispatches, parks, and simply never settles.
  # That reads as "slow stack", not as "misconfigured callback".
  if [[ "$BENCH_PAYMENT_PARKING" == "1" ]]; then
    export EXERIS_PAYMENT_GATEWAY_URL="${EXERIS_PAYMENT_GATEWAY_URL:-http://localhost:9300/payments}"
    local _callback_port="${EXERIS_HTTP_PORT:-${_base_port:-}}"
    if [[ -z "${EXERIS_PAYMENT_CALLBACK_URL:-}" && ! "$_callback_port" =~ ^[0-9]+$ ]]; then
      # Without a port the URL would be built as ".../127.0.0.1:/api/..." —
      # syntactically plausible, uniformly unreachable, and the only symptom would be
      # every saga stranding. Refuse instead.
      echo "ERROR: BENCH_PAYMENT_PARKING=1 but no target port could be derived from BASE_URL='${BASE_URL}'." >&2
      echo "ERROR: the gateway callback URL cannot be built; every saga would park forever." >&2
      echo "ERROR: Set EXERIS_PAYMENT_CALLBACK_URL explicitly to override." >&2
      exit 75
    fi
    # BENCH_CONTAINER_HOST_ADDR is how a container addresses the host, and it is one
    # knob rather than four literals because it changed once already: it was
    # host.docker.internal while the stack ran on the docker bridge, and is 127.0.0.1
    # now that every service is host-networked. A wrong value fails invisibly — the saga
    # dispatches, parks, and never settles, which reads as a slow stack.
    export EXERIS_PAYMENT_CALLBACK_URL="${EXERIS_PAYMENT_CALLBACK_URL:-http://${BENCH_CONTAINER_HOST_ADDR}:${_callback_port}/api/v1/payments/callback}"
    # Same address for the restate arm: under host networking the ingress binds the
    # host's loopback, so the gateway reaches it at 127.0.0.1:8080 (on the bridge this
    # had to be the compose service name instead).
    export EXERIS_RESTATE_INGRESS_CALLBACK_URL="${EXERIS_RESTATE_INGRESS_CALLBACK_URL:-http://${BENCH_CONTAINER_HOST_ADDR}:8080}"
    # The stub speaks plaintext HTTP/1.1 only. Under a TLS protocol mode the callback
    # would be dispatched to a port that answers TLS, every settle would fail, and
    # every saga would strand — so refuse the run instead of producing a directory
    # full of unresolved sagas that looks like a target problem.
    case "${declared_protocol_mode:-h1}" in
      h1|h2c) ;;
      *)
        echo "ERROR: BENCH_PAYMENT_PARKING=1 with protocol mode '${declared_protocol_mode}'." >&2
        echo "ERROR: the payment gateway stub speaks plaintext HTTP/1.1 only; every callback" >&2
        echo "ERROR: would fail against a TLS port and every saga would park forever." >&2
        echo "ERROR: Set EXERIS_PAYMENT_CALLBACK_URL to a reachable plaintext endpoint to override." >&2
        exit 75
        ;;
    esac
  fi
  echo "Runtime overrides: graph_backend=${EXERIS_GRAPH_BACKEND_TYPE} protocol=${declared_protocol_mode} http_max=${EXERIS_HTTP_MAX_VERSION} h2c_upgrade=${EXERIS_HTTP_H2C_UPGRADE_ENABLED} http2=${EXERIS_HTTP2_ENABLED} ssl=${EXERIS_SSL_ENABLED} fault_mode=${FAULT_MODE}"
}

wait_for_compose_service_health() {
  local compose_file="$1"
  local service="$2"
  local required="$3"
  local container_id status deadline elapsed last_print=0

  container_id="$(docker compose -f "$compose_file" ps -q "$service" 2>/dev/null || true)"
  if [[ -z "$container_id" ]]; then
    if [[ "$required" == "true" ]]; then
      echo "Warning: could not resolve container id for required service '$service' from compose file '$compose_file'." >&2
      return 1
    fi
    echo "Warning: could not resolve container id for optional service '$service' from compose file '$compose_file'." >&2
    return 0
  fi

  echo "Waiting for service '$service' to become healthy (timeout: ${HEALTH_TIMEOUT_SECONDS}s)..."
  deadline="$((SECONDS + HEALTH_TIMEOUT_SECONDS))"
  while (( SECONDS < deadline )); do
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id" 2>/dev/null || true)"
    if [[ "$status" == "healthy" ]]; then
      elapsed="$((SECONDS - (deadline - HEALTH_TIMEOUT_SECONDS)))"
      echo "  $service healthy after ${elapsed}s."
      return 0
    fi
    if (( SECONDS - last_print >= 5 )); then
      elapsed="$((SECONDS - (deadline - HEALTH_TIMEOUT_SECONDS)))"
      printf '  %s: %s (%ds elapsed, %ds remaining)\n' \
        "$service" "${status:-unknown}" "$elapsed" "$((deadline - SECONDS))"
      last_print="$SECONDS"
    fi
    sleep 1
  done

  status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id" 2>/dev/null || true)"
  if [[ "$required" == "true" ]]; then
    echo "Warning: required service '$service' did not become healthy within ${HEALTH_TIMEOUT_SECONDS}s (status: ${status:-unknown})." >&2
    return 1
  fi

  echo "Warning: optional service '$service' did not become healthy within ${HEALTH_TIMEOUT_SECONDS}s (status: ${status:-unknown}); continuing." >&2
  return 0
}

ensure_benchmark_infra() {
  if [[ "$AUTO_START_INFRA" != "true" ]]; then
    return 0
  fi

  if ! command -v docker >/dev/null 2>&1; then
    echo "Warning: docker is unavailable; cannot auto-start benchmark infra." >&2
    return 0
  fi

  if ! _ensure_docker_daemon; then
    echo "ERROR: Docker daemon is not available; cannot start benchmark infra." >&2
    return 1
  fi

  if [[ ! -f "$BENCHMARK_COMPOSE_FILE" ]]; then
    echo "Warning: compose file not found at '$BENCHMARK_COMPOSE_FILE'; cannot auto-start benchmark infra." >&2
    return 0
  fi

  if [[ "$GRAPH_TRACK" == "neo4j" ]]; then
    echo "Auto-starting benchmark infra: benchmark-postgres, benchmark-neo4j (graph_track=neo4j)"
    if ! docker compose "${BENCHMARK_COMPOSE_UP_ARGS[@]}" up -d benchmark-postgres benchmark-neo4j; then
      echo "Warning: docker compose failed to start benchmark infra services; checking health anyway." >&2
    fi
    wait_for_compose_service_health "$BENCHMARK_COMPOSE_FILE" "benchmark-postgres" "true"
    wait_for_compose_service_health "$BENCHMARK_COMPOSE_FILE" "benchmark-neo4j" "false"
  else
    echo "Auto-starting benchmark infra: benchmark-postgres (graph_track=${GRAPH_TRACK}, Neo4j skipped)"
    if ! docker compose "${BENCHMARK_COMPOSE_UP_ARGS[@]}" up -d benchmark-postgres; then
      echo "Warning: docker compose failed to start benchmark-postgres; checking health anyway." >&2
    fi
    wait_for_compose_service_health "$BENCHMARK_COMPOSE_FILE" "benchmark-postgres" "true"
  fi

  # Postgres TCP-auth preflight. Observed twice on 2026-07-30: TCP auth for the
  # `postgres` role started failing mid-campaign with "password authentication
  # failed" while local-socket auth (trust, per pg_hba) kept working, so the
  # container looked healthy. No seed SQL touches roles and the cause is
  # unexplained; `ALTER USER postgres WITH PASSWORD` restores it immediately.
  # Repair, re-verify, and abort if it still fails — losing a rep to this is
  # avoidable, and silently seeding half a database is not acceptable.
  # The probe MUST take a password-authenticated path. An earlier version used
  # `psql -h 127.0.0.1` from inside the container, which pg_hba maps to
  # `host all all 127.0.0.1/32 trust` — no password is ever checked, so the
  # probe passed while the seed (a separate container reaching Postgres over the
  # docker network, matching `host all all all scram-sha-256`) still failed.
  # Mirror the seed's path exactly: another container, over the compose network.
  _pg_net="$(docker inspect exeris-e2e-saga-postgres \
    --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{break}}{{end}}' 2>/dev/null || true)"
  # NOTE (2026-08-19): the seed's path changed with the network mode. Under host
  # networking there is no compose DNS, so the seed container reaches Postgres at
  # 127.0.0.1 - which pg_hba maps to `trust`. This probe therefore verifies REACHABILITY
  # there, not the password; the scram path that broke on 2026-07-30 is no longer used
  # by anything in the deployment. Probing the old service-name address instead failed
  # for every run, which is how this was caught.
  _pg_auth_probe() {
    [[ -z "$_pg_net" ]] && return 0   # cannot probe; leave it to the seed's own fail-closed
    if [[ "$_pg_net" == "host" ]]; then
      docker run --rm --network host -e PGPASSWORD=postgres postgres:16.2 \
        psql -h 127.0.0.1 -U postgres -tAc 'select 1' >/dev/null 2>&1
    else
      docker run --rm --network "$_pg_net" -e PGPASSWORD=postgres postgres:16.2 \
        psql -h exeris-e2e-saga-postgres -U postgres -tAc 'select 1' >/dev/null 2>&1
    fi
  }
  if ! _pg_auth_probe; then
    echo "WARN: Postgres password auth (docker-network path, as the seed uses) is failing; resetting the role password." >&2
    docker exec exeris-e2e-saga-postgres \
      psql -U postgres -tAc "alter user postgres with password 'postgres'" >/dev/null 2>&1 || true
    if ! _pg_auth_probe; then
      echo "ERROR: Postgres password auth still failing after reset; the seed would fail and the run would be measured against an incomplete database." >&2
      exit 72
    fi
    echo "Postgres password auth repaired (role password reset to the compose-declared value)."
  fi

  echo "Running DB seed migrations (benchmark-db-seed)..."
  # `docker compose up` returns 0 even when the one-shot service container exits
  # non-zero, so the seed's own exit code has to be read back explicitly.
  # Observed 2026-07-30: psql failed with "password authentication failed", the
  # container exited 2, and the harness printed "DB seed migrations complete."
  # and carried on toward measuring against an EMPTY database.
  docker compose "${BENCHMARK_COMPOSE_UP_ARGS[@]}" up --force-recreate --no-deps benchmark-db-seed || true
  _seed_rc="$(docker inspect exeris-e2e-saga-db-seed --format '{{.State.ExitCode}}' 2>/dev/null || echo "unknown")"
  if [[ "$_seed_rc" != "0" ]]; then
    echo "ERROR: DB seed container exited ${_seed_rc}; the database is not in a known state." >&2
    echo "ERROR: refusing to continue — a run against a partially seeded or empty database produces" >&2
    echo "ERROR: results that look valid and are not. See logs above for the psql error." >&2
    exit 70
  fi
  echo "DB seed migrations complete (exit 0)."

  if [[ "$GRAPH_TRACK" == "neo4j" ]]; then
    echo "[seed] Seeding Neo4j from PostgreSQL..."
    # pipefail makes the script's status survive the tee, but the seed script is
    # itself fail-open (it printed "completed successfully" after loading 0
    # nodes from 4 failed psql calls), so the row counts are checked below too.
    "$SEED_NEO4J_SCRIPT" 2>&1 | tee "$NEO4J_SEED_LOG"
    _neo4j_products="$(grep -oE '^[[:space:]]*Product nodes:[[:space:]]*[0-9]+' "$NEO4J_SEED_LOG" 2>/dev/null | tail -1 | grep -oE '[0-9]+$' || echo 0)"
    if [[ "${_neo4j_products:-0}" -lt 1 ]]; then
      echo "ERROR: Neo4j seed loaded ${_neo4j_products:-0} Product nodes — the recommendation graph is empty." >&2
      echo "ERROR: the seed script reports success regardless of psql failures, so this is checked here." >&2
      echo "ERROR: refusing to continue; every recommendation request would hit an empty graph." >&2
      exit 71
    fi
    echo "[seed] Neo4j seed verified: ${_neo4j_products} Product nodes."
  fi

  # Name of the anonymous volume currently backing the Axon Server event store,
  # or empty when the container does not exist. Always succeeds (callers run
  # under `set -e`).
  _axon_events_volume_name() {
    docker inspect exeris-e2e-saga-axonserver \
      --format '{{range .Mounts}}{{if eq .Destination "/axonserver/events"}}{{.Name}}{{end}}{{end}}' \
      2>/dev/null || true
  }

  # spring-axon-embedded is the one arm that matches every *axon*/*spring* pattern above
  # and must NOT get an Axon Server: its whole point is a TWO-process CONTRACT-v2 s1
  # deployment unit with Axon's stores in the shared Postgres. Starting the container
  # anyway would idle ~2 GB next to the measurement and land in the s8 footprint rollup,
  # i.e. it would report the three-process cost under the two-process arm's name.
  if [[ "$TARGET_APP" == *axon-embedded* || "$CONTRACT_ID" == *axon_embedded* ]]; then
    echo "Axon EMBEDDED arm (contract=${CONTRACT_ID}): Axon Server is deliberately NOT started;"
    echo "  the event, token and saga stores live in Postgres via JPA (s1 unit = target JVM + Postgres)."
    # Not started is not the same as not running: the stack is shared, and an Axon Server
    # left up by the previous arm idles a ~2 GB JVM on the backend cores this run is pinned
    # against. Stop it, so the deployment on the box matches the deployment in the metadata.
    if [[ -n "$(docker ps -q -f name=exeris-e2e-saga-axonserver)" ]]; then
      echo "  stopping a leftover exeris-e2e-saga-axonserver so it does not run beside this arm."
      docker stop exeris-e2e-saga-axonserver >/dev/null 2>&1 || true
    fi
  elif [[ "$CONTRACT_ID" == *axon* || "$TARGET_APP" == *axon* || "$TARGET_APP" == *spring* || "$TARGET_APP" == *quarkus* ]]; then
    echo "Axon target detected (contract=${CONTRACT_ID}); starting benchmark-axonserver."
    # Fresh event store per rep. `rm -f` WITHOUT `-s` silently skips a RUNNING
    # container ("No stopped containers") — the anonymous volumes the image
    # declares (/axonserver/data, /axonserver/events, ...) then survive and
    # `up --force-recreate` re-attaches them, so the event store carries over
    # between reps. Because CONTRACT-v2 s3 issues the SAME deterministic
    # orderId set every run and spring-hibernate uses that orderId as its
    # aggregate identifier, the carried-over store rejects every re-created
    # aggregate with AXONIQ-2000 "Invalid sequence number 0" and the rep is
    # worthless. `-s` (stop first) is what the restate block below already
    # does; the two must not diverge.
    _axon_events_vol_before="$(_axon_events_volume_name)"
    docker compose -f "$BENCHMARK_COMPOSE_FILE" rm -sf --volumes benchmark-axonserver 2>/dev/null || true
    if ! docker compose "${BENCHMARK_COMPOSE_UP_ARGS[@]}" up -d --force-recreate benchmark-axonserver; then
      echo "Warning: docker compose failed to start benchmark-axonserver; checking health anyway." >&2
    fi
    wait_for_compose_service_health "$BENCHMARK_COMPOSE_FILE" "benchmark-axonserver" "false"

    # Assert the wipe actually happened. Checking the volume identity is
    # mechanism-independent: if /axonserver/events is the same volume as before,
    # prior events are still there no matter why. Fail closed — a silently
    # carried-over event store does not crash the run, it produces a run whose
    # saga outcomes are an artifact of the previous rep.
    _axon_events_vol_after="$(_axon_events_volume_name)"
    if [[ -n "$_axon_events_vol_before" && "$_axon_events_vol_before" == "$_axon_events_vol_after" ]]; then
      echo "ERROR: Axon Server event store was NOT reset — /axonserver/events is still volume ${_axon_events_vol_after} after rm --volumes + --force-recreate." >&2
      echo "ERROR: CONTRACT-v2 s3 reissues the same deterministic orderId set every run, so a carried-over event store makes every aggregate a duplicate (AXONIQ-2000) and the rep's saga outcomes meaningless." >&2
      exit 66
    fi
    echo "Initializing Axon Server cluster and default context..."
    for _axon_init_attempt in $(seq 1 15); do
      _axon_init_http="$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "http://localhost:8024/v2/cluster/init?initialContext=default" \
        2>/dev/null || echo "000")"
      # 200/202 = init accepted/started; 400/406 = already initialized
      if [[ "$_axon_init_http" == "200" || "$_axon_init_http" == "202" || "$_axon_init_http" == "400" || "$_axon_init_http" == "406" ]]; then
        echo "  Axon Server cluster initialized (HTTP ${_axon_init_http})."
        # 202 = async task; wait for context to be fully ready
        if [[ "$_axon_init_http" == "202" ]]; then
          sleep 3
        fi
        break
      fi
      echo "  Attempt ${_axon_init_attempt}: cluster init returned ${_axon_init_http}, retrying in 2s..."
      sleep 2
    done
    sleep 1
  fi

  if [[ "$CONTRACT_ID" == *restate* || "$TARGET_APP" == *restate* ]]; then
    echo "Restate target detected (contract=${CONTRACT_ID}); starting benchmark-restate-server."
    # Fresh journal per run (same policy as the axonserver force-recreate above):
    # stale invocation journals from a previous run must not replay into this one.
    docker compose -f "$BENCHMARK_COMPOSE_FILE" rm -sf --volumes benchmark-restate-server 2>/dev/null || true
    if ! docker compose "${BENCHMARK_COMPOSE_UP_ARGS[@]}" up -d --force-recreate benchmark-restate-server; then
      echo "Warning: docker compose failed to start benchmark-restate-server; checking health anyway." >&2
    fi
    # The restate image has no shell/wget for a container healthcheck; poll the
    # admin API from the host instead (readiness gate for the ingress as well).
    local _restate_admin_url="${RESTATE_ADMIN_URL:-http://localhost:9070}"
    local _restate_health_http="000"
    echo "Waiting for restate-server admin API at ${_restate_admin_url}/health..."
    for _restate_health_attempt in $(seq 1 30); do
      _restate_health_http="$(curl -s -o /dev/null -w "%{http_code}" \
        "${_restate_admin_url}/health" 2>/dev/null || echo "000")"
      if [[ "$_restate_health_http" == "200" ]]; then
        echo "  restate-server admin API healthy (HTTP ${_restate_health_http})."
        break
      fi
      echo "  Attempt ${_restate_health_attempt}: admin health returned ${_restate_health_http}, retrying in 2s..."
      sleep 2
    done
    if [[ "$_restate_health_http" != "200" ]]; then
      echo "Warning: restate-server admin API did not become healthy; target self-registration and ingress calls may fail." >&2
    fi
  fi
}

_BASE_URL_EXPLICIT="false"
_CONTRACT_ID_EXPLICIT="false"
BASE_URL="http://localhost:9000"
CURL_INSECURE_OPT=""
CONTRACT_ID="exeris_community_h1_v2"
TARGET_APP="exeris-community"
TARGET_APP_LOG_FILE=""
AUTO_START_INFRA="true"
START_TARGET_ON_DEMAND="true"
FORCE_RESTART_TARGET="true"
HEALTH_TIMEOUT_SECONDS="120"
START_TARGET_SCRIPT="$REPO_ROOT/runtime/drivers/start-target.sh"
STOP_TARGET_SCRIPT="$REPO_ROOT/runtime/drivers/stop-target.sh"
BENCHMARK_COMPOSE_REF="runtime/compose/e2e-shop-order-saga.yml"
BENCHMARK_COMPOSE_FILE="$REPO_ROOT/$BENCHMARK_COMPOSE_REF"
# Graph removed from this scenario 2026-07-31 (CONTRACT-v2 §2). "none" keeps Neo4j
# out of the §1 deployment unit entirely — not started, not seeded, not sampled.
# --graph-track is still accepted so the separate graph benchmark can drive it.
GRAPH_TRACK="none"
# CONTRACT-v2 s4 fault-class label: 'terminal' (deterministic per-orderId business
# decline, s4.1) or 'transient' (retryable infra fault, s4.2). MUST NOT be mixed
# within a run; headline latency/throughput claims come from terminal runs only.
FAULT_MODE="terminal"
PROFILE="dev-laptop"
K6_DOCKER_IMAGE="grafana/k6:latest"
OUTPUT_DIR=""
SKIP_SEED_VERIFY="false"
PRE_TMP=""
ENABLE_JFR="true"
JFR_SETTINGS="profile"
JFR_MAX_SIZE_MB="256"
ENABLE_PERF_STAT="false"
BENCH_CGROUP_MEMORY_LIMIT_MB="${BENCH_CGROUP_MEMORY_LIMIT_MB:-}"
BENCH_CGROUP_CPU_QUOTA_PCT="${BENCH_CGROUP_CPU_QUOTA_PCT:-}"
_BENCH_CGROUP_SCOPE_UNIT=""
K6_EXIT_CODE=0
# Defaulted next to the code it describes so `set -u` cannot trip on an exit path
# that never reaches the classifier (k6 not run at all, an early abort).
K6_EXIT_CLASS="clean"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)
      BASE_URL="$2"
      _BASE_URL_EXPLICIT="true"
      shift 2
      ;;
    --contract-id)
      CONTRACT_ID="$2"
      _CONTRACT_ID_EXPLICIT="true"
      shift 2
      ;;
    --target-app)
      TARGET_APP="$2"
      shift 2
      ;;
    --auto-start-infra)
      AUTO_START_INFRA="true"
      shift
      ;;
    --no-auto-start-infra)
      AUTO_START_INFRA="false"
      shift
      ;;
    --auto-start-target)
      START_TARGET_ON_DEMAND="true"
      shift
      ;;
    --no-auto-start-target)
      START_TARGET_ON_DEMAND="false"
      shift
      ;;
    --force-restart-target)
      FORCE_RESTART_TARGET="true"
      shift
      ;;
    --no-force-restart-target)
      FORCE_RESTART_TARGET="false"
      shift
      ;;
    --health-timeout-seconds)
      HEALTH_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --graph-track)
      GRAPH_TRACK="$2"
      shift 2
      ;;
    --fault-mode)
      FAULT_MODE="$2"
      shift 2
      ;;
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    --k6-docker-image)
      K6_DOCKER_IMAGE="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --skip-seed-verify)
      SKIP_SEED_VERIFY="true"
      shift
      ;;
    --enable-jfr)
      ENABLE_JFR="true"
      shift
      ;;
    --no-jfr)
      ENABLE_JFR="false"
      shift
      ;;
    --jfr-settings)
      JFR_SETTINGS="$2"
      shift 2
      ;;
    --jfr-max-size-mb)
      JFR_MAX_SIZE_MB="$2"
      shift 2
      ;;
    --enable-perf-stat)
      ENABLE_PERF_STAT="true"
      shift
      ;;
    --cgroup-memory-limit-mb)
      BENCH_CGROUP_MEMORY_LIMIT_MB="$2"
      shift 2
      ;;
    --cgroup-cpu-quota-pct)
      BENCH_CGROUP_CPU_QUOTA_PCT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$FAULT_MODE" in
  terminal|transient) ;;
  *)
    echo "ERROR: --fault-mode must be 'terminal' or 'transient' (got: $FAULT_MODE)" >&2
    exit 1
    ;;
esac

# Restate contract-id fail-closed check: restate is not a scenario.json fixed
# contract, so the runner cannot derive a restate contract id — and the default
# (exeris_community_h1_v2) is an exeris contract while the restate facade is a
# HTTP/1.1. Stamping the h2c default onto a restate run would mislabel every
# artifact (protocol axis + contract id), so abort instead of defaulting.
if [[ "$TARGET_APP" == *restate* || "$CONTRACT_ID" == *restate* ]]; then
  if [[ "$_CONTRACT_ID_EXPLICIT" != "true" ]]; then
    echo "ERROR: restate run detected (target_app=${TARGET_APP}) but --contract-id was not passed; refusing to stamp the defaulted h2c contract id '${CONTRACT_ID}' onto a restate (h1 facade) run." >&2
    echo "ERROR: pass --contract-id <restate-appropriate id> explicitly (see targets/restate-benchmark-app/README.md and CONTRACT-v2-IMPLEMENTATION.md, restate row)." >&2
    exit 1
  fi
  if [[ "$CONTRACT_ID" != *restate* ]]; then
    echo "ERROR: restate run detected (target_app=${TARGET_APP}) but --contract-id '${CONTRACT_ID}' is not a restate-appropriate id (must contain 'restate'); refusing to mislabel the run." >&2
    echo "ERROR: pass --contract-id <restate-appropriate id> explicitly (see targets/restate-benchmark-app/README.md and CONTRACT-v2-IMPLEMENTATION.md, restate row)." >&2
    exit 1
  fi
fi

# CONTRACT-v2 s8 durability-tier declaration. The value is a LABEL stamped into
# run-metadata.json / result.json / correctness-gate.json — it changes no target
# behavior. restate-server 1.7 default = replicated loglet + RocksDB WAL fsync
# per commit batch (T2 fsync node-durable); the Postgres-backed stacks persist
# saga-relevant state through Postgres at synchronous_commit=on (same T2 tier,
# Postgres-backed). Override the label (RESTATE_DURABILITY_TIER_LABEL /
# BENCH_DURABILITY_TIER_LABEL) when the actual durability configuration differs;
# cross-tier comparisons are forbidden (s8).
if [[ "$TARGET_APP" == *restate* || "$CONTRACT_ID" == *restate* ]]; then
  if [[ -n "${RESTATE_DURABILITY_TIER_LABEL:-}" ]]; then
    DURABILITY_TIER="$RESTATE_DURABILITY_TIER_LABEL"
    DURABILITY_TIER_SOURCE="env:RESTATE_DURABILITY_TIER_LABEL"
  else
    DURABILITY_TIER="T2-fsync-node-durable"
    DURABILITY_TIER_SOURCE="default:restate-server-1.7-wal-fsync"
  fi
else
  if [[ -n "${BENCH_DURABILITY_TIER_LABEL:-}" ]]; then
    DURABILITY_TIER="$BENCH_DURABILITY_TIER_LABEL"
    DURABILITY_TIER_SOURCE="env:BENCH_DURABILITY_TIER_LABEL"
  else
    DURABILITY_TIER="T2-fsync-node-durable-postgres"
    DURABILITY_TIER_SOURCE="default:postgres-synchronous-commit-on"
  fi
fi
echo "Durability tier label: ${DURABILITY_TIER} (source: ${DURABILITY_TIER_SOURCE}; label only, no behavior change)"

# Derive the path of the target process log file (fixed name from EXTERNAL_START_CMD) for failure capture.
case "${TARGET_APP:-}" in
  exeris-community|exeris-community-app|exeris-e2e-community-h2*)  TARGET_APP_LOG_FILE="/tmp/exeris-community.log"  ;;
  exeris-community-app-locality)                  TARGET_APP_LOG_FILE="/tmp/exeris-locality-8080.log"  ;;
  spring-axon-embedded|spring-axon-jpa)            TARGET_APP_LOG_FILE="/tmp/exeris-spring-axon-embedded-9014.log" ;;
  spring-on-exeris|spring-hibernate|spring-app-axon|spring-*)      TARGET_APP_LOG_FILE="/tmp/exeris-spring-9001.log"    ;;
  quarkus-hibernate|quarkus-app-axon|quarkus-*)   TARGET_APP_LOG_FILE="/tmp/exeris-quarkus-9002.log"   ;;
  restate|restate-benchmark-app|restate-*)        TARGET_APP_LOG_FILE="/tmp/exeris-restate-9004.log"   ;;
  *)                                               TARGET_APP_LOG_FILE=""                               ;;
esac

# If --base-url was not supplied, derive it from target-asset-matrix.json
if [[ "$_BASE_URL_EXPLICIT" == "false" ]]; then
  _asset_matrix="$REPO_ROOT/runtime/drivers/target-asset-matrix.json"
  if [[ -f "$_asset_matrix" ]]; then
    _derived_health_url="$(jq -r --arg id "$TARGET_APP" \
      '.targets[] | select(.target_id == $id) | .health_url' \
      "$_asset_matrix" 2>/dev/null || true)"
    if [[ -n "$_derived_health_url" && "$_derived_health_url" != "null" ]]; then
      # Fail closed when the asset matrix and the target's own env file disagree
      # about where the target listens. The matrix drives BASE_URL and the
      # readiness poll; the env file drives the actual bind port. A stale matrix
      # entry does not merely time out — if another target of the same family is
      # up on the matrix port (spring-hibernate 9001 vs spring-on-exeris 9004,
      # which share a port range by design), readiness passes against the WRONG
      # APPLICATION and k6 silently benchmarks it under this target's label.
      # That is a mislabeled result, which is worse than a failed run.
      _env_file_ref="$(jq -r --arg id "$TARGET_APP" \
        '.targets[] | select(.target_id == $id) | .env_file // empty' \
        "$_asset_matrix" 2>/dev/null || true)"
      if [[ -n "$_env_file_ref" && -f "$REPO_ROOT/$_env_file_ref" ]]; then
        _env_health_url="$(sed -n 's/^[[:space:]]*HEALTH_URL=//p' "$REPO_ROOT/$_env_file_ref" | tail -1 | tr -d '"'"'"'' | tr -d '\r')"
        # Only compare literals — an env value carrying a shell expansion is
        # resolved at launch time and cannot be checked here.
        if [[ -n "$_env_health_url" && "$_env_health_url" != *'$'* \
              && "$_env_health_url" != "$_derived_health_url" ]]; then
          echo "ERROR: health-endpoint disagreement for target '${TARGET_APP}'." >&2
          echo "ERROR:   runtime/drivers/target-asset-matrix.json : ${_derived_health_url}" >&2
          echo "ERROR:   ${_env_file_ref} : ${_env_health_url}" >&2
          echo "ERROR: the matrix drives BASE_URL and the readiness poll while the env file drives the actual bind port." >&2
          echo "ERROR: proceeding risks benchmarking a DIFFERENT target that happens to hold the matrix port, and labelling the result '${TARGET_APP}'. Reconcile the two before running." >&2
          exit 78
        fi
      fi
      BASE_URL="${_derived_health_url%/health}"
      echo "BASE_URL derived from asset matrix for target '${TARGET_APP}': ${BASE_URL}"
    fi
  fi
fi

# CONTRACT-v2 §4 parking-workload knobs. Defaulted HERE, before
# configure_target_runtime_overrides, because that function exports the targets'
# payment gateway and callback URLs and needs both. (The gateway's docker-stats
# sampler further down consumes them too.)
BENCH_PAYMENT_PARKING="${BENCH_PAYMENT_PARKING:-0}"
# How a container addresses the host. 127.0.0.1 since the stack went host-networked
# (2026-08-19); host.docker.internal is the value to set if it is ever moved back onto
# the docker bridge. Used for the gateway callback, the restate ingress callback and the
# restate SDK advertised URL - the three addresses whose failure mode is a saga that
# parks and never settles.
export BENCH_CONTAINER_HOST_ADDR="${BENCH_CONTAINER_HOST_ADDR:-127.0.0.1}"
# Sets parked concurrency (parked ≈ arrival rate × delay). CONTRACT-v2 §2.1 pins
# it per workload shape — ~1 ms for shape A, 100 ms for shape B, harness-controlled
# for shape C — and it MUST be identical across stacks within a run, so it is both
# stamped into run metadata and verified against the running gateway before load.
PAYMENT_STUB_DELAY_MS="${PAYMENT_STUB_DELAY_MS:-100}"

# ...and the contract id has to AGREE with it. The comment above already stated the
# §2.1 mapping; nothing enforced it, and the whole roster ran a 100 ms gateway under
# `park1` ids -- shape B's workload wearing shape A's name -- from the introduction of
# parking until 2026-08-19. It survived because the two facts lived in different files:
# the delay defaults here, the shape lives in the contract id, and the existing check
# below only compares the declared delay against the RUNNING GATEWAY. A stack can be
# perfectly self-consistent and still be measuring a different workload than it claims.
#
# This is not a cosmetic mismatch. §2.1 gives shape A "the only shape in which saga
# latency is a legitimate headline" and shape B "latency is dominated by the gateway
# delay... report it only alongside the delay" -- so the wrong label grants permission
# to headline a number that is mostly a constant.
case "$CONTRACT_ID" in
  *_park1_v3)   _expected_delay_ms=1 ;;
  *_park100_v3) _expected_delay_ms=100 ;;
  *)            _expected_delay_ms="" ;;   # shape C / non-parking ids: harness-controlled
esac
if [[ -n "$_expected_delay_ms" && "$PAYMENT_STUB_DELAY_MS" != "$_expected_delay_ms" ]]; then
  echo "ERROR: workload-shape mismatch (CONTRACT-v2 §2.1)." >&2
  echo "ERROR:   contract id '${CONTRACT_ID}' declares a ${_expected_delay_ms} ms payment-gateway park," >&2
  echo "ERROR:   but this run is configured for ${PAYMENT_STUB_DELAY_MS} ms." >&2
  echo "ERROR: §2.1 shapes carry their own contract ids and workload_profile_key and MUST NEVER" >&2
  echo "ERROR: be aggregated, so a run may not be recorded under a shape it did not execute." >&2
  echo "ERROR: Either set PAYMENT_STUB_DELAY_MS=${_expected_delay_ms}, or pass the contract id for" >&2
  echo "ERROR: the shape you actually intend to run." >&2
  exit 64
fi

configure_target_runtime_overrides
# Pick a free port if the configured target port is busy.
_configured_port="$(bench_extract_port_from_url "$BASE_URL")"
if [[ -n "$_configured_port" && "$_configured_port" =~ ^[0-9]+$ ]]; then
  _free_port="$(_pick_free_port "$_configured_port")"
  if [[ "$_free_port" != "$_configured_port" ]]; then
    echo "Port ${_configured_port} is occupied; reassigning target to free port ${_free_port}."
    BASE_URL="${BASE_URL%:${_configured_port}}:${_free_port}"
    export EXERIS_PORT="$_free_port"
    export SPRING_SERVER_PORT="$_free_port"
    export SERVER_PORT="$_free_port"
    # Keep Quarkus h2 plain-HTTP port consistent with the new SSL port.
    if [[ "${EXERIS_HTTP_PORT:-}" == "$(( 10#${_configured_port} + 10000 ))" ]]; then
      export EXERIS_HTTP_PORT="$(( 10#${_free_port} + 10000 ))"
    else
      export EXERIS_HTTP_PORT="$_free_port"
    fi
  fi
fi
[[ "${BASE_URL:-}" == https://* ]] && CURL_INSECURE_OPT="-k" || CURL_INSECURE_OPT=""

require_cmd jq
require_cmd curl
require_cmd git
require_cmd java

SCENARIO_DIR="$REPO_ROOT/scenarios/e2e-shop-order-saga"
K6_SCRIPT="$SCENARIO_DIR/k6.js"
K6_ENV_FILE="$SCENARIO_DIR/k6.env"
if [[ "${TARGET_APP:-}" == "exeris-community-app-locality" ]]; then
  K6_ENV_FILE="$SCENARIO_DIR/k6-locality.env"
fi
SCENARIO_JSON="$SCENARIO_DIR/scenario.json"
SEED_NEO4J_SCRIPT="$SCENARIO_DIR/seed/seed-neo4j-from-postgres.sh"
SEED_MANIFEST_REF=""
SEED_MANIFEST_VERSION=""
SEED_MANIFEST_PATH=""
SEED_MANIFEST_ID="unknown"
SEED_VERIFY_SCRIPT_REF=""
SEED_VERIFY_SCRIPT=""
SEED_APPLY_SCRIPT_REF="runtime/db/seed/seed-apply.sh"
SEED_APPLY_SCRIPT="$REPO_ROOT/runtime/db/seed/seed-apply.sh"
CAPTURE_ENV_SCRIPT="$REPO_ROOT/scripts/capture-env.sh"

require_file "$K6_SCRIPT"
require_file "$K6_ENV_FILE"
require_file "$SCENARIO_JSON"

SEED_MANIFEST_REF="$(jq -r --arg cid "$CONTRACT_ID" '
  .fixed_contracts[$cid].seed_manifest_refs.manifest_ref
  // .seed.manifest_ref
  // "scenarios/e2e-shop-order-saga/seed/seed-manifest.json"' "$SCENARIO_JSON" 2>/dev/null || true)"
if [[ -z "$SEED_MANIFEST_REF" || "$SEED_MANIFEST_REF" == "null" ]]; then
  SEED_MANIFEST_REF="scenarios/e2e-shop-order-saga/seed/seed-manifest.json"
fi

SEED_MANIFEST_VERSION="$(jq -r --arg cid "$CONTRACT_ID" '
  .fixed_contracts[$cid].seed_manifest_refs.manifest_version
  // .seed.manifest_version
  // "1"' "$SCENARIO_JSON" 2>/dev/null || true)"
if [[ -z "$SEED_MANIFEST_VERSION" || "$SEED_MANIFEST_VERSION" == "null" ]]; then
  SEED_MANIFEST_VERSION="1"
fi

SEED_VERIFY_SCRIPT_REF="$(jq -r --arg cid "$CONTRACT_ID" '
  .fixed_contracts[$cid].seed_manifest_refs.verification_script
  // .seed.verification_script
  // "scenarios/e2e-shop-order-saga/seed/verify-seed.sh"' "$SCENARIO_JSON" 2>/dev/null || true)"
if [[ -z "$SEED_VERIFY_SCRIPT_REF" || "$SEED_VERIFY_SCRIPT_REF" == "null" ]]; then
  SEED_VERIFY_SCRIPT_REF="scenarios/e2e-shop-order-saga/seed/verify-seed.sh"
fi

BENCHMARK_COMPOSE_REF="$(jq -r '
  .infra.compose_ref
  // "runtime/compose/e2e-shop-order-saga.yml"' "$SCENARIO_JSON" 2>/dev/null || true)"
if [[ -z "$BENCHMARK_COMPOSE_REF" || "$BENCHMARK_COMPOSE_REF" == "null" ]]; then
  BENCHMARK_COMPOSE_REF="runtime/compose/e2e-shop-order-saga.yml"
fi

BENCHMARK_COMPOSE_FILE="$REPO_ROOT/$BENCHMARK_COMPOSE_REF"
SEED_MANIFEST_PATH="$REPO_ROOT/$SEED_MANIFEST_REF"
SEED_VERIFY_SCRIPT="$REPO_ROOT/$SEED_VERIFY_SCRIPT_REF"

# Backend container network mode (fairness gate). By default the stateful backends
# run bridged with published ports → every target↔backend packet crosses NAT, an
# asymmetric tax across stacks of differing DB-chattiness. DB_HOST_NETWORK=1 (or
# BENCH_BACKEND_NETWORK=host) layers the host-net override so backends share the
# host network with the target. The chosen mode is recorded in result.json.
# Only `up` commands use BENCHMARK_COMPOSE_UP_ARGS; rm/health/ps stay on the base
# file. The override only changes a service's network_mode — service names and the
# project are identical, so rm/health/ps resolve the same containers either way.
# (This is why the entity-read runners, which have no rm step, apply the override
# to every compose_db subcommand: there the asymmetry simply doesn't arise.)
BENCHMARK_COMPOSE_UP_ARGS=( -f "$BENCHMARK_COMPOSE_FILE" )
if [[ "${DB_HOST_NETWORK:-0}" == "1" || "${BENCH_BACKEND_NETWORK:-}" == "host" ]]; then
  BACKEND_NETWORK_MODE="host"
  _hostnet_override="$REPO_ROOT/runtime/compose/e2e-shop-order-saga.host-net.yml"
  if [[ -f "$_hostnet_override" ]]; then
    BENCHMARK_COMPOSE_UP_ARGS+=( -f "$_hostnet_override" )
  else
    echo "Warning: DB_HOST_NETWORK requested but override not found: $_hostnet_override; falling back to bridge." >&2
    BACKEND_NETWORK_MODE="bridge"
  fi
else
  BACKEND_NETWORK_MODE="bridge"
fi
echo "Backend container network mode: $BACKEND_NETWORK_MODE"

if [[ "$GRAPH_TRACK" == "neo4j" ]]; then
  require_file "$SEED_NEO4J_SCRIPT"
fi
require_file "$SEED_MANIFEST_PATH"
require_file "$SEED_APPLY_SCRIPT"
require_file "$SEED_VERIFY_SCRIPT"
require_file "$CAPTURE_ENV_SCRIPT"

SEED_MANIFEST_ID="$(jq -r '.manifest_id // .id // "unknown"' "$SEED_MANIFEST_PATH" 2>/dev/null || true)"
if [[ -z "$SEED_MANIFEST_ID" || "$SEED_MANIFEST_ID" == "null" ]]; then
  SEED_MANIFEST_ID="unknown"
fi

RUN_TIMESTAMP_UTC="$(date -u +%Y%m%dT%H%M%SZ)"
ISO_TIMESTAMP_UTC="${RUN_TIMESTAMP_UTC:0:4}-${RUN_TIMESTAMP_UTC:4:2}-${RUN_TIMESTAMP_UTC:6:2}T${RUN_TIMESTAMP_UTC:9:2}:${RUN_TIMESTAMP_UTC:11:2}:${RUN_TIMESTAMP_UTC:13:2}Z"
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$REPO_ROOT/results/raw/e2e-shop-order-saga/${RUN_TIMESTAMP_UTC}-baseline"
fi

mkdir -p "$OUTPUT_DIR"
K6_OUTPUT_JSON="$OUTPUT_DIR/k6-output.json"
K6_SUMMARY_JSON="$OUTPUT_DIR/k6-summary.json"
K6_CONSOLE_LOG="$OUTPUT_DIR/k6-console.log"
# Per-second throughput reconstruction (warmup curve). The CSV is the raw stream;
# the JSON is the aggregated series + steady-state/time-to-peak merged into result.json.
K6_TIMESERIES_CSV="$OUTPUT_DIR/k6-timeseries.csv"
K6_THROUGHPUT_SERIES_JSON="$OUTPUT_DIR/k6-throughput-series.json"
ENV_JSON="$OUTPUT_DIR/env.json"
RUN_METADATA_JSON="$OUTPUT_DIR/run-metadata.json"
NEO4J_SEED_LOG="$OUTPUT_DIR/neo4j-seed.log"
SEED_VERIFY_LOG="$OUTPUT_DIR/seed-verify.log"
RESOURCE_SAMPLES_CSV="$OUTPUT_DIR/resource-samples.csv"
RESOURCE_METRICS_JSON="$OUTPUT_DIR/resource-metrics.json"
LOGS_DIR="$OUTPUT_DIR/logs"
JFR_FILE="$OUTPUT_DIR/target-${TARGET_APP}-${RUN_TIMESTAMP_UTC}.jfr"
JFR_START_JSON="$LOGS_DIR/jfr-start.json"
JFR_START_TXT="$LOGS_DIR/jfr-start.txt"
JFR_CHECK_TXT="$LOGS_DIR/jfr-check.txt"
JFR_STOP_TXT="$LOGS_DIR/jfr-stop.txt"
JFR_METADATA_JSON="$LOGS_DIR/jfr-metadata.json"
JCMD_DIAGNOSTICS_JSON="$LOGS_DIR/jcmd-diagnostics.json"
CGROUP_LIMITS_JSON="$LOGS_DIR/cgroup-limits.json"
ENDPOINT_PREFLIGHT_TXT="$LOGS_DIR/endpoint-preflight.txt"
PERF_STAT_CSV="$LOGS_DIR/perf-stat.csv"
REGISTER_PREFLIGHT_BODY_JSON="$LOGS_DIR/register-preflight-body.json"
RECOMMEND_PREFLIGHT_BODY_JSON="$LOGS_DIR/recommend-preflight-body.json"
RECOMMEND_PREFLIGHT_STATUS_TXT="$LOGS_DIR/recommend-preflight-status.txt"
TARGET_RUNTIME_LOG="$LOGS_DIR/target-runtime.log"
CLAIM_STATUS_JSON="$OUTPUT_DIR/claim-status.json"
CORRECTNESS_GATE_JSON="$OUTPUT_DIR/correctness-gate.json"
RESULT_JSON="$OUTPUT_DIR/result.json"
RUNTIME_LOG_METADATA_JSON="$LOGS_DIR/runtime-log-metadata.json"
AXON_STATS_CSV="$LOGS_DIR/axonserver-docker-stats.csv"
AXON_STATS_PID=""
RESTATE_STATS_CSV="$LOGS_DIR/restate-server-docker-stats.csv"
RESTATE_STATS_PID=""
# CONTRACT-v2 §1/§8 whole-deployment footprint. The shared backends are part of
# every stack's deployment unit and were previously unsampled, which measured
# only where work LIVES, not what it COSTS: exeris-community runs the saga
# in-process and checkpoints flow state to Postgres (v5 tables), while the Axon
# stacks push saga progression to a separate Axon Server container. Sampling
# only the target JVM flatters whichever stack externalises the most work.
POSTGRES_STATS_CSV="$LOGS_DIR/postgres-docker-stats.csv"
POSTGRES_STATS_PID=""
# CONTRACT-v2 §4 parking workload: the external payment gateway is part of the
# deployment unit, so it is sampled like Axon Server and restate-server. Only
# started when the workload actually parks (BENCH_PAYMENT_PARKING=1).
PAYMENT_GATEWAY_STATS_CSV="$LOGS_DIR/payment-gateway-docker-stats.csv"
PAYMENT_GATEWAY_STATS_PID=""
# BENCH_PAYMENT_PARKING and PAYMENT_STUB_DELAY_MS are defaulted far earlier, before
# configure_target_runtime_overrides, because that function needs them to export the
# targets' gateway/callback URLs. Defaulting them here would have left the function
# reading an unset variable — and skipping the export silently.
NEO4J_STATS_CSV="$LOGS_DIR/neo4j-docker-stats.csv"
NEO4J_STATS_PID=""
BACKEND_IDLE_BASELINE_JSON="$LOGS_DIR/backend-idle-baseline.json"
DEPLOYMENT_FOOTPRINT_JSON="$OUTPUT_DIR/deployment-footprint.json"
# Actual Postgres backend count per run. Every stack is CONFIGURED with the same
# pool ceiling (EXERIS_DB_POOL_MAX_SIZE, default 256 -> Hikari max / Quarkus jdbc
# max / kernel pool), but configuration parity is not runtime parity: pools open
# connections on demand, so a stack may simply never reach the ceiling, and one
# that plateaus exactly AT it was capped. Without this sample the difference is
# indistinguishable, and DB config has already been the hidden variable in this
# repo more than once.
PG_CONNECTIONS_CSV="$LOGS_DIR/postgres-connections.csv"
PG_CONNECTIONS_PID=""
# OS-level sidecars (opt-in via BENCH_OS_SIDECARS=1, default OFF). pidstat gives
# per-thread %wait (C2 starvation) + context switches; mpstat gives per-CPU
# %usr/%sys/%soft/%idle (network/softirq burn). See tools/bench/lib/os-sampler.sh.
TARGET_PIDSTAT_CSV="$LOGS_DIR/target-${TARGET_APP}-pidstat.csv"
HOST_MPSTAT_CSV="$LOGS_DIR/host-mpstat.csv"
TARGET_PIDSTAT_PID=""
HOST_MPSTAT_PID=""
mkdir -p "$LOGS_DIR"
# EXIT alone is not enough: bash does not run an EXIT trap when the shell is killed
# by an UNTRAPPED signal, so Ctrl-C, a `kill` from a campaign wrapper, or a dropped
# ssh session left the per-second sampler loops running with no parent. Trapping the
# three signals explicitly, then re-exiting with the conventional 128+signo, keeps the
# exit status honest for whatever is reading it while still running cleanup.
trap cleanup_baseline EXIT
trap 'cleanup_baseline; exit 130' INT
trap 'cleanup_baseline; exit 143' TERM
trap 'cleanup_baseline; exit 129' HUP

if [[ "$AUTO_START_INFRA" == "true" ]]; then
  ensure_benchmark_infra
fi

if [[ "$SKIP_SEED_VERIFY" != "true" ]]; then
  "$SEED_VERIFY_SCRIPT" 2>&1 | tee "$SEED_VERIFY_LOG"
fi

if [[ "$FORCE_RESTART_TARGET" == "true" && -n "$START_TARGET_SCRIPT" ]]; then
  echo "Force-restarting target '$TARGET_APP' (--force-restart-target)..."
  "$START_TARGET_SCRIPT" "$TARGET_APP" || echo "Warning: start-target.sh exited non-zero; bench_ensure_target_ready will perform authoritative health wait." >&2
fi
bench_ensure_target_ready "$BASE_URL" "$CURL_INSECURE_OPT" "$HEALTH_TIMEOUT_SECONDS" "$START_TARGET_ON_DEMAND" "$START_TARGET_SCRIPT" "$TARGET_APP"

# Restate: ensure the SDK deployment is registered against the restate-server
# admin API before k6 traffic. The target self-registers at startup
# (RESTATE_AUTO_REGISTER), but that races the (force-recreated) server coming
# up — a force=true POST here is idempotent and makes registration
# deterministic post-readiness. The SDK endpoint (:9084) is already listening
# once /health answers: it binds before the facade in the target's main().
if [[ "$CONTRACT_ID" == *restate* || "$TARGET_APP" == *restate* ]]; then
  _restate_admin_url="${RESTATE_ADMIN_URL:-http://localhost:9070}"
  _restate_sdk_url="${RESTATE_SDK_ADVERTISED_URL:-http://${BENCH_CONTAINER_HOST_ADDR:-127.0.0.1}:${RESTATE_SDK_PORT:-9084}}"
  RESTATE_REGISTRATION_TXT="$LOGS_DIR/restate-registration.txt"
  _restate_reg_http="000"
  echo "Registering Restate deployment ${_restate_sdk_url} at ${_restate_admin_url}/deployments..."
  for _restate_reg_attempt in $(seq 1 15); do
    _restate_reg_http="$(curl -s -o "$RESTATE_REGISTRATION_TXT" -w "%{http_code}" \
      -X POST "${_restate_admin_url}/deployments" \
      -H 'content-type: application/json' \
      --data "{\"uri\":\"${_restate_sdk_url}\",\"force\":true}" \
      2>/dev/null || echo "000")"
    if [[ "$_restate_reg_http" == "200" || "$_restate_reg_http" == "201" ]]; then
      echo "  Restate deployment registered (HTTP ${_restate_reg_http})."
      break
    fi
    echo "  Attempt ${_restate_reg_attempt}: deployment registration returned ${_restate_reg_http}, retrying in 2s..."
    sleep 2
  done
  if [[ "$_restate_reg_http" != "200" && "$_restate_reg_http" != "201" ]]; then
    echo "ERROR: Restate deployment registration failed (last HTTP ${_restate_reg_http}); OrderSaga would be uninvokable. See $RESTATE_REGISTRATION_TXT" >&2
    exit 1
  fi
fi

DECLARED_PROTOCOL_MODE="$(bench_derive_declared_protocol_mode "$TARGET_APP")"
DECLARED_TRANSPORT_MODE="$(bench_derive_transport_mode "$DECLARED_PROTOCOL_MODE")"
bench_probe_observed_protocol_mode "$BASE_URL"
OBSERVED_PROTOCOL_MODE="$BENCH_OBSERVED_PROTOCOL_MODE"
OBSERVED_TRANSPORT_MODE="$(bench_derive_transport_mode "$OBSERVED_PROTOCOL_MODE")"
EFFECTIVE_PROTOCOL_MODE="$DECLARED_PROTOCOL_MODE"
EFFECTIVE_TRANSPORT_MODE="$DECLARED_TRANSPORT_MODE"

echo "Observed protocol pre-run: ${OBSERVED_PROTOCOL_MODE} (declared: ${DECLARED_PROTOCOL_MODE})"

PRE_TMP="$(mktemp)"
USER_SUFFIX="$(printf '%04d' "$((RANDOM % 10000))")"
PRE_USERNAME="bench_${RUN_TIMESTAMP_UTC}_${USER_SUFFIX}"
PRE_EMAIL="${PRE_USERNAME}@example.test"
jq -n --arg u "$PRE_USERNAME" --arg e "$PRE_EMAIL" --arg p "benchmark-pass-123" \
  '{username:$u,email:$e,password:$p}' > "$PRE_TMP"

REGISTER_CODE="$(curl -sS $CURL_INSECURE_OPT -o "$REGISTER_PREFLIGHT_BODY_JSON" -w '%{http_code}' \
  -X POST "$BASE_URL/api/v1/auth/register" \
  -H 'content-type: application/json' \
  --data-binary "@$PRE_TMP")"
if [[ "$REGISTER_CODE" != "200" && "$REGISTER_CODE" != "201" && "$REGISTER_CODE" != "409" ]]; then
  echo "Preflight failed: POST $BASE_URL/api/v1/auth/register returned $REGISTER_CODE" >&2
  exit 1
fi

PRE_TOKEN=""
if [[ "$REGISTER_CODE" == "200" || "$REGISTER_CODE" == "201" ]]; then
  PRE_TOKEN="$(jq -r '.token // empty' "$REGISTER_PREFLIGHT_BODY_JSON" 2>/dev/null || true)"
fi

if [[ -n "$PRE_TOKEN" ]]; then
  RECOMMEND_CODE="$(curl -sS $CURL_INSECURE_OPT \
    -o "$RECOMMEND_PREFLIGHT_BODY_JSON" \
    -w '%{http_code}' \
    -X GET "$BASE_URL/api/v1/products/recommended?limit=10" \
    -H "Authorization: Bearer $PRE_TOKEN")"
  echo "$RECOMMEND_CODE" > "$RECOMMEND_PREFLIGHT_STATUS_TXT"
  if [[ "$RECOMMEND_CODE" != "200" ]]; then
    echo "Preflight failed: GET $BASE_URL/api/v1/products/recommended returned $RECOMMEND_CODE (see $RECOMMEND_PREFLIGHT_BODY_JSON)" >&2
    exit 1
  fi
  echo "Recommendation preflight OK (status=${RECOMMEND_CODE})."
fi


# --- CONTRACT-v2 §3.1: declared terminal vocabulary + preflight ---------------
#
# The harness reads the vocabulary this stack DECLARES and never infers it. A
# stack whose declaration is absent, incomplete, or contradicted at preflight
# does not run — that is a launch failure, not a result.
#
# This exists because the alternative is what happened: the detector was blind on
# one arm, reported a clean zero, and nothing in the pipeline could tell that
# apart from "no compensations occurred".
TERMINAL_VOCABULARY_JSON="$(python3 - "$CONTRACT_ID" <<'PY'
import json, sys
cid = sys.argv[1]
j = json.load(open("scenarios/e2e-shop-order-saga/scenario.json", encoding="utf-8"))
for ns in ("fixed_contracts", "baseline_only_contracts"):
    c = j.get(ns, {}).get(cid)
    if isinstance(c, dict) and "terminal_vocabulary" in c:
        print(json.dumps(c["terminal_vocabulary"], separators=(",", ":"))); sys.exit(0)
sys.exit(3)
PY
)" || {
  echo "ERROR: contract '${CONTRACT_ID}' declares no terminal_vocabulary (CONTRACT-v2 3.1)." >&2
  echo "ERROR: the harness will not guess the terminal field or its tokens — that is the" >&2
  echo "ERROR: defect class 3.1 exists to close. Declare it in scenario.json." >&2
  exit 79
}

# Negative control (CONTRACT-v2 7). Deliberately falsifies the declaration so the
# detector cannot see COMPENSATED, and the run MUST end in detector_fault rather
# than in a compensation figure. A check never observed to fire is not evidence
# that it would.
# Two modes, because they exercise DIFFERENT guards and only one of them is the
# guard the v1 defect got past:
#
#   preflight - falsify the declaration everywhere. The 3.1 preflight must reject
#               it before the window opens. Cheap, and the earliest possible catch.
#   detector  - falsify ONLY the copy handed to k6, leaving the preflight reading
#               the true declaration. Preflight then PASSES (the stack really does
#               emit COMPENSATED) and the detector alone is blind — the v1 shape.
BENCH_NEGATIVE_CONTROL="${BENCH_NEGATIVE_CONTROL:-0}"
K6_VOCABULARY_JSON="$TERMINAL_VOCABULARY_JSON"
case "$BENCH_NEGATIVE_CONTROL" in
  1|preflight)
    TERMINAL_VOCABULARY_JSON="$(printf '%s' "$TERMINAL_VOCABULARY_JSON" | jq -c '.terminal_tokens.COMPENSATED = "__NEGATIVE_CONTROL_WRONG_TOKEN__"')"
    K6_VOCABULARY_JSON="$TERMINAL_VOCABULARY_JSON"
    echo "NEGATIVE CONTROL (preflight): declaration falsified; the 3.1 preflight MUST reject it." >&2
    ;;
  detector)
    K6_VOCABULARY_JSON="$(printf '%s' "$TERMINAL_VOCABULARY_JSON" | jq -c '.terminal_tokens.COMPENSATED = "__NEGATIVE_CONTROL_WRONG_TOKEN__"')"
    echo "NEGATIVE CONTROL (detector): only k6 copy falsified; preflight will PASS." >&2
    echo "NEGATIVE CONTROL (detector): the run MUST end detector_fault, never a compensation figure." >&2
    ;;
esac
export K6_TERMINAL_VOCABULARY="$K6_VOCABULARY_JSON"

VOCAB_FIELD="$(printf '%s' "$TERMINAL_VOCABULARY_JSON" | jq -r '.terminal_field')"
VOCAB_TOK_COMPLETED="$(printf '%s' "$TERMINAL_VOCABULARY_JSON" | jq -r '.terminal_tokens.COMPLETED')"
VOCAB_TOK_COMPENSATED="$(printf '%s' "$TERMINAL_VOCABULARY_JSON" | jq -r '.terminal_tokens.COMPENSATED')"
echo "Declared terminal vocabulary: field=${VOCAB_FIELD} completed=${VOCAB_TOK_COMPLETED} compensated=${VOCAB_TOK_COMPENSATED}"


# CONTRACT-v2 3.1 preflight (normative): before the measurement window opens, drive
# one forced-DECLINE and one forced-SUCCESS order and require the DECLARED tokens to
# appear on the DECLARED field. Failure to observe either is a launch failure.
#
# This is the check that would have caught the v1 zero-compensation defect at t=0
# instead of after a full campaign: a stack that cannot show a COMPENSATED under a
# guaranteed decline is either not compensating or not observable, and either way
# its compensation count is worthless.
#
# The two orderIds are chosen by IMPORTING tools/bench/lib/fnv1a64.py, never by
# re-implementing the rule. A fourth copy of a rule that must be identical
# everywhere is precisely the drift this contract keeps having to correct.
preflight_terminal_vocabulary() {
  local base="$1" token="$2"
  [[ -n "$token" ]] || { echo "vocabulary preflight: no auth token; skipping is NOT allowed" >&2; return 1; }

  local ids decline_id success_id
  ids="$(python3 - <<'PY'
import sys
sys.path.insert(0, "tools/bench/lib")
from fnv1a64 import decline          # the single normative implementation
d = s = None
for i in range(100000):
    oid = f"preflight-vocab-i{i}"
    if d is None and decline(oid): d = oid
    if s is None and not decline(oid): s = oid
    if d and s: break
if not (d and s):
    sys.exit(4)
print(d); print(s)
PY
)" || { echo "vocabulary preflight: could not derive probe orderIds" >&2; return 1; }
  decline_id="$(printf '%s\n' "$ids" | sed -n 1p)"
  success_id="$(printf '%s\n' "$ids" | sed -n 2p)"

  local _pid _cart _body _observed _expected _oid
  _pid="$(jq -r '.[0].id // empty' "$RECOMMEND_PREFLIGHT_BODY_JSON" 2>/dev/null || true)"
  [[ -n "$_pid" ]] || { echo "vocabulary preflight: no product id from the recommendation preflight" >&2; return 1; }

  for _case in "decline:${decline_id}:${VOCAB_TOK_COMPENSATED}" "success:${success_id}:${VOCAB_TOK_COMPLETED}"; do
    _oid="$(printf '%s' "$_case" | cut -d: -f2)"
    _expected="$(printf '%s' "$_case" | cut -d: -f3)"

    curl -sS $CURL_INSECURE_OPT -o /dev/null -X POST "$base/api/v1/cart/add" \
      -H "Authorization: Bearer $token" -H 'content-type: application/json' \
      --data-binary "$(jq -nc --arg p "$_pid" '{productId:$p,quantity:1}')" || return 1
    _cart="$(curl -sS $CURL_INSECURE_OPT -X GET "$base/api/v1/cart" \
      -H "Authorization: Bearer $token" | jq -r '.cart_id // .id // empty')"
    [[ -n "$_cart" ]] || { echo "vocabulary preflight: no cart id" >&2; return 1; }

    _body="$(curl -sS $CURL_INSECURE_OPT -X POST "$base/api/v1/orders" \
      -H "Authorization: Bearer $token" -H 'content-type: application/json' \
      --data-binary "$(jq -nc --arg o "$_oid" --arg c "$_cart" '{orderId:$o,cartId:$c,paymentMethod:"CARD"}')")"
    _observed="$(printf '%s' "$_body" | jq -r --arg f "$VOCAB_FIELD" '.[$f] // empty')"

    # Inline is the declared model, but the declaration also permits a polled
    # fallback, so a non-terminal inline answer is followed up rather than failed.
    if [[ "$_observed" != "$_expected" ]]; then
      local _n=0
      while (( _n < 30 )); do
        _observed="$(curl -sS $CURL_INSECURE_OPT -X GET "$base/api/v1/orders/${_oid}/status" \
          -H "Authorization: Bearer $token" | jq -r --arg f "$VOCAB_FIELD" '.[$f] // empty')"
        [[ "$_observed" == "$_expected" ]] && break
        _n=$((_n+1)); sleep 1
      done
    fi

    if [[ "$_observed" != "$_expected" ]]; then
      echo "ERROR: CONTRACT-v2 3.1 vocabulary preflight FAILED on the ${_case%%:*} case." >&2
      echo "ERROR:   orderId        ${_oid}" >&2
      echo "ERROR:   declared field ${VOCAB_FIELD}" >&2
      echo "ERROR:   expected token ${_expected}" >&2
      echo "ERROR:   observed       '${_observed:-<absent>}'" >&2
      echo "ERROR: the declaration in scenario.json does not describe what this stack emits." >&2
      echo "ERROR: Running anyway would produce a compensation count that cannot be trusted" >&2
      echo "ERROR: in either direction — the exact failure 3.1 exists to prevent." >&2
      return 1
    fi
    echo "  vocabulary preflight ${_case%%:*}: observed '${_observed}' on '${VOCAB_FIELD}' as declared."
  done
  return 0
}

if ! preflight_terminal_vocabulary "$BASE_URL" "$PRE_TOKEN"; then
  if [[ "$BENCH_NEGATIVE_CONTROL" == "1" || "$BENCH_NEGATIVE_CONTROL" == "preflight" ]]; then
    echo "NEGATIVE CONTROL: preflight rejected the falsified declaration, as required." >&2
    echo "NEGATIVE CONTROL: this is the expected outcome — the detector is demonstrably not blind." >&2
    exit 80
  fi
  exit 79
fi

bench_read_k6_defaults "$K6_ENV_FILE"
export BASE_URL

"$CAPTURE_ENV_SCRIPT" --profile "$PROFILE" --tool k6 > "$ENV_JSON"

TARGET_PORT="$(bench_extract_port_from_url "$BASE_URL")"
TARGET_PID="$(bench_detect_pid_for_port "$TARGET_PORT")"
printf 'epoch_ms,utime_ticks,stime_ticks,rss_kb,vmsize_kb,threads,vmhwm_kb,smaps_rss_kb,cgroup_mem_kb\n' > "$RESOURCE_SAMPLES_CSV"

# Apply OS-level cgroup limits (memory + CPU) if configured.
# Must run after TARGET_PID is known and before resource sampler starts,
# so that all cgroup_mem_kb samples are read from the correct scope.
# Soft-failure: logs warning and continues.
_apply_process_cgroup_limits "$TARGET_PID" "$CGROUP_LIMITS_JSON" || true

if [[ -n "$TARGET_PID" ]]; then
  echo "Starting resource sampler for target pid ${TARGET_PID} on port ${TARGET_PORT}."
  bench_start_resource_sampler "$TARGET_PID" "$RESOURCE_SAMPLES_CSV"
else
  echo "Warning: target pid could not be detected for base url '$BASE_URL' (port '${TARGET_PORT:-unknown}')." >&2
fi

# OS-level sidecars (opt-in). pidstat needs the target pid; mpstat is host-global.
if [[ "${BENCH_OS_SIDECARS:-0}" == "1" ]]; then
  if [[ -n "$TARGET_PID" ]]; then
    TARGET_PIDSTAT_PID="$(bench_start_pidstat_sampler "$TARGET_PID" "$TARGET_PIDSTAT_CSV" 1)"
    [[ -n "$TARGET_PIDSTAT_PID" ]] \
      && echo "pidstat sidecar started (pid ${TARGET_PIDSTAT_PID}) → $TARGET_PIDSTAT_CSV" \
      || echo "Warning: pidstat sidecar not started (pidstat missing or pid invalid)." >&2
  fi
  HOST_MPSTAT_PID="$(bench_start_mpstat_sampler "$HOST_MPSTAT_CSV" 1)"
  [[ -n "$HOST_MPSTAT_PID" ]] \
    && echo "mpstat sidecar started (pid ${HOST_MPSTAT_PID}) → $HOST_MPSTAT_CSV" \
    || echo "Warning: mpstat sidecar not started (mpstat missing — install sysstat)." >&2
fi

# Capture jcmd diagnostics and endpoint preflight immediately after PID detection
if [[ -n "$TARGET_PID" ]]; then
  bench_capture_jcmd_diagnostics "$TARGET_PID" "$LOGS_DIR" "$TARGET_APP" || true
else
  bench_capture_jcmd_diagnostics "" "$LOGS_DIR" "$TARGET_APP" || true
fi
bench_capture_endpoint_preflight_body "$BASE_URL" "$CURL_INSECURE_OPT" "$LOGS_DIR" || true

# Start JFR recording before the k6 run
JFR_RECORDING_NAME="$(printf '%s_%s' "$TARGET_APP" "$RUN_TIMESTAMP_UTC" | tr -c '[:alnum:]' '_' | sed 's/^_*//; s/_*$//')"
if [[ "$ENABLE_JFR" == "true" && -n "$TARGET_PID" ]]; then
  echo "Starting JFR recording (settings=${JFR_SETTINGS}) for target pid ${TARGET_PID}."
  bench_start_jfr_recording "$TARGET_PID" "$LOGS_DIR" "$JFR_RECORDING_NAME" "$JFR_SETTINGS" || true
elif [[ "$ENABLE_JFR" == "true" ]]; then
  echo "Warning: JFR recording skipped; target pid not detected." >&2
  bench_start_jfr_recording "" "$LOGS_DIR" "$JFR_RECORDING_NAME" "$JFR_SETTINGS" || true
fi

# Sidecar docker-stats sampler (1 Hz). Used for deployment-unit sidecars
# (Axon Server, restate-server) whose CPU/RSS is a separate container and
# therefore NOT captured by the per-process resource sampler. Sets
# _CONTAINER_STATS_SAMPLER_PID (the sampler runs as a direct child of this
# shell so the post-run kill/wait semantics are unchanged).
_CONTAINER_STATS_SAMPLER_PID=""
_start_container_stats_sampler() {
  local _stats_container="$1"
  local _stats_csv="$2"
  printf 'epoch_ms,cpu_pct,mem_usage_mb,mem_limit_mb,net_in_mb,net_out_mb,block_in_mb,block_out_mb,pids\n' > "$_stats_csv"
  (
    _mem_to_mb() {
      local v="$1"
      if [[ "$v" == *GiB ]]; then
        awk -v n="${v%GiB}" 'BEGIN{printf "%.1f\n", n*1024}'
      elif [[ "$v" == *MiB ]]; then
        echo "${v%MiB}"
      elif [[ "$v" == *kB ]]; then
        awk -v n="${v%kB}" 'BEGIN{printf "%.3f\n", n/1024}'
      else
        echo "0"
      fi
    }
    _io_to_mb() {
      local v="$1"
      if [[ "$v" == *GB ]]; then
        awk -v n="${v%GB}" 'BEGIN{printf "%.1f\n", n*1024}'
      elif [[ "$v" == *MB ]]; then
        echo "${v%MB}"
      elif [[ "$v" == *kB ]]; then
        awk -v n="${v%kB}" 'BEGIN{printf "%.3f\n", n/1024}'
      else
        echo "0"
      fi
    }
    while true; do
      _line="$(docker stats --no-stream --format '{{.CPUPerc}},{{.MemUsage}},{{.NetIO}},{{.BlockIO}},{{.PIDs}}' "$_stats_container" 2>/dev/null || true)"
      [[ -z "$_line" ]] && { sleep 1; continue; }
      # date +%s%3N is unreliable (ignores %3N width and drops leading zeros in
      # the sub-second field, corrupting the timestamp) — read s and ns in one
      # atomic call and combine arithmetically. See resource-sampler.sh.
      _epoch_s=""; _epoch_ns=""
      read -r _epoch_s _epoch_ns < <(date +'%s %N')
      [[ "$_epoch_ns" =~ ^[0-9]+$ ]] || _epoch_ns=0
      _epoch_ms=$(( _epoch_s * 1000 + 10#$_epoch_ns / 1000000 ))
      # Parse CPUPerc (strip %)
      _cpu="${_line%%,*}"; _cpu="${_cpu//%/}"
      _rest="${_line#*,}"
      # Parse MemUsage: "123MiB / 456GiB" → usage and limit in MB
      _mem_field="${_rest%%,*}"; _rest="${_rest#*,}"
      _mem_usage_raw="${_mem_field%% /*}"; _mem_limit_raw="${_mem_field##* / }"
      _mem_u="$(_mem_to_mb "$_mem_usage_raw")"
      _mem_l="$(_mem_to_mb "$_mem_limit_raw")"
      # Parse NetIO: "1.2MB / 3.4MB"
      _net_field="${_rest%%,*}"; _rest="${_rest#*,}"
      _net_in_raw="${_net_field%% /*}"; _net_out_raw="${_net_field##* / }"
      _net_in="$(_io_to_mb "$_net_in_raw")"
      _net_out="$(_io_to_mb "$_net_out_raw")"
      # Parse BlockIO: "1.2MB / 3.4MB"
      _blk_field="${_rest%%,*}"; _pids="${_rest##*,}"
      _blk_in_raw="${_blk_field%% /*}"; _blk_out_raw="${_blk_field##* / }"
      _blk_in="$(_io_to_mb "$_blk_in_raw")"
      _blk_out="$(_io_to_mb "$_blk_out_raw")"
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$_epoch_ms" "$_cpu" "$_mem_u" "$_mem_l" "$_net_in" "$_net_out" "$_blk_in" "$_blk_out" "$_pids" >> "$_stats_csv"
      sleep 1
    done
  ) &
  _CONTAINER_STATS_SAMPLER_PID="$!"
}

# --- Shared-backend sampling (CONTRACT-v2 §1 deployment unit) ---------------
#
# Postgres and Neo4j serve EVERY stack and are part of every deployment unit, so
# they are sampled on every run, not conditionally like axonserver/restate.
#
# Idle baseline first: Postgres RSS is dominated by fixed shared_buffers and is
# essentially identical on every stack, so a raw Σ RSS would be swamped by a
# constant and would COMPRESS the real between-stack differences. Capturing the
# pre-load value lets the rollup report both raw and delta-over-idle, and makes
# the attributable part explicit. CPU needs no such correction — a shared
# backend's CPU under load is caused by the stack's query pattern.
_capture_backend_idle_baseline() {
  local _c _cpu _mem _line
  local _json="{}"
  local _idle_containers=(exeris-e2e-saga-postgres)
  [[ "$GRAPH_TRACK" == "neo4j" ]] && _idle_containers+=(exeris-e2e-saga-neo4j)
  for _c in "${_idle_containers[@]}"; do
    _line="$(docker stats --no-stream --format '{{.CPUPerc}},{{.MemUsage}}' "$_c" 2>/dev/null || true)"
    [[ -z "$_line" ]] && continue
    _cpu="${_line%%,*}"; _cpu="${_cpu//%/}"
    _mem="${_line#*,}"; _mem="${_mem%% /*}"
    _json="$(jq -c --arg c "$_c" --arg cpu "$_cpu" --arg mem "$_mem" \
      '. + {($c): {cpu_pct_idle: ($cpu|tonumber? // null), mem_usage_idle_raw: $mem}}' <<<"$_json")"
  done
  jq -n --argjson b "$_json" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{captured_at_utc: $at, note: "Sampled after backend readiness and before load. Postgres RSS is mostly fixed shared_buffers and identical across stacks; subtract this to get the attributable part.", backends: $b}' \
    > "$BACKEND_IDLE_BASELINE_JSON"
}
_capture_backend_idle_baseline

# Postgres backend-count sampler (answers "did this stack actually get its pool?").
printf 'epoch_s,total_backends,active,idle,idle_in_txn,max_connections\n' > "$PG_CONNECTIONS_CSV"
(
  while true; do
    _pgrow="$(docker exec exeris-e2e-saga-postgres psql -U postgres -tAF, -c \
      "select count(*),
              count(*) filter (where state='active'),
              count(*) filter (where state='idle'),
              count(*) filter (where state='idle in transaction'),
              current_setting('max_connections')
       from pg_stat_activity
       where backend_type='client backend' and pid<>pg_backend_pid()" 2>/dev/null || true)"
    [[ -n "$_pgrow" ]] && printf '%s,%s\n' "$(date +%s)" "$_pgrow" >> "$PG_CONNECTIONS_CSV"
    sleep 1
  done
) &
PG_CONNECTIONS_PID="$!"

for _shared in "exeris-e2e-saga-postgres:$POSTGRES_STATS_CSV:POSTGRES" \
               "exeris-e2e-saga-neo4j:$NEO4J_STATS_CSV:NEO4J"; do
  _sc="${_shared%%:*}"; _rest_s="${_shared#*:}"; _scsv="${_rest_s%%:*}"; _svar="${_rest_s##*:}"
  if docker inspect --format '{{.Id}}' "$_sc" >/dev/null 2>&1; then
    _start_container_stats_sampler "$_sc" "$_scsv"
    printf -v "${_svar}_STATS_PID" '%s' "$_CONTAINER_STATS_SAMPLER_PID"
    echo "Shared-backend docker stats sampler started (container: ${_sc})."
  else
    echo "Warning: ${_sc} not found; its share of the deployment footprint will be missing." >&2
  fi
done

# --- Host-networking exposure audit (fail closed) -------------------------------------
#
# The stack runs with network_mode: host, so nothing publishes ports on our behalf any
# more: each service binds whatever address it was told to, and the compose file tells
# all of them 127.0.0.1. If one of those settings is wrong - or an image changes its
# default - the service binds 0.0.0.0 on a box with a public IP and no firewall this
# account can inspect. That has already happened once here (Postgres reachable from the
# internet, rogue superuser roles, 2026-07-30), and it is invisible from inside a run:
# the benchmark works perfectly either way.
#
# So the bind addresses are checked, not trusted, on every run.
_saga_stack_ports="5432 9300 8024 8124 8080 9070 9071 8090 5122 7474 7687"
if command -v ss >/dev/null 2>&1; then
  _exposed=""
  while read -r _laddr; do
    [[ -z "$_laddr" ]] && continue
    _lport="${_laddr##*:}"
    _lhost="${_laddr%:*}"
    case " $_saga_stack_ports " in *" $_lport "*) ;; *) continue ;; esac
    # Loopback wears four spellings in ss output: 127.0.0.1, [::1], the v4-mapped
    # [::ffff:127.0.0.1] that every JVM here produces on a dual-stack socket, and
    # 127.0.0.53%lo for systemd-resolved. Anything else is off-loopback.
    case "$_lhost" in
      127.*|"[::1]"|"[::ffff:127."*|localhost) ;;
      *) _exposed="${_exposed} ${_laddr}" ;;
    esac
  done < <(ss -Hltn 2>/dev/null | awk '{print $4}')
  if [[ -n "$_exposed" ]]; then
    echo "ERROR: saga stack ports are bound off-loopback:${_exposed}" >&2
    echo "ERROR: the stack is host-networked, so these are reachable from anywhere this box is." >&2
    echo "ERROR: fix the service bind address in runtime/compose/e2e-shop-order-saga.yml and" >&2
    echo "ERROR: recreate the container. Refusing to run." >&2
    exit 77
  fi
  echo "Exposure audit: all saga stack ports bound to loopback."
else
  echo "ERROR: ss is unavailable, so the host-networked stack's bind addresses cannot be" >&2
  echo "ERROR: verified. Refusing to run rather than assume they are loopback." >&2
  exit 77
fi

# --- CPU pinning for the backend containers ------------------------------------------
#
# Postgres, the payment gateway and whichever saga server this arm needs (Axon Server,
# LRA coordinator, restate-server) all run in containers and, unpinned, land on the same
# cores as the target and the load generator. On this box that is 8 physical cores for
# everything, and the effect is measurable: 50 sessions/s declared, 36.5/s delivered.
#
# Applied with `docker update` rather than in the compose file so the split lives with
# the run that declares it — the compose stack is shared with ad-hoc use, and a cpuset
# baked in there would silently constrain runs that never asked for one.
#
# Fails closed: a partially-pinned deployment is worse than an unpinned one, because the
# metadata would claim isolation the run did not have.
if [[ -n "${BENCH_BACKEND_CPUS:-}" ]]; then
  for _c in exeris-e2e-saga-postgres exeris-e2e-saga-payment-gateway             exeris-e2e-saga-axonserver exeris-e2e-saga-lra-coordinator             exeris-e2e-saga-restate-server; do
    if docker inspect -f '{{.State.Running}}' "$_c" >/dev/null 2>&1; then
      if ! docker update --cpuset-cpus "$BENCH_BACKEND_CPUS" "$_c" >/dev/null 2>&1; then
        echo "ERROR: could not pin $_c to CPUs ${BENCH_BACKEND_CPUS}." >&2
        echo "ERROR: refusing to run a partially-pinned deployment — the metadata would claim" >&2
        echo "ERROR: an isolation this run does not have." >&2
        exit 76
      fi
    fi
  done
  echo "Backend containers pinned to CPUs ${BENCH_BACKEND_CPUS}."
fi

# Payment gateway sampler (parking workload only).
PAYMENT_GATEWAY_STATS_PID=""
if [[ "$BENCH_PAYMENT_PARKING" == "1" ]]; then
  if docker inspect --format '{{.Id}}' exeris-e2e-saga-payment-gateway >/dev/null 2>&1; then
    _start_container_stats_sampler exeris-e2e-saga-payment-gateway "$PAYMENT_GATEWAY_STATS_CSV"
    PAYMENT_GATEWAY_STATS_PID="$_CONTAINER_STATS_SAMPLER_PID"
    echo "Payment-gateway docker stats sampler started."
  else
    echo "ERROR: BENCH_PAYMENT_PARKING=1 but exeris-e2e-saga-payment-gateway is not running." >&2
    echo "ERROR: every saga would dispatch to a gateway that cannot answer and park forever." >&2
    exit 73
  fi

  # The gateway's delay and fault mode are set when compose brings it up, NOT by this
  # script — so what the run STAMPS and what the gateway actually INJECTS can disagree
  # silently, and both are workload parameters. The delay sets parked concurrency; the
  # fault mode sets the §7 expected compensation count. Read them back from the running
  # process and fail closed on disagreement rather than publish metadata that describes
  # a run that did not happen.
  _gw_health="$(curl -sf --max-time 5 "${PAYMENT_GATEWAY_HEALTH_URL:-http://localhost:9300/health}" || true)"
  if [[ -z "$_gw_health" ]]; then
    echo "ERROR: payment gateway is running but /health did not answer." >&2
    exit 74
  fi
  _gw_delay="$(printf '%s' "$_gw_health" | jq -r '.delay_ms // empty')"
  _gw_fault="$(printf '%s' "$_gw_health" | jq -r '.fault_mode // empty')"
  if [[ "$_gw_delay" != "$PAYMENT_STUB_DELAY_MS" ]]; then
    echo "ERROR: gateway callback delay is ${_gw_delay} ms but the run declares ${PAYMENT_STUB_DELAY_MS} ms." >&2
    echo "ERROR: the delay sets parked concurrency (parked ~= rate x delay) and is stamped into" >&2
    echo "ERROR: run metadata. Recreate the gateway with PAYMENT_STUB_DELAY_MS=${PAYMENT_STUB_DELAY_MS}." >&2
    exit 74
  fi
  if [[ -z "$_gw_fault" ]]; then
    echo "ERROR: gateway /health reports no fault_mode — it predates PAYMENT_STUB_FAULT_MODE." >&2
    echo "ERROR: recreate the gateway container so the injected fault class is verifiable." >&2
    exit 74
  fi
  if [[ "$_gw_fault" != "$FAULT_MODE" ]]; then
    echo "ERROR: gateway fault mode is '${_gw_fault}' but the run declares '${FAULT_MODE}'." >&2
    echo "ERROR: the §4.1 decline is decided in the gateway, so its mode — not the targets'" >&2
    echo "ERROR: EXERIS_SAGA_FAULT_MODE — determines the expected compensation count (§7 O2)." >&2
    echo "ERROR: Recreate the gateway with PAYMENT_STUB_FAULT_MODE=${FAULT_MODE}." >&2
    exit 74
  fi
  echo "Payment gateway verified: delay=${_gw_delay}ms fault_mode=${_gw_fault}."
fi

# Start Axon Server docker stats sampler (if axon contract detected)
AXON_STATS_PID=""
if [[ "$TARGET_APP" == *axon-embedded* || "$CONTRACT_ID" == *axon_embedded* ]]; then
  : # no Axon Server in this arm's deployment unit; nothing to sample (see the start gate above)
elif [[ "$CONTRACT_ID" == *axon* || "$TARGET_APP" == *axon* || "$TARGET_APP" == *spring* || "$TARGET_APP" == *quarkus* ]]; then
  _axon_cid="$(docker inspect --format '{{.Id}}' exeris-e2e-saga-axonserver 2>/dev/null || true)"
  if [[ -n "$_axon_cid" ]]; then
    _start_container_stats_sampler exeris-e2e-saga-axonserver "$AXON_STATS_CSV"
    AXON_STATS_PID="$_CONTAINER_STATS_SAMPLER_PID"
    echo "Axon Server docker stats sampler started (container: exeris-e2e-saga-axonserver, pid: ${AXON_STATS_PID})."
  else
    echo "Warning: exeris-e2e-saga-axonserver container not found; Axon Server stats will not be captured." >&2
  fi
fi

# Start restate-server docker stats sampler (if restate target detected) —
# same deployment-unit attribution policy as Axon Server above.
RESTATE_STATS_PID=""
if [[ "$CONTRACT_ID" == *restate* || "$TARGET_APP" == *restate* ]]; then
  _restate_cid="$(docker inspect --format '{{.Id}}' exeris-e2e-saga-restate-server 2>/dev/null || true)"
  if [[ -n "$_restate_cid" ]]; then
    _start_container_stats_sampler exeris-e2e-saga-restate-server "$RESTATE_STATS_CSV"
    RESTATE_STATS_PID="$_CONTAINER_STATS_SAMPLER_PID"
    echo "restate-server docker stats sampler started (container: exeris-e2e-saga-restate-server, pid: ${RESTATE_STATS_PID})."
  else
    echo "Warning: exeris-e2e-saga-restate-server container not found; restate-server stats will not be captured." >&2
  fi
fi

# Start perf-stat if requested
if [[ "$ENABLE_PERF_STAT" == "true" && -n "$TARGET_PID" ]]; then
  echo "Starting perf stat for target pid ${TARGET_PID}."
  bench_start_perf_stat "$TARGET_PID" "$PERF_STAT_CSV"
fi

# Extend poll budget for Axon targets: SimpleEventBus async projection may lag under high concurrency.
if [[ "$CONTRACT_ID" == *axon* || "$TARGET_APP" == *axon* || "$TARGET_APP" == *spring* || "$TARGET_APP" == *quarkus* ]]; then
  export K6_MAX_POLL_ATTEMPTS="${K6_MAX_POLL_ATTEMPTS:-40}"
fi
# CONTRACT-v2 s8 outcome-split reporting needs p99 for saga_completed_duration /
# saga_compensated_duration (med == p50 is already in k6's default set, p(99) is
# not, and k6 only adds extra stats implicitly when a threshold references them).
# K6_* OS env reaches both the local k6 binary and the docker fallback (-e
# forwarding in tools/bench/lib/k6.sh). Caller override wins.
export K6_SUMMARY_TREND_STATS="${K6_SUMMARY_TREND_STATS:-avg,min,med,max,p(90),p(95),p(99)}"
K6_EXIT_CODE=0
set +e
bench_run_k6 "$K6_SCRIPT" "$K6_OUTPUT_JSON" "$K6_SUMMARY_JSON" "" "$K6_DOCKER_IMAGE" "$K6_TIMESERIES_CSV" \
  2>&1 | tee "$K6_CONSOLE_LOG"
K6_EXIT_CODE="${PIPESTATUS[0]}"
set -e

# Reconstruct the per-second throughput series from the CSV stream so steady-state
# throughput and time-to-peak come from the measurement window only — not a single
# average over warmup+measurement+cooldown. Never fatal: emits valid JSON regardless.
"$REPO_ROOT/tools/aggregate-k6-throughput.sh" "$K6_TIMESERIES_CSV" "$K6_THROUGHPUT_SERIES_JSON" || true
# Classify the exit code instead of assuming it. "Non-zero means thresholds" is
# wrong in the one case that matters most: a run killed from outside exits non-zero
# and has NO verdict about the target at all, yet was being written into
# claim-status.json as `threshold_failure` -- a measured statement about the stack,
# manufactured from an operator pressing Ctrl-C. One is on disk already: the campaign
# of 2026-08-19 07:32 recorded exeris-community rep 1 as a threshold failure when its
# own k6 console says "test run was aborted because k6 received a 'terminated' signal"
# 4m21s into a 15m window.
#
# 99 and 105 are pinned from evidence, not from memory of the exit-code table: 99 is
# k6's documented threshold-breach code, and 105 was observed in this k6 (v2.0.0)
# alongside exactly that abort message. Anything else stays deliberately unclassified
# rather than being folded into either bucket.
case "$K6_EXIT_CODE" in
  0)   K6_EXIT_CLASS="clean" ;;
  99)  K6_EXIT_CLASS="threshold_failure" ;;
  105) K6_EXIT_CLASS="run_aborted" ;;
  *)   K6_EXIT_CLASS="k6_exit_nonzero" ;;
esac
if [[ "$K6_EXIT_CODE" -ne 0 ]]; then
  case "$K6_EXIT_CLASS" in
    threshold_failure)
      echo "Warning: k6 exited ${K6_EXIT_CODE} -- thresholds breached. Continuing artifact collection." >&2 ;;
    run_aborted)
      echo "Warning: k6 exited ${K6_EXIT_CODE} -- the RUN WAS ABORTED (signal), not a threshold breach. This run supports no claim about the target in either direction; artifacts are collected for post-mortem only." >&2 ;;
    *)
      echo "Warning: k6 exited ${K6_EXIT_CODE} -- cause not classified. Read ${K6_CONSOLE_LOG} before drawing any conclusion from this run." >&2 ;;
  esac
fi

bench_stop_resource_sampler
bench_stop_perf_stat

# Stop OS-level sidecars (converts raw tool output to CSV; no-op if not started).
if [[ -n "$TARGET_PIDSTAT_PID" ]]; then
  bench_stop_pidstat_sampler "$TARGET_PIDSTAT_PID" "$TARGET_PIDSTAT_CSV"
  TARGET_PIDSTAT_PID=""
fi
if [[ -n "$HOST_MPSTAT_PID" ]]; then
  bench_stop_mpstat_sampler "$HOST_MPSTAT_PID" "$HOST_MPSTAT_CSV"
  HOST_MPSTAT_PID=""
fi

# Stop the container/backend samplers (same helper the EXIT trap uses).
_stop_container_samplers

# --- CONTRACT-v2 §1/§8 whole-deployment footprint rollup --------------------
#
# Σ over every process in the deployment unit, not just the target JVM. Reports
# per-component figures alongside the sum so a reader can see WHERE the cost
# sits — the whole point when one stack runs the saga in-process and another
# externalises it to Axon Server.
#
# Two deliberate asymmetries in how the numbers are formed:
#  * shared backends (Postgres, Neo4j) also report rss_delta_over_idle_mb,
#    because their raw RSS is mostly fixed allocation identical on every stack;
#    the sum of raw RSS is reported but is the WEAKER comparator.
#  * CPU is summed without correction — a shared backend's CPU under load is
#    attributable to the stack driving it.
_csv_stat() { # <csv> <col-index-1based> <mean|max>
  local f="$1" c="$2" mode="$3"
  [[ -s "$f" ]] || { printf 'null\n'; return 0; }
  awk -F, -v c="$c" -v m="$mode" 'NR>1 && $c ~ /^[0-9.]+$/ {
      n++; s+=$c; if ($c>mx) mx=$c
    } END {
      if (n==0) { print "null" } else if (m=="max") { printf "%.1f\n", mx } else { printf "%.2f\n", s/n }
    }' "$f"
}

_component_json() { # <name> <csv> <role> <sample-seconds>
  local name="$1" csv="$2" role="$3" secs="${4:-0}"
  [[ -s "$csv" ]] || return 0
  jq -n --arg n "$name" --arg role "$role" --argjson secs "${secs:-0}" \
    --argjson cpu_avg "$(_csv_stat "$csv" 2 mean)" \
    --argjson cpu_max "$(_csv_stat "$csv" 2 max)" \
    --argjson rss_avg "$(_csv_stat "$csv" 3 mean)" \
    --argjson rss_max "$(_csv_stat "$csv" 3 max)" \
    '{component:$n, role:$role, sample_span_seconds:$secs,
      cpu_pct_avg:$cpu_avg, cpu_pct_max:$cpu_max,
      rss_mb_avg:$rss_avg, rss_mb_max:$rss_max,
      cpu_core_seconds: (if $cpu_avg == null then null else (($cpu_avg/100)*$secs) end)}'
}

# Wall-clock span of a stats CSV, from the epoch_ms column.
#
# NOT the row count. An earlier version used row count as seconds on the
# assumption that the sampler ticks at 1 Hz because the loop says `sleep 1` —
# but `docker stats --no-stream` takes ~2 s itself (it samples twice to compute
# a CPU delta), so the real interval is ~3 s. Measured on a campaign CSV: 113
# rows spanning 335.7 s, i.e. 2.97 s per sample. Every container's
# cpu_core_seconds was therefore understated by ~3x, and so was the
# whole-deployment CPU per saga.
_csv_span_seconds() {
  local f="$1"
  [[ -s "$f" ]] || { printf '0\n'; return 0; }
  awk -F, 'NR==2{first=$1} END{ if (NR>2 && first>0) printf "%.1f\n", ($1-first)/1000; else print 0 }' "$f"
}

# Defined here next to its helpers, but CALLED after resource-metrics.json is
# finalized — it reads the target JVM's figures from that file, and an earlier
# call silently produced a rollup whose target component was null, i.e. a
# whole-deployment sum with the target missing from it.
_write_deployment_footprint() {
  _comp_target="$(jq -n \
    --argjson cores "$(jq -r '.avg_cores_used // null' "$RESOURCE_METRICS_JSON" 2>/dev/null || echo null)" \
    --argjson rssmax "$(jq -r 'if .peak_rss_kb then ((.peak_rss_kb/1024)*10|floor/10) else null end' "$RESOURCE_METRICS_JSON" 2>/dev/null || echo null)" \
    '{component:"target-jvm", role:"target", cores_used_avg:$cores, rss_mb_max:$rssmax}')"

  _comps="$(printf '%s\n' \
    "$(_component_json exeris-e2e-saga-postgres "$POSTGRES_STATS_CSV" shared-backend "$(_csv_span_seconds "$POSTGRES_STATS_CSV")")" \
    "$(if [[ "$GRAPH_TRACK" == "neo4j" ]]; then _component_json exeris-e2e-saga-neo4j "$NEO4J_STATS_CSV" shared-backend "$(_csv_span_seconds "$NEO4J_STATS_CSV")"; fi)" \
    "$(_component_json exeris-e2e-saga-axonserver "$AXON_STATS_CSV" stack-specific "$(_csv_span_seconds "$AXON_STATS_CSV")")" \
    "$(_component_json exeris-e2e-saga-restate-server "$RESTATE_STATS_CSV" stack-specific "$(_csv_span_seconds "$RESTATE_STATS_CSV")")" \
    "$(_component_json exeris-e2e-saga-payment-gateway "$PAYMENT_GATEWAY_STATS_CSV" shared-external "$(_csv_span_seconds "$PAYMENT_GATEWAY_STATS_CSV")")" \
    | jq -s '.')"

  # Throughput normalization. Raw cpu_pct is an average over the sampling
  # window, so it is NOT comparable between runs that served different volumes —
  # and the sweep already showed throughput varying run to run. Convert to
  # core-seconds and divide by completed iterations so the figure is per saga.
  _iters="$(jq -r '.metrics.iterations.count // 0' "$K6_SUMMARY_JSON" 2>/dev/null || echo 0)"
  _pg_peak="$(_csv_stat "$PG_CONNECTIONS_CSV" 2 max)"
  _pg_peak_active="$(_csv_stat "$PG_CONNECTIONS_CSV" 3 max)"
  _pg_server_max="$(awk -F, 'NR>1 && $6 ~ /^[0-9]+$/ {print $6; exit}' "$PG_CONNECTIONS_CSV" 2>/dev/null)"

  jq -n \
    --arg contract "$CONTRACT_ID" --arg target "$TARGET_APP" \
    --argjson target_comp "$_comp_target" \
    --argjson components "$_comps" \
    --argjson iterations "${_iters:-0}" \
    --argjson pool_max "${EXERIS_DB_POOL_MAX_SIZE:-0}" \
    --argjson pg_peak "${_pg_peak:-null}" \
    --argjson pg_peak_active "${_pg_peak_active:-null}" \
    --argjson pg_server_max "${_pg_server_max:-null}" \
    --slurpfile idle "$BACKEND_IDLE_BASELINE_JSON" \
    --arg generated_at_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      schema_version: "1",
      contract_ref: "scenarios/e2e-shop-order-saga/CONTRACT-v2.md#1",
      contract_id: $contract,
      target_app: $target,
      target: $target_comp,
      components: $components,
      iterations: $iterations,
      # Fairness evidence, not a performance metric: every stack is configured
      # with the same pool ceiling, but "configured" != "obtained". peak == the
      # configured max means the stack was pool-CAPPED and its numbers reflect
      # the pool, not the runtime; peak well below means the pool was not the
      # limiter. Without this the two are indistinguishable.
      postgres_connections: {
        pool_max_configured: $pool_max,
        peak_backends: $pg_peak,
        peak_active: $pg_peak_active,
        server_max_connections: $pg_server_max,
        pool_capped: (if ($pool_max > 0 and $pg_peak >= $pool_max) then true else false end),
        note: "client backends only, sampled at 1 Hz for the whole run (includes warmup and cooldown). NOTE: keep this string free of single quotes — the jq program is bash single-quoted, and an apostrophe here silently broke the whole rollup once."
      },
      sum_container_cpu_pct_avg: ([$components[].cpu_pct_avg // 0] | add),
      sum_container_rss_mb_max:  ([$components[].rss_mb_max  // 0] | add),
      sum_container_cpu_core_seconds: ([$components[].cpu_core_seconds // 0] | add),
      # The comparable figure: throughput-normalized, so runs that served
      # different volumes can be put side by side.
      container_cpu_core_seconds_per_iteration:
        (if $iterations > 0
         then (([$components[].cpu_core_seconds // 0] | add) / $iterations)
         else null end),
      backend_idle_baseline: ($idle[0] // null),
      interpretation: {
        why: "CONTRACT-v2 §1 makes the unit of comparison the whole deployment. exeris-community runs the saga in-process and checkpoints flow state to Postgres; the Axon stacks run saga progression in a separate Axon Server container. Target-JVM-only figures measure where the work lives, not what it costs.",
        rss_caveat: "sum_container_rss_mb_max includes Postgres, whose RSS is dominated by fixed shared_buffers and is near-identical on every stack. Summing it raw COMPRESSES real between-stack differences; use backend_idle_baseline to take the delta, and prefer CPU for shared backends.",
        cpu_note: "Container CPU is summed without correction: a shared backend'"'"'s CPU under load is attributable to the stack driving it.",
        units: "cpu_pct is docker-stats percent-of-one-core; target cores_used_avg is cores. Do not add the two without converting."
      },
      generated_at_utc: $generated_at_utc
    }' > "$DEPLOYMENT_FOOTPRINT_JSON" 2>/dev/null || echo '{"schema_version":"1","error":"footprint rollup failed"}' > "$DEPLOYMENT_FOOTPRINT_JSON"
}

# Capture JFR dump and metadata after the run
if [[ "$ENABLE_JFR" == "true" ]]; then
  if [[ -n "$TARGET_PID" ]]; then
    bench_capture_jfr_metadata "$TARGET_PID" "$LOGS_DIR" "$JFR_FILE"
  else
    jq -n '{pid: "", jcmd_available: false, check_ok: false, recording_detected: false, dump_attempted: false, dump_success: false, jfr_file: "", note: "target pid not detected"}' \
      > "$JFR_METADATA_JSON"
  fi
fi

bench_summarize_resource_samples "$RESOURCE_SAMPLES_CSV" "$RESOURCE_METRICS_JSON"
if [[ -n "$TARGET_PID" ]]; then
  bench_augment_resource_metrics_with_jvm_breakdown "$TARGET_PID" "$RESOURCE_METRICS_JSON"
else
  jq '. + {note: "target pid could not be detected"}' "$RESOURCE_METRICS_JSON" > "$RESOURCE_METRICS_JSON.tmp"
  mv "$RESOURCE_METRICS_JSON.tmp" "$RESOURCE_METRICS_JSON"
fi

# CONTRACT-v2 §1/§8 whole-deployment rollup. Must run HERE, after
# resource-metrics.json is finalized and the k6 summary exists — it reads the
# target JVM's figures from the former and the iteration count (for throughput
# normalization) from the latter.
_write_deployment_footprint

bench_collect_target_runtime_log "$TARGET_PID" "$TARGET_APP" "$TARGET_RUNTIME_LOG" || true

bench_derive_k6_protocol_mode_from_output "$K6_OUTPUT_JSON" "$BASE_URL"
K6_OBSERVED_PROTOCOL_MODE="$BENCH_K6_OBSERVED_PROTOCOL_MODE"
K6_PROTO_TAGS_CSV="$BENCH_K6_PROTO_TAGS_CSV"

bench_finalize_protocol_mode "$DECLARED_PROTOCOL_MODE" "$OBSERVED_PROTOCOL_MODE" "$K6_OBSERVED_PROTOCOL_MODE"
EFFECTIVE_PROTOCOL_MODE="$BENCH_EFFECTIVE_PROTOCOL_MODE"
EFFECTIVE_TRANSPORT_MODE="$BENCH_EFFECTIVE_TRANSPORT_MODE"

echo "Observed protocol during k6 run: ${K6_OBSERVED_PROTOCOL_MODE} (proto tags: ${K6_PROTO_TAGS_CSV})"

COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
COMPOSE_SHA256="$(file_sha256_or_unknown "$BENCHMARK_COMPOSE_FILE")"
SEED_MANIFEST_SHA256="$(file_sha256_or_unknown "$SEED_MANIFEST_PATH")"
SEED_VERIFY_SCRIPT_SHA256="$(file_sha256_or_unknown "$SEED_VERIFY_SCRIPT")"
SEED_APPLY_SCRIPT_SHA256="$(file_sha256_or_unknown "$SEED_APPLY_SCRIPT")"

# --- CONTRACT-v2 s4.1 exact compensation oracle (s7 O2-style hard assert) ---
# decline(orderId) := fnv1a64(orderId) mod 1000 < 30 over the seeded,
# deterministic orderId population, so the expected compensation count per run
# is an exact integer, not a statistical estimate. observed == expected is a
# hard pass/fail gate; a declined payment is business-terminal (compensated,
# never retried). Expected values come from tools/bench/lib/fnv1a64.py — the
# single source of truth kept in lockstep with generateOrderId() in k6.js:
#   orderId = `${K6_ORDER_SEED}-${exec.scenario.name}-i${iterationInTest}`
# iterationInTest is a dense zero-based PER-SCENARIO index, so the issued
# population is one dense 0..N-1 sequence per k6 scenario (warmup/measurement/
# cooldown); per-scenario counts are derived from the k6 NDJSON stream and the
# density assumption is checked against per-scenario completed iterations.
# Backward compat: summaries from the pre-v2 k6 script (no saga_issued_total
# counter) skip the gate with an explicit WARN instead of failing.
FNV1A64_HELPER="$REPO_ROOT/tools/bench/lib/fnv1a64.py"
GATE_STATUS="skipped"
GATE_REASON=""
GATE_EXPECTED=""
GATE_OBSERVED=""
GATE_ISSUED=""
GATE_POP_COUNTS=""
GATE_DENSITY_NOTE=""
# ids_file  = oracle ran over the exactly-issued orderId list read back from the
#             `oidx`-tagged NDJSON (no density assumption).
# regenerated = oracle ran over a dense 0..N-1 range per scenario rebuilt from
#             counts (pre-tag artifacts); guarded by the density check below.
GATE_POPULATION_SOURCE="none"
# Defaults MUST match ORDER_SEED / generateOrderId() in scenarios/e2e-shop-order-saga/k6.js.
GATE_ORDER_SEED="${K6_ORDER_SEED:-exeris-saga-v2}"
GATE_ORDER_ID_FORMAT="{seed}-{scenario}-i{index}"

GATE_ISSUED="$(jq -r '.metrics.saga_issued_total.count // empty' "$K6_SUMMARY_JSON" 2>/dev/null || true)"
GATE_OBSERVED="$(jq -r '.metrics.saga_compensated_total.count // empty' "$K6_SUMMARY_JSON" 2>/dev/null || true)"

# v2 capability marker: the driving k6 script declaring saga_issued_total is the
# only derivable distinction between a legacy pre-v2 summary (documented
# skip-with-WARN) and a v2-capable run whose gate inputs are broken (fails
# closed, status=error). Target-build v2-ness is not independently derivable
# here; the k6 script is the authority.
GATE_V2_CAPABLE="false"
if grep -q 'saga_issued_total' "$K6_SCRIPT" 2>/dev/null; then
  GATE_V2_CAPABLE="true"
fi

# k6 omits zero-sample metrics from the summary export: a missing counter under
# a v2 script (which declares saga_issued_total) means 0 issued, not "old script".
if [[ -z "$GATE_ISSUED" && -f "$K6_SUMMARY_JSON" && "$GATE_V2_CAPABLE" == "true" ]]; then
  GATE_ISSUED="0"
fi

if [[ ! -f "$K6_SUMMARY_JSON" ]]; then
  if [[ "$GATE_V2_CAPABLE" == "true" ]]; then
    GATE_STATUS="error"
    GATE_REASON="k6 summary not found for a v2-capable k6 script; gate inputs missing — failing closed (this is not the documented pre-v2 legacy-summary skip)"
  else
    GATE_REASON="k6 summary not found; correctness gate not evaluable (pre-v2 k6 script)"
  fi
elif [[ -z "$GATE_ISSUED" ]]; then
  if [[ "$GATE_V2_CAPABLE" == "true" ]]; then
    GATE_STATUS="error"
    GATE_REASON="saga_issued_total unreadable from k6 summary despite a v2-capable k6 script; failing closed"
  else
    GATE_REASON="k6 summary lacks the saga_issued_total counter (pre-CONTRACT-v2 k6 script); gate skipped"
  fi
else
  # With the v2 script present, an absent saga_compensated_total means zero
  # compensations were observed — exactly the v1 Axon defect class the gate
  # must catch — so it counts as 0, never as "skip".
  [[ -z "$GATE_OBSERVED" ]] && GATE_OBSERVED="0"

  # --- CONTRACT-v2 §7 O0: outcome accounting, PRECONDITION for O1-O3 ------------
  #
  # A lone compensation counter cannot distinguish "the system did not compensate"
  # from "the observer did not see it": both read zero. That is not hypothetical —
  # it is the v1 zero-compensation defect, a detector fault reported as a
  # measurement. A balanced set CAN distinguish them, because a blind detector
  # cannot satisfy the identity: whatever it failed to classify has to land
  # somewhere.
  #
  #   completed + compensated + unrecovered + unresolved + submit_rejected == issued
  #
  # saga_not_submitted_total is deliberately NOT in the sum: those iterations
  # aborted before issuance and never incremented saga_issued_total.
  # --- CONTRACT-v2 §2 load model: was the DECLARED arrival rate actually delivered? -----
  #
  # constant-arrival-rate drops iterations when no VU is free. k6 counts them in
  # dropped_iterations and then reports a perfectly healthy run: the gate passes, the
  # latency percentiles look fine, and the workload was simply smaller than the contract
  # says. §2 pins 50 sessions/s as normative, so a run that could not deliver it did not
  # run this contract.
  #
  # Measured 2026-08-19 on a 90 s rate check: 190 dropped against 4 313 issued (4.4%),
  # entirely during the initial ramp. Bound is 0.5% — above that the shortfall is
  # structural rather than ramp noise.
  _dropped="$(jq -r '.metrics.dropped_iterations.count // 0' "$K6_SUMMARY_JSON" 2>/dev/null || echo 0)"
  _dropped="${_dropped%%.*}"
  if [[ "${GATE_ISSUED%%.*}" -gt 0 && "$_dropped" -gt 0 ]]; then
    _drop_bp=$(( _dropped * 10000 / ${GATE_ISSUED%%.*} ))
    if [[ "$_drop_bp" -gt 50 ]]; then
      GATE_STATUS="error"
      GATE_REASON="§2 load model not delivered: k6 dropped ${_dropped} iterations against ${GATE_ISSUED} issued ($(( _drop_bp / 100 )).$(( _drop_bp % 100 ))%), above the 0.5% bound. constant-arrival-rate drops when no VU is free, so the workload actually applied was smaller than the declared 50 sessions/s. Raise K6_*_VUS_MAX / _PRE, or the arm cannot sustain the contract rate — either way this is not a run of this contract."
    fi
  fi

  _o0_count() { jq -r ".metrics.${1}.count // 0" "$K6_SUMMARY_JSON" 2>/dev/null || echo 0; }
  # k6 omits zero-sample metrics, so absence means zero — never "unknown".
  GATE_O0_COMPLETED="$(_o0_count saga_completed_total)"
  GATE_O0_COMPENSATED="$(_o0_count saga_compensated_total)"
  GATE_O0_UNRECOVERED="$(_o0_count saga_failed_unrecovered_total)"
  GATE_O0_UNRESOLVED="$(_o0_count saga_unresolved_total)"
  GATE_O0_REJECTED="$(_o0_count saga_submit_rejected_total)"
  GATE_O0_SUM=$(( ${GATE_O0_COMPLETED%%.*} + ${GATE_O0_COMPENSATED%%.*} + ${GATE_O0_UNRECOVERED%%.*}                   + ${GATE_O0_UNRESOLVED%%.*} + ${GATE_O0_REJECTED%%.*} ))
  # Capability marker, same posture as GATE_V2_CAPABLE: a k6 script predating the
  # O0 counters cannot balance, and must be recorded as not-evaluable rather than
  # accused of a detector fault it has no way to report.
  GATE_O0_CAPABLE="false"
  if grep -q 'saga_unresolved_total' "$K6_SCRIPT" 2>/dev/null; then
    GATE_O0_CAPABLE="true"
  fi

  # The identity is necessary but NOT sufficient, and seeing why matters: a detector
  # that cannot recognise a stack's COMPENSATED token classifies those sagas as
  # UNRESOLVED, and the sum still balances. O0 alone would pass while the compensation
  # count is exactly as wrong as it was in v1.
  #
  # An unresolved saga is an OBSERVATION failure, not an outcome — whatever caused it,
  # the compensation figure cannot be trusted in either direction. Bound is the same 2%
  # the k6 saga_status_resolved threshold uses, so the two agree rather than conflict.
  # The shortfall between issued and the five buckets is NOT automatically a
  # misclassification. k6 stops iterations still in flight at each phase boundary
  # (gracefulStop): they incremented saga_issued_total and were then killed before any
  # outcome. That is TRUNCATION — the load generator stopped watching — and it is a
  # different thing from a detector that cannot recognise an outcome it was shown.
  #
  # Measured 2026-08-19: a 100 s three-phase run truncated 210 of 4 611 (4.6%), which my
  # first O0 called detector_fault. Wrong verdict on a real signal, which is exactly what
  # this gate exists to prevent in the other direction. Truncation scales with phase
  # count rather than duration, so at the contract's 300/900/30 its share should be well
  # under the 1% bound below.
  # k6 counts an iteration only when it RUNS TO COMPLETION, so issued-minus-iterations is
  # the number of sessions cut off mid-flight by a phase gracefulStop. Those sessions have
  # already incremented saga_issued_total and can never reach a terminal bucket, which is
  # the mechanical way truncation happens. Reading it lets the message below report the
  # cause instead of guessing at one.
  GATE_O0_ITERATIONS="$(jq -r '.metrics.iterations.count // 0' "$K6_SUMMARY_JSON" 2>/dev/null || echo 0)"
  GATE_O0_INTERRUPTED=$(( ${GATE_ISSUED%%.*} - ${GATE_O0_ITERATIONS%%.*} ))
  [[ "$GATE_O0_INTERRUPTED" -lt 0 ]] && GATE_O0_INTERRUPTED=0
  GATE_O0_TRUNCATED=$(( ${GATE_ISSUED%%.*} - GATE_O0_SUM ))
  GATE_O0_TRUNCATED_BP=0
  if [[ "${GATE_ISSUED%%.*}" -gt 0 && "$GATE_O0_TRUNCATED" -gt 0 ]]; then
    GATE_O0_TRUNCATED_BP=$(( GATE_O0_TRUNCATED * 10000 / ${GATE_ISSUED%%.*} ))
  fi
  GATE_O0_UNRESOLVED_PCT=0   # basis points
  if [[ "${GATE_ISSUED%%.*}" -gt 0 ]]; then
    GATE_O0_UNRESOLVED_PCT=$(( ${GATE_O0_UNRESOLVED%%.*} * 10000 / ${GATE_ISSUED%%.*} ))
  fi
  # Second detector_fault condition, added after the negative control measured its own
  # margin: a fully blind detector produces unresolved ~= the decline rate, so at 3%
  # declines the run above landed at 2.29% — over the 2% bound, but only just. At a 1%
  # decline rate the same total blindness would slip UNDER it.
  #
  # Observing zero compensations where the oracle expects some is the exact v1 signature.
  # It is reported as detector_fault rather than gate FAIL deliberately: the run cannot
  # distinguish "did not compensate" from "could not see it", and saying so is honest
  # where either verdict would be a guess.
  if [[ "$GATE_O0_CAPABLE" == "true" && "${GATE_OBSERVED%%.*}" -eq 0 && -n "${GATE_EXPECTED:-}" && "${GATE_EXPECTED%%.*}" -gt 0 ]]; then
    GATE_STATUS="detector_fault"
    GATE_REASON="O0: zero compensations observed where the §4.1 oracle expects ${GATE_EXPECTED} over ${GATE_ISSUED} issued. Zero-against-nonzero is the v1 signature and cannot distinguish a stack that did not compensate from a detector that could not see it. Check this stack's declared terminal_tokens (§3.1) first."
  elif [[ "$GATE_O0_CAPABLE" == "true" && "$GATE_O0_UNRESOLVED_PCT" -gt 200 ]]; then
    GATE_STATUS="detector_fault"
    GATE_REASON="O0: ${GATE_O0_UNRESOLVED} of ${GATE_ISSUED} issued sagas ($(( GATE_O0_UNRESOLVED_PCT / 100 )).$(( GATE_O0_UNRESOLVED_PCT % 100 ))%) reached no terminal outcome the detector recognises, above the 2% bound. An unresolved saga is an observation failure, not an outcome, so the compensation count cannot be trusted in either direction. First thing to check: this stack's declared terminal_tokens (CONTRACT-v2 §3.1) against what it actually emits."
  elif [[ "$GATE_O0_CAPABLE" == "true" && "$GATE_O0_TRUNCATED" -lt 0 ]]; then
    GATE_STATUS="detector_fault"
    GATE_REASON="O0: the five terminal buckets sum to ${GATE_O0_SUM}, MORE than the ${GATE_ISSUED} issued. A saga counted twice is as wrong as one counted never, and no truncation explains it."
  elif [[ "$GATE_O0_CAPABLE" == "true" && "$GATE_O0_TRUNCATED_BP" -gt 100 ]]; then

    # The identity did not close. This is an instrument failure, NOT a result: it

    # supports no correctness claim in either direction, the same standing as

    # `error` and `skipped`. Reporting the compensation figure here is exactly the

    # mistake v1 made.

    GATE_STATUS="detector_fault"

    # Name the mechanism rather than guessing at it. The §3.1 preflight runs BEFORE the
    # measurement window and fails the run closed, so if execution reached here the
    # declared vocabulary already matched what the stack emits — pointing at §3.1 anyway
    # sends the reader to re-check the one thing this run has already proved. Interrupted
    # iterations are the honest first suspect, and they are a WINDOW problem: truncation
    # scales with phase count, so short windows inflate it and the contract's 300/900/30
    # is where the 1% bound is meant to hold.
    _o0_hint="Check the phase windows first: truncation scales with phase count, not duration, so abbreviated windows inflate it."
    if [[ "$GATE_O0_INTERRUPTED" -gt 0 ]]; then
      _o0_hint="k6 completed ${GATE_O0_ITERATIONS} iterations against ${GATE_ISSUED} issued, i.e. ${GATE_O0_INTERRUPTED} session(s) were cut off mid-flight by a phase gracefulStop — that, not a vocabulary mismatch, is what put sagas in no bucket. Compare saga_completed_duration against the 30s gracefulStop BEFORE assuming short windows: measured 2026-08-19, lengthening the windows made this WORSE on an arm whose p95 saga settle time was 28.6s, because the sessions themselves outlived the stop. A settle time approaching gracefulStop is a stack finding; only if it is comfortably below one should you suspect the windows."
    fi
    GATE_REASON="O0: ${GATE_O0_TRUNCATED} of ${GATE_ISSUED} issued reached no terminal bucket ($(( GATE_O0_TRUNCATED_BP / 100 )).$(( GATE_O0_TRUNCATED_BP % 100 ))%), above the 1% truncation bound. Buckets: completed(${GATE_O0_COMPLETED}) + compensated(${GATE_O0_COMPENSATED}) + unrecovered(${GATE_O0_UNRECOVERED}) + unresolved(${GATE_O0_UNRESOLVED}) + submit_rejected(${GATE_O0_REJECTED}) = ${GATE_O0_SUM} != issued(${GATE_ISSUED}). Some issued sagas were classified into no terminal bucket, so the compensation count cannot be trusted in either direction. ${_o0_hint}"

  elif [[ "$FAULT_MODE" == "transient" ]]; then
    # s4.2 inverse assertion: transient faults must NOT produce compensations.
    GATE_EXPECTED="0"
  elif [[ "$GATE_ISSUED" == "0" ]]; then
    # VACUOUS-PASS GUARD. Arithmetically, zero issued orders means zero expected
    # declines, so observed(0) == expected(0) and the gate would report PASS —
    # certifying a run in which nothing happened. That is not hypothetical: on
    # 2026-07-30 a failed DB seed left the database empty, every session died
    # before order creation, and only the seed fail-closed checks (added in the
    # same change) stopped an empty run reaching this branch.
    #
    # A run that issues nothing is broken, not correct. Fail closed.
    GATE_STATUS="error"
    GATE_REASON="zero orders issued — the gate cannot certify a run in which no saga ran. Arithmetically 0 == 0 would PASS; that would certify an empty run. Check the seed, the target readiness and the k6 error taxonomy."
  elif ! command -v python3 >/dev/null 2>&1; then
    GATE_STATUS="error"
    GATE_REASON="python3 unavailable; expected declines not computable — failing closed on a v2-capable run"
  else
    # --- Preferred population source: the exactly-issued orderId list ---------
    #
    # k6.js tags every saga_issued_total sample with `oidx` = the per-scenario
    # iterationInTest of that issuance, so the NDJSON stream names the issued
    # population directly. Reconstructing `${seed}-${scenario}-i${oidx}` and
    # passing it via --ids-file makes the oracle exact with no density
    # assumption at all — an iteration that aborted before order creation
    # simply never contributed a sample. The count-based path below stays as
    # the fallback for artifacts produced before the tag existed, and keeps its
    # fail-closed density check.
    GATE_IDS_FILE="$LOGS_DIR/gate-issued-order-ids.txt"
    _gate_ids_ok="false"
    if [[ -s "$K6_OUTPUT_JSON" ]]; then
      # Emit one id per issuance; drop a stray CR (CRLF-contaminated streams)
      # before it silently changes the hashed orderId.
      jq -r --arg seed "$GATE_ORDER_SEED" \
        'select(.type=="Point" and .metric=="saga_issued_total")
         | (.data.tags.scenario // "") as $s
         | (.data.tags.oidx // "") as $i
         | if $s == "" or $i == "" then "__UNTAGGED__" else "\($seed)-\($s)-i\($i)" end' \
        "$K6_OUTPUT_JSON" 2>/dev/null | tr -d '\r' > "$GATE_IDS_FILE" || true

      _gate_ids_total="$(wc -l < "$GATE_IDS_FILE" | tr -d ' ')"
      _gate_ids_untagged="$(grep -c '^__UNTAGGED__$' "$GATE_IDS_FILE" 2>/dev/null || true)"
      _gate_ids_untagged="${_gate_ids_untagged:-0}"
      _gate_ids_unique="$(sort -u "$GATE_IDS_FILE" | grep -c . 2>/dev/null || true)"
      _gate_ids_unique="${_gate_ids_unique:-0}"

      if [[ "$_gate_ids_untagged" -gt 0 ]]; then
        echo "Correctness gate: ${_gate_ids_untagged}/${_gate_ids_total} saga_issued_total samples carry no oidx tag; falling back to the count-based population." >&2
      elif [[ "$_gate_ids_total" -eq 0 ]]; then
        : # no samples in the stream — let the count-based path report it
      elif [[ "$_gate_ids_total" -ne "$_gate_ids_unique" ]]; then
        # Duplicate (scenario, index) pairs cannot happen for a dense
        # per-scenario iterationInTest; treat as a corrupted/merged stream and
        # fail closed rather than silently hashing a wrong population.
        GATE_STATUS="error"
        GATE_REASON="issued orderId list has duplicates (${_gate_ids_total} samples, ${_gate_ids_unique} unique) in $(basename "$K6_OUTPUT_JSON"); population untrustworthy"
      elif [[ "$_gate_ids_total" -ne "$GATE_ISSUED" ]]; then
        GATE_STATUS="error"
        GATE_REASON="issued orderId list size (${_gate_ids_total}) != summary saga_issued_total (${GATE_ISSUED}); inconsistent k6 artifacts"
      else
        _gate_ids_ok="true"
      fi
    fi

    if [[ "$_gate_ids_ok" == "true" ]]; then
      GATE_POPULATION_SOURCE="ids_file"
      # Per-scenario breakdown is reporting metadata only here — the oracle runs
      # over the literal id list, not over a regenerated dense range. Read the
      # scenario back from the stream rather than parsing it out of the composed
      # id (the seed itself contains '-').
      GATE_POP_COUNTS="$(jq -r 'select(.type=="Point" and .metric=="saga_issued_total")
                                | .data.tags.scenario // "unknown"' \
                           "$K6_OUTPUT_JSON" 2>/dev/null | tr -d '\r' \
        | sort | uniq -c \
        | awk '{printf "%s%s=%s", (NR>1 ? "," : ""), $2, $1}')"
      GATE_EXPECTED="$(python3 "$FNV1A64_HELPER" --ids-file "$GATE_IDS_FILE" 2>&1)" || true
      if [[ ! "$GATE_EXPECTED" =~ ^[0-9]+$ ]]; then
        GATE_STATUS="error"
        GATE_REASON="fnv1a64.py --ids-file did not produce an integer (output: ${GATE_EXPECTED:-empty})"
        GATE_EXPECTED=""
      fi
    elif [[ "$GATE_STATUS" == "error" ]]; then
      : # already failed closed above
    else

    # Per-scenario issued counts and completed-iteration counts from the k6
    # NDJSON stream (--out json=). iterations > issued in any scenario means an
    # iteration aborted BEFORE order creation → the issued index set is no
    # longer dense and count-based regeneration would run the oracle over the
    # wrong id set; the exact oracle is then not computable from counts alone.
    declare -A _gate_issued_by=() _gate_iters_by=()
    if [[ -s "$K6_OUTPUT_JSON" ]]; then
      while read -r _g_cnt _g_metric _g_scen; do
        # Strip a trailing CR (CRLF-emitting jq builds / CRLF-contaminated
        # streams) — a CR inside the scenario name would silently change the
        # hashed orderIds and corrupt the exact oracle.
        _g_scen="${_g_scen%$'\r'}"
        [[ -z "${_g_cnt:-}" || -z "${_g_scen:-}" ]] && continue
        case "$_g_metric" in
          saga_issued_total) _gate_issued_by["$_g_scen"]="$_g_cnt" ;;
          iterations)        _gate_iters_by["$_g_scen"]="$_g_cnt" ;;
        esac
      done < <(jq -r 'select(.type=="Point" and (.metric=="saga_issued_total" or .metric=="iterations"))
                        | .metric + " " + (.data.tags.scenario // "unknown")' \
                 "$K6_OUTPUT_JSON" 2>/dev/null | sort | uniq -c || true)
    fi

    if [[ "${#_gate_issued_by[@]}" -eq 0 ]]; then
      GATE_STATUS="error"
      GATE_REASON="no per-scenario saga_issued_total samples in $(basename "$K6_OUTPUT_JSON"); the '${GATE_ORDER_ID_FORMAT}' population needs the scenario split; exact oracle not computable"
    else
      _gate_total_issued=0
      _gate_density_violations=""
      while IFS= read -r _g_scen; do
        [[ -z "$_g_scen" ]] && continue
        _g_issued="${_gate_issued_by[$_g_scen]:-0}"
        _g_iters="${_gate_iters_by[$_g_scen]:-0}"
        if [[ "$_g_issued" -gt 0 ]]; then
          GATE_POP_COUNTS+="${GATE_POP_COUNTS:+,}${_g_scen}=${_g_issued}"
        fi
        _gate_total_issued=$(( _gate_total_issued + _g_issued ))
        if (( _g_iters > _g_issued )); then
          _gate_density_violations+="${_gate_density_violations:+, }${_g_scen}: iterations=${_g_iters} > issued=${_g_issued}"
        elif (( _g_issued > _g_iters )); then
          GATE_DENSITY_NOTE+="${GATE_DENSITY_NOTE:+; }${_g_scen}: issued=${_g_issued} > completed iterations=${_g_iters} (post-issue interruption; index set assumed still dense)"
        fi
      done < <(printf '%s\n' "${!_gate_issued_by[@]}" "${!_gate_iters_by[@]}" | sort -u)

      if [[ -n "$_gate_density_violations" ]]; then
        GATE_STATUS="error"
        GATE_REASON="issued orderId population not regenerable: iterations aborted before order creation (${_gate_density_violations}); exact oracle needs the actual issued id list (fnv1a64.py --ids-file)"
      elif [[ "$_gate_total_issued" -ne "$GATE_ISSUED" ]]; then
        GATE_STATUS="error"
        GATE_REASON="per-scenario issued sum (${_gate_total_issued}) != summary saga_issued_total (${GATE_ISSUED}); inconsistent k6 artifacts"
      else
        GATE_POPULATION_SOURCE="regenerated"
        GATE_EXPECTED="$(python3 "$FNV1A64_HELPER" --seed "$GATE_ORDER_SEED" --counts "$GATE_POP_COUNTS" 2>&1)" || true
        if [[ ! "$GATE_EXPECTED" =~ ^[0-9]+$ ]]; then
          GATE_STATUS="error"
          GATE_REASON="fnv1a64.py did not produce an integer (output: ${GATE_EXPECTED:-empty})"
          GATE_EXPECTED=""
        fi
      fi
    fi

    fi  # end: exact ids_file path vs. count-based fallback
  fi
fi

if [[ -n "$GATE_EXPECTED" ]]; then
  if [[ "$GATE_OBSERVED" == "$GATE_EXPECTED" ]]; then
    GATE_STATUS="pass"
    GATE_REASON="observed_compensations == expected_declines (${GATE_OBSERVED}); issued=${GATE_ISSUED}${GATE_POP_COUNTS:+ (${GATE_POP_COUNTS})} seed=${GATE_ORDER_SEED} fault=${FAULT_MODE}"
  else
    GATE_STATUS="fail"
    GATE_REASON="observed_compensations=${GATE_OBSERVED} != expected_declines=${GATE_EXPECTED} (issued=${GATE_ISSUED}${GATE_POP_COUNTS:+ (${GATE_POP_COUNTS})} seed=${GATE_ORDER_SEED} fault=${FAULT_MODE}); CONTRACT-v2 s4.1 requires exact equality"
  fi
fi

case "$GATE_STATUS" in
  pass)    echo "Correctness gate PASS: ${GATE_REASON}" ;;
  fail)    echo "ERROR: correctness gate FAIL: ${GATE_REASON}" >&2 ;;
  error)   echo "ERROR: correctness gate ERROR (fails closed): ${GATE_REASON}" >&2 ;;
  skipped) echo "WARN: correctness gate SKIPPED: ${GATE_REASON}" >&2 ;;
  detector_fault) echo "ERROR: correctness gate DETECTOR_FAULT (instrument failure, not a result): ${GATE_REASON}" >&2 ;;
esac

jq -n \
  --arg status           "$GATE_STATUS" \
  --arg reason           "$GATE_REASON" \
  --arg expected         "$GATE_EXPECTED" \
  --arg observed         "$GATE_OBSERVED" \
  --arg issued           "$GATE_ISSUED" \
  --arg order_seed       "$GATE_ORDER_SEED" \
  --arg order_id_format  "$GATE_ORDER_ID_FORMAT" \
  --arg pop_counts       "$GATE_POP_COUNTS" \
  --arg pop_source       "$GATE_POPULATION_SOURCE" \
  --arg density_note     "$GATE_DENSITY_NOTE" \
  --arg fault_mode       "$FAULT_MODE" \
  --arg durability_tier  "$DURABILITY_TIER" \
  --arg durability_tier_source "$DURABILITY_TIER_SOURCE" \
  --arg generated_at_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    schema_version:   "1",
    gate_id:          "contract_v2_s4_1_exact_compensation",
    gate_name:        "observed_compensations == expected_declines",
    contract_ref:     "scenarios/e2e-shop-order-saga/CONTRACT-v2.md#4.1",
    decline_rule:     "fnv1a64(orderId) mod 1000 < 30 (unsigned, FNV-1a 64 over UTF-8 bytes)",
    fault_mode:       $fault_mode,
    durability_tier:  $durability_tier,
    durability_tier_source: $durability_tier_source,
    status:           $status,
    pass_fail:        (if $status == "pass" then "pass" elif $status == "fail" then "fail" else "not_evaluated" end),
    expected:         (if $expected == "" then null else ($expected | tonumber) end),
    observed:         (if $observed == "" then null else ($observed | tonumber) end),
    issued_orders:    (if $issued   == "" then null else ($issued   | tonumber) end),
    order_seed:       $order_seed,
    order_id_format:  $order_id_format,
    issued_by_scenario: (if $pop_counts == ""
                         then null
                         else ($pop_counts | split(",") | map(split("=") | {(.[0]): (.[1] | tonumber)}) | add)
                         end),
    density_note:     (if $density_note == "" then null else $density_note end),
    population_source: $pop_source,
    population_assumption:
      (if $pop_source == "ids_file"
       then "none: the oracle ran over the exactly-issued orderId list reconstructed from the oidx-tagged saga_issued_total samples in the k6 NDJSON stream (fnv1a64.py --ids-file). Iterations that aborted before order creation contribute no sample and are correctly absent from the population."
       else "one dense iteration-index sequence 0..N-1 per k6 scenario (exec.scenario.iterationInTest); density checked via per-scenario completed iterations vs saga_issued_total from the k6 NDJSON stream (see fnv1a64.py)"
       end),
    helper_ref:       "tools/bench/lib/fnv1a64.py",
    reason:           $reason,
    generated_at_utc: $generated_at_utc
  }' > "$CORRECTNESS_GATE_JSON"

if [[ "$GATE_STATUS" == "fail" ]]; then
  RUNNER_STATUS="compensation_mismatch"
elif [[ "$GATE_STATUS" == "detector_fault" ]]; then
  # O0 identity did not close: some issued sagas were classified into no terminal
  # bucket. Distinct from compensation_gate_error on purpose — the gate RAN and the
  # INSTRUMENT is what failed, so the run supports no correctness claim in either
  # direction. Collapsing it into `error` would relose the distinction O0 exists
  # to make.
  RUNNER_STATUS="detector_fault"
elif [[ "$GATE_STATUS" == "error" ]]; then
  # Gate not evaluable on a v2-capable run (missing k6 metrics, helper crash,
  # python3 unavailable, inconsistent artifacts) — fails closed, never silent.
  RUNNER_STATUS="compensation_gate_error"
elif [[ "$K6_EXIT_CODE" -eq 0 ]]; then
  RUNNER_STATUS="clean"
else
  # Same classification as the warning above: an aborted run and a threshold
  # breach are different claims and must not share a status.
  RUNNER_STATUS="$K6_EXIT_CLASS"
fi

jq -n \
  --arg scenario_id "e2e-shop-order-saga" \
  --arg contract_id "$CONTRACT_ID" \
  --arg target_app "$TARGET_APP" \
  --arg graph_track "$GRAPH_TRACK" \
  --arg fault_mode "$FAULT_MODE" \
  --arg durability_tier "$DURABILITY_TIER" \
  --arg durability_tier_source "$DURABILITY_TIER_SOURCE" \
  --arg correctness_gate_status "$GATE_STATUS" \
  --arg hardware_profile "$PROFILE" \
  --arg tier "community" \
  --arg benchmark_family "runtime" \
  --arg protocol_mode "$EFFECTIVE_PROTOCOL_MODE" \
  --arg transport_mode "$EFFECTIVE_TRANSPORT_MODE" \
  --arg protocol_mode_declared "$DECLARED_PROTOCOL_MODE" \
  --arg protocol_mode_observed "$OBSERVED_PROTOCOL_MODE" \
  --arg protocol_mode_observed_k6 "$K6_OBSERVED_PROTOCOL_MODE" \
  --arg protocol_tags_observed_k6 "$K6_PROTO_TAGS_CSV" \
  --arg transport_mode_declared "$DECLARED_TRANSPORT_MODE" \
  --arg transport_mode_observed "$OBSERVED_TRANSPORT_MODE" \
  --arg comparison_axis "within-tier-protocol" \
  --arg claim_scope "exploratory" \
  --arg commit_sha "$COMMIT_SHA" \
  --arg run_timestamp_utc "$RUN_TIMESTAMP_UTC" \
  --arg base_url "$BASE_URL" \
  --arg protocol_probe_endpoint "$BASE_URL/health" \
  --arg output_dir "$OUTPUT_DIR" \
  --arg env_file "env.json" \
  --arg tool "k6" \
  --arg jfr_enabled "$ENABLE_JFR" \
  --arg jfr_settings "$JFR_SETTINGS" \
  --arg jfr_max_size_mb "$JFR_MAX_SIZE_MB" \
  --arg jfr_file "$JFR_FILE" \
  --arg perf_stat_enabled "$ENABLE_PERF_STAT" \
  --arg logs_dir "$LOGS_DIR" \
  --arg compose_ref "$BENCHMARK_COMPOSE_REF" \
  --arg compose_sha256 "$COMPOSE_SHA256" \
  --arg backend_network_mode "$BACKEND_NETWORK_MODE" \
  --arg seed_baseline_apply_script_ref "$SEED_APPLY_SCRIPT_REF" \
  --arg seed_baseline_apply_script_sha256 "$SEED_APPLY_SCRIPT_SHA256" \
  --arg seed_overlay_manifest_ref "$SEED_MANIFEST_REF" \
  --arg seed_overlay_manifest_version "$SEED_MANIFEST_VERSION" \
  --arg seed_overlay_manifest_id "$SEED_MANIFEST_ID" \
  --arg seed_overlay_manifest_sha256 "$SEED_MANIFEST_SHA256" \
  --arg seed_overlay_verification_script_ref "$SEED_VERIFY_SCRIPT_REF" \
  --arg seed_overlay_verification_script_sha256 "$SEED_VERIFY_SCRIPT_SHA256" \
  --arg seed_overlay_verification_skipped "$SKIP_SEED_VERIFY" \
  --argjson k6_exit_code "$K6_EXIT_CODE" \
  --arg k6_exit_class "$K6_EXIT_CLASS" \
  --arg runner_status "$RUNNER_STATUS" \
  '{
    scenario_id: $scenario_id,
    contract_id: $contract_id,
    target_app: $target_app,
    graph_track: $graph_track,
    fault_mode: $fault_mode,
    durability_tier: $durability_tier,
    durability_tier_source: $durability_tier_source,
    hardware_profile: $hardware_profile,
    tier: $tier,
    benchmark_family: $benchmark_family,
    protocol_mode: $protocol_mode,
    transport_mode: $transport_mode,
    protocol_mode_declared: $protocol_mode_declared,
    protocol_mode_observed: $protocol_mode_observed,
    protocol_mode_observed_k6: $protocol_mode_observed_k6,
    protocol_tags_observed_k6: $protocol_tags_observed_k6,
    transport_mode_declared: $transport_mode_declared,
    transport_mode_observed: $transport_mode_observed,
    protocol_probe_non_blocking: true,
    protocol_probe_endpoint: $protocol_probe_endpoint,
    comparison_axis: $comparison_axis,
    claim_scope: $claim_scope,
    commit_sha: $commit_sha,
    run_timestamp_utc: $run_timestamp_utc,
    base_url: $base_url,
    output_dir: $output_dir,
    env_file: $env_file,
    tool: $tool,
    jfr_enabled: ($jfr_enabled == "true"),
    jfr_settings: $jfr_settings,
    jfr_file: $jfr_file,
    perf_stat_enabled: ($perf_stat_enabled == "true"),
    k6_exit_code: $k6_exit_code,
    runner_status: $runner_status,
    correctness_gate_status: $correctness_gate_status,
    logs_dir: $logs_dir,
    backend_network_mode: $backend_network_mode,
    fault_injection: {
      fault_mode: $fault_mode,
      selection: "per-orderId, deterministic, business-terminal (CONTRACT-v2 s4.1)",
      decline_rule: "fnv1a64(orderId) mod 1000 < 30 (unsigned)",
      nominal_decline_fraction: 0.03,
      transient_retry_policy: {
        max_attempts: 3,
        initial_backoff_ms: 50,
        backoff_factor: 2,
        jitter: false
      }
    },
    infra_contract: {
      compose_ref: $compose_ref,
      compose_sha256: $compose_sha256,
      backend_network_mode: $backend_network_mode,
      seed_baseline: {
        apply_script_ref: $seed_baseline_apply_script_ref,
        apply_script_sha256: $seed_baseline_apply_script_sha256
      },
      seed_overlay: {
        manifest_ref: $seed_overlay_manifest_ref,
        manifest_version: $seed_overlay_manifest_version,
        manifest_id: $seed_overlay_manifest_id,
        manifest_sha256: $seed_overlay_manifest_sha256,
        verification_script_ref: $seed_overlay_verification_script_ref,
        verification_script_sha256: $seed_overlay_verification_script_sha256,
        verification_skipped: ($seed_overlay_verification_skipped == "true")
      }
    }
  }' > "$RUN_METADATA_JSON"

# Generate claim-status.json
jq -n \
  --arg scenario_id      "e2e-shop-order-saga" \
  --arg contract_id      "$CONTRACT_ID" \
  --arg target_app       "$TARGET_APP" \
  --arg graph_track      "$GRAPH_TRACK" \
  --arg fault_mode       "$FAULT_MODE" \
  --arg hardware_profile "$PROFILE" \
  --arg claim_scope      "exploratory" \
  --arg correctness_gate_status "$GATE_STATUS" \
  --argjson k6_exit_code "$K6_EXIT_CODE" \
  --arg k6_exit_class "$K6_EXIT_CLASS" \
  '{
    schema_version:   "1",
    scenario_id:      $scenario_id,
    contract_id:      $contract_id,
    target_app:       $target_app,
    graph_track:      $graph_track,
    fault_mode:       $fault_mode,
    hardware_profile: $hardware_profile,
    claim_scope:      $claim_scope,
    correctness_gate_status: $correctness_gate_status,
    rejection_codes:  (
      (if $correctness_gate_status == "fail" then ["compensation_mismatch"] else [] end)
      + (if $correctness_gate_status == "error" then ["compensation_gate_error"] else [] end)
      + (if $hardware_profile != "perf-box-amd64" then ["non_canonical_hardware_profile"] else [] end)
      + (if $k6_exit_code != 0 then [$k6_exit_class] else [] end)
    ),
    reason: (
      if $correctness_gate_status == "fail"
      then "correctness gate failed: observed compensations != expected declines (CONTRACT-v2 s4.1); performance numbers excluded from headline tables"
      elif $correctness_gate_status == "error"
      then "correctness gate errored: CONTRACT-v2 s4.1 not evaluable on a v2-capable run (fails closed); performance numbers excluded from headline tables"
      elif $hardware_profile != "perf-box-amd64"
      then "not perf-box-amd64 hardware profile"
      elif $k6_exit_class == "run_aborted"
      then ("k6 exited with code " + ($k6_exit_code | tostring) +
            ": the run was ABORTED by a signal. This is a runner fault, not a measured threshold breach -- it supports no claim about the target in either direction.")
      elif $k6_exit_code != 0
      then ("k6 exited with code " + ($k6_exit_code | tostring) + " (" + $k6_exit_class + ")")
      else "eligible"
      end
    )
  }' > "$CLAIM_STATUS_JSON"

# Generate logs/runtime-log-metadata.json (JAR provenance)
# Primary: read actual JAR path from /proc/<pid>/cmdline of the running JVM.
# Fallback: read path hint written by start-target.sh to /tmp/exeris-bench-target.log.path.
_jar_path=""
_jar_exists="false"
_jar_sha256=""
_jar_size_bytes=""
_jar_mtime_utc=""
_jar_detection_method=""

# Strategy 1: /proc/$TARGET_PID/cmdline — argv of the running JVM, -jar argument
if [[ -n "$TARGET_PID" && -f "/proc/$TARGET_PID/cmdline" ]]; then
  _cmdline_jar="$(tr '\0' '\n' < "/proc/$TARGET_PID/cmdline" 2>/dev/null | \
    awk '/\.jar$/{print; exit}' || true)"
  if [[ -n "$_cmdline_jar" && -f "$_cmdline_jar" ]]; then
    _jar_path="$_cmdline_jar"
    _jar_detection_method="proc_cmdline"
  fi
fi

# Strategy 2: path hint written by start-target.sh (jar launcher mode only)
if [[ -z "$_jar_path" && -f "/tmp/exeris-bench-target.log.path" ]]; then
  _log_hint_path="$(cat /tmp/exeris-bench-target.log.path 2>/dev/null | tr -d '[:space:]' || true)"
  # The hint file contains the stdout log path; the JAR path is not stored separately this way.
  # Only use if it ends in .jar (future: start-target.sh could write jar path separately).
  if [[ "$_log_hint_path" == *.jar && -f "$_log_hint_path" ]]; then
    _jar_path="$_log_hint_path"
    _jar_detection_method="log_path_hint"
  fi
fi

if [[ -n "$_jar_path" && -f "$_jar_path" ]]; then
  _jar_exists="true"
  _jar_sha256="$(sha256sum "$_jar_path" 2>/dev/null | awk '{print $1}' || true)"
  _jar_size_bytes="$(stat -c '%s' "$_jar_path" 2>/dev/null || true)"
  _jar_mtime_utc="$(date -u -d "@$(stat -c '%Y' "$_jar_path" 2>/dev/null)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
fi
jq -n \
  --arg launcher_mode       "standalone-jar" \
  --arg env_file            "$ENV_JSON" \
  --arg jar_path            "${_jar_path:-}" \
  --arg jar_exists          "$_jar_exists" \
  --arg jar_sha256          "${_jar_sha256:-}" \
  --arg jar_size_bytes      "${_jar_size_bytes:-}" \
  --arg jar_mtime_utc       "${_jar_mtime_utc:-}" \
  --arg detection_method    "${_jar_detection_method:-none}" \
  '{
    launcher_mode:  $launcher_mode,
    env_file:       $env_file,
    jar_path:       (if $jar_path != "" then $jar_path else null end),
    jar_exists:     ($jar_exists == "true"),
    jar_sha256:     (if $jar_sha256     != "" then $jar_sha256              else null end),
    jar_size_bytes: (if $jar_size_bytes != "" then ($jar_size_bytes | tonumber) else null end),
    jar_mtime_utc:  (if $jar_mtime_utc  != "" then $jar_mtime_utc           else null end),
    detection_method: $detection_method
  }' > "$RUNTIME_LOG_METADATA_JSON"

# Effective core count for ops/s/core (CONTRACT-v2 s8: throughput as ops/s AND
# ops/s/core). Precedence: explicit cgroup CPU quota (effective cores) >
# resource-sampler host_logical_cpus (nproc at sample time) > env.json
# cpu.logical_threads > nproc fallback.
CORES_EFFECTIVE=""
CORES_SOURCE="unknown"
if [[ -n "$BENCH_CGROUP_CPU_QUOTA_PCT" ]]; then
  CORES_EFFECTIVE="$(awk -v p="$BENCH_CGROUP_CPU_QUOTA_PCT" 'BEGIN { printf "%.2f", p / 100 }')"
  CORES_SOURCE="cgroup_cpu_quota_pct"
fi
if [[ -z "$CORES_EFFECTIVE" ]]; then
  CORES_EFFECTIVE="$(jq -r '.host_logical_cpus // empty' "$RESOURCE_METRICS_JSON" 2>/dev/null || true)"
  [[ -n "$CORES_EFFECTIVE" ]] && CORES_SOURCE="resource_metrics_host_logical_cpus"
fi
if [[ -z "$CORES_EFFECTIVE" ]]; then
  CORES_EFFECTIVE="$(jq -r '.cpu.logical_threads // empty' "$ENV_JSON" 2>/dev/null || true)"
  [[ -n "$CORES_EFFECTIVE" ]] && CORES_SOURCE="env_cpu_logical_threads"
fi
if [[ -z "$CORES_EFFECTIVE" ]]; then
  CORES_EFFECTIVE="$(nproc 2>/dev/null || true)"
  [[ -n "$CORES_EFFECTIVE" ]] && CORES_SOURCE="nproc"
fi
if [[ ! "$CORES_EFFECTIVE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  CORES_EFFECTIVE=""
  CORES_SOURCE="unknown"
fi

# Generate result.json (canonical merged artifact)
# Create null stubs for optional JSON files that may not exist (JFR disabled, or the
# throughput aggregator skipped when no CSV/python3).
for _optional_json in "$JFR_METADATA_JSON" "$JFR_START_JSON" "$K6_THROUGHPUT_SERIES_JSON" "$CORRECTNESS_GATE_JSON"; do
  [[ -f "$_optional_json" ]] || printf 'null\n' > "$_optional_json"
done

# Effective measurement-window split (seconds), mirroring the k6.js defaults so
# result.json records the window split explicitly — a fairness/reproducibility
# field: throughput is steady-state from the measurement window, not a flat average.
_k6_dur_to_s() {
  # NOTE: `rest="$d"` must NOT share a `local` statement with `d`. Bash expands
  # every word of the command BEFORE `local` performs any assignment, so `$d`
  # is still unset at expansion time and `set -u` aborts the script here. That
  # killed the runner immediately after the correctness gate, so result.json —
  # the run's primary artifact — was never assembled on ANY run.
  local d="${1:-}"
  local total=0 num unit
  local rest="$d"
  [[ -z "$rest" ]] && { printf '0\n'; return 0; }
  while [[ "$rest" =~ ^([0-9]+)(ms|h|m|s)(.*)$ ]]; do
    num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[3]}"
    case "$unit" in
      h)  total=$(( total + num * 3600 )) ;;
      m)  total=$(( total + num * 60 )) ;;
      s)  total=$(( total + num )) ;;
      ms) : ;;  # sub-second: ignored for window seconds
      *)  : ;;  # regex guarantees one of the above; default keeps the case exhaustive
    esac
  done
  printf '%s\n' "$total"
}
_warmup_window_s="$(_k6_dur_to_s "${K6_WARMUP_DURATION:-120s}")"
_measurement_window_s="$(_k6_dur_to_s "${K6_MEASURE_DURATION:-180s}")"
_cooldown_window_s="$(_k6_dur_to_s "${K6_COOLDOWN_DURATION:-30s}")"

if [[ -f "$RUN_METADATA_JSON" && -f "$K6_SUMMARY_JSON" && -f "$RESOURCE_METRICS_JSON" && -f "$ENV_JSON" ]]; then
  _reproducibility_status="incomplete"
  if [[ -n "$COMMIT_SHA" && "$COMMIT_SHA" != "unknown" && -f "$RESOURCE_METRICS_JSON" && -f "$ENV_JSON" ]]; then
    _reproducibility_status="complete"
  fi
  _final_reason="ok"
  if [[ "$RUNNER_STATUS" != "clean" ]]; then
    _final_reason="$RUNNER_STATUS"
  fi

  jq -n \
    --arg      run_id              "e2e-shop-order-saga-${RUN_TIMESTAMP_UTC}" \
    --arg      iso_timestamp       "$ISO_TIMESTAMP_UTC" \
    --arg      reproducibility_status "$_reproducibility_status" \
    --arg      final_reason        "$_final_reason" \
    --slurpfile run_metadata       "$RUN_METADATA_JSON" \
    --slurpfile k6_summary         "$K6_SUMMARY_JSON" \
    --slurpfile resource_metrics   "$RESOURCE_METRICS_JSON" \
    --slurpfile env_data           "$ENV_JSON" \
    --slurpfile runtime_log        "$RUNTIME_LOG_METADATA_JSON" \
    --slurpfile jfr_capture        "$JFR_METADATA_JSON" \
    --slurpfile jfr_start          "$JFR_START_JSON" \
    --slurpfile throughput_series  "$K6_THROUGHPUT_SERIES_JSON" \
    --slurpfile correctness_gate   "$CORRECTNESS_GATE_JSON" \
    --arg      cores_effective     "$CORES_EFFECTIVE" \
    --arg      cores_source        "$CORES_SOURCE" \
    --argjson  warmup_window_s     "$_warmup_window_s" \
    --argjson  measurement_window_s "$_measurement_window_s" \
    --argjson  cooldown_window_s   "$_cooldown_window_s" \
    '
    ($run_metadata[0]) as $rm |
    ($k6_summary[0].metrics)  as $km |
    ($env_data[0])            as $env |
    ($throughput_series[0])   as $ts |
    {
      schema_version:           "1",
      run_id:                   $run_id,
      timestamp:                $iso_timestamp,
      scenario_id:              $rm.scenario_id,
      contract_id:              $rm.contract_id,
      target_app:               $rm.target_app,
      graph_track:              $rm.graph_track,
      fault_mode:               $rm.fault_mode,
      durability_tier:          $rm.durability_tier,
      durability_tier_source:   $rm.durability_tier_source,
      tier:                     $rm.tier,
      benchmark_family:         $rm.benchmark_family,
      run_timestamp_utc:        $rm.run_timestamp_utc,
      commit_sha:               $rm.commit_sha,
      protocol_mode:            $rm.protocol_mode,
      transport_mode:           $rm.transport_mode,
      claim_scope:              $rm.claim_scope,
      tool:                     $rm.tool,
      k6_exit_code:             $rm.k6_exit_code,
      runner_status:            $rm.runner_status,
      final_reason:             $final_reason,
      reproducibility_status:   $reproducibility_status,
      correctness_gate:         ($correctness_gate[0]),
      output_dir:               $rm.output_dir,
      metrics: {
        tool:                        "k6",
        orders_initiated:            ($km.orders_initiated.count // 0),
        saga_success_rate:           ($km.saga_success.value // 0),
        saga_compensated_rate:       ($km.saga_compensated.value // 0),
        saga_issued_total:             ($km.saga_issued_total.count // null),
        saga_completed_total:          ($km.saga_completed_total.count // null),
        saga_compensated_total:        ($km.saga_compensated_total.count // null),
        saga_failed_unrecovered_total: ($km.saga_failed_unrecovered_total.count // null),
        http_reqs_total:             ($km.http_reqs.count // 0),
        http_reqs_rate:              ($km.http_reqs.rate // 0),
        http_req_duration_avg_ms:    ($km.http_req_duration.avg // null),
        http_req_duration_p90_ms:    ($km.http_req_duration["p(90)"] // null),
        http_req_duration_p95_ms:    ($km.http_req_duration["p(95)"] // null),
        iteration_duration_avg_ms:   ($km.iteration_duration.avg // null),
        iteration_duration_p90_ms:   ($km.iteration_duration["p(90)"] // null),
        iteration_duration_p95_ms:   ($km.iteration_duration["p(95)"] // null),
        error_rate_pct:              (($km.http_req_failed.value // 0) * 100),
        latency_by_outcome: {
          note: "CONTRACT-v2 s8: COMPLETED and COMPENSATED are separate populations (structurally different code paths); never mix or average across them",
          completed: {
            count:  ($km.saga_completed_total.count // null),
            p50_ms: ($km.saga_completed_duration["p(50)"] // $km.saga_completed_duration.med // null),
            p99_ms: ($km.saga_completed_duration["p(99)"] // null)
          },
          compensated: {
            count:  ($km.saga_compensated_total.count // null),
            p50_ms: ($km.saga_compensated_duration["p(50)"] // $km.saga_compensated_duration.med // null),
            p99_ms: ($km.saga_compensated_duration["p(99)"] // null)
          }
        },
        cores_effective:             (if $cores_effective == "" then null else ($cores_effective | tonumber) end),
        cores_source:                $cores_source,
        steady_state_throughput_rps: ($ts.steady_state_throughput_rps // null),
        steady_state_throughput_rps_per_core: (
          if $cores_effective != "" and (($cores_effective | tonumber) > 0)
             and (($ts.steady_state_throughput_rps // null) != null)
          then ($ts.steady_state_throughput_rps / ($cores_effective | tonumber))
          else null
          end),
        http_reqs_rate_per_core: (
          if $cores_effective != "" and (($cores_effective | tonumber) > 0)
          then (($km.http_reqs.rate // 0) / ($cores_effective | tonumber))
          else null
          end),
        orders_initiated_rate:       ($km.orders_initiated.rate // null),
        orders_initiated_rate_per_core: (
          if $cores_effective != "" and (($cores_effective | tonumber) > 0)
             and (($km.orders_initiated.rate // null) != null)
          then ($km.orders_initiated.rate / ($cores_effective | tonumber))
          else null
          end),
        time_to_peak_s:              ($ts.time_to_peak_s // null),
        throughput_series:           ($ts.throughput_series // [])
      },
      run_config: {
        warmup_window_s:       $warmup_window_s,
        measurement_window_s:  $measurement_window_s,
        cooldown_window_s:     $cooldown_window_s
      },
      run_metadata: ($rm + {
        metadata: {
          jdk_vendor:              ($env.jdk.vendor_raw // "unknown"),
          jdk_version:             (($env.jdk.major_version // 0) | tostring),
          benchmark_tool_version:  ($env.benchmark_tool.version // "unknown"),
          jvm_flags:               ($env.jvm_flags // []),
          hardware_profile:        $rm.hardware_profile,
          scenario_id:             $rm.scenario_id,
          target_classification:   "runtime-exploratory"
        },
        pinned_versions: {
          jdk_version:             (($env.jdk.major_version // 0) | tostring),
          benchmark_tool_version:  ($env.benchmark_tool.version // "unknown"),
          target_commit_sha:       $rm.commit_sha
        },
        actual_versions: {
          jdk_version:             (($env.jdk.major_version // 0) | tostring),
          benchmark_tool_version:  ($env.benchmark_tool.version // "unknown"),
          target_commit_sha:       $rm.commit_sha
        },
        runtime_log:  $runtime_log[0],
        jfr_capture:  $jfr_capture[0],
        jfr_start:    $jfr_start[0]
      }),
      k6_summary:       $k6_summary[0],
      resource_metrics: $resource_metrics[0]
    }' > "$RESULT_JSON"
fi

bench_print_run_summary "$RUN_METADATA_JSON" "$K6_SUMMARY_JSON" "$RESOURCE_METRICS_JSON"

echo "k6 output: $K6_OUTPUT_JSON"
echo "k6 summary: $K6_SUMMARY_JSON"
echo "k6 console: $K6_CONSOLE_LOG"
echo "env metadata: $ENV_JSON"
echo "run metadata: $RUN_METADATA_JSON"
echo "resource samples: $RESOURCE_SAMPLES_CSV"
echo "resource metrics: $RESOURCE_METRICS_JSON"
# The embedded arm matches *axon* but never starts Axon Server, and announcing a stats
# file that was never written told a reader the three-process deployment unit had been
# measured when CONTRACT-v2 §1 says this arm has two. Say what is actually true per arm.
if [[ "$CONTRACT_ID" == *axon_embedded* || "$TARGET_APP" == *axon-embedded* ]]; then
  echo "Note: no Axon Server in this arm — CONTRACT-v2 §1 deployment unit is target JVM + Postgres."
  echo "      The saga engine runs in-process, so no third process holds part of its CPU/RSS;"
  echo "      Postgres stays outside resource-metrics.json exactly as it does for every arm."
elif [[ "$CONTRACT_ID" == *axon* || "$TARGET_APP" == *axon* ]]; then
  echo "axon server stats: $AXON_STATS_CSV"
  echo "Note: Axon Server CPU/RSS is in $AXON_STATS_CSV (separate process). Not included in resource-metrics.json."
fi
if [[ "$CONTRACT_ID" == *restate* || "$TARGET_APP" == *restate* ]]; then
  echo "restate server stats: $RESTATE_STATS_CSV"
  echo "Note: restate-server CPU/RSS is in $RESTATE_STATS_CSV (separate container). Not included in resource-metrics.json."
fi
echo "logs dir: $LOGS_DIR"
echo "jcmd diagnostics: $JCMD_DIAGNOSTICS_JSON"
echo "endpoint preflight: $ENDPOINT_PREFLIGHT_TXT"
echo "claim status: $CLAIM_STATUS_JSON"
echo "deployment footprint: $DEPLOYMENT_FOOTPRINT_JSON"
echo "correctness gate: $CORRECTNESS_GATE_JSON (status: ${GATE_STATUS})"
echo "result: $RESULT_JSON"
echo "runtime log metadata: $RUNTIME_LOG_METADATA_JSON"
echo "target runtime log: $TARGET_RUNTIME_LOG"
if [[ "$ENABLE_JFR" == "true" ]]; then
  echo "jfr metadata: $JFR_METADATA_JSON"
  echo "jfr file: $JFR_FILE"
fi
if [[ "$ENABLE_PERF_STAT" == "true" ]]; then
  echo "perf stat: $PERF_STAT_CSV"
fi
echo "Note: results are exploratory unless profile is perf-box-amd64."

# Fail closed on the CONTRACT-v2 s4.1 correctness gate: a compensation-count
# mismatch is a correctness bug (v1 "zero compensations" class), not a
# statistical anomaly. gate status=error (gate not evaluable on a v2-capable
# run: missing k6 metrics, helper crash, python3 unavailable, inconsistent
# artifacts) also fails closed — an unevaluated gate must never pass silently.
# Only the documented pre-v2 legacy-summary skip remains a WARN. Artifacts
# above are still written for post-mortem.
if [[ "$GATE_STATUS" == "fail" ]]; then
  echo "ERROR: CONTRACT-v2 s4.1 correctness gate FAILED: observed_compensations=${GATE_OBSERVED} expected_declines=${GATE_EXPECTED} (issued=${GATE_ISSUED}, seed=${GATE_ORDER_SEED})." >&2
  echo "ERROR: run marked runner_status=compensation_mismatch; performance numbers from this run are excluded from headline tables. Details: $CORRECTNESS_GATE_JSON" >&2
  exit 3
elif [[ "$GATE_STATUS" == "detector_fault" ]]; then
  echo "ERROR: CONTRACT-v2 s7 O0 DETECTOR FAULT: ${GATE_REASON}" >&2
  echo "ERROR: this is an instrument failure, not a measurement — the run supports NO correctness claim in either direction, and its compensation count must not be quoted. Details: $CORRECTNESS_GATE_JSON" >&2
  exit 5
elif [[ "$GATE_STATUS" == "error" ]]; then
  echo "ERROR: CONTRACT-v2 s4.1 correctness gate ERROR (fails closed): ${GATE_REASON}" >&2
  echo "ERROR: run marked runner_status=compensation_gate_error; performance numbers from this run are excluded from headline tables. Details: $CORRECTNESS_GATE_JSON" >&2
  exit 4
fi
