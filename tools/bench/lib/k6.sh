#!/usr/bin/env bash
set -u

# CO Guard: k6 closed-loop executors (shared-iterations, ramping-vus) produce
# Coordinated Omission-contaminated p99 latency. This is the canonical guard.
bench_k6_assert_arrival_rate_executor() {
  local k6_script="$1"

  if ! grep -qE '"(constant|ramping)-arrival-rate"' "$k6_script" 2>/dev/null \
     && ! grep -qE "executor:[[:space:]]*'(constant|ramping)-arrival-rate'" "$k6_script" 2>/dev/null; then
    echo "ERROR: k6 scenario does not declare a constant-arrival-rate or ramping-arrival-rate executor." >&2
    echo "  Closed-loop executors (shared-iterations, ramping-vus) produce CO-contaminated p99 latency." >&2
    echo "  Update $k6_script to use: executor: 'constant-arrival-rate'" >&2
    echo "  See docs/methodology.md for guidance." >&2
    echo "  To run throughput-only probes (no latency claims), set CO_GUARD_BYPASS=true" >&2
    if [[ "${CO_GUARD_BYPASS:-false}" != "true" ]]; then
      return 1
    fi
    echo "WARN: CO_GUARD_BYPASS=true — latency results will be CO-contaminated. Do not publish p99." >&2
    return 0
  fi

  return 0
}

bench_read_k6_defaults() {
  local env_file="$1"
  local key raw val
  # k6 binary treats these as system-level runtime overrides — if set in OS env
  # they replace 'export const options' in the script with a plain default scenario.
  # These must NOT be exported to OS env; they stay out of the environment entirely.
  local -r _K6_SYSTEM_VARS='K6_VUS|K6_DURATION|K6_ITERATIONS|K6_RAMP_UP|K6_STAGES'
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line%%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    # Accept: [export] KEY=value  where KEY starts with K6_ or EXERIS_
    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z][A-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)[[:space:]]*$ ]]; then
      key="${BASH_REMATCH[2]}"
      raw="${BASH_REMATCH[3]}"
      # Only process K6_* and EXERIS_* variables
      [[ "$key" != K6_* && "$key" != EXERIS_* ]] && continue
      # Never export k6 system-level vars that override script options
      [[ "$key" =~ ^(${_K6_SYSTEM_VARS})$ ]] && continue
      # Strip surrounding quotes
      if [[ "$raw" =~ ^\"(.*)\"$ ]]; then
        val="${BASH_REMATCH[1]}"
      elif [[ "$raw" =~ ^\'(.*)\'$ ]]; then
        val="${BASH_REMATCH[1]}"
      else
        val="${raw%%[[:space:]]*}"
      fi
      # Only export if not already set in the environment (inline caller vars win)
      if [[ -z "${!key+x}" ]]; then
        export "$key=$val"
      fi
    fi
  done < "$env_file"
}

# bench_run_k6(k6_script, output_json, summary_json, stage_spec, docker_image)
# Env vars consumed from caller environment by k6 script: BASE_URL and all K6_* vars.
# REPO_ROOT must be exported by caller for docker volume mount fallback.
bench_run_k6() {
  local k6_script="$1"
  local output_json="$2"
  local summary_json="$3"
  local stage_spec="${4:-}"
  local docker_image="${5:-grafana/k6:latest}"

  bench_k6_assert_arrival_rate_executor "$k6_script" || return 1

  local stage_args=()
  if [[ -n "$stage_spec" ]]; then
    IFS=',' read -ra _k6_stages <<< "$stage_spec"
    for _k6_s in "${_k6_stages[@]}"; do
      stage_args+=( --stage "$_k6_s" )
    done
  fi

  if command -v k6 >/dev/null 2>&1; then
    # k6 >= v0.41 does not expose OS env vars to __ENV automatically.
    # Build explicit --env args for BASE_URL, K6_*, and EXERIS_* vars.
    # Use %%=* / #*= instead of IFS='=' read to preserve values containing '='.
    local _local_env_args=()
    _local_env_args+=( --env "BASE_URL=${BASE_URL:-}" )
    while IFS= read -r _lk6_line; do
      [[ -z "$_lk6_line" ]] && continue
      _lk6_key="${_lk6_line%%=*}"
      _lk6_rest="${_lk6_line#*=}"
      [[ -z "$_lk6_key" ]] && continue
      _local_env_args+=( --env "${_lk6_key}=${_lk6_rest}" )
    done < <(env | grep -E '^(K6_|EXERIS_)')
    k6 run \
      --out "json=$output_json" \
      --summary-export="$summary_json" \
      "${_local_env_args[@]}" \
      "${stage_args[@]}" \
      "$k6_script"
  elif command -v docker >/dev/null 2>&1; then
    # Collect all K6_* and EXERIS_* env vars and BASE_URL to forward into the container.
    # Use %%=* / #*= instead of IFS='=' read to preserve values containing '='.
    # Two arg lists:
    #   _docker_env_args: Docker -e flags (set OS env in container for non-k6 use)
    #   _k6_env_args:     k6 --env flags (expose vars in __ENV; required since k6 >= v0.41
    #                     no longer exposes OS env to __ENV automatically)
    local _docker_env_args=()
    local _k6_env_args=()
    _docker_env_args+=( -e "BASE_URL=${BASE_URL:-}" )
    _k6_env_args+=( --env "BASE_URL=${BASE_URL:-}" )
    while IFS= read -r _k6_line; do
      [[ -z "$_k6_line" ]] && continue
      _k6_key="${_k6_line%%=*}"
      _k6_rest="${_k6_line#*=}"
      [[ -z "$_k6_key" ]] && continue
      _docker_env_args+=( -e "${_k6_key}=${_k6_rest}" )
      _k6_env_args+=( --env "${_k6_key}=${_k6_rest}" )
    done < <(env | grep -E '^(K6_|EXERIS_)')

    docker run --rm \
      --network host \
      "${_docker_env_args[@]}" \
      -v "${REPO_ROOT:-}:${REPO_ROOT:-}" \
      -w "${REPO_ROOT:-}" \
      --user "$(id -u):$(id -g)" \
      "$docker_image" run \
      --out "json=${output_json}" \
      --summary-export="${summary_json}" \
      "${_k6_env_args[@]}" \
      "${stage_args[@]}" \
      "$k6_script"
  else
    echo "ERROR: k6 binary not found and docker fallback is unavailable." >&2
    return 1
  fi
}
