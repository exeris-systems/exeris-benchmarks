#!/usr/bin/env bash
# 3-way matched-heap footprint decomposition — analysis side.
# Runs tools/extract-footprint-decomposition.sh over every cell of every repeat,
# collects the raw captures into this campaign directory, and emits a LONG-format TSV
# (one row per cell x repeat). Medians across repeats are computed downstream, not here
# — this script's job is extraction and preservation, not statistics.
#
# Reads nothing it did not measure: every number comes from smaps Rss per mapping
# joined against the NMT heap address range. No RSS-minus-Xmx arithmetic anywhere.

set -uo pipefail
cd /home/bench/exeris-benchmarks || exit 1

REPEATS="${REPEATS:-1 2 3}"
RUN_BASE=/tmp/foot3way
CAMPAIGN_DIR=results/raw/20260729-entity-read-by-id-3way-footprint-decomposition
EXTRACTOR=tools/extract-footprint-decomposition.sh

mkdir -p "$CAMPAIGN_DIR"
SUMMARY="$CAMPAIGN_DIR/decomposition-runs.tsv"
printf 'cell\trepeat\tstack\tcontract\trps\ttotal_rss_kb\theap_res_kb\theap_committed_kb\theap_residency\tnonheap_res_kb\tnonheap_net_of_nmt_kb\tnmt_cost_kb\n' > "$SUMMARY"

for R in $REPEATS; do
  for LABEL in light-community light-qtuned light-qhib heavy-community heavy-qtuned heavy-qhib; do
    OUT="$RUN_BASE/r${R}/${LABEL}-run"
    CELL_DIR="$CAMPAIGN_DIR/$LABEL/r${R}"

    [ -d "$OUT" ] || { echo "SKIP $LABEL r$R: no run dir ($OUT)"; continue; }
    mkdir -p "$CELL_DIR"

    SMAPS=$(find "$OUT" -name 'footprint-smaps-*.txt.gz' 2>/dev/null | head -1)
    NMT=$(find "$OUT" -name 'footprint-nmt-detail-*.txt' 2>/dev/null | head -1)
    RES=$(find "$OUT" -name result.json 2>/dev/null | head -1)
    RM=$(find "$OUT" -name resource-metrics.json 2>/dev/null | head -1)

    # Preserve the raw captures next to the derived numbers — smaps/NMT are plain text,
    # public-safe (no JFR), and they are the whole evidence base for the claim.
    [ -n "$SMAPS" ] && cp "$SMAPS" "$CELL_DIR/" 2>/dev/null
    [ -n "$NMT" ]   && gzip -c "$NMT" > "$CELL_DIR/$(basename "$NMT").gz" 2>/dev/null
    [ -n "$RES" ]   && cp "$RES" "$CELL_DIR/" 2>/dev/null
    [ -n "$RM" ]    && cp "$RM" "$CELL_DIR/" 2>/dev/null

    if [ -z "$SMAPS" ] || [ -z "$NMT" ]; then
      echo "SKIP $LABEL r$R: smaps=${SMAPS:-MISSING} nmt=${NMT:-MISSING}"
      continue
    fi

    D="$CELL_DIR/footprint-decomposition.json"
    if ! bash "$EXTRACTOR" "$NMT" "$SMAPS" "$D" 2>"$CELL_DIR/extract.err"; then
      echo "FAIL $LABEL r$R: extractor errored — see $CELL_DIR/extract.err"
      continue
    fi

    STACK="${LABEL#*-}"; CONTRACT="${LABEL%%-*}"
    RPS=$( [ -n "$RES" ] && jq -r '.metrics.throughput_rps // 0' "$RES" 2>/dev/null || echo 0 )
    jq -r --arg cell "$LABEL" --arg rep "$R" --arg stack "$STACK" --arg contract "$CONTRACT" --arg rps "$RPS" '
      [ $cell, $rep, $stack, $contract, $rps,
        (.total.smaps_resident_kb|tostring),
        (.heap.smaps_resident_kb|tostring),
        (.heap.nmt_committed_kb|tostring),
        ((.heap.residency_ratio*1000|round/1000)|tostring),
        (.non_heap.smaps_resident_kb|tostring),
        (.non_heap.smaps_resident_net_of_nmt_kb|tostring),
        (.non_heap.instrument_cost.nmt_tracking_committed_kb|tostring)
      ] | @tsv' "$D" >> "$SUMMARY"
  done
done

echo
echo "=== FOOTPRINT DECOMPOSITION — all repeats (matched 256 MB heap, exploratory) ==="
column -t -s $'\t' "$SUMMARY"
echo
echo "Rows: $(( $(wc -l < "$SUMMARY") - 1 )) (expect 6 cells x repeats)"
echo "Written to $SUMMARY"
