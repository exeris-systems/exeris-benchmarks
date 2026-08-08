#!/usr/bin/env bash
#
# aggregate-db-cpuset-mpstat.sh — derive a committable aggregate from the DB-cpuset
# mpstat stream, then let .gitignore drop the stream.
#
# WHY THIS EXISTS
#
# results/**/db-cpuset-mpstat.csv is git-ignored for size (~450 KB per arm-window,
# ~50 MB per campaign). That rule was written while the DB was still UNPINNED, when
# the stream genuinely carried no attributable signal — an all-core capture filed
# under a db-cpuset name. Once the DB gained its own cpuset the same stream became
# the evidence for the single most consequential finding a DB-bound contract can
# produce: whether the measured arms were racing each other or queueing behind a
# saturated Postgres. Dropping it now would leave that claim uncited.
#
# The sidecar db-cpuset-mpstat.meta.json records only WHETHER the window was
# attributable, never the utilisation it observed. So this tool derives the numbers
# and writes db-cpuset-metrics.json next to the stream. Same contract as every other
# sampler in this repo: raw stream out of git, aggregate in.
#
# READ THE OUTPUT AS A CEILING TEST, NOT AS A TARGET METRIC
#
# This is the DB's CPU, not the measured target's. It cannot be attributed to either
# arm of a pair — Postgres serves both, and on this box the cpuset is shared by every
# backend. Its only sound use is to answer "was there headroom?":
#
#   busy_pct_mean near 100  -> the arms were bounded by Postgres, and any throughput
#                              ratio between them reads the DB ceiling, not the stack.
#                              Report cpu/req instead; it survives a shared ceiling.
#   busy_pct_mean well down -> the contract left DB headroom and throughput ratios
#                              are about the arms.
#
# steal_pct is broken out deliberately: a non-zero value means the hypervisor took
# time from the DB cpuset, which invalidates the ceiling reading rather than
# supporting it.
#
# THE LOAD GENERATOR IS THE SAME PROBLEM, WITH THE OPPOSITE VERDICT
#
# --role loadgen aggregates loadgen-cpuset-mpstat.csv, which the runner started sampling on
# 2026-08-07. It is the same measurement and the same size problem, but it is read the other
# way round. A saturated DB bounds the result and must be declared; a saturated LOAD GENERATOR
# INVALIDATES it — at that point the number describes how fast wrk can offer requests, not how
# fast the server can serve them, and no amount of care elsewhere rescues it. It is the last
# ceiling in the rig that was never sampled, so until 2026-08-07 nothing could rule it out.
#
# USAGE
#   tools/aggregate-db-cpuset-mpstat.sh <stream.csv> [output.json]
#   tools/aggregate-db-cpuset-mpstat.sh --walk <dir> [--role db|loadgen]
#
# Idempotent: re-running overwrites the aggregate from the stream it is given.

set -euo pipefail

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

aggregate_one() {
  local csv="$1"
  local out="${2:-${csv%.csv}-metrics.json}"
  local meta="${csv%.csv}.meta.json"

  if [[ ! -r "$csv" ]]; then
    echo "ERROR: cannot read $csv" >&2
    return 1
  fi

  # Meta is advisory: the aggregate is still correct without it, but provenance
  # (which cpuset, was it attributable) travels with the numbers when present.
  local meta_json='null'
  if [[ -r "$meta" ]]; then
    meta_json="$(cat "$meta")"
  fi

  local role="db"; [[ "$(basename "$csv")" == loadgen-* ]] && role="loadgen"

  LC_ALL=C awk -F, -v meta="$meta_json" -v src="$(basename "$csv")" -v role="$role" '
    NR == 1 {
      # Resolve columns by NAME. mpstat field order has changed across sysstat
      # releases (%gnice is recent); a fixed index would silently read the wrong
      # column on a box with a different sysstat and produce plausible garbage.
      for (i = 1; i <= NF; i++) {
        h = $i; gsub(/^[ \t]+|[ \t]+$/, "", h)
        col[h] = i
      }
      if (!("%idle" in col)) { print "ERROR: no %idle column in header" > "/dev/stderr"; exit 2 }
      next
    }
    NF < 3 { next }
    {
      ts = $1; cpu = $2
      idle = $(col["%idle"]) + 0
      busy = 100 - idle

      # Per-timestamp mean across the cpuset: the utilisation of the DB as a unit.
      # Summing per-CPU rows without dividing would report 800% on an 8-CPU set.
      ts_sum[ts] += busy; ts_n[ts]++

      percpu_sum[cpu] += busy; percpu_n[cpu]++
      if (!(cpu in seen_cpu)) { seen_cpu[cpu] = 1; cpu_order[++ncpu] = cpu }

      for (k in col) {
        if (k ~ /^%/ && k != "%idle") { comp_sum[k] += $(col[k]) + 0 }
      }
      rows++
    }
    END {
      if (rows == 0) { print "ERROR: no data rows" > "/dev/stderr"; exit 3 }

      n = 0
      for (t in ts_sum) { v[++n] = ts_sum[t] / ts_n[t]; sum += v[n] }
      # Insertion sort: n is the sample count (~900), and awk has no sort().
      for (i = 2; i <= n; i++) { x = v[i]; j = i - 1; while (j > 0 && v[j] > x) { v[j+1] = v[j]; j-- } v[j+1] = x }

      mean = sum / n
      i50 = int(n * 0.50); if (i50 < 1) i50 = 1
      i95 = int(n * 0.95); if (i95 < 1) i95 = 1
      p50 = v[i50]
      p95 = v[i95]

      printf "{\n"
      printf "  \"source_stream\": \"%s\",\n", src
      printf "  \"samples\": %d,\n", n
      printf "  \"cpus_in_set\": %d,\n", ncpu
      printf "  \"busy_pct_mean\": %.2f,\n", mean
      printf "  \"busy_pct_min\": %.2f,\n", v[1]
      printf "  \"busy_pct_p50\": %.2f,\n", p50
      printf "  \"busy_pct_p95\": %.2f,\n", p95
      printf "  \"busy_pct_max\": %.2f,\n", v[n]

      printf "  \"component_pct_mean\": {\n"
      first = 1
      split("%usr %sys %iowait %soft %irq %steal %nice %guest %gnice", want, " ")
      for (wi = 1; wi <= 9; wi++) {
        k = want[wi]
        if (!(k in comp_sum)) continue
        if (!first) printf ",\n"
        # comp_sum accumulates one addend per CPU-row, so dividing by the row count
        # yields the per-CPU mean — directly comparable to per_cpu_busy_pct_mean.
        printf "    \"%s\": %.2f", substr(k, 2), comp_sum[k] / rows
        first = 0
      }
      printf "\n  },\n"

      printf "  \"per_cpu_busy_pct_mean\": {\n"
      for (i = 1; i <= ncpu; i++) {
        c = cpu_order[i]
        printf "    \"%s\": %.2f%s\n", c, percpu_sum[c] / percpu_n[c], (i < ncpu ? "," : "")
      }
      printf "  },\n"

      # Not a verdict, a reading. The threshold is stated so a reader can disagree
      # with it without having to re-derive the number.
      printf "  \"role\": \"%s\",\n", role
      if (role == "loadgen") {
        printf "  \"ceiling_reading\": \"%s\",\n", (mean >= 95 ? "loadgen_saturated_RESULT_INVALID" : (mean >= 80 ? "loadgen_near_saturation" : "loadgen_headroom_available"))
        printf "  \"ceiling_reading_threshold_note\": \"loadgen_saturated at busy_pct_mean >= 95, near_saturation >= 80. A saturated load generator does NOT bound the result, it INVALIDATES it: the measurement then describes how fast the driver can offer requests, not how fast the target can serve them. Unlike the DB ceiling, no comparator survives this — discard the leaf.\",\n"
      } else {
        printf "  \"ceiling_reading\": \"%s\",\n", (mean >= 95 ? "db_saturated" : (mean >= 80 ? "db_near_saturation" : "db_headroom_available"))
        printf "  \"ceiling_reading_threshold_note\": \"db_saturated at busy_pct_mean >= 95, db_near_saturation >= 80. When saturated, throughput ratios between arms read the Postgres ceiling and cpu/req is the sound comparator.\",\n"
      }
      printf "  \"sampler_meta\": %s\n", meta
      printf "}\n"
    }
  ' "$csv" > "$out.tmp"

  mv "$out.tmp" "$out"
  echo "$out"
}

main() {
  [[ $# -eq 0 ]] && usage 1

  if [[ "$1" == "--walk" ]]; then
    [[ $# -lt 2 ]] && usage 1
    local root="$2" count=0 failed=0
    local stream_name="${3:-db-cpuset-mpstat.csv}"
    while IFS= read -r -d '' csv; do
      if aggregate_one "$csv" >/dev/null; then
        count=$((count + 1))
      else
        failed=$((failed + 1))
        echo "WARN: failed on $csv" >&2
      fi
    done < <(find "$root" -type f -name "$stream_name" -print0 | sort -z)
    echo "aggregated=$count failed=$failed"
    [[ $failed -eq 0 ]]
    return
  fi

  [[ "$1" == "-h" || "$1" == "--help" ]] && usage 0
  aggregate_one "$@"
}

main "$@"
