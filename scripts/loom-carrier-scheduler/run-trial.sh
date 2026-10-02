#!/usr/bin/env bash
# run-trial.sh — one fresh-JVM trial of the loom-carrier-scheduler scenario.
#
# A trial is: start the mock backend, start the server under one scheduler arm, warm up closed-loop,
# then measure open-loop at a fixed rate (wrk2) or closed-loop at saturation (wrk), while recording
# per-thread CPU and placement. Every gate a trial can fail is written into trial.json; nothing is
# dropped silently, and a trial that fails a gate stays on disk so the campaign can show it.
#
# Usage:
#   scripts/loom-carrier-scheduler/run-trial.sh --kernel-dir <dir from build-kernel.sh> \
#       --arm A_iso|C_iso|D --backend jdk|kernel --rate <req/s>|max --out <dir> [options]
#
# Options (defaults are the CPU-bound regime on a 6-core / 12-thread host):
#   --connections 100   --load-threads 4      --warmup 10   --duration 30   (seconds)
#   --think-ms 1        --mock-threads 2      --poller-mode ""  (empty = JVM default)
#   --server-aux-cpus 0,6     JVM auxiliary threads and transport reactors
#   --carrier-cpus 2,3        scheduler carriers (one per CPU for arm D)
#   --mock-cpus 1,7           mock backend JVM
#   --load-cpus 4,5,10,11     load generator
#   --heap 1g
#   --profile none|cpu|wall   async-profiler on the server during the measurement window. A
#                             profiled trial is diagnostic only and is marked so: the profiler
#                             perturbs the latency it would explain.
#   --perf-sched              record scheduler switch/migration events for the server process
#                             (perf sched record) and derive each thread's run time per CPU.
#                             Diagnostic only, for the same reason. Needs perf_event_paranoid <= -1
#                             and read access to /sys/kernel/tracing.
#
# Environment: LOOM_JDK, WRK, WRK2, ASYNC_PROFILER (default <workspace>/tools/async-profiler).
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="$(cd "$BENCH_ROOT/.." && pwd)"
while [[ ! -d "$WORKSPACE_ROOT/tools/jdk-loom" && "$WORKSPACE_ROOT" != "/" ]]; do
  WORKSPACE_ROOT="$(dirname "$WORKSPACE_ROOT")"
done

LOOM_JDK="${LOOM_JDK:-$WORKSPACE_ROOT/tools/jdk-loom/current}"
WRK="${WRK:-$(command -v wrk)}"
# The snap-packaged wrk2 exits 1 without output on this host; the harness defaults to a source build
# of giltene/wrk2 under the workspace tools directory and records its commit.
WRK2="${WRK2:-$WORKSPACE_ROOT/tools/wrk2/wrk2}"
ASYNC_PROFILER="${ASYNC_PROFILER:-$WORKSPACE_ROOT/tools/async-profiler}"
APP_DIR="$BENCH_ROOT/targets/exeris-loom-scheduler-app"

KERNEL_DIR="" ARM="" BACKEND="" RATE="" OUT=""
CONNECTIONS=100 LOAD_THREADS=4 WARMUP=10 DURATION=30 THINK_MS=1 MOCK_THREADS=2 POLLER_MODE=""
SERVER_AUX_CPUS="0,6" CARRIER_CPUS="2,3" MOCK_CPUS="1,7" LOAD_CPUS="4,5,10,11" HEAP="1g" PROFILE="none"
SERVER_PORT="" MOCK_PORT="" PERF_SCHED="no"

die() { echo "run-trial: $*" >&2; exit 2; }
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kernel-dir) KERNEL_DIR="$2" ;;   --arm) ARM="$2" ;;            --backend) BACKEND="$2" ;;
    --rate) RATE="$2" ;;               --out) OUT="$2" ;;            --connections) CONNECTIONS="$2" ;;
    --load-threads) LOAD_THREADS="$2" ;; --warmup) WARMUP="$2" ;;    --duration) DURATION="$2" ;;
    --think-ms) THINK_MS="$2" ;;       --mock-threads) MOCK_THREADS="$2" ;;
    --poller-mode) POLLER_MODE="$2" ;; --server-aux-cpus) SERVER_AUX_CPUS="$2" ;;
    --carrier-cpus) CARRIER_CPUS="$2" ;; --mock-cpus) MOCK_CPUS="$2" ;; --load-cpus) LOAD_CPUS="$2" ;;
    --heap) HEAP="$2" ;;               --profile) PROFILE="$2" ;;
    --server-port) SERVER_PORT="$2" ;; --mock-port) MOCK_PORT="$2" ;;
    --perf-sched) PERF_SCHED="yes"; shift; continue ;;
    *) die "unknown option $1" ;;
  esac
  shift 2
done

[[ -n "$KERNEL_DIR" && -f "$KERNEL_DIR/kernel-cp.txt" ]] || die "--kernel-dir must point at a build-kernel.sh output"
[[ "$ARM" =~ ^(A_iso|C_iso|D)$ ]] || die "--arm must be A_iso, C_iso or D"
[[ "$BACKEND" =~ ^(jdk|kernel)$ ]] || die "--backend must be jdk or kernel"
[[ "$RATE" == "max" || "$RATE" =~ ^[0-9]+$ ]] || die "--rate must be max or an integer"
[[ "$PROFILE" =~ ^(none|cpu|wall)$ ]] || die "--profile must be none, cpu or wall"
[[ -n "$OUT" ]] || die "--out is required"
[[ -x "$LOOM_JDK/bin/java" ]] || die "no java under LOOM_JDK=$LOOM_JDK"
[[ -x "$WRK" ]] || die "wrk not found (warmup always uses it)"
[[ "$RATE" == "max" || -x "$WRK2" ]] || die "wrk2 not found at $WRK2"

IFS=, read -r -a CARRIERS <<<"$CARRIER_CPUS"
[[ ${#CARRIERS[@]} -ge 1 ]] || die "--carrier-cpus is empty"
CARRIER_COUNT=${#CARRIERS[@]}

mkdir -p "$OUT"
[[ -e "$OUT/trial.json" ]] && die "$OUT already holds a trial"

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
SERVER_PORT="${SERVER_PORT:-$(free_port)}"
MOCK_PORT="${MOCK_PORT:-$(free_port)}"

# --- build the app against this kernel build -------------------------------------------------
KERNEL_CP="$(cat "$KERNEL_DIR/kernel-cp.txt")"
APP_BUILD="$KERNEL_DIR/app"
if [[ ! -f "$APP_BUILD/app-classpath.txt" ]]; then
  mkdir -p "$APP_BUILD"
  KERNEL_CP="$KERNEL_CP" JAVA_HOME="$LOOM_JDK" APP_TARGET_DIR="$APP_BUILD" bash "$APP_DIR/build.sh" \
    >"$APP_BUILD/build.txt" 2>&1 || die "app build failed, see $APP_BUILD/build.txt"
fi
APP_CP="$(cat "$APP_BUILD/app-classpath.txt")"

# --- arm definition -----------------------------------------------------------------------------
SCHED_IMPL="eu.exeris.kernel.core.transport.scheduler.locality.ExerisCarrierScheduler"
ARM_OPTS=()
case "$ARM" in
  A_iso)
    ARM_OPTS=(-Djdk.virtualThreadScheduler.parallelism="$CARRIER_COUNT"
              -Djdk.virtualThreadScheduler.maxPoolSize="$CARRIER_COUNT")
    CARRIER_NAME_RE='^ForkJoinPool-[0-9]+-worker-[0-9]+$' ;;
  C_iso)
    ARM_OPTS=(-Djdk.virtualThreadScheduler.implClass="$SCHED_IMPL" -Dexeris.locality.allVthreads=true
              -Dexeris.transport.locality=true -Dexeris.carrier.count="$CARRIER_COUNT")
    CARRIER_NAME_RE='^exeris-carrier-[0-9]+$' ;;
  D)
    ARM_OPTS=(-Djdk.virtualThreadScheduler.implClass="$SCHED_IMPL" -Dexeris.locality.allVthreads=true
              -Dexeris.transport.locality=true -Dexeris.carrier.count="$CARRIER_COUNT"
              -Dexeris.carrier.affinity="$CARRIER_CPUS")
    CARRIER_NAME_RE='^exeris-carrier-[0-9]+$' ;;
esac
POLLER_OPTS=()
[[ -n "$POLLER_MODE" ]] && POLLER_OPTS=(-Djdk.pollerMode="$POLLER_MODE")
# Without these the Community transport cannot reach the socket descriptors and falls back to NIO,
# which is a different I/O path from the one under study; the transport gate checks which one ran.
ACCESS_OPTS=(--add-opens java.base/sun.nio.ch=ALL-UNNAMED --add-opens java.base/java.io=ALL-UNNAMED
  --enable-native-access=ALL-UNNAMED)
REACTOR_COUNT="$(awk -F, '{print NF}' <<<"$SERVER_AUX_CPUS")"

SERVER_CMD=("$LOOM_JDK/bin/java" -Xms"$HEAP" -Xmx"$HEAP" -XX:+UseParallelGC "${ACCESS_OPTS[@]}"
  "${ARM_OPTS[@]}" "${POLLER_OPTS[@]}"
  -Dexeris.transport.reactorCount="$REACTOR_COUNT" -Dexeris.reactor.affinity="$SERVER_AUX_CPUS"
  -Dexeris.http.port="$SERVER_PORT" -Dexeris.http.bindHost=127.0.0.1
  -Dloom.bench.backend="$BACKEND" -Dloom.bench.backend.host=127.0.0.1 -Dloom.bench.backend.port="$MOCK_PORT"
  -cp "$APP_CP" eu.exeris.benchmarks.targets.loomscheduler.LoomSchedulerServer)
MOCK_CMD=("$LOOM_JDK/bin/java" -Xms"$HEAP" -Xmx"$HEAP" -XX:+UseParallelGC "${ACCESS_OPTS[@]}"
  -Djdk.virtualThreadScheduler.parallelism="$MOCK_THREADS"
  -Dexeris.http.port="$MOCK_PORT" -Dexeris.http.bindHost=127.0.0.1 -Dloom.bench.mock.thinkMs="$THINK_MS"
  -cp "$APP_CP" eu.exeris.benchmarks.targets.loomscheduler.MockBackend)

PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  sleep 1
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill -9 "$p" 2>/dev/null || true; done
}
trap cleanup EXIT

wait_ready() {  # <file> <pattern> <pid> <what>
  local i
  for i in $(seq 1 120); do
    grep -q "$2" "$1" 2>/dev/null && return 0
    kill -0 "$3" 2>/dev/null || die "$4 exited before ready, see $1"
    sleep 0.25
  done
  die "$4 not ready after 30 s, see $1"
}

# --- thread map and placement -------------------------------------------------------------------
# Linux keeps 15 bytes of a thread name, so carrier-0 and carrier-1 are indistinguishable in
# /proc and pidstat. The Java names come from a thread dump: nid is the kernel TID.
thread_map() {  # <pid> <file>: lines "tid<TAB>java-name"
  "$LOOM_JDK/bin/jcmd" "$1" Thread.print 2>/dev/null | python3 -c '
import re, sys
for line in sys.stdin:
    m = re.match(r"\"(.*)\".* nid=(0x[0-9a-fA-F]+|[0-9]+)", line)
    if m:
        print(f"{int(m.group(2), 0)}\t{m.group(1)}")
' >"$2"
}
affinity_dump() {  # <pid> <map> <file>: "tid<TAB>java-name<TAB>cpus_allowed_list"
  local tid name
  : >"$3"
  for d in /proc/"$1"/task/*; do
    tid="${d##*/}"
    name="$(awk -F'\t' -v t="$tid" '$1==t{print $2}' "$2")"
    [[ -z "$name" ]] && name="$(cat "$d/comm" 2>/dev/null || echo '?')"
    printf '%s\t%s\t%s\n' "$tid" "$name" "$(awk '/Cpus_allowed_list/{print $2}' "$d/status" 2>/dev/null)" >>"$3"
  done
}
# Arms A_iso and C_iso share the carrier CPUs between carriers; arm D binds each carrier itself
# through exeris.carrier.affinity, and the harness only verifies that binding. Workers the JVM
# creates later inherit the creating thread's mask, so placement is re-applied after warmup and
# checked again at the end of the measurement window.
# The JDK starts some platform threads lazily from whichever thread first needs them (the poller
# threads and the virtual-thread unparker, on the first blocking socket call), so they inherit a
# carrier's mask. Every thread that is neither a carrier nor a reactor is moved back to the
# auxiliary CPUs; reactors keep the one-CPU binding the transport gives each of them.
pin_threads() {  # <pid> <map>
  local tid name
  for d in /proc/"$1"/task/*; do
    tid="${d##*/}"
    name="$(awk -F'\t' -v t="$tid" '$1==t{print $2}' "$2")"
    if [[ "$name" =~ $CARRIER_NAME_RE ]]; then
      [[ "$ARM" == "D" ]] || taskset -p -c "$CARRIER_CPUS" "$tid" >/dev/null 2>&1 || true
    elif [[ "$name" != carrier/native-tcp/reactor/* ]]; then
      taskset -p -c "$SERVER_AUX_CPUS" "$tid" >/dev/null 2>&1 || true
    fi
  done
}

# --- run ----------------------------------------------------------------------------------------
log "trial arm=$ARM backend=$BACKEND rate=$RATE out=$OUT"
taskset -c "$MOCK_CPUS" "${MOCK_CMD[@]}" >"$OUT/mock-stdout.txt" 2>&1 &
MOCK_PID=$!; PIDS+=("$MOCK_PID")
wait_ready "$OUT/mock-stdout.txt" "LOOM-MOCK READY" "$MOCK_PID" "mock backend"

taskset -c "$SERVER_AUX_CPUS" "${SERVER_CMD[@]}" >"$OUT/server-stdout.txt" 2>&1 &
SERVER_PID=$!; PIDS+=("$SERVER_PID")
wait_ready "$OUT/server-stdout.txt" "LOOM-BENCH READY" "$SERVER_PID" "server"

URL="http://127.0.0.1:$SERVER_PORT/backend"
curl -sf "$URL" >/dev/null || die "smoke request to $URL failed"

thread_map "$SERVER_PID" "$OUT/threads-ready.txt"
pin_threads "$SERVER_PID" "$OUT/threads-ready.txt"

log "warmup ${WARMUP}s (closed loop)"
taskset -c "$LOAD_CPUS" "$WRK" -t"$LOAD_THREADS" -c"$CONNECTIONS" -d"${WARMUP}s" "$URL" >"$OUT/warmup.txt" 2>&1

thread_map "$SERVER_PID" "$OUT/threads.txt"
pin_threads "$SERVER_PID" "$OUT/threads.txt"
affinity_dump "$SERVER_PID" "$OUT/threads.txt" "$OUT/affinity-start.txt"

# Probes run for the measurement window only.
pidstat -u -w -t -p "$SERVER_PID" 1 "$DURATION" >"$OUT/pidstat-server.txt" 2>&1 &
PIDSTAT_PID=$!; PIDS+=("$PIDSTAT_PID")
pidstat -u -p "$MOCK_PID" 1 "$DURATION" >"$OUT/pidstat-mock.txt" 2>&1 &
PIDS+=("$!")

PERF_STATUS="not_measured"
PARANOID="$(cat /proc/sys/kernel/perf_event_paranoid)"
if command -v perf >/dev/null && [[ "$PARANOID" -le 1 ]]; then
  perf stat -e task-clock,cycles,instructions,context-switches,cpu-migrations \
    -p "$SERVER_PID" -o "$OUT/perf-stat.txt" -- sleep "$DURATION" &
  PIDS+=("$!"); PERF_STATUS="measured"
else
  echo "perf stat not run: perf_event_paranoid=$PARANOID (needs <= 1)" >"$OUT/perf-stat.txt"
fi

PROFILE_STATUS="none"
if [[ "$PROFILE" != "none" ]]; then
  [[ -x "$ASYNC_PROFILER/bin/asprof" ]] || die "async-profiler not found at $ASYNC_PROFILER"
  "$ASYNC_PROFILER/bin/asprof" -e "$PROFILE" -d "$DURATION" -t -o collapsed \
    -f "$OUT/profile-$PROFILE.collapsed.txt" "$SERVER_PID" >"$OUT/asprof-stdout.txt" 2>&1 &
  PIDS+=("$!"); PROFILE_STATUS="$PROFILE"
fi

PERF_SCHED_STATUS="none"
if [[ "$PERF_SCHED" == "yes" ]]; then
  perf sched record -p "$SERVER_PID" -o "$OUT/perf-sched.data" -- sleep "$DURATION" \
    >/dev/null 2>"$OUT/perf-sched-record.txt" &
  PIDS+=("$!"); PERF_SCHED_STATUS="recorded"
fi

if [[ "$RATE" == "max" ]]; then
  log "measure ${DURATION}s closed loop (wrk)"
  taskset -c "$LOAD_CPUS" "$WRK" -t"$LOAD_THREADS" -c"$CONNECTIONS" -d"${DURATION}s" --latency "$URL" \
    >"$OUT/load.txt" 2>&1
else
  log "measure ${DURATION}s open loop at ${RATE} req/s (wrk2)"
  taskset -c "$LOAD_CPUS" "$WRK2" -t"$LOAD_THREADS" -c"$CONNECTIONS" -d"${DURATION}s" -R"$RATE" --latency "$URL" \
    >"$OUT/load.txt" 2>&1
fi

affinity_dump "$SERVER_PID" "$OUT/threads.txt" "$OUT/affinity-end.txt"
wait "$PIDSTAT_PID" 2>/dev/null || true
sleep 2

# --- environment record -------------------------------------------------------------------------
{
  echo "uname: $(uname -a)"
  echo "cpu: $(lscpu | awk -F: '/Model name/{gsub(/^ +/,"",$2);print $2}')"
  echo "governor: $(cat /sys/devices/system/cpu/cpu"${CARRIERS[0]}"/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
  echo "isolated: $(cat /sys/devices/system/cpu/isolated 2>/dev/null)"
  echo "perf_event_paranoid: $PARANOID"
  echo "--- lscpu -e"; lscpu -e
  echo "wrk: $("$WRK" -v 2>&1 | head -1)"
  echo "wrk2: $WRK2 at $(git -C "$(dirname "$WRK2")" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "--- java -version"; "$LOOM_JDK/bin/java" -version 2>&1
  echo "--- server command"; printf '%q ' "${SERVER_CMD[@]}"; echo
  echo "--- mock command"; printf '%q ' "${MOCK_CMD[@]}"; echo
} >"$OUT/environment.txt"
cp "$KERNEL_DIR/kernel-identity.json" "$OUT/kernel-identity.json"

BENCH_SHA="$(git -C "$BENCH_ROOT" rev-parse HEAD)"
BENCH_DIRTY="$(git -C "$BENCH_ROOT" status --porcelain -- scripts/loom-carrier-scheduler targets/exeris-loom-scheduler-app | wc -l)"

python3 "$SCRIPT_DIR/parse_trial.py" "$OUT" \
  --arm "$ARM" --backend "$BACKEND" --rate "$RATE" --connections "$CONNECTIONS" --load-threads "$LOAD_THREADS" \
  --warmup "$WARMUP" --duration "$DURATION" --think-ms "$THINK_MS" --poller-mode "${POLLER_MODE:-default}" \
  --carrier-cpus "$CARRIER_CPUS" --server-aux-cpus "$SERVER_AUX_CPUS" --mock-cpus "$MOCK_CPUS" --load-cpus "$LOAD_CPUS" \
  --carrier-name-re "$CARRIER_NAME_RE" --perf "$PERF_STATUS" --profile "$PROFILE_STATUS" \
  --perf-sched "$PERF_SCHED_STATUS" \
  --bench-commit "$BENCH_SHA" --bench-dirty "$BENCH_DIRTY"
