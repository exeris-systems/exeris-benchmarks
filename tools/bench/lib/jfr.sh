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
    if jcmd "$pid" "JFR.start name=${recording_name} settings=${settings} disk=true" \
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
