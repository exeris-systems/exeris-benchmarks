#!/usr/bin/env python3
"""Cut a diagnostic trial's recordings to the latency probe's slow windows.

wrk2 reports a histogram and no time, so a tail cannot be attributed from it. The latency probe
(latency_probe.py) gives a timeline on CLOCK_MONOTONIC; this script finds the windows where probe
requests were slow and compares, inside those windows against outside them:

  - the scheduler trace (perf-sched.data, every CPU): for each server thread that matters, the
    share of time running, waiting for a CPU and sleeping; what occupied the CPU it waited for;
    and, for floating carriers, the time one carrier waited behind the other while the other
    carrier CPU was idle (stacking);
  - GC and safepoint pauses (gc-server.log, gc-mock.log);
  - the wall-clock profile (profile-wall.jfr): leaf frames of carriers and poller threads;
  - the JFR recording (server.jfr): virtual-thread pinning events.

Whatever was not recorded is skipped. Writes diag.json and diag.txt into the trial directory.
"""
import bisect
import heapq
import json
import re
import subprocess
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from parse_trial import load_names, load_thread_map  # noqa: E402

WORKSPACE_TOOLS = Path(__file__).resolve().parents[4] / "tools"
for parent in Path(__file__).resolve().parents:
    if (parent / "tools" / "jdk-loom").is_dir():
        WORKSPACE_TOOLS = parent / "tools"
        break
JFRCONV = WORKSPACE_TOOLS / "async-profiler" / "bin" / "jfrconv"
JFR = WORKSPACE_TOOLS / "jdk-loom" / "current" / "bin" / "jfr"
ENV = {"LC_ALL": "C", "PATH": "/usr/bin:/bin"}

MERGE_GAP_S = 0.020
MAX_WALL_WINDOWS = 60


# --- windows ------------------------------------------------------------------------------------

def merge(intervals, gap=0.0):
    out = []
    for s, e in sorted(intervals):
        if out and s <= out[-1][1] + gap:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return [tuple(x) for x in out]


def overlap(a0, a1, windows):
    """Length of [a0, a1] that falls inside a sorted list of disjoint windows."""
    total = 0.0
    i = bisect.bisect_left(windows, (a0, a0)) - 1
    i = max(i, 0)
    while i < len(windows) and windows[i][0] < a1:
        s, e = windows[i]
        total += max(0.0, min(a1, e) - max(a0, s))
        i += 1
    return total


def clip(windows, lo, hi):
    return [(max(s, lo), min(e, hi)) for s, e in windows if e > lo and s < hi]


def load_probe(out):
    path = out / "probe.csv"
    if not path.exists():
        return None
    rows = []
    for line in path.read_text().splitlines()[1:]:
        c, due, lat, st = line.split(",")
        rows.append((float(due), float(lat), int(st)))
    ok = sorted(r[1] for r in rows if r[2] == 200)
    if not ok:
        return None
    floor = ok[len(ok) // 2]
    threshold = max(2.0 * floor, floor + 10.0)
    slow = [(due, due + lat / 1000.0) for due, lat, st in rows if st != 200 or lat > threshold]
    windows = merge(slow, MERGE_GAP_S)
    span = (rows[0][0], max(due + lat / 1000.0 for due, lat, _ in rows))
    episodes = []
    for s, e in windows:
        inside = [r for r in rows if s <= r[0] <= e]
        episodes.append({"start_s": round(s - span[0], 3), "duration_ms": round((e - s) * 1000, 1),
                         "requests": len(inside), "max_latency_ms": round(max((r[1] for r in inside), default=0), 1)})
    return {
        "requests": len(rows), "failed": sum(1 for r in rows if r[2] != 200),
        "p50_ms": round(floor, 2), "p99_ms": round(ok[int(len(ok) * 0.99)], 2), "max_ms": round(ok[-1], 2),
        "slow_threshold_ms": round(threshold, 2), "slow_requests": len(slow),
        "slow_windows": len(windows), "slow_time_ms": round(sum(e - s for s, e in windows) * 1000, 1),
        "longest_window_ms": round(max((e - s for s, e in windows), default=0) * 1000, 1),
        "top_windows": sorted(episodes, key=lambda x: -x["duration_ms"])[:10],
        "_windows": windows, "_span": span,
    }


def clock_offset(out):
    """Seconds to add to CLOCK_MONOTONIC to get Unix time."""
    wall, mono = map(float, (out / "clock.txt").read_text().split())
    return wall - mono


# --- thread roles -------------------------------------------------------------------------------

CARRIER_RE = re.compile(r"^(exeris-carrier-\d+|ForkJoinPool-\d+-worker-\d+)$")


def role(name):
    if CARRIER_RE.match(name):
        return name
    for prefix in ("Master-Poller", "Read-Poller", "Write-Poller", "VirtualThread-unparker",
                   "carrier/native-tcp/reactor/", "carrier/native-tcp/acceptor"):
        if name.startswith(prefix):
            return name
    if name.startswith(("GC Thread", "VM Thread", "C1 Comp", "C2 Comp", "VM Periodic")):
        return "server JVM internal"
    return None


# --- scheduler trace ----------------------------------------------------------------------------

LINE_RE = re.compile(r"^\s*(.*?)\s+(\d+)\s+\[(\d+)\]\s+([\d.]+):\s+sched:(\w+):\s+(.*)$")
# perf prints sched_switch either raw (prev_comm=... prev_pid=...) or, on newer kernels and perf,
# as "prev_comm:prev_pid [prio] STATE ==> next_comm:next_pid [prio]".
SWITCH_RE = re.compile(r"prev_comm=(.*) prev_pid=(\d+) prev_prio=\S+ prev_state=(\S+) ==> next_comm=(.*) next_pid=(\d+)"
                       r"|^(.*):(\d+) \[-?\d+\] (\S+) ==> (.*):(\d+) \[-?\d+\]\s*$")
WAKING_RE = re.compile(r"comm=(.*) pid=(\d+) prio=\S+ target_cpu=(\d+)")
MIGRATE_RE = re.compile(r"comm=(.*) pid=(\d+) prio=\S+ orig_cpu=(\d+) dest_cpu=(\d+)")


def analyze_sched(out, server_names, mock_tids, carrier_cpus, windows):
    data = out / "perf-sched.data"
    if not data.exists() or data.stat().st_size == 0:
        return None
    tracked = {tid: r for tid, n in server_names.items() if (r := role(n))}
    label_of = {}

    def label(tid, comm):
        if tid == "0":
            return "idle"
        if tid in server_names:
            return "server:" + (role(server_names[tid]) or "other")
        if tid in mock_tids:
            return "mock"
        return "other:" + re.sub(r"[/:]\d+$", "", comm)

    seg_start = defaultdict(list)   # cpu -> [t]
    seg_label = defaultdict(list)   # cpu -> [label]
    state = {}                      # tid -> (state, since, cpu)
    intervals = defaultdict(list)   # tid -> [(s, e, state, cpu)]
    waits = []                      # (tid, s, e, cpu)
    t_first = t_last = None

    def stream(path):
        proc = subprocess.Popen(["perf", "script", "-i", str(path), "-F", "comm,tid,cpu,time,event,trace"],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=ENV)
        procs.append(proc)
        for line in proc.stdout:
            m = LINE_RE.match(line)
            if m:
                yield float(m.group(4)), m

    procs = []
    sources = [stream(data)]
    wake = out / "perf-sched-wake.data"
    if wake.exists() and wake.stat().st_size > 0:
        sources.append(stream(wake))

    def enter(tid, st, t, cpu):
        prev = state.get(tid)
        if prev is not None:
            intervals[tid].append((prev[1], t, prev[0], prev[2]))
            if prev[0] == "wait" and st == "run":
                waits.append((tid, prev[1], t, cpu))
        state[tid] = (st, t, cpu)

    for t, m in heapq.merge(*sources, key=lambda x: x[0]):
        cpu, ev, rest = int(m.group(3)), m.group(5), m.group(6)
        t_first = t if t_first is None else t_first
        t_last = t
        if ev == "sched_switch":
            s = SWITCH_RE.match(rest)
            if not s:
                continue
            g = s.groups()[0:5] if s.group(1) is not None else s.groups()[5:10]
            prev_tid, prev_state, next_comm, next_tid = g[1], g[2], g[3], g[4]
            seg_start[cpu].append(t)
            seg_label[cpu].append(label(next_tid, next_comm))
            if prev_tid in tracked:
                enter(prev_tid, "wait" if prev_state.startswith("R") else "sleep", t, cpu)
            if next_tid in tracked:
                enter(next_tid, "run", t, cpu)
        elif ev == "sched_waking":
            w = WAKING_RE.match(rest)
            if w and w.group(2) in tracked and state.get(w.group(2), ("sleep",))[0] == "sleep":
                enter(w.group(2), "wait", t, int(w.group(3)))
        elif ev == "sched_migrate_task":
            g = MIGRATE_RE.match(rest)
            if g and g.group(2) in tracked and state.get(g.group(2), ("",))[0] == "wait":
                st = state[g.group(2)]
                state[g.group(2)] = (st[0], st[1], int(g.group(4)))
    for proc in procs:
        proc.wait()
    if t_first is None:
        return {"error": "perf script produced no sched events"}
    for tid, (st, since, cpu) in state.items():
        intervals[tid].append((since, t_last, st, cpu))

    slow = clip(windows, t_first, t_last)
    slow_total = sum(e - s for s, e in slow)
    span_total = t_last - t_first

    def occupants(cpu, s, e, exclude):
        starts = seg_start.get(cpu, [])
        acc = defaultdict(float)
        i = max(bisect.bisect_right(starts, s) - 1, 0)
        while i < len(starts) and starts[i] < e:
            a = max(starts[i], s)
            b = min(starts[i + 1] if i + 1 < len(starts) else t_last, e)
            if b > a and seg_label[cpu][i] != exclude:
                acc[seg_label[cpu][i]] += b - a
            i += 1
        return acc

    threads = {}
    by_role = defaultdict(list)
    for tid, r in tracked.items():
        by_role[r].append(tid)
    for r, tids in sorted(by_role.items()):
        frac = {"in_slow": defaultdict(float), "outside": defaultdict(float)}
        for tid in tids:
            for s, e, st, _ in intervals.get(tid, []):
                ins = overlap(s, e, slow)
                frac["in_slow"][st] += ins
                frac["outside"][st] += (e - s) - ins
        occ = {"in_slow": defaultdict(float), "outside": defaultdict(float)}
        eps = []
        for tid, s, e, cpu in waits:
            if tid not in tids:
                continue
            eps.append(e - s)
            ins = overlap(s, e, slow)
            share = ins / (e - s) if e > s else 0.0
            for lab, d in occupants(cpu, s, e, "server:" + r).items():
                occ["in_slow"][lab] += d * share
                occ["outside"][lab] += d * (1 - share)
        eps.sort()

        def pct(d):
            tot = sum(d.values())
            return {k: round(100 * v / tot, 1) for k, v in sorted(d.items(), key=lambda kv: -kv[1])} if tot else {}

        def top(d, n=5):
            tot = sum(d.values())
            return {k: round(100 * v / tot, 1) for k, v in sorted(d.items(), key=lambda kv: -kv[1])[:n]} if tot else {}
        threads[r] = {
            "state_pct_in_slow": pct(frac["in_slow"]), "state_pct_outside": pct(frac["outside"]),
            "wait_episodes": len(eps), "wait_max_ms": round(eps[-1] * 1000, 2) if eps else 0,
            "wait_p99_ms": round(eps[int(len(eps) * 0.99)] * 1000, 3) if eps else 0,
            "waited_behind_in_slow": top(occ["in_slow"]), "waited_behind_outside": top(occ["outside"]),
        }

    idle = {}
    for cpu in carrier_cpus:
        acc = {"in_slow": 0.0, "outside": 0.0}
        starts = seg_start.get(cpu, [])
        for i, a in enumerate(starts):
            if seg_label[cpu][i] != "idle":
                continue
            b = starts[i + 1] if i + 1 < len(starts) else t_last
            ins = overlap(a, b, slow)
            acc["in_slow"] += ins
            acc["outside"] += (b - a) - ins
        idle[f"cpu{cpu}"] = {
            "idle_pct_in_slow": round(100 * acc["in_slow"] / slow_total, 1) if slow_total else None,
            "idle_pct_outside": round(100 * acc["outside"] / (span_total - slow_total), 1) if span_total > slow_total else None,
        }

    # Stacking: a carrier waits on CPU c while the other carrier runs there and the other carrier
    # CPU is idle. Only defined for two carriers sharing two CPUs.
    stacking = None
    carriers = [tid for tid, r in tracked.items() if CARRIER_RE.match(r)]
    if len(carriers) == 2 and len(carrier_cpus) == 2:
        tot = {"in_slow": 0.0, "outside": 0.0}
        longest = 0.0
        for tid, s, e, cpu in waits:
            if tid not in carriers or cpu not in carrier_cpus:
                continue
            other = "server:" + tracked[carriers[1] if tid == carriers[0] else carriers[0]]
            sibling = carrier_cpus[1] if cpu == carrier_cpus[0] else carrier_cpus[0]
            starts = seg_start.get(cpu, [])
            i = max(bisect.bisect_right(starts, s) - 1, 0)
            stacked = 0.0
            while i < len(starts) and starts[i] < e:
                a = max(starts[i], s)
                b = min(starts[i + 1] if i + 1 < len(starts) else t_last, e)
                if b > a and seg_label[cpu][i] == other:
                    for lab, d in occupants(sibling, a, b, None).items():
                        if lab == "idle":
                            ins = overlap(a, b, slow) * d / (b - a)
                            tot["in_slow"] += ins
                            tot["outside"] += d - ins
                            stacked += d
                i += 1
            longest = max(longest, stacked)
        stacking = {
            "stacked_ms_per_s_in_slow": round(1000 * tot["in_slow"] / slow_total, 2) if slow_total else None,
            "stacked_ms_per_s_outside": round(1000 * tot["outside"] / (span_total - slow_total), 2) if span_total > slow_total else None,
            "longest_episode_ms": round(longest * 1000, 2),
        }

    return {"recorded_s": round(span_total, 1), "slow_s_in_recording": round(slow_total, 3),
            "threads": threads, "carrier_cpus": idle, "stacking": stacking}


# --- GC and safepoint logs ------------------------------------------------------------------------

GC_RE = re.compile(r"^\[([^\]]+)\]\[[^\]]+\]\[\w+\]\[([\w,]+)\s*\]\s*(.*)$")


def analyze_pauses(path, offset, windows, lo, hi):
    if not path.exists():
        return None
    pauses = []
    for line in path.read_text(errors="replace").splitlines():
        m = GC_RE.match(line)
        if not m:
            continue
        end = datetime.fromisoformat(m.group(1)).timestamp() - offset
        msg = m.group(3)
        if "safepoint" in m.group(2):
            t = re.search(r"Total: (\d+) ns", msg)
            if t:
                dur = int(t.group(1)) / 1e9
                op = re.search(r'Safepoint "([^"]+)"', msg)
                pauses.append((end - dur, end, "safepoint " + (op.group(1) if op else "?")))
        elif "Pause" in msg:
            t = re.search(r"([\d.]+)ms$", msg)
            if t:
                dur = float(t.group(1)) / 1000
                kind = re.search(r"Pause [\w ]+?(?= \(|\s\d|$)", msg)
                pauses.append((end - dur, end, kind.group(0) if kind else "gc pause"))
    pauses = [p for p in pauses if p[1] > lo and p[0] < hi]
    if not pauses:
        return {"pauses": 0}
    durs = sorted(p[1] - p[0] for p in pauses)
    in_slow = [p for p in pauses if overlap(p[0], p[1], windows) > 0]
    covered = sum(overlap(p[0], p[1], windows) for p in pauses)
    slow_total = sum(e - s for s, e in clip(windows, lo, hi))
    return {"pauses": len(pauses), "total_ms": round(sum(durs) * 1000, 1), "max_ms": round(durs[-1] * 1000, 2),
            "overlapping_slow_windows": len(in_slow),
            "slow_time_covered_pct": round(100 * covered / slow_total, 1) if slow_total else None,
            "longest": sorted(({"what": p[2], "ms": round((p[1] - p[0]) * 1000, 2)} for p in pauses),
                              key=lambda x: -x["ms"])[:5]}


# --- wall-clock profile ---------------------------------------------------------------------------

def collapsed(jfr, frm=None, to=None):
    args = [str(JFRCONV), "--wall", "-t", "-o", "collapsed"]
    if frm is not None:
        args += ["--from", str(int(frm)), "--to", str(int(to) + 1)]
    out = subprocess.run(args + [str(jfr), "/dev/stdout"], capture_output=True, text=True, env=ENV)
    stacks = defaultdict(int)
    for line in out.stdout.splitlines():
        stack, _, n = line.rpartition(" ")
        if stack and n.isdigit():
            stacks[stack] += int(n)
    return stacks


def java_leaf(frames):
    """The deepest Java frame: a native leaf is usually a syscall stub that says nothing about
    why the thread is there."""
    for f in reversed(frames[1:]):
        if "/" in f:
            return re.sub(r"_\[[^\]]*\]$", "", f)
    return frames[-1]


def leaf_profile(stacks):
    """Per thread role: share of samples by deepest Java frame."""
    acc = defaultdict(lambda: defaultdict(int))
    for stack, n in stacks.items():
        frames = stack.split(";")
        m = re.match(r"\[(.*?) tid=\d+\]", frames[0])
        r = role(m.group(1)) if m else None
        if not r or r == "server JVM internal":
            continue
        group = "carriers" if CARRIER_RE.match(r) else r
        acc[group][java_leaf(frames)] += n
    res = {}
    for group, leaves in acc.items():
        tot = sum(leaves.values())
        res[group] = {"samples": tot, "top_leaves_pct": {k: round(100 * v / tot, 1)
                                                         for k, v in sorted(leaves.items(), key=lambda kv: -kv[1])[:8]}}
    return res


def analyze_wall(out, offset, windows, lo, hi):
    jfr = out / "profile-wall.jfr"
    if not jfr.exists() or not JFRCONV.exists():
        return None
    overall = collapsed(jfr)
    slow = defaultdict(int)
    picked = sorted(clip(windows, lo, hi), key=lambda w: -(w[1] - w[0]))[:MAX_WALL_WINDOWS]
    for s, e in picked:
        for stack, n in collapsed(jfr, (s + offset) * 1000, (e + offset) * 1000).items():
            slow[stack] += n
    (out / "profile-wall.collapsed.txt").write_text("".join(f"{k} {v}\n" for k, v in overall.items()))
    (out / "profile-wall-slow.collapsed.txt").write_text("".join(f"{k} {v}\n" for k, v in slow.items()))
    return {"windows_cut": len(picked), "overall": leaf_profile(overall), "in_slow": leaf_profile(slow)}


# --- JFR ----------------------------------------------------------------------------------------

def analyze_jfr(out, offset, windows, lo, hi):
    path = out / "server.jfr"
    if not path.exists():
        return None
    proc = subprocess.run([str(JFR), "print", "--json", "--events", "jdk.VirtualThreadPinned", str(path)],
                          capture_output=True, text=True)
    try:
        events = json.loads(proc.stdout)["recording"]["events"]
    except (ValueError, KeyError):
        return {"error": proc.stderr.strip()[-300:]}
    pinned = []
    for ev in events:
        v = ev["values"]
        start = datetime.fromisoformat(v["startTime"]).timestamp() - offset
        d = re.match(r"PT(?:(\d+)M)?([\d.]+)S", v.get("duration", "PT0S"))
        dur = (int(d.group(1) or 0) * 60 + float(d.group(2))) if d else 0.0
        if start + dur < lo or start > hi:
            continue
        frames = (v.get("stackTrace") or {}).get("frames") or []
        top = next((f["method"]["type"]["name"] + "." + f["method"]["name"] for f in frames
                    if not f["method"]["type"]["name"].startswith(("java.lang.VirtualThread", "jdk.internal"))), "?")
        pinned.append((start, start + dur, top))
    if not pinned:
        return {"pinned_events": 0}
    by_frame = defaultdict(lambda: [0, 0.0])
    for s, e, top in pinned:
        by_frame[top][0] += 1
        by_frame[top][1] += e - s
    return {"pinned_events": len(pinned), "pinned_total_ms": round(sum(e - s for s, e, _ in pinned) * 1000, 1),
            "pinned_max_ms": round(max(e - s for s, e, _ in pinned) * 1000, 2),
            "overlapping_slow_windows": sum(1 for s, e, _ in pinned if overlap(s, e, windows) > 0),
            "by_frame": {k: {"events": c, "ms": round(t * 1000, 1)}
                         for k, (c, t) in sorted(by_frame.items(), key=lambda kv: -kv[1][1])[:8]}}


# --- report -------------------------------------------------------------------------------------

def main(trial_dir):
    out = Path(trial_dir)
    trial = json.loads((out / "trial.json").read_text())
    probe = load_probe(out)
    if probe is None:
        print("no probe timeline; nothing to cut", file=sys.stderr)
        return 1
    windows, (lo, hi) = probe.pop("_windows"), probe.pop("_span")
    offset = clock_offset(out)
    names = load_names(out)
    mock_tids = set(load_thread_map(out / "mock-threads.txt"))
    carrier_cpus = [int(c) for c in trial["layout"]["carriers"].split(",")]

    diag = {
        "trial": out.name, "arm": trial["arm"], "rate": trial["rate"], "poller_mode": trial.get("poller_mode"),
        "diagnostics": trial.get("diagnostics"),
        "wrk2_p99_ms": trial["load"]["percentiles_ms"].get("p99"),
        "probe": probe,
        "sched": analyze_sched(out, names, mock_tids, carrier_cpus, windows),
        "gc_server": analyze_pauses(out / "gc-server.log", offset, windows, lo, hi),
        "gc_mock": analyze_pauses(out / "gc-mock.log", offset, windows, lo, hi),
        "wall": analyze_wall(out, offset, windows, lo, hi),
        "jfr": analyze_jfr(out, offset, windows, lo, hi),
    }
    (out / "diag.json").write_text(json.dumps(diag, indent=2) + "\n")

    lines = [f"{out.name}: arm {trial['arm']} rate {trial['rate']}, wrk2 p99 {diag['wrk2_p99_ms']} ms, "
             f"diagnostics: {', '.join(trial.get('diagnostics') or [])}",
             f"probe: {probe['requests']} requests, p50 {probe['p50_ms']} p99 {probe['p99_ms']} max {probe['max_ms']} ms; "
             f"slow (> {probe['slow_threshold_ms']} ms): {probe['slow_requests']} requests in {probe['slow_windows']} windows, "
             f"{probe['slow_time_ms']} ms total, longest {probe['longest_window_ms']} ms"]
    for key in ("sched", "gc_server", "gc_mock", "wall", "jfr"):
        if diag[key] is not None:
            lines.append(f"--- {key}")
            lines.append(json.dumps(diag[key], indent=1))
    (out / "diag.txt").write_text("\n".join(lines) + "\n")
    print(lines[0]); print(lines[1])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
