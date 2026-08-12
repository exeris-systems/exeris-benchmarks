#!/usr/bin/env bash
# extract-idle-coresidence.sh -- what each arm costs while launched but NOT driven.
#
# WHY THIS EXISTS
#
# CLAIMS L8 ("an idle Spring-on-Exeris process is ~18x less idle than Tomcat or the native
# runtime") came from the 2026-08-06 ladder, which ran the DB on Docker BRIDGE networking. Under
# bridge an unpinned docker-proxy can land on either cpuset, so a floating process could have sat
# next to one arm and been counted as its idle cost.
#
# The test that cleared docker-proxy for L9 does not transfer: it works by predicting FEWER CORES
# AT CONSTANT cpu/req, and an idle arm serves nothing, so there is no denominator -- stolen cycles
# would look exactly like signal.
#
# What does transfer: the co-resident sampler runs on every campaign, host-net ones included. So
# the question is answered by reading committed artefacts, not by a new run. That is what this
# script does.
#
# WHAT IT READS
#
#   <leaf>/neighbour-resource-metrics.json       avg_cores_used, rss_kb_avg, threads_avg
#   <leaf>/neighbour-resource-metrics.meta.json  role: resident-idle, measured_target_id
#
# The neighbour is the OTHER arm of the pair, so its identity is taken from the sibling leaf's
# result.json rather than from the port number, which is not uniformly recorded in env files.
#
# READING THE OUTPUT
#
# The finding is the ABSOLUTE figure, not the ratio. Measured 2026-08-11 over six campaigns and
# both network modes: the Spring-on-Exeris arms sit at 0.0267-0.0280 cores REGARDLESS of network
# mode (a 3 % spread), while the quiet arms range 0.0012-0.0078 depending on CAMPAIGN DESIGN (a
# 6.5x range). So the ratio inherits variability the finding does not have. Quote
# "~0.027 cores, ~0.68 % of a 4-core pin"; give a ratio only with the pair and campaign attached.
#
# USAGE
#   tools/extract-idle-coresidence.sh [--campaigns <dir>] [<campaign-id> ...]

set -uo pipefail
export LC_ALL=C

CAMPAIGN_ROOT="results/raw/entity-read-by-id"
CAMPAIGNS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --campaigns) CAMPAIGN_ROOT="$2"; shift 2 ;;
    -h|--help)   sed -n '2,36p' "$0"; exit 0 ;;
    --*)         echo "ERROR: unknown option '$1'" >&2; exit 1 ;;
    *)           CAMPAIGNS+=("$1"); shift ;;
  esac
done

if [[ ${#CAMPAIGNS[@]} -eq 0 ]]; then
  while IFS= read -r d; do CAMPAIGNS+=("$(basename "$d")"); done \
    < <(find "$CAMPAIGN_ROOT" -maxdepth 1 -mindepth 1 -type d | sort)
fi

OBS="$(mktemp)"; trap 'rm -f "$OBS"' EXIT

for c in "${CAMPAIGNS[@]}"; do
  root="$CAMPAIGN_ROOT/$c"
  [[ -d "$root" ]] || { echo "WARN: no such campaign $c" >&2; continue; }
  mode="$(find "$root" -name result.json -print -quit \
          | xargs -r jq -r '.run_config.metadata.backend_network_mode // "?"')"
  while IFS= read -r meta; do
    d="$(dirname "$meta")"; parent="$(dirname "$d")"; self="$(basename "$d")"
    other=$([[ "$self" == "target-a" ]] && echo target-b || echo target-a)
    [[ -f "$parent/$other/result.json" ]] || continue
    nid="$(jq -r '.run_config.target_contract.target_id // "?"' "$parent/$other/result.json")"
    jq -r --arg c "$c" --arg m "$mode" --arg nid "$nid" \
      '[$c, $m, $nid, (.avg_cores_used//empty), (.rss_kb_avg//empty), (.threads_avg//empty)] | @tsv' \
      "$d/neighbour-resource-metrics.json" 2>/dev/null
  done < <(find "$root" -name 'neighbour-resource-metrics.meta.json') >> "$OBS"
done

[[ -s "$OBS" ]] || { echo "ERROR: no idle windows found under $CAMPAIGN_ROOT" >&2; exit 1; }

echo
echo "Idle co-residence cost -- launched but not driven. $(wc -l < "$OBS") windows."
echo
printf '%-8s %-32s %5s %9s %10s %8s %6s\n' netmode "idle arm" n cores "% of 4-pin" "RSS MB" thr
awk -F'\t' '
  { k=$2 SUBSEP $3; n[k]++; s[k]+=$4; r[k]+=$5; t[k]+=$6
    if ($4>mx[k]) mx[k]=$4 }
  END { for (k in n) { split(k,f,SUBSEP)
          printf "%-8s %-32s %5d %9.4f %9.3f%% %8.0f %6.1f\n",
            f[1], f[2], n[k], s[k]/n[k], s[k]/n[k]/4*100, r[k]/n[k]/1024, t[k]/n[k] } }
' "$OBS" | sort
echo
echo "Per campaign (design sensitivity lives here, not in netmode):"
awk -F'\t' '{k=$1 SUBSEP $2 SUBSEP $3; n[k]++; s[k]+=$4}
  END { for (k in n) { split(k,f,SUBSEP)
          printf "  %-44s %-7s %-30s n=%-3d %.4f\n", substr(f[1],1,44), f[2], f[3], n[k], s[k]/n[k] } }
' "$OBS" | sort -k2,2 -k3,3
