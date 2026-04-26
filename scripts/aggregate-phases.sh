#!/usr/bin/env bash
# Exeris fairness header:
# - Keep tier, phase, and benchmark-family labels explicit.
# - Do not turn mixed-wiring or cross-tier summaries into relative performance claims.
# - Public artifacts must redact implementation-sensitive Enterprise fields; results (throughput, latency, JFR) are public.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RUN_DIR=""
OUTPUT_DIR=""
TITLE=""
PUBLICATION_MODE="public"
PHASES=(baseline profile gc)

declare -A BENCHMARK_NAME=(
  [B3]="JDK SSLEngine"
  [B4]="Netty TCNative"
  [B6]="Exeris Community"
  [B6b]="Exeris Community RoundTrip"
  [B7]="Exeris Enterprise"
  [B5]="Exeris OffHeapTlsEngine Memory-BIO Lens"
)

declare -A BENCHMARK_TIER=(
  [B3]="JDK"
  [B4]="JDK"
  [B6]="Community"
  [B6b]="Community"
  [B7]="Enterprise"
  [B5]="Enterprise"
)

declare -A BENCHMARK_ORDER=(
  [B3]=10
  [B4]=20
  [B6]=30
  [B6b]=35
  [B7]=40
  [B5]=45
)

usage() {
  cat <<'EOF'
Usage:
  ./scripts/aggregate-phases.sh --run-dir <dir> --output-dir <dir> [options]

Options:
  --run-dir <dir>                 Run directory containing baseline/profile/gc subdirs
  --output-dir <dir>              Output directory for aggregate Markdown and JSON
  --title <text>                  Optional report title override
  --publication-mode <mode>       public|internal-only (default: public)
  -h, --help                      Show this help
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

format_scalar() {
  local json_file="$1"
  local jq_expr="$2"
  jq -r "${jq_expr} | if . == null or . == \"\" then \"n/a\" else tostring end" "$json_file"
}

runner_status_for_file() {
  local json_file="$1"
  jq -r '
    .runner_status //
    (if .final_reason == "ok" then "success"
     elif .final_reason == "partial_json" then "partial"
     else "failed"
     end)
  ' "$json_file"
}

status_display_for_file() {
  local json_file="$1"
  local runner_status
  runner_status="$(runner_status_for_file "$json_file")"
  if [[ "$runner_status" == "success" ]]; then
    printf 'success'
  else
    printf 'INCOMPLETE'
  fi
}

canonical_dir() {
  local path="$1"
  (cd "$path" && pwd -P)
}

normalize_tier_label() {
  local raw_tier="$1"
  local tier_lc
  tier_lc="$(printf '%s' "$raw_tier" | tr '[:upper:]' '[:lower:]')"
  case "$tier_lc" in
    community) printf 'Community' ;;
    enterprise) printf 'Enterprise' ;;
    jdk) printf 'JDK' ;;
    ""|n/a|n-a|na|null|unknown) printf 'n/a' ;;
    *) printf '%s' "$raw_tier" ;;
  esac
}

resolve_benchmark_tier() {
  local benchmark_id="$1"
  local map_tier
  local file_path
  local file_tier

  map_tier="$(normalize_tier_label "${BENCHMARK_TIER[$benchmark_id]:-n/a}")"
  if [[ "$map_tier" != "n/a" ]]; then
    printf '%s' "$map_tier"
    return
  fi

  for phase in "${PHASES[@]}"; do
    file_path="${file_for_key[$benchmark_id:$phase]:-}"
    if [[ -z "$file_path" || ! -f "$file_path" ]]; then
      continue
    fi

    file_tier="$(jq -r '.target.tier // empty' "$file_path")"
    file_tier="$(normalize_tier_label "$file_tier")"
    if [[ "$file_tier" != "n/a" ]]; then
      printf '%s' "$file_tier"
      return
    fi
  done

  printf 'n/a'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir)
      RUN_DIR="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --title)
      TITLE="$2"
      shift 2
      ;;
    --publication-mode)
      PUBLICATION_MODE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$RUN_DIR" ]] || die "--run-dir is required"
[[ -d "$RUN_DIR" ]] || die "Run dir does not exist: $RUN_DIR"
[[ -n "$OUTPUT_DIR" ]] || die "--output-dir is required"

case "$PUBLICATION_MODE" in
  public|internal-only) ;;
  *) die "invalid --publication-mode '$PUBLICATION_MODE' (expected: public|internal-only)" ;;
esac

command -v jq >/dev/null 2>&1 || die "jq is required"

mkdir -p "$OUTPUT_DIR"

RUN_DIR="$(canonical_dir "$RUN_DIR")"
OUTPUT_DIR="$(canonical_dir "$OUTPUT_DIR")"

RUN_ID="$(basename "$RUN_DIR")"
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MARKDOWN_REPORT="$OUTPUT_DIR/aggregate-$RUN_ID.md"
JSON_REPORT="$OUTPUT_DIR/aggregate-$RUN_ID.json"

if [[ -z "$TITLE" ]]; then
  TITLE="Benchmark Aggregate Report"
fi

TMP_ALL_JSON="$(mktemp)"
TMP_VISIBLE_JSON="$(mktemp)"
TMP_ORDERED_IDS="$(mktemp)"
trap 'rm -f "$TMP_ALL_JSON" "$TMP_VISIBLE_JSON" "$TMP_ORDERED_IDS"' EXIT

declare -a normalized_files=()
declare -a available_phases=()
declare -A file_for_key=()
declare -A benchmark_seen=()

for phase in "${PHASES[@]}"; do
  phase_dir="$RUN_DIR/$phase"
  if [[ ! -d "$phase_dir" ]]; then
    continue
  fi

  available_phases+=("$phase")
  while IFS= read -r -d '' file_path; do
    normalized_files+=("$file_path")
    base_name="$(basename "$file_path")"
    if [[ "$base_name" =~ ^([^_]+)_([^_]+)-normalized\.json$ ]]; then
      benchmark_id="${BASH_REMATCH[1]}"
      benchmark_phase="${BASH_REMATCH[2]}"
      file_for_key["$benchmark_id:$benchmark_phase"]="$file_path"
      benchmark_seen["$benchmark_id"]=1
    fi
  done < <(find "$phase_dir" -maxdepth 1 -type f -name '*-normalized.json' -print0 | sort -z)
done

if [[ ${#normalized_files[@]} -eq 0 ]]; then
  die "No normalized JSON files found under $RUN_DIR"
fi

jq -s '.' "${normalized_files[@]}" > "$TMP_ALL_JSON"

case "$PUBLICATION_MODE" in
  public)
    jq 'map(
      if ((.target.tier // "") | ascii_downcase) == "enterprise" then
        .reproducibility_metadata.jvm_flags = ["[redacted-enterprise-impl]"] |
        .reproducibility_metadata.scenario_classification = "[redacted-enterprise-impl]" |
        .metrics.throughput_rps_by_case = (
          .metrics.throughput_rps_by_case // {} |
          with_entries(.key |= gsub("^[a-zA-Z0-9_.]+\\."; ""))
        ) |
        .metrics.latency_p50_us_by_case = (
          .metrics.latency_p50_us_by_case // {} |
          with_entries(.key |= gsub("^[a-zA-Z0-9_.]+\\."; ""))
        ) |
        .metrics.latency_p99_us_by_case = (
          .metrics.latency_p99_us_by_case // {} |
          with_entries(.key |= gsub("^[a-zA-Z0-9_.]+\\."; ""))
        ) |
        .metrics.latency_p999_us_by_case = (
          .metrics.latency_p999_us_by_case // {} |
          with_entries(.key |= gsub("^[a-zA-Z0-9_.]+\\."; ""))
        )
      else
        .
      end
    )' "$TMP_ALL_JSON" > "$TMP_VISIBLE_JSON"
    ;;
  internal-only)
    cp "$TMP_ALL_JSON" "$TMP_VISIBLE_JSON"
    ;;
esac

cp "$TMP_VISIBLE_JSON" "$JSON_REPORT"

ALL_COUNT="$(jq 'length' "$TMP_ALL_JSON")"
VISIBLE_COUNT="$(jq 'length' "$TMP_VISIBLE_JSON")"
SUPPRESSED_COUNT=$((ALL_COUNT - VISIBLE_COUNT))
COLLECTION_SCOPE="$(jq -r 'map(.jfr_metrics.collection_scope // empty) | unique | if length == 0 then "n/a" else join(" / ") end' "$TMP_VISIBLE_JSON")"
VISIBLE_TIER_COUNT="$(jq -r 'map((.target.tier // "unknown") | ascii_downcase) | unique | length' "$TMP_VISIBLE_JSON")"
CROSS_TIER_WARNING=""
if [[ "$VISIBLE_TIER_COUNT" -gt 1 ]]; then
  CROSS_TIER_WARNING="NOTE: Cross-tier comparison (JDK vs Community vs Enterprise) is included. Ensure wiring model, payload, and concurrency are equivalent before making relative performance claims."
fi

for benchmark_id in "${!benchmark_seen[@]}"; do
  printf '%s\t%s\n' "${BENCHMARK_ORDER[$benchmark_id]:-999}" "$benchmark_id"
done | sort -n -k1,1 -k2,2 | cut -f2 > "$TMP_ORDERED_IDS"

{
  echo "# $TITLE"
  echo "**Run dir**: $RUN_DIR"
  echo "**Generated**: $GENERATED_AT"
  echo "**Publication mode**: $PUBLICATION_MODE"
  echo ""

  echo "## Summary Table"
  echo "| ID | Tier | Phase | Status | exec_class | claim_scope | Throughput (ops/s) | p99 latency (µs) | CPU % max | RSS MB |"
  echo "|---|---|---|---|---|---|---|---|---|---|"

  while IFS= read -r benchmark_id; do
    benchmark_tier="$(resolve_benchmark_tier "$benchmark_id")"

    for phase in "${PHASES[@]}"; do
      file_path="${file_for_key[$benchmark_id:$phase]:-}"
      if [[ -z "$file_path" ]]; then
        echo "| $benchmark_id | $benchmark_tier | $phase | n/a | n/a | n/a | n/a | n/a | n/a | n/a |"
        continue
      fi

      exec_class="$(format_scalar "$file_path" '.execution_class')"
      claim_scope="$(format_scalar "$file_path" '.claim_scope')"
      throughput="$(format_scalar "$file_path" '.metrics.throughput_rps')"
      latency_p99="$(format_scalar "$file_path" '.metrics.latency_p99_us')"
      cpu_max="$(format_scalar "$file_path" '.jfr_metrics.cpu.cpu_percent_max // .jfr_metrics.cpu.jvm_user_percent_max')"
      rss_mb="$(format_scalar "$file_path" '.jfr_metrics.memory.max_rss_mb')"
      status_display="$(status_display_for_file "$file_path")"

      echo "| $benchmark_id | $benchmark_tier | $phase | $status_display | $exec_class | $claim_scope | $throughput | $latency_p99 | $cpu_max | $rss_mb |"
    done
  done < "$TMP_ORDERED_IDS"

  echo ""
  echo "## Per-Benchmark Details"

  while IFS= read -r benchmark_id; do
    benchmark_tier="$(resolve_benchmark_tier "$benchmark_id")"
    benchmark_name="${BENCHMARK_NAME[$benchmark_id]:-$benchmark_id}"

    for phase in "${PHASES[@]}"; do
      file_path="${file_for_key[$benchmark_id:$phase]:-}"
      if [[ -z "$file_path" ]]; then
        continue
      fi

      runner_status="$(runner_status_for_file "$file_path")"
      exec_class="$(format_scalar "$file_path" '.execution_class')"
      claim_scope="$(format_scalar "$file_path" '.claim_scope')"
      final_reason="$(format_scalar "$file_path" '.final_reason')"
      scenario="$(format_scalar "$file_path" '.scenario')"
      target_mode="$(format_scalar "$file_path" '.target.mode')"
      throughput="$(format_scalar "$file_path" '.metrics.throughput_rps')"
      latency_p99="$(format_scalar "$file_path" '.metrics.latency_p99_us')"
      cpu_max="$(format_scalar "$file_path" '.jfr_metrics.cpu.cpu_percent_max // .jfr_metrics.cpu.jvm_user_percent_max')"
      rss_mb="$(format_scalar "$file_path" '.jfr_metrics.memory.max_rss_mb')"
      collection_scope="$(format_scalar "$file_path" '.jfr_metrics.collection_scope')"
      warning_count="$(jq -r '(.jfr_metrics.warnings // []) | length' "$file_path")"

      echo "### $benchmark_id — $benchmark_name ($phase)"
      echo "- runner_status: $runner_status"
      echo "- execution_class: $exec_class"
      echo "- claim_scope: $claim_scope"
      echo "- final_reason: $final_reason"
      echo "- tier: $benchmark_tier"
      echo "- target_mode: $target_mode"
      echo "- scenario: $scenario"
      echo "- throughput_rps: $throughput"
      echo "- latency_p99_us: $latency_p99"
      echo "- cpu_percent_max: $cpu_max"
      echo "- max_rss_mb: $rss_mb"
      echo "- collection_scope: $collection_scope"
      echo "- jfr_warning_count: $warning_count"
      echo ""
    done
  done < "$TMP_ORDERED_IDS"

  echo "## Methodology Notes"
  echo "- Collection scope: $COLLECTION_SCOPE"
  if [[ ${#available_phases[@]} -gt 0 ]]; then
    printf '%s' '- Phases measured: '
    printf '%s' "${available_phases[0]}"
    for phase in "${available_phases[@]:1}"; do
      printf ', %s' "$phase"
    done
    printf '\n'
  else
    echo "- Phases measured: n/a"
  fi
  echo "- B4 uses EmbeddedChannel wiring (no real socket I/O)."
  echo "- B3, B6, and B7 use loopback socket paths; cross-tier conclusions must account for wiring model differences."
  echo "- B5 is an in-process Memory-BIO OffHeapTlsEngine lens and is not equivalent to B6 FD-owner integration path."
  if [[ -n "$CROSS_TIER_WARNING" ]]; then
    echo "- $CROSS_TIER_WARNING"
  fi
} > "$MARKDOWN_REPORT"

echo "Aggregate Markdown report written to: $MARKDOWN_REPORT"
echo "Aggregate JSON report written to: $JSON_REPORT"