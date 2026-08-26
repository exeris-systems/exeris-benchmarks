#!/usr/bin/env bash
# Review a seeded baseline campaign and promote one leaf into baselines/.
#
# Promotion is deliberately a SEPARATE step from measurement. docs/regression-policy.md's one
# non-negotiable rule is that a baseline is never updated silently to hide a regression, and a
# script that measures and promotes in the same breath makes silent update the default behaviour.
# This one prints the spread, refuses to overwrite an existing baseline without a stated reason,
# and records that reason in the file it writes.
#
# It also refuses to promote a leaf whose fences are not RECORDED. That is the exact defect that
# left this repo without a usable baseline: the 2026-07-21 triad pinned the DB but did not write
# db_cpuset, so every later comparison against it degrades to FENCE-UNVERIFIED and cannot accept
# or reject a regression. A baseline that cannot be fence-checked is not a baseline.
#
# Usage: scripts/promote-kernel-baseline.sh <campaign-dir> [--replace "<reason>"] [--review-only]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CAMPAIGN="${1:-}"
[[ -n "$CAMPAIGN" && -d "$CAMPAIGN" ]] || { echo "usage: $0 <campaign-dir> [--replace \"<reason>\"] [--review-only]" >&2; exit 2; }
shift
REPLACE_REASON=""
REVIEW_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --replace)     REPLACE_REASON="$2"; shift 2 ;;
    --review-only) REVIEW_ONLY=1; shift ;;
    *) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
  esac
done

python3 - "$CAMPAIGN" "$REPLACE_REASON" "$REVIEW_ONLY" <<'PY'
import json, os, sys, glob, shutil, statistics as st

campaign, replace_reason, review_only = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
exit_code = 0

for contract_dir in sorted(glob.glob(os.path.join(campaign, "*"))):
    if not os.path.isdir(contract_dir):
        continue
    contract = os.path.basename(contract_dir)
    leaves = sorted(glob.glob(os.path.join(contract_dir, "run*", "result.json")))
    if not leaves:
        continue

    rows = []
    for f in leaves:
        j = json.load(open(f))
        md = j.get("run_config", {}).get("metadata", {})
        rows.append({
            "path": f,
            "rps": j["metrics"]["throughput_rps"],
            "p99": j["metrics"].get("latency_p99_us"),
            "net": md.get("backend_network_mode"),
            "cpuset": md.get("db_cpuset"),
            "scenario": md.get("scenario_id"),
            "hw": md.get("hardware_profile"),
        })

    print(f"\n=== {contract}  n={len(rows)}")

    # Fence recording is a precondition, not a warning.
    bad = [r for r in rows if r["net"] != "host" or not r["cpuset"]]
    if bad:
        print(f"    REFUSED: {len(bad)} of {len(rows)} leaves do not record both fences as required")
        for r in bad:
            print(f"      {r['path']}: backend_network_mode={r['net']!r} db_cpuset={r['cpuset']!r}")
        print("    A baseline that cannot be fence-checked degrades every future comparison to")
        print("    FENCE-UNVERIFIED, which must not be used to accept or reject a regression.")
        exit_code = 1
        continue

    vals = [r["rps"] for r in rows]
    lo, hi, mean = min(vals), max(vals), st.mean(vals)
    cv = (st.pstdev(vals) / mean * 100) if len(vals) > 1 else 0.0
    spread_pct = (hi - lo) / mean * 100 if mean else 0.0
    print(f"    rps    : mean {mean:,.0f}  min {lo:,.0f}  max {hi:,.0f}  CV {cv:.2f}%  spread {spread_pct:.2f}%")
    print(f"    fences : backend_network_mode=host  db_cpuset={rows[0]['cpuset']}")

    # The median leaf, not the best one. Picking the fastest leaf builds a baseline that every
    # later run regresses against by construction.
    ordered = sorted(rows, key=lambda r: r["rps"])
    chosen = ordered[len(ordered) // 2]
    print(f"    chosen : median leaf {chosen['path']}  ({chosen['rps']:,.0f} rps)")

    # The systematic slot effect on this box is 2.3-3.9% and does not shrink with repeats; the
    # warning line is -5%. Say so out loud when the observed spread is already eating that budget.
    if spread_pct > 2.3:
        print(f"    NOTE   : observed spread {spread_pct:.2f}% is inside the known 2.3-3.9% slot")
        print( "             effect, which is systematic. Read a later -5% against this spread.")

    identity = {}
    ident_file = os.path.join(os.path.dirname(chosen["path"]), "identity.txt")
    if os.path.exists(ident_file):
        identity["live_process_check"] = open(ident_file).read().strip().splitlines()

    dest_dir = os.path.join("baselines", "exeris-community", "pure-h1",
                            f"{chosen['scenario']}-{contract}")
    dest = os.path.join(dest_dir, f"{chosen['hw']}.json")
    prov = os.path.join(dest_dir, f"{chosen['hw']}.provenance.json")

    if os.path.exists(dest) and not replace_reason:
        print(f"    REFUSED: {dest} exists. Re-seeding a baseline needs --replace \"<reason>\";")
        print( "             see docs/regression-policy.md. Never replace one to mask a regression.")
        exit_code = 1
        continue

    if review_only:
        print(f"    review-only: would write {dest}")
        continue

    os.makedirs(dest_dir, exist_ok=True)
    shutil.copyfile(chosen["path"], dest)
    json.dump({
        "campaign": campaign,
        "contract": contract,
        "n": len(rows),
        "selection": "median leaf by throughput",
        "throughput_rps": {"mean": mean, "min": lo, "max": hi,
                           "cv_pct": cv, "spread_pct": spread_pct},
        "fences": {"backend_network_mode": "host", "db_cpuset": rows[0]["cpuset"]},
        "slot_effect_note": ("2.3-3.9% on perf-box-amd64, systematic - does not shrink with "
                             "repeats. Compare a later run against the recorded spread, not "
                             "against this single leaf alone."),
        "identity": identity,
        "replaced_reason": replace_reason or None,
    }, open(prov, "w"), indent=2)
    open(prov, "a").write("\n")
    print(f"    WROTE  : {dest}")
    print(f"    WROTE  : {prov}")

sys.exit(exit_code)
PY
