#!/usr/bin/env bash
# runtime/drivers/target-contract-registry.sh
# Deterministic target_id -> launcher contract resolver for runtime drivers.

set -euo pipefail

TARGET_CONTRACT_TARGET_ID=""
TARGET_CONTRACT_TIER=""
TARGET_CONTRACT_PROTOCOL_MODE=""
TARGET_CONTRACT_LAUNCHER_MODE=""
TARGET_CONTRACT_ENV_FILE=""
TARGET_CONTRACT_PROFILE_ID=""
TARGET_CONTRACT_COMPOSE_FILE=""
TARGET_CONTRACT_JAR_PATH=""
TARGET_CONTRACT_HEALTH_URL=""

TARGET_CONTRACT_INPUT_ID=""

target_registry_root() {
  local registry_dir
  registry_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "${registry_dir}/../.." && pwd
}

normalize_target_alias() {
  local raw_id="${1:-}"
  case "${raw_id}" in
    community) echo "exeris-native-community" ;;
    enterprise) echo "exeris-kernel-enterprise" ;;
    spring-benchmark-app|spring-runtime) echo "spring-jvm-vt-tuned" ;;
    spring-app-axon) echo "spring-app-axon" ;;
    quarkus-benchmark-app|quarkus-runtime) echo "quarkus-jvm-vt-tuned" ;;
    quarkus-app-axon) echo "quarkus-app-axon" ;;
    exeris-community-app|exeris-e2e-community-h2c) echo "exeris-community-app" ;;
    exeris-benchmark-app|exeris-runtime-h1) echo "exeris-benchmark-app-community-h1" ;;
    *) echo "${raw_id}" ;;
  esac
}

target_registry_config_error() {
  local msg="${1:-invalid target contract configuration}"
  echo "CONFIG_ERROR: ${msg}" >&2
}

target_registry_matrix_path() {
  local root
  root="$(target_registry_root)"
  echo "${root}/runtime/drivers/target-asset-matrix.json"
}

target_registry_execution_profile_matrix_path() {
  local root
  root="$(target_registry_root)"
  echo "${root}/runtime/profiles/runtime-execution-profiles.json"
}

target_registry_require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    target_registry_config_error "jq is required for target contract registry"
    return 67
  fi
  return 0
}

target_registry_get_matrix_row_json() {
  local canonical_id="${1:-}"
  local matrix_path
  local match_count

  matrix_path="$(target_registry_matrix_path)"
  if [[ ! -f "${matrix_path}" ]]; then
    target_registry_config_error "target asset matrix not found: ${matrix_path}"
    return 64
  fi

  match_count="$(jq -r --arg id "${canonical_id}" '[.targets[] | select(.target_id == $id)] | length' "${matrix_path}" 2>/dev/null || echo "")"
  if [[ -z "${match_count}" ]]; then
    target_registry_config_error "target asset matrix is not valid JSON: ${matrix_path}"
    return 64
  fi

  if [[ "${match_count}" == "0" ]]; then
    return 1
  fi

  if [[ "${match_count}" != "1" ]]; then
    target_registry_config_error "target asset matrix has duplicate rows for target_id='${canonical_id}'"
    return 64
  fi

  jq -c --arg id "${canonical_id}" '.targets[] | select(.target_id == $id)' "${matrix_path}"
}

target_registry_get_execution_profile_json() {
  local execution_profile_id="${1:-}"
  local matrix_path
  local match_count

  if [[ -z "${execution_profile_id}" ]]; then
    target_registry_config_error "execution_profile_id is required"
    return 64
  fi

  target_registry_require_jq || return $?

  matrix_path="$(target_registry_execution_profile_matrix_path)"
  if [[ ! -f "${matrix_path}" ]]; then
    target_registry_config_error "runtime execution profile matrix not found: ${matrix_path}"
    return 64
  fi

  match_count="$(jq -r --arg id "${execution_profile_id}" '[.profiles[] | select(.execution_profile_id == $id)] | length' "${matrix_path}" 2>/dev/null || echo "")"
  if [[ -z "${match_count}" ]]; then
    target_registry_config_error "runtime execution profile matrix is not valid JSON: ${matrix_path}"
    return 64
  fi

  if [[ "${match_count}" == "0" ]]; then
    return 1
  fi

  if [[ "${match_count}" != "1" ]]; then
    target_registry_config_error "runtime execution profile matrix has duplicate rows for execution_profile_id='${execution_profile_id}'"
    return 64
  fi

  jq -c --arg id "${execution_profile_id}" '.profiles[] | select(.execution_profile_id == $id)' "${matrix_path}"
}

target_registry_make_abs_path() {
  local maybe_path="${1:-}"
  local root

  if [[ -z "${maybe_path}" ]]; then
    echo ""
    return 0
  fi

  if [[ "${maybe_path}" == /* ]]; then
    echo "${maybe_path}"
    return 0
  fi

  root="$(target_registry_root)"
  echo "${root}/${maybe_path}"
}

target_registry_matrix_row_json() {
  local target_id_or_legacy="${1:-}"
  local canonical_id
  local row_json

  if [[ -z "${target_id_or_legacy}" ]]; then
    target_registry_config_error "target_id is required"
    return 64
  fi

  target_registry_require_jq || return $?

  canonical_id="$(normalize_target_alias "${target_id_or_legacy}")"
  if ! row_json="$(target_registry_get_matrix_row_json "${canonical_id}")"; then
    if [[ "$?" -eq 1 ]]; then
      target_registry_config_error "unknown target_id '${target_id_or_legacy}' (canonical='${canonical_id}')"
      return 64
    fi
    return 64
  fi

  echo "${row_json}"
}

set_target_contract_fields() {
  TARGET_CONTRACT_TARGET_ID="$1"
  TARGET_CONTRACT_TIER="$2"
  TARGET_CONTRACT_PROTOCOL_MODE="$3"
  TARGET_CONTRACT_LAUNCHER_MODE="$4"
  TARGET_CONTRACT_ENV_FILE="$5"
  TARGET_CONTRACT_PROFILE_ID="$6"
  TARGET_CONTRACT_COMPOSE_FILE="$7"
  TARGET_CONTRACT_JAR_PATH="$8"
  TARGET_CONTRACT_HEALTH_URL="$9"
}

resolve_target_contract() {
  local target_id_or_legacy="${1:-}"
  local canonical_id
  local row_json
  local asset_state
  local non_runnable_reason
  local missing_assets
  local launcher_mode
  local env_file
  local profile_id
  local compose_file
  local jar_path
  local health_url
  local tier
  local protocol_mode

  if [[ -z "${target_id_or_legacy}" ]]; then
    target_registry_config_error "target_id is required"
    return 64
  fi

  target_registry_require_jq || return $?

  TARGET_CONTRACT_INPUT_ID="${target_id_or_legacy}"
  canonical_id="$(normalize_target_alias "${target_id_or_legacy}")"

  if ! row_json="$(target_registry_get_matrix_row_json "${canonical_id}")"; then
    if [[ "$?" -eq 1 ]]; then
      target_registry_config_error "unknown target_id '${target_id_or_legacy}' (canonical='${canonical_id}')"
      return 64
    fi
    return 64
  fi

  asset_state="$(jq -r '.asset_state' <<<"${row_json}")"
  if [[ "${asset_state}" != "runnable" ]]; then
    non_runnable_reason="$(jq -r '.non_runnable_reason // "non_runnable target"' <<<"${row_json}")"
    missing_assets="$(jq -r '.missing_assets // [] | join(",")' <<<"${row_json}")"
    if [[ -n "${missing_assets}" ]]; then
      target_registry_config_error "target_id '${canonical_id}' is non_runnable: ${non_runnable_reason}; missing_assets=${missing_assets}"
    else
      target_registry_config_error "target_id '${canonical_id}' is non_runnable: ${non_runnable_reason}"
    fi
    return 65
  fi

  tier="$(jq -r '.tier' <<<"${row_json}")"
  protocol_mode="$(jq -r '.protocol_mode' <<<"${row_json}")"
  launcher_mode="$(jq -r '.launcher_mode' <<<"${row_json}")"
  env_file="$(jq -r '.env_file' <<<"${row_json}")"
  profile_id="$(jq -r '.profile_id' <<<"${row_json}")"
  compose_file="$(jq -r '.compose_file' <<<"${row_json}")"
  jar_path="$(jq -r '.jar_path' <<<"${row_json}")"
  health_url="$(jq -r '.health_url' <<<"${row_json}")"

  set_target_contract_fields \
    "${canonical_id}" \
    "${tier}" \
    "${protocol_mode}" \
    "${launcher_mode}" \
    "$(target_registry_make_abs_path "${env_file}")" \
    "${profile_id}" \
    "$(target_registry_make_abs_path "${compose_file}")" \
    "$(target_registry_make_abs_path "${jar_path}")" \
    "${health_url}"

  return 0
}

assert_target_contract_complete() {
  local field
  local -a missing=()
  for field in \
    TARGET_CONTRACT_TARGET_ID \
    TARGET_CONTRACT_TIER \
    TARGET_CONTRACT_PROTOCOL_MODE \
    TARGET_CONTRACT_LAUNCHER_MODE \
    TARGET_CONTRACT_ENV_FILE \
    TARGET_CONTRACT_PROFILE_ID \
    TARGET_CONTRACT_COMPOSE_FILE \
    TARGET_CONTRACT_JAR_PATH \
    TARGET_CONTRACT_HEALTH_URL; do
    if [[ -z "${!field+x}" ]]; then
      missing+=("${field}")
    fi
  done

  for field in \
    TARGET_CONTRACT_TARGET_ID \
    TARGET_CONTRACT_TIER \
    TARGET_CONTRACT_PROTOCOL_MODE \
    TARGET_CONTRACT_LAUNCHER_MODE \
    TARGET_CONTRACT_ENV_FILE \
    TARGET_CONTRACT_PROFILE_ID \
    TARGET_CONTRACT_HEALTH_URL; do
    if [[ -z "${!field}" ]]; then
      missing+=("${field}=empty")
    fi
  done

  case "${TARGET_CONTRACT_LAUNCHER_MODE}" in
    docker)
      if [[ -z "${TARGET_CONTRACT_COMPOSE_FILE}" ]]; then
        missing+=("TARGET_CONTRACT_COMPOSE_FILE=empty for docker launcher")
      fi
      ;;
    jar)
      if [[ -z "${TARGET_CONTRACT_JAR_PATH}" ]]; then
        missing+=("TARGET_CONTRACT_JAR_PATH=empty for jar launcher")
      fi
      ;;
    external)
      # No additional required path fields.
      ;;
    *)
      missing+=("TARGET_CONTRACT_LAUNCHER_MODE=invalid(${TARGET_CONTRACT_LAUNCHER_MODE:-missing})")
      ;;
  esac

  case "${TARGET_CONTRACT_PROTOCOL_MODE}" in
    h1|h2|h2c|h3) ;;
    *) missing+=("TARGET_CONTRACT_PROTOCOL_MODE=invalid(${TARGET_CONTRACT_PROTOCOL_MODE:-missing})") ;;
  esac

  case "${TARGET_CONTRACT_TIER}" in
    community|enterprise) ;;
    *) missing+=("TARGET_CONTRACT_TIER=invalid(${TARGET_CONTRACT_TIER:-missing})") ;;
  esac

  if [[ ${#missing[@]} -gt 0 ]]; then
    target_registry_config_error "target contract incomplete for '${TARGET_CONTRACT_INPUT_ID:-unknown}': ${missing[*]}"
    return 66
  fi

  return 0
}

target_contract_to_json() {
  if ! command -v jq >/dev/null 2>&1; then
    target_registry_config_error "jq is required to serialize target contract JSON"
    return 67
  fi

  jq -n \
    --arg target_id "${TARGET_CONTRACT_TARGET_ID}" \
    --arg tier "${TARGET_CONTRACT_TIER}" \
    --arg protocol_mode "${TARGET_CONTRACT_PROTOCOL_MODE}" \
    --arg launcher_mode "${TARGET_CONTRACT_LAUNCHER_MODE}" \
    --arg env_file "${TARGET_CONTRACT_ENV_FILE}" \
    --arg profile_id "${TARGET_CONTRACT_PROFILE_ID}" \
    --arg compose_file "${TARGET_CONTRACT_COMPOSE_FILE}" \
    --arg jar_path "${TARGET_CONTRACT_JAR_PATH}" \
    --arg health_url "${TARGET_CONTRACT_HEALTH_URL}" \
  '{
    target_id: $target_id,
    tier: $tier,
    protocol_mode: $protocol_mode,
    launcher_mode: $launcher_mode,
    env_file: $env_file,
    profile_id: $profile_id,
    compose_file: $compose_file,
    jar_path: $jar_path,
    health_url: $health_url
  }'
}