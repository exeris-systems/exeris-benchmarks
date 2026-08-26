#!/usr/bin/env bash
# Boot-verify every arm of the kernel-version axis before any campaign is allowed to run.
#
# Boot-verify is a hard entry condition in this repo, not a nicety. Inspecting a jar proves what
# was built; it does not prove the arm starts, binds, reaches its database, and serves the
# scenario's own endpoints. Defects that jar inspection cannot see have reached campaign start here
# before - a wrong heap size, a bootstrap-order failure, an arm that 404s the light contract.
#
# What this checks per arm:
#   1. the process starts and /health returns 200 within the timeout
#   2. it serves BOTH scenario contracts - the light single-row read and the aggregate read - with
#      a 200 and a non-empty body, and 404s a row that does not exist (a runtime that 404s the
#      light contract because it cannot parse a query string is indistinguishable from "no such
#      row" at the driver, which is exactly how a whole arm once went missing)
#   3. the RUNNING process is the arm it claims to be: /proc/<pid>/cmdline must name the arm's
#      staged jar and carry (or not carry) the preview flag, and /proc/<pid>/exe must resolve into
#      the arm's own JDK. Four arms share one staged jar and differ only by JDK and JVM flag, so
#      the jar path alone cannot tell them apart and a mis-launch would report several numbers for
#      one configuration while every gate passed.
#
# Usage: scripts/verify-kernel-version-axis-boot.sh [arm-target-id ...]     (default: all)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MANIFEST="runtime/drivers/kernel-version-axis-arms.json"

JDK25_HOME="${JDK25_HOME:-$HOME/.sdkman/candidates/java/25.0.3-tem}"
JDK26_HOME="${JDK26_HOME:-$HOME/.sdkman/candidates/java/26-oracle}"
JDK28_HOME="${JDK28_HOME:-$HOME/Pobrane/openjdk-28-ea+10_linux-x64_bin/jdk-28}"

EXERIS_DB_JDBC_URL="${EXERIS_DB_JDBC_URL:-jdbc:postgresql://localhost:5432/benchmark_db?prepareThreshold=1}"
EXERIS_DB_USERNAME="${EXERIS_DB_USERNAME:-benchmark}"
EXERIS_DB_PASSWORD="${EXERIS_DB_PASSWORD:-benchmark}"
BOOT_TIMEOUT_SECONDS="${BOOT_TIMEOUT_SECONDS:-60}"
LOG_DIR="${LOG_DIR:-/tmp/exeris-axis-bootverify}"

LIGHT_PATH="/api/v1/user?id=1"
AGGREGATE_PATH="/api/v1/users"
MISSING_PATH="/api/v1/user?id=999999"

mkdir -p "$LOG_DIR"

pass_count=0
fail_count=0
declare -a FAILED_ARMS=()

say()  { echo "$*"; }
ok()   { echo "  PASS  $*"; }
bad()  { echo "  FAIL  $*"; }

read_arms() {
  python3 - "$MANIFEST" "$@" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1]))
wanted = set(sys.argv[2:])
# Accept the arm letter as well as the target id, and refuse an argument that matches neither.
# A selector that silently matches nothing used to print "0 passed, 0 failed - cleared for a
# campaign", which is the exact opposite of what this script exists to say.
by_arm = {a["arm"]: a["target_id"] for a in manifest["arms"]}
ids = {a["target_id"] for a in manifest["arms"]}
resolved = set()
for w in wanted:
    if w in ids:
        resolved.add(w)
    elif w in by_arm:
        resolved.add(by_arm[w])
    else:
        sys.exit("unknown arm selector '%s'; known arms: %s (ids: %s)"
                 % (w, ", ".join(sorted(by_arm)), ", ".join(sorted(ids))))
for a in manifest["arms"]:
    if resolved and a["target_id"] not in resolved:
        continue
    print("\t".join([
        a["arm"], a["target_id"], str(a["port"]), a["staged_jar"],
        a["kernel_group_id"], a["kernel_version"], str(a["jdk_feature"]),
        a["jdk_home_var"], "yes" if a["enable_preview_flag"] else "no",
        str(a["app_compiler_release"]),
    ]))
PY
}

http_code() { curl -s -o "$2" -w '%{http_code}' --max-time 10 "$1" 2>/dev/null || echo "000"; }

verify_arm() {
  local arm="$1" target_id="$2" port="$3" jar="$4" group="$5" version="$6"
  local jdk_feature="$7" jdk_home_var="$8" want_preview="$9" app_release="${10}"

  local jdk_home="${!jdk_home_var}"
  local log_file="${LOG_DIR}/${target_id}.log"
  local issues=0

  say ""
  say "=== arm ${arm}  ${target_id}  (${group}:${version}, JDK ${jdk_feature}, preview flag=${want_preview}, app release ${app_release})"

  if [[ ! -x "$jdk_home/bin/java" ]]; then
    bad "no java at ${jdk_home} (set ${jdk_home_var})"
    fail_count=$((fail_count + 1)); FAILED_ARMS+=("$target_id"); return
  fi
  if [[ ! -f "$jar" ]]; then
    bad "staged jar missing: ${jar} - run scripts/build-kernel-version-axis-jars.sh first"
    fail_count=$((fail_count + 1)); FAILED_ARMS+=("$target_id"); return
  fi

  local -a preview_arg=()
  [[ "$want_preview" == "yes" ]] && preview_arg=(--enable-preview)

  EXERIS_PORT="$port" \
  EXERIS_HTTP_MAX_VERSION=HTTP_1_1 \
  EXERIS_HTTP_H2C_UPGRADE_ENABLED=false \
  EXERIS_DB_JDBC_URL="$EXERIS_DB_JDBC_URL" \
  EXERIS_DB_USERNAME="$EXERIS_DB_USERNAME" \
  EXERIS_DB_PASSWORD="$EXERIS_DB_PASSWORD" \
  EXERIS_DB_POOL_MIN_SIZE="${EXERIS_DB_POOL_MIN_SIZE:-16}" \
  EXERIS_DB_POOL_MAX_SIZE="${EXERIS_DB_POOL_MAX_SIZE:-256}" \
  EXERIS_ENABLE_TELEMETRY_SUBSYSTEM=false \
  EXERIS_TELEMETRY_JFR_ENABLED=false \
  nohup "$jdk_home/bin/java" \
    --add-opens java.base/sun.nio.ch=ALL-UNNAMED \
    --add-opens java.base/java.io=ALL-UNNAMED \
    --enable-native-access=ALL-UNNAMED \
    "${preview_arg[@]}" \
    -jar "$jar" > "$log_file" 2>&1 &
  local pid=$!

  local healthy=0 waited=0
  while [[ $waited -lt $BOOT_TIMEOUT_SECONDS ]]; do
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    if [[ "$(http_code "http://localhost:${port}/health" /dev/null)" == "200" ]]; then healthy=1; break; fi
    sleep 1; waited=$((waited + 1))
  done

  if [[ $healthy -ne 1 ]]; then
    bad "did not reach /health 200 within ${BOOT_TIMEOUT_SECONDS}s (log: ${log_file})"
    say "        last log lines:"
    tail -6 "$log_file" 2>/dev/null | sed 's/^/        | /'
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    fail_count=$((fail_count + 1)); FAILED_ARMS+=("$target_id"); return
  fi
  ok "health 200 after ${waited}s (pid ${pid})"

  # --- identity: is the process actually this arm? -----------------------------------------
  local cmdline; cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null)"
  local exe;     exe="$(readlink -f "/proc/${pid}/exe" 2>/dev/null)"

  if [[ "$cmdline" == *"$jar"* ]]; then
    ok "running jar matches ${jar}"
  else
    bad "running jar does NOT match ${jar}; cmdline was: ${cmdline}"; issues=$((issues + 1))
  fi

  local has_preview="no"; [[ "$cmdline" == *"--enable-preview"* ]] && has_preview="yes"
  if [[ "$has_preview" == "$want_preview" ]]; then
    ok "preview flag on the running process = ${has_preview}, as declared"
  else
    bad "preview flag mismatch: running=${has_preview}, declared=${want_preview}"; issues=$((issues + 1))
  fi

  if [[ "$exe" == "$(readlink -f "$jdk_home")"* ]]; then
    ok "JVM binary resolves inside ${jdk_home_var}"
  else
    bad "JVM binary ${exe} is outside ${jdk_home}; this arm would measure the wrong JDK"; issues=$((issues + 1))
  fi

  local reported_java; reported_java="$("$jdk_home/bin/java" -version 2>&1 | head -1)"
  if [[ "$reported_java" == *"\"${jdk_feature}"* ]]; then
    ok "JDK feature release ${jdk_feature} confirmed (${reported_java})"
  else
    bad "expected JDK ${jdk_feature}, got: ${reported_java}"; issues=$((issues + 1))
  fi

  # --- does it serve the scenario, not just /health? ---------------------------------------
  local body="${LOG_DIR}/${target_id}.body"
  local code
  code="$(http_code "http://localhost:${port}${LIGHT_PATH}" "$body")"
  if [[ "$code" == "200" && -s "$body" ]]; then
    ok "light contract ${LIGHT_PATH} -> 200, $(wc -c < "$body") bytes"
  else
    bad "light contract ${LIGHT_PATH} -> ${code} (a 404 here is the GET-with-query defect, not a missing row)"
    issues=$((issues + 1))
  fi

  code="$(http_code "http://localhost:${port}${AGGREGATE_PATH}" "$body")"
  if [[ "$code" == "200" && -s "$body" ]]; then
    ok "aggregate contract ${AGGREGATE_PATH} -> 200, $(wc -c < "$body") bytes"
  else
    bad "aggregate contract ${AGGREGATE_PATH} -> ${code}"; issues=$((issues + 1))
  fi

  code="$(http_code "http://localhost:${port}${MISSING_PATH}" /dev/null)"
  if [[ "$code" == "404" ]]; then
    ok "absent row ${MISSING_PATH} -> 404, so the light contract really is reading the row"
  else
    bad "absent row ${MISSING_PATH} -> ${code}, expected 404"; issues=$((issues + 1))
  fi

  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  if [[ $issues -eq 0 ]]; then
    say "  -> arm ${arm} (${target_id}) VERIFIED"
    pass_count=$((pass_count + 1))
  else
    say "  -> arm ${arm} (${target_id}) FAILED with ${issues} issue(s)"
    fail_count=$((fail_count + 1)); FAILED_ARMS+=("$target_id")
  fi
}

say "Kernel-version axis boot verification"
say "database: ${EXERIS_DB_JDBC_URL} as ${EXERIS_DB_USERNAME}"
say "logs:     ${LOG_DIR}/"

while IFS=$'\t' read -r arm target_id port jar group version jdk_feature jdk_home_var want_preview app_release; do
  [[ -n "$arm" ]] || continue
  verify_arm "$arm" "$target_id" "$port" "$jar" "$group" "$version" \
             "$jdk_feature" "$jdk_home_var" "$want_preview" "$app_release"
done < <(read_arms "$@")

# A run that verified nothing is not a pass. Without this the summary below reports the
# happy path for an empty arm set.
if (( pass_count + fail_count == 0 )); then
  say "no arms were verified - refusing to report the axis as cleared"
  exit 2
fi

say ""
say "============================================================"
say "boot verification: ${pass_count} passed, ${fail_count} failed"
if [[ $fail_count -gt 0 ]]; then
  say "failed arms: ${FAILED_ARMS[*]}"
  say "NO campaign may start on this axis until every arm passes."
  exit 1
fi
say "every arm verified - the axis is cleared for a campaign"
