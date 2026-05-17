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
PUBLICATION_MODE="public"
JFR_ARTIFACTS=()
DESTRUCTIVE_ARTIFACTS=()

usage() {
  cat <<'EOF'
Usage:
  ./scripts/publish-report.sh --result <result.json> --output <dir> [options]

Options:
  --result <path>             Normalized benchmark result JSON (required)
  --env <path>                Environment metadata JSON
  --output <dir>              Report output directory (required)
  --archive <dir>             Archive directory for result copy
  --publication-mode <mode>   Publication mode: public|internal-only|redacted (default: public)
  --jfr-artifact <path>       JFR-related artifact candidate for publication (repeatable)
  --destructive-artifact <path>
                              Destructive/fuzz artifact candidate (crash input, radamsa
                              dump, slowloris log). Blocked in public mode by basename.
                              Repeatable.
  -h, --help                  Show this help

Confidentiality guard:
  - public: blocks raw JFR artifacts by extension/signature AND destructive
            crash/fuzz artifacts by basename pattern (default-deny)
  - internal-only: allows raw .jfr and destructive artifacts for restricted publication
  - redacted: allows JFR-related artifacts only if raw JFR is not detected; still
              blocks destructive crash inputs
EOF
}

has_jfr_extension() {
  local file_path="$1"
  local lower_path
  lower_path="$(printf '%s' "$file_path" | tr '[:upper:]' '[:lower:]')"
  [[ "$lower_path" == *.jfr ]]
}

read_file_magic_hex() {
  local file_path="$1"
  if command -v xxd &>/dev/null; then
    xxd -p -l 4 "$file_path" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'
    return 0
  fi
  if command -v od &>/dev/null; then
    od -An -N4 -tx1 "$file_path" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'
    return 0
  fi
  return 2
}

is_raw_jfr_file() {
  local file_path="$1"
  local magic_hex

  if has_jfr_extension "$file_path"; then
    return 0
  fi

  magic_hex="$(read_file_magic_hex "$file_path")" || return $?
  [[ "$magic_hex" == "464c5200" ]]
}

# Basenames of artifacts produced by Jazzer/radamsa/slowloris campaigns that may
# contain raw attacker bytes (including the original malformed input that
# crashed the parser). These are blocked in public/redacted publication modes.
is_destructive_crash_input() {
  local file_path="$1"
  local base
  base="$(basename "$file_path")"
  case "$base" in
    crash-*|oom-*|slowloris-*|slow-attack-*|timeout-*|*.fuzz-input|*.radamsa|jazzer-crash-*|jazzer-hang-*)
      return 0
      ;;
  esac
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --result)  RESULT_FILE="$2"; shift 2 ;;
    --env)     ENV_FILE="$2";    shift 2 ;;
    --output)  OUTPUT_DIR="$2";  shift 2 ;;
    --archive) ARCHIVE_DIR="$2"; shift 2 ;;
    --publication-mode) PUBLICATION_MODE="$2"; shift 2 ;;
    --jfr-artifact) JFR_ARTIFACTS+=("$2"); shift 2 ;;
    --destructive-artifact) DESTRUCTIVE_ARTIFACTS+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$RESULT_FILE" ]] && { echo "ERROR: --result required" >&2; exit 1; }
[[ -z "$OUTPUT_DIR" ]]  && { echo "ERROR: --output required" >&2; exit 1; }
[[ ! -f "$RESULT_FILE" ]] && { echo "ERROR: --result path does not exist or is not a file: $RESULT_FILE" >&2; exit 1; }
if [[ -n "$ENV_FILE" && ! -f "$ENV_FILE" ]]; then
  echo "ERROR: --env path does not exist or is not a file: $ENV_FILE" >&2
  exit 1
fi

case "$PUBLICATION_MODE" in
  public|internal-only|redacted) ;;
  *)
    echo "ERROR: invalid --publication-mode '$PUBLICATION_MODE' (expected: public|internal-only|redacted)" >&2
    exit 1
    ;;
esac

for artifact in "${JFR_ARTIFACTS[@]}"; do
  if [[ ! -f "$artifact" ]]; then
    echo "ERROR: --jfr-artifact path does not exist or is not a file: $artifact" >&2
    exit 1
  fi
done

for artifact in "${DESTRUCTIVE_ARTIFACTS[@]}"; do
  if [[ ! -f "$artifact" ]]; then
    echo "ERROR: --destructive-artifact path does not exist or is not a file: $artifact" >&2
    exit 1
  fi
done

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required" >&2; exit 1
fi

RAW_JFR_INPUTS=()
if [[ "$PUBLICATION_MODE" != "internal-only" ]]; then
  if ! command -v xxd &>/dev/null && ! command -v od &>/dev/null; then
    echo "ERROR: public/redacted publication requires content-level JFR detection." >&2
    echo "Install either 'xxd' or 'od', or use --publication-mode internal-only." >&2
    exit 1
  fi

  if is_raw_jfr_file "$RESULT_FILE"; then
    RAW_JFR_INPUTS+=("--result:$RESULT_FILE")
  fi

  if [[ -n "$ENV_FILE" ]] && is_raw_jfr_file "$ENV_FILE"; then
    RAW_JFR_INPUTS+=("--env:$ENV_FILE")
  fi

  for artifact in "${JFR_ARTIFACTS[@]}"; do
    if is_raw_jfr_file "$artifact"; then
      RAW_JFR_INPUTS+=("--jfr-artifact:$artifact")
    fi
  done
fi

if [[ "$PUBLICATION_MODE" == "public" && ${#RAW_JFR_INPUTS[@]} -gt 0 ]]; then
  echo "ERROR: raw JFR artifacts are blocked in public mode (case-insensitive extension/signature check)." >&2
  printf 'Blocked input: %s\n' "${RAW_JFR_INPUTS[@]}" >&2
  echo "Use --publication-mode internal-only for restricted publication, or provide non-raw/redacted artifacts." >&2
  exit 1
fi

if [[ "$PUBLICATION_MODE" == "redacted" && ${#RAW_JFR_INPUTS[@]} -gt 0 ]]; then
  echo "ERROR: redacted mode forbids raw JFR inputs (case-insensitive extension/signature check)." >&2
  printf 'Blocked input: %s\n' "${RAW_JFR_INPUTS[@]}" >&2
  echo "Replace raw JFR inputs with redacted/non-raw artifacts or use --publication-mode internal-only." >&2
  exit 1
fi

DESTRUCTIVE_BLOCKED_INPUTS=()
if [[ "$PUBLICATION_MODE" != "internal-only" ]]; then
  for artifact in "${DESTRUCTIVE_ARTIFACTS[@]}"; do
    if is_destructive_crash_input "$artifact"; then
      DESTRUCTIVE_BLOCKED_INPUTS+=("--destructive-artifact:$artifact")
    fi
  done
fi

if [[ ${#DESTRUCTIVE_BLOCKED_INPUTS[@]} -gt 0 ]]; then
  echo "ERROR: destructive crash/fuzz inputs are blocked outside internal-only mode (basename pattern check)." >&2
  printf 'Blocked input: %s\n' "${DESTRUCTIVE_BLOCKED_INPUTS[@]}" >&2
  echo "These files (crash-*, jazzer-crash-*, *.fuzz-input, *.radamsa, slowloris-*, slow-attack-*, timeout-*, oom-*)" >&2
  echo "may contain attacker-supplied bytes. Re-run with --publication-mode internal-only." >&2
  exit 1
fi

CONFIDENTIALITY_STATUS="public-safe-no-raw-jfr"
JFR_HANDLING="raw-jfr-blocked"
if [[ "$PUBLICATION_MODE" == "internal-only" ]]; then
  CONFIDENTIALITY_STATUS="internal-only-sensitive"
  JFR_HANDLING="raw-jfr-allowed"
elif [[ "$PUBLICATION_MODE" == "redacted" ]]; then
  CONFIDENTIALITY_STATUS="public-redacted"
  JFR_HANDLING="redacted-artifacts-only"
fi

if [[ ${#DESTRUCTIVE_ARTIFACTS[@]} -gt 0 && "$PUBLICATION_MODE" == "internal-only" ]]; then
  CONFIDENTIALITY_STATUS="destructive-internal-only"
fi

mkdir -p "$OUTPUT_DIR"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$OUTPUT_DIR/report-${TIMESTAMP}.md"

# Extract classification labels from result JSON.
TIER="$(jq -r '.target.tier // "N/A"' "$RESULT_FILE" 2>/dev/null || echo 'N/A')"
PROTOCOL="$(jq -r '.target.mode // .protocol_mode // "N/A"' "$RESULT_FILE" 2>/dev/null || echo 'N/A')"
FAMILY="$(jq -r '.benchmark_family // "N/A"' "$RESULT_FILE" 2>/dev/null || echo 'N/A')"
COMP_AXIS="$(jq -r '.comparison_axis // "N/A"' "$RESULT_FILE" 2>/dev/null || echo 'N/A')"
EXEC_CLASS="$(jq -r '.execution_class // "N/A"' "$RESULT_FILE" 2>/dev/null || echo 'N/A')"
CLAIM_SCOPE="$(jq -r '.claim_scope // "N/A"' "$RESULT_FILE" 2>/dev/null || echo 'N/A')"

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
  echo "| publication_mode | $PUBLICATION_MODE |"
  echo "| confidentiality_status | $CONFIDENTIALITY_STATUS |"
  echo "| jfr_handling | $JFR_HANDLING |"
  echo ""

  echo "## Classification"
  echo ""
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| tier | $TIER |"
  echo "| protocol | $PROTOCOL |"
  echo "| family | $FAMILY |"
  echo "| comparison_axis | $COMP_AXIS |"
  echo "| execution_class | $EXEC_CLASS |"
  echo "| claim_scope | $CLAIM_SCOPE |"
  echo ""
  if [[ "$CLAIM_SCOPE" != "comparison_eligible" ]]; then
    echo "> **CAVEAT: claim_scope is not comparison_eligible ($CLAIM_SCOPE).**"
    echo "> Comparative performance claims are DISALLOWED for this result."
    echo "> Use non-comparative (descriptive or regression-only) language."
    echo ""
  fi

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
    (.metrics // {}) |
    to_entries[] |
    select(.value != null) |
    "| \(.key) | \(.value) |"
  ' "$RESULT_FILE"

} > "$REPORT"

echo "Report written to: $REPORT"
echo "Publication mode: $PUBLICATION_MODE"
echo "Confidentiality status: $CONFIDENTIALITY_STATUS"

if [[ -n "$ARCHIVE_DIR" ]]; then
  mkdir -p "$ARCHIVE_DIR"
  REPO_SHA="$(jq -r '.target.commit_sha // "unknown"' "$RESULT_FILE" | cut -c1-7)"
  ARCHIVE_NAME="${TIMESTAMP}-${REPO_SHA}.json"
  cp "$RESULT_FILE" "$ARCHIVE_DIR/$ARCHIVE_NAME"
  echo "Result archived to: $ARCHIVE_DIR/$ARCHIVE_NAME"

  if [[ ${#JFR_ARTIFACTS[@]} -gt 0 ]]; then
    JFR_ARCHIVE_DIR="$ARCHIVE_DIR/jfr"
    mkdir -p "$JFR_ARCHIVE_DIR"
    for artifact in "${JFR_ARTIFACTS[@]}"; do
      cp "$artifact" "$JFR_ARCHIVE_DIR/${TIMESTAMP}-$(basename "$artifact")"
    done
    echo "JFR artifacts archived to: $JFR_ARCHIVE_DIR"
  fi
fi
