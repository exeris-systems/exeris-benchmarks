#!/usr/bin/env bash
# 3-way matched-heap footprint decomposition — non-heap CATEGORY breakdown.
#
# Second-pass analysis over the captures already preserved in this campaign directory by
# foot-3way-analyze.sh. Unlike that script, this one reads NOTHING from /tmp: it runs
# against the committed `footprint-nmt-detail-*.txt.gz` files, so every number in the
# report is reproducible from a fresh clone with no re-measurement.
#
#   ./nonheap-breakdown-analyze.sh            # from the repo root or from this directory
#
# What it answers: the heap/non-heap split (decomposition-runs.tsv) says WHERE the
# matched-heap RSS difference lives; this says WHAT the non-heap part is made of.
#
# UNIT DISCIPLINE — the two artifacts measure different quantities and must not be summed:
#   decomposition-runs.tsv   RESIDENT kB (smaps Rss: pages actually in RAM)
#   nonheap-categories.tsv   COMMITTED kB (NMT accounting: pages the JVM asked for)
# NMT exposes no per-category residency, so a category's committed size is an UPPER BOUND
# on its resident size. Two coverage columns carry that gap explicitly:
#   nmt_coverage_of_res    NMT non-heap committed / non-heap Rss
#   nmt_coverage_of_anon   NMT non-heap committed / non-heap ANONYMOUS Rss   <- the fair one
# The anonymous denominator is the fair one: NMT tracks anonymous and malloc-backed memory
# only, so JVM/libc text, the CDS archive and mapped jars are resident but outside its
# accounting by construction. Both are reported so the reader can see which is quoted.
#
# The anonymous split needs per-mapping smaps attributed against the NMT heap range, which
# is exactly what tools/extract-footprint-decomposition.sh already does, so this script
# re-runs that tool rather than duplicating the range logic. Output goes to a NEW file
# (footprint-anon-split.json) instead of overwriting the published footprint-decomposition.json,
# which keeps the first-pass artifacts and their on-box provenance paths intact — and turns
# the re-run into a reproducibility check: the script asserts the two agree field-for-field
# on heap / non-heap / total Rss and fails the cell loudly if they ever diverge.
#
# Medians are per-metric across repeats — the same convention as §5 of the triad report,
# so a median row is not necessarily any single observed repeat.

set -uo pipefail

# MANDATORY, not hygiene: mawk 1.3.4 honours the locale's decimal separator, so under a
# comma-decimal locale (pl_PL, de_DE, ...) `"0.61" + 0` silently evaluates to 0 — the
# coverage column came out as a column of zeros before this line existed. jq always emits
# a '.' decimal point, so every awk consumer of jq output must be pinned to C.
export LC_ALL=C

_ABS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$_ABS_SCRIPT_DIR/../../.." && pwd)"

# Run from the repo root and address everything RELATIVELY from here on. Not cosmetic: the
# extractors stamp their input paths into `provenance` and echo them to the .err logs, so
# absolute paths would bake one machine's home directory into committed artifacts and make
# a clone elsewhere produce a different file for identical inputs.
cd "$REPO_ROOT" || exit 1
SCRIPT_DIR="${_ABS_SCRIPT_DIR#"$REPO_ROOT"/}"

EXTRACTOR="tools/extract-nmt-category-breakdown.sh"
DECOMPOSER="tools/extract-footprint-decomposition.sh"

for T in "$EXTRACTOR" "$DECOMPOSER"; do
  [ -f "$T" ] || { echo "ERROR: tool not found: $T" >&2; exit 1; }
done

REPEATS="${REPEATS:-1 2 3}"
CELLS="${CELLS:-light-community light-qtuned light-qhib heavy-community heavy-qtuned heavy-qhib}"

LONG="$SCRIPT_DIR/nonheap-categories.tsv"
MEDIANS="$SCRIPT_DIR/nonheap-categories-medians.tsv"

COLS='nonheap_committed_kb class_metadata_total_kb class_kb metaspace_kb shared_class_space_kb code_kb gc_kb thread_kb compiler_kb symbol_kb internal_kb other_kb nmt_instrument_kb nonheap_res_kb nonheap_anon_kb nonheap_file_kb loaded_classes platform_threads'

printf 'cell\trepeat\tstack\tcontract\t%s\tnmt_coverage_of_res\tnmt_coverage_of_anon\n' \
  "$(echo "$COLS" | tr ' ' '\t')" > "$LONG"

for R in $REPEATS; do
  for LABEL in $CELLS; do
    CELL_DIR="$SCRIPT_DIR/$LABEL/r${R}"
    NMT=$(find "$CELL_DIR" -name 'footprint-nmt-detail-*.txt.gz' 2>/dev/null | head -1)
    SMAPS=$(find "$CELL_DIR" -name 'footprint-smaps-*.txt.gz' 2>/dev/null | head -1)
    DECOMP="$CELL_DIR/footprint-decomposition.json"

    if [ -z "$NMT" ] || [ -z "$SMAPS" ]; then
      echo "SKIP $LABEL r$R: nmt=${NMT:-MISSING} smaps=${SMAPS:-MISSING} under $CELL_DIR" >&2
      continue
    fi

    OUT="$CELL_DIR/nmt-category-breakdown.json"
    if ! bash "$EXTRACTOR" "$NMT" "$OUT" 2>"$CELL_DIR/nmt-category-breakdown.err"; then
      echo "FAIL $LABEL r$R: category extractor errored — see $CELL_DIR/nmt-category-breakdown.err" >&2
      continue
    fi

    ANON="$CELL_DIR/footprint-anon-split.json"
    if ! bash "$DECOMPOSER" "$NMT" "$SMAPS" "$ANON" 2>"$CELL_DIR/footprint-anon-split.err"; then
      echo "FAIL $LABEL r$R: decomposer errored — see $CELL_DIR/footprint-anon-split.err" >&2
      continue
    fi

    # Reproducibility check, not decoration: the re-run must reproduce the first pass
    # exactly on every field they share. A mismatch means the captures or the tool moved
    # under us, and the cell is dropped rather than reported.
    if [ -f "$DECOMP" ]; then
      AGREE=$(jq -s '
        [ (.[0].heap.smaps_resident_kb     == .[1].heap.smaps_resident_kb),
          (.[0].non_heap.smaps_resident_kb == .[1].non_heap.smaps_resident_kb),
          (.[0].total.smaps_resident_kb    == .[1].total.smaps_resident_kb),
          (.[0].total.nmt_committed_kb     == .[1].total.nmt_committed_kb)
        ] | all' "$DECOMP" "$ANON")
      if [ "$AGREE" != "true" ]; then
        echo "FAIL $LABEL r$R: re-run disagrees with first-pass footprint-decomposition.json — refusing to report this cell" >&2
        continue
      fi
    else
      echo "WARN $LABEL r$R: no first-pass footprint-decomposition.json to cross-check against" >&2
    fi

    STACK="${LABEL#*-}"; CONTRACT="${LABEL%%-*}"
    jq -r --slurpfile anon "$ANON" \
          --arg cell "$LABEL" --arg rep "$R" --arg stack "$STACK" --arg contract "$CONTRACT" '
      .non_heap.rollups as $r |
      ($anon[0].non_heap.smaps_resident_kb)            as $res |
      ($anon[0].non_heap.smaps_anonymous_kb)           as $anonres |
      ($anon[0].non_heap.smaps_file_backed_resident_kb) as $file |
      [ $cell, $rep, $stack, $contract,
        .non_heap.nmt_committed_kb,
        $r.class_metadata_total_kb,
        $r.class_metadata_parts.class_kb,
        $r.class_metadata_parts.metaspace_kb,
        $r.class_metadata_parts.shared_class_space_kb,
        $r.code_kb, $r.gc_kb, $r.thread_kb, $r.compiler_kb,
        $r.symbol_kb, $r.internal_kb, $r.other_kb, $r.nmt_instrument_kb,
        $res, $anonres, $file,
        (.counters.loaded_classes // 0), (.counters.threads // 0),
        (if $res     > 0 then ((.non_heap.nmt_committed_kb / $res)     * 1000 | round / 1000) else null end),
        (if $anonres > 0 then ((.non_heap.nmt_committed_kb / $anonres) * 1000 | round / 1000) else null end)
      ] | @tsv' "$OUT" >> "$LONG"
  done
done

# --- Per-metric medians across repeats --------------------------------------------
awk -F'\t' '
  NR == 1 { for (i = 5; i <= NF; i++) hdr[i] = $i; nf = NF; next }
  { cells[$1] = $4 "\t" $3; for (i = 5; i <= nf; i++) { n[$1 SUBSEP i]++; v[$1 SUBSEP i SUBSEP n[$1 SUBSEP i]] = $i + 0 } }
  function median(cell, col,   k, cnt, arr, j, tmp, m) {
    cnt = n[cell SUBSEP col]
    if (cnt == 0) return ""
    for (j = 1; j <= cnt; j++) arr[j] = v[cell SUBSEP col SUBSEP j]
    for (j = 2; j <= cnt; j++) { tmp = arr[j]; k = j - 1; while (k >= 1 && arr[k] > tmp) { arr[k+1] = arr[k]; k-- } arr[k+1] = tmp }
    if (cnt % 2) m = arr[(cnt+1)/2]; else m = (arr[cnt/2] + arr[cnt/2+1]) / 2
    return m
  }
  END {
    printf "contract\tstack\tcell"
    for (i = 5; i <= nf; i++) printf "\t%s", hdr[i]
    printf "\n"
    split("light-community light-qtuned light-qhib heavy-community heavy-qtuned heavy-qhib", order, " ")
    for (o = 1; o <= 6; o++) {
      c = order[o]
      if (!(c in cells)) continue
      printf "%s\t%s", cells[c], c
      for (i = 5; i <= nf; i++) printf "\t%s", median(c, i)
      printf "\n"
    }
  }
' "$LONG" > "$MEDIANS"

echo
echo "=== NON-HEAP COMMITTED BY NMT CATEGORY — per-metric medians, n=3 (kB) ==="
echo "=== matched 256 MB heap; exploratory; COMMITTED not RESIDENT             ==="
column -t -s $'\t' "$MEDIANS"
echo
echo "Long format: $LONG  ($(( $(wc -l < "$LONG") - 1 )) rows)"
echo "Medians:     $MEDIANS"
