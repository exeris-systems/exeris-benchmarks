#!/usr/bin/env bash
# Entry condition for any campaign arm: boot it against the real database and prove it serves
# the contract, BEFORE committing machine-time to a campaign.
#
# WHY THIS EXISTS
# On 2026-08-06 four consecutive arm failures passed jar inspection and died at startup:
#   - no SLF4J provider   -> Boot printed its banner on stdout and reported the failure through
#                            SLF4J, so the process died with no error text anywhere
#   - no PersistenceEngineProvider bean (exeris.runtime.tx.enabled has no matchIfMissing)
#   - no Jackson 2 ObjectMapper bean under Boot 4
#   - no Jackson 3 ObjectMapper bean either, because JacksonAutoConfiguration does not run
#     under spring.main.web-application-type=none
# A fifth defect would not have failed at all: exeris-community would have run at the runner's
# default 256 MB heap against three arms at 1280 MB and quietly reported a ~3x RSS difference
# as a finding.
#
# Every one of those is invisible to `unzip -l`. The only thing that catches them is starting
# the process and asking it for a row. That is all this script does.
#
# WHAT IT CHECKS, per arm
#   1. the process starts and stays up
#   2. /health answers
#   3. the heavy contract answers 200 with a non-empty body
#   4. the light contract answers 200 with a non-empty body   (a pre-#50 runtime 404s here,
#      and a 404 is indistinguishable from "no such row" — this is why it is checked explicitly)
#   5. the launched JVM carries the heap the caller intended  (the silent-posture defect above)
#
# It also records the body checksum per arm. Arms that are supposed to issue byte-identical SQL
# should return byte-identical bodies; a mismatch means the comparison has silently become a
# query-plan or serialisation comparison. The script reports the checksums and does NOT fail on
# a difference — deciding which arms must agree is the caller's job, not this script's.
#
# RUN IT AS THE USER THE CAMPAIGN RUNS AS.
# The targets write their logs to fixed paths in /tmp. On a box with fs.protected_regular=2
# (the default on modern kernels) a different user — INCLUDING root — cannot truncate a log
# file another user already created there, so the target dies instantly on redirect with
# `Permission denied` and every symptom points at the application instead. Verified on the
# perf box 2026-08-06: `ssh perf-box` lands as root, the campaign user is bench.
#
# Usage:
#   tools/preflight-ladder-arms.sh                       # the four ladder arms
#   tools/preflight-ladder-arms.sh spring-hibernate:9001 # explicit id:port list
#
# Exit 0 = every arm checked is fit to enter a campaign.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MATRIX="${REPO_ROOT}/runtime/drivers/target-asset-matrix.json"

# Campaign posture. Kept equal to scripts/run-spring-triad-campaign.sh on purpose: booting an
# arm under a different posture than the campaign will use proves less than it appears to.
: "${EXERIS_DB_JDBC_URL:=jdbc:postgresql://localhost:5432/benchmark_db?prepareThreshold=1&defaultRowFetchSize=0&adaptiveFetch=false&preferQueryMode=extended}"
: "${EXERIS_DB_USERNAME:=benchmark}"
: "${EXERIS_DB_PASSWORD:=benchmark}"
: "${EXERIS_DB_POOL_MIN_SIZE:=16}"
: "${EXERIS_DB_POOL_MAX_SIZE:=256}"
: "${SERVER_CPU_AFFINITY:=0-1,8-9}"
: "${PREFLIGHT_HEAP_MB:=1280}"
: "${PREFLIGHT_BOOT_TIMEOUT:=90}"
export EXERIS_DB_JDBC_URL EXERIS_DB_USERNAME EXERIS_DB_PASSWORD
export EXERIS_DB_POOL_MIN_SIZE EXERIS_DB_POOL_MAX_SIZE SERVER_CPU_AFFINITY

# ALL THREE families, so one setting covers every arm this repo can put in a pair.
#
# QUARKUS_JAVA_OPTS was missing until 2026-08-07, and its absence was not cosmetic: a Quarkus arm
# launched with no heap flags at all, so the -Xmx assertion below could only ever FAIL for it —
# the tool would refuse a perfectly good arm while reporting a heap mismatch. Worse in the other
# direction: had the assertion been skipped for Quarkus, an arm would have entered a cross-stack
# pair at the JVM default heap against Spring arms at 1280m, which is exactly the defect
# (exeris-community at 256m vs 1280m) this tool was written to catch. Iso-heap matters MOST on
# cross-stack pairs like quarkus-tuned__spring-on-exeris-pure-native, where footprint is one of
# the reported axes.
export SPRING_JAVA_OPTS="-Xms${PREFLIGHT_HEAP_MB}m -Xmx${PREFLIGHT_HEAP_MB}m"
export EXERIS_JAVA_OPTS="-Xms${PREFLIGHT_HEAP_MB}m -Xmx${PREFLIGHT_HEAP_MB}m"
export QUARKUS_JAVA_OPTS="-Xms${PREFLIGHT_HEAP_MB}m -Xmx${PREFLIGHT_HEAP_MB}m"
export EXERIS_ENABLE_TELEMETRY_SUBSYSTEM=false
export EXERIS_TELEMETRY_JFR_ENABLED=false

HEAVY_PATH="/api/v1/users"
LIGHT_PATH="/api/v1/user?id=1"

DEFAULT_ARMS=(
  "spring-hibernate:9001"
  "spring-on-exeris-pure:9005"
  "spring-on-exeris-pure-native:9006"
  "exeris-community:9000"
)

if [[ $# -gt 0 ]]; then
  ARMS=("$@")
else
  ARMS=("${DEFAULT_ARMS[@]}")
fi

failures=0
declare -A HEAVY_SUM=() LIGHT_SUM=()

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

stop_arm() {
  local pid_file=$1 port=$2
  if [[ -f "$pid_file" ]]; then
    local pid; pid="$(cat "$pid_file" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
  fi
  # Belt and braces: match on the listening socket, never on a `pgrep -f` pattern that could
  # also match this script's own command line (that mistake killed the controlling shell once).
  local lpid
  lpid="$(ss -ltnp 2>/dev/null | grep -oE "[:.]${port}\b.*pid=[0-9]+" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
  [[ -n "$lpid" ]] && kill "$lpid" 2>/dev/null
  for _ in $(seq 1 20); do
    ss -ltn 2>/dev/null | grep -qE "[:.]${port}\b" || return 0
    sleep 0.5
  done
  [[ -n "${lpid:-}" ]] && kill -9 "$lpid" 2>/dev/null
  return 0
}

check_arm() {
  local target_id=$1 port=$2
  local arm_failures=0
  echo ""
  echo "=============================================================="
  echo "PREFLIGHT ${target_id}  (port ${port})"
  echo "=============================================================="

  local env_file
  env_file="$(jq -r --arg id "$target_id" \
    '.targets[] | select(.target_id == $id) | .env_file // ""' "$MATRIX" 2>/dev/null)"
  if [[ -z "$env_file" || ! -f "$env_file" ]]; then
    red "FAIL[$target_id]: no usable env_file in target-asset-matrix.json (got '${env_file}')"
    return 1
  fi
  echo "  env_file: ${env_file}"

  if ss -ltn 2>/dev/null | grep -qE "[:.]${port}\b"; then
    red "FAIL[$target_id]: port ${port} is already in use — refusing to test against a stale process"
    return 1
  fi

  local pid_file; pid_file="$(mktemp)"
  export EXTERNAL_PID_FILE="$pid_file"

  local start_cmd
  start_cmd="$(set -a; source "$env_file" >/dev/null 2>&1; printf '%s' "${EXTERNAL_START_CMD:-}")"
  if [[ -z "$start_cmd" ]]; then
    red "FAIL[$target_id]: env_file defines no EXTERNAL_START_CMD"
    rm -f "$pid_file"; return 1
  fi

  # Capture the launcher's own stderr rather than discarding it. The first version of this
  # script sent it to /dev/null and reported "/health did not answer" for what was actually
  # `Permission denied` on the target's log file — running as root, which cannot truncate a
  # bench-owned file in /tmp under fs.protected_regular=2. The script existed to stop exactly
  # that kind of silent misattribution and was committing it itself.
  #
  # set +u inside the subshell: env files legitimately reference variables the caller may not
  # have set, and an unbound-variable abort here would look identical to a boot failure.
  local launch_err; launch_err="$(mktemp)"
  ( set +u; set -a; source "$env_file" >/dev/null 2>&1; set +a
    export EXTERNAL_PID_FILE="$pid_file"
    eval "$EXTERNAL_START_CMD" ) >/dev/null 2>"$launch_err"

  if [[ -s "$launch_err" ]]; then
    echo "  --- launcher stderr ---"
    sed 's/^/    /' "$launch_err"
  fi

  # 1 + 2: does it come up at all?
  local up=0 waited=0
  while (( waited < PREFLIGHT_BOOT_TIMEOUT )); do
    if curl -fsS --max-time 3 "http://localhost:${port}/health" >/dev/null 2>&1; then up=1; break; fi
    sleep 2; waited=$((waited + 2))
  done

  if (( up == 0 )); then
    red "FAIL[$target_id]: /health did not answer within ${PREFLIGHT_BOOT_TIMEOUT}s"
    echo "  --- last 25 lines of the target log (this is where the silent failures show) ---"
    local log; log="$(printf '%s' "$start_cmd" | grep -oE '> ?/tmp/[^ ]+\.log' | tr -d '> ' | head -1)"
    [[ -n "$log" && -f "$log" ]] && tail -25 "$log" | sed 's/^/    /' || echo "    (no log file found in EXTERNAL_START_CMD)"
    stop_arm "$pid_file" "$port"; rm -f "$pid_file" "$launch_err"; return 1
  fi
  rm -f "$launch_err"
  green "  PASS  /health answered after ${waited}s"

  # 5: is the posture the one the caller asked for? Checked while the process is still up.
  local lpid cmdline
  lpid="$(ss -ltnp 2>/dev/null | grep -oE "[:.]${port}\b.*pid=[0-9]+" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
  if [[ -n "$lpid" ]]; then
    cmdline="$(tr '\0' ' ' < "/proc/${lpid}/cmdline" 2>/dev/null)"
    if [[ "$cmdline" == *"-Xmx${PREFLIGHT_HEAP_MB}m"* ]]; then
      green "  PASS  launched with -Xmx${PREFLIGHT_HEAP_MB}m"
    else
      red   "  FAIL  heap posture mismatch: expected -Xmx${PREFLIGHT_HEAP_MB}m"
      echo  "        actual: $(printf '%s' "$cmdline" | grep -oE '\-Xm[sx][0-9]+m' | tr '\n' ' ')"
      echo  "        This is the defect that does NOT crash: the arm serves correctly and"
      echo  "        reports a footprint from a posture nobody chose."
      arm_failures=$((arm_failures + 1))
    fi
  fi

  # 3 + 4: does it serve BOTH contracts? Heavy-passes-light-404s has TWO distinct causes and the
  # hint below must not collapse them — see the arm-family branch at the 404.
  local kind path code body
  for kind in heavy light; do
    [[ "$kind" == heavy ]] && path="$HEAVY_PATH" || path="$LIGHT_PATH"
    body="$(curl -sS --max-time 15 -w '\n%{http_code}' "http://localhost:${port}${path}" 2>/dev/null)"
    code="$(printf '%s' "$body" | tail -1)"
    body="$(printf '%s' "$body" | head -n -1)"
    if [[ "$code" != "200" ]]; then
      red "  FAIL  ${kind} ${path} -> HTTP ${code:-<none>}"
      # The pre-#50 hint is Exeris-SPECIFIC and was previously printed for every arm. On
      # quarkus-tuned (2026-08-07) that misattributed a 25-day-stale jar — the light endpoint had
      # simply not been built yet — to a runtime bug in a runtime that arm does not even use. A
      # preflight written to stop silent misattribution must not commit it in its own diagnostics.
      if [[ "$kind" == light && "$code" == "404" ]]; then
        case "$target_id" in
          spring-on-exeris*|exeris-*)
            echo "        404 on light is the pre-#50 signature: the query string is not stripped."
            echo "        Check the runtime build in the env file before suspecting the app."
            ;;
          *)
            echo "        This arm does not run exeris-spring-runtime, so #50 is NOT the explanation."
            echo "        Most likely a stale build: compare the jar's mtime against src/."
            ;;
        esac
      fi
      arm_failures=$((arm_failures + 1))
      continue
    fi
    if [[ -z "$body" || "$body" == "[]" || "$body" == "{}" ]]; then
      red "  FAIL  ${kind} ${path} -> 200 but empty body (${body:-<empty>}) — the DB has no seed data"
      arm_failures=$((arm_failures + 1))
      continue
    fi
    local sum; sum="$(printf '%s' "$body" | sha256sum | cut -c1-16)"
    green "  PASS  ${kind} ${path} -> 200, $(printf '%s' "$body" | wc -c) bytes, sha=${sum}"
    if [[ "$kind" == heavy ]]; then HEAVY_SUM[$target_id]="$sum"; else LIGHT_SUM[$target_id]="$sum"; fi
  done

  stop_arm "$pid_file" "$port"
  rm -f "$pid_file"

  if (( arm_failures > 0 )); then
    red "RESULT[$target_id]: ${arm_failures} problem(s) — NOT fit to enter a campaign"
    return 1
  fi
  green "RESULT[$target_id]: fit to enter a campaign"
  return 0
}

for entry in "${ARMS[@]}"; do
  check_arm "${entry%%:*}" "${entry##*:}" || failures=$((failures + 1))
done

echo ""
echo "=============================================================="
echo "RESPONSE EQUIVALENCE (reported, not enforced)"
echo "=============================================================="
echo "  Arms declared to issue byte-identical SQL should agree here. A difference means the"
echo "  pair measures serialisation or query plan as well as the axis under test."
for kind in heavy light; do
  echo "  ${kind}:"
  if [[ "$kind" == heavy ]]; then
    for k in "${!HEAVY_SUM[@]}"; do printf '    %-32s %s\n' "$k" "${HEAVY_SUM[$k]}"; done
  else
    for k in "${!LIGHT_SUM[@]}"; do printf '    %-32s %s\n' "$k" "${LIGHT_SUM[$k]}"; done
  fi
done

echo ""
if (( failures > 0 )); then
  red "PREFLIGHT FAILED: ${failures} arm(s) unfit. Do not start the campaign."
  exit 1
fi
green "PREFLIGHT PASSED: all ${#ARMS[@]} arm(s) booted, served both contracts, and match the intended posture."
exit 0
