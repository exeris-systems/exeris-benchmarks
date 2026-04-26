#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <campaign-dir>"
  exit 1
fi

CAMPAIGN_DIR="$1"
if [[ ! -d "$CAMPAIGN_DIR" ]]; then
  echo "ERROR: Campaign directory not found: $CAMPAIGN_DIR"
  exit 1
fi

TMP_FILE="$CAMPAIGN_DIR/.repeatability-input.ndjson"
SUMMARY_JSON="$CAMPAIGN_DIR/repeatability-summary.json"
SUMMARY_MD="$CAMPAIGN_DIR/repeatability-summary.md"

: > "$TMP_FILE"

for result_file in "$CAMPAIGN_DIR"/repeat-*/result.json; do
  if [[ ! -f "$result_file" ]]; then
    continue
  fi

  if ! jq -e . "$result_file" >/dev/null 2>&1; then
    continue
  fi

  jq -c '{
    run_label: (.run_id // "unknown"),
    throughput_rps: (.metrics.throughput_rps // null),
    latency_p99_us: (.metrics.latency_p99_us // null),
    total_errors: (.metrics.total_errors // null)
  }' "$result_file" >> "$TMP_FILE"
done

if [[ ! -s "$TMP_FILE" ]]; then
  echo "ERROR: No valid repeat result.json files found in $CAMPAIGN_DIR"
  rm -f "$TMP_FILE"
  exit 1
fi

jq -s '
  def median(arr):
    (arr | length) as $n
    | if $n == 0 then null
      elif ($n % 2) == 1 then arr[($n / 2 | floor)]
      else ((arr[($n / 2 - 1)] + arr[($n / 2)]) / 2)
      end;
  def mean(arr):
    if (arr | length) == 0 then null else (arr | add) / (arr | length) end;
  def stddev_pop(arr):
    (mean(arr)) as $m
    | if $m == null then null
      else ((arr | map((. - $m) * (. - $m)) | add) / (arr | length) | sqrt)
      end;

  map(select(.throughput_rps != null and .latency_p99_us != null and .total_errors != null)) as $runs
  | ($runs | map(.throughput_rps) | sort) as $throughput
  | ($runs | map(.latency_p99_us) | sort) as $p99
  | (mean($throughput)) as $throughput_mean
  | (stddev_pop($throughput)) as $throughput_stddev
  | if $throughput_mean == null or $throughput_mean == 0 then null else ($throughput_stddev / $throughput_mean) end as $throughput_cv
  | ($runs | all(.total_errors == 0)) as $all_zero_errors
  | {
      sample_size: ($runs | length),
      throughput_rps: {
        min: ($throughput[0] // null),
        median: median($throughput),
        max: ($throughput[-1] // null),
        coefficient_of_variation: $throughput_cv
      },
      latency_p99_us: {
        min: ($p99[0] // null),
        median: median($p99),
        max: ($p99[-1] // null)
      },
      gate: {
        cv_threshold: 0.15,
        all_total_errors_zero: $all_zero_errors,
        result: (if ($throughput_cv != null and $throughput_cv <= 0.15 and $all_zero_errors and ($runs | length) > 0) then "pass" else "fail" end)
      }
    }
' "$TMP_FILE" > "$SUMMARY_JSON"

sample_size="$(jq -r '.sample_size' "$SUMMARY_JSON")"
throughput_min="$(jq -r '.throughput_rps.min' "$SUMMARY_JSON")"
throughput_median="$(jq -r '.throughput_rps.median' "$SUMMARY_JSON")"
throughput_max="$(jq -r '.throughput_rps.max' "$SUMMARY_JSON")"
throughput_cv="$(jq -r '.throughput_rps.coefficient_of_variation' "$SUMMARY_JSON")"
p99_min="$(jq -r '.latency_p99_us.min' "$SUMMARY_JSON")"
p99_median="$(jq -r '.latency_p99_us.median' "$SUMMARY_JSON")"
p99_max="$(jq -r '.latency_p99_us.max' "$SUMMARY_JSON")"
gate_result="$(jq -r '.gate.result' "$SUMMARY_JSON")"

cat > "$SUMMARY_MD" <<EOF
# Entity Read-By-ID Campaign Repeatability Summary

- Sample size: $sample_size
- Throughput (RPS): min=$throughput_min median=$throughput_median max=$throughput_max
- Throughput CV: $throughput_cv
- P99 latency (us): min=$p99_min median=$p99_median max=$p99_max
- Gate result: $gate_result (pass requires CV <= 0.15 and all total_errors == 0)
EOF

rm -f "$TMP_FILE"

echo "Wrote: $SUMMARY_JSON"
echo "Wrote: $SUMMARY_MD"
