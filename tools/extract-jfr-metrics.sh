#!/usr/bin/env bash
# extract-jfr-metrics.sh
# Extract CPU / memory / GC metrics from a JFR recording using `jfr print --json`.

set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[extract-jfr-metrics] $*" >&2; }

JFR_FILE="${1:?Usage: $0 <jfr-file> [output-json]}"
OUTPUT_FILE="${2:-}"

[[ -f "$JFR_FILE" ]] || fail "JFR file not found: $JFR_FILE"
command -v jq >/dev/null 2>&1 || fail "jq is required"

_java="$(command -v java 2>/dev/null)" || fail "java not found in PATH"
JFR_BIN="$(dirname "$_java")/jfr"
[[ -x "$JFR_BIN" ]] || fail "jfr binary not found at: $JFR_BIN"

JFR_TOOL_VERSION="$($JFR_BIN --version 2>/dev/null | head -n 1 | sed 's/"/\\"/g' || echo "unknown")"

JFR_JSON_FILE="$(mktemp)"
trap 'rm -f "$JFR_JSON_FILE"' EXIT

LC_ALL=C "$JFR_BIN" print --json "$JFR_FILE" > "$JFR_JSON_FILE"

METRICS_JSON="$(jq -c --arg jfr_tool_version "$JFR_TOOL_VERSION" '
  def to_num:
    if . == null then 0
    elif (type == "number") then .
    else
      (tostring
        | gsub("%"; "")
        | gsub(","; ".")
        | capture("(?<n>[-+]?[0-9]+(?:\\.[0-9]+)?)")?.n
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

  def events_windowed($type; $ws):
    if $ws == null then events_by_type($type)
    else [events_with_meta($type)[] | select(.startTime != null and .startTime >= $ws) | .values]
    end;

  def max_of:
    if (length) == 0 then 0 else max end;

  (events_with_meta("eu.exeris.bench.PhaseMarkerEvent")
    | if length > 0 then (sort_by(.startTime) | first | .startTime) else null end) as $window_start |

  (events_windowed("jdk.CPULoad"; $window_start)) as $cpu |
  (events_windowed("jdk.GarbageCollection"; $window_start)) as $gc |
  (events_windowed("jdk.ResidentSetSize"; $window_start)) as $rss |
  (events_windowed("jdk.GCHeapSummary"; $window_start)) as $heap |

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
  (if $window_start == null then ($warnings_base + ["PhaseMarkerEvent not found; gc_count/cpu may include setup-phase events"]) else $warnings_base end) as $warnings0 |
  (if ($cpu | length) == 0 then ($warnings0 + ["jdk.CPULoad events not found"]) else $warnings0 end) as $warnings1 |
  (if ($gc | length) == 0 then ($warnings1 + ["jdk.GarbageCollection events not found"]) else $warnings1 end) as $warnings2 |
  (if ($rss | length) == 0 and ($heap | length) > 0 then ($warnings2 + ["jdk.ResidentSetSize unavailable; using jdk.GCHeapSummary.heapUsed as RSS proxy"]) else $warnings2 end) as $warnings3 |
  (if ($rss | length) == 0 and ($heap | length) == 0 then ($warnings3 + ["No resident memory events found (jdk.ResidentSetSize/jdk.GCHeapSummary)"]) else $warnings3 end) as $warnings4 |
  (if (($gc | length) > 0 and $gc_pause_max_ms == 0) then ($warnings4 + ["gc_event_count>0 but gc_pause_max_ms==0; verify JFR GC duration parsing"]) else $warnings4 end) as $warnings |

  {
    schema_version: "1.0",
    source: "jfr",
    collection_scope: (if $window_start != null then "jfr_measurement_window" else "jfr_sampled" end),
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
      jfr_tool_version: $jfr_tool_version
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
