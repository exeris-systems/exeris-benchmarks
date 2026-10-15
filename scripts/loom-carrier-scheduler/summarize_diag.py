#!/usr/bin/env python3
"""Tabulate a run-diagnostics.sh directory: one row per trial, one section per recorder.

Every trial here ran with a recorder attached, so the latencies are diagnostic, not results; the
point of each table is the comparison between the probe's slow windows and the rest of the same
trial.
"""
import json
from collections import defaultdict
import sys
from pathlib import Path


def fmt(d, n=4):
    if not d:
        return "—"
    return ", ".join(f"{k} {v}" for k, v in list(d.items())[:n])


def main(root):
    root = Path(root)
    trials = []
    for f in sorted(root.glob("*/diag.json")):
        d = json.loads(f.read_text())
        d["kind"] = f.parent.name.rsplit("-", 1)[1]
        d["cell"] = f"{d['arm']} @ {d['rate']}"
        trials.append(d)
    failed = sorted(p.name for p in root.iterdir() if p.is_dir() and not (p / "diag.json").exists())
    trials.sort(key=lambda d: (d["cell"], d["kind"], d["trial"]))
    out = [f"# Diagnostics `{root.name}`", "",
           "Every trial ran with a latency probe and at least one recorder: latencies here are diagnostic, "
           "not results. *Slow* means a probe request above the trial's threshold (twice its median), "
           "merged into windows; each recorder is compared inside those windows against outside them.", ""]
    if failed:
        out += [f"Trials without a diagnosis (see their `.log`): {', '.join(failed)}", ""]

    light = defaultdict(list)
    for d in trials:
        if d["kind"] in ("light", "ctl", "idle"):
            light[(d["arm"], d["rate"], d.get("poller_mode"), d["kind"])].append(d)
    if light:
        out += ["## Least-perturbed trials by cell, pollerMode and kind", "",
                "The least perturbed trials (probe and GC log only). Across fresh JVMs; the D-at-70 % "
                "question is whether the split into fast and slow JVMs survives a change of pollerMode.", "",
                "`ctl` adds a backend trace; `idle` also raises the mock's idle timeout to 600 s.", "",
                "| arm | rate | pollerMode | kind | n | wrk2 p99, sorted | probe slow ms, sorted |",
                "|:--|--:|--:|:--|--:|:--|:--|"]
        for (arm, rate, pm, kind), ds in sorted(light.items()):
            p99 = sorted(d["wrk2_p99_ms"] for d in ds if d["wrk2_p99_ms"] is not None)
            slow = sorted(d["probe"]["slow_time_ms"] for d in ds)
            out.append(f"| {arm} | {rate} | {pm} | {kind} | {len(ds)} | {', '.join(f'{x:.1f}' for x in p99)} | "
                       f"{', '.join(f'{x:.0f}' for x in slow)} |")
        out.append("")

    out += ["## Probe and pauses", "",
            "| trial | kind | wrk2 p99 | probe p99 | probe max | slow windows | slow ms | longest ms | "
            "server GC+safepoint: max ms / % of slow time | mock: max ms / % |",
            "|:--|:--|--:|--:|--:|--:|--:|--:|:--|:--|"]
    for d in trials:
        p, gs, gm = d["probe"], d.get("gc_server") or {}, d.get("gc_mock") or {}
        out.append(f"| {d['trial']} | {d['kind']} | {d['wrk2_p99_ms']} | {p['p99_ms']} | {p['max_ms']} | "
                   f"{p['slow_windows']} | {p['slow_time_ms']} | {p['longest_window_ms']} | "
                   f"{gs.get('max_ms', '—')} / {gs.get('slow_time_covered_pct', '—')} | "
                   f"{gm.get('max_ms', '—')} / {gm.get('slow_time_covered_pct', '—')} |")

    sched = [d for d in trials if d.get("sched") and "threads" in d["sched"]]
    if sched:
        out += ["", "## Scheduler trace", "",
                "State shares of each thread role inside the slow windows / outside them, the longest single "
                "wait for a CPU, and what ran on the CPU it waited for during slow windows.", "",
                "| trial | role | in slow: run / wait / sleep % | outside: run / wait / sleep % | wait max ms | "
                "waited behind (slow) |",
                "|:--|:--|:--|:--|--:|:--|"]
        for d in sched:
            for role, t in d["sched"]["threads"].items():
                if role == "server JVM internal":
                    continue
                si, so = t["state_pct_in_slow"], t["state_pct_outside"]
                out.append(f"| {d['trial']} | {role} | {si.get('run', 0)} / {si.get('wait', 0)} / {si.get('sleep', 0)} | "
                           f"{so.get('run', 0)} / {so.get('wait', 0)} / {so.get('sleep', 0)} | {t['wait_max_ms']} | "
                           f"{fmt(t['waited_behind_in_slow'], 3)} |")
        out += ["", "| trial | carrier CPU idle % in slow / outside | stacking ms/s in slow / outside | longest stacked ms |",
                "|:--|:--|:--|--:|"]
        for d in sched:
            s = d["sched"]
            idle = "; ".join(f"{c} {v['idle_pct_in_slow']} / {v['idle_pct_outside']}" for c, v in s["carrier_cpus"].items())
            st = s.get("stacking") or {}
            out.append(f"| {d['trial']} | {idle} | {st.get('stacked_ms_per_s_in_slow', '—')} / "
                       f"{st.get('stacked_ms_per_s_outside', '—')} | {st.get('longest_episode_ms', '—')} |")

    wall = [d for d in trials if d.get("wall")]
    if wall:
        out += ["", "## Wall-clock profile", "",
                "Deepest Java frame, share of samples, inside the slow windows against the whole window.", "",
                "| trial | thread | in slow | whole window |", "|:--|:--|:--|:--|"]
        for d in wall:
            for group in ("carriers", "Master-Poller", "carrier/native-tcp/reactor/0"):
                a = d["wall"]["in_slow"].get(group, {})
                b = d["wall"]["overall"].get(group, {})
                out.append(f"| {d['trial']} | {group} | {fmt(a.get('top_leaves_pct'))} | {fmt(b.get('top_leaves_pct'))} |")

    jfr = [d for d in trials if d.get("jfr")]
    if jfr:
        out += ["", "## Virtual-thread pinning (JFR, ≥ 1 ms)", "",
                "| trial | events | total ms | max ms | in slow windows | top frames |", "|:--|--:|--:|--:|--:|:--|"]
        for d in jfr:
            j = d["jfr"]
            out.append(f"| {d['trial']} | {j.get('pinned_events', '—')} | {j.get('pinned_total_ms', '—')} | "
                       f"{j.get('pinned_max_ms', '—')} | {j.get('overlapping_slow_windows', '—')} | "
                       f"{fmt({k: v['events'] for k, v in (j.get('by_frame') or {}).items()}, 3)} |")

    backend = [d for d in trials if d.get("backend")]
    if backend:
        out += ["", "## Mock backend", "",
                "The mock JVM's CPU (two CPUs, 200 % at most): median, largest one-second value and the second it "
                "fell in, and the median after it. Where the backend was traced: the server's connections to the "
                "mock (pool) and from the load generator (client), as established / CLOSE_WAIT / TIME_WAIT from "
                "three seconds before that peak to three after, and the mock threads that rose by 5 points or more.", "",
                "| trial | kind | wrk2 p99 | mock CPU median / peak @ s / after | pool est / CW / TW around peak | "
                "client est / CW / TW around peak | mock threads at peak |",
                "|:--|:--|--:|:--|:--|:--|:--|"]

        def conn(c):
            if not c:
                return "—"
            return " / ".join(str(c[f"{n}_around_peak"]) for n in ("established", "close_wait", "time_wait"))
        for d in backend:
            b = d["backend"]
            thr = ", ".join(f"{k} {v['baseline']:.0f}→{v['at_peak']:.0f}"
                            for k, v in list((b.get("threads_jumping_at_peak") or {}).items())[:4]) or "—"
            out.append(f"| {d['trial']} | {d['kind']} | {d['wrk2_p99_ms']} | {b['cpu_median_pct']:.0f} / "
                       f"{b['cpu_peak_pct']:.0f} @ {b['peak_second']} / {b['cpu_after_peak_median_pct']} | "
                       f"{conn(b.get('pool_connections'))} | {conn(b.get('client_connections'))} | {thr} |")
        prof = [d for d in backend if d["backend"].get("mock_profile")]
        if prof:
            out += ["", "Mock CPU profile, deepest Java frame, share of samples in the peak second against the whole "
                    "window:", "", "| trial | peak second | whole window |", "|:--|:--|:--|"]
            for d in prof:
                mp = d["backend"]["mock_profile"]
                out.append(f"| {d['trial']} | {fmt(mp['top_frames_peak_second'], 5)} | {fmt(mp['top_frames_whole'], 5)} |")

    (root / "summary.md").write_text("\n".join(out) + "\n")
    print(f"wrote {root / 'summary.md'} ({len(trials)} trials, {len(failed)} without diagnosis)")


if __name__ == "__main__":
    main(sys.argv[1])
