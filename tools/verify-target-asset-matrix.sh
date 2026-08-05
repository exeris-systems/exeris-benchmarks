#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MATRIX_PATH="${REPO_ROOT}/runtime/drivers/target-asset-matrix.json"

# Runnable targets listed here are intentionally baseline-only and are not part
# of any scenario comparative manifest.
#   spring-on-exeris: saga terminal-state metrics ineligible (flow-worker VT outside
#     compat provider scope); baseline request-path only.
#   quarkus-tuned: pure-JDBC, tuned transport (native epoll + native BoringSSL TLS)
#     counterpart of default-Quarkus quarkus-hibernate; app in flight, not yet promoted
#     to a comparative-pair-manifest (quarkus-hibernate__quarkus-tuned) as comparison_eligible.
#   restate: baseline-only per scenarios/e2e-shop-order-saga/CONTRACT-v2-IMPLEMENTATION.md
#     (anti-overclaim ledger, "No Restate comparisons"): not comparison-eligible until the
#     h1-facade-vs-h2c-canonical-contract protocol mismatch is resolved or scoped h1-vs-h1;
#     descriptive single-stack baseline runs only.
JUSTIFIED_UNUSED_RUNNABLE_TARGETS=(
  "spring-on-exeris"
  "quarkus-tuned"
  "restate"
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

# Extract the TCP port from an http(s) URL. Echoes nothing when the URL carries no
# explicit port or is not a literal (contains a shell expansion).
url_port() {
  local url="$1"
  [[ "${url}" == *'$'* ]] && return 0
  [[ "${url}" =~ ^https?://[^/:]+:([0-9]+) ]] || return 0
  echo "${BASH_REMATCH[1]}"
}

# The port a target's env file declares for its own health probe, if it declares one
# literally. Quarkus env files carry no HEALTH_URL (the driver derives it), so absence
# is normal and yields an empty result rather than a failure.
env_health_port() {
  local env_abs="$1" line
  line="$(grep -E '^[[:space:]]*HEALTH_URL=' "${env_abs}" 2>/dev/null | tail -1)" || return 0
  [[ -n "${line}" ]] || return 0
  url_port "${line#*=}"
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

    # Port-drift guard. A matrix health_url pointing at a port the target does not serve is
    # not a cosmetic defect: when the stale port belongs to the OTHER arm of a comparative
    # pair, the readiness gate probes the wrong process and passes while the target under
    # test is down — a false green that yields a published run measuring nothing.
    # (Regression: spring-on-exeris carried 9001, spring-hibernate's port, while its env
    # declares 9004.)
    matrix_port="$(url_port "${health_url}")"
    env_port="$(env_health_port "${env_abs}")"
    if [[ -n "${matrix_port}" && -n "${env_port}" ]]; then
      if [[ "${matrix_port}" == "${env_port}" ]]; then
        pass "health_url port agrees with env_file: ${target_id} (${matrix_port})"
      else
        fail "health_url port drift: ${target_id} matrix=${matrix_port} but ${env_file} declares ${env_port}"
      fi
    fi
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
      # This branch used to assert the fields without reading them. It is now an
      # actual check, because the omission it missed is expensive and silent:
      # start-target.sh runs EXTERNAL_START_CMD through `bash -lc`, and every
      # external env file ends that command with `echo $! > "$EXTERNAL_PID_FILE"`.
      # With the variable undeclared the redirect targets an empty path, bash
      # reports `line 1: : No such file or directory`, and start-target.sh calls
      # the target failed — but the JVM has ALREADY launched, so an orphan keeps
      # holding the port and the next attempt reports "port NNNN is occupied".
      # Nothing in the campaign fails outright; the affected pairs are simply
      # skipped and the run completes with fewer leaves than it should have.
      # (Regression: spring-on-exeris-pure shipped without it and cost a
      # four-hour campaign in which two of three pairs never ran.)
      if [[ -n "${env_file}" && -f "${env_abs}" ]]; then
        missing_launcher_fields=()
        grep -qE '^[[:space:]]*EXTERNAL_START_CMD=' "${env_abs}" \
          || missing_launcher_fields+=("EXTERNAL_START_CMD")
        if grep -q 'EXTERNAL_PID_FILE' "${env_abs}"; then
          grep -qE '^[[:space:]]*EXTERNAL_PID_FILE=' "${env_abs}" \
            || missing_launcher_fields+=("EXTERNAL_PID_FILE (referenced but never assigned)")
        else
          missing_launcher_fields+=("EXTERNAL_PID_FILE")
        fi
        if [[ ${#missing_launcher_fields[@]} -eq 0 ]]; then
          pass "runnable external target has required launcher fields: ${target_id}"
        else
          fail "runnable external target env_file is missing launcher fields: ${target_id} -> ${missing_launcher_fields[*]}"
        fi
      else
        pass "runnable external target has required launcher fields: ${target_id}"
      fi
      ;;
    *)
      fail "runnable target has unsupported launcher_mode: ${target_id} (${launcher_mode})"
      ;;
  esac
done < <(jq -r '.targets[] | select(.asset_state == "runnable") | .target_id' "${MATRIX_PATH}")

# Shared-port guard. Two runnable targets on the same health port cannot be launched
# together, and a readiness probe against that port cannot tell them apart. This is a
# warning rather than a failure: co-residency is only a problem for targets that some
# scenario actually pairs, and the matrix alone cannot decide that.
while IFS= read -r dup_port; do
  [[ -n "${dup_port}" ]] || continue
  dup_ids="$(jq -r --arg p ":${dup_port}/" \
    '[.targets[] | select(.asset_state == "runnable") | select(.health_url | contains($p)) | .target_id] | join(", ")' \
    "${MATRIX_PATH}")"
  warn "health_url port ${dup_port} is shared by multiple runnable targets: ${dup_ids}"
done < <(jq -r '[.targets[] | select(.asset_state == "runnable") | .health_url
                | capture("^https?://[^/:]+:(?<port>[0-9]+)").port]
               | group_by(.) | map(select(length > 1) | .[0]) | .[]' "${MATRIX_PATH}" 2>/dev/null)

if [[ ${warn_count} -gt 0 ]]; then
  echo "Matrix verification emitted ${warn_count} warning(s)."
fi

if [[ ${fail_count} -gt 0 ]]; then
  echo "Matrix verification failed with ${fail_count} issue(s)." >&2
  exit 1
fi

echo "Matrix verification passed."
