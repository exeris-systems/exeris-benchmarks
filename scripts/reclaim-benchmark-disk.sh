#!/usr/bin/env bash
set -euo pipefail

# reclaim-benchmark-disk.sh
#
# Reclaims disk from raw benchmark by-products that are (a) untracked, (b) not cited by
# any published report, and (c) either superseded or reducible to an already-present
# derived artifact.
#
# SAFETY MODEL — read before running with --execute:
#
#   * DRY-RUN BY DEFAULT. Nothing is removed without --execute.
#   * Everything this script targets is .gitignore'd, so it is NOT in git and deletion is
#     PERMANENT. git cannot restore it. That is the whole risk; there is no undo.
#   * Tracked files are refused outright — if a candidate turns up in `git ls-files`, it is
#     skipped and reported, never deleted.
#   * Run ids cited by anything under results/reports/ or docs/ are protected. The citation
#     set is rebuilt from those trees on every invocation, so a newly-written report
#     automatically protects its own evidence.
#   * results/reports/, results/history/, baselines/ and schemas/ are never touched.
#
# Usage:
#   scripts/reclaim-benchmark-disk.sh                      # report only (default)
#   scripts/reclaim-benchmark-disk.sh --categories guided-jfr,k6-streams
#   scripts/reclaim-benchmark-disk.sh --execute            # actually delete
#   scripts/reclaim-benchmark-disk.sh --list guided-jfr    # print every candidate path
#
# Categories:
#   guided-jfr    uncited JFR under results/raw/guided — recordings capped at the old
#                 250 MB rotation ceiling, i.e. tail-only slices (triad bug 4)
#   k6-streams    results/**/tools/k6/stream.json — per-sample streams; the sibling
#                 summary.json keeps the aggregated metrics
#   h2load-logs   h2load-requests.log where a derived h2load-*.json sits beside it
#   stale-applogs 2026-03-31 target-runtime.log / target-app.log — uncited, superseded
#                 by the 2026-07 campaigns
#   crash-dumps   hs_err_pid* / replay_pid* at the repo root

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ALL_CATEGORIES="guided-jfr,k6-streams,h2load-logs,stale-applogs,crash-dumps"
CATEGORIES="$ALL_CATEGORIES"
EXECUTE=0
LIST_CATEGORY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --categories) CATEGORIES="$2"; shift 2 ;;
    --execute)    EXECUTE=1; shift ;;
    --list)       LIST_CATEGORY="$2"; shift 2 ;;
    -h|--help)    sed -n '1,40p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown option '$1' (see --help)" >&2; exit 64 ;;
  esac
done

CYAN='\033[0;36m'; YEL='\033[1;33m'; RED='\033[0;31m'; GRN='\033[0;32m'; NC='\033[0m'
log()  { echo -e "${CYAN}[reclaim]${NC} $*"; }
warn() { echo -e "${YEL}[reclaim] WARN${NC} $*" >&2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- citation set: every run id referenced from a report or a doc ------------------
build_citation_set() {
  grep -rhoE '[0-9]{8}T[0-9]{6}Z|[0-9]{8}-[0-9]{6}' results/reports/ docs/ 2>/dev/null \
    | sort -u > "$WORK/cited.txt" || true
  log "Citation set: $(wc -l < "$WORK/cited.txt") run ids referenced by results/reports/ + docs/"
}

is_cited() {
  local path="$1" id
  while read -r id; do
    [[ -n "$id" && "$path" == *"$id"* ]] && return 0
  done < "$WORK/cited.txt"
  return 1
}

is_tracked() {
  git ls-files --error-unmatch "$1" >/dev/null 2>&1
}

# --- candidate producers -----------------------------------------------------------
# Each prints NUL-separated candidate paths. Filtering (citation / tracked) happens once,
# centrally, in collect() — so a new category cannot accidentally skip a safety check.

cand_guided_jfr()   { find results/raw/guided -type f -name '*.jfr' -print0 2>/dev/null; }

cand_k6_streams() {
  # Only where the aggregated summary.json survives alongside.
  find results -type f -path '*/tools/k6/stream.json' -print0 2>/dev/null \
    | while IFS= read -r -d '' p; do
        [[ -f "$(dirname "$p")/summary.json" ]] && printf '%s\0' "$p"
      done
}

cand_h2load_logs() {
  # Only where a derived h2load-*.json (percentiles) sits beside the raw request dump.
  find results -type f -name 'h2load-requests.log' -print0 2>/dev/null \
    | while IFS= read -r -d '' p; do
        if ls "$(dirname "$p")" 2>/dev/null | grep -qiE '^h2load-.*\.json$'; then
          printf '%s\0' "$p"
        fi
      done
}

cand_stale_applogs() {
  find results -type f -path '*20260331*' \
    \( -name 'target-runtime.log' -o -name 'target-app.log' \) -print0 2>/dev/null
}

cand_crash_dumps() {
  find . -maxdepth 1 -type f \( -name 'hs_err_pid*' -o -name 'replay_pid*' \) -print0 2>/dev/null
}

collect() {
  local cat="$1" out="$WORK/${cat}.list" skipped_cited=0 skipped_tracked=0
  : > "$out"
  local bytes=0 files=0 p

  while IFS= read -r -d '' p; do
    if is_tracked "$p"; then
      skipped_tracked=$((skipped_tracked + 1)); continue
    fi
    if is_cited "$p"; then
      skipped_cited=$((skipped_cited + 1)); continue
    fi
    printf '%s\n' "$p" >> "$out"
    bytes=$((bytes + $(stat -c%s "$p" 2>/dev/null || echo 0)))
    files=$((files + 1))
  done < <("cand_${cat//-/_}")

  echo "$bytes" > "$WORK/${cat}.bytes"
  echo "$files" > "$WORK/${cat}.files"
  echo "$skipped_cited" > "$WORK/${cat}.cited"
  echo "$skipped_tracked" > "$WORK/${cat}.tracked"
}

human_gb() { awk -v b="$1" 'BEGIN{printf "%.2f GB", b/1073741824}'; }

# --- main --------------------------------------------------------------------------
build_citation_set

log "Free before: $(df -h . | tail -1 | awk '{print $4}')"
echo

printf "%-16s %12s %8s %9s %9s\n" CATEGORY RECLAIMABLE FILES "KEPT:cit" "KEPT:git"
printf "%-16s %12s %8s %9s %9s\n" "----------------" "------------" "--------" "---------" "---------"

TOTAL_BYTES=0
for cat in ${CATEGORIES//,/ }; do
  case ",$ALL_CATEGORIES," in *",$cat,"*) ;; *) warn "unknown category '$cat' — skipped"; continue ;; esac
  collect "$cat"
  b="$(cat "$WORK/${cat}.bytes")"
  printf "%-16s %12s %8s %9s %9s\n" \
    "$cat" "$(human_gb "$b")" "$(cat "$WORK/${cat}.files")" \
    "$(cat "$WORK/${cat}.cited")" "$(cat "$WORK/${cat}.tracked")"
  TOTAL_BYTES=$((TOTAL_BYTES + b))
done

printf "%-16s %12s\n" "----------------" "------------"
printf "%-16s %12s\n" TOTAL "$(human_gb "$TOTAL_BYTES")"
echo

if [[ -n "$LIST_CATEGORY" ]]; then
  if [[ -f "$WORK/${LIST_CATEGORY}.list" ]]; then
    log "Candidates in '${LIST_CATEGORY}':"
    cat "$WORK/${LIST_CATEGORY}.list"
  else
    warn "category '${LIST_CATEGORY}' was not collected (not in --categories)"
  fi
  echo
fi

if (( EXECUTE == 0 )); then
  echo -e "${YEL}DRY RUN${NC} — nothing removed. Re-run with --execute to delete."
  echo "         Everything listed is untracked and .gitignore'd: deletion is PERMANENT."
  echo "         Inspect a category first with: $0 --list <category>"
  exit 0
fi

echo -e "${RED}EXECUTING${NC} — removing $(human_gb "$TOTAL_BYTES") of untracked raw by-products."
removed_bytes=0 removed_files=0
for cat in ${CATEGORIES//,/ }; do
  [[ -f "$WORK/${cat}.list" ]] || continue
  while IFS= read -r p; do
    [[ -f "$p" ]] || continue
    sz="$(stat -c%s "$p" 2>/dev/null || echo 0)"
    if rm -f -- "$p"; then
      removed_bytes=$((removed_bytes + sz)); removed_files=$((removed_files + 1))
    else
      warn "failed to remove $p"
    fi
  done < "$WORK/${cat}.list"
  log "  ${cat}: done"
done

echo
echo -e "${GRN}Removed${NC} ${removed_files} files, $(human_gb "$removed_bytes")"
log "Free after: $(df -h . | tail -1 | awk '{print $4}')"
log "Note: Docker is a separate pool — check 'docker system df' and prune deliberately."
