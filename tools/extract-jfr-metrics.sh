#!/usr/bin/env bash
# extract-jfr-metrics.sh
# Extract CPU / memory / GC metrics from a JFR recording using `jfr print --json`.

set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[extract-jfr-metrics] $*" >&2; }

usage() {
  cat >&2 <<'EOF'
Usage: extract-jfr-metrics.sh [options] <jfr-file> [output-json]

Options:
  --window-start <iso8601>  Start of the measurement window (inclusive).
  --window-end   <iso8601>  End of the measurement window (inclusive).

Both accept any offset form date(1) parses ("...Z" or "...+02:00"). Supplying a
window is how the RUNTIME track bounds the measurement: see the window-source
note below.
EOF
  exit 2
}

WINDOW_START_ARG=""
WINDOW_END_ARG=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --window-start) [[ $# -ge 2 ]] || usage; WINDOW_START_ARG="$2"; shift 2 ;;
    --window-end)   [[ $# -ge 2 ]] || usage; WINDOW_END_ARG="$2";   shift 2 ;;
    -h|--help)      usage ;;
    --)             shift; POSITIONAL+=("$@"); break ;;
    -*)             fail "unknown option: $1" ;;
    *)              POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

JFR_FILE="${1:?$(usage)}"
OUTPUT_FILE="${2:-}"

[[ -f "$JFR_FILE" ]] || fail "JFR file not found: $JFR_FILE"
command -v jq >/dev/null 2>&1 || fail "jq is required"

_java="$(command -v java 2>/dev/null)" || fail "java not found in PATH"
JFR_BIN="$(dirname "$_java")/jfr"
[[ -x "$JFR_BIN" ]] || fail "jfr binary not found at: $JFR_BIN"

JFR_TOOL_VERSION="$($JFR_BIN --version 2>/dev/null | head -n 1 | sed 's/"/\\"/g' || echo "unknown")"

# Convert an ISO-8601 instant to epoch seconds. JFR emits local-offset stamps
# ("2026-07-31T13:54:54.016+02:00") while the harness records window boundaries
# in UTC ("2026-07-31T12:02:05Z"); comparing those two as STRINGS silently
# mis-orders them, so every comparison below happens in epoch seconds.
to_epoch() {
  local iso="$1" out
  out="$(date -u -d "${iso}" +%s 2>/dev/null)" || fail "unparseable timestamp: ${iso}"
  [[ -n "${out}" ]] || fail "unparseable timestamp: ${iso}"
  echo "${out}"
}

WINDOW_START_EPOCH="null"
WINDOW_END_EPOCH="null"
[[ -n "${WINDOW_START_ARG}" ]] && WINDOW_START_EPOCH="$(to_epoch "${WINDOW_START_ARG}")"
[[ -n "${WINDOW_END_ARG}" ]]   && WINDOW_END_EPOCH="$(to_epoch "${WINDOW_END_ARG}")"

if [[ "${WINDOW_START_EPOCH}" != "null" && "${WINDOW_END_EPOCH}" != "null" \
      && "${WINDOW_END_EPOCH}" -le "${WINDOW_START_EPOCH}" ]]; then
  fail "--window-end (${WINDOW_END_ARG}) is not after --window-start (${WINDOW_START_ARG})"
fi

# Only these five event types are consumed by the jq filter below, so filtering
# at the SOURCE is not a micro-optimisation. `jfr print --json` expands a
# recording by roughly an order of magnitude and jq then parses the result as a
# single document. Exeris targets emit high-volume custom telemetry — in the
# entity-read-by-id campaign 93 % of a 3.8 GB recording was
# eu.exeris.kernel.persistence.* — so the unfiltered dump exhausts memory.
# Filtered, the same recording yields ~14 MB and parses in well under a second.
JFR_EVENTS='jdk.CPULoad,jdk.GarbageCollection,jdk.ResidentSetSize,jdk.GCHeapSummary,eu.exeris.bench.PhaseMarkerEvent'

JFR_JSON_FILE="$(mktemp)"
trap 'rm -f "$JFR_JSON_FILE"' EXIT

LC_ALL=C "$JFR_BIN" print --json --events "$JFR_EVENTS" "$JFR_FILE" > "$JFR_JSON_FILE"

METRICS_JSON="$(jq -c \
  --arg jfr_tool_version "$JFR_TOOL_VERSION" \
  --arg window_start_iso "$WINDOW_START_ARG" \
  --arg window_end_iso "$WINDOW_END_ARG" \
  --argjson win_start "$WINDOW_START_EPOCH" \
  --argjson win_end "$WINDOW_END_EPOCH" '
  def to_num:
    if . == null then 0
    elif (type == "number") then .
    else
      (tostring
        | gsub("%"; "")
        | gsub(","; ".")
        | (capture("(?<n>[-+]?[0-9]+(?:\\.[0-9]+)?)")? | .n)
        | tonumber?) // 0
    end;

  def clamp_pct:
    if . < 0 then 0
    elif . > 100 then 100
    else .
    end;

  def duration_to_ms:
    if . == null then 0
    elif (type == "number") then .
    else
      (tostring) as $s |
      if ($s | test("^PT")) then
        (($s | capture("^PT(?:(?<h>[0-9]+)H)?(?:(?<m>[0-9]+)M)?(?<sec>[0-9]+(?:\\.[0-9]+)?)S$")?) as $m
          | if $m == null then 0
            else ((($m.h // "0") | tonumber) * 3600000)
              + ((($m.m // "0") | tonumber) * 60000)
              + ((($m.sec // "0") | tonumber) * 1000)
            end)
      elif ($s | test("[[:space:]]ns$")) then (($s | to_num) / 1000000)
      elif ($s | test("[[:space:]]us$")) then (($s | to_num) / 1000)
      elif ($s | test("[[:space:]]ms$")) then ($s | to_num)
      elif ($s | test("[[:space:]]s$")) then (($s | to_num) * 1000)
      else 0
      end
    end;

  def events_by_type($type):
    [(.recording.events // [])[]? | select(.type == $type) | .values];

  def events_with_meta($type):
    [(.recording.events // [])[]? | select(.type == $type) | {startTime: (.startTime // .values.startTime), values: .values}];

  # JFR stamps carry a local offset ("...+02:00"); harness window boundaries are
  # UTC ("...Z"). Both are normalised to epoch seconds so ordering is real
  # rather than lexicographic.
  def iso_to_epoch:
    if . == null then null
    else
      ((capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\\.[0-9]+)?(?<tz>Z|[+-][0-9]{2}:?[0-9]{2})?$")?) // null) as $m
      | if $m == null then null
        else
          ((($m.d) + "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $base
          | (if (($m.tz) // "Z") == "Z" then 0
             else (($m.tz) | gsub(":"; "")) as $t
               | ((($t[1:3] | tonumber) * 3600) + (($t[3:5] | tonumber) * 60))
                 * (if ($t[0:1]) == "-" then -1 else 1 end)
             end) as $off
          | $base - $off
        end
      end;

  def events_windowed($type; $ws; $we):
    if $ws == null and $we == null then events_by_type($type)
    else
      [ events_with_meta($type)[]
        | . as $e
        | ($e.startTime | iso_to_epoch) as $t
        | select($t != null
                 and ($ws == null or $t >= $ws)
                 and ($we == null or $t <= $we))
        | $e.values ]
    end;

  def max_of:
    if (length) == 0 then 0 else max end;

  # Window precedence: an explicitly supplied window wins, then the JMH-track
  # PhaseMarkerEvent, then the whole recording. The runtime track has no phase
  # marker — that event is emitted only by the JMH TLS benchmarks — so without
  # an explicit window its maxima would silently include warmup and startup.
  (events_with_meta("eu.exeris.bench.PhaseMarkerEvent")
    | map(.startTime | iso_to_epoch) | map(select(. != null))
    | if length > 0 then min else null end) as $phase_start |

  (if $win_start != null then $win_start else $phase_start end) as $ws |
  $win_end as $we |

  (if $win_start != null then "explicit_window"
   elif $phase_start != null then "phase_marker_event"
   else "whole_recording" end) as $window_source |

  (events_windowed("jdk.CPULoad"; $ws; $we)) as $cpu |
  (events_windowed("jdk.GarbageCollection"; $ws; $we)) as $gc |
  (events_windowed("jdk.ResidentSetSize"; $ws; $we)) as $rss |
  (events_windowed("jdk.GCHeapSummary"; $ws; $we)) as $heap |

  ($cpu | map(.jvmUser | to_num) | max_of) as $jvm_user_raw |
  ($cpu | map(.jvmSystem | to_num) | max_of) as $jvm_sys_raw |
  ($cpu | map(.machineTotal | to_num) | max_of) as $machine_raw |

  (if $jvm_user_raw > 1.5 then 1 else 100 end) as $cpu_scale |

  (($jvm_user_raw * $cpu_scale) | clamp_pct) as $jvm_user_pct |
  (($jvm_sys_raw * $cpu_scale) | clamp_pct) as $jvm_sys_pct |
  (($machine_raw * $cpu_scale) | clamp_pct) as $machine_pct |

  ($rss | map(.size | to_num) | max_of) as $rss_max_bytes |
  ($heap | map(.heapUsed | to_num) | max_of) as $heap_used_max |
  ($heap | map(.heapSpace.committedSize | to_num) | max_of) as $heap_committed_max |

  ($gc | map(.duration | duration_to_ms)) as $gc_pause_ms |
  ($gc_pause_ms | max_of) as $gc_pause_max_ms |
  ($gc_pause_ms | add // 0) as $gc_pause_total_ms |

  (if $rss_max_bytes > 0 then $rss_max_bytes else $heap_used_max end) as $max_rss_bytes |
  (if $rss_max_bytes > 0 then "jdk.ResidentSetSize" else "jdk.GCHeapSummary.heapUsed (proxy)" end) as $rss_source |

  [] as $warnings_base |
  (if $window_source == "whole_recording"
    then ($warnings_base + ["no measurement window supplied and no PhaseMarkerEvent found; maxima span the whole recording and include warmup/startup"])
    else $warnings_base end) as $warnings_w |
  (if $window_source != "whole_recording" and ($cpu | length) == 0 and ($gc | length) == 0 and ($rss | length) == 0 and ($heap | length) == 0
    then ($warnings_w + ["measurement window selected zero events; verify the window overlaps the recording span"])
    else $warnings_w end) as $warnings0 |
  (if ($cpu | length) == 0 then ($warnings0 + ["jdk.CPULoad events not found"]) else $warnings0 end) as $warnings1 |
  (if ($gc | length) == 0 then ($warnings1 + ["jdk.GarbageCollection events not found"]) else $warnings1 end) as $warnings2 |
  (if ($rss | length) == 0 and ($heap | length) > 0 then ($warnings2 + ["jdk.ResidentSetSize unavailable; using jdk.GCHeapSummary.heapUsed as RSS proxy"]) else $warnings2 end) as $warnings3 |
  (if ($rss | length) == 0 and ($heap | length) == 0 then ($warnings3 + ["No resident memory events found (jdk.ResidentSetSize/jdk.GCHeapSummary)"]) else $warnings3 end) as $warnings4 |
  (if (($gc | length) > 0 and $gc_pause_max_ms == 0) then ($warnings4 + ["gc_event_count>0 but gc_pause_max_ms==0; verify JFR GC duration parsing"]) else $warnings4 end) as $warnings |

  {
    schema_version: "1.0",
    source: "jfr",
    collection_scope: (if $window_source == "whole_recording" then "jfr_sampled" else "jfr_measurement_window" end),
    cpu: {
      jvm_user_percent_max: (($jvm_user_pct * 100 | round) / 100),
      jvm_system_percent_max: (($jvm_sys_pct * 100 | round) / 100),
      machine_total_percent_max: (($machine_pct * 100 | round) / 100),
      cpu_percent_max: (((($jvm_user_pct + $jvm_sys_pct) | clamp_pct) * 100 | round) / 100)
    },
    memory: {
      max_rss_bytes: ($max_rss_bytes | floor),
      max_rss_kb: (($max_rss_bytes / 1024) | floor),
      max_rss_mb: (($max_rss_bytes / 1048576) | floor),
      heap_used_max_bytes: ($heap_used_max | floor),
      rss_source: $rss_source
    },
    gc: {
      gc_count: ($gc | length),
      gc_pause_max_ms: (($gc_pause_max_ms * 1000 | round) / 1000),
      gc_pause_total_ms: (($gc_pause_total_ms * 1000 | round) / 1000),
      heap_used_bytes_max: ($heap_used_max | floor),
      heap_committed_bytes_max: ($heap_committed_max | floor)
    },
    events: {
      "jdk.CPULoad": ($cpu | length),
      "jdk.ResidentSetSize": ($rss | length),
      "jdk.GarbageCollection": ($gc | length),
      "jdk.GCHeapSummary": ($heap | length)
    },
    metadata: {
      jfr_tool_version: $jfr_tool_version,
      window_source: $window_source,
      window_start: (if $window_start_iso == "" then null else $window_start_iso end),
      window_end: (if $window_end_iso == "" then null else $window_end_iso end),
      events_filtered_at_source: true
    },
    warnings: $warnings
  }
' "$JFR_JSON_FILE")"

if [[ -z "$OUTPUT_FILE" ]]; then
  echo "$METRICS_JSON" | jq .
elif [[ "$OUTPUT_FILE" == *.with-metrics.json && -f "$OUTPUT_FILE" ]]; then
  TMP="$(mktemp)"
  jq --argjson m "$METRICS_JSON" '.resource_metrics = $m' "$OUTPUT_FILE" > "$TMP" \
    && mv "$TMP" "$OUTPUT_FILE" \
    || { rm -f "$TMP"; fail "jq patch failed: $OUTPUT_FILE"; }
  log "Patched resource_metrics in: $OUTPUT_FILE"
else
  echo "$METRICS_JSON" | jq . > "$OUTPUT_FILE"
  log "Written to: $OUTPUT_FILE"
fi
