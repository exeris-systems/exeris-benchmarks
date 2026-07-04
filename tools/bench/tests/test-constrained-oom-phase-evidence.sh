#!/usr/bin/env bash
# test-constrained-oom-phase-evidence.sh — locks in the constrained-run OOM/phase
# attribution so it doesn't rot.
#
# Two layers:
#   1. The pure decision table (tools/bench/lib/constrained-classify.sh): given an exit
#      code, a memory.events oom_kill delta, and the furthest phase.state value, assert
#      the (outcome, failed_phase, oom_after_measurement) triple. This is the logic the
#      wrapper sources, so the test exercises the real function, not a copy.
#   2. The evidence shape: build the canonical evidence objects the wrapper emits and
#      validate them against schemas/constrained-execution-evidence.schema.json, plus a
#      negative case proving the failed_phase enum rejects an out-of-band value.

set -u -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$REPO_ROOT/tools/bench/lib/constrained-classify.sh"
SCHEMA="$REPO_ROOT/schemas/constrained-execution-evidence.schema.json"

# shellcheck source=../lib/constrained-classify.sh
source "$LIB"

FAILURES=0

# ---- Layer 1: decision table --------------------------------------------------------

# assert_classify <name> <expected triple> <rc> <oom_kill_delta> <phase> [readiness_failed] [heap_oom]
assert_classify() {
  local name="$1" expected="$2"; shift 2
  local got
  got="$(classify_constrained_outcome "$@")"
  if [[ "$got" == "$(printf '%b' "$expected")" ]]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name" >&2
    echo "      expected: $(printf '%b' "$expected" | tr '\t' '|')" >&2
    echo "      got:      $(printf '%s' "$got" | tr '\t' '|')" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# Clean run: measurement validated, no OOM.
assert_classify "clean ok"                 'ok\tnull\tfalse'         0 0 measure_complete 0 0
# Kernel OOM during warmup: hard kill, no measurement at all.
assert_classify "oom in warmup"            'oom_killed\twarmup\tfalse'   1 1 warmup 0 0
# Kernel OOM mid-measurement: phase never reached measure_complete.
assert_classify "oom in measure"           'oom_killed\tmeasure\tfalse'  1 1 measure 0 0
# Kernel OOM after a validated measurement: result stays valid, flagged as teardown.
assert_classify "oom after measure -> ok+flag" 'ok\tteardown\ttrue'      0 1 measure_complete 0 0
# OOM after measure but the driver also exited nonzero (postprocess hiccup): outcome
# keeps its RC-derived value, flag + teardown still carry the truth.
assert_classify "oom after measure, rc!=0"  'startup_failed\tteardown\ttrue' 1 1 measure_complete 0 0
# Kernel OOM during readiness, before the app served anything.
assert_classify "oom in readiness"         'oom_killed\treadiness\tfalse' 1 1 readiness 0 0
# Non-OOM readiness timeout: no oom_kill, log shows readiness failure.
assert_classify "readiness timeout"        'readiness_timeout\treadiness\tfalse' 1 0 readiness 1 0
# Non-OOM crash with a JVM heap OOME in the log but no cgroup kill.
assert_classify "heap OOME, no cgroup kill" 'oom_killed\tmeasure\tfalse'  1 0 measure 0 1
# Non-OOM startup failure, phase marker missing.
assert_classify "startup failed, unknown phase" 'startup_failed\tlaunch\tfalse' 1 0 unknown 0 0
# OOM kill delta but phase.state missing entirely -> earliest phase.
assert_classify "oom, unknown phase"       'oom_killed\tlaunch\tfalse'   1 1 unknown 0 0

# ---- Layer 1b: memory_failure_kind synthesis ----------------------------------------

# assert_kind <name> <expected> <oom_kill_delta> <hs_err_present> <hs_err_is_oom> <heap_oom_log>
assert_kind() {
  local name="$1" expected="$2"; shift 2
  local got; got="$(derive_memory_failure_kind "$@")"
  if [[ "$got" == "$expected" ]]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name (expected=$expected got=$got)" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

assert_kind "kind: cgroup kill wins"        cgroup_oom_kill 1 0 0 0
assert_kind "kind: cgroup kill beats hs_err" cgroup_oom_kill 1 1 1 1
assert_kind "kind: jvm native oom (hs_err)"  jvm_native_oom  0 1 1 0
assert_kind "kind: jvm crash (hs_err segv)"  jvm_crash       0 1 0 0
assert_kind "kind: jvm native oom (heap log)" jvm_native_oom 0 0 0 1
assert_kind "kind: none"                     none            0 0 0 0

# ---- Layer 2: evidence shape vs schema ----------------------------------------------

have_validator=1
if ! command -v check-jsonschema >/dev/null 2>&1 \
   && ! command -v ajv >/dev/null 2>&1 \
   && ! python3 -c 'import jsonschema' >/dev/null 2>&1; then
  echo "SKIP (layer 2): no JSON-schema validator (check-jsonschema/ajv/python3+jsonschema)" >&2
  have_validator=0
fi

validate_evidence() { # <file> -> 0 pass, 1 fail
  local f="$1"
  if command -v check-jsonschema >/dev/null 2>&1; then
    check-jsonschema --schemafile "$SCHEMA" "$f" >/dev/null 2>&1
  elif command -v ajv >/dev/null 2>&1; then
    ajv validate -s "$SCHEMA" -d "$f" >/dev/null 2>&1
  else
    python3 -c 'import json,sys,jsonschema; jsonschema.validate(json.load(open(sys.argv[2])), json.load(open(sys.argv[1])))' "$SCHEMA" "$f" >/dev/null 2>&1
  fi
}

# Mirrors the fields the wrapper's jq emits, parameterized over the discriminating set.
emit_evidence() { # <oom_kill_delta> <phase_reached> <failed_phase|null> <oom_after> <target_alive|null> <outcome> <memory_failure_kind> <hs_err_present:true|false>
  jq -n \
    --argjson oom_kill_delta "$1" \
    --arg phase_reached "$2" \
    --arg failed_phase "$3" \
    --argjson oom_after "$4" \
    --arg target_alive "$5" \
    --arg outcome "$6" \
    --arg memory_failure_kind "${7:-none}" \
    --argjson hs_err_present "${8:-false}" \
    '{
      execution_profile_id: "runtime-constrained-128m-0p5vcpu-v1",
      jit_representativeness: "representative",
      contract_id: "fixed_contract_v1",
      target_runtime: "community",
      target_build: "jvm",
      cgroup_effective: {
        memory_max_bytes: 134217728,
        cpu_quota_us: 50000,
        cpu_period_us: 100000,
        memory_peak_bytes: 134217728,
        cpu_stat: { nr_periods: 100, nr_throttled: 10, throttled_usec: 1234 },
        memory_events: { oom_kill: $oom_kill_delta, oom: $oom_kill_delta, oom_group_kill: 0, max: 5 }
      },
      phase_reached: $phase_reached,
      failed_phase: (if $failed_phase == "null" then null else $failed_phase end),
      oom_after_measurement: $oom_after,
      target_alive_at_teardown: (if $target_alive == "null" then null else ($target_alive|tonumber) end),
      memory_failure_kind: $memory_failure_kind,
      crash_artifacts: {
        hs_err_present: $hs_err_present,
        hs_err_paths: (if $hs_err_present then ["crash-artifacts/hs_err_pid123.log"] else [] end),
        hs_err_cause: (if $hs_err_present then "SIGSEGV" else null end),
        replay_present: false,
        core_present: false
      },
      dmesg_oom: {
        available: false,
        oom_killer_invoked: null,
        matched_line_count: 0,
        sample_lines: [],
        note: "best-effort kernel ring-buffer scan; unavailable here."
      },
      jvm_overlay_flags: ["-XX:+UseSerialGC"],
      launch_command: ["./scripts/run-entity-read-by-id.sh"],
      benchmark_exit_code: 0,
      outcome: $outcome
    }'
}

if [[ "$have_validator" -eq 1 ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP (layer 2): jq not available" >&2
  else
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

    # Positive: clean, warmup-OOM (cgroup), teardown-OOM, JVM crash with hs_err present.
    emit_evidence 0 measure_complete null     false 1 ok         none            false > "$TMP/clean.json"
    emit_evidence 1 warmup           warmup   false 0 oom_killed cgroup_oom_kill false > "$TMP/warmup-oom.json"
    emit_evidence 1 measure_complete teardown true  1 ok         cgroup_oom_kill false > "$TMP/teardown-oom.json"
    emit_evidence 0 measure          measure  false 0 startup_failed jvm_crash    true  > "$TMP/jvm-crash.json"

    for case in clean warmup-oom teardown-oom jvm-crash; do
      if validate_evidence "$TMP/$case.json"; then
        echo "PASS: evidence schema-valid ($case)"
      else
        echo "FAIL: evidence rejected by schema ($case)" >&2
        FAILURES=$((FAILURES + 1))
      fi
    done

    # Negative: failed_phase=measure_complete is not a valid failed_phase value.
    emit_evidence 1 measure_complete measure_complete true 1 ok > "$TMP/bad-phase.json"
    if validate_evidence "$TMP/bad-phase.json"; then
      echo "FAIL: schema accepted an invalid failed_phase (measure_complete)" >&2
      FAILURES=$((FAILURES + 1))
    else
      echo "PASS: schema rejects invalid failed_phase"
    fi
  fi
fi

# ------------------------------------------------------------------------------------
if [[ "$FAILURES" -gt 0 ]]; then
  echo "FAILED: $FAILURES assertion(s)" >&2
  exit 1
fi
echo "OK: all constrained OOM/phase assertions passed"
