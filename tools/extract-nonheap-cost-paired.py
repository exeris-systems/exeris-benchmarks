import json, re, subprocess, os, statistics
C = "/home/bench/exeris-benchmarks/results/raw/kernel-version-axis/20260818T062534Z-light-valhalla-carriers"
JFR = "/opt/jdk28/bin/jfr"

def jprint(f, ev):
    r = subprocess.run([JFR, "print", "--json", "--events", ev, f],
                       capture_output=True, text=True)
    try:
        return json.loads(r.stdout).get("recording", {}).get("events", [])
    except Exception:
        return []

def scan(f):
    out = {}
    ev = [e["values"] for e in jprint(f, "jdk.MetaspaceSummary")]
    after = [v for v in ev if str(v.get("when")) == "After GC"]
    if after:
        v = after[-1]
        for sec in ("metaspace", "dataSpace", "classSpace"):
            d = v.get(sec) or {}
            for k in ("committed", "used", "reserved"):
                if k in d:
                    out[sec + "." + k] = float(d[k])
    ev = [e["values"] for e in jprint(f, "jdk.ClassLoadingStatistics")]
    if ev:
        out["loadedClasses"] = max(int(v["loadedClassCount"]) for v in ev)
        out["unloadedClasses"] = max(int(v["unloadedClassCount"]) for v in ev)
    ev = [e["values"] for e in jprint(f, "jdk.CodeCacheStatistics")]
    if ev:
        used, entries, adaptors = {}, {}, {}
        for v in ev:
            t = str(v.get("codeBlobType"))
            res = float(v["reservedTopAddress"]) - float(v["startAddress"])
            u = res - float(v.get("unallocatedCapacity", 0) or 0)
            used[t] = max(used.get(t, 0.0), u)
            entries[t] = max(entries.get(t, 0), int(v.get("entryCount", 0) or 0))
            adaptors[t] = max(adaptors.get(t, 0), int(v.get("adaptorCount", 0) or 0))
        out["codeCache.used"] = sum(used.values())
        out["codeCache.entries"] = sum(entries.values())
        out["codeCache.adaptors"] = sum(adaptors.values())
    return out

legs = {}
for leg in ("E__F", "D_double_prime__F"):
    rows = []
    base = os.path.join(C, "light", leg)
    for run in sorted(os.listdir(base)):
        for order in ("ab", "ba"):
            d = os.path.join(base, run, order)
            if not os.path.isdir(d):
                continue
            pair = {}
            for slot in ("target-a", "target-b"):
                p = os.path.join(d, slot)
                fs = [x for x in os.listdir(p) if x.startswith("target-") and x.endswith(".jfr")] if os.path.isdir(p) else []
                if not fs:
                    continue
                arm = re.search(r"target-(exeris-[a-z0-9-]+)-\d{8}", fs[0]).group(1)
                pair[arm] = scan(os.path.join(p, fs[0]))
            if len(pair) == 2:
                rows.append((run, order, pair))
    legs[leg] = rows

TCRIT = {3: 4.303, 4: 3.182, 5: 2.776, 6: 2.571}
KEYS = ["loadedClasses", "metaspace.used", "metaspace.committed",
        "dataSpace.used", "classSpace.used",
        "codeCache.used", "codeCache.entries", "codeCache.adaptors"]
for leg, rows in legs.items():
    arms = sorted({k for _, _, p in rows for k in p})
    A, B = arms[0], arms[1]
    if "0111pv" in A:
        A, B = B, A
    print("=" * 96)
    print("LEG %s   A=%s   B=%s   n=%d" % (leg, A, B, len(rows)))
    for k in KEYS:
        da = [p[A].get(k) for _, _, p in rows]
        db = [p[B].get(k) for _, _, p in rows]
        if any(v is None or v == 0 for v in da + db):
            print("  %-22s <missing>" % k)
            continue
        deltas = [(y - x) / x * 100 for x, y in zip(da, db)]
        ma, mb, md = statistics.mean(da), statistics.mean(db), statistics.mean(deltas)
        sd = statistics.stdev(deltas)
        hw = TCRIT[len(deltas)] * sd / (len(deltas) ** 0.5)
        neg = sum(1 for x in deltas if x < 0)
        pos = sum(1 for x in deltas if x > 0)
        isc = k in ("loadedClasses", "codeCache.entries", "codeCache.adaptors")
        u = "" if isc else " kB"
        fa, fb = (ma, mb) if isc else (ma / 1024, mb / 1024)
        print("  %-22s A=%11.1f%s  B=%11.1f%s  abs=%+9.1f%s  d=%+7.3f%%  CI[%+7.3f,%+7.3f]  -%d/+%d"
              % (k, fa, u, fb, u, (fb - fa), u, md, md - hw, md + hw, neg, pos))
        fmt = (lambda x: int(x)) if isc else (lambda x: round(x / 1024, 1))
        print("      A %s" % [fmt(x) for x in da])
        print("      B %s" % [fmt(x) for x in db])
