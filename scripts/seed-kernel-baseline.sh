#!/usr/bin/env bash
# Seed (or replace) the Exeris regression baseline for entity-read-by-id.
#
# WHY THIS EXISTS AS ITS OWN SCRIPT
# baselines/ held nothing but a README until now, and not from neglect: neither existing family of
# runs can serve. The 2026-07-21 triad ran host-net (the prescribed condition) but predates the
# db_cpuset field, so compare-results.sh can only reach it through BENCH_ALLOW_UNVERIFIED_FENCES=1
# and stamps the answer FENCE-UNVERIFIED - the DB *was* pinned (runtime/compose/*.tuned.yml sets
# cpuset "4-7,12-15"), it simply was not recorded per leaf. The kernel-version-axis campaigns record
# both fences but ran bridge, and host-vs-bridge is +20.5% on this box, a refusal compare-results.sh
# does not let you override. A baseline therefore needs its own run under host-net WITH the field
# recorded, which is all this script does.
#
# Exeris is the baseline. Spring and Quarkus are reference arms and are deliberately not seeded here.
#
# WHAT IDENTITY A BASELINE CARRIES
# "exeris-community" is not an identity. The kernel-version axis measured six arms that are all the
# community app and differ only by (staged jar, JDK, preview flag); "0.11.0" alone is ambiguous
# between five of them. run-entity-read-by-id.sh writes no build_provenance, so this script derives
# the identity from the LIVE process and writes it beside the baseline. A baseline whose kernel
# coordinate and JDK are not recorded cannot answer the next regression question.
#
# WHAT n MEANS HERE
# The neighbour/slot effect on this box is 2.3-3.9% and is SYSTEMATIC - it does not shrink with
# repeats. Against a -5% warning line a single leaf spends most of the budget on measurement
# artifact. So the run is repeated, the median leaf becomes the baseline file, and the spread is
# recorded alongside it. Compare against the recorded spread, not against the single leaf alone.
#
# Usage: scripts/seed-kernel-baseline.sh [--arm C] [--contracts light,heavy] [--repeats 3]
#                                        [--replace "<reason>"] [--dry-run]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MANIFEST="runtime/drivers/kernel-version-axis-arms.json"
ARM="C"                       # mainline 0.11.0 on JDK 25 LTS, no preview = what the line ships
CONTRACTS="light,heavy"
REPEATS=3
REPLACE_REASON=""
DRY_RUN=0

# Contract ids, kept identical to run-kernel-version-axis-campaign.sh. A baseline measured on a
# different contract than the run it is later compared against is worse than no baseline.
declare -A CONTRACT_IDS=(
  [light]="fixed_contract_cross_runtime_h1_single_read_v1"
  [heavy]="fixed_contract_cross_runtime_h1_v1"
)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arm)       ARM="$2"; shift 2 ;;
    --contracts) CONTRACTS="$2"; shift 2 ;;
    --repeats)   REPEATS="$2"; shift 2 ;;
    --replace)   REPLACE_REASON="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -h|--help)   sed -n '1,32p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
  esac
done

die() { echo "[baseline] ERROR: $*" >&2; exit 1; }
log() { echo "[baseline] $*"; }

# --- fences. These are the whole reason this script exists; they are not defaults to be overridden.
export BENCH_DB_TUNED=1 DB_HOST_NETWORK=1
export BENCH_DB_CPUSET="${BENCH_DB_CPUSET:-4-7,12-15}"
export SERVER_CPU_AFFINITY="${SERVER_CPU_AFFINITY:-0-1,8-9}"
export LOADGEN_CPU_AFFINITY="${LOADGEN_CPU_AFFINITY:-2-3,10-11}"
export BENCH_LOADGEN_CPU_AFFINITY="$LOADGEN_CPU_AFFINITY"
export BENCHMARK_HARDWARE_PROFILE="${BENCHMARK_HARDWARE_PROFILE:-perf-box-amd64}"
export HARDWARE_PROFILE="$BENCHMARK_HARDWARE_PROFILE"

# Matched fixed heap. Without it RSS records whatever the collector committed against this box's
# ~15.5 GB ergonomic heap, and the footprint half of the baseline is meaningless.
export EXERIS_JAVA_OPTS="${EXERIS_JAVA_OPTS:--Xms256m -Xmx256m}"

# pgjdbc normalization, same four parameters stage 8 gates on.
: "${EXERIS_DB_JDBC_URL:=jdbc:postgresql://localhost:5432/benchmark_db?prepareThreshold=1&defaultRowFetchSize=0&adaptiveFetch=false&preferQueryMode=extended}"
: "${EXERIS_DB_USERNAME:=benchmark}"
: "${EXERIS_DB_PASSWORD:=benchmark}"
export EXERIS_DB_JDBC_URL EXERIS_DB_USERNAME EXERIS_DB_PASSWORD

arm_field() {
  python3 - "$MANIFEST" "$ARM" "$1" <<'PY'
import json, sys
for a in json.load(open(sys.argv[1]))["arms"]:
    if a["arm"] == sys.argv[2]:
        print(a[sys.argv[3]]); break
else:
    sys.exit("unknown arm %s" % sys.argv[2])
PY
}

TARGET_ID="$(arm_field target_id)" || die "arm ${ARM} not in ${MANIFEST}"
PORT="$(arm_field port)"
JAR="$(arm_field staged_jar)"
KGROUP="$(arm_field kernel_group_id)"
KVERSION="$(arm_field kernel_version)"
JDK_VAR="$(arm_field jdk_home_var)"
JDK_FEATURE="$(arm_field jdk_feature)"
PREVIEW="$(arm_field enable_preview_flag)"
JDK_HOME="${!JDK_VAR:-}"

[[ -n "$JDK_HOME" && -x "$JDK_HOME/bin/java" ]] || die "no java at ${JDK_VAR}='${JDK_HOME}'"
[[ -f "$JAR" ]] || die "staged jar missing: ${JAR}"

log "arm ${ARM} (${TARGET_ID}): ${KGROUP}:${KVERSION}, JDK ${JDK_FEATURE}, preview=${PREVIEW}"
log "fences   : backend_network_mode=host, db_cpuset=${BENCH_DB_CPUSET}"
log "pins     : server ${SERVER_CPU_AFFINITY}, loadgen ${LOADGEN_CPU_AFFINITY}"
log "heap     : ${EXERIS_JAVA_OPTS}"

if (( DRY_RUN )); then log "dry run - stopping before the entry condition"; exit 0; fi

# Entry condition. Same rule as the axis campaign: jar inspection is not evidence, boot is.
log "boot verification (hard entry condition)"
./scripts/verify-kernel-version-axis-boot.sh "$ARM" || die "boot verification failed for arm ${ARM}"

CAMPAIGN="results/raw/kernel-baseline/$(date -u +%Y%m%dT%H%M%SZ)-${TARGET_ID}"
mkdir -p "$CAMPAIGN"

start_arm() {
  local preview_flag=""
  [[ "$PREVIEW" == "True" || "$PREVIEW" == "true" ]] && preview_flag="--enable-preview"
  # shellcheck disable=SC2086
  EXERIS_PORT="$PORT" EXERIS_HTTP_MAX_VERSION=HTTP_1_1 EXERIS_HTTP_H2C_UPGRADE_ENABLED=false \
    taskset -c "$SERVER_CPU_AFFINITY" \
    "$JDK_HOME/bin/java" $EXERIS_JAVA_OPTS $preview_flag -jar "$JAR" \
    > "$CAMPAIGN/target-${TARGET_ID}.log" 2>&1 &
  echo $! > "$CAMPAIGN/target.pid"
  local waited=0
  until curl -sf "http://localhost:${PORT}/health" >/dev/null 2>&1; do
    sleep 1; waited=$((waited + 1))
    (( waited > 90 )) && die "arm ${ARM} did not become healthy on :${PORT} within 90s"
  done
}

stop_arm() {
  local pid; pid="$(cat "$CAMPAIGN/target.pid" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}
trap stop_arm EXIT

for contract in ${CONTRACTS//,/ }; do
  cid="${CONTRACT_IDS[$contract]:-}"
  [[ -n "$cid" ]] || die "unknown contract '${contract}' (known: ${!CONTRACT_IDS[*]})"

  for ((r = 1; r <= REPEATS; r++)); do
    out="$CAMPAIGN/${contract}/run$(printf '%02d' "$r")"
    mkdir -p "$out"
    log "[${contract}] run ${r}/${REPEATS}"
    start_arm

    # The identity check runs against the LIVE process, not the jar we think we launched. This is
    # the one guard that catches a baseline recorded from the wrong arm, which no downstream
    # consumer could detect afterwards.
    ./tools/verify-kernel-version-axis-identity.sh "$TARGET_ID" "$PORT" > "$out/identity.txt" \
      || die "live process on :${PORT} is not arm ${ARM}"

    BENCHMARK_ALLOW_EXTERNAL_TARGET=1 BENCHMARK_TARGET_PORT="$PORT" \
      ./scripts/run-entity-read-by-id.sh \
        --contract "$cid" \
        --claim-scope comparison-eligible \
        --profile "$BENCHMARK_HARDWARE_PROFILE" \
        --cpu-affinity "$SERVER_CPU_AFFINITY" \
        --client-cpu-affinity "$LOADGEN_CPU_AFFINITY" \
        --output-dir "$out" \
      || die "measurement failed: ${contract} run ${r}"

    stop_arm
  done
done
trap - EXIT

log "measurements complete: ${CAMPAIGN}"
log "run scripts/promote-kernel-baseline.sh to review the spread and write baselines/"
