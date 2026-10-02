#!/usr/bin/env bash
# ==============================================================================
# run-loom-cache-locality-sweep.sh
#
# Direct empirical evaluation of Francesco Nigro's cache locality thesis in
# OpenJDK Loom (EA build 28-testing, branch fibers).
#
# Workload: /delayed endpoint parking virtual thread for 20 ms while allocating
# and dirtying/reading 8 KB of state (every 64-byte cache line) before and after.
#
# Sweep: 100, 1,000, 10,000 concurrent connections at fixed rate (3,000 req/s)
#   - 100 conns:   working set < 1 MB << 32 MB L3 (in-cache baseline)
#   - 1,000 conns: working set ~8 MB > 2x 512 KB L2 (L2 overflow)
#   - 10,000 conns: working set ~80 MB > 2.5x 32 MB L3 (LLC spillover into DRAM)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_ROOT="$(cd "${BENCH_ROOT}/.." && pwd)"

JDK_HOME="${WORKSPACE_ROOT}/tools/jdk-loom/current"
JAVA="${JDK_HOME}/bin/java"
WRK2="${WRK2:-${WORKSPACE_ROOT}/tools/wrk2/wrk2}"

APP_JAR="${BENCH_ROOT}/targets/exeris-h1-locality-app/target/exeris-h1-locality-app.jar"
REPORT_DIR="${BENCH_ROOT}/results/reports/loomdev-cache-sweep"
mkdir -p "${REPORT_DIR}"

BASE_PORT="${BENCH_BASE_PORT:-8200}"
TRIAL_COUNTER=0

CLIENT_THREADS="${BENCH_CLIENT_THREADS:-2}"
WARMUP_SEC="${WARMUP_SEC:-6}"
MEASURE_SEC="${MEASURE_SEC:-12}"
REPETITIONS="${REPETITIONS:-2}"
FIXED_RATE="${FIXED_RATE:-3000}"
DELAY_MS="${DELAY_MS:-20}"
STATE_KB="${STATE_KB:-8}"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${REPORT_DIR}/run-${TIMESTAMP}"
mkdir -p "${RUN_DIR}"

REPORT_FILE="${REPORT_DIR}/REPORT-CACHE-SWEEP-${TIMESTAMP}.md"
REPORT_JSON="${REPORT_DIR}/REPORT-CACHE-SWEEP-${TIMESTAMP}.json"

export no_proxy="127.0.0.1,localhost,*"
export NO_PROXY="127.0.0.1,localhost,*"

echo "================================================================="
echo " OpenJDK Loom Cache Locality Concurrency Sweep Benchmark"
echo " Date         : $(date)"
echo " CPU          : AMD Ryzen 5 5600 6-Core (Zen 3, single CCX, 32MB L3)"
echo " Workload     : /delayed (${DELAY_MS} ms delay, ${STATE_KB} KB state touched)"
echo " Fixed Rate   : ${FIXED_RATE} req/s"
echo " Concurrency  : 100, 1000, 10000 connections"
echo " Warmup       : ${WARMUP_SEC}s, Measurement: ${MEASURE_SEC}s, Reps: ${REPETITIONS}"
echo " Output Dir   : ${RUN_DIR}"
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

SERVER_MASK_DEFAULT="0,1,2,3,6,7"
CLIENT_MASK="4,5,10,11"

declare -A CONFIG_NAMES
CONFIG_NAMES["A"]="Stock FJP (unconstrained, floating across 0-3,6-7)"
CONFIG_NAMES["A_iso"]="Stock FJP (isolated: carriers on {2,3}, aux on 0,1,6,7)"
CONFIG_NAMES["C_iso"]="ExerisCarrierScheduler (isolated: carriers floating on {2,3}, aux on 0,1,6,7)"
CONFIG_NAMES["D"]="ExerisCarrierScheduler (1:1 pinned: carrier 0 on Core 2, carrier 1 on Core 3, aux on 0,1,6,7)"

declare -A CONFIG_VM_OPTS
COMMON_TRANSPORT_OPTS="-Dtransport.reactorCount=2 -Dexeris.transport.reactorCount=2 -Dexeris.reactor.affinity=0,1 -Dexeris.simulated.delay.ms=${DELAY_MS} -Dexeris.simulated.state.kb=${STATE_KB}"
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
SWEEP_CONNS=(100 1000 10000)

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

    # Set parent process PID mask to 0,1,6,7 so future threads inherit 0,1,6,7
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
    local CONNS="$1"
    local CFG="$2"
    local REP="$3"
    local TRIAL_ID="conns-${CONNS}_cfg-${CFG}_rep-${REP}"

    local VM_OPTS="${CONFIG_VM_OPTS[${CFG}]}"
    local MASK="${CONFIG_MASKS[${CFG}]}"
    local LOG_PREFIX="${RUN_DIR}/${TRIAL_ID}"

    TRIAL_COUNTER=$(( TRIAL_COUNTER + 1 ))
    local PORT=$(( BASE_PORT + TRIAL_COUNTER ))
    local URL="http://127.0.0.1:${PORT}/delayed"
    local HEALTH_URL="http://127.0.0.1:${PORT}/health"

    echo "  -> [${TRIAL_ID}] ${CONFIG_NAMES[${CFG}]} (conns: ${CONNS}, rate: ${FIXED_RATE}, mask: ${MASK}, port: ${PORT})"

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

    # Release port
    for _ in {1..30}; do
        if ! ss -tlpn | grep -q ":${PORT} "; then
            break
        fi
        sleep 0.2
    done

    # Start server
    taskset -c "${MASK}" "${APP_CMD[@]}" > "${LOG_PREFIX}-server.log" 2>&1 &
    local SERVER_PID=$!

    # Wait for readiness
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

    # Repin immediately upon readiness
    apply_thread_pinning "${CFG}" "${SERVER_PID}"

    # Warmup phase
    if [ "${WARMUP_SEC}" -gt 0 ]; then
        local WARMUP_CONNS=$(( CONNS > 100 ? 100 : CONNS ))
        taskset -c "${CLIENT_MASK}" "${WRK2}" -t "${CLIENT_THREADS}" -c "${WARMUP_CONNS}" -d "${WARMUP_SEC}s" -R 1000 "${URL}" > /dev/null 2>&1 || true
    fi

    # Repin after warmup
    apply_thread_pinning "${CFG}" "${SERVER_PID}"

    # Dump thread affinity
    echo "=== Thread Affinity Dump for ${TRIAL_ID} ===" > "${LOG_PREFIX}-affinity.log"
    for tdir in /proc/${SERVER_PID}/task/*; do
        if [ -d "${tdir}" ]; then
            local tid=$(basename "${tdir}")
            local tname=$(cat "${tdir}/comm" 2>/dev/null || echo "unknown")
            local affinity=$(grep "Cpus_allowed_list" "${tdir}/status" 2>/dev/null | awk '{print $2}' || echo "unknown")
            echo "TID: ${tid} | Name: ${tname} | Cpus_allowed_list: ${affinity}" >> "${LOG_PREFIX}-affinity.log"
        fi
    done

    # Start pidstat telemetry
    local PIDSTAT_PID=""
    LC_ALL=C pidstat -u -w -t -p "${SERVER_PID}" 1 "${MEASURE_SEC}" > "${LOG_PREFIX}-pidstat.log" 2>&1 &
    PIDSTAT_PID=$!

    # Measurement pass with wrk2
    local BENCH_OUT=""
    BENCH_OUT="$(taskset -c "${CLIENT_MASK}" "${WRK2}" -t "${CLIENT_THREADS}" -c "${CONNS}" -d "${MEASURE_SEC}s" -R "${FIXED_RATE}" --latency "${URL}" 2>&1)"
    echo "${BENCH_OUT}" > "${LOG_PREFIX}-loadgen.log"

    # Stop pidstat
    kill -SIGINT "${PIDSTAT_PID}" 2>/dev/null || true
    wait "${PIDSTAT_PID}" 2>/dev/null || true

    # Terminate server JVM cleanly
    kill -SIGTERM "${SERVER_PID}" 2>/dev/null || true
    for _ in {1..30}; do
        if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
            break
        fi
        sleep 0.2
    done
    kill -9 "${SERVER_PID}" 2>/dev/null || true

    sleep 1
}

# Execute Sweep
for conns in "${SWEEP_CONNS[@]}"; do
    echo ""
    echo "================================================================="
    echo ">>> Running Sweep Concurrency: ${conns} Connections <<<"
    echo "================================================================="

    for rep in $(seq 1 "${REPETITIONS}"); do
        echo "--- Concurrency ${conns} Repetition ${rep}/${REPETITIONS} ---"
        ORDER=()
        if [ $((rep % 2)) -eq 1 ]; then
            ORDER=("${ACTIVE_CONFIGS[@]}")
        else
            for (( i=${#ACTIVE_CONFIGS[@]}-1; i>=0; i-- )); do
                ORDER+=("${ACTIVE_CONFIGS[i]}")
            done
        fi

        for cfg in "${ORDER[@]}"; do
            run_single_trial "${conns}" "${cfg}" "${rep}"
        done
    done
done

# Post-processing and Report Generation
echo ""
echo "================================================================="
echo " Processing Telemetry & Generating Report..."
echo "================================================================="

python3 -c "
import glob, json, os, re, statistics

run_dir = '${RUN_DIR}'
report_file = '${REPORT_FILE}'
report_json = '${REPORT_JSON}'
active_configs = '${ACTIVE_CONFIGS[*]}'.split()
sweep_conns = [int(c) for c in '${SWEEP_CONNS[*]}'.split()]

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
    if us >= 1000000.0:
        return f'{us/1000000.0:.2f} s'
    elif us >= 1000.0:
        return f'{us/1000.0:.2f} ms'
    return f'{us:.1f} us'

def parse_loadgen(filepath):
    res = {'rps': 0.0, 'mean': 0.0, 'p50': 0.0, 'p90': 0.0, 'p99': 0.0, 'p999': 0.0}
    if not os.path.exists(filepath):
        return res
    with open(filepath) as f:
        for line in f:
            m_rps = re.search(r'Requests/sec:\s+([\d.]+)', line)
            if m_rps: res['rps'] = float(m_rps.group(1))
            m_mean = re.search(r'Latency\s+([\d.]+(?:ms|us|s))\s+([\d.]+(?:ms|us|s))', line)
            if m_mean: res['mean'] = parse_time_us(m_mean.group(1))
            m_p50 = re.match(r'^\s*(?:50\.000%|50%)\s+([\d.]+(?:ms|us|s))', line)
            if m_p50: res['p50'] = parse_time_us(m_p50.group(1))
            m_p90 = re.match(r'^\s*(?:90\.000%|90%)\s+([\d.]+(?:ms|us|s))', line)
            if m_p90: res['p90'] = parse_time_us(m_p90.group(1))
            m_p99 = re.match(r'^\s*(?:99\.000%|99%)\s+([\d.]+(?:ms|us|s))', line)
            if m_p99: res['p99'] = parse_time_us(m_p99.group(1))
            m_p999 = re.match(r'^\s*(?:99\.900%|99\.9%)\s+([\d.]+(?:ms|us|s))', line)
            if m_p999: res['p999'] = parse_time_us(m_p999.group(1))
    return res

def parse_pidstat(filepath):
    res = {'cpu_usr': 0.0, 'cpu_sys': 0.0, 'cpu_wait': 0.0, 'cpu_tot': 0.0, 'carrier_cpu': 0.0, 'reactor_cpu': 0.0, 'carrier_wait': 0.0}
    if not os.path.exists(filepath):
        return res
    with open(filepath) as f:
        lines = f.readlines()
    carrier_wait_samples = []
    for line in lines:
        parts = line.split()
        if not parts or parts[0] not in ('Average:', 'Średnia:'):
            continue
        if len(parts) >= 9 and parts[1].isdigit() and parts[2].isdigit() and parts[3] == '-':
            try:
                res['cpu_usr'] = float(parts[4].replace(',', '.'))
                res['cpu_sys'] = float(parts[5].replace(',', '.'))
                res['cpu_wait'] = float(parts[7].replace(',', '.'))
                res['cpu_tot'] = float(parts[8].replace(',', '.'))
            except ValueError:
                pass
        elif len(parts) >= 8 and parts[1].isdigit() and parts[2] == '-' and parts[3].isdigit():
            cmd = parts[-1]
            try:
                tot = float(parts[8].replace(',', '.'))
                wait = float(parts[7].replace(',', '.'))
                if 'ctor/' in cmd or 'reactor' in cmd:
                    res['reactor_cpu'] += tot
                elif 'ForkJoi' in cmd or 'exeris-' in cmd or 'rier-0' in cmd or 'rier-1' in cmd:
                    res['carrier_cpu'] += tot
                    carrier_wait_samples.append(wait)
            except (ValueError, IndexError):
                pass
    if carrier_wait_samples:
        res['carrier_wait'] = statistics.mean(carrier_wait_samples)
    return res

def summarize_metric(vals):
    if not vals: return 'N/A'
    med = statistics.median(vals)
    return f'{med:.1f} [{min(vals):.1f} - {max(vals):.1f}]'

def summarize_time_metric(vals):
    if not vals: return 'N/A'
    med = statistics.median(vals)
    return f'{format_us(med)} [{format_us(min(vals))} - {format_us(max(vals))}]'

results = {}
for conns in sweep_conns:
    results[conns] = {}
    for cfg in active_configs:
        files = sorted(glob.glob(f'{run_dir}/conns-{conns}_cfg-{cfg}_rep-*-loadgen.log'))
        rps_l, p50_l, p90_l, p99_l, p999_l = [], [], [], [], []
        cpu_tot_l, carrier_cpu_l, carrier_wait_l = [], [], []
        for lf in files:
            pidstat_f = lf.replace('-loadgen.log', '-pidstat.log')
            lg = parse_loadgen(lf)
            pid = parse_pidstat(pidstat_f)
            if lg['rps'] > 0:
                rps_l.append(lg['rps'])
                p50_l.append(lg['p50'])
                p90_l.append(lg['p90'])
                p99_l.append(lg['p99'])
                p999_l.append(lg['p999'])
                cpu_tot_l.append(pid['cpu_tot'])
                carrier_cpu_l.append(pid['carrier_cpu'])
                carrier_wait_l.append(pid['carrier_wait'])
        results[conns][cfg] = {
            'rps': rps_l, 'p50': p50_l, 'p90': p90_l, 'p99': p99_l, 'p999': p999_l,
            'cpu_tot': cpu_tot_l, 'carrier_cpu': carrier_cpu_l, 'carrier_wait': carrier_wait_l
        }

with open(report_json, 'w') as jf:
    json.dump(results, jf, indent=2)

md = []
md.append('# Loom Cache Locality Concurrency Sweep Report')
md.append('')
md.append('**Date:** ' + os.popen('date').read().strip())
md.append('**Hardware:** AMD Ryzen 5 5600 6-Core (Zen 3, single CCX, 32MB L3, 6x 512KB L2)')
md.append('**Workload:** \`/delayed\` (20 ms simulated backend delay, 8 KB state touched per request)')
md.append('**Fixed Rate:** 3,000 req/s')
md.append('')

for conns in sweep_conns:
    working_set_est = (conns * 8) / 1024.0 # MB
    md.append(f'## Concurrency Level: {conns} Connections (Estimated Working Set: ~{working_set_est:.1f} MB)')
    md.append('')
    md.append('| Config | Description | Actual RPS | p50 | p90 | p99 | Worst p99 | p99.9 | Total CPU (%) | Carrier CPU (%) | Carrier %wait |')
    md.append('| :---: | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |')
    for cfg in active_configs:
        d = results[conns][cfg]
        arps = summarize_metric(d['rps'])
        p50 = summarize_time_metric(d['p50'])
        p90 = summarize_time_metric(d['p90'])
        p99 = summarize_time_metric(d['p99'])
        worst_p99 = format_us(max(d['p99'])) if d['p99'] else 'N/A'
        p999 = summarize_time_metric(d['p999'])
        cpu = summarize_metric(d['cpu_tot'])
        carrier = summarize_metric(d['carrier_cpu'])
        wait = summarize_metric(d['carrier_wait'])
        md.append(f'| **{cfg}** | {cfg_descriptions[cfg]} | {arps} | {p50} | {p90} | {p99} | **{worst_p99}** | {p999} | {cpu} | {carrier} | {wait} |')
    md.append('')

with open(report_file, 'w') as mf:
    mf.write('\n'.join(md))

print(f'Report written to: {report_file}')
print(f'JSON written to: {report_json}')
"

echo "================================================================="
echo " Cache Sweep Benchmark Complete: ${REPORT_FILE}"
echo "================================================================="
