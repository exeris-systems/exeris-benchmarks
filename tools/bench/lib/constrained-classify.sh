#!/usr/bin/env bash
# constrained-classify.sh — pure classification of a constrained run's outcome from
# the authoritative cgroup OOM signal + the inner runner's phase marker.
#
# Kept as a sourceable, side-effect-free library so the decision table is unit-tested
# directly (tools/bench/tests/test-constrained-oom-phase-evidence.sh) instead of being
# re-derived in the test and drifting from scripts/run-entity-read-by-id-constrained.sh.
#
# Why this exists: a cgroup OOM-kill is a SIGKILL — the JVM logs nothing — so detection
# cannot rely on grepping the target log. memory.events' oom_kill counter is the only
# authoritative signal, and phase.state is the only way to attribute the kill to
# warmup vs measure vs teardown.

# _map_failed_phase <phase.state value> -> a schema-valid failed_phase
# phase.state advances setup -> launch -> readiness -> warmup -> measure -> measure_complete.
# measure_complete means the measurement window already validated, so a failure past it
# is a teardown-phase failure; anything unrecognized degrades to launch (earliest).
_map_failed_phase() {
  case "$1" in
    setup|launch|readiness|warmup|measure) printf '%s' "$1" ;;
    measure_complete) printf 'teardown' ;;
    *) printf 'launch' ;;
  esac
}

# classify_constrained_outcome <rc> <oom_kill_delta> <phase_reached> <readiness_failed> <heap_oom_log>
#   rc              : exit code of the benchmark driver
#   oom_kill_delta  : memory.events oom_kill counter delta across the run (>0 == kernel OOM-kill)
#   phase_reached   : last value written to phase.state (or "unknown")
#   readiness_failed: 1 if the target log shows a readiness-check failure, else 0
#   heap_oom_log    : 1 if the target log shows a JVM heap OutOfMemoryError, else 0
# Echoes a single TAB-separated line: <outcome>\t<failed_phase>\t<oom_after_measurement>
#   outcome              : ok | startup_failed | readiness_timeout | oom_killed
#   failed_phase         : null | setup | launch | readiness | warmup | measure | teardown
#   oom_after_measurement: true | false
classify_constrained_outcome() {
  local rc="$1" oom_kill_delta="$2" phase_reached="$3" readiness_failed="${4:-0}" heap_oom_log="${5:-0}"
  local outcome="ok" failed_phase="null" oom_after="false"

  if (( rc != 0 )); then
    outcome="startup_failed"
    [[ "$readiness_failed" == "1" ]] && outcome="readiness_timeout"
  fi

  if (( oom_kill_delta > 0 )); then
    if [[ "$phase_reached" == "measure_complete" ]]; then
      # Measurement already validated as a real result; the kernel kill landed in
      # teardown. Policy: result stays valid (keep RC-derived outcome) but is flagged.
      oom_after="true"
      failed_phase="teardown"
    else
      outcome="oom_killed"
      failed_phase="$(_map_failed_phase "$phase_reached")"
    fi
  elif (( rc != 0 )); then
    # No kernel OOM event: attribute the phase for triage; the heap-OOM log string is a
    # weak corroborator only (a JVM-level OOME that did not trip the cgroup killer).
    failed_phase="$(_map_failed_phase "$phase_reached")"
    [[ "$heap_oom_log" == "1" ]] && outcome="oom_killed"
  fi

  printf '%s\t%s\t%s\n' "$outcome" "$failed_phase" "$oom_after"
}

# derive_memory_failure_kind <oom_kill_delta> <hs_err_present> <hs_err_is_oom> <heap_oom_log>
#   oom_kill_delta : memory.events oom_kill delta (>0 == kernel OOM-kill)
#   hs_err_present : 1 if a JVM hs_err_pid*.log was produced by this run, else 0
#   hs_err_is_oom  : 1 if that hs_err's fatal cause is a native "Out of Memory Error", else 0
#   heap_oom_log   : 1 if the target stdout shows a JVM heap OutOfMemoryError, else 0
# Echoes the diagnostic memory-failure kind:
#   cgroup_oom_kill : kernel SIGKILLed the process at memory.max (authoritative)
#   jvm_native_oom  : the JVM itself hit a native/heap OOM (hs_err OOM, or heap OOME in log)
#   jvm_crash       : the JVM died on a non-OOM fatal error (SIGSEGV, internal error)
#   none            : no memory-failure signal observed
# A cgroup kill wins over JVM-internal signals: when the kernel SIGKILLs the JVM no
# hs_err is written, so any hs_err alongside oom_kill>0 is from an earlier sub-event.
derive_memory_failure_kind() {
  local oom_kill_delta="$1" hs_err_present="${2:-0}" hs_err_is_oom="${3:-0}" heap_oom_log="${4:-0}"
  if (( oom_kill_delta > 0 )); then printf 'cgroup_oom_kill'; return; fi
  if [[ "$hs_err_present" == "1" ]]; then
    if [[ "$hs_err_is_oom" == "1" ]]; then printf 'jvm_native_oom'; else printf 'jvm_crash'; fi
    return
  fi
  if [[ "$heap_oom_log" == "1" ]]; then printf 'jvm_native_oom'; return; fi
  printf 'none'
}
