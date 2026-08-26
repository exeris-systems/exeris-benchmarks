#!/usr/bin/env bash
set -u

bench_start_jfr_recording() {
  local pid="$1"
  local logs_dir="$2"
  local recording_name="$3"
  local settings="${4:-profile}"
  local jcmd_available=false
  local start_attempted=false
  local start_success=false
  local recording_already_present=false
  local note=""

  : > "${logs_dir}/jfr-start.txt"

  if command -v jcmd >/dev/null 2>&1; then
    jcmd_available=true
  fi

  if [[ "$jcmd_available" != true ]]; then
    note="jcmd not available"
    jq -n \
      --arg  pid                        "$pid" \
      --argjson jcmd_available          false \
      --argjson start_attempted         false \
      --argjson start_success           false \
      --argjson recording_already_present false \
      --arg  recording_name             "$recording_name" \
      --arg  note                       "$note" \
      '{pid:$pid,jcmd_available:$jcmd_available,start_attempted:$start_attempted,
        start_success:$start_success,recording_already_present:$recording_already_present,
        recording_name:$recording_name,note:$note}' \
      > "${logs_dir}/jfr-start.json" || true
    return 0
  fi

  if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ || ! -d "/proc/$pid" ]]; then
    note="target pid invalid or not running"
    jq -n \
      --arg  pid                        "$pid" \
      --argjson jcmd_available          true \
      --argjson start_attempted         false \
      --argjson start_success           false \
      --argjson recording_already_present false \
      --arg  recording_name             "$recording_name" \
      --arg  note                       "$note" \
      '{pid:$pid,jcmd_available:$jcmd_available,start_attempted:$start_attempted,
        start_success:$start_success,recording_already_present:$recording_already_present,
        recording_name:$recording_name,note:$note}' \
      > "${logs_dir}/jfr-start.json" || true
    return 0
  fi

  if jcmd "$pid" JFR.check > "${logs_dir}/jfr-start.txt" 2>&1; then
    if grep -qE "^Recording [0-9]+:" "${logs_dir}/jfr-start.txt" 2>/dev/null; then
      recording_already_present=true
      # Stop existing recordings best-effort to take ownership before starting new one
      while IFS= read -r _rec_name; do
        [[ -z "$_rec_name" ]] && continue
        jcmd "$pid" "JFR.stop name=${_rec_name}" >> "${logs_dir}/jfr-start.txt" 2>&1 || true
      done < <(grep -oE 'name=[^ ]+' "${logs_dir}/jfr-start.txt" | sed 's/name=//' 2>/dev/null || true)
    fi
    start_attempted=true
    # Additive steady-state compiler telemetry (opt-in, default OFF). jcmd JFR.start
    # accepts a repeated settings= token, merged on top of the base config — so this
    # is purely additive. BENCH_JFR_STEADY_STATE=1 uses env/jfr-steady-state.jfc
    # (resolved relative to this lib: tools/bench/lib → repo root); BENCH_JFR_EXTRA_SETTINGS
    # overrides with a custom overlay path. See docs/methodology.md.
    local _extra_settings_arg=""
    if [[ -n "${BENCH_JFR_EXTRA_SETTINGS:-}" ]]; then
      _extra_settings_arg=" settings=${BENCH_JFR_EXTRA_SETTINGS}"
    elif [[ "${BENCH_JFR_STEADY_STATE:-0}" == "1" ]]; then
      local _lib_repo_root
      _lib_repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd 2>/dev/null || true)"
      if [[ -n "$_lib_repo_root" && -f "${_lib_repo_root}/env/jfr-steady-state.jfc" ]]; then
        _extra_settings_arg=" settings=${_lib_repo_root}/env/jfr-steady-state.jfc"
      fi
    fi
    # Recording size cap. jcmd JFR.start with no maxsize= takes JFR's 250MB default and
    # ROTATES: the recording silently keeps only the tail. On an Exeris target that is not a
    # theoretical risk — the kernel's own eu.exeris.persistence.* events are ~5-6 commits per
    # request and filled 240MB of the 250MB budget in one measured run, leaving a ~2% tail of a
    # 900s window. Any per-window rate read off such a recording is a tail sample, not a mean.
    # BENCH_JFR_MAXSIZE (e.g. "2g", "512m") lifts the cap; unset preserves the 250MB default so
    # every existing campaign keeps its current behaviour. Pair it with
    # BENCH_JFR_EXTRA_SETTINGS=env/jfr-no-exeris-telemetry.jfc to remove the cause rather than
    # widen the symptom. See docs/methodology.md.
    local _maxsize_arg=""
    if [[ -n "${BENCH_JFR_MAXSIZE:-}" ]]; then
      _maxsize_arg=" maxsize=${BENCH_JFR_MAXSIZE}"
    fi
    if jcmd "$pid" "JFR.start name=${recording_name} settings=${settings}${_extra_settings_arg}${_maxsize_arg} disk=true" \
        >> "${logs_dir}/jfr-start.txt" 2>&1; then
      start_success=true
      note="${recording_already_present:+replaced existing recording; }recording started"
    else
      note="JFR.start command failed"
    fi
  else
    note="JFR.check command failed"
  fi

  jq -n \
    --arg  pid                          "$pid" \
    --argjson jcmd_available            true \
    --argjson start_attempted           "$start_attempted" \
    --argjson start_success             "$start_success" \
    --argjson recording_already_present "$recording_already_present" \
    --arg  recording_name               "$recording_name" \
    --arg  note                         "$note" \
    '{pid:$pid,jcmd_available:$jcmd_available,start_attempted:$start_attempted,
      start_success:$start_success,recording_already_present:$recording_already_present,
      recording_name:$recording_name,note:$note}' \
    > "${logs_dir}/jfr-start.json" || true
}

bench_capture_jfr_metadata() {
  local pid="$1"
  local logs_dir="$2"
  local jfr_file="$3"
  local jcmd_available=false
  local check_ok=false
  local recording_detected=false
  local dump_attempted=false
  local dump_success=false
  local stop_attempted=false
  local stop_success=false
  local stop_recording_name=""
  local own_recording=""
  local note=""
  local start_meta_file="${logs_dir}/jfr-start.json"

  if command -v jcmd >/dev/null 2>&1; then
    jcmd_available=true
  fi

  if [[ -f "$start_meta_file" ]]; then
    own_recording="$(jq -r \
      'if (.start_success == true and .recording_already_present == false)
       then (.recording_name // "")
       else "" end' "$start_meta_file" 2>/dev/null || true)"
    [[ "$own_recording" == "null" ]] && own_recording=""
  fi

  if [[ "$jcmd_available" == true && -n "$pid" && "$pid" =~ ^[0-9]+$ && -d "/proc/$pid" ]]; then
    if jcmd "$pid" JFR.check > "${logs_dir}/jfr-check.txt" 2>&1; then
      check_ok=true
      if grep -qE "^Recording [0-9]+:" "${logs_dir}/jfr-check.txt" 2>/dev/null; then
        recording_detected=true
        dump_attempted=true
        local dump_name_arg=""
        [[ -n "$own_recording" ]] && dump_name_arg="name=${own_recording} "
        if jcmd "$pid" "JFR.dump ${dump_name_arg}filename=${jfr_file}" > /dev/null 2>&1; then
          [[ -f "$jfr_file" ]] && dump_success=true
        fi
      fi
    fi
  fi

  if [[ "$recording_detected" == true && -n "$own_recording" ]]; then
    stop_recording_name="$own_recording"
    stop_attempted=true
    if jcmd "$pid" "JFR.stop name=${stop_recording_name}" \
        > "${logs_dir}/jfr-stop.txt" 2>&1; then
      stop_success=true
    else
      note="jfr stop attempted but failed"
    fi
  elif [[ "$recording_detected" == true && -z "$own_recording" ]]; then
    note="jfr stop skipped: recording ownership not from this run"
  fi

  [[ -f "${logs_dir}/jfr-check.txt" ]] || : > "${logs_dir}/jfr-check.txt"
  [[ -f "${logs_dir}/jfr-stop.txt"  ]] || : > "${logs_dir}/jfr-stop.txt"

  jq -n \
    --arg  pid                  "$pid" \
    --argjson jcmd_available    "$jcmd_available" \
    --argjson check_ok          "$check_ok" \
    --argjson recording_detected "$recording_detected" \
    --argjson dump_attempted    "$dump_attempted" \
    --argjson dump_success      "$dump_success" \
    --argjson stop_attempted    "$stop_attempted" \
    --argjson stop_success      "$stop_success" \
    --arg  stop_recording_name  "$stop_recording_name" \
    --arg  jfr_file             "$jfr_file" \
    --arg  note                 "$note" \
    '{pid:$pid,jcmd_available:$jcmd_available,check_ok:$check_ok,
      recording_detected:$recording_detected,dump_attempted:$dump_attempted,
      dump_success:$dump_success,stop_attempted:$stop_attempted,
      stop_success:$stop_success,stop_recording_name:$stop_recording_name,
      jfr_file:$jfr_file,note:$note}' \
    > "${logs_dir}/jfr-metadata.json" || true
}
