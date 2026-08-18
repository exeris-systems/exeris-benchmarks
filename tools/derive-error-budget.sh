#!/usr/bin/env bash
# derive-error-budget.sh -- re-derive the cpu/req error budget from committed artefacts.
#
# WHY THIS EXISTS
#
# A report may not carry an error budget that cannot be re-derived. The 2026-08-11 draft
# carried one whose rows had no citation: they had been computed in earlier work and quoted
# forward until nobody could say which campaign produced them. Quoting a tolerance you cannot
# reproduce is the same defect as quoting a result you cannot reproduce -- it just hides one
# level down, in the yardstick rather than in the measurement.
#
# So the budget is computed here, from artefacts in results/raw/entity-read-by-id/, and the
# report cites this script plus its output CSV rather than a remembered number.
#
# WHAT IT MEASURES
#
# Two variance LAYERS, deliberately kept apart (see the report's 2.1 -- a budget without a
# scope misleads in both directions):
#
#   arm-order   The SAME arm, SAME repeat, SAME JVM instances, measured in both directions of
#               a counterbalanced pair (ab vs ba). Isolates position-in-sequence. It does NOT
#               include restart variance -- both directions share one JVM lifetime, one warmup
#               and one JIT state. Using this alone UNDER-states uncertainty.
#
#   repeat      The SAME arm, SAME direction, across repeats -- i.e. varying only a full
#               teardown and relaunch. This is the layer that answers "would this difference
#               recur if I ran it again from scratch", and it is the one a claim of the form
#               "arm A costs more than arm B" has to clear.
#
# Both are reported per CONTRACT, because they are not contract-independent and collapsing
# them into one number is how the old +/-2.00 % row managed to over-state heavy by ~2x while
# simultaneously under-stating light.
#
# METRIC
#
#   cpu/req [ms] = resource-metrics.json .cpu_time_seconds / result.json .metrics.total_requests * 1000
#
# the same formula tools/aggregate-matrix.sh and the campaign runners use. cpu/req is the only
# metric in scope: the budget does not transfer to throughput (DB-ceiling bound on heavy) and
# emphatically not to percentiles -- see the report's 2 for the measured sensitivity gap.
#
# USAGE
#
#   tools/derive-error-budget.sh [--csv <path>] [--campaigns <dir>] [<campaign-id> ...]
#
# With no campaign ids, every *-n3 campaign under the campaigns dir is used.

set -uo pipefail
export LC_ALL=C

CAMPAIGN_ROOT="results/raw/entity-read-by-id"
CSV_OUT=""
CAMPAIGNS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --csv)       CSV_OUT="$2"; shift 2 ;;
    --campaigns) CAMPAIGN_ROOT="$2"; shift 2 ;;
    -h|--help)   sed -n '2,45p' "$0"; exit 0 ;;
    --*)         echo "ERROR: unknown option '$1'" >&2; exit 1 ;;
    *)           CAMPAIGNS+=("$1"); shift ;;
  esac
done

if [[ ! -d "$CAMPAIGN_ROOT" ]]; then
  echo "ERROR: campaign root not found: $CAMPAIGN_ROOT" >&2
  exit 1
fi

if [[ ${#CAMPAIGNS[@]} -eq 0 ]]; then
  while IFS= read -r d; do CAMPAIGNS+=("$(basename "$d")"); done \
    < <(find "$CAMPAIGN_ROOT" -maxdepth 1 -type d -name '*-n3' | sort)
fi

if [[ ${#CAMPAIGNS[@]} -eq 0 ]]; then
  echo "ERROR: no campaigns found under $CAMPAIGN_ROOT" >&2
  exit 1
fi

# cpu/req for one measured arm directory, or empty if the artefacts are not both present.
cpu_per_req() {
  local d="$1" c t
  [[ -f "$d/resource-metrics.json" && -f "$d/result.json" ]] || return 0
  c="$(jq -r '.cpu_time_seconds // empty' "$d/resource-metrics.json" 2>/dev/null)"
  t="$(jq -r '.metrics.total_requests // empty' "$d/result.json" 2>/dev/null)"
  [[ -n "$c" && -n "$t" ]] || return 0
  awk -v c="$c" -v t="$t" 'BEGIN{ if (t+0 > 0) printf "%.6f", c/t*1000 }'
}

# The single run directory of a (campaign, repeat, contract, pair) cell.
run_dir() {
  find "$1/$2/$3" -maxdepth 1 -type d -name 'run*' 2>/dev/null | sort | head -1
}

OBS="$(mktemp)"; trap 'rm -f "$OBS"' EXIT

for cid in "${CAMPAIGNS[@]}"; do
  root="$CAMPAIGN_ROOT/$cid"
  [[ -d "$root" ]] || { echo "WARN: skipping missing campaign $cid" >&2; continue; }

  for contract in heavy light; do
    # Pair names come from the first repeat that has this contract. Non-pair entries
    # (campaign-env.json, campaign.log, diagnostics/, ...) simply yield no artefacts.
    first_rep="$(find "$root" -maxdepth 1 -type d -name 'repeat*' | sort | head -1)"
    [[ -n "$first_rep" && -d "$first_rep/$contract" ]] || continue

    while IFS= read -r pair; do
      [[ -n "$pair" ]] || continue
      for dir in ab ba; do
        for arm in target-a target-b; do
          while IFS= read -r rep; do
            run="$(run_dir "$rep" "$contract" "$pair")"
            [[ -n "$run" ]] || continue
            v="$(cpu_per_req "$run/$dir/$arm")"
            [[ -n "$v" ]] || continue
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
              "$cid" "$contract" "$pair" "$(basename "$rep")" "$dir" "$arm" "$v" >> "$OBS"
          done < <(find "$root" -maxdepth 1 -type d -name 'repeat*' | sort)
        done
      done
    done < <(find "$first_rep/$contract" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort)
  done
done

if [[ ! -s "$OBS" ]]; then
  echo "ERROR: no cpu/req observations extracted -- check artefact layout under $CAMPAIGN_ROOT" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Layer 1: arm order. Pair each (campaign, contract, pair, repeat, arm) across ab/ba.
# Layer 2: repeat.    Group each (campaign, contract, pair, dir, arm) across repeats.
# Emitted as one long CSV so the report can cite rows, then summarised per contract.
# ---------------------------------------------------------------------------
DERIVED="$(mktemp)"; trap 'rm -f "$OBS" "$DERIVED"' EXIT

awk -F'\t' '
  { key = $1 SUBSEP $2 SUBSEP $3 SUBSEP $4 SUBSEP $6
    if ($5 == "ab") ab[key] = $7; else ba[key] = $7
    rkey = $1 SUBSEP $2 SUBSEP $3 SUBSEP $5 SUBSEP $6
    rn[rkey]++; rv[rkey, rn[rkey]] = $7
  }
  END {
    for (k in ab) {
      if (!(k in ba)) continue
      split(k, f, SUBSEP)
      d = (ba[k] - ab[k]) / ab[k] * 100
      printf "arm_order,%s,%s,%s,%s,%s,2,%.6f,%.4f\n", f[1], f[2], f[3], f[4], f[5], ab[k], (d<0?-d:d)
    }
    for (k in rn) {
      n = rn[k]; if (n < 3) continue
      split(k, f, SUBSEP)
      s = 0; for (i = 1; i <= n; i++) s += rv[k, i]
      m = s / n
      ss = 0; for (i = 1; i <= n; i++) ss += (rv[k, i] - m) ^ 2
      sd = sqrt(ss / (n - 1))
      printf "repeat,%s,%s,%s,%s,%s,%d,%.6f,%.4f\n", f[1], f[2], f[3], f[4], f[5], n, m, (m>0 ? sd/m*100 : 0)
    }
  }
' "$OBS" | sort -t, -k1,1 -k2,2 -k3,3 -k4,4 -k5,5 -k6,6 > "$DERIVED"

HEADER='layer,campaign,contract,pair,group,arm,n,mean_cpu_per_req_ms,spread_pct'

if [[ -n "$CSV_OUT" ]]; then
  mkdir -p "$(dirname "$CSV_OUT")"
  { echo "$HEADER"; cat "$DERIVED"; } > "$CSV_OUT"
  echo "wrote $CSV_OUT ($(wc -l < "$DERIVED") derived observations)"
fi

echo
echo "cpu/req error budget, derived from ${#CAMPAIGNS[@]} campaign(s) under $CAMPAIGN_ROOT"
echo "campaigns: ${CAMPAIGNS[*]}"
echo
printf '%-10s %-8s %5s %8s %8s %8s %8s\n' layer contract n mean median p95 max
for layer in arm_order repeat; do
  for contract in heavy light; do
    awk -F, -v l="$layer" -v c="$contract" '$1==l && $3==c {print $9}' "$DERIVED" \
      | sort -g \
      | awk -v l="$layer" -v c="$contract" '
          { v[NR] = $1 }
          END {
            if (NR > 0) {
              s = 0; for (i = 1; i <= NR; i++) s += v[i]
              printf "%-10s %-8s %5d %7.2f%% %7.2f%% %7.2f%% %7.2f%%\n", \
                l, c, NR, s/NR, v[int((NR+1)/2)], v[int(0.95*NR + 0.9999)], v[NR]
            }
          }'
  done
done
echo
echo "spread_pct is |ba-ab|/ab for arm_order and the coefficient of variation for repeat."
echo "Read p95 as the budget row; max is reported so a single excursion cannot hide."
