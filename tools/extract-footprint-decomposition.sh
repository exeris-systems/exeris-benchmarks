#!/usr/bin/env bash
# extract-footprint-decomposition.sh
# Decompose a JVM's resident footprint into HEAP-RESIDENT vs NON-HEAP-RESIDENT
# from two raw captures: `jcmd <pid> VM.native_memory detail` and /proc/<pid>/smaps.
#
# WHY THIS EXISTS (2026-07-21 triad report, §5): the report can state the matched-heap
# RSS *ratio* but not its *composition*, because you cannot derive a heap/non-heap split
# by subtracting the declared -Xmx from RSS. Without AlwaysPreTouch, -Xms COMMITS pages
# without TOUCHING them, so the resident heap is strictly smaller than the declared heap
# (measured: 262144KB committed vs 201512KB resident on a probe JVM). An earlier revision
# of §5 did exactly that subtraction and the row was withdrawn as invalid.
#
# The only sound method is per-region residency:
#   1. NMT `detail` prints a virtual memory map with the Java Heap ADDRESS RANGE.
#   2. /proc/<pid>/smaps prints Rss PER MAPPING.
#   3. Heap-resident = sum of Rss over mappings falling inside the NMT heap range.
#      Non-heap-resident = total Rss - heap-resident.
#
# Attribution is by RANGE CONTAINMENT, never exact match: NMT reports the reserved range
# (e.g. 0xf0000000-0x100000000) while smaps shows the actual committed mapping inside it
# (f0000000-ffe00000). An exact-match join silently yields zero.

set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[extract-footprint-decomposition] $*" >&2; }

NMT_FILE="${1:?Usage: $0 <nmt-detail.txt> <smaps.txt> [output-json]}"
SMAPS_FILE="${2:?Usage: $0 <nmt-detail.txt> <smaps.txt> [output-json]}"
OUTPUT_FILE="${3:-}"

[[ -f "$NMT_FILE" ]] || fail "NMT detail file not found: $NMT_FILE"
[[ -f "$SMAPS_FILE" ]] || fail "smaps file not found: $SMAPS_FILE"
command -v jq >/dev/null 2>&1 || fail "jq is required"

# Accept gzipped captures transparently — the sampler stores smaps gzipped (a JVM's
# smaps is ~1 MB of text, ~20 KB compressed).
#
# Materialize ONCE into a temp file instead of streaming per query. Two reasons, both
# learned the hard way:
#  1. `set -o pipefail` + `... | grep -q ...` is a RACE, not a stable pattern: grep -q
#     exits at the first match and closes the pipe, so the producer takes SIGPIPE (141)
#     and pipefail reports the whole pipeline as failed even though the match succeeded.
#     It passed on a small local capture and failed on a real 176 KB one — the match sits
#     on line 11 of ~2600, so the producer still had most of the file to write.
#  2. The previous form re-decompressed the input for every field extracted (6+ times).
_NMT_TXT="$(mktemp)"
_SMAPS_TXT="$(mktemp)"
trap 'rm -f "$_NMT_TXT" "$_SMAPS_TXT"' EXIT

_materialize() {
  case "$1" in
    *.gz) gzip -dc "$1" > "$2" ;;
    *) cat "$1" > "$2" ;;
  esac
}

_materialize "$NMT_FILE" "$_NMT_TXT" || fail "could not read NMT capture: $NMT_FILE"
_materialize "$SMAPS_FILE" "$_SMAPS_TXT" || fail "could not read smaps capture: $SMAPS_FILE"

# NMT is emitted with `scale=KB`; refuse anything else rather than silently mis-scaling.
if ! grep -qE '\(reserved=[0-9]+KB, committed=[0-9]+KB\)' "$_NMT_TXT"; then
  fail "NMT capture is not in KB scale (expected 'jcmd ... VM.native_memory detail scale=KB'): $NMT_FILE"
fi

# `sed ... | head -n 1` is the SAME SIGPIPE-under-pipefail trap as the guard above:
# head exits after one line and the producer dies on SIGPIPE, which pipefail then
# reports as failure. Every extraction below is "first match wins", so drop pipefail
# for this block rather than contort each expression. Restored immediately after.
set +o pipefail

# --- 1. Java Heap address ranges from the NMT virtual memory map -----------------
#
# Lines look like:
#   [0x00000000f0000000 - 0x0000000100000000] reserved and committed 262144KB for Java Heap from
HEAP_RANGES="$(sed -nE \
  's/^\[0x0*([0-9a-fA-F]+) - 0x0*([0-9a-fA-F]+)\].* for Java Heap( from)?.*$/\1 \2/p' "$_NMT_TXT")"

[[ -n "$HEAP_RANGES" ]] || fail "no 'for Java Heap' range in the NMT virtual memory map — was NMT run with 'detail' (not 'summary')? $NMT_FILE"

# --- 2. NMT committed totals (cross-check axis, independent of residency) ---------
NMT_TOTAL_COMMITTED_KB="$(sed -nE \
  's/^[[:space:]]*Total:[[:space:]]*reserved=[0-9]+KB, committed=([0-9]+)KB.*/\1/p' "$_NMT_TXT" | head -n 1)"
NMT_HEAP_RESERVED_KB="$(sed -nE \
  's/^[[:space:]]*-?[[:space:]]*Java Heap[[:space:]]*\(reserved=([0-9]+)KB, committed=[0-9]+KB\).*/\1/p' "$_NMT_TXT" | head -n 1)"
NMT_HEAP_COMMITTED_KB="$(sed -nE \
  's/^[[:space:]]*-?[[:space:]]*Java Heap[[:space:]]*\(reserved=[0-9]+KB, committed=([0-9]+)KB\).*/\1/p' "$_NMT_TXT" | head -n 1)"

# NMT `detail` is not free: it tracks per-callsite malloc data in NATIVE memory —
# i.e. it inflates the very non-heap footprint this tool measures. `summary` is not
# an option (the virtual memory map, and thus the heap address range, only appears
# under `detail`). So instead of pretending the instrument is weightless, read the
# cost it reports about itself and carry it, so the non-heap figure can be stated
# both as-measured and net-of-instrument. All arms must run the SAME NMT level for
# the comparison to hold; the netting matters for absolute levels, not for ratios.
NMT_TRACKING_OVERHEAD_KB="$(sed -nE \
  's/.*\(tracking overhead=([0-9]+)KB\).*/\1/p' "$_NMT_TXT" | head -n 1)"
NMT_TRACKING_COMMITTED_KB="$(sed -nE \
  's/^[[:space:]]*-?[[:space:]]*Native Memory Tracking[[:space:]]*\(reserved=[0-9]+KB, committed=([0-9]+)KB\).*/\1/p' "$_NMT_TXT" | head -n 1)"

set -o pipefail

: "${NMT_TOTAL_COMMITTED_KB:=0}"
: "${NMT_HEAP_RESERVED_KB:=0}"
: "${NMT_HEAP_COMMITTED_KB:=0}"
: "${NMT_TRACKING_OVERHEAD_KB:=0}"
: "${NMT_TRACKING_COMMITTED_KB:=0}"

# --- 3. Attribute smaps residency by range containment ----------------------------
#
# Portable hex conversion: mawk has no strtonum() (gawk-only), so convert by hand.
# Addresses are <= 48 bits, well inside awk's double-precision integer range.
DECOMP="$(awk -v ranges="$HEAP_RANGES" '
  function hex2dec(s,   i, c, d, n) {
    n = 0; s = tolower(s)
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      d = index("0123456789abcdef", c) - 1
      if (d < 0) continue
      n = n * 16 + d
    }
    return n
  }
  BEGIN {
    nr = split(ranges, lines, "\n")
    for (i = 1; i <= nr; i++) {
      if (lines[i] == "") continue
      split(lines[i], p, " ")
      rs[i] = hex2dec(p[1]); re[i] = hex2dec(p[2])
      nranges++
    }
  }
  # Mapping header: "f0000000-ffe00000 rw-p 00000000 00:00 0"
  /^[0-9a-fA-F]+-[0-9a-fA-F]+ / {
    split($1, a, "-")
    mstart = hex2dec(a[1]); mend = hex2dec(a[2])
    is_heap = 0
    for (i = 1; i <= nranges; i++) {
      # Containment, not equality: the committed mapping sits inside the reserved range.
      if (mstart >= rs[i] && mstart < re[i]) { is_heap = 1; break }
    }
    mappings++
    if (is_heap) heap_mappings++
    next
  }
  /^Rss:/ {
    total_rss += $2
    if (is_heap) heap_rss += $2
  }
  /^Size:/ {
    total_size += $2
    if (is_heap) heap_size += $2
  }
  END {
    printf "%d %d %d %d %d %d\n", \
      heap_rss + 0, total_rss + 0, heap_size + 0, total_size + 0, \
      heap_mappings + 0, mappings + 0
  }
' "$_SMAPS_TXT")"

read -r HEAP_RSS_KB TOTAL_RSS_KB HEAP_MAPPED_KB TOTAL_MAPPED_KB HEAP_MAPPINGS TOTAL_MAPPINGS <<<"$DECOMP"

[[ "${TOTAL_RSS_KB:-0}" -gt 0 ]] || fail "smaps capture yielded zero total Rss — malformed or empty: $SMAPS_FILE"
[[ "${HEAP_MAPPINGS:-0}" -gt 0 ]] || fail "no smaps mapping fell inside the NMT Java Heap range — captures are from different processes or different points in time"

NONHEAP_RSS_KB=$(( TOTAL_RSS_KB - HEAP_RSS_KB ))
COMMITTED_NOT_RESIDENT_KB=$(( NMT_HEAP_COMMITTED_KB - HEAP_RSS_KB ))
NONHEAP_NMT_COMMITTED_KB=$(( NMT_TOTAL_COMMITTED_KB - NMT_HEAP_COMMITTED_KB ))

log "heap resident ${HEAP_RSS_KB}kB / committed ${NMT_HEAP_COMMITTED_KB}kB; non-heap resident ${NONHEAP_RSS_KB}kB; total RSS ${TOTAL_RSS_KB}kB"

RESULT="$(jq -n \
  --argjson heap_smaps_resident_kb        "$HEAP_RSS_KB" \
  --argjson heap_smaps_mapped_kb          "$HEAP_MAPPED_KB" \
  --argjson heap_nmt_reserved_kb          "$NMT_HEAP_RESERVED_KB" \
  --argjson heap_nmt_committed_kb         "$NMT_HEAP_COMMITTED_KB" \
  --argjson heap_committed_not_resident_kb "$COMMITTED_NOT_RESIDENT_KB" \
  --argjson nonheap_smaps_resident_kb     "$NONHEAP_RSS_KB" \
  --argjson nonheap_nmt_committed_kb      "$NONHEAP_NMT_COMMITTED_KB" \
  --argjson total_smaps_resident_kb       "$TOTAL_RSS_KB" \
  --argjson total_smaps_mapped_kb         "$TOTAL_MAPPED_KB" \
  --argjson total_nmt_committed_kb        "$NMT_TOTAL_COMMITTED_KB" \
  --argjson nmt_tracking_overhead_kb      "$NMT_TRACKING_OVERHEAD_KB" \
  --argjson nmt_tracking_committed_kb     "$NMT_TRACKING_COMMITTED_KB" \
  --argjson heap_mappings                 "$HEAP_MAPPINGS" \
  --argjson total_mappings                "$TOTAL_MAPPINGS" \
  --arg     nmt_source                    "$NMT_FILE" \
  --arg     smaps_source                  "$SMAPS_FILE" \
  '{
    tool: "extract-footprint-decomposition",
    scale: "KB",
    heap: {
      smaps_resident_kb:         $heap_smaps_resident_kb,
      smaps_mapped_kb:           $heap_smaps_mapped_kb,
      nmt_reserved_kb:           $heap_nmt_reserved_kb,
      nmt_committed_kb:          $heap_nmt_committed_kb,
      committed_not_resident_kb: $heap_committed_not_resident_kb,
      residency_ratio: (if $heap_nmt_committed_kb > 0
                        then ($heap_smaps_resident_kb / $heap_nmt_committed_kb)
                        else null end)
    },
    non_heap: {
      smaps_resident_kb: $nonheap_smaps_resident_kb,
      nmt_committed_kb:  $nonheap_nmt_committed_kb,
      instrument_cost: {
        nmt_tracking_overhead_kb:  $nmt_tracking_overhead_kb,
        nmt_tracking_committed_kb: $nmt_tracking_committed_kb,
        note: "NMT `detail` stores per-callsite data in native memory, so it inflates non-heap. Reported so the figure can be stated net-of-instrument. Valid to compare across arms only when every arm ran the same NMT level."
      },
      smaps_resident_net_of_nmt_kb: ($nonheap_smaps_resident_kb - $nmt_tracking_committed_kb)
    },
    total: {
      smaps_resident_kb: $total_smaps_resident_kb,
      smaps_mapped_kb:   $total_smaps_mapped_kb,
      nmt_committed_kb:  $total_nmt_committed_kb
    },
    attribution: {
      method: "nmt_detail_heap_range_containment_over_smaps_rss",
      heap_mappings_matched: $heap_mappings,
      total_mappings:        $total_mappings,
      note: "Heap residency is measured, never derived by subtracting declared -Xmx from RSS: without AlwaysPreTouch, -Xms commits pages it never touches, so committed > resident. See triad report §5."
    },
    provenance: {
      nmt_source:   $nmt_source,
      smaps_source: $smaps_source
    }
  }')"

if [[ -n "$OUTPUT_FILE" ]]; then
  printf '%s\n' "$RESULT" > "$OUTPUT_FILE"
  log "wrote $OUTPUT_FILE"
else
  printf '%s\n' "$RESULT"
fi
