#!/usr/bin/env bash
set -u

BENCH_HEALTH_HTTP_CODE="${BENCH_HEALTH_HTTP_CODE:-}"

bench_normalize_health_base_url() {
  local health_url=${1:-}

  if [[ -z "$health_url" ]]; then
    return 1
  fi

  if [[ "$health_url" =~ ^(https?://[^/]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

bench_wait_for_http_200_with_metrics() {
  local target_id=$1
  local url=$2
  local label=$3
  local max_wait_seconds=${4:-60}
  local insecure=${5:-}
  local elapsed=0
  local attempts=0
  local code=""
  local start_epoch_ms
  local first_200_epoch_ms
  local first_200_utc

  BENCH_WAIT_HTTP_200_UTC=""
  BENCH_WAIT_HTTP_200_EPOCH_MS=""
  BENCH_WAIT_HTTP_200_ATTEMPTS=""
  BENCH_WAIT_HTTP_200_ELAPSED_SECONDS=""

  start_epoch_ms=$(date -u +%s%3N)

  while (( elapsed < max_wait_seconds )); do
    attempts=$((attempts + 1))
    # shellcheck disable=SC2086
    code=$(curl -sS $insecure -o /dev/null -w "%{http_code}" --max-time 5 "$url" || true)
    if [[ "$code" == "200" ]]; then
      first_200_epoch_ms=$(date -u +%s%3N)
      first_200_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      BENCH_WAIT_HTTP_200_UTC="$first_200_utc"
      BENCH_WAIT_HTTP_200_EPOCH_MS="$first_200_epoch_ms"
      BENCH_WAIT_HTTP_200_ATTEMPTS="$attempts"
      BENCH_WAIT_HTTP_200_ELAPSED_SECONDS=$(( (first_200_epoch_ms - start_epoch_ms) / 1000 ))
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  echo "ERROR: Target ${target_id} did not return HTTP 200 for ${label} within ${max_wait_seconds}s: ${url} (last status: ${code:-n/a})"
  return 1
}

# HTTPS endpoints in the bench harness use self-signed smoke certs (see
# tools/bench/lib/certs.sh); accept them with -k, matching the convention in
# run-e2e-shop-order-saga-baseline.sh (CURL_INSECURE_OPT) and start-target.sh
# (curl -sfk). Plain-http URLs are unaffected.
_bench_preflight_insecure_opt() {
  [[ "${1:-}" == https://* ]] && printf -- '-k' || printf ''
}

bench_run_endpoint_preflight() {
  local url=$1
  local output_file=$2
  local timeout_seconds=${3:-60}
  local insecure; insecure="$(_bench_preflight_insecure_opt "$url")"

  BENCH_PREFLIGHT_HTTP_CODE=""
  BENCH_PREFLIGHT_HTTP_CODE=$(curl -sS $insecure -o "$output_file" -w "%{http_code}" --max-time "$timeout_seconds" "$url" || true)

  [[ "$BENCH_PREFLIGHT_HTTP_CODE" == "200" ]]
}

bench_run_endpoint_preflight_with_headers() {
  local url=$1
  local output_file=$2
  local timeout_seconds=${3:-60}
  local insecure; insecure="$(_bench_preflight_insecure_opt "$url")"

  BENCH_PREFLIGHT_HTTP_CODE=""
  BENCH_PREFLIGHT_HTTP_CODE=$(curl -sS $insecure -i -o "$output_file" -w "%{http_code}" --max-time "$timeout_seconds" "$url" || true)

  [[ "$BENCH_PREFLIGHT_HTTP_CODE" == "200" ]]
}

bench_print_preflight_payload_preview() {
  local preflight_file=$1
  local max_chars=${2:-512}
  local preview=""
  local raw_length="0"

  if [[ ! -s "$preflight_file" ]]; then
    printf '<empty>\n'
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    preview="$(jq -c '
      if type == "array" then
        if length > 0 then .[0] else [] end
      elif type == "object" then
        .
      else
        .
      end
    ' "$preflight_file" 2>/dev/null || true)"

    if [[ -n "$preview" ]]; then
      raw_length="$(printf '%s' "$preview" | wc -c | tr -d '[:space:]')"
      printf '%s' "$(printf '%s' "$preview" | head -c "$max_chars")"
      if [[ "$raw_length" =~ ^[0-9]+$ ]] && (( raw_length > max_chars )); then
        printf '%s' '...<truncated>'
      fi
      printf '\n'
      return 0
    fi
  fi

  raw_length="$(wc -c < "$preflight_file" | tr -d '[:space:]')"
  preview="$(head -c "$max_chars" "$preflight_file")"

  printf '%s' "$preview"
  if [[ "$raw_length" =~ ^[0-9]+$ ]] && (( raw_length > max_chars )); then
    printf '%s' '...<truncated>'
  fi
  printf '\n'
}

# ============================================================================
# Additional readiness helpers
# ============================================================================

bench_health_http_code() {
  local url="$1"
  local insecure_flag="${2:-}"
  local code

  # shellcheck disable=SC2086
  code="$(curl -sS $insecure_flag --connect-timeout 3 --max-time 8 \
    -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"

  if [[ "$code" =~ ^[0-9]{3}$ ]]; then
    BENCH_HEALTH_HTTP_CODE="$code"
  else
    BENCH_HEALTH_HTTP_CODE="000"
  fi

  echo "$BENCH_HEALTH_HTTP_CODE"
  [[ "$BENCH_HEALTH_HTTP_CODE" == "200" ]]
}

bench_wait_for_health() {
  local url="$1"
  local timeout_seconds="${2:-60}"
  local insecure_flag="${3:-}"
  local deadline code elapsed last_print=0

  deadline="$((SECONDS + timeout_seconds))"
  while (( SECONDS < deadline )); do
    bench_health_http_code "$url" "$insecure_flag" || true
    code="$BENCH_HEALTH_HTTP_CODE"
    [[ "$code" == "200" ]] && return 0
    if (( SECONDS - last_print >= 5 )); then
      elapsed="$((SECONDS - (deadline - timeout_seconds)))"
      printf '  health poll: %s → %s (%ds elapsed, %ds remaining)\n' \
        "$url" "$code" "$elapsed" "$((deadline - SECONDS))" >&2
      last_print="$SECONDS"
    fi
    sleep 1
  done

  bench_health_http_code "$url" "$insecure_flag" || true
  [[ "$BENCH_HEALTH_HTTP_CODE" == "200" ]]
}

bench_ensure_target_ready() {
  local base_url="$1"
  local insecure_flag="${2:-}"
  local timeout_seconds="${3:-60}"
  local start_on_demand="${4:-false}"
  local start_script="${5:-}"
  local target_app="${6:-}"
  local code elapsed

  bench_health_http_code "${base_url}/health" "$insecure_flag" || true
  code="$BENCH_HEALTH_HTTP_CODE"

  if [[ "$code" != "200" && "$start_on_demand" == "true" && -n "$start_script" ]]; then
    echo "Target health is $code at ${base_url}/health; attempting to start target '$target_app' via $start_script"
    "$start_script" "$target_app" || true
  fi

  if [[ "$code" == "200" ]]; then
    echo "Target ready immediately at ${base_url}/health."
    return 0
  fi

  echo "Waiting for target at ${base_url}/health (timeout: ${timeout_seconds}s)..."
  if bench_wait_for_health "${base_url}/health" "$timeout_seconds" "$insecure_flag"; then
    elapsed="$((SECONDS))"
    echo "  Target ready."
    return 0
  fi

  echo "Preflight failed: target not healthy after ${timeout_seconds}s at ${base_url}/health" >&2
  exit 1
}

bench_capture_endpoint_preflight_body() {
  local base_url="$1"
  local insecure_flag="${2:-}"
  local logs_dir="$3"
  local output_file="$logs_dir/endpoint-preflight.txt"
  local _tmpbody _code _version _url _ep

  mkdir -p "$logs_dir"
  {
    printf '=== ENDPOINT PREFLIGHT ===\n'
    printf 'Timestamp: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
    printf 'Base URL: %s\n\n' "$base_url"

    local -a _get_endpoints=(
      "/health"
      "/db/ping"
      "/api/v1/users"
      "/api/v1/products/recommended"
      "/api/v1/cart"
    )

    for _ep in "${_get_endpoints[@]}"; do
      _url="${base_url}${_ep}"
      _tmpbody="$(mktemp)"
      # shellcheck disable=SC2086
      _code="$(curl -sS $insecure_flag -o "$_tmpbody" -w '%{http_code}' \
        --max-time 5 "$_url" 2>/dev/null || true)"
      # shellcheck disable=SC2086
      _version="$(curl -sS $insecure_flag -o /dev/null -w '%{http_version}' \
        --max-time 5 "$_url" 2>/dev/null || true)"
      printf '%s\n' "--- GET ${_url} ---"
      printf 'HTTP/%-4s  status: %s\n' "$_version" "$_code"
      printf 'Body:\n'
      cat "$_tmpbody"
      printf '\n\n'
      rm -f "$_tmpbody"
    done

    printf '%s\n' '--- POST endpoints (skipped in preflight -- side effects) ---'
    printf '  POST %s/api/v1/auth/register\n' "$base_url"
    printf '  POST %s/api/v1/cart/add\n' "$base_url"
    printf '  POST %s/api/v1/orders\n' "$base_url"
    printf '\n'
  } > "$output_file" 2>&1 || true
}

bench_extract_port_from_url() {
  local base_url="$1"
  local scheme hostport port

  scheme="${base_url%%://*}"
  hostport="${base_url#*://}"
  hostport="${hostport%%/*}"

  if [[ "$hostport" == *":"* ]]; then
    port="${hostport##*:}"
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      echo "$port"
      return 0
    fi
  fi

  case "$scheme" in
    https) echo "443" ;;
    http)  echo "80"  ;;
    *)     echo ""; return 1 ;;
  esac
}

bench_port_reachable() {
  local port="$1"

  if [[ -z "$port" ]]; then
    return 1
  fi

  (echo > /dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1
}

bench_find_available_local_port() {
  local preferred_port="${1:-8080}"
  local fallback_start="${2:-18080}"
  local candidate

  if ! bench_port_reachable "$preferred_port"; then
    printf '%s\n' "$preferred_port"
    return 0
  fi

  if [[ "$fallback_start" == "$preferred_port" ]]; then
    fallback_start=$((preferred_port + 1))
  fi

  for candidate in $(seq "$fallback_start" $((fallback_start + 200))); do
    if ! bench_port_reachable "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "ERROR: no free localhost port available for benchmark target fallback" >&2
  return 1
}

bench_detect_pid_for_port() {
  local port="$1"
  local pid=""

  if [[ -z "$port" ]]; then
    echo ""
    return 0
  fi

  if command -v ss >/dev/null 2>&1; then
    pid="$(ss -ltnp "sport = :${port}" 2>/dev/null | \
      sed -nE 's/.*pid=([0-9]+).*/\1/p' | head -n 1)"
    if [[ -n "$pid" ]]; then
      echo "$pid"
      return 0
    fi
  fi

  if command -v lsof >/dev/null 2>&1; then
    pid="$(lsof -nP -iTCP:"${port}" -sTCP:LISTEN -t 2>/dev/null | head -n 1)"
    if [[ -n "$pid" ]]; then
      echo "$pid"
      return 0
    fi
  fi

  echo ""
}

bench_collect_target_runtime_log() {
  local target_pid="${1:-}"
  local target_app="${2:-}"
  local dest_file="$3"
  local _log_path_hint="/tmp/exeris-bench-target.log.path"
  local _src=""

  # Strategy 1: path written by start-target.sh jar launcher
  if [[ -f "$_log_path_hint" ]]; then
    _src="$(cat "$_log_path_hint" 2>/dev/null || true)"
  fi

  # Strategy 2: discover via /proc/<pid>/fd/1 (Linux -- jar mode with file redirect)
  if [[ -z "$_src" && -n "$target_pid" && -d "/proc/$target_pid" ]]; then
    local _fd1
    _fd1="$(readlink -f "/proc/$target_pid/fd/1" 2>/dev/null || true)"
    if [[ -n "$_fd1" && -f "$_fd1" ]]; then
      _src="$_fd1"
    fi
  fi

  # Strategy 3: docker logs -- match container by target_app name fragment
  if [[ -z "$_src" && -n "$target_app" ]] && command -v docker >/dev/null 2>&1; then
    local _container
    _container="$(docker ps --filter "name=${target_app}" --format '{{.Names}}' 2>/dev/null | head -n1 || true)"
    if [[ -n "$_container" ]]; then
      docker logs "$_container" > "$dest_file" 2>&1 || true
      return 0
    fi
  fi

  if [[ -n "$_src" && -f "$_src" ]]; then
    cp "$_src" "$dest_file" 2>/dev/null || true
  else
    printf 'target-runtime.log: not available (pid=%s app=%s hint=%s)\n' \
      "${target_pid:-n/a}" "${target_app:-n/a}" "$_log_path_hint" > "$dest_file" 2>/dev/null || true
  fi
}
