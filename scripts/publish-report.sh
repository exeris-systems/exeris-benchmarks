#!/usr/bin/env bash
# publish-report.sh — Generate a Markdown summary from the latest result set and
# optionally archive to results/history/.
#
# Usage:
#   ./scripts/publish-report.sh --result results/raw/jmh-20260315-120000.json \
#       --env    results/raw/20260315-120000-env.json \
#       --output results/summaries/
#   ./scripts/publish-report.sh --result ... --archive results/history/community/pure/
set -euo pipefail

RESULT_FILE=""
ENV_FILE=""
OUTPUT_DIR=""
ARCHIVE_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --result)  RESULT_FILE="$2"; shift 2 ;;
    --env)     ENV_FILE="$2";    shift 2 ;;
    --output)  OUTPUT_DIR="$2";  shift 2 ;;
    --archive) ARCHIVE_DIR="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$RESULT_FILE" ]] && { echo "ERROR: --result required" >&2; exit 1; }
[[ -z "$OUTPUT_DIR" ]]  && { echo "ERROR: --output required" >&2; exit 1; }

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required" >&2; exit 1
fi

mkdir -p "$OUTPUT_DIR"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$OUTPUT_DIR/report-${TIMESTAMP}.md"

{
  echo "# Exeris Benchmark Report"
  echo ""
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""
  echo "## Run metadata"
  echo ""
  echo "| Field | Value |"
  echo "|---|---|"
  jq -r '
    "| run_id | \(.run_id) |",
    "| scenario | \(.scenario) |",
    "| tool | \(.tool) |",
    "| target repo | \(.target.repo // "N/A") |",
    "| target commit | \(.target.commit_sha // "N/A") |",
    "| target mode | \(.target.mode // "N/A") |",
    "| target tier | \(.target.tier // "N/A") |"
  ' "$RESULT_FILE"
  echo ""

  if [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]]; then
    echo "## Environment"
    echo ""
    echo "| Field | Value |"
    echo "|---|---|"
    jq -r '
      "| hardware_profile | \(.hardware_profile) |",
      "| cpu_model | \(.cpu.model) |",
      "| physical_cores | \(.cpu.physical_cores) |",
      "| memory_gb | \(.memory_gb) |",
      "| os | \(.os.name) \(.os.version) |",
      "| kernel | \(.kernel) |",
      "| jdk | \(.jdk.vendor) \(.jdk.version) |",
      "| cpu_governor | \(.cpu.cpu_governor // "unknown") |"
    ' "$ENV_FILE"
    echo ""
  fi

  echo "## Results"
  echo ""
  echo "| Metric | Value |"
  echo "|---|---|"
  jq -r '
    .metrics |
    to_entries[] |
    select(.value != null) |
    "| \(.key) | \(.value) |"
  ' "$RESULT_FILE"

} > "$REPORT"

echo "Report written to: $REPORT"

if [[ -n "$ARCHIVE_DIR" ]]; then
  mkdir -p "$ARCHIVE_DIR"
  REPO_SHA="$(jq -r '.target.commit_sha // "unknown"' "$RESULT_FILE" | cut -c1-7)"
  ARCHIVE_NAME="${TIMESTAMP}-${REPO_SHA}.json"
  cp "$RESULT_FILE" "$ARCHIVE_DIR/$ARCHIVE_NAME"
  echo "Result archived to: $ARCHIVE_DIR/$ARCHIVE_NAME"
fi
