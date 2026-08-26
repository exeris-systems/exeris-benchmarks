import json, os, re, subprocess, sys, collections
JFR = "/opt/jdk28/bin/jfr"
C = sys.argv[1]

def acc(f, into):
    r = subprocess.run([JFR, "print", "--json", "--events", "jdk.ObjectAllocationSample", f],
                       capture_output=True, text=True)
    try:
        evs = json.loads(r.stdout)["recording"]["events"]
    except Exception:
        return 0.0
    tot = 0.0
    for e in evs:
        v = e["values"]
        oc = v.get("objectClass")
        name = oc.get("name") if isinstance(oc, dict) else (oc if isinstance(oc, str) else None)
        try:
            w = float(v.get("weight"))
        except (TypeError, ValueError):
            continue
        into[name or "<unknown>"] += w
        tot += w
    return tot

arms = collections.defaultdict(collections.Counter)
totals = collections.Counter()
files = collections.Counter()
for root, _, fs in os.walk(C):
    for fn in fs:
        m = re.match(r"target-(exeris-[a-z0-9-]+)-\d{8}-\d+\.jfr$", fn)
        if not m:
            continue
        arm = m.group(1)
        totals[arm] += acc(os.path.join(root, fn), arms[arm])
        files[arm] += 1

names = sorted(arms)
A = [n for n in names if "0111pv" not in n][0]
B = [n for n in names if "0111pv" in n][0]
print("A=%s (%d recordings)   B=%s (%d recordings)" % (A, files[A], B, files[B]))
print("est. total  A=%.0f MB   B=%.0f MB" % (totals[A]/1e6, totals[B]/1e6))
print()
print("%-52s %8s %8s %9s" % ("type", "A share", "B share", "B-A pp"))
union = set(arms[A]) | set(arms[B])
rows = []
for t in union:
    sa = 100*arms[A][t]/totals[A] if totals[A] else 0
    sb = 100*arms[B][t]/totals[B] if totals[B] else 0
    rows.append((max(sa, sb), t, sa, sb))
rows.sort(reverse=True)
for _, t, sa, sb in rows[:18]:
    print("%-52s %7.2f%% %7.2f%% %+8.2f" % (t, sa, sb, sb-sa))
print()
carriers = [t for t in union if t.startswith("eu/exeris") and any(
    k in t for k in ("Http", "Route", "PathTemplate", "ReadResult", "RequestPersistence", "FlowKey", "StreamId"))]
print("converted-carrier types appearing in the sample: %d" % len(carriers))
for t in sorted(carriers, key=lambda x: -(arms[A][x]+arms[B][x]))[:10]:
    sa = 100*arms[A][t]/totals[A] if totals[A] else 0
    sb = 100*arms[B][t]/totals[B] if totals[B] else 0
    print("  %-50s %7.3f%% %7.3f%%" % (t, sa, sb))
