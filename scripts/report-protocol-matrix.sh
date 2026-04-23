#!/usr/bin/env bash
# report-protocol-matrix.sh — build matrix summaries from normalized result JSON files.
#
# Usage:
#   ./scripts/report-protocol-matrix.sh results/normalized > results/summaries/protocol-matrix.md
set -euo pipefail

RESULT_DIR="${1:-results/normalized}"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

if [[ ! -d "$RESULT_DIR" ]]; then
  echo "ERROR: directory not found: $RESULT_DIR" >&2
  exit 1
fi

echo "# Protocol Matrix Summary"
echo ""
echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

echo "## Within-tier"
echo ""
echo "| Tier | Protocol | Scenario | Throughput (rps) | p99 (us) | Source |"
echo "|---|---|---|---:|---:|---|"

TMP="$(mktemp)"
trap 'rm -f "${TMP:-}"' EXIT

readarray -d '' result_files < <(find "$RESULT_DIR" -type f -name '*.json' -print0)

if [[ ${#result_files[@]} -gt 0 ]]; then
  jq -r '
    select(.target.tier != null and .target.protocol != null) |
    [
      .target.tier,
      .target.protocol,
      .scenario,
      (.metrics.throughput_rps // "N/A"),
      (.metrics.latency_p99_us // "N/A"),
      input_filename
    ] | @tsv
  ' "${result_files[@]}" \
  | sort \
  | awk -F'\t' '{ printf("| %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $6) }'
fi

echo ""
echo "## Cross-tier same-protocol pairs"
echo ""
echo "| Protocol | Scenario | Community rps | Enterprise rps | Delta (Enterprise vs Community) |"
echo "|---|---|---:|---:|---:|"

if [[ ${#result_files[@]} -gt 0 ]]; then
  jq -r '
    select((.target.protocol == "h1" or .target.protocol == "h2") and .target.tier != null) |
    [
      .target.protocol,
      .scenario,
      .target.tier,
      (.metrics.throughput_rps // "")
    ] | @tsv
  ' "${result_files[@]}" > "$TMP"
else
  : > "$TMP"
fi

for protocol in h1 h2; do
  awk -F'\t' -v p="$protocol" '$1==p {print}' "$TMP" | awk -F'\t' '
    {
      key=$1"|"$2;
      if ($3=="community") c[key]=$4;
      if ($3=="enterprise") e[key]=$4;
      scen[key]=$2;
    }
    END {
      for (k in scen) {
        cv = (k in c ? c[k] : "N/A");
        ev = (k in e ? e[k] : "N/A");
        delta = "N/A";
        if (cv != "N/A" && ev != "N/A" && cv != "" && ev != "" && cv+0 != 0) {
          delta = sprintf("%+.2f%%", ((ev+0)-(cv+0))/(cv+0)*100.0);
        }
        split(k, arr, "|");
        printf("| %s | %s | %s | %s | %s |\n", arr[1], scen[k], cv, ev, delta);
      }
    }
  ' | sort

done

rm -f "$TMP"
