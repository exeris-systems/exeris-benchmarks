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
#       --arm A_iso|B_pin|B_float|C_iso|D|D2|Dv --backend jdk|kernel --rate <req/s>|max --out <dir> [options]
#
# Arms D2 and Dv are arm D plus the scheduler properties of a committed file (armcfg.py): D2 takes
# arms/D2.properties, Dv takes arms/pilot/<stem>.properties and needs --variant <stem>. The set the
# trial ran with is copied into the trial directory and recorded in trial.json with its digest.
#
# Options (defaults are the CPU-bound regime on a 6-core / 12-thread host):
#   --connections 100   --load-threads 4      --warmup 30   --duration 30   (seconds)
#   --warmup-mode closed|open   closed: wrk at saturation; open: wrk2 at the trial's own rate, so the
#                               measurement starts from the load shape it measures (rate=max
#                               always warms closed-loop)
#   --think-ms 1        --mock-threads 2      --pool 128    --poller-mode ""  (empty = JVM default)
#   --max-connections N  raise the kernel's connection and admission limits on server and mock
#                        (http.maxConnections, transport.maxConnections and
#                        transport.paqs.maxActiveStreams; defaults 4096 / 4096 / 5000), for
#                        connection counts or in-flight requests above those defaults
#   --server-aux-cpus 0,6     JVM auxiliary threads and transport reactors
#   --carrier-cpus 2,3        scheduler carriers (one per CPU for arms B_pin, D, D2 and Dv)
#   --mock-cpus 1,7           mock backend JVM
#   --load-cpus 4,5,10,11     load generator
#   --heap 1g
#   --profile none|cpu|wall   async-profiler on the server during the measurement window. A
#                             profiled trial is diagnostic only and is marked so: the profiler
#                             perturbs the latency it would explain.
#   --perf-sched              record sched_switch and sched_migrate_task on the server's CPUs and
#                             sched_waking aimed at them from any CPU, on CLOCK_MONOTONIC, and
#                             derive each server thread's run time per CPU. Diagnostic only, for the same reason. Needs
#                             perf_event_paranoid <= -1 and read access to /sys/kernel/tracing.
#   --perf-sched-delay S      start that recording S seconds into the window (default 0)
#   --perf-record             sample the carrier CPUs with call graphs (perf record -g, 999 Hz, user
#                             and kernel) for the whole window, and write the samples' shares by
#                             symbol to perf-record-report.txt. Diagnostic only. Kernel symbols need
#                             kernel.kptr_restrict=0 as well as perf_event_paranoid <= -1.
#   --perf-sched-seconds S    and record for S seconds (default: the rest of the window)
#   --wall-interval 5ms       sampling interval of --profile wall, which is written as JFR so that
#                             stacks can be cut to any time range
#   --latency-probe R         also send R req/s from a separate client that records every request's
#                             latency against its intended send time on CLOCK_MONOTONIC
#                             (latency_probe.py), the one latency timeline the trial has; one
#                             connection per 10 req/s, so each has 100 ms per request
#   --gc-log                  GC and safepoint logs from server and mock, with wall-clock time
#   --jfr                     a JFR recording of the server, virtual-thread pinning from 1 ms
#   --backend-trace           every second, on CLOCK_MONOTONIC: the server's connections to the mock
#                             and from the load generator by TCP state (backend_trace.py), the
#                             mock's per-thread CPU (pidstat-mock-threads.txt), and the mock's CPU
#                             profile as JFR (profile-mock-cpu.jfr)
#   --mock-idle-timeout MS    the mock's HTTP and transport idle timeout (default: the kernel's,
#                             30 s); a configuration change, recorded as one
#   --app-src DIR             build and run the benchmark app from DIR instead of this checkout's
#                             targets/exeris-loom-scheduler-app, e.g. an earlier commit's app
#                             extracted with git archive; recorded in environment.txt
#   --nofile SOFT:HARD        set the trial's descriptor limits instead of raising the soft limit
#                             to the hard one; the JVMs and load generators inherit them
#
#   --variant STEM            the pilot cell of arm Dv (arms/pilot/STEM.properties)
#   --stats                   enable the scheduler's counters (exeris.locality.stats) and read them
#                             at the start and the end of the window from the server's
#                             /__sched-stats endpoint into scheduler-stats-{start,end}.json; arms
#                             that run ExerisCarrierScheduler only. The counters cost cycles, so
#                             the trial is diagnostic.
#   --perf-threads            context switches and futex calls per server thread over the window
#                             (perf stat --per-thread); diagnostic.
#   --pilot                   mark the trial as a pilot trial: never evidence. Implies --perf-threads.
#
# Every diagnostic marks the trial as perturbed. When any is on, analyze_diag.py cuts the recorded
# data to the probe's slow windows and writes diag.txt / diag.json beside trial.json.
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
CONNECTIONS=100 LOAD_THREADS=4 WARMUP=30 DURATION=30 THINK_MS=1 MOCK_THREADS=2 POOL=128 POLLER_MODE="" WARMUP_MODE="closed" MAX_CONNECTIONS=""
SERVER_AUX_CPUS="0,6" CARRIER_CPUS="2,3" MOCK_CPUS="1,7" LOAD_CPUS="4,5,10,11" HEAP="1g" PROFILE="none"
SERVER_PORT="" MOCK_PORT="" PERF_SCHED="no" PERF_RECORD="no"
PERF_SCHED_DELAY=0 PERF_SCHED_SECONDS="" WALL_INTERVAL="5ms" PROBE_RATE=0 GC_LOG="no" JFR="no"
BACKEND_TRACE="no" MOCK_IDLE_TIMEOUT="" NOFILE_SET="" VARIANT="" STATS="no" PERF_THREADS="no" PILOT="no"

die() { echo "run-trial: $*" >&2; exit 2; }
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kernel-dir) KERNEL_DIR="$2" ;;   --arm) ARM="$2" ;;            --backend) BACKEND="$2" ;;
    --rate) RATE="$2" ;;               --out) OUT="$2" ;;            --connections) CONNECTIONS="$2" ;;
    --load-threads) LOAD_THREADS="$2" ;; --warmup) WARMUP="$2" ;; --warmup-mode) WARMUP_MODE="$2" ;;    --duration) DURATION="$2" ;;
    --think-ms) THINK_MS="$2" ;;       --mock-threads) MOCK_THREADS="$2" ;;  --pool) POOL="$2" ;; --max-connections) MAX_CONNECTIONS="$2" ;;
    --poller-mode) POLLER_MODE="$2" ;; --server-aux-cpus) SERVER_AUX_CPUS="$2" ;;
    --carrier-cpus) CARRIER_CPUS="$2" ;; --mock-cpus) MOCK_CPUS="$2" ;; --load-cpus) LOAD_CPUS="$2" ;;
    --heap) HEAP="$2" ;;               --profile) PROFILE="$2" ;;
    --server-port) SERVER_PORT="$2" ;; --mock-port) MOCK_PORT="$2" ;;
    --perf-sched) PERF_SCHED="yes"; shift; continue ;;
    --perf-record) PERF_RECORD="yes"; shift; continue ;;
    --perf-sched-delay) PERF_SCHED_DELAY="$2" ;; --perf-sched-seconds) PERF_SCHED_SECONDS="$2" ;;
    --wall-interval) WALL_INTERVAL="$2" ;; --latency-probe) PROBE_RATE="$2" ;;
    --gc-log) GC_LOG="yes"; shift; continue ;;
    --jfr) JFR="yes"; shift; continue ;;
    --backend-trace) BACKEND_TRACE="yes"; shift; continue ;;
    --mock-idle-timeout) MOCK_IDLE_TIMEOUT="$2" ;;
    --app-src) APP_DIR="$2" ;;         --nofile) NOFILE_SET="$2" ;;
    --variant) VARIANT="$2" ;;
    --stats) STATS="yes"; shift; continue ;;
    --perf-threads) PERF_THREADS="yes"; shift; continue ;;
    --pilot) PILOT="yes"; PERF_THREADS="yes"; shift; continue ;;
    *) die "unknown option $1" ;;
  esac
  shift 2
done

[[ -n "$KERNEL_DIR" && -f "$KERNEL_DIR/kernel-cp.txt" ]] || die "--kernel-dir must point at a build-kernel.sh output"
[[ "$ARM" =~ ^(A_iso|B_pin|B_float|C_iso|D|D2|Dv)$ ]] || die "--arm must be A_iso, B_pin, B_float, C_iso, D, D2 or Dv"
[[ "$ARM" == "Dv" ]] && { [[ "$VARIANT" =~ ^[A-Za-z0-9_-]+$ ]] || die "arm Dv needs --variant <stem of arms/pilot/<stem>.properties>"; }
[[ "$ARM" == "Dv" || -z "$VARIANT" ]] || die "--variant applies to arm Dv only"
[[ "$STATS" == "no" || "$ARM" =~ ^(C_iso|D|D2|Dv)$ ]] || die "--stats needs an arm that runs ExerisCarrierScheduler (C_iso, D, D2, Dv)"
# The arm's property file is read before anything is started or written: a missing or malformed
# file refuses the trial.
ARM_PROPS="$(python3 "$SCRIPT_DIR/armcfg.py" jvm-args "$ARM" ${VARIANT:+"$VARIANT"})" || exit 2
ARM_PROPS_RECORD="$(python3 "$SCRIPT_DIR/armcfg.py" normalise "$ARM" ${VARIANT:+"$VARIANT"})" || exit 2
PROP_OPTS=()
[[ -n "$ARM_PROPS" ]] && mapfile -t PROP_OPTS <<<"$ARM_PROPS"
[[ "$BACKEND" =~ ^(jdk|kernel)$ ]] || die "--backend must be jdk or kernel"
[[ "$RATE" == "max" || "$RATE" =~ ^[0-9]+$ ]] || die "--rate must be max or an integer"
[[ "$PROFILE" =~ ^(none|cpu|wall)$ ]] || die "--profile must be none, cpu or wall"
[[ "$WARMUP_MODE" =~ ^(closed|open)$ ]] || die "--warmup-mode must be closed or open"
[[ -n "$OUT" ]] || die "--out is required"
[[ "$PROBE_RATE" =~ ^[0-9]+$ ]] || die "--latency-probe must be an integer req/s"
[[ -z "$MOCK_IDLE_TIMEOUT" || "$MOCK_IDLE_TIMEOUT" =~ ^[0-9]+$ ]] || die "--mock-idle-timeout must be milliseconds"
[[ -z "$NOFILE_SET" || "$NOFILE_SET" =~ ^[0-9]+:[0-9]+$ ]] || die "--nofile must be SOFT:HARD"
[[ -f "$APP_DIR/build.sh" && -d "$APP_DIR/src" ]] || die "--app-src $APP_DIR holds no app (build.sh, src/)"
APP_DIR="$(cd "$APP_DIR" && pwd)"
[[ -z "$PERF_SCHED_SECONDS" ]] && PERF_SCHED_SECONDS=$((DURATION - PERF_SCHED_DELAY))
(( PERF_SCHED_DELAY >= 0 && PERF_SCHED_SECONDS > 0 && PERF_SCHED_DELAY + PERF_SCHED_SECONDS <= DURATION )) \
  || die "--perf-sched-delay + --perf-sched-seconds must fit inside --duration"
[[ -x "$LOOM_JDK/bin/java" ]] || die "no java under LOOM_JDK=$LOOM_JDK"
[[ -x "$WRK" ]] || die "wrk not found (warmup always uses it)"
[[ "$RATE" == "max" || -x "$WRK2" ]] || die "wrk2 not found at $WRK2"

IFS=, read -r -a CARRIERS <<<"$CARRIER_CPUS"
[[ ${#CARRIERS[@]} -ge 1 ]] || die "--carrier-cpus is empty"
CARRIER_COUNT=${#CARRIERS[@]}

# wrk and wrk2 need one descriptor per connection and never raise their own limit; a soft limit
# below that turns the excess connections into connect errors and caps throughput at what the
# connected ones can carry.
if [[ -n "$NOFILE_SET" ]]; then
  # The soft limit goes first: the kernel refuses a hard limit below the current soft one.
  ulimit -Sn "${NOFILE_SET%%:*}" || die "cannot set the soft descriptor limit to ${NOFILE_SET%%:*}"
  ulimit -Hn "${NOFILE_SET#*:}" || die "cannot set the hard descriptor limit to ${NOFILE_SET#*:}"
else
  ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
fi
NOFILE="$(ulimit -n)"
[[ "$NOFILE" == "unlimited" || "$NOFILE" -ge $((CONNECTIONS + 64)) ]] \
  || die "descriptor limit $NOFILE is below $CONNECTIONS connections; raise it (host-shield.sh run sets 1048576)"

mkdir -p "$OUT"
[[ -e "$OUT/trial.json" ]] && die "$OUT already holds a trial"
# The set this trial ran with, in the form the parser compares against what the server echoes.
printf '%s' "$ARM_PROPS_RECORD" >"$OUT/arm-properties.txt"

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
SERVER_PORT="${SERVER_PORT:-$(free_port)}"
MOCK_PORT="${MOCK_PORT:-$(free_port)}"

# --- build the app against this kernel build -------------------------------------------------
# The build directory is keyed by the app's sources as well as the kernel, so a changed app is
# compiled again instead of a stale build being measured under the new harness commit.
KERNEL_CP="$(cat "$KERNEL_DIR/kernel-cp.txt")"
APP_SRC_HASH="$(cd "$APP_DIR" && find build.sh src -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-12)"
APP_BUILD="$KERNEL_DIR/app-$APP_SRC_HASH"
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
  B_pin)
    # The stock pool with the same parameters as A_iso, each worker binding itself to one CPU of
    # the carrier set when it starts (PinnedForkJoinScheduler in the app).
    ARM_OPTS=(-Djdk.virtualThreadScheduler.implClass=eu.exeris.benchmarks.targets.loomscheduler.PinnedForkJoinScheduler
              -Djdk.virtualThreadScheduler.parallelism="$CARRIER_COUNT"
              -Djdk.virtualThreadScheduler.maxPoolSize="$CARRIER_COUNT"
              -Dexeris.carrier.affinity="$CARRIER_CPUS"
              --add-exports java.base/jdk.internal.misc=ALL-UNNAMED
              --add-exports java.base/jdk.internal.access=ALL-UNNAMED)
    CARRIER_NAME_RE='^spi-fjp-worker-[0-9]+$' ;;
  B_float)
    # B_pin with the binding off: the built-in scheduler reproduced through the SPI, run against
    # A_iso to check the reproduction. Its workers share the carrier CPUs as A_iso's do.
    ARM_OPTS=(-Djdk.virtualThreadScheduler.implClass=eu.exeris.benchmarks.targets.loomscheduler.PinnedForkJoinScheduler
              -Djdk.virtualThreadScheduler.parallelism="$CARRIER_COUNT"
              -Djdk.virtualThreadScheduler.maxPoolSize="$CARRIER_COUNT"
              -Dloom.bench.pinned.bind=false
              --add-exports java.base/jdk.internal.misc=ALL-UNNAMED
              --add-exports java.base/jdk.internal.access=ALL-UNNAMED)
    CARRIER_NAME_RE='^spi-fjp-worker-[0-9]+$' ;;
  C_iso)
    ARM_OPTS=(-Djdk.virtualThreadScheduler.implClass="$SCHED_IMPL" -Dexeris.locality.allVthreads=true
              -Dexeris.transport.locality=true -Dexeris.carrier.count="$CARRIER_COUNT")
    CARRIER_NAME_RE='^exeris-carrier-[0-9]+$' ;;
  D|D2|Dv)
    # D2 and Dv are D plus the properties of their file.
    ARM_OPTS=(-Djdk.virtualThreadScheduler.implClass="$SCHED_IMPL" -Dexeris.locality.allVthreads=true
              -Dexeris.transport.locality=true -Dexeris.carrier.count="$CARRIER_COUNT"
              -Dexeris.carrier.affinity="$CARRIER_CPUS" "${PROP_OPTS[@]}")
    CARRIER_NAME_RE='^exeris-carrier-[0-9]+$' ;;
esac
STATS_OPTS=()
[[ "$STATS" == "yes" ]] && STATS_OPTS=(-Dexeris.locality.stats=true)
POLLER_OPTS=()
[[ -n "$POLLER_MODE" ]] && POLLER_OPTS=(-Djdk.pollerMode="$POLLER_MODE")
# Without these the Community transport cannot reach the socket descriptors and falls back to NIO,
# which is a different I/O path from the one under study; the transport gate checks which one ran.
ACCESS_OPTS=(--add-opens java.base/sun.nio.ch=ALL-UNNAMED --add-opens java.base/java.io=ALL-UNNAMED
  --enable-native-access=ALL-UNNAMED)
REACTOR_COUNT="$(awk -F, '{print NF}' <<<"$SERVER_AUX_CPUS")"
LIMIT_OPTS=()
[[ -n "$MAX_CONNECTIONS" ]] && LIMIT_OPTS=(-Dexeris.http.maxConnections="$MAX_CONNECTIONS"
  -Dexeris.transport.maxConnections="$MAX_CONNECTIONS" -Dexeris.transport.paqs.maxActiveStreams="$MAX_CONNECTIONS")

DIAG=()
SERVER_DIAG_OPTS=() MOCK_DIAG_OPTS=()
[[ "$PILOT" == "yes" ]] && DIAG+=("v2 pilot")
[[ "$STATS" == "yes" ]] && DIAG+=("scheduler stats")
[[ "$PERF_THREADS" == "yes" ]] && DIAG+=("perf per thread")
if [[ "$GC_LOG" == "yes" ]]; then
  SERVER_DIAG_OPTS+=("-Xlog:gc,safepoint:file=$OUT/gc-server.log:time,uptimemillis,level,tags")
  MOCK_DIAG_OPTS+=("-Xlog:gc,safepoint:file=$OUT/gc-mock.log:time,uptimemillis,level,tags")
  DIAG+=("gc log")
fi
if [[ -n "$MOCK_IDLE_TIMEOUT" ]]; then
  MOCK_DIAG_OPTS+=(-Dexeris.http.idleTimeoutMillis="$MOCK_IDLE_TIMEOUT"
                   -Dexeris.transport.idleTimeoutMillis="$MOCK_IDLE_TIMEOUT")
  DIAG+=("mock idle timeout ${MOCK_IDLE_TIMEOUT} ms")
fi
if [[ "$JFR" == "yes" ]]; then
  # Only the JDK's virtual-thread events: the kernel's own JFR events fire per request, and a
  # recording that enables them measures the recorder.
  KERNEL_CLASS_DIRS=()
  IFS=: read -r -a _cp <<<"$KERNEL_CP"
  for _e in "${_cp[@]}"; do [[ -d "$_e" ]] && KERNEL_CLASS_DIRS+=("$_e"); done
  python3 "$SCRIPT_DIR/make_pinning_jfc.py" "${KERNEL_CLASS_DIRS[@]}" >"$OUT/diag.jfc"
  SERVER_DIAG_OPTS+=("-XX:StartFlightRecording:name=diag,settings=$OUT/diag.jfc")
  DIAG+=("jfr")
fi
SERVER_CMD=("$LOOM_JDK/bin/java" -Xms"$HEAP" -Xmx"$HEAP" -XX:+UseParallelGC "${ACCESS_OPTS[@]}" "${SERVER_DIAG_OPTS[@]}"
  "${ARM_OPTS[@]}" "${STATS_OPTS[@]}" "${POLLER_OPTS[@]}" "${LIMIT_OPTS[@]}"
  -Dexeris.transport.reactorCount="$REACTOR_COUNT" -Dexeris.reactor.affinity="$SERVER_AUX_CPUS"
  -Dexeris.http.port="$SERVER_PORT" -Dexeris.http.bindHost=127.0.0.1
  -Dloom.bench.backend="$BACKEND" -Dloom.bench.backend.host=127.0.0.1 -Dloom.bench.backend.port="$MOCK_PORT"
  -Dloom.bench.backend.pool="$POOL"
  -cp "$APP_CP" eu.exeris.benchmarks.targets.loomscheduler.LoomSchedulerServer)
MOCK_CMD=("$LOOM_JDK/bin/java" -Xms"$HEAP" -Xmx"$HEAP" -XX:+UseParallelGC "${ACCESS_OPTS[@]}" "${MOCK_DIAG_OPTS[@]}"
  -Djdk.virtualThreadScheduler.parallelism="$MOCK_THREADS" "${LIMIT_OPTS[@]}"
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
  "$LOOM_JDK/bin/jcmd" "$1" Thread.print 2>&1 | tee "${2%.txt}-dump.txt" | python3 -c '
import re, sys
for line in sys.stdin:
    # A Java thread header carries its OS id as "#<n> [<tid>]"; a carrier that is running a virtual
    # thread is printed without nid=, so the bracketed id is read first and nid= is the fallback
    # for VM threads, which have no "#<n>".
    m = re.match(r"\"(.*)\" #\d+ \[(\d+)\]", line) or re.match(r"\"(.*)\".* nid=(0x[0-9a-fA-F]+|[0-9]+)", line)
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
# Arms A_iso and C_iso share the carrier CPUs between carriers; arms B_pin, D, D2 and Dv bind each carrier
# itself to one CPU of exeris.carrier.affinity, and the harness only verifies that binding. Workers the JVM
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
      [[ "$ARM" =~ ^(D|D2|Dv|B_pin)$ ]] || taskset -p -c "$CARRIER_CPUS" "$tid" >/dev/null 2>&1 || true
    elif [[ "$name" != carrier/native-tcp/reactor/* ]]; then
      taskset -p -c "$SERVER_AUX_CPUS" "$tid" >/dev/null 2>&1 || true
    fi
  done
}

# The host's isolation is recorded, not assumed: a campaign run on an unshielded desktop is still a
# campaign, but its summary has to say so. See host-shield.sh.
host_state() {  # <file>
  local cg
  cg="$(sed -n 's/^0:://p' /proc/self/cgroup)"
  {
    echo "graphical_target=$(systemctl is-active graphical.target 2>/dev/null || true)"
    for sl in system.slice user.slice init.scope; do
      echo "allowed_cpus.$sl=$(systemctl show "$sl" -p AllowedCPUs --value 2>/dev/null)"
    done
    echo "own_cgroup=$cg"
    echo "own_cpus_allowed=$(awk '/Cpus_allowed_list/{print $2}' /proc/self/status)"
    echo "isolated=$(cat /sys/devices/system/cpu/isolated 2>/dev/null)"
    echo "boost=$(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo n/a)"
    echo "governors=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c | xargs)"
    # The CPU-bound tail depends on the host's state, which changes after boot; every trial records
    # the boot it ran in, how far into it, and whether connection tracking and iptables are loaded,
    # since every loopback packet then passes their hooks.
    echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"
    echo "uptime_s=$(awk '{printf "%d", $1}' /proc/uptime)"
    echo "netfilter_modules=$(awk '$1 ~ /^(nf_conntrack|nf_nat|ip_tables|iptable_[a-z]+|nf_tables|br_netfilter)$/ {print $1}' /proc/modules | sort | xargs)"
    echo "loopback_notrack=${LOOPBACK_NOTRACK:-unset}"
  } >"$1"
}

# Kernel state that grows with what the host has done since boot and that the network path or
# memory accounting walks: tracked connections, dying memory cgroups, unreclaimable slab, sockets.
# Recorded at both ends of the window so that a trial's own contribution is visible beside the
# level it started from.
host_counters() {  # <file>
  {
    echo "conntrack_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo n/a)"
    echo "cgroup_dying_root=$(awk '$1=="nr_dying_descendants"{print $2}' /sys/fs/cgroup/cgroup.stat 2>/dev/null)"
    echo "cgroup_descendants_root=$(awk '$1=="nr_descendants"{print $2}' /sys/fs/cgroup/cgroup.stat 2>/dev/null)"
    echo "cgroup_dying_bench_slice=$(awk '$1=="nr_dying_descendants"{print $2}' /sys/fs/cgroup/bench.slice/cgroup.stat 2>/dev/null)"
    awk '/^Slab:/{print "slab_kb=" $2} /^SUnreclaim:/{print "sunreclaim_kb=" $2}' /proc/meminfo
    ss -s 2>/dev/null | awk -F'[ :(),]+' '/^TCP:/{print "tcp_sockets=" $2; for (i = 3; i < NF; i += 2) print "tcp_" $i "=" $(i + 1)}'
  } >"$1"
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

if [[ "$WARMUP_MODE" == "open" && "$RATE" != "max" ]]; then
  log "warmup ${WARMUP}s (open loop at ${RATE} req/s)"
  taskset -c "$LOAD_CPUS" "$WRK2" -t"$LOAD_THREADS" -c"$CONNECTIONS" -d"${WARMUP}s" -R"$RATE" --latency "$URL" \
    >"$OUT/warmup.txt" 2>&1
else
  log "warmup ${WARMUP}s (closed loop)"
  taskset -c "$LOAD_CPUS" "$WRK" -t"$LOAD_THREADS" -c"$CONNECTIONS" -d"${WARMUP}s" "$URL" >"$OUT/warmup.txt" 2>&1
fi

thread_map "$SERVER_PID" "$OUT/threads.txt"
pin_threads "$SERVER_PID" "$OUT/threads.txt"
thread_map "$MOCK_PID" "$OUT/mock-threads.txt"
affinity_dump "$SERVER_PID" "$OUT/threads.txt" "$OUT/affinity-start.txt"

host_state "$OUT/host.txt"
cp /proc/interrupts "$OUT/interrupts-start.txt"
host_counters "$OUT/host-counters-start.txt"

# The scheduler's counters are cumulative from JVM start; the window's share is the difference
# between the two readings, taken from the server's own endpoint.
fetch_stats() {  # <file>
  curl -s --max-time 5 "http://127.0.0.1:$SERVER_PORT/__sched-stats" >"$1" || echo '{"unavailable":true}' >"$1"
}
[[ "$STATS" == "yes" ]] && fetch_stats "$OUT/scheduler-stats-start.json"

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

PERF_THREADS_STATUS="not_measured"
if [[ "$PERF_THREADS" == "yes" ]]; then
  # Per server thread, so the carriers' switches and futex calls can be told from the reactors' and
  # the JDK's helper threads'; threads.txt maps the thread ids to Java names.
  if command -v perf >/dev/null && [[ "$PARANOID" -le -1 ]]; then
    perf stat --per-thread -e context-switches,syscalls:sys_enter_futex -p "$SERVER_PID" \
      -o "$OUT/perf-threads.txt" -- sleep "$DURATION" &
    PIDS+=("$!"); PERF_THREADS_STATUS="measured"
  else
    echo "perf per-thread stat not run: perf_event_paranoid=$PARANOID (needs -1 for the futex tracepoint)" >"$OUT/perf-threads.txt"
  fi
fi

PROFILE_STATUS="none"
if [[ "$PROFILE" != "none" ]]; then
  [[ -x "$ASYNC_PROFILER/bin/asprof" ]] || die "async-profiler not found at $ASYNC_PROFILER"
  if [[ "$PROFILE" == "wall" ]]; then
    # JFR keeps each sample's time, so the stacks can later be cut to the probe's slow windows.
    "$ASYNC_PROFILER/bin/asprof" -e wall -i "$WALL_INTERVAL" -d "$DURATION" -t -o jfr \
      -f "$OUT/profile-wall.jfr" "$SERVER_PID" >"$OUT/asprof-stdout.txt" 2>&1 &
  else
    "$ASYNC_PROFILER/bin/asprof" -e "$PROFILE" -d "$DURATION" -t -o collapsed \
      -f "$OUT/profile-$PROFILE.collapsed.txt" "$SERVER_PID" >"$OUT/asprof-stdout.txt" 2>&1 &
  fi
  PIDS+=("$!"); PROFILE_STATUS="$PROFILE"; DIAG+=("async-profiler $PROFILE")
fi

PERF_SCHED_STATUS="none" PERF_SCHED_PID=""
if [[ "$PERF_SCHED" == "yes" ]]; then
  # Switches on the server's CPUs, where its threads run and wait; wake-ups from every CPU, since
  # the softirq that wakes a server thread runs on the sender's CPU, filtered in the kernel to
  # those that target a server CPU. Everything else on the host would multiply the volume
  # without adding a server thread's state. CLOCK_MONOTONIC is the probe's clock. The recorders
  # run on the load generator's CPUs, away from the CPUs they observe.
  SCHED_CPUS="$SERVER_AUX_CPUS,$CARRIER_CPUS"
  WAKE_FILTER="$(tr ',' '\n' <<<"$SCHED_CPUS" | sed 's/.*/target_cpu == &/' | paste -sd'|' | sed 's/|/ || /g')"
  ( sleep "$PERF_SCHED_DELAY"
    taskset -c "$LOAD_CPUS" perf record -B -m 64M -C "$SCHED_CPUS" -k CLOCK_MONOTONIC \
      -e sched:sched_switch -e sched:sched_migrate_task -o "$OUT/perf-sched.data" \
      -- sleep "$PERF_SCHED_SECONDS" >/dev/null 2>"$OUT/perf-sched-record.txt" &
    taskset -c "$LOAD_CPUS" perf record -B -m 64M -a -k CLOCK_MONOTONIC \
      -e sched:sched_waking --filter "$WAKE_FILTER" -o "$OUT/perf-sched-wake.data" \
      -- sleep "$PERF_SCHED_SECONDS" >/dev/null 2>"$OUT/perf-sched-wake-record.txt" &
    wait ) &
  PERF_SCHED_PID=$!; PIDS+=("$PERF_SCHED_PID"); PERF_SCHED_STATUS="recorded"; DIAG+=("perf sched record")
fi

PERF_RECORD_PID=""
if [[ "$PERF_RECORD" == "yes" ]]; then
  # Everything that runs on the carrier CPUs, kernel included: the question it answers is where
  # the carriers' kernel time goes. The recorder runs on the load generator's CPUs.
  taskset -c "$LOAD_CPUS" perf record -g -F 999 -C "$CARRIER_CPUS" -o "$OUT/perf-record.data" \
    -- sleep "$DURATION" >/dev/null 2>"$OUT/perf-record-stderr.txt" &
  PERF_RECORD_PID=$!; PIDS+=("$PERF_RECORD_PID"); DIAG+=("perf record")
fi

python3 -c 'import time; print(f"{time.time():.6f} {time.monotonic():.6f}")' >"$OUT/clock.txt"
BACKEND_TRACE_PID=""
if [[ "$BACKEND_TRACE" == "yes" ]]; then
  taskset -c "$LOAD_CPUS" python3 "$SCRIPT_DIR/backend_trace.py" "$MOCK_PORT" "$SERVER_PORT" "$DURATION" \
    >"$OUT/backend-trace.txt" 2>&1 &
  BACKEND_TRACE_PID=$!; PIDS+=("$BACKEND_TRACE_PID")
  pidstat -u -t -p "$MOCK_PID" 1 "$DURATION" >"$OUT/pidstat-mock-threads.txt" 2>&1 &
  PIDS+=("$!")
  # The mock's CPU profile as JFR, so the second its CPU jumps can be cut out and compared.
  if [[ -x "$ASYNC_PROFILER/bin/asprof" ]]; then
    "$ASYNC_PROFILER/bin/asprof" -e cpu -i 5ms -d "$DURATION" -t -o jfr -f "$OUT/profile-mock-cpu.jfr" "$MOCK_PID" \
      >"$OUT/asprof-mock-stdout.txt" 2>&1 &
    PIDS+=("$!")
  fi
  DIAG+=("backend trace")
fi
PROBE_PID=""
if (( PROBE_RATE > 0 )); then
  taskset -c "$LOAD_CPUS" python3 "$SCRIPT_DIR/latency_probe.py" --url "$URL" --rate "$PROBE_RATE" \
    --connections "$(( (PROBE_RATE + 9) / 10 ))" --duration "$DURATION" --out "$OUT/probe.csv" \
    >"$OUT/probe-stdout.txt" 2>&1 &
  PROBE_PID=$!; PIDS+=("$PROBE_PID"); DIAG+=("latency probe ${PROBE_RATE} req/s")
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

[[ "$STATS" == "yes" ]] && fetch_stats "$OUT/scheduler-stats-end.json"
affinity_dump "$SERVER_PID" "$OUT/threads.txt" "$OUT/affinity-end.txt"
cp /proc/interrupts "$OUT/interrupts-end.txt"
host_counters "$OUT/host-counters-end.txt"
wait "$PIDSTAT_PID" 2>/dev/null || true
[[ -n "$PROBE_PID" ]] && { wait "$PROBE_PID" 2>/dev/null || true; }
[[ -n "$PERF_SCHED_PID" ]] && { wait "$PERF_SCHED_PID" 2>/dev/null || true; }
if [[ -n "$PERF_RECORD_PID" ]]; then
  wait "$PERF_RECORD_PID" 2>/dev/null || true
  perf report -i "$OUT/perf-record.data" --no-children --sort dso,sym -g none --percent-limit 0.05 \
    --stdio >"$OUT/perf-record-report.txt" 2>"$OUT/perf-record-report-stderr.txt" || true
fi
[[ -n "$BACKEND_TRACE_PID" ]] && { wait "$BACKEND_TRACE_PID" 2>/dev/null || true; }
if [[ "$JFR" == "yes" ]]; then
  "$LOOM_JDK/bin/jcmd" "$SERVER_PID" JFR.dump name=diag filename="$OUT/server.jfr" >"$OUT/jfr-dump.txt" 2>&1 || true
fi
sleep 2

# --- environment record -------------------------------------------------------------------------
{
  echo "uname: $(uname -a)"
  echo "cpu: $(lscpu | awk -F: '/Model name/{gsub(/^ +/,"",$2);print $2}')"
  echo "governor: $(cat /sys/devices/system/cpu/cpu"${CARRIERS[0]}"/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
  echo "isolated: $(cat /sys/devices/system/cpu/isolated 2>/dev/null)"
  echo "perf_event_paranoid: $PARANOID"
  echo "nofile: $NOFILE"
  echo "nofile hard: $(ulimit -Hn)"
  echo "app source: $APP_DIR"
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
  --warmup "$WARMUP" --warmup-mode "$WARMUP_MODE" --duration "$DURATION" --think-ms "$THINK_MS" --poller-mode "${POLLER_MODE:-default}" \
  --carrier-cpus "$CARRIER_CPUS" --server-aux-cpus "$SERVER_AUX_CPUS" --mock-cpus "$MOCK_CPUS" --load-cpus "$LOAD_CPUS" \
  --carrier-name-re "$CARRIER_NAME_RE" --perf "$PERF_STATUS" --profile "$PROFILE_STATUS" \
  --perf-sched "$PERF_SCHED_STATUS" --pool "$POOL" --max-connections "${MAX_CONNECTIONS:-default}" \
  --bench-commit "$BENCH_SHA" --bench-dirty "$BENCH_DIRTY" \
  --variant "$VARIANT" --stats "$STATS" --perf-threads "$PERF_THREADS_STATUS" \
  --diag "$(IFS=,; echo "${DIAG[*]:-none}")"

if (( ${#DIAG[@]} > 0 )); then
  python3 "$SCRIPT_DIR/analyze_diag.py" "$OUT" >"$OUT/analyze-diag-stdout.txt" 2>&1 \
    || log "analyze_diag.py failed, see $OUT/analyze-diag-stdout.txt"
fi
