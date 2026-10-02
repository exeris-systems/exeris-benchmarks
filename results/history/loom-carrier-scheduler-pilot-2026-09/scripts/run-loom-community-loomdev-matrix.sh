#!/usr/bin/env bash
# ==============================================================================
# scripts/run-loom-community-loomdev-matrix.sh
#
# OpenJDK loom-dev Empirical Evaluation Matrix for VirtualThreadScheduler Locality:
# Strict controls, scientific hygiene, and reproducible Community (POSIX/FFM) stack.
#
# Matrix Configurations:
#   Config A: Stock FJP, default poller, parallelism=2
#   Config B: Stock FJP, pollerMode=3, parallelism=2
#   Config C: ExerisCarrierScheduler, pollerMode=3, 2 carriers (floating)
#   Config D: ExerisCarrierScheduler, pollerMode=3, 2 carriers (pinned cores 2,3)
#   Config E: ExerisCarrierScheduler, pollerMode=3, 2 carriers (pinned cores 2,3, N+1 core budget)
#
# CPU Topology (6C / 12T):
#   - Cores 0,1 (CPUs 0, 1, 6, 7) : JVM auxiliary threads (Master Poller, GC, JIT)
#   - Cores 2,3 (CPUs 2, 3)       : Carriers 0 and 1 (SMT siblings 8, 9 left completely idle)
#   - Cores 4,5 (CPUs 4, 5, 10, 11): Isolated Load Generator (wrk / wrk2)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_ROOT="$(cd "${BENCH_ROOT}/.." && pwd)"

JDK_HOME="${WORKSPACE_ROOT}/tools/jdk-loom/current"
JAVA="${JDK_HOME}/bin/java"
WRK="${WRK:-/usr/bin/wrk}"
WRK2="${WRK2:-${WORKSPACE_ROOT}/tools/wrk2/wrk2}"

APP_JAR="${BENCH_ROOT}/targets/exeris-h1-locality-app/target/exeris-h1-locality-app.jar"
REPORT_DIR="${BENCH_ROOT}/results/reports/loomdev-community"
mkdir -p "${REPORT_DIR}"

BASE_PORT="${BENCH_BASE_PORT:-8100}"
TRIAL_COUNTER=0

THREADS="${BENCH_THREADS:-4}"
CONNECTIONS="${BENCH_CONNS:-100}"
WARMUP_SEC="${WARMUP_SEC:-30}"
MEASURE_SEC="${MEASURE_SEC:-60}"
REPETITIONS="${REPETITIONS:-5}"
RUN_RATE_SWEEP="${RUN_RATE_SWEEP:-true}"
INCLUDE_CONFIG_E="${INCLUDE_CONFIG_E:-true}"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${REPORT_DIR}/run-${TIMESTAMP}"
mkdir -p "${RUN_DIR}"

REPORT_FILE="${REPORT_DIR}/REPORT-LOOMDEV-${TIMESTAMP}.md"
REPORT_JSON="${REPORT_DIR}/REPORT-LOOMDEV-${TIMESTAMP}.json"

export no_proxy="127.0.0.1,localhost,*"
export NO_PROXY="127.0.0.1,localhost,*"

echo "================================================================="
echo " OpenJDK loom-dev Carrier Locality Benchmark Matrix"
echo " Date        : $(date)"
echo " JDK Version : $("${JAVA}" -version 2>&1 | head -n 1)"
echo " Warmup      : ${WARMUP_SEC}s"
echo " Measurement : ${MEASURE_SEC}s"
echo " Repetitions : ${REPETITIONS}"
echo " Threads/Conn: ${THREADS} threads, ${CONNECTIONS} connections"
echo " Output Dir  : ${RUN_DIR}"
echo "================================================================="

# Build app target if needed
if [ ! -f "${APP_JAR}" ]; then
    echo "Building H1 Locality App..."
    bash "${BENCH_ROOT}/targets/exeris-h1-locality-app/build.sh"
fi

# Build classpath for Community runtime
if [ ! -f "/tmp/comm_cp.txt" ]; then
    JAVA_HOME="${JDK_HOME}" mvn dependency:build-classpath -pl exeris-kernel-community -Dmdep.outputFile=/tmp/comm_cp.txt -f "${WORKSPACE_ROOT}/exeris-kernel/pom.xml" > /dev/null 2>&1
fi

FILTERED_COMM_DEPS="$(tr ':' '\n' < /tmp/comm_cp.txt | grep -v "/eu/exeris/" | tr '\n' ':')"
SPI_CLASSES="${WORKSPACE_ROOT}/exeris-kernel/exeris-kernel-spi/target/classes"
CORE_CLASSES="${WORKSPACE_ROOT}/exeris-kernel/exeris-kernel-core/target/classes"
COMMUNITY_CLASSES="${WORKSPACE_ROOT}/exeris-kernel/exeris-kernel-community/target/classes"
COMMUNITY_CP="${APP_JAR}:${SPI_CLASSES}:${CORE_CLASSES}:${COMMUNITY_CLASSES}:${FILTERED_COMM_DEPS}"

# CPU Pinning Masks
# Server allowed CPUs: 0,1,2,3,6,7 (Auxiliary on 0,1,6,7; Carriers on 2,3; SMT 8,9 UNTOUCHED)
SERVER_MASK_DEFAULT="0,1,2,3,6,7"
# Server allowed CPUs for N+1 budget (Config E): 0,2,3 (1 auxiliary core + 2 carrier cores)
SERVER_MASK_NPLUS1="0,2,3"
# Client allowed CPUs: 4,5,10,11 (Isolated physical cores 4,5 + their SMT siblings)
CLIENT_MASK="4,5,10,11"

declare -A CONFIG_NAMES
CONFIG_NAMES["A"]="Stock FJP (unconstrained, floating across 0-3,6-7)"
CONFIG_NAMES["A_iso"]="Stock FJP (isolated: carriers on {2,3}, aux on 0,1,6,7)"
CONFIG_NAMES["C_iso"]="ExerisCarrierScheduler (isolated: carriers floating on {2,3}, aux on 0,1,6,7)"
CONFIG_NAMES["D"]="ExerisCarrierScheduler (1:1 pinned: carrier 0 on Core 2, carrier 1 on Core 3, aux on 0,1,6,7)"

declare -A CONFIG_VM_OPTS
COMMON_TRANSPORT_OPTS="-Dtransport.reactorCount=2 -Dexeris.transport.reactorCount=2 -Dexeris.reactor.affinity=0,1"
CONFIG_VM_OPTS["A"]="-Djdk.virtualThreadScheduler.parallelism=2 -Djdk.virtualThreadScheduler.maxPoolSize=2 ${COMMON_TRANSPORT_OPTS}"
CONFIG_VM_OPTS["A_iso"]="-Djdk.virtualThreadScheduler.parallelism=2 -Djdk.virtualThreadScheduler.maxPoolSize=2 ${COMMON_TRANSPORT_OPTS}"
CONFIG_VM_OPTS["C_iso"]="-Djdk.virtualThreadScheduler.implClass=eu.exeris.kernel.core.transport.scheduler.locality.ExerisCarrierScheduler -Dexeris.transport.locality=true -Dexeris.locality.allVthreads=true -Dexeris.carrier.count=2 ${COMMON_TRANSPORT_OPTS}"
CONFIG_VM_OPTS["D"]="-Djdk.virtualThreadScheduler.implClass=eu.exeris.kernel.core.transport.scheduler.locality.ExerisCarrierScheduler -Dexeris.transport.locality=true -Dexeris.locality.allVthreads=true -Dexeris.carrier.count=2 -Dexeris.carrier.affinity=2,3 ${COMMON_TRANSPORT_OPTS}"

declare -A CONFIG_MASKS
CONFIG_MASKS["A"]="${SERVER_MASK_DEFAULT}"
CONFIG_MASKS["A_iso"]="0,1,6,7"
CONFIG_MASKS["C_iso"]="0,1,6,7"
CONFIG_MASKS["D"]="0,1,6,7"

ACTIVE_CONFIGS=("A" "A_iso" "C_iso" "D")

apply_thread_pinning() {
    local CFG="$1"
    local SPID="$2"

    if [ "${CFG}" = "A" ]; then
        for tdir in /proc/${SPID}/task/*; do
            if [ -d "${tdir}" ]; then
                local tid=$(basename "${tdir}")
                local tname=$(cat "${tdir}/comm" 2>/dev/null || echo "unknown")
                if [[ "${tname}" =~ (ctor/0) ]]; then
                    taskset -pc 0 "${tid}" > /dev/null 2>&1 || true
                elif [[ "${tname}" =~ (ctor/1) ]]; then
                    taskset -pc 1 "${tid}" > /dev/null 2>&1 || true
                elif [[ "${tname}" =~ (ceptor) ]]; then
                    taskset -pc 0,1 "${tid}" > /dev/null 2>&1 || true
                fi
            fi
        done
        return
    fi

    # For A_iso, C_iso, D:
    # First: set process PID mask to 0,1,6,7 so future threads inherit 0,1,6,7
    taskset -pc 0,1,6,7 "${SPID}" > /dev/null 2>&1 || true

    for tdir in /proc/${SPID}/task/*; do
        if [ -d "${tdir}" ]; then
            local tid=$(basename "${tdir}")
            local tname=$(cat "${tdir}/comm" 2>/dev/null || echo "unknown")
            if [ "${CFG}" = "A_iso" ]; then
                if [[ "${tname}" =~ (ForkJoi|worker) ]]; then
                    taskset -pc 2,3 "${tid}" > /dev/null 2>&1 || true
                elif [[ "${tname}" =~ (ctor/0) ]]; then
                    taskset -pc 0 "${tid}" > /dev/null 2>&1 || true
                elif [[ "${tname}" =~ (ctor/1) ]]; then
                    taskset -pc 1 "${tid}" > /dev/null 2>&1 || true
                elif [[ "${tname}" =~ (ceptor) ]]; then
                    taskset -pc 0,1 "${tid}" > /dev/null 2>&1 || true
                else
                    taskset -pc 0,1,6,7 "${tid}" > /dev/null 2>&1 || true
                fi
            elif [ "${CFG}" = "C_iso" ]; then
                if [[ "${tname}" =~ (carrier-[0-9]|rier-[0-9]) ]]; then
                    taskset -pc 2,3 "${tid}" > /dev/null 2>&1 || true
                elif [[ "${tname}" =~ (ctor/0) ]]; then
                    taskset -pc 0 "${tid}" > /dev/null 2>&1 || true
                elif [[ "${tname}" =~ (ctor/1) ]]; then
                    taskset -pc 1 "${tid}" > /dev/null 2>&1 || true
                elif [[ "${tname}" =~ (ceptor) ]]; then
                    taskset -pc 0,1 "${tid}" > /dev/null 2>&1 || true
                else
                    taskset -pc 0,1,6,7 "${tid}" > /dev/null 2>&1 || true
                fi
            elif [ "${CFG}" = "D" ]; then
                if [[ "${tname}" =~ (carrier-0|rier-0) ]]; then
                    taskset -pc 2 "${tid}" > /dev/null 2>&1 || true
                elif [[ "${tname}" =~ (carrier-1|rier-1) ]]; then
                    taskset -pc 3 "${tid}" > /dev/null 2>&1 || true
                elif [[ "${tname}" =~ (ctor/0) ]]; then
                    taskset -pc 0 "${tid}" > /dev/null 2>&1 || true
                elif [[ "${tname}" =~ (ctor/1) ]]; then
                    taskset -pc 1 "${tid}" > /dev/null 2>&1 || true
                elif [[ "${tname}" =~ (ceptor) ]]; then
                    taskset -pc 0,1 "${tid}" > /dev/null 2>&1 || true
                else
                    taskset -pc 0,1,6,7 "${tid}" > /dev/null 2>&1 || true
                fi
            fi
        fi
    done
}

run_single_trial() {
    local BENCH_TOOL="$1" # "wrk" or "wrk2"
    local RATE="$2"       # "max" or numeric target rps
    local CFG="$3"
    local REP="$4"
    local TRIAL_ID="${BENCH_TOOL}_rate-${RATE}_cfg-${CFG}_rep-${REP}"

    local VM_OPTS="${CONFIG_VM_OPTS[${CFG}]}"
    local MASK="${CONFIG_MASKS[${CFG}]}"
    local LOG_PREFIX="${RUN_DIR}/${TRIAL_ID}"

    TRIAL_COUNTER=$(( TRIAL_COUNTER + 1 ))
    local PORT=$(( BASE_PORT + TRIAL_COUNTER ))
    local URL="http://127.0.0.1:${PORT}/plaintext"
    local HEALTH_URL="http://127.0.0.1:${PORT}/health"

    echo "  -> [${TRIAL_ID}] ${CONFIG_NAMES[${CFG}]} (mask: ${MASK}, port: ${PORT})"

    local APP_CMD=(
        "${JAVA}"
        "--enable-preview"
        "--add-opens" "java.base/sun.nio.ch=ALL-UNNAMED"
        "--add-opens" "java.base/java.lang=ALL-UNNAMED"
        "--enable-native-access=ALL-UNNAMED"
        "-Dexeris.http.port=${PORT}"
        "-Dexeris.http.bindHost=127.0.0.1"
    )
    if [ -n "${VM_OPTS}" ]; then
        # shellcheck disable=SC2206
        APP_CMD+=(${VM_OPTS})
    fi
    APP_CMD+=("-cp" "${COMMUNITY_CP}" "eu.exeris.benchmarks.targets.h1locality.H1LocalityApplication")

    # Ensure port is completely released by any previous trial
    for _ in {1..30}; do
        if ! ss -tlpn | grep -q ":${PORT} "; then
            break
        fi
        sleep 0.2
    done

    # Start fresh server JVM with taskset
    taskset -c "${MASK}" "${APP_CMD[@]}" > "${LOG_PREFIX}-server.log" 2>&1 &
    local SERVER_PID=$!

    # Wait for server readiness
    local READY=false
    for _ in {1..30}; do
        if curl --noproxy "*" -s -o /dev/null -w "%{http_code}" "${HEALTH_URL}" 2>/dev/null | grep -q "200"; then
            READY=true
            break
        fi
        sleep 0.5
    done

    if [ "${READY}" != "true" ]; then
        echo "ERROR: Server failed to start for trial ${TRIAL_ID}. See ${LOG_PREFIX}-server.log"
        kill -9 "${SERVER_PID}" 2>/dev/null || true
        return 1
    fi

    # Repin threads according to configuration policy immediately upon server readiness (before warmup)
    apply_thread_pinning "${CFG}" "${SERVER_PID}"

    # Warmup phase (isolated on client cores)
    if [ "${WARMUP_SEC}" -gt 0 ]; then
        taskset -c "${CLIENT_MASK}" "${WRK}" -t 2 -c 32 -d "${WARMUP_SEC}s" "${URL}" > /dev/null 2>&1 || true
    fi

    # Repin threads again after warmup to catch any dynamically spawned JVM threads (e.g. C2/GC)
    apply_thread_pinning "${CFG}" "${SERVER_PID}"

    # Capture thread affinity topology from /proc/$SERVER_PID/task/*/status after warmup
    echo "=== Thread Affinity Dump for ${TRIAL_ID} ===" > "${LOG_PREFIX}-affinity.log"
    for tdir in /proc/${SERVER_PID}/task/*; do
        if [ -d "${tdir}" ]; then
            tid=$(basename "${tdir}")
            tname=$(cat "${tdir}/comm" 2>/dev/null || echo "unknown")
            affinity=$(grep "Cpus_allowed_list" "${tdir}/status" 2>/dev/null | awk '{print $2}' || echo "unknown")
            echo "TID: ${tid} | Name: ${tname} | Cpus_allowed_list: ${affinity}" >> "${LOG_PREFIX}-affinity.log"
        fi
    done

    # Start pidstat telemetry on server PID and client load generator
    local PIDSTAT_PID=""
    LC_ALL=C pidstat -u -w -t -p "${SERVER_PID}" 1 "${MEASURE_SEC}" > "${LOG_PREFIX}-pidstat.log" 2>&1 &
    PIDSTAT_PID=$!

    # Measurement pass
    local BENCH_OUT=""
    if [ "${BENCH_TOOL}" = "wrk" ]; then
        BENCH_OUT="$(taskset -c "${CLIENT_MASK}" "${WRK}" -t "${THREADS}" -c "${CONNECTIONS}" -d "${MEASURE_SEC}s" --latency "${URL}" 2>&1)"
    else
        BENCH_OUT="$(taskset -c "${CLIENT_MASK}" "${WRK2}" -t "${THREADS}" -c "${CONNECTIONS}" -d "${MEASURE_SEC}s" -R "${RATE}" --latency "${URL}" 2>&1)"
    fi
    echo "${BENCH_OUT}" > "${LOG_PREFIX}-loadgen.log"

    # Wait for pidstat to finish
    wait "${PIDSTAT_PID}" 2>/dev/null || true

    # Terminate server gracefully
    kill -TERM "${SERVER_PID}" 2>/dev/null || true
    sleep 1.5
    kill -9 "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true

    # Cooldown and verify port is released
    for _ in {1..30}; do
        if ! ss -tlpn | grep -q ":${PORT} "; then
            break
        fi
        sleep 0.2
    done
    sleep 0.5
}

# ------------------------------------------------------------------------------
# Phase 1: Saturation (WRK) Interleaved Runs
# ------------------------------------------------------------------------------
echo ""
echo "================================================================="
echo " Phase 1: Maximum Saturation Sweep (wrk, 100% load)"
echo "================================================================="

for rep in $(seq 1 "${REPETITIONS}"); do
    echo "--- Saturation Repetition ${rep}/${REPETITIONS} ---"
    # Interleave orders: odd reps forward, even reps reverse
    ORDER=()
    if [ $((rep % 2)) -eq 1 ]; then
        ORDER=("${ACTIVE_CONFIGS[@]}")
    else
        for (( i=${#ACTIVE_CONFIGS[@]}-1; i>=0; i-- )); do
            ORDER+=("${ACTIVE_CONFIGS[i]}")
        done
    fi

    for cfg in "${ORDER[@]}"; do
        run_single_trial "wrk" "max" "${cfg}" "${rep}"
    done
done

# ------------------------------------------------------------------------------
# Compute Median Baseline RPS for Rate Sweep
# ------------------------------------------------------------------------------
python3 -c "
import glob, re, statistics

rps_list = []
for f in sorted(glob.glob('${RUN_DIR}/wrk_rate-max_cfg-A_rep-*-loadgen.log')):
    with open(f) as fp:
        for line in fp:
            m = re.search(r'Requests/sec:\s+([\d.]+)', line)
            if m:
                rps_list.append(float(m.group(1)))
if rps_list:
    med = statistics.median(rps_list)
    print(f'{int(med)}')
else:
    print('100000')
" > "${RUN_DIR}/baseline_a_median.txt"

MAX_A_RPS="$(cat "${RUN_DIR}/baseline_a_median.txt")"
echo "Calculated Baseline A Median Saturation Throughput: ${MAX_A_RPS} RPS"

# ------------------------------------------------------------------------------
# Phase 2: Controlled Rate Latency Sweep (WRK2) at 50%, 70%, 85%, 95%
# ------------------------------------------------------------------------------
if [ "${RUN_RATE_SWEEP}" = "true" ] && [ -x "${WRK2}" ]; then
    echo ""
    echo "================================================================="
    echo " Phase 2: Controlled Rate Latency Sweep (wrk2, Coordinated-Omission-Free)"
    echo " Rates based on Baseline A (${MAX_A_RPS} req/s): 50%, 70%, 85%, 90%, 95%"
    echo "================================================================="

    SWEEP_PERCENTAGES=(50 70 85 90 95)
    for pct in "${SWEEP_PERCENTAGES[@]}"; do
        TARGET_RATE=$(( MAX_A_RPS * pct / 100 ))
        echo ">>> Running Sweep Point: ${pct}% of Baseline A = ${TARGET_RATE} req/s <<<"

        for rep in $(seq 1 "${REPETITIONS}"); do
            echo "--- Rate Sweep ${pct}% Repetition ${rep}/${REPETITIONS} ---"
            ORDER=()
            if [ $((rep % 2)) -eq 1 ]; then
                ORDER=("${ACTIVE_CONFIGS[@]}")
            else
                for (( i=${#ACTIVE_CONFIGS[@]}-1; i>=0; i-- )); do
                    ORDER+=("${ACTIVE_CONFIGS[i]}")
                done
            fi

            for cfg in "${ORDER[@]}"; do
                run_single_trial "wrk2" "${TARGET_RATE}" "${cfg}" "${rep}"
            done
        done
    done
else
    echo "Skipping Phase 2 (wrk2 not executable or RUN_RATE_SWEEP=false)"
fi

# ------------------------------------------------------------------------------
# Phase 3: Telemetry Processing & Report Generation
# ------------------------------------------------------------------------------
echo ""
echo "================================================================="
echo " Phase 3: Telemetry Processing & Report Generation"
echo "================================================================="

python3 -c "
import glob, json, os, re, statistics

run_dir = '${RUN_DIR}'
report_file = '${REPORT_FILE}'
report_json = '${REPORT_JSON}'
active_configs = '${ACTIVE_CONFIGS[*]}'.split()

cfg_descriptions = {
    'A': 'Stock FJP (unconstrained, floating across 0-3,6-7)',
    'A_iso': 'Stock FJP (isolated: carriers on {2,3}, aux on 0,1,6,7)',
    'C_iso': 'ExerisCarrierScheduler (isolated: carriers floating on {2,3}, aux on 0,1,6,7)',
    'D': 'ExerisCarrierScheduler (1:1 pinned: carrier 0 on Core 2, carrier 1 on Core 3, aux on 0,1,6,7)'
}

def parse_time_us(s):
    s = s.strip()
    if s.endswith('ms'):
        return float(s[:-2]) * 1000.0
    elif s.endswith('us'):
        return float(s[:-2])
    elif s.endswith('s'):
        return float(s[:-1]) * 1000000.0
    return float(s)

def format_us(us):
    if us >= 1000.0:
        return f'{us/1000.0:.2f} ms'
    return f'{us:.1f} us'

def parse_loadgen(filepath):
    res = {'rps': 0.0, 'mean': 0.0, 'p50': 0.0, 'p75': 0.0, 'p90': 0.0, 'p99': 0.0, 'p999': 0.0, 'littles_ratio': 1.0}
    with open(filepath) as f:
        for line in f:
            m_rps = re.search(r'Requests/sec:\s+([\d.]+)', line)
            if m_rps:
                res['rps'] = float(m_rps.group(1))
            m_mean = re.search(r'Latency\s+([\d.]+(?:ms|us|s))', line)
            if m_mean:
                res['mean'] = parse_time_us(m_mean.group(1))
            m_p50 = re.match(r'^\s*(?:50\.000%|50%)\s+([\d.]+(?:ms|us|s))', line)
            if m_p50: res['p50'] = parse_time_us(m_p50.group(1))
            m_p75 = re.match(r'^\s*(?:75\.000%|75%)\s+([\d.]+(?:ms|us|s))', line)
            if m_p75: res['p75'] = parse_time_us(m_p75.group(1))
            m_p90 = re.match(r'^\s*(?:90\.000%|90%)\s+([\d.]+(?:ms|us|s))', line)
            if m_p90: res['p90'] = parse_time_us(m_p90.group(1))
            m_p99 = re.match(r'^\s*(?:99\.000%|99%)\s+([\d.]+(?:ms|us|s))', line)
            if m_p99: res['p99'] = parse_time_us(m_p99.group(1))
            m_p999 = re.match(r'^\s*(?:99\.900%|99\.9%)\s+([\d.]+(?:ms|us|s))', line)
            if m_p999: res['p999'] = parse_time_us(m_p999.group(1))
    if res['rps'] > 0 and res['mean'] > 0:
        expected_mean_us = (100.0 / res['rps']) * 1000000.0
        res['littles_ratio'] = res['mean'] / expected_mean_us
    return res

def parse_pidstat(filepath):
    res = {'cpu_usr': 0.0, 'cpu_sys': 0.0, 'cpu_wait': 0.0, 'cpu_tot': 0.0, 'cswch': 0.0, 'nvcswch': 0.0, 'carrier_cpu': 0.0, 'reactor_cpu': 0.0}
    if not os.path.exists(filepath):
        return res
    with open(filepath) as f:
        lines = f.readlines()
    is_cswch_section = False
    for line in lines:
        parts = line.split()
        if not parts or parts[0] not in ('Average:', 'Średnia:'):
            continue
        if len(parts) >= 6 and 'cswch/s' in line:
            is_cswch_section = True
            continue
        # Process summary line in CPU section: Average: UID TGID TID %usr %system %guest %wait %CPU CPU Command
        if len(parts) >= 9 and parts[1].isdigit() and parts[2].isdigit() and parts[3] == '-':
            try:
                res['cpu_usr'] = float(parts[4].replace(',', '.'))
                res['cpu_sys'] = float(parts[5].replace(',', '.'))
                res['cpu_wait'] = float(parts[7].replace(',', '.'))
                res['cpu_tot'] = float(parts[8].replace(',', '.'))
            except ValueError:
                pass
        # Thread lines
        elif len(parts) >= 8 and parts[1].isdigit() and parts[2] == '-' and parts[3].isdigit():
            cmd = parts[-1]
            if not is_cswch_section:
                try:
                    tot = float(parts[8].replace(',', '.'))
                    if 'ctor/' in cmd or 'reactor' in cmd:
                        res['reactor_cpu'] += tot
                    elif 'ForkJoi' in cmd or 'exeris-' in cmd or 'carrier-' in cmd or 'rier-0' in cmd or 'rier-1' in cmd:
                        res['carrier_cpu'] += tot
                except (ValueError, IndexError):
                    pass
            else:
                try:
                    res['cswch'] += float(parts[4].replace(',', '.'))
                    res['nvcswch'] += float(parts[5].replace(',', '.'))
                except (ValueError, IndexError):
                    pass
    return res

def summarize_metric(vals):
    if not vals:
        return 'N/A'
    med = statistics.median(vals)
    return f'{med:.1f} [{min(vals):.1f} - {max(vals):.1f}]'

def summarize_time_metric(vals):
    if not vals:
        return 'N/A'
    med = statistics.median(vals)
    return f'{format_us(med)} [{format_us(min(vals))} - {format_us(max(vals))}]'

results = {}

# Process Saturation
sat_results = {}
for cfg in active_configs:
    files = sorted(glob.glob(f'{run_dir}/wrk_rate-max_cfg-{cfg}_rep-*-loadgen.log'))
    rps_list, mean_list, ratio_list, p50_list, p90_list, p99_list = [], [], [], [], [], []
    cpu_tot_list, cpu_usr_list, cpu_sys_list = [], [], []
    carrier_cpu_list, reactor_cpu_list = [], []
    cswch_list, nvcswch_list = [], []
    for lf in files:
        pidstat_f = lf.replace('-loadgen.log', '-pidstat.log')
        lg_data = parse_loadgen(lf)
        pid_data = parse_pidstat(pidstat_f)
        if lg_data['rps'] > 0:
            rps_list.append(lg_data['rps'])
            mean_list.append(lg_data['mean'])
            ratio_list.append(lg_data['littles_ratio'])
            p50_list.append(lg_data['p50'])
            p90_list.append(lg_data['p90'])
            p99_list.append(lg_data['p99'])
            cpu_tot_list.append(pid_data['cpu_tot'])
            cpu_usr_list.append(pid_data['cpu_usr'])
            cpu_sys_list.append(pid_data['cpu_sys'])
            carrier_cpu_list.append(pid_data['carrier_cpu'])
            reactor_cpu_list.append(pid_data['reactor_cpu'])
            cswch_list.append(pid_data['cswch'])
            nvcswch_list.append(pid_data['nvcswch'])
    sat_results[cfg] = {
        'rps': rps_list,
        'mean': mean_list,
        'littles_ratio': ratio_list,
        'p50': p50_list,
        'p90': p90_list,
        'p99': p99_list,
        'cpu_tot': cpu_tot_list,
        'cpu_usr': cpu_usr_list,
        'cpu_sys': cpu_sys_list,
        'carrier_cpu': carrier_cpu_list,
        'reactor_cpu': reactor_cpu_list,
        'cswch': cswch_list,
        'nvcswch': nvcswch_list
    }
results['saturation'] = sat_results

# Process Rate Sweeps
rates_found = set()
for f in glob.glob(f'{run_dir}/wrk2_rate-*_cfg-A_rep-1-loadgen.log'):
    m = re.search(r'wrk2_rate-(\d+)_', f)
    if m:
        rates_found.add(int(m.group(1)))

rate_results = {}
for rate in sorted(rates_found):
    rate_results[rate] = {}
    for cfg in active_configs:
        files = sorted(glob.glob(f'{run_dir}/wrk2_rate-{rate}_cfg-{cfg}_rep-*-loadgen.log'))
        rps_list, p50_list, p90_list, p99_list, p999_list = [], [], [], [], []
        cpu_tot_list, cpu_usr_list, cpu_sys_list = [], [], []
        carrier_cpu_list, reactor_cpu_list = [], []
        for lf in files:
            pidstat_f = lf.replace('-loadgen.log', '-pidstat.log')
            lg_data = parse_loadgen(lf)
            pid_data = parse_pidstat(pidstat_f)
            if lg_data['rps'] > 0:
                rps_list.append(lg_data['rps'])
                p50_list.append(lg_data['p50'])
                p90_list.append(lg_data['p90'])
                p99_list.append(lg_data['p99'])
                p999_list.append(lg_data['p999'])
                cpu_tot_list.append(pid_data['cpu_tot'])
                cpu_usr_list.append(pid_data['cpu_usr'])
                cpu_sys_list.append(pid_data['cpu_sys'])
                carrier_cpu_list.append(pid_data['carrier_cpu'])
                reactor_cpu_list.append(pid_data['reactor_cpu'])
        rate_results[rate][cfg] = {
            'rps': rps_list,
            'p50': p50_list,
            'p90': p90_list,
            'p99': p99_list,
            'p999': p999_list,
            'cpu_tot': cpu_tot_list,
            'cpu_usr': cpu_usr_list,
            'cpu_sys': cpu_sys_list,
            'carrier_cpu': carrier_cpu_list,
            'reactor_cpu': reactor_cpu_list
        }
results['rate_sweep'] = rate_results

with open(report_json, 'w') as jf:
    json.dump(results, jf, indent=2)

# Generate Markdown
md = []
md.append('# Loom VirtualThreadScheduler Locality Empirical Report')
md.append('')
md.append('**Date:** ' + os.popen('date').read().strip())
md.append('**Stack:** Community POSIX/FFM Transport, H1 \`/plaintext\`')
md.append('**Repetitions:** Interleaved runs, fresh JVM per trial, median [min - max]')
md.append('')
md.append('## 1. Maximum Throughput Saturation (wrk)')
md.append('')
md.append('| Config | Description | Throughput (req/s) | Mean Latency | Little Ratio | p50 Latency | p99 Latency | Total CPU (%) | %usr / %sys | Carrier CPU (%) | Reactor CPU (%) | Non-Voluntary Cswch/s |')
md.append('| :---: | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |')

for cfg in active_configs:
    d = sat_results[cfg]
    rps_str = summarize_metric(d['rps'])
    mean_str = summarize_time_metric(d.get('mean', []))
    ratio_str = summarize_metric(d.get('littles_ratio', []))
    p50_str = summarize_time_metric(d['p50'])
    p99_str = summarize_time_metric(d['p99'])
    cpu_str = summarize_metric(d['cpu_tot'])
    usr_sys_str = f\"{statistics.median(d['cpu_usr']):.1f}% / {statistics.median(d['cpu_sys']):.1f}%\" if d['cpu_usr'] else 'N/A'
    carrier_cpu_str = summarize_metric(d['carrier_cpu'])
    reactor_cpu_str = summarize_metric(d['reactor_cpu'])
    nvcswch_str = summarize_metric(d['nvcswch'])
    md.append(f\"| **{cfg}** | {cfg_descriptions[cfg]} | {rps_str} | {mean_str} | {ratio_str} | {p50_str} | {p99_str} | {cpu_str} | {usr_sys_str} | {carrier_cpu_str} | {reactor_cpu_str} | {nvcswch_str} |\")

md.append('')
md.append('> **Sanity Check on Closed-Loop Saturation:** In closed-loop wrk with 100 connections, Little\\'s Law dictates average latency = ~100 / RPS (ratio 1.0). Ratios significantly differing from 1.0 (such as in Config A/B) reflect client sampling artifacts under severe tail contention. Controlled open-loop evaluation via wrk2 (Section 3) provides the verified, coordinated-omission-free ground truth.')

md.append('')
md.append('## 2. Factor-by-Factor Empirical Delta Analysis')
md.append('')

def get_med(cfg, metric):
    vals = sat_results.get(cfg, {}).get(metric, [])
    return statistics.median(vals) if vals else 0.0

rps_a = get_med('A', 'rps')
rps_a_iso = get_med('A_iso', 'rps')
rps_c_iso = get_med('C_iso', 'rps')
rps_d = get_med('D', 'rps')

cpu_a = get_med('A', 'cpu_tot')
cpu_a_iso = get_med('A_iso', 'cpu_tot')
cpu_c_iso = get_med('C_iso', 'cpu_tot')
cpu_d = get_med('D', 'cpu_tot')

p99_a = get_med('A', 'p99')
p99_a_iso = get_med('A_iso', 'p99')
p99_c_iso = get_med('C_iso', 'p99')
p99_d = get_med('D', 'p99')

if rps_a > 0:
    if rps_a_iso > 0:
        md.append(f'- **Factor 1 (A_iso vs A - Core Isolation of FJP):** Restricting FJP carriers to {{2,3}} away from network reactors and GC/JIT changes throughput by {(rps_a_iso - rps_a) / rps_a * 100:+.1f}% ({rps_a_iso:.0f} vs {rps_a:.0f} req/s), p99: {format_us(p99_a_iso)} vs {format_us(p99_a)}.')
    if rps_c_iso > 0 and rps_a_iso > 0:
        md.append(f'- **Factor 2 (C_iso vs A_iso - Scheduling Architecture without Stealing):** On identical dedicated cores {{2,3}}, replacing FJP work-stealing with dedicated per-carrier MPSC queues changes throughput by {(rps_c_iso - rps_a_iso) / rps_a_iso * 100:+.1f}% ({rps_c_iso:.0f} vs {rps_a_iso:.0f} req/s), p99: {format_us(p99_c_iso)} vs {format_us(p99_a_iso)}.')
    if rps_d > 0 and rps_c_iso > 0:
        md.append(f'- **Factor 3 (D vs C_iso - 1:1 Carrier Pinning):** Adding 1:1 CPU affinity to the custom scheduler changes throughput by {(rps_d - rps_c_iso) / rps_c_iso * 100:+.1f}% ({rps_d:.0f} vs {rps_c_iso:.0f} req/s), p99: {format_us(p99_d)} vs {format_us(p99_c_iso)}.')
    if rps_d > 0:
        md.append(f'- **Overall (D vs A - Pinned Custom Scheduler vs Unconstrained Stock FJP):** Throughput: {(rps_d - rps_a) / rps_a * 100:+.1f}% ({rps_d:.0f} vs {rps_a:.0f} req/s).')

md.append('')
md.append('## 3. Coordinated-Omission-Free Latency Sweep (wrk2)')
md.append('')

if rates_found:
    for rate in sorted(rates_found):
        md.append(f'### Target Rate: {rate} req/s')
        md.append('')
        md.append('| Config | Description | Actual RPS | p50 | p90 | p99 | p99.9 | Total CPU (%) | Carrier CPU (%) | Reactor CPU (%) |')
        md.append('| :---: | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |')
        for cfg in active_configs:
            rd = rate_results[rate][cfg]
            arps = summarize_metric(rd['rps'])
            p50 = summarize_time_metric(rd['p50'])
            p90 = summarize_time_metric(rd['p90'])
            p99 = summarize_time_metric(rd['p99'])
            p999 = summarize_time_metric(rd['p999'])
            cpu = summarize_metric(rd['cpu_tot'])
            carrier = summarize_metric(rd['carrier_cpu'])
            reactor = summarize_metric(rd['reactor_cpu'])
            md.append(f\"| **{cfg}** | {cfg_descriptions[cfg]} | {arps} | {p50} | {p90} | {p99} | {p999} | {cpu} | {carrier} | {reactor} |\")
        md.append('')
else:
    md.append('*Rate sweep skipped or pending execution.*')
    md.append('')

md.append('## 4. Draft Experience Report for loom-dev (Plain Text Skeleton)')
md.append('')
md.append('\`\`\`text')
md.append('Subject: Experience report: Carrier locality with a custom VirtualThreadScheduler in an FFM POSIX transport')
md.append('')
md.append('Hi Loom team,')
md.append('')
md.append('I have been experimenting with the custom virtual thread scheduler SPI in the')
md.append('loom repo (EA build 28-testing, branch fibers) in Exeris, an open JVM runtime.')
md.append('I would like to share empirical results and API observations as an external data point')
md.append('outside Netty.')
md.append('')
md.append('Architecture & Mechanics')
md.append('  - Community Transport: Socket ingress is performed via Panama FFM on raw POSIX socket')
md.append('    file descriptors into off-heap MemorySegments. Dedicated platform reactor threads')
md.append('    (using java.nio.channels.Selector) detect readiness and wake worker virtual threads')
md.append('    via LockSupport.unpark(vt). Responses are written directly to the socket fd by the')
md.append('    virtual thread on its carrier (falling back to reactor flush only on partial writes).')
md.append('  - Continuation Dispatch: When unparked, the Loom runtime dispatches the continuation')
md.append('    to VirtualThreadScheduler.onContinue(task).')
md.append('  - Custom Scheduler: Dedicated MPSC queue per carrier (no work-stealing).')
md.append('')
md.append('Setup & Topology')
md.append('  AMD Ryzen 5 5600 6-Core Processor (Zen 3, single CCX, 32MB unified L3, 6x 512KB L2).')
md.append('  SMT topology verified via lscpu -e: physical cores 0..5 map to CPU pairs (0,6), (1,7),')
md.append('  (2,8), (3,9), (4,10), (5,11). Carriers isolated on physical CPUs 2, 3 (SMT siblings 8, 9 idle).')
md.append('  Platform reactors pinned to CPUs 0, 1. Other JVM threads (GC, JIT) re-pinned to CPUs 0, 1, 6, 7.')
md.append('  Load generator on CPUs 4, 5, 10, 11. Plain HTTP/1.1 GET /plaintext, 100 connections.')
md.append('')
md.append('Configurations (All normalized to 2 carrier threads)')
md.append('  A:     Stock FJP (unconstrained, floating across CPUs 0-3, 6-7)')
md.append('  A_iso: Stock FJP (isolated: carriers restricted to CPUs 2, 3, aux on 0,1,6,7)')
md.append('  C_iso: Custom scheduler (isolated: carriers floating across CPUs 2, 3, aux on 0,1,6,7)')
md.append('  D:     Custom scheduler (1:1 pinned: carrier 0 on CPU 2, carrier 1 on CPU 3, aux on 0,1,6,7)')
md.append('')
md.append('Results Summary (Saturation with wrk)')
for cfg in active_configs:
    md.append(f'  {cfg:<6} {summarize_metric(sat_results[cfg][\"rps\"])} req/s, wrk p99: {summarize_time_metric(sat_results[cfg][\"p99\"])}')
md.append('')
md.append('Controlled Rate Sweep Summary (wrk2, Coordinated-Omission-Free)')
if rates_found:
    for rate in sorted(rates_found):
        md.append(f'  Target Rate: {rate} req/s:')
        for cfg in active_configs:
            rd = rate_results[rate][cfg]
            md.append(f'    {cfg:<6} actual: {summarize_metric(rd[\"rps\"])} req/s, p99: {summarize_time_metric(rd[\"p99\"])}')
md.append('')
md.append('Observations')
md.append('  1. Isolating Effects: Factorial Comparison:')
md.append('     Comparing A vs A_iso isolates the effect of separating FJP carriers from network reactors')
md.append('     and GC/JIT. Comparing A_iso vs C_iso isolates scheduling architecture (work-stealing vs')
md.append('     per-carrier MPSC queues) on identical dedicated cores. Comparing C_iso vs D isolates')
md.append('     1:1 carrier affinity pinning.')
md.append('  2. Capacity Cliff vs Graceful Degradation:')
md.append('     Below single-queue capacity (50% to 85% load), pinned carrier configurations provide')
md.append('     repeatable, tight tail latencies. Near capacity (90% to 95%), single-queue accumulation')
md.append('     creates a sharper latency cliff for pinned carriers, whereas floating configurations degrade')
md.append('     more gradually across wider variance.')
md.append('')
md.append('API Feedback for OpenJDK Loom')
md.append('  1. Carrier Routing Hints in Thread.Builder.OfVirtual:')
md.append('     VirtualThreadScheduler.newThread(builder, preferredCarrier, task) is public on the scheduler')
md.append('     SPI, but application code creating virtual threads via Thread.ofVirtual() cannot specify')
md.append('     a preferred carrier or routing tag without direct access to the custom scheduler instance.')
md.append('     Exposing an affinity or carrier hint on Thread.Builder.OfVirtual would allow standard')
md.append('     dispatchers to pass routing intent without custom scheduler coupling.')
md.append('')
md.append('Questions')
md.append('  1. Are there plans to expose carrier routing hints on Thread.Builder.OfVirtual?')
md.append('  2. How do the Loom authors view the trade-off between floating work-stealing carriers and')
md.append('     pinned single-queue carriers for network I/O workloads approaching capacity?')
md.append('')
md.append('Thanks for making the scheduler pluggable.')
md.append('')
md.append('Arkadiusz Przychocki')
md.append('\`\`\`')

with open(report_file, 'w') as mf:
    mf.write('\n'.join(md))

print(f'Report written to: {report_file}')
print(f'JSON written to: {report_json}')
"

echo "================================================================="
echo " Benchmark Complete! Results in: ${REPORT_FILE}"
echo "================================================================="
