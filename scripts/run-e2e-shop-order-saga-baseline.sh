#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_ROOT/tools/bench/lib"

source "$LIB/readiness.sh"
source "$LIB/protocol.sh"
source "$LIB/resource-sampler.sh"
source "$LIB/jfr.sh"
source "$LIB/jcmd.sh"
source "$LIB/perf.sh"
source "$LIB/k6.sh"
source "$LIB/run-summary.sh"

# Saga-order runs opt into Axon explicitly; generic runtime startup stays default-off.
export EXERIS_AXON_ENABLED="${EXERIS_AXON_ENABLED:-true}"

usage() {
  cat <<'EOF'
Usage: run-e2e-shop-order-saga-baseline.sh [options]

Options:
  --base-url <url>         Base URL for target app (default: https://localhost:8080)
  --contract-id <id>       Contract id (default: exeris_community_h2c_v1)
  --target-app <name>      Target app label (default: exeris-e2e-community-h2)
  --auto-start-infra       Auto-start benchmark infra (Postgres + Neo4j) via docker compose (default)
  --no-auto-start-infra    Do not auto-start benchmark infra
  --auto-start-target      Auto-start target app if health preflight fails (default)
  --no-auto-start-target   Do not auto-start target app if health preflight fails
  --force-restart-target      Kill and restart target even if already healthy (default: enabled)
  --no-force-restart-target   Reuse existing target process if already healthy
  --health-timeout-seconds <n>  Seconds to wait for target health (default: 60)
  --graph-track <name>     Graph track label (default: postgres)
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

cleanup_baseline() {
  [[ -n "$PRE_TMP" ]] && rm -f "$PRE_TMP"
  bench_stop_resource_sampler
  bench_stop_perf_stat
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
  echo "Runtime overrides: graph_backend=${EXERIS_GRAPH_BACKEND_TYPE} protocol=${declared_protocol_mode} http_max=${EXERIS_HTTP_MAX_VERSION} h2c_upgrade=${EXERIS_HTTP_H2C_UPGRADE_ENABLED} http2=${EXERIS_HTTP2_ENABLED} ssl=${EXERIS_SSL_ENABLED}"
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
    if ! docker compose -f "$BENCHMARK_COMPOSE_FILE" up -d benchmark-postgres benchmark-neo4j; then
      echo "Warning: docker compose failed to start benchmark infra services; checking health anyway." >&2
    fi
    wait_for_compose_service_health "$BENCHMARK_COMPOSE_FILE" "benchmark-postgres" "true"
    wait_for_compose_service_health "$BENCHMARK_COMPOSE_FILE" "benchmark-neo4j" "false"
  else
    echo "Auto-starting benchmark infra: benchmark-postgres (graph_track=${GRAPH_TRACK}, Neo4j skipped)"
    if ! docker compose -f "$BENCHMARK_COMPOSE_FILE" up -d benchmark-postgres; then
      echo "Warning: docker compose failed to start benchmark-postgres; checking health anyway." >&2
    fi
    wait_for_compose_service_health "$BENCHMARK_COMPOSE_FILE" "benchmark-postgres" "true"
  fi

  echo "Running DB seed migrations (benchmark-db-seed)..."
  docker compose -f "$BENCHMARK_COMPOSE_FILE" up --force-recreate --no-deps benchmark-db-seed
  echo "DB seed migrations complete."

  if [[ "$GRAPH_TRACK" == "neo4j" ]]; then
    echo "[seed] Seeding Neo4j from PostgreSQL..."
    "$SEED_NEO4J_SCRIPT" 2>&1 | tee "$NEO4J_SEED_LOG"
  fi

  if [[ "$CONTRACT_ID" == *axon* || "$TARGET_APP" == *axon* || "$TARGET_APP" == *spring* || "$TARGET_APP" == *quarkus* ]]; then
    echo "Axon target detected (contract=${CONTRACT_ID}); starting benchmark-axonserver."
    docker compose -f "$BENCHMARK_COMPOSE_FILE" rm -f --volumes benchmark-axonserver 2>/dev/null || true
    if ! docker compose -f "$BENCHMARK_COMPOSE_FILE" up -d --force-recreate benchmark-axonserver; then
      echo "Warning: docker compose failed to start benchmark-axonserver; checking health anyway." >&2
    fi
    wait_for_compose_service_health "$BENCHMARK_COMPOSE_FILE" "benchmark-axonserver" "false"
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
}

_BASE_URL_EXPLICIT="false"
BASE_URL="https://localhost:8080"
CURL_INSECURE_OPT=""
CONTRACT_ID="exeris_community_h2c_v1"
TARGET_APP="exeris-e2e-community-h2"
TARGET_APP_LOG_FILE=""
AUTO_START_INFRA="true"
START_TARGET_ON_DEMAND="true"
FORCE_RESTART_TARGET="true"
HEALTH_TIMEOUT_SECONDS="120"
START_TARGET_SCRIPT="$REPO_ROOT/runtime/drivers/start-target.sh"
STOP_TARGET_SCRIPT="$REPO_ROOT/runtime/drivers/stop-target.sh"
BENCHMARK_COMPOSE_REF="runtime/compose/e2e-shop-order-saga.yml"
BENCHMARK_COMPOSE_FILE="$REPO_ROOT/$BENCHMARK_COMPOSE_REF"
GRAPH_TRACK="postgres"
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)
      BASE_URL="$2"
      _BASE_URL_EXPLICIT="true"
      shift 2
      ;;
    --contract-id)
      CONTRACT_ID="$2"
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

# Derive the path of the target process log file (fixed name from EXTERNAL_START_CMD) for failure capture.
case "${TARGET_APP:-}" in
  exeris-community-app|exeris-e2e-community-h2*)  TARGET_APP_LOG_FILE="/tmp/exeris-community-8080.log" ;;
  exeris-community-app-locality)                  TARGET_APP_LOG_FILE="/tmp/exeris-locality-8080.log"  ;;
  spring-app-axon|spring-*)                        TARGET_APP_LOG_FILE="/tmp/exeris-spring-9001.log"    ;;
  quarkus-app-axon|quarkus-*)                      TARGET_APP_LOG_FILE="/tmp/exeris-quarkus-9002.log"   ;;
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
      BASE_URL="${_derived_health_url%/health}"
      echo "BASE_URL derived from asset matrix for target '${TARGET_APP}': ${BASE_URL}"
    fi
  fi
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
RESULT_JSON="$OUTPUT_DIR/result.json"
RUNTIME_LOG_METADATA_JSON="$LOGS_DIR/runtime-log-metadata.json"
AXON_STATS_CSV="$LOGS_DIR/axonserver-docker-stats.csv"
AXON_STATS_PID=""
mkdir -p "$LOGS_DIR"
trap cleanup_baseline EXIT

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

# Start Axon Server docker stats sampler (if axon contract detected)
AXON_STATS_PID=""
if [[ "$CONTRACT_ID" == *axon* || "$TARGET_APP" == *axon* || "$TARGET_APP" == *spring* || "$TARGET_APP" == *quarkus* ]]; then
  _axon_cid="$(docker inspect --format '{{.Id}}' exeris-e2e-saga-axonserver 2>/dev/null || true)"
  if [[ -n "$_axon_cid" ]]; then
    printf 'epoch_ms,cpu_pct,mem_usage_mb,mem_limit_mb,net_in_mb,net_out_mb,block_in_mb,block_out_mb,pids\n' > "$AXON_STATS_CSV"
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
        _line="$(docker stats --no-stream --format '{{.CPUPerc}},{{.MemUsage}},{{.NetIO}},{{.BlockIO}},{{.PIDs}}' exeris-e2e-saga-axonserver 2>/dev/null || true)"
        [[ -z "$_line" ]] && { sleep 1; continue; }
        _epoch_ms="$(date +%s%3N)"
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
          "$_epoch_ms" "$_cpu" "$_mem_u" "$_mem_l" "$_net_in" "$_net_out" "$_blk_in" "$_blk_out" "$_pids" >> "$AXON_STATS_CSV"
        sleep 1
      done
    ) &
    AXON_STATS_PID="$!"
    echo "Axon Server docker stats sampler started (container: exeris-e2e-saga-axonserver, pid: ${AXON_STATS_PID})."
  else
    echo "Warning: exeris-e2e-saga-axonserver container not found; Axon Server stats will not be captured." >&2
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
K6_EXIT_CODE=0
set +e
bench_run_k6 "$K6_SCRIPT" "$K6_OUTPUT_JSON" "$K6_SUMMARY_JSON" "" "$K6_DOCKER_IMAGE" \
  2>&1 | tee "$K6_CONSOLE_LOG"
K6_EXIT_CODE="${PIPESTATUS[0]}"
set -e
if [[ "$K6_EXIT_CODE" -ne 0 ]]; then
  echo "Warning: k6 exited with code ${K6_EXIT_CODE} (likely threshold failures). Continuing artifact collection." >&2
fi

bench_stop_resource_sampler
bench_stop_perf_stat

# Stop Axon Server docker stats sampler
if [[ -n "$AXON_STATS_PID" ]]; then
  kill "$AXON_STATS_PID" >/dev/null 2>&1 || true
  wait "$AXON_STATS_PID" 2>/dev/null || true
  AXON_STATS_PID=""
fi

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

if [[ "$K6_EXIT_CODE" -eq 0 ]]; then
  RUNNER_STATUS="clean"
else
  RUNNER_STATUS="threshold_failure"
fi

jq -n \
  --arg scenario_id "e2e-shop-order-saga" \
  --arg contract_id "$CONTRACT_ID" \
  --arg target_app "$TARGET_APP" \
  --arg graph_track "$GRAPH_TRACK" \
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
  --arg runner_status "$RUNNER_STATUS" \
  '{
    scenario_id: $scenario_id,
    contract_id: $contract_id,
    target_app: $target_app,
    graph_track: $graph_track,
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
    logs_dir: $logs_dir,
    infra_contract: {
      compose_ref: $compose_ref,
      compose_sha256: $compose_sha256,
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
  --arg hardware_profile "$PROFILE" \
  --arg claim_scope      "exploratory" \
  --argjson k6_exit_code "$K6_EXIT_CODE" \
  '{
    schema_version:   "1",
    scenario_id:      $scenario_id,
    contract_id:      $contract_id,
    target_app:       $target_app,
    graph_track:      $graph_track,
    hardware_profile: $hardware_profile,
    claim_scope:      $claim_scope,
    rejection_codes:  (
      if $hardware_profile != "perf-box-amd64"
      then ["non_canonical_hardware_profile"]
      elif $k6_exit_code != 0
      then ["threshold_failure"]
      else []
      end
    ),
    reason: (
      if $hardware_profile != "perf-box-amd64"
      then "not perf-box-amd64 hardware profile"
      elif $k6_exit_code != 0
      then ("k6 exited with code " + ($k6_exit_code | tostring))
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

# Generate result.json (canonical merged artifact)
# Create null stubs for optional JFR JSON files that may not exist when JFR is disabled.
for _optional_json in "$JFR_METADATA_JSON" "$JFR_START_JSON"; do
  [[ -f "$_optional_json" ]] || printf 'null\n' > "$_optional_json"
done

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
    '
    ($run_metadata[0]) as $rm |
    ($k6_summary[0].metrics)  as $km |
    ($env_data[0])            as $env |
    {
      schema_version:           "1",
      run_id:                   $run_id,
      timestamp:                $iso_timestamp,
      scenario_id:              $rm.scenario_id,
      contract_id:              $rm.contract_id,
      target_app:               $rm.target_app,
      graph_track:              $rm.graph_track,
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
      output_dir:               $rm.output_dir,
      metrics: {
        tool:                        "k6",
        orders_initiated:            ($km.orders_initiated.count // 0),
        saga_success_rate:           ($km.saga_success.value // 0),
        saga_compensated_rate:       ($km.saga_compensated.value // 0),
        http_reqs_total:             ($km.http_reqs.count // 0),
        http_reqs_rate:              ($km.http_reqs.rate // 0),
        http_req_duration_avg_ms:    ($km.http_req_duration.avg // null),
        http_req_duration_p90_ms:    ($km.http_req_duration["p(90)"] // null),
        http_req_duration_p95_ms:    ($km.http_req_duration["p(95)"] // null),
        iteration_duration_avg_ms:   ($km.iteration_duration.avg // null),
        iteration_duration_p90_ms:   ($km.iteration_duration["p(90)"] // null),
        iteration_duration_p95_ms:   ($km.iteration_duration["p(95)"] // null),
        error_rate_pct:              (($km.http_req_failed.value // 0) * 100)
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
if [[ "$CONTRACT_ID" == *axon* || "$TARGET_APP" == *axon* ]]; then
  echo "axon server stats: $AXON_STATS_CSV"
  echo "Note: Axon Server CPU/RSS is in $AXON_STATS_CSV (separate process). Not included in resource-metrics.json."
fi
echo "logs dir: $LOGS_DIR"
echo "jcmd diagnostics: $JCMD_DIAGNOSTICS_JSON"
echo "endpoint preflight: $ENDPOINT_PREFLIGHT_TXT"
echo "claim status: $CLAIM_STATUS_JSON"
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
