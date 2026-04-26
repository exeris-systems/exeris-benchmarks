#!/usr/bin/env bash
# normalize-result.sh — bridge between run-jmh-case.sh artifacts and compare/publish pipeline
# Converts raw JMH output, status JSON, and reproducibility metadata into normalized result JSON
set -euo pipefail

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") \\
  --jmh-json <path>          Raw JMH output JSON (required)
  --status-json <path>       Status JSON from run-jmh-case.sh (required)
  --repro-json <path>        Reproducibility metadata JSON (required)
  --output <path>            Output normalized result JSON path (required)
  --run-id <id>              Run identifier (default: derived from output filename)
  --comparison-axis <axis>   Comparison axis label (default: none)
  --forks <n>                Fork count used in run (default: read from JMH json if possible, else 1)
EOF
  exit 1
}

JMH_JSON=""
STATUS_JSON=""
REPRO_JSON=""
OUTPUT=""
RUN_ID=""
COMPARISON_AXIS="none"
FORKS=""
JFR_METRICS_JSON=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jmh-json)        JMH_JSON="$2";        shift 2 ;;
    --status-json)     STATUS_JSON="$2";     shift 2 ;;
    --repro-json)      REPRO_JSON="$2";      shift 2 ;;
    --output)          OUTPUT="$2";          shift 2 ;;
    --run-id)          RUN_ID="$2";          shift 2 ;;
    --comparison-axis) COMPARISON_AXIS="$2"; shift 2 ;;
    --forks)           FORKS="$2";           shift 2 ;;
    --jfr-metrics)     JFR_METRICS_JSON="$2"; shift 2 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage ;;
  esac
done

[[ -z "$JMH_JSON" ]]   && { echo "ERROR: --jmh-json is required" >&2;   usage; }
[[ -z "$STATUS_JSON" ]] && { echo "ERROR: --status-json is required" >&2; usage; }
[[ -z "$REPRO_JSON" ]]  && { echo "ERROR: --repro-json is required" >&2;  usage; }
[[ -z "$OUTPUT" ]]      && { echo "ERROR: --output is required" >&2;      usage; }

[[ -f "$JMH_JSON" ]]    || { echo "ERROR: JMH JSON not found: $JMH_JSON" >&2;    exit 1; }
[[ -f "$STATUS_JSON" ]] || { echo "ERROR: Status JSON not found: $STATUS_JSON" >&2; exit 1; }
[[ -f "$REPRO_JSON" ]]  || { echo "ERROR: Repro JSON not found: $REPRO_JSON" >&2;  exit 1; }

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required but not found in PATH" >&2; exit 1; }

# Derive run_id from output filename if not provided
if [[ -z "$RUN_ID" ]]; then
  RUN_ID="$(basename "$OUTPUT" .json)"
fi

# Derive forks from JMH json if not explicitly provided
if [[ -z "$FORKS" ]]; then
  FORKS=$(jq '[.[].forks // 1] | max // 1' "$JMH_JSON" 2>/dev/null || echo 1)
  [[ -z "$FORKS" || "$FORKS" == "null" ]] && FORKS=1
fi

# Ensure forks is a positive integer
[[ "$FORKS" =~ ^[0-9]+$ ]] || FORKS=1

# Derive execution_class: guard if forks >= 3, else exploratory
if [[ "$FORKS" -ge 3 ]]; then
  EXECUTION_CLASS="guard"
else
  EXECUTION_CLASS="exploratory"
fi

# Extract fields from status JSON
RUNNER_STATUS=$(jq -r '.runner_status // "failed"' "$STATUS_JSON")
POSTPROCESS_RC=$(jq -r '.postprocess_rc // 0' "$STATUS_JSON")
METRICS_COLLECTED=$(jq -r '.metrics_collected // false' "$STATUS_JSON")

# Derive claim_scope
if [[ "$RUNNER_STATUS" == "success" && "$EXECUTION_CLASS" == "guard" ]]; then
  CLAIM_SCOPE="comparison_eligible"
else
  CLAIM_SCOPE="descriptive_only"
fi

# Derive final_reason
if [[ "$RUNNER_STATUS" == "success" ]]; then
  FINAL_REASON="ok"
elif [[ "$RUNNER_STATUS" == "failed" ]]; then
  if [[ "$POSTPROCESS_RC" != "0" ]]; then
    FINAL_REASON="postprocess_exit_nonzero"
  elif [[ "$METRICS_COLLECTED" == "false" ]]; then
    FINAL_REASON="missing_metrics"
  else
    FINAL_REASON="benchmark_exit_nonzero"
  fi
elif [[ "$RUNNER_STATUS" == "partial" ]]; then
  FINAL_REASON="partial_json"
else
  FINAL_REASON="benchmark_exit_nonzero"
fi

# Build metrics from raw JMH JSON
# For thrpt: mean of primaryMetric.score
# For sample: mean of scorePercentiles 50.0 / 99.0 / 99.9 — only emit keys with data
METRICS_JSON=$(jq -n \
  --slurpfile jmh "$JMH_JSON" \
  '
    ($jmh[0] // []) as $entries |
    [ $entries[] | select(.mode == "thrpt") | .primaryMetric.score ] as $thrpt |
    [ $entries[]
      | select(.mode == "thrpt")
      | {
          key: ((.benchmark // "unknown")|tostring) + "|payload=" + (
            ((.params // {}) as $params
             | if ($params | type) == "object" then
                 ($params.payloadBytes // $params.payload // "unknown")
               else
                 "unknown"
               end
            )
            | tostring
          ),
          value: .primaryMetric.score
        }
      | select(.value != null)
    ] as $thrptByCaseRows |
    [ $entries[] | select(.mode == "sample") | .primaryMetric.scorePercentiles["50.0"] // empty ] as $p50 |
    [ $entries[] | select(.mode == "sample") | .primaryMetric.scorePercentiles["99.0"] // empty ] as $p99 |
    [ $entries[] | select(.mode == "sample") | .primaryMetric.scorePercentiles["99.9"] // empty ] as $p999 |
    [ $entries[]
      | select(.mode == "sample")
      | {
          key: ((.benchmark // "unknown")|tostring) + "|payload=" + (
            ((.params // {}) as $params
             | if ($params | type) == "object" then
                 ($params.payloadBytes // $params.payload // "unknown")
               else
                 "unknown"
               end
            )
            | tostring
          ),
          value: (.primaryMetric.scorePercentiles["50.0"] // null)
        }
      | select(.value != null)
    ] as $p50ByCaseRows |
    [ $entries[]
      | select(.mode == "sample")
      | {
          key: ((.benchmark // "unknown")|tostring) + "|payload=" + (
            ((.params // {}) as $params
             | if ($params | type) == "object" then
                 ($params.payloadBytes // $params.payload // "unknown")
               else
                 "unknown"
               end
            )
            | tostring
          ),
          value: (.primaryMetric.scorePercentiles["99.0"] // null)
        }
      | select(.value != null)
    ] as $p99ByCaseRows |
    [ $entries[]
      | select(.mode == "sample")
      | {
          key: ((.benchmark // "unknown")|tostring) + "|payload=" + (
            ((.params // {}) as $params
             | if ($params | type) == "object" then
                 ($params.payloadBytes // $params.payload // "unknown")
               else
                 "unknown"
               end
            )
            | tostring
          ),
          value: (.primaryMetric.scorePercentiles["99.9"] // null)
        }
      | select(.value != null)
    ] as $p999ByCaseRows |
    {}
    | if ($thrpt | length) > 0 then
        . + {
          throughput_rps: (($thrpt | add) / ($thrpt | length)),
          throughput_rps_scope: "aggregate_over_all_thrpt_rows"
        }
      else
        .
      end
    | if ($p50  | length) > 0 then . + { latency_mean_us: (($p50  | add) / ($p50  | length)) } else . end
    | if ($p99  | length) > 0 then . + { latency_p99_us:  (($p99  | add) / ($p99  | length)) } else . end
    | if ($p999 | length) > 0 then . + { latency_p999_us: (($p999 | add) / ($p999 | length)) } else . end
    | if ($thrptByCaseRows | length) > 0 then
        . + {
          throughput_rps_by_case: (
            reduce $thrptByCaseRows[] as $row ({};
              .[$row.key] = ((.[$row.key] // []) + [$row.value])
            )
            | map_values((add / length))
          )
        }
      else
        .
      end
    | if ($p50ByCaseRows | length) > 0 then
        . + {
          latency_p50_us_by_case: (
            reduce $p50ByCaseRows[] as $row ({};
              .[$row.key] = ((.[$row.key] // []) + [$row.value])
            )
            | map_values((add / length))
          )
        }
      else
        .
      end
    | if ($p99ByCaseRows | length) > 0 then
        . + {
          latency_p99_us_by_case: (
            reduce $p99ByCaseRows[] as $row ({};
              .[$row.key] = ((.[$row.key] // []) + [$row.value])
            )
            | map_values((add / length))
          )
        }
      else
        .
      end
    | if ($p999ByCaseRows | length) > 0 then
        . + {
          latency_p999_us_by_case: (
            reduce $p999ByCaseRows[] as $row ({};
              .[$row.key] = ((.[$row.key] // []) + [$row.value])
            )
            | map_values((add / length))
          )
        }
      else
        .
      end
  ')

# Merge JFR metrics if available
JFR_BLOCK="null"
if [[ -n "$JFR_METRICS_JSON" && -f "$JFR_METRICS_JSON" ]]; then
  if jq empty "$JFR_METRICS_JSON" 2>/dev/null; then
    JFR_BLOCK=$(jq -c '{cpu: .cpu, memory: .memory, gc: .gc, warnings: (.warnings // [])}' "$JFR_METRICS_JSON" 2>/dev/null || echo "null")
  fi
fi

# Extract reproducibility metadata fields
COMMIT_SHA=$(jq -r '.benchmark_commit_sha // .target_commit_sha // "unknown"' "$REPRO_JSON")
TIER=$(jq -r '.tier // "community"' "$REPRO_JSON")
SCENARIO_ID=$(jq -r '.scenario_id // ""' "$REPRO_JSON")
FAMILY=$(jq -r '.family // "micro"' "$REPRO_JSON")
IMPL_VARIANT=$(jq -r '.implementation_variant // ""' "$REPRO_JSON")

# Emit normalized result JSON
mkdir -p "$(dirname "$OUTPUT")"
jq -n \
  --arg run_id          "$RUN_ID" \
  --arg scenario        "$SCENARIO_ID" \
  --arg tool            "jmh" \
  --arg commit_sha      "$COMMIT_SHA" \
  --arg tier            "$TIER" \
  --arg mode            "$IMPL_VARIANT" \
  --arg execution_class "$EXECUTION_CLASS" \
  --arg claim_scope     "$CLAIM_SCOPE" \
  --arg final_reason    "$FINAL_REASON" \
  --arg benchmark_family "$FAMILY" \
  --arg comparison_axis "$COMPARISON_AXIS" \
  --argjson metrics     "$METRICS_JSON" \
  --argjson jfr_metrics "$JFR_BLOCK" \
  --slurpfile repro     "$REPRO_JSON" \
  '{
    run_id:            $run_id,
    scenario:          $scenario,
    tool:              $tool,
    target: {
      repo:       "exeris-benchmarks",
      commit_sha: $commit_sha,
      mode:       $mode,
      tier:       $tier
    },
    execution_class:   $execution_class,
    claim_scope:       $claim_scope,
    final_reason:      $final_reason,
    benchmark_family:  $benchmark_family,
    comparison_axis:   $comparison_axis,
    metrics:           $metrics,
    jfr_metrics:       (if $jfr_metrics != null then $jfr_metrics else null end),
    reproducibility_metadata: ($repro[0] // null)
  }' > "$OUTPUT"

echo "Normalized result written to: $OUTPUT"
