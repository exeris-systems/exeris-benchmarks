#!/usr/bin/env bash
# Kernel-version axis campaign: 0.10.2 vs 0.11.0 vs preview/0.11.0, run as a ladder of
# single-variable legs declared in runtime/drivers/kernel-version-axis-arms.json.
#
# THE GUARD THIS SCRIPT EXISTS FOR
# The three kernel coordinates cannot share a JDK, so the arms are NOT freely comparable. Only the
# legs named in the manifest hold everything but one variable constant. A direct arm-A-vs-arm-E
# number - the one the release notes will want - moves kernel version, JDK feature release, and
# language/runtime feature set at the same time and cannot be attributed to any of them. This
# script therefore refuses to run any pair that is not a declared leg, rather than leaving that
# discipline to whoever reads the results later.
#
# The headline figure is assembled from the legs, not measured directly: the ladder decomposes
# 0.10.2 -> preview/0.11.0 into release delta, LTS cost, JDK delta, flag tax, recompile tax, and
# the Valhalla + StructuredTaskScope delta.
#
# Usage:
#   scripts/run-kernel-version-axis-campaign.sh [options]
#     --legs <a,b,...>          legs to run (default: all declared legs)
#     --repeats <n>             repeats per leg, each run as A/B then B/A (default: 5)
#     --scenario <id>           scenario id (default: entity-read-by-id)
#     --contracts <l,h>         which workload contracts to run: light, heavy, or both (default: both)
#     --warmup-seconds <n>      override the contract's warmup (default: the contract's own)
#     --measurement-seconds <n> override the contract's duration (default: the contract's own)
#     --output-dir <path>       default results/raw/kernel-version-axis/<timestamp>-campaign
#     --skip-boot-verify        run without re-verifying the arms (NOT for published results)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MANIFEST="runtime/drivers/kernel-version-axis-arms.json"

REPEATS=5
SCENARIO_ID="entity-read-by-id"

# The axis runs two workload contracts, kept in separate result trees and never averaged together:
#
#   light  fixed_contract_cross_runtime_h1_single_read_v1   GET /api/v1/user?id=1   warm 300 / dur 900
#   heavy  fixed_contract_cross_runtime_h1_v1               GET /api/v1/users       warm  60 / dur 120
#
# Both matter and they answer different questions. Community persistence is JDBC over HikariCP, so on
# the heavy aggregate read most of the response time is Postgres and kernel-internal effects - the
# entire subject of this axis - compress toward zero; the light single-row read is where a Valhalla
# or JIT difference can actually show. The heavy contract is what a user's aggregate endpoint
# actually experiences. Reporting only one of them would misstate the release.
#
# The request path is DERIVED from the contract's own `endpoint` in scenario.json rather than passed
# alongside it, so a contract can never be driven at another contract's path.
#
# The two -debug keys map to the scenario's own short-window debug contracts. They exist to prove the
# pipeline produces gate artefacts before a multi-hour campaign is committed, and scenario.json marks
# them "NOT for eligible results" - they carry a distinct contract id, so a debug run can never be
# mistaken for or averaged with a real one.
CONTRACT_SET="light,heavy"
declare -A CONTRACT_IDS=(
  [light]="fixed_contract_cross_runtime_h1_single_read_v1"
  [heavy]="fixed_contract_cross_runtime_h1_v1"
  [light-debug]="fixed_contract_cross_runtime_h1_single_read_debug"
  [heavy-debug]="fixed_contract_cross_runtime_h1_debug"
)
WARMUP_SECONDS=""      # empty = use the contract's own window
MEASUREMENT_SECONDS=""
OUTPUT_DIR=""
SKIP_BOOT_VERIFY=0
LEGS_FILTER=""
HARDWARE_PROFILE="${BENCHMARK_HARDWARE_PROFILE:-perf-box-amd64}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --legs)                LEGS_FILTER="$2"; shift 2 ;;
    --repeats)             REPEATS="$2"; shift 2 ;;
    --scenario)            SCENARIO_ID="$2"; shift 2 ;;
    --contracts)           CONTRACT_SET="$2"; shift 2 ;;
    --warmup-seconds)      WARMUP_SECONDS="$2"; shift 2 ;;
    --measurement-seconds) MEASUREMENT_SECONDS="$2"; shift 2 ;;
    --output-dir)          OUTPUT_DIR="$2"; shift 2 ;;
    --skip-boot-verify)    SKIP_BOOT_VERIFY=1; shift ;;
    -h|--help)             sed -n '1,30p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ "$REPEATS" =~ ^[0-9]+$ && "$REPEATS" -gt 0 ]] || { echo "ERROR: --repeats must be a positive integer" >&2; exit 2; }
[[ -f "$MANIFEST" ]] || { echo "ERROR: manifest not found: $MANIFEST" >&2; exit 2; }

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="results/raw/kernel-version-axis/$(date -u +%Y%m%dT%H%M%SZ)-campaign"
fi
mkdir -p "$OUTPUT_DIR"

# The axis is exploratory and within-tier. It must never be written into the constrained tree or
# carry a constrained contract - those are a different track with different eligibility rules.
if [[ "$OUTPUT_DIR" == *"results/constrained/"* || "$CONTRACT_SET" == *constrained* ]]; then
  echo "ERROR: the kernel-version axis is an exploratory within-tier ladder, not a constrained run" >&2
  exit 2
fi

log()  { echo "[axis] $*"; }
die()  { echo "[axis] ERROR: $*" >&2; exit 1; }

IFS=',' read -r -a CONTRACT_KEYS <<< "$CONTRACT_SET"
for _k in "${CONTRACT_KEYS[@]}"; do
  [[ -n "${CONTRACT_IDS[$_k]:-}" ]] || { echo "ERROR: unknown contract '${_k}' (known: light, heavy, light-debug, heavy-debug)" >&2; exit 2; }
done

# pgjdbc fairness normalization. Stage 8's DB-config gate rejects a run whose JDBC URL leaves any of
# these four to the driver's defaults, and it is right to: an un-normalized URL has been the hidden
# variable in this scenario three times, once nearly crowning the wrong runtime on the aggregate
# read. Both arms of a leg inherit one environment here, so equality alone proves nothing - the
# parameters have to be pinned explicitly or the arms ride whatever pgjdbc decides per connection.
: "${EXERIS_DB_JDBC_URL:=jdbc:postgresql://localhost:5432/benchmark_db?prepareThreshold=1&defaultRowFetchSize=0&adaptiveFetch=false&preferQueryMode=extended}"
export EXERIS_DB_JDBC_URL
for _p in prepareThreshold defaultRowFetchSize adaptiveFetch preferQueryMode; do
  if [[ "$EXERIS_DB_JDBC_URL" != *"${_p}="* ]]; then
    echo "ERROR: EXERIS_DB_JDBC_URL does not pin '${_p}'." >&2
    echo "       Stage 8 would reject every step as DB_CONFIG_NOT_NORMALIZED after the full run." >&2
    echo "       Expected shape: ...?prepareThreshold=1&defaultRowFetchSize=0&adaptiveFetch=false&preferQueryMode=extended" >&2
    exit 2
  fi
done

# Credentials, and they belong here rather than in the caller's shell. The boot verifier defaults to
# benchmark/benchmark and passes; this script used to default to neither, so the arms it launched
# inherited the driver env's `postgres` and died on "role does not exist" AFTER a green entry
# condition. A hard entry condition that runs on different credentials than the campaign is not an
# entry condition. Same defaults as scripts/verify-kernel-version-axis-boot.sh - keep them in step.
: "${EXERIS_DB_USERNAME:=benchmark}"
: "${EXERIS_DB_PASSWORD:=benchmark}"
export EXERIS_DB_USERNAME EXERIS_DB_PASSWORD

# Pull a contract's own endpoint / warmup / duration out of scenario.json. Deriving them beats
# passing them in: a contract driven at another contract's path, or with another contract's window,
# is a fairness defect that nothing downstream would catch.
contract_field() {
  python3 - "scenarios/${SCENARIO_ID}/scenario.json" "$1" "$2" <<'CONTRACT_PY'
import json, sys
scenario, contract_id, field = sys.argv[1], sys.argv[2], sys.argv[3]
def walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == contract_id and isinstance(v, dict) and "endpoint" in v:
                return v
            r = walk(v)
            if r: return r
    elif isinstance(o, list):
        for v in o:
            r = walk(v)
            if r: return r
    return None
c = walk(json.load(open(scenario)))
if c is None or field not in c:
    sys.exit(1)
print(c[field])
CONTRACT_PY
}

# --- manifest access --------------------------------------------------------------------------
arm_field() {
  python3 - "$MANIFEST" "$1" "$2" <<'PY'
import json, sys
manifest, arm_name, field = sys.argv[1], sys.argv[2], sys.argv[3]
for a in json.load(open(manifest))["arms"]:
    if a["arm"] == arm_name:
        print(a[field]); sys.exit(0)
sys.exit(1)
PY
}

declared_legs() {
  python3 - "$MANIFEST" <<'PY'
import json, sys
for leg in json.load(open(sys.argv[1]))["legs"]:
    a, b = leg["leg"].split("->")
    print("\t".join([leg["leg"], a, b, leg["isolates"], leg["held_constant"], leg["claim"]]))
PY
}

# THE GUARD: a pair is runnable only if the manifest declares it as a leg.
assert_declared_leg() {
  local leg="$1"
  while IFS=$'\t' read -r name _a _b _iso _held _claim; do
    [[ "$name" == "$leg" ]] && return 0
  done < <(declared_legs)
  die "'${leg}' is not a declared leg of this axis.

Arms of this ladder are not freely comparable: the three kernel coordinates cannot share a JDK, so
an undeclared pair moves more than one variable and its difference cannot be attributed. Declared
legs are:
$(declared_legs | cut -f1 | sed 's/^/  /')

If you want the end-to-end 0.10.2 -> preview/0.11.0 figure, assemble it from these legs and report
the decomposition alongside it. Do not measure it as one pair."
}

# --- arm lifecycle ----------------------------------------------------------------------------
start_arm() {
  local arm="$1" log_dir="$2"
  local target_id port env_file
  target_id="$(arm_field "$arm" target_id)" || die "unknown arm ${arm}"
  port="$(arm_field "$arm" port)"
  env_file="runtime/drivers/env/${target_id}.env"
  [[ -f "$env_file" ]] || die "missing env file ${env_file}; run scripts/generate-kernel-version-axis-wiring.sh"

  ( set -a; source "$env_file" >/dev/null 2>&1; set +a
    eval "$EXTERNAL_START_CMD" )

  local waited=0
  while [[ $waited -lt 90 ]]; do
    if [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:${port}/health" 2>/dev/null)" == "200" ]]; then
      log "  arm ${arm} (${target_id}) up on :${port}"
      # Re-derive identity from the live process, exactly as boot-verify does. A campaign that
      # measured the wrong JDK or the wrong jar would otherwise complete and pass every gate.
      tools/verify-kernel-version-axis-identity.sh "$target_id" "$port" > "${log_dir}/${target_id}.identity.txt" 2>&1 \
        || die "arm ${arm} started but is not the configuration it claims to be; see ${log_dir}/${target_id}.identity.txt"
      return 0
    fi
    sleep 1; waited=$((waited + 1))
  done
  die "arm ${arm} (${target_id}) did not become healthy on :${port} within 90s"
}

stop_arm() {
  local arm="$1"
  local target_id; target_id="$(arm_field "$arm" target_id)"
  local env_file="runtime/drivers/env/${target_id}.env"
  ( set -a; source "$env_file" >/dev/null 2>&1; set +a
    eval "${EXTERNAL_STOP_CMD:-true}" ) || true
  sleep 2
}

stop_all_arms() {
  local arm
  for arm in A B C-prime C D D-prime D-double-prime E; do stop_arm "$arm" 2>/dev/null || true; done
}
trap stop_all_arms EXIT

# --- entry conditions --------------------------------------------------------------------------
log "kernel-version axis campaign"
log "output    : ${OUTPUT_DIR}"
log "scenario  : ${SCENARIO_ID}"
for _k in "${CONTRACT_KEYS[@]}"; do
  log "  contract ${_k}: ${CONTRACT_IDS[$_k]}"
done
log "repeats   : ${REPEATS} per leg, each run A/B and B/A"
log "hardware  : ${HARDWARE_PROFILE}"

if [[ $SKIP_BOOT_VERIFY -eq 1 ]]; then
  log "WARNING: boot verification skipped; these results are not publishable"
  echo "boot_verify=skipped" > "${OUTPUT_DIR}/entry-conditions.txt"
else
  log "running boot verification (hard entry condition)"
  if ! ./scripts/verify-kernel-version-axis-boot.sh > "${OUTPUT_DIR}/boot-verify.log" 2>&1; then
    tail -20 "${OUTPUT_DIR}/boot-verify.log"
    die "boot verification failed; see ${OUTPUT_DIR}/boot-verify.log. No leg may run until every arm passes."
  fi
  log "boot verification passed for all arms"
  echo "boot_verify=passed" > "${OUTPUT_DIR}/entry-conditions.txt"
fi

cp "$MANIFEST" "${OUTPUT_DIR}/kernel-version-axis-arms.json"
./scripts/capture-env.sh > "${OUTPUT_DIR}/env.json" 2>/dev/null || log "WARNING: capture-env.sh failed; reproducibility metadata incomplete"

# --- run the legs -------------------------------------------------------------------------------
declare -a SELECTED=()
if [[ -n "$LEGS_FILTER" ]]; then
  IFS=',' read -r -a SELECTED <<< "$LEGS_FILTER"
  for leg in "${SELECTED[@]}"; do assert_declared_leg "$leg"; done
else
  while IFS=$'\t' read -r name _rest; do SELECTED+=("$name"); done < <(declared_legs)
fi

log "legs to run: ${#SELECTED[@]}  contracts: ${CONTRACT_SET}"
failed=0

for contract_key in "${CONTRACT_KEYS[@]}"; do
  contract_id="${CONTRACT_IDS[$contract_key]}"
  endpoint="$(contract_field "$contract_id" endpoint)" || die "contract ${contract_id} not found in scenarios/${SCENARIO_ID}/scenario.json"
  # "GET /api/v1/user?id=1" -> "/api/v1/user?id=1"
  request_path="${endpoint#* }"
  warmup="${WARMUP_SECONDS:-$(contract_field "$contract_id" warmup_seconds)}"
  measurement="${MEASUREMENT_SECONDS:-$(contract_field "$contract_id" duration_seconds)}"

  log ""
  log "############################################################"
  log "CONTRACT ${contract_key}: ${contract_id}"
  log "  endpoint : ${endpoint}"
  log "  window   : warmup ${warmup}s, measurement ${measurement}s per target"
  log "############################################################"

for leg in "${SELECTED[@]}"; do
  assert_declared_leg "$leg"
  arm_a="${leg%%->*}"
  arm_b="${leg##*->}"
  leg_slug="$(echo "$leg" | tr -d ' ' | tr '>' '_' | tr -- '-' '_')"
  target_a="$(arm_field "$arm_a" target_id)"
  target_b="$(arm_field "$arm_b" target_id)"

  log ""
  log "============================================================"
  log "LEG ${leg}: ${target_a} vs ${target_b}"
  python3 - "$MANIFEST" "$leg" <<'PY'
import json, sys
for leg in json.load(open(sys.argv[1]))["legs"]:
    if leg["leg"] == sys.argv[2]:
        print(f"[axis]   isolates      : {leg['isolates']}")
        print(f"[axis]   held constant : {leg['held_constant']}")
        print(f"[axis]   claim         : {leg['claim']}")
PY
  log "============================================================"

  for run in $(seq 1 "$REPEATS"); do
    for order in ab ba; do
      if [[ "$order" == "ab" ]]; then a="$target_a"; b="$target_b"; else a="$target_b"; b="$target_a"; fi
      out="${OUTPUT_DIR}/${contract_key}/${leg_slug}/run$(printf '%02d' "$run")/${order}"
      mkdir -p "$out"

      log "  [${contract_key}] run $(printf '%02d' "$run")/${REPEATS} ${order}: A=${a} B=${b}"

      start_arm "$arm_a" "$out"
      start_arm "$arm_b" "$out"

      # JDK attribution. run-comparative.sh derives run_config.metadata.jdk_version from `java` on
      # PATH - ONE value for the whole invocation, for both targets. On this axis that is wrong twice
      # over: the PATH JDK is not any arm's JDK, and the two arms of a JDK leg run on DIFFERENT JDKs,
      # so no single field can be right. Rather than patch a script every other campaign depends on,
      # record the truth beside the result and say plainly that the harness field must not be read
      # here. Where both arms genuinely share a JDK, pin it so the harness field is at least correct.
      jdk_a="$(arm_field "$arm_a" jdk_feature)"; jdk_b="$(arm_field "$arm_b" jdk_feature)"
      harness_path_jdk="$(java -version 2>&1 | awk -F'"' '/version/ {print $2; exit}')"
      python3 - "$out/axis-jdk-attribution.json" "$target_a" "$jdk_a" "$target_b" "$jdk_b" \
                "$leg" "$contract_key" "$harness_path_jdk" <<'ATTR_PY'
import json, sys
out, ta, ja, tb, jb, leg, contract, path_jdk = sys.argv[1:9]
json.dump({
    "leg": leg,
    "contract": contract,
    "arms": {ta: {"jdk_feature": int(ja)}, tb: {"jdk_feature": int(jb)}},
    "harness_path_jdk": path_jdk,
    "harness_jdk_field_is_authoritative": False,
    "warning": (
        "run_config.metadata.jdk_version and run_config.*_versions.jdk_version in "
        "comparative-result.json record `java` on the harness PATH (" + path_jdk + "), which is NOT "
        "the JDK that launched either arm and is never authoritative on this axis. Read the per-arm "
        "jdk_feature here instead. BENCHMARK_PINNED_JDK_VERSION cannot express the truth: gate G7 "
        "checks it against the PATH java, so setting it to an arm's real JDK fails the run as "
        "PIN_MISMATCH rather than correcting the metadata."
    ),
}, open(out, "w"), indent=2)
ATTR_PY

      # Deliberately NOT setting BENCHMARK_PINNED_JDK_VERSION. It is a gate-G7 assertion compared
      # against the harness PATH java, not a metadata override - pinning an arm's real JDK makes
      # every same-JDK leg fail as PIN_MISMATCH. Measured: doing so voided 12 of 14 steps.

      set +e
      BENCH_SKIP_SCENARIO_INFRA_SETUP=1 \
      BENCHMARK_PAIR_ORDER="$order" \
      BENCHMARK_AB_BA_ORDERS_COMPLETED="ab,ba" \
      BENCHMARK_TRACK_ID="track-${contract_key}-${leg_slug}-${order}-$(printf '%02d' "$run")" \
      BENCHMARK_HARDWARE_PROFILE="$HARDWARE_PROFILE" \
      HARDWARE_PROFILE="$HARDWARE_PROFILE" \
      WRK_REQUEST_PATH="$request_path" \
        ./scripts/run-comparative.sh \
          --target-a "$a" --target-b "$b" \
          --scenario-id "$SCENARIO_ID" \
          --contract-id "$contract_id" \
          --warmup-seconds "$warmup" \
          --measurement-seconds "$measurement" \
          --output-dir "$out" 2>&1 | tee -a "${out}/run.log"
      status="${PIPESTATUS[0]}"
      set -e

      stop_arm "$arm_b"
      stop_arm "$arm_a"

      if [[ "$status" -ne 0 ]]; then
        log "  WARNING: [${contract_key}] leg ${leg} run ${run} ${order} failed (see ${out}/run.log)"
        failed=$((failed + 1))
      else
        # run-comparative.sh can exit 0 on a step whose claim-status.json is non_eligible - the
        # gates passed but a precondition such as DB-config normalization did not. Comparative math
        # is valid ONLY on comparison_eligible steps, so treating exit 0 as success would quietly
        # bank unusable runs and report a campaign as complete. Read the verdict, not the exit code.
        claim="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["claim_status"])' \
                 "${out}/claim-status.json" 2>/dev/null || echo missing)"
        if [[ "$claim" != "comparison_eligible" ]]; then
          reason="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("final_reason") or ",".join(d.get("rejection_codes",[])))' \
                    "${out}/claim-status.json" 2>/dev/null || echo unknown)"
          log "  WARNING: [${contract_key}] leg ${leg} run ${run} ${order} is ${claim} (${reason}); not usable for comparative math"
          failed=$((failed + 1))
        fi
      fi
    done
  done
done
done   # contract

log ""
log "============================================================"
if [[ $failed -gt 0 ]]; then
  log "campaign finished with ${failed} failed step(s); output: ${OUTPUT_DIR}"
  log "Comparative math is valid only for steps whose claim-status.json is comparison_eligible."
  exit 1
fi
log "campaign complete: ${OUTPUT_DIR}"
log ""
log "Every directory here is ONE declared leg. When reporting, quote the legs and their"
log "decomposition. The end-to-end 0.10.2 -> preview/0.11.0 figure is a sum of legs, never a"
log "measured pair, and every leg crossing into JDK 28 inherits an early-access-vs-GA difference"
log "that this axis cannot separate out."
