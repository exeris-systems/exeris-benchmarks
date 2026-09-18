#!/usr/bin/env bash
# Summarize a kernel-version-axis campaign: per-leg deltas, order balance, and eligibility.
#
# Reads only steps whose claim-status.json is comparison_eligible - a step that failed a precondition
# carries numbers that look fine and mean nothing, and run-comparative.sh can exit 0 on one.
#
# Three axes are reported, and on a DB-bound contract the last two are the ones that can answer a
# runtime question at all. Throughput is capped by whatever saturates first - when Postgres is the
# ceiling, every arm reports the database's number and the kernel is invisible. CPU per request is
# normalised by request, so it stays a property of the runtime even while throughput is externally
# pinned; RSS does not depend on throughput at all. A null on rps with a real delta on cpu/req is
# therefore not a contradiction - it is the expected shape of a DB-bound measurement.
#
# Every leg is reported with its A/B and B/A halves shown SEPARATELY as well as pooled. Order effect
# is not a footnote here: the two arms of a leg are measured one after the other on the same box, so
# a systematic drift between first-measured and second-measured shows up as a difference between the
# ab and ba deltas. If those two disagree in sign or differ by more than the effect being claimed,
# the pooled number is not a measurement of the kernel - it is a measurement of running order.
#
# Usage: scripts/summarize-kernel-version-axis.sh <campaign-dir> [--contract heavy|light]

set -euo pipefail

CAMPAIGN_DIR="${1:-}"
[[ -n "$CAMPAIGN_DIR" && -d "$CAMPAIGN_DIR" ]] || { echo "usage: $0 <campaign-dir> [--contract <key>]" >&2; exit 2; }
CONTRACT_FILTER=""
[[ "${2:-}" == "--contract" ]] && CONTRACT_FILTER="${3:-}"

python3 - "$CAMPAIGN_DIR" "$CONTRACT_FILTER" <<'PY'
import json, os, sys, glob, math, statistics as st

campaign, contract_filter = sys.argv[1], sys.argv[2]

manifest_path = os.path.join(campaign, "kernel-version-axis-arms.json")
legs_meta = {}
arm_of_target = {}
if os.path.exists(manifest_path):
    m = json.load(open(manifest_path))
    for leg in m["legs"]:
        legs_meta[leg["leg"]] = leg
    for a in m["arms"]:
        arm_of_target[a["target_id"]] = a

def slug(leg):
    return leg.replace(" ", "").replace(">", "_").replace("-", "_")

rows = {}          # (contract, leg_slug) -> list of dicts
skipped = []

for cs in glob.glob(os.path.join(campaign, "*", "*", "run*", "*", "claim-status.json")):
    d = os.path.dirname(cs)
    parts = d.split(os.sep)
    order, leg_slug, contract = parts[-1], parts[-3], parts[-4]
    if contract_filter and contract != contract_filter:
        continue
    status = json.load(open(cs))
    if status.get("claim_status") != "comparison_eligible":
        skipped.append((contract, leg_slug, parts[-2], order,
                        status.get("final_reason") or ",".join(status.get("rejection_codes", []))))
        continue
    res_path = os.path.join(d, "comparative-result.json")
    if not os.path.exists(res_path):
        continue
    res = json.load(open(res_path))
    entry = {"order": order}
    for t in res["targets"]:
        met = t.get("metrics", t)
        entry[t["target_id"]] = {
            "rps": met.get("throughput_rps"),
            "p50_us": met.get("latency_p50_us"),
            "p99_us": met.get("latency_p99_us"),
            "err_pct": met.get("error_rate_pct"),
            "cpu_us_per_req": None,
            "rss_mb": None,
        }
    # cpu/req and RSS live in each target's own result.json, not in the comparative roll-up.
    # target-a / target-b are POSITIONAL: in a ba step, target-a is the leg's second arm. Bind them
    # by the target_id the leaf itself records, never by directory name, or every ba row is swapped.
    for side in ("target-a", "target-b"):
        leaf = os.path.join(d, side, "result.json")
        if not os.path.exists(leaf):
            continue
        lj = json.load(open(leaf))
        tid = (lj.get("target", {}).get("repo")
               or os.path.basename(lj.get("env_ref", "")).replace(".env", ""))
        if tid not in entry:
            continue
        rm = lj.get("run_config", {}).get("resource_metrics", {})
        reqs = lj.get("metrics", {}).get("total_requests")
        cpu_s = rm.get("cpu_time_seconds")
        if cpu_s and reqs:
            entry[tid]["cpu_us_per_req"] = cpu_s / reqs * 1e6
        if rm.get("rss_kb_avg"):
            entry[tid]["rss_mb"] = rm["rss_kb_avg"] / 1024.0
    rows.setdefault((contract, leg_slug), []).append(entry)

def mean(xs):
    xs = [x for x in xs if x is not None]
    return st.mean(xs) if xs else None

def pct(a, b):
    """percent change from a to b"""
    if a in (None, 0) or b is None:
        return None
    return (b - a) / a * 100.0

leg_by_slug = {slug(k): k for k in legs_meta}
printed_any = False

for (contract, leg_slug) in sorted(rows):
    samples = rows[(contract, leg_slug)]
    leg_name = leg_by_slug.get(leg_slug, leg_slug)
    meta = legs_meta.get(leg_name, {})
    arm_a_name, _, arm_b_name = leg_name.partition("->")
    ta = next((a["target_id"] for a in arm_of_target.values() if a["arm"] == arm_a_name), None)
    tb = next((a["target_id"] for a in arm_of_target.values() if a["arm"] == arm_b_name), None)
    if not ta or not tb:
        continue

    printed_any = True
    print(f"\n=== [{contract}] {leg_name}   n={len(samples)} eligible step(s)")
    if meta:
        print(f"    isolates      : {meta['isolates']}")
        print(f"    held constant : {meta['held_constant']}")
    print(f"    A = {ta}")
    print(f"    B = {tb}")

    def half(order):
        s = [x for x in samples if x["order"] == order]
        return (mean([x[ta]["rps"] for x in s if ta in x]),
                mean([x[tb]["rps"] for x in s if tb in x]),
                len(s))

    ab_a, ab_b, n_ab = half("ab")
    ba_a, ba_b, n_ba = half("ba")
    all_a = mean([x[ta]["rps"] for x in samples if ta in x])
    all_b = mean([x[tb]["rps"] for x in samples if tb in x])

    print(f"    {'':<10} {'A rps':>12} {'B rps':>12} {'B vs A':>10}")
    for label, a, b, n in (("ab", ab_a, ab_b, n_ab), ("ba", ba_a, ba_b, n_ba), ("pooled", all_a, all_b, len(samples))):
        if a is None or b is None:
            print(f"    {label:<10} {'-':>12} {'-':>12} {'-':>10}   (n={n})")
            continue
        print(f"    {label:<10} {a:>12,.0f} {b:>12,.0f} {pct(a,b):>+9.2f}%   (n={n})")

    d_ab, d_ba = pct(ab_a, ab_b), pct(ba_a, ba_b)
    if d_ab is not None and d_ba is not None:
        spread = abs(d_ab - d_ba)
        pooled = pct(all_a, all_b)
        verdict = "consistent" if (d_ab > 0) == (d_ba > 0) else "SIGN FLIP between orders"
        print(f"    order effect  : ab {d_ab:+.2f}% vs ba {d_ba:+.2f}%  -> spread {spread:.2f} pp, {verdict}")
        if pooled is not None and spread > abs(pooled):
            print(f"    WARNING: the order spread ({spread:.2f} pp) exceeds the pooled effect "
                  f"({abs(pooled):.2f}%). This leg measures running order, not the kernel.")

    # dispersion across repeats, per arm - the thing that decides whether a small delta is real
    for tid, lbl in ((ta, "A"), (tb, "B")):
        vals = [x[tid]["rps"] for x in samples if tid in x and x[tid]["rps"] is not None]
        if len(vals) > 1:
            cv = st.pstdev(vals) / st.mean(vals) * 100
            print(f"    {lbl} spread     : min {min(vals):,.0f}  max {max(vals):,.0f}  CV {cv:.2f}%")

    for metric, label, unit, better in (("cpu_us_per_req", "CPU/req", "us", "lower"),
                                        ("rss_mb", "RSS", "MB", "lower")):
        va = [x[ta][metric] for x in samples if ta in x and x[ta].get(metric) is not None]
        vb = [x[tb][metric] for x in samples if tb in x and x[tb].get(metric) is not None]
        if not va or not vb:
            print(f"    {label:<13}: not captured in these leaves")
            continue
        ma, mb = st.mean(va), st.mean(vb)
        delta = pct(ma, mb)
        line = f"    {label:<13}: A {ma:>9,.1f} {unit}   B {mb:>9,.1f} {unit}   {delta:+.2f}%"
        # paired CI where both arms are present in the same step
        pairs = [x[tb][metric] - x[ta][metric] for x in samples
                 if ta in x and tb in x and x[ta].get(metric) is not None and x[tb].get(metric) is not None]
        if len(pairs) > 2:
            sd = st.stdev(pairs); se = sd / math.sqrt(len(pairs))
            tcrit = {3: 4.303, 4: 3.182, 5: 2.776, 6: 2.571}.get(len(pairs), 2.0)
            lo, hi = st.mean(pairs) - tcrit*se, st.mean(pairs) + tcrit*se
            zero = "crosses zero" if lo < 0 < hi else "EXCLUDES zero"
            line += f"   95% CI [{lo/ma*100:+.2f}%, {hi/ma*100:+.2f}%] {zero}"
        print(line)
        if len(va) > 1 and len(vb) > 1:
            print(f"    {'':<13}  CV: A {st.pstdev(va)/ma*100:.2f}%  B {st.pstdev(vb)/mb*100:.2f}%")

    errs = [x[t]["err_pct"] for x in samples for t in (ta, tb) if t in x and x[t]["err_pct"] is not None]
    if errs and max(errs) > 0:
        print(f"    NOTE: non-zero error rate observed, max {max(errs)}%")

if not printed_any:
    print("no eligible steps found yet")

if skipped:
    print(f"\n--- {len(skipped)} step(s) EXCLUDED as non-eligible ---")
    for s in skipped[:12]:
        print("   ", "/".join(s[:4]), "->", s[4])
PY
