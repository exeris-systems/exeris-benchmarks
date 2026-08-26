import json, os, re, statistics, subprocess
import sys
C = sys.argv[1] if len(sys.argv) > 1 else "/home/bench/exeris-benchmarks/results/raw/kernel-version-axis/20260818T062534Z-light-valhalla-carriers"
JFR = "/opt/jdk28/bin/jfr"

def jev(f, ev):
    r = subprocess.run([JFR, "print", "--json", "--events", ev, f], capture_output=True, text=True)
    try:
        return [e["values"] for e in json.loads(r.stdout)["recording"]["events"]]
    except Exception:
        return []

def ts(s):
    m = re.match(r".*T(\d\d):(\d\d):(\d\d)\.(\d+)", str(s))
    if not m:
        return None
    return int(m.group(1))*3600 + int(m.group(2))*60 + int(m.group(3)) + float("0." + m.group(4))

def scan(f):
    ev = jev(f, "jdk.GCHeapSummary")
    pts = []
    for v in ev:
        t = ts(v.get("startTime"))
        used = v.get("heapUsed")
        when = str(v.get("when"))
        if t is None or used is None:
            continue
        pts.append((t, float(used), when))
    pts.sort(key=lambda x: x[0])
    if len(pts) < 4:
        return None
    alloc = 0.0
    n = 0
    for i in range(len(pts) - 1):
        if pts[i][2] == "After GC" and pts[i+1][2] == "Before GC":
            d = pts[i+1][1] - pts[i][1]
            if d > 0:
                alloc += d
                n += 1
    span = pts[-1][0] - pts[0][0]
    if span <= 0:
        return None
    gcs = sum(1 for p in pts if p[2] == "Before GC")
    pause = 0.0
    for v in jev(f, "jdk.GCPhasePause"):
        t = ts(v.get("startTime"))
        dur = v.get("duration")
        secs = None
        if isinstance(dur, (int, float)):
            secs = float(dur) / 1e9
        elif isinstance(dur, str):
            m2 = re.match(r"PT([\d.]+)S", dur)
            if m2:
                secs = float(m2.group(1))
        if t is not None and pts[0][0] <= t <= pts[-1][0] and secs is not None:
            pause += secs
    return {"span": span, "alloc_per_s": alloc/span, "gc_per_s": gcs/span,
            "pause_ms_per_s": pause*1000.0/span if pause else None, "cycles": n}

TCRIT = {1: 0.0, 2: 12.706, 3: 4.303, 4: 3.182, 5: 2.776, 6: 2.571}
for legname in ("E__F",):
    base = os.path.join(C, "light", legname)
    rows = []
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
                m = scan(os.path.join(p, fs[0]))
                rj = os.path.join(p, "result.json")
                rps = None
                if os.path.exists(rj):
                    rps = json.load(open(rj)).get("metrics", {}).get("throughput_rps")
                if m and rps:
                    m["rps"] = rps
                    m["alloc_B_per_req"] = m["alloc_per_s"] / rps
                    pair[arm] = m
            if len(pair) == 2:
                rows.append(pair)
    arms = sorted({k for p in rows for k in p})
    A, B = arms[0], arms[1]
    if "0111pv" in A:
        A, B = B, A
    print("LEG %s  A=%s  B=%s  n=%d" % (legname, A, B, len(rows)))
    print("  spans A %s" % [round(p[A]["span"], 1) for p in rows])
    print("  spans B %s" % [round(p[B]["span"], 1) for p in rows])
    for k, sc, unit in (("alloc_B_per_req", 1, "B/req"), ("alloc_per_s", 1/1e6, "MB/s"),
                        ("gc_per_s", 1, "/s"), ("pause_ms_per_s", 1, "ms/s")):
        da = [p[A].get(k) for p in rows]; db = [p[B].get(k) for p in rows]
        if any(v is None for v in da + db):
            print("  %-18s <missing>" % k); continue
        dl = [(y-x)/x*100 for x, y in zip(da, db)]
        md = statistics.mean(dl); sd = statistics.stdev(dl) if len(dl) > 1 else 0.0
        hw = (TCRIT.get(len(dl), 2.571)*sd/len(dl)**0.5) if len(dl) > 1 else 0.0
        print("  %-18s A=%10.2f %-6s B=%10.2f %-6s d=%+6.2f%%  CI[%+6.2f,%+6.2f]  -%d/+%d"
              % (k, statistics.mean(da)*sc, unit, statistics.mean(db)*sc, unit, md, md-hw, md+hw,
                 sum(1 for x in dl if x < 0), sum(1 for x in dl if x > 0)))
