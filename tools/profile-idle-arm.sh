#!/usr/bin/env bash
# profile-idle-arm.sh — record what a benchmark arm does when it is serving NOTHING.
#
# WHY
#
# The 2026-08-06 ladder measured, via the co-resident sampler, that an idle
# spring-on-exeris process burns 0.67-0.70 % of a 4-core pin against 0.04-0.05 % for Tomcat
# and for exeris-community — ~18x, split by hosting model rather than runtime family
# (docs/CLAIMS.md L8). The sampler says HOW MUCH. Nothing said WHAT.
#
# An idle process is the ideal profiling subject: with no traffic, whatever appears in the
# profile IS the answer, because nothing else is running.
#
# TWO THINGS THIS SCRIPT EXISTS TO GET RIGHT
#
# 1. THE NOISE FLOOR IS NOT OPTIONAL. On a loaded application JFR's overhead is ~1-2 % and
#    vanishes; on a process burning 0.027 cores the same ABSOLUTE overhead is proportionally
#    enormous, and settings=profile contributes its own periodic work (jdk.CPULoad every
#    second, the sampler thread, chunk rotation) which lands in the profile AS work. Read
#    naively, an idle profile reports JFR. So this script records the QUIET arms under
#    identical settings in the same invocation: their profiles are the instrument's floor, and
#    anything in a noisy arm's profile that is not also in theirs is signal. Do not run this
#    for one arm only — a single idle profile is uninterpretable.
#
# 2. SETTLE BEFORE RECORDING. Straight after boot a JVM is doing JIT compilation, class
#    loading and startup tasks — none of which is the steady-state idle behaviour the sampler
#    measured during a 15-minute window well after warmup. Default settle is 180 s.
#
# READING ORDER: park intervals BEFORE hot-methods.
# 0.027 cores over the window arrives as periodic wakeups. ExecutionSample catches them but
# smears them across frames; a thread parking on a FIXED interval is the signature of a timer
# rather than of work. Precedent in this lab: the triad report §7 identified Agroal pool
# housekeeping from "ThreadPark/JavaMonitorWait on agroal-* threads with 2-minute and
# exactly-2000 ms timers". "Exactly 2000 ms" is what names a timer; an averaged CPU figure
# never could.
#
# USAGE (run as the campaign user — the targets write logs to fixed /tmp paths)
#   tools/profile-idle-arm.sh <target_id:port> [<target_id:port> ...]
#
# Env: IDLE_SETTLE_SECONDS (180), IDLE_RECORD_SECONDS (120), IDLE_OUT_DIR

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SETTLE="${IDLE_SETTLE_SECONDS:-180}"
RECORD="${IDLE_RECORD_SECONDS:-120}"
OUT="${IDLE_OUT_DIR:-results/raw/idle-profile/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"

: "${EXERIS_DB_JDBC_URL:=jdbc:postgresql://localhost:5432/benchmark_db?prepareThreshold=1&defaultRowFetchSize=0&adaptiveFetch=false&preferQueryMode=extended}"
: "${EXERIS_DB_USERNAME:=benchmark}"
: "${EXERIS_DB_PASSWORD:=benchmark}"
: "${EXERIS_DB_POOL_MIN_SIZE:=16}"
: "${EXERIS_DB_POOL_MAX_SIZE:=256}"
# Same pin as a campaign: idle cost is reported as a fraction of this pin, so it must match.
: "${SERVER_CPU_AFFINITY:=0-1,8-9}"
: "${SPRING_JAVA_OPTS:=-Xms1280m -Xmx1280m}"
: "${BENCH_EXERIS_HEAP_MB:=1280}"
: "${EXERIS_JAVA_OPTS:=-Xms${BENCH_EXERIS_HEAP_MB}m -Xmx${BENCH_EXERIS_HEAP_MB}m}"
: "${QUARKUS_JAVA_OPTS:=-Xms1280m -Xmx1280m}"
export EXERIS_DB_JDBC_URL EXERIS_DB_USERNAME EXERIS_DB_PASSWORD \
       EXERIS_DB_POOL_MIN_SIZE EXERIS_DB_POOL_MAX_SIZE SERVER_CPU_AFFINITY \
       SPRING_JAVA_OPTS EXERIS_JAVA_OPTS QUARKUS_JAVA_OPTS

echo "settle=${SETTLE}s record=${RECORD}s out=${OUT}"
echo "arms: $*"
echo

for spec in "$@"; do
  target_id="${spec%%:*}"
  port="${spec##*:}"
  arm_out="${OUT}/${target_id}"
  mkdir -p "$arm_out"
  echo "=============================================================="
  echo "IDLE PROFILE: ${target_id} (port ${port})"
  echo "=============================================================="

  ./runtime/drivers/stop-target.sh "$target_id" >/dev/null 2>&1 || true
  sleep 2
  if ! ./runtime/drivers/start-target.sh "$target_id" > "${arm_out}/start.log" 2>&1; then
    echo "  SKIP: start-target failed (see ${arm_out}/start.log)"
    continue
  fi

  ready=0
  for _ in $(seq 1 90); do
    if curl -fsS --max-time 2 "http://localhost:${port}/health" >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
  done
  if [[ "$ready" -ne 1 ]]; then
    echo "  SKIP: /health never answered"
    ./runtime/drivers/stop-target.sh "$target_id" >/dev/null 2>&1 || true
    continue
  fi

  pid="$(ss -ltnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p {print $0}' | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
  if [[ -z "$pid" ]]; then
    echo "  SKIP: could not resolve pid on port ${port}"
    ./runtime/drivers/stop-target.sh "$target_id" >/dev/null 2>&1 || true
    continue
  fi
  echo "  pid=${pid}, settling ${SETTLE}s (JIT/classload/startup are NOT idle behaviour)"
  sleep "$SETTLE"

  # CPU over the recording window, from /proc, so the profile comes with the magnitude it is
  # explaining. utime+stime in clock ticks.
  read_cpu() { awk '{print $14+$15}' "/proc/${pid}/stat" 2>/dev/null || echo 0; }
  cpu0="$(read_cpu)"

  jcmd "$pid" "JFR.start name=idle settings=profile disk=true maxsize=64m" \
    > "${arm_out}/jfr-start.txt" 2>&1
  sleep "$RECORD"
  cpu1="$(read_cpu)"
  jcmd "$pid" "JFR.dump name=idle filename=${PWD}/${arm_out}/idle.jfr" >> "${arm_out}/jfr-stop.txt" 2>&1
  jcmd "$pid" "JFR.stop name=idle" >> "${arm_out}/jfr-stop.txt" 2>&1

  hz="$(getconf CLK_TCK 2>/dev/null || echo 100)"
  cores="$(awk -v a="$cpu0" -v b="$cpu1" -v hz="$hz" -v s="$RECORD" 'BEGIN{printf "%.5f",(b-a)/hz/s}')"
  threads="$(ls "/proc/${pid}/task" 2>/dev/null | wc -l)"
  rss_kb="$(awk '/^VmRSS:/{print $2}' "/proc/${pid}/status" 2>/dev/null || echo 0)"

  cat > "${arm_out}/idle-metrics.json" <<JSON
{
  "target_id": "${target_id}",
  "pid": ${pid},
  "settle_seconds": ${SETTLE},
  "record_seconds": ${RECORD},
  "idle_cores": ${cores},
  "idle_pct_of_4core_pin": $(awk -v c="$cores" 'BEGIN{printf "%.3f",c/4*100}'),
  "threads": ${threads},
  "rss_kb": ${rss_kb},
  "jfr_settings": "profile",
  "note": "CPU measured from /proc/<pid>/stat over exactly the JFR window, so the profile and the magnitude describe the same interval. This figure INCLUDES JFR's own overhead — compare against the quiet arms recorded in the same invocation, which are the instrument's noise floor."
}
JSON
  echo "  idle_cores=${cores} ($(awk -v c="$cores" 'BEGIN{printf "%.2f",c/4*100}')% of pin)  threads=${threads}  rss=$((rss_kb/1024))MB"

  ./runtime/drivers/stop-target.sh "$target_id" >/dev/null 2>&1 || true
  sleep 3
done

echo
echo "=============================================================="
echo "IDLE PROFILES COMPLETE — ${OUT}"
echo "Read park intervals FIRST, hot-methods second. The quiet arms are the floor."
echo "=============================================================="
