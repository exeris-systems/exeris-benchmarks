#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MATRIX_PATH="${REPO_ROOT}/runtime/drivers/target-asset-matrix.json"

# Runnable targets listed here are intentionally baseline-only and are not part
# of any scenario comparative manifest.
JUSTIFIED_UNUSED_RUNNABLE_TARGETS=(
  "exeris-e2e-community-h2"
)

fail_count=0
warn_count=0

pass() {
  echo "PASS: $1"
}

fail() {
  echo "FAIL: $1" >&2
  fail_count=$((fail_count + 1))
}

warn() {
  echo "WARN: $1"
  warn_count=$((warn_count + 1))
}

matrix_path_to_abs() {
  local path_value="$1"
  if [[ -z "${path_value}" ]]; then
    echo ""
    return 0
  fi

  if [[ "${path_value}" = /* ]]; then
    echo "${path_value}"
  else
    echo "${REPO_ROOT}/${path_value}"
  fi
}

contains_justified_unused() {
  local needle="$1"
  local item
  for item in "${JUSTIFIED_UNUSED_RUNNABLE_TARGETS[@]}"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 2
fi

if [[ ! -f "${MATRIX_PATH}" ]]; then
  echo "ERROR: Matrix not found at ${MATRIX_PATH}" >&2
  exit 2
fi

if jq empty "${MATRIX_PATH}" >/dev/null 2>&1; then
  pass "matrix is valid JSON"
else
  fail "matrix is invalid JSON"
fi

if jq -e '
  .schema_version == "1" and
  (.targets | type == "array") and
  (.targets | all(.[];
    (.target_id | type == "string" and length > 0) and
    (.tier | IN("community", "enterprise")) and
    (.protocol_mode | IN("h1", "h2", "h2c", "h3")) and
    (.launcher_mode | IN("docker", "jar", "external")) and
    (.env_file | type == "string") and
    (.profile_id | type == "string" and length > 0) and
    (.compose_file | type == "string") and
    (.jar_path | type == "string") and
    (.health_url | type == "string" and length > 0) and
    (.asset_state | IN("runnable", "non_runnable")) and
    (.eligibility_class | IN("baseline-candidate", "locality-research", "non-runnable")) and
    (.missing_assets | type == "array") and
    (.non_runnable_reason | type == "string")
  ))
' "${MATRIX_PATH}" >/dev/null; then
  pass "matrix shape and enums are valid"
else
  fail "matrix shape or enum values are invalid"
fi

total_ids="$(jq '.targets | length' "${MATRIX_PATH}")"
unique_ids="$(jq '[.targets[].target_id] | unique | length' "${MATRIX_PATH}")"
if [[ "${total_ids}" == "${unique_ids}" ]]; then
  pass "target_id values are unique"
else
  fail "duplicate target_id entries found (${total_ids} rows, ${unique_ids} unique)"
fi

mapfile -t scenario_manifest_paths < <(find "${REPO_ROOT}/scenarios" -name comparative-pair-manifest.json -type f | sort)
if [[ ${#scenario_manifest_paths[@]} -eq 0 ]]; then
  fail "no comparative-pair-manifest.json files found under scenarios/"
fi

scenario_targets_tmp="$(mktemp)"
trap 'rm -f "${scenario_targets_tmp}"' EXIT

for manifest_path in "${scenario_manifest_paths[@]}"; do
  if ! jq -e '.compatible_targets | type == "array"' "${manifest_path}" >/dev/null; then
    fail "compatible_targets missing or invalid in ${manifest_path}"
    continue
  fi
  jq -r '.compatible_targets[].target_id' "${manifest_path}" >> "${scenario_targets_tmp}"
done

sort -u "${scenario_targets_tmp}" -o "${scenario_targets_tmp}"
mapfile -t scenario_targets < "${scenario_targets_tmp}"

for target_id in "${scenario_targets[@]}"; do
  if jq -e --arg id "${target_id}" '.targets[] | select(.target_id == $id)' "${MATRIX_PATH}" >/dev/null; then
    pass "scenario compatible target present in matrix: ${target_id}"
  else
    fail "scenario compatible target missing from matrix: ${target_id}"
  fi
done

mapfile -t runnable_targets < <(jq -r '.targets[] | select(.asset_state == "runnable") | .target_id' "${MATRIX_PATH}" | sort)
for target_id in "${runnable_targets[@]}"; do
  eligibility_class="$(jq -r --arg id "${target_id}" '.targets[] | select(.target_id == $id) | .eligibility_class' "${MATRIX_PATH}")"
  if grep -Fxq "${target_id}" "${scenario_targets_tmp}"; then
    pass "runnable target appears in compatible_targets: ${target_id}"
  elif [[ "${eligibility_class}" == "locality-research" ]]; then
    pass "runnable target explicitly scoped to locality research: ${target_id}"
  elif contains_justified_unused "${target_id}"; then
    pass "runnable target justified as temporarily unused: ${target_id}"
  else
    fail "runnable target not referenced by any compatible_targets and not justified: ${target_id}"
  fi
done

while IFS= read -r target_id; do
  launcher_mode="$(jq -r --arg id "${target_id}" '.targets[] | select(.target_id == $id) | .launcher_mode' "${MATRIX_PATH}")"
  eligibility_class="$(jq -r --arg id "${target_id}" '.targets[] | select(.target_id == $id) | .eligibility_class' "${MATRIX_PATH}")"
  env_file="$(jq -r --arg id "${target_id}" '.targets[] | select(.target_id == $id) | .env_file' "${MATRIX_PATH}")"
  profile_id="$(jq -r --arg id "${target_id}" '.targets[] | select(.target_id == $id) | .profile_id' "${MATRIX_PATH}")"
  health_url="$(jq -r --arg id "${target_id}" '.targets[] | select(.target_id == $id) | .health_url' "${MATRIX_PATH}")"
  compose_file="$(jq -r --arg id "${target_id}" '.targets[] | select(.target_id == $id) | .compose_file' "${MATRIX_PATH}")"
  jar_path="$(jq -r --arg id "${target_id}" '.targets[] | select(.target_id == $id) | .jar_path' "${MATRIX_PATH}")"

  if [[ -z "${env_file}" || -z "${profile_id}" || -z "${health_url}" ]]; then
    fail "runnable target has empty required core fields: ${target_id}"
    continue
  fi

  env_abs="$(matrix_path_to_abs "${env_file}")"
  if [[ ! -f "${env_abs}" ]]; then
    fail "runnable target env_file does not exist: ${target_id} (${env_file})"
  else
    pass "runnable target env_file exists: ${target_id}"
  fi

  case "${launcher_mode}" in
    docker)
      if [[ -z "${compose_file}" ]]; then
        fail "runnable docker target has empty compose_file: ${target_id}"
      else
        compose_abs="$(matrix_path_to_abs "${compose_file}")"
        if [[ -f "${compose_abs}" ]]; then
          pass "runnable docker target compose_file exists: ${target_id}"
        else
          fail "runnable docker target compose_file does not exist: ${target_id} (${compose_file})"
        fi
      fi
      ;;
    jar)
      if [[ -z "${jar_path}" ]]; then
        if [[ "${eligibility_class}" == "baseline-candidate" ]]; then
          fail "baseline-candidate runnable jar target has empty jar_path: ${target_id}"
        else
          warn "runnable jar target has empty jar_path (build-time-only allowed): ${target_id}"
        fi
      else
        jar_abs="$(matrix_path_to_abs "${jar_path}")"
        if [[ -f "${jar_abs}" ]]; then
          pass "runnable jar target jar_path exists: ${target_id}"
        else
          if [[ "${eligibility_class}" == "baseline-candidate" ]]; then
            fail "baseline-candidate runnable jar target jar_path does not exist: ${target_id} (${jar_path})"
          else
            warn "runnable jar target jar_path does not exist (build-time-only allowed): ${target_id} (${jar_path})"
          fi
        fi
      fi
      ;;
    external)
      pass "runnable external target has required launcher fields: ${target_id}"
      ;;
    *)
      fail "runnable target has unsupported launcher_mode: ${target_id} (${launcher_mode})"
      ;;
  esac
done < <(jq -r '.targets[] | select(.asset_state == "runnable") | .target_id' "${MATRIX_PATH}")

if [[ ${warn_count} -gt 0 ]]; then
  echo "Matrix verification emitted ${warn_count} warning(s)."
fi

if [[ ${fail_count} -gt 0 ]]; then
  echo "Matrix verification failed with ${fail_count} issue(s)." >&2
  exit 1
fi

echo "Matrix verification passed."
