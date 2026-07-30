#!/usr/bin/env bash
# extract-nmt-category-breakdown.sh
# Break a JVM's NON-HEAP committed footprint down into NMT categories from a single
# `jcmd <pid> VM.native_memory {summary|detail} scale=KB` capture.
#
# WHY THIS EXISTS (2026-07-21 triad report, §5): the heap/non-heap split answers *where*
# the matched-heap RSS difference lives, but not *what* the non-heap part is made of.
# Companion to tools/extract-footprint-decomposition.sh:
#
#   extract-footprint-decomposition.sh  heap-resident vs non-heap-resident  (smaps x NMT)
#   extract-nmt-category-breakdown.sh   non-heap committed, by category      (NMT only)
#
# The two measure DIFFERENT quantities and must not be summed or equated:
#   - decomposition reports RESIDENT bytes (smaps Rss — pages actually in RAM)
#   - this tool reports COMMITTED bytes (NMT accounting — pages the JVM asked for)
# NMT has no per-category residency, so a category's committed size is an upper bound on
# its resident size. Report the coverage ratio (NMT non-heap committed / non-heap Rss)
# next to any category claim so the unexplained remainder stays visible.
#
# Two double-counting traps in NMT's own output, both avoided here by reading ONLY the
# top-level `-  <Category> (reserved=..., committed=...)` lines:
#   1. Under `Class`, NMT prints a nested `Metadata:` block whose committed size is ALSO
#      reported by the top-level `Metaspace` category. Summing both inflates class
#      metadata by ~2x.
#   2. `Class space:` under `Class` restates the same mmap already in `Class` committed.
# Class-metadata storage is therefore rolled up as Class + Metaspace + Shared class space,
# each of which is a top-level category. Verified: top-level categories sum to NMT's own
# `Total: committed=` within +/-1KB (rounding) on all 18 cells of the 20260729 campaign.

set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[extract-nmt-category-breakdown] $*" >&2; }

NMT_FILE="${1:?Usage: $0 <nmt-capture.txt[.gz]> [output-json]}"
OUTPUT_FILE="${2:-}"
# NMT omits categories under 1KB and rounds each line, so the category sum need not hit
# `Total:` exactly. Measured spread on the campaign is +/-1KB; 64KB leaves headroom
# without letting a genuinely truncated capture through.
CLOSURE_TOLERANCE_KB="${CLOSURE_TOLERANCE_KB:-64}"

[[ -f "$NMT_FILE" ]] || fail "NMT capture not found: $NMT_FILE"
command -v jq >/dev/null 2>&1 || fail "jq is required"

# Materialize once — same reasoning as extract-footprint-decomposition.sh: streaming a
# gzip into an early-exiting consumer under `set -o pipefail` is a SIGPIPE race, and
# re-decompressing per field is wasteful.
_NMT_TXT="$(mktemp)"
trap 'rm -f "$_NMT_TXT"' EXIT

case "$NMT_FILE" in
  *.gz) gzip -dc "$NMT_FILE" > "$_NMT_TXT" ;;
  *) cat "$NMT_FILE" > "$_NMT_TXT" ;;
esac

grep -qE '\(reserved=[0-9]+KB, committed=[0-9]+KB\)' "$_NMT_TXT" \
  || fail "capture is not in KB scale (expected 'jcmd ... VM.native_memory ... scale=KB'): $NMT_FILE"

# --- Parse top-level categories and the Total line --------------------------------
#
# Emits: first line "TOTAL <reserved> <committed>", then one "CAT <name>\t<res>\t<com>"
# per category. mawk-compatible: no 3-arg match(), no strtonum(), no gensub().
PARSED="$(awk '
  function field(s, key,   v) {
    if (match(s, key "=[0-9]+KB")) {
      v = substr(s, RSTART + length(key) + 1, RLENGTH - length(key) - 3)
      return v + 0
    }
    return -1
  }
  /^[[:space:]]*Total:[[:space:]]*reserved=[0-9]+KB/ {
    if (!seen_total) {
      printf "TOTAL\t%d\t%d\n", field($0, "reserved"), field($0, "committed")
      seen_total = 1
    }
    next
  }
  # Top-level category: "-                     Class (reserved=1049112KB, committed=2776KB)"
  /^-[[:space:]]+[^(]+\(reserved=[0-9]+KB, committed=[0-9]+KB/ {
    line = $0
    sub(/^-[[:space:]]+/, "", line)
    name = substr(line, 1, index(line, "(") - 1)
    sub(/[[:space:]]+$/, "", name)
    printf "CAT\t%s\t%d\t%d\n", name, field($0, "reserved"), field($0, "committed")
  }
' "$_NMT_TXT")"

[[ -n "$PARSED" ]] || fail "no NMT category lines parsed — is this a Native Memory Tracking capture? $NMT_FILE"

# NMT annotates two categories with counts: "(classes #4674)" under Class and
# "(threads #34)" under Thread. They turn a byte figure into a per-unit one — a class
# metadata delta means something different if it comes with 2x the classes than if the
# same classes cost more each. Absent counts are reported as null, never as 0.
_count() {
  awk -v key="$1" '
    $0 ~ "\\(" key " #[0-9]+\\)" {
      if (match($0, "\\(" key " #[0-9]+\\)")) {
        s = substr($0, RSTART, RLENGTH)
        sub("\\(" key " #", "", s); sub("\\)", "", s)
        print s + 0; exit
      }
    }' "$_NMT_TXT"
}
CLASS_COUNT="$(_count classes)"
THREAD_COUNT="$(_count threads)"
: "${CLASS_COUNT:=null}"
: "${THREAD_COUNT:=null}"

TOTAL_LINE="$(printf '%s\n' "$PARSED" | grep '^TOTAL' || true)"
[[ -n "$TOTAL_LINE" ]] || fail "no 'Total: reserved=...' line in capture: $NMT_FILE"
IFS=$'\t' read -r _ TOTAL_RESERVED_KB TOTAL_COMMITTED_KB <<<"$TOTAL_LINE"

CATEGORY_TSV="$(printf '%s\n' "$PARSED" | sed -n 's/^CAT\t//p')"
[[ -n "$CATEGORY_TSV" ]] || fail "Total line present but no category lines: $NMT_FILE"

# --- Fail closed on a capture whose categories do not add up ----------------------
SUM_COMMITTED_KB="$(printf '%s\n' "$CATEGORY_TSV" | awk -F'\t' '{s += $3} END {print s + 0}')"
CLOSURE_DELTA_KB=$(( SUM_COMMITTED_KB - TOTAL_COMMITTED_KB ))
CLOSURE_ABS=${CLOSURE_DELTA_KB#-}
if (( CLOSURE_ABS > CLOSURE_TOLERANCE_KB )); then
  fail "category committed sum ${SUM_COMMITTED_KB}kB does not close against NMT Total ${TOTAL_COMMITTED_KB}kB (delta ${CLOSURE_DELTA_KB}kB > ${CLOSURE_TOLERANCE_KB}kB tolerance) — capture is truncated or a category was double-counted: $NMT_FILE"
fi

# --- Shape into JSON --------------------------------------------------------------
#
# Category keys are snake_cased NMT names ("Shared class space" -> shared_class_space)
# so downstream jq paths are stable; `nmt_name` preserves the original spelling.
CATEGORIES_JSON="$(printf '%s\n' "$CATEGORY_TSV" | jq -R -s '
  split("\n") | map(select(length > 0) | split("\t")) |
  map({
    key: (.[0] | ascii_downcase | gsub("[^a-z0-9]+"; "_") | sub("^_"; "") | sub("_$"; "")),
    value: { nmt_name: .[0], reserved_kb: (.[1] | tonumber), committed_kb: (.[2] | tonumber) }
  }) | from_entries')"

HEAP_COMMITTED_KB="$(printf '%s' "$CATEGORIES_JSON" | jq -r '.java_heap.committed_kb // 0')"
NONHEAP_COMMITTED_KB=$(( TOTAL_COMMITTED_KB - HEAP_COMMITTED_KB ))

log "non-heap committed ${NONHEAP_COMMITTED_KB}kB across $(printf '%s\n' "$CATEGORY_TSV" | wc -l) categories (closure delta ${CLOSURE_DELTA_KB}kB)"

RESULT="$(jq -n \
  --argjson categories            "$CATEGORIES_JSON" \
  --argjson total_reserved_kb     "$TOTAL_RESERVED_KB" \
  --argjson total_committed_kb    "$TOTAL_COMMITTED_KB" \
  --argjson heap_committed_kb     "$HEAP_COMMITTED_KB" \
  --argjson nonheap_committed_kb  "$NONHEAP_COMMITTED_KB" \
  --argjson sum_committed_kb      "$SUM_COMMITTED_KB" \
  --argjson closure_delta_kb      "$CLOSURE_DELTA_KB" \
  --argjson closure_tolerance_kb  "$CLOSURE_TOLERANCE_KB" \
  --argjson class_count           "$CLASS_COUNT" \
  --argjson thread_count          "$THREAD_COUNT" \
  --arg     nmt_source            "$NMT_FILE" \
  '
  def com(k): ($categories[k].committed_kb // 0);
  {
    tool: "extract-nmt-category-breakdown",
    scale: "KB",
    measures: "committed",
    note: "NMT accounts COMMITTED bytes and has no per-category residency. A category committed size is an UPPER BOUND on its resident size; do not sum or equate these with the smaps Rss figures from extract-footprint-decomposition.sh.",
    total: {
      nmt_reserved_kb:  $total_reserved_kb,
      nmt_committed_kb: $total_committed_kb
    },
    java_heap: { nmt_committed_kb: $heap_committed_kb },
    non_heap: {
      nmt_committed_kb: $nonheap_committed_kb,
      rollups: {
        class_metadata_total_kb: (com("class") + com("metaspace") + com("shared_class_space")),
        class_metadata_parts: {
          class_kb:              com("class"),
          metaspace_kb:          com("metaspace"),
          shared_class_space_kb: com("shared_class_space"),
          note: "Class = class-space mmap + class-tagged malloc; Metaspace = non-class metadata; Shared class space = the CDS archive (largely file-backed and shareable, so it behaves differently from the other two under RSS accounting). Kept separate for that reason, and rolled up only for the all-class-metadata figure."
        },
        code_kb:            com("code"),
        gc_kb:              com("gc"),
        thread_kb:          com("thread"),
        compiler_kb:        com("compiler"),
        symbol_kb:          com("symbol"),
        internal_kb:        com("internal"),
        other_kb:           com("other"),
        nmt_instrument_kb:  com("native_memory_tracking")
      }
    },
    counters: {
      loaded_classes: $class_count,
      threads:        $thread_count,
      note: "Platform threads only. Virtual-thread stacks are heap-resident StackChunk objects, so they are counted in Java Heap, not in the Thread category — a Loom-first design MOVES stack memory into the heap term rather than removing it from the footprint."
    },
    categories: $categories,
    closure: {
      category_sum_committed_kb: $sum_committed_kb,
      nmt_total_committed_kb:    $total_committed_kb,
      delta_kb:                  $closure_delta_kb,
      tolerance_kb:              $closure_tolerance_kb,
      note: "Only top-level `-  <Category>` lines are summed. NMT nests a `Metadata:` block under Class that the top-level `Metaspace` category restates — counting both inflates class metadata about 2x. Fails closed when the sum misses NMT Total by more than the tolerance."
    },
    provenance: { nmt_source: $nmt_source }
  }')"

if [[ -n "$OUTPUT_FILE" ]]; then
  printf '%s\n' "$RESULT" > "$OUTPUT_FILE"
  log "wrote $OUTPUT_FILE"
else
  printf '%s\n' "$RESULT"
fi
