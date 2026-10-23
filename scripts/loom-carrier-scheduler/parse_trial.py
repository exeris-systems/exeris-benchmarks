#!/usr/bin/env python3
"""Turn one loom-carrier-scheduler trial directory into trial.json.

Every gate is evaluated and recorded with its reason. A trial that fails a gate is still written:
the campaign summary decides what it may be used for, and a failed trial that is missing from the
record cannot be told apart from one that never ran, or be kept out of a latency statistic.
"""
import argparse
import json
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

import armcfg

UNIT_MS = {"us": 0.001, "ms": 1.0, "s": 1000.0, "m": 60000.0}


def to_ms(text):
    m = re.fullmatch(r"([0-9.]+)(us|ms|s|m)", text.strip())
    return float(m.group(1)) * UNIT_MS[m.group(2)] if m else None


def cpu_set(text):
    out = set()
    # systemctl show -p AllowedCPUs emits space-separated lists (e.g. "0 6"); normalise to commas.
    normalised = text.strip().replace(" ", ",")
    for part in normalised.split(","):
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-")
            out.update(range(int(a), int(b) + 1))
        else:
            out.add(int(part))
    return out


def parse_load(path, rate):
    text = path.read_text(errors="replace") if path.exists() else ""
    res = {"requests_per_sec": None, "percentiles_ms": {}, "socket_errors": None, "non_2xx": 0}
    m = re.search(r"Requests/sec:\s+([0-9.]+)", text)
    if m:
        res["requests_per_sec"] = float(m.group(1))
    # wrk2: " 99.000%    3.52ms"; wrk: "     99%    3.52ms"
    for pct, val in re.findall(r"^\s*([0-9.]+)%\s+([0-9.]+(?:us|ms|s|m))\s*$", text, re.M):
        key = f"p{float(pct):g}"
        if key not in res["percentiles_ms"]:
            res["percentiles_ms"][key] = to_ms(val)
    m = re.search(r"Socket errors: connect (\d+), read (\d+), write (\d+), timeout (\d+)", text)
    res["socket_errors"] = {k: int(v) for k, v in zip(("connect", "read", "write", "timeout"), m.groups())} if m else None
    cal = [float(v) for v in re.findall(r"calibration: mean lat\.: ([0-9.]+)ms", text)]
    res["calibration_mean_ms"] = round(sum(cal) / len(cal), 3) if cal else None
    m = re.search(r"Non-2xx or 3xx responses:\s+(\d+)", text)
    res["non_2xx"] = int(m.group(1)) if m else 0
    return res


def is_carrier(name, carrier_re):
    """Match a carrier by Java name, or by the 15-byte name the JVM gives the OS thread.

    The JVM shortens a long thread name for the kernel to its first 7 and last 6 characters around
    "..", so a carrier whose Java name was not captured still reads as exeris-..rier-<n> or
    ForkJoi..rker-<n> in /proc.
    """
    if re.match(carrier_re, name):
        return True
    alias = r"^ForkJoi\.\.rker-\d+$" if "ForkJoinPool" in carrier_re else r"^exeris-\.\.rier-\d+$"
    return bool(re.match(alias, name))


def load_names(out):
    """TID -> Java name: the dump at readiness, overlaid by the one after warmup, and for any thread
    neither dump named, the name the affinity dumps read from /proc."""
    names = load_thread_map(out / "threads-ready.txt")
    names.update(load_thread_map(out / "threads.txt"))
    for dump in ("affinity-start.txt", "affinity-end.txt"):
        path = out / dump
        if path.exists():
            for line in path.read_text().splitlines():
                parts = line.split("\t")
                if len(parts) == 3 and parts[0] not in names:
                    names[parts[0]] = parts[1]
    return names


def load_thread_map(path):
    names = {}
    if path.exists():
        for line in path.read_text().splitlines():
            if "\t" in line:
                tid, name = line.split("\t", 1)
                names[tid] = name
    return names


def parse_pidstat(path, names, carrier_re, keep_cswch=False):
    """Average rows per thread, from both the -u and the -w report.

    keep_cswch adds the carriers' voluntary context switches per second, which pilot trials compare;
    the key is absent otherwise so that a record parsed before it existed re-parses unchanged.
    """
    rows = {}
    header = None
    for line in path.read_text(errors="replace").splitlines() if path.exists() else []:
        if not line.startswith("Average:"):
            header = None if not line.strip() else header
            continue
        cols = line.split()
        if "TID" in cols:
            header = cols
            continue
        if header is None or len(cols) < len(header):
            continue
        rec = dict(zip(header, cols[: len(header)]))
        tid = rec.get("TID")
        if not tid:
            continue
        key = "process" if tid == "-" else tid
        entry = rows.setdefault(key, {"tid": tid})
        for col in ("%usr", "%system", "%wait", "%CPU", "cswch/s", "nvcswch/s"):
            if col in rec:
                try:
                    entry[col] = float(rec[col])
                except ValueError:
                    pass
    groups = {"carriers": [], "reactors": [], "other": []}
    for key, entry in rows.items():
        if key == "process":
            continue
        name = names.get(key, "?")
        entry["name"] = name
        if is_carrier(name, carrier_re):
            groups["carriers"].append(entry)
        elif name.startswith("carrier/native-tcp/reactor/"):
            groups["reactors"].append(entry)
        else:
            groups["other"].append(entry)

    def total(items, col):
        return round(sum(e.get(col, 0.0) for e in items), 2)

    out = {"process": rows.get("process", {})}
    for g in ("carriers", "reactors"):
        items = groups[g]
        out[g] = {
            "count": len(items),
            "cpu_pct": total(items, "%CPU"),
            "usr_pct": total(items, "%usr"),
            "sys_pct": total(items, "%system"),
            "wait_pct_max": round(max((e.get("%wait", 0.0) for e in items), default=0.0), 2),
            "wait_pct_each": {e["name"]: e.get("%wait") for e in items},
            "nvcswch_per_s": total(items, "nvcswch/s"),
        }
    if keep_cswch:
        out["carriers"]["cswch_per_s"] = total(groups["carriers"], "cswch/s")
    return out


def parse_perf(path):
    if not path.exists():
        return None
    text = path.read_text(errors="replace")
    if "not run" in text:
        return None

    def counter(name):
        m = re.search(r"^\s*([0-9.,]+)\s+(?:msec\s+)?" + re.escape(name) + r"\b", text, re.M)
        return float(m.group(1).replace(",", "")) if m else None

    elapsed = re.search(r"([0-9.]+) seconds time elapsed", text)
    elapsed = float(elapsed.group(1)) if elapsed else None
    task_clock = counter("task-clock")
    cycles = counter("cycles")
    instructions = counter("instructions")
    cs = counter("context-switches")
    return {
        "task_clock_ms": task_clock,
        "elapsed_s": elapsed,
        "cpus_utilized": round(task_clock / 1000.0 / elapsed, 3) if task_clock and elapsed else None,
        "cycles": cycles,
        "instructions": instructions,
        "ipc": round(instructions / cycles, 3) if instructions and cycles else None,
        "context_switches_per_s": round(cs / elapsed, 1) if cs is not None and elapsed else None,
        "cpu_migrations": counter("cpu-migrations"),
    }


def parse_perf_sched(out, names):
    """Run time of each server thread per CPU, from perf sched timehist, as a share of its total."""
    data = out / "perf-sched.data"
    if not data.exists():
        return None
    proc = subprocess.run(["perf", "sched", "timehist", "-i", str(data)], capture_output=True, text=True,
                          env={"LC_ALL": "C", "PATH": "/usr/bin:/bin"})
    run_ms = defaultdict(lambda: defaultdict(float))
    for line in proc.stdout.splitlines():
        m = re.match(r"\s*[0-9.]+\s+\[(\d+)\]\s+(.+?)\[(\d+)(?:/\d+)?\]\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)", line)
        if not m:
            continue
        cpu, tid, run = int(m.group(1)), m.group(3), float(m.group(6))
        if tid in names:
            run_ms[names[tid]][cpu] += run
    dist = {}
    lines = []
    for name in sorted(run_ms):
        total = sum(run_ms[name].values())
        if total <= 0:
            continue
        share = {cpu: round(100.0 * ms / total, 1) for cpu, ms in sorted(run_ms[name].items())}
        dist[name] = {"run_ms": round(total, 1), "share_pct_by_cpu": share}
        lines.append(f"{name:40s} {total:10.1f} ms  " + "  ".join(f"cpu{c}={p}%" for c, p in share.items()))
    (out / "perf-sched-distribution.txt").write_text("\n".join(lines) + "\n")
    return dist


def interrupts_per_cpu(path):
    if not path.exists():
        return None
    lines = path.read_text().splitlines()
    ncpu = len(lines[0].split())
    totals = [0] * ncpu
    for line in lines[1:]:
        parts = line.split()
        for i, v in enumerate(parts[1:1 + ncpu]):
            if v.isdigit():
                totals[i] += int(v)
    return totals


def parse_host(out, bench_cpus, carrier_cpus):
    state = {}
    host_file = out / "host.txt"
    if host_file.exists():
        for line in host_file.read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                state[k] = v
    problems = []
    if state.get("graphical_target") == "active":
        problems.append("graphical session active")
    for sl in ("system.slice", "user.slice", "init.scope"):
        allowed = state.get(f"allowed_cpus.{sl}", "")
        if not allowed:
            problems.append(f"{sl} unconfined")
        elif cpu_set(allowed) & bench_cpus:
            problems.append(f"{sl} allowed on benchmark CPUs ({allowed})")
    own = state.get("own_cpus_allowed", "")
    if own and not bench_cpus <= cpu_set(own):
        problems.append(f"the harness may not use every benchmark CPU (allowed {own})")
    start, end = interrupts_per_cpu(out / "interrupts-start.txt"), interrupts_per_cpu(out / "interrupts-end.txt")
    irq = None
    if start and end:
        delta = [e - s for s, e in zip(start, end)]
        irq = {f"cpu{c}": delta[c] for c in sorted(carrier_cpus) if c < len(delta)}
    counters = {}
    for side in ("start", "end"):
        f = out / f"host-counters-{side}.txt"
        if f.exists():
            counters[side] = dict(line.split("=", 1) for line in f.read_text().splitlines() if "=" in line)
    return {"state": state, "shielded": not problems, "problems": problems,
            "interrupts_on_carrier_cpus_during_window": irq, "counters": counters or None}


# Arms whose carriers bind themselves, one CPU each.
PINNED_ARMS = ("B_pin", "D", "D2", "Dv")


def isolation_gate(path, arm, carrier_cpus, carrier_re, expected_carriers):
    if not path.exists():
        return False, ["affinity dump missing"], {}
    problems = []
    carriers = {}
    for line in path.read_text().splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        tid, name, allowed = parts
        cpus = cpu_set(allowed)
        if is_carrier(name, carrier_re):
            carriers[name] = sorted(cpus)
            if arm in PINNED_ARMS:
                if len(cpus) != 1 or not cpus <= carrier_cpus:
                    problems.append(f"{name} allowed {allowed}, expected one CPU of {sorted(carrier_cpus)}")
            elif cpus != carrier_cpus:
                problems.append(f"{name} allowed {allowed}, expected {sorted(carrier_cpus)}")
        elif cpus & carrier_cpus:
            problems.append(f"non-carrier {name} (tid {tid}) may run on carrier CPUs: {allowed}")
    if len(carriers) != expected_carriers:
        problems.append(f"{len(carriers)} carrier threads, expected {expected_carriers}")
    if arm in PINNED_ARMS:
        pinned = [c[0] for c in carriers.values() if len(c) == 1]
        if len(set(pinned)) != len(pinned):
            problems.append("two carriers pinned to the same CPU")
    return not problems, problems, carriers


ECHO_RE = re.compile(r"^LOOM-BENCH locality\.properties (.*)$", re.M)
FLAGS_RE = re.compile(r"\[ExerisCarrierScheduler\] locality flags: (.*)$", re.M)


def parse_pairs(text):
    """`name=value name=value` -> dict; the app prints <none> for an empty set."""
    return {k: v for k, _, v in (tok.partition("=") for tok in text.split()) if _}


def fmt_pairs(pairs):
    return " ".join(f"{k}={v}" for k, v in sorted(pairs.items())) or "<none>"


def arm_config_gate(server_log, arm, file_props, stats, poller_mode):
    """Did the server run with the property set the arm names, and did the scheduler take it?

    Two readings must agree with the expectation. The app echoes every exeris.locality.* system
    property it was started with (a property the harness mistyped is echoed as typed). The
    scheduler prints the effective value of every flag it knows; a mistyped name is absent from
    that line, and a flag nobody set must read as its default. A kernel build older than the line
    prints none, which is acceptable only when the arm sets no property of its own. A trial whose
    server did not echo (an app older than the echo) has no such gate.
    """
    m = ECHO_RE.search(server_log)
    if not m:
        return None
    expected = armcfg.expected_echo(arm, file_props, stats)
    echo = parse_pairs(m.group(1))
    problems = []
    if echo != expected:
        problems.append(f"the server was started with {fmt_pairs(echo)}, expected {fmt_pairs(expected)}")
    runs_scheduler = arm in armcfg.SCHEDULER_ARMS
    f = FLAGS_RE.search(server_log) if runs_scheduler else None
    kernel = parse_pairs(f.group(1)) if f else None
    unchecked = []
    if runs_scheduler:
        if kernel is None:
            if file_props or stats:
                problems.append("the kernel printed no effective-flags line, so it cannot show it took "
                                + fmt_pairs({**file_props, **({armcfg.PREFIX + 'stats': 'true'} if stats else {})}))
        else:
            for name, want in sorted(expected.items()):
                got = kernel.get(name)
                if got is None:
                    problems.append(f"{name} is not among the kernel's effective flags")
                elif got.lower() != want.lower():
                    problems.append(f"{name}: kernel reports {got}, expected {want}")
            for name, accepted in sorted(armcfg.DEFAULTS.items()):
                if name in expected or name not in kernel:
                    continue
                accepted = (accepted,) if isinstance(accepted, str) else accepted
                if kernel[name].lower() not in accepted:
                    problems.append(f"{name}: kernel reports {kernel[name]}, expected the default {accepted[0]}")
            if poller_mode not in ("default", "") and kernel.get("jdk.pollerMode", poller_mode) != poller_mode:
                problems.append(f"jdk.pollerMode: kernel reports {kernel['jdk.pollerMode']}, expected {poller_mode}")
            unchecked = sorted(k for k in kernel if k not in armcfg.DEFAULTS and k not in expected
                               and k != "jdk.pollerMode")
    return {"pass": not problems, "problems": problems, "expected": expected, "echo": echo,
            "kernel_flags": kernel, "unchecked_flags": unchecked}


def parse_scheduler_stats(out):
    """The window's share of the scheduler's counters: end reading minus start reading."""
    start, end = out / "scheduler-stats-start.json", out / "scheduler-stats-end.json"
    if not (start.exists() and end.exists()):
        return {"supported": None, "reason": "no reading at one end of the window"}
    try:
        a, b = json.loads(start.read_text()), json.loads(end.read_text())
    except ValueError:
        return {"supported": None, "reason": "a reading is not JSON"}
    if a.get("unsupported") or b.get("unsupported"):
        return {"supported": False, "reason": "the kernel build has no statsSnapshot()"}
    if a.get("unavailable") or b.get("unavailable"):
        return {"supported": None, "reason": "the endpoint did not answer"}
    text = (out / "load.txt").read_text(errors="replace") if (out / "load.txt").exists() else ""
    m = re.search(r"^\s*(\d+) requests in", text, re.M)
    requests = int(m.group(1)) if m else None
    delta = {k: b[k] - a.get(k, 0) for k in sorted(b) if isinstance(b[k], (int, float))}
    if not delta:
        return {"supported": True, "requests": requests, "delta": {}, "per_request": {},
                "reason": "the counters are off (empty snapshot)"}
    return {"supported": True, "requests": requests, "delta": delta,
            "per_request": {k: round(v / requests, 6) for k, v in delta.items()} if requests else {}}


PERF_THREAD_RE = re.compile(r"^\s*(.+?)-(\d+)\s+(<not counted>|<not supported>|[0-9][0-9,.]*)\s+(\S+)")


def parse_perf_threads(path, names, carrier_re):
    """Context switches and futex calls of each server thread over the window, grouped as pidstat is.

    `perf stat --per-thread` prints one row per thread and event as `comm-tid  count  event`; the
    comma-separated form (`comm-tid,count,,event,...`) is read too. Threads that ended before the
    window did are not listed by perf and are absent here.
    """
    if not path.exists() or "not run" in path.read_text(errors="replace"):
        return None
    events = {"context-switches": "context_switches", "syscalls:sys_enter_futex": "futex_calls"}
    threads = {}
    for line in path.read_text(errors="replace").splitlines():
        m = PERF_THREAD_RE.match(line)
        if m:
            comm, tid, count, event = m.groups()
        else:
            cols = line.split(",")
            m = re.match(r"^\s*(.+)-(\d+)$", cols[0]) if len(cols) >= 4 else None
            if not m:
                continue
            comm, tid, count, event = m.group(1), m.group(2), cols[1], cols[3]
        if event not in events:
            continue
        try:
            value = int(float(count.replace(",", "")))
        except ValueError:
            value = None
        threads.setdefault(tid, {"name": names.get(tid, comm)})[events[event]] = value
    groups = {"carriers": [], "reactors": [], "other": []}
    for tid, rec in threads.items():
        name = rec["name"]
        if is_carrier(name, carrier_re):
            groups["carriers"].append(rec)
        elif name.startswith("carrier/native-tcp/reactor/"):
            groups["reactors"].append(rec)
        else:
            groups["other"].append(rec)
    res = {}
    for g, items in groups.items():
        res[g] = {"count": len(items)}
        for key in events.values():
            vals = [r.get(key) for r in items if r.get(key) is not None]
            res[g][key] = sum(vals) if vals else None
    res["carriers"]["each"] = {r["name"]: {k: r.get(k) for k in events.values()} for r in groups["carriers"]}
    return res


# Gates that decide whether a valid trial may be cited, not whether its measurement is sound.
EVIDENCE_ONLY_GATES = ("harness_clean", "host_shielded", "host_untracked")
# Gates whose failure is a result about the arm, not a fault in the measurement: an arm that cannot
# carry the target rate has been measured, and that is reported. Its latency is not comparable with
# a run that kept up, so it stays out of the percentiles.
OUTCOME_GATES = ("load",)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    for opt in ("arm", "backend", "rate", "connections", "load-threads", "warmup", "warmup-mode", "duration", "think-ms",
                "poller-mode", "carrier-cpus", "server-aux-cpus", "mock-cpus", "load-cpus", "carrier-name-re",
                "perf", "profile", "perf-sched", "pool", "max-connections", "bench-commit", "bench-dirty"):
        ap.add_argument("--" + opt, required=True)
    # Diagnostics the trial ran with, comma-separated; absent in trials recorded before it existed.
    ap.add_argument("--diag", default="none")
    # The pilot cell of arm Dv, whether the scheduler's counters were on, and whether the per-thread
    # perf stat ran; absent in trials recorded before they existed.
    ap.add_argument("--variant", default="")
    ap.add_argument("--stats", default="no")
    ap.add_argument("--perf-threads", default="not_measured")
    a = ap.parse_args()
    out = Path(a.out)

    carrier_cpus = cpu_set(a.carrier_cpus)
    names = load_names(out)
    load = parse_load(out / "load.txt", a.rate)
    gates = {}

    rps = load["requests_per_sec"]
    if rps is None:
        gates["load"] = {"pass": False, "reason": "no Requests/sec in load output"}
    elif a.rate == "max":
        gates["load"] = {"pass": True, "reason": "closed loop"}
    else:
        # wrk2 opens each thread's connections 5 ms apart and divides by the whole duration, so a
        # server that keeps up still reports rate x (1 - ramp / (2 x duration)). The gate compares
        # against that expectation; the latency histogram is unaffected, because wrk2 resets it after
        # its calibration period, which already covers the ramp.
        target = float(a.rate)
        ramp_s = 0.005 * int(a.connections) / int(a.load_threads)
        expected = target * (1.0 - ramp_s / (2.0 * int(a.duration)))
        ratio = rps / expected
        gates["load"] = {"pass": ratio >= 0.99, "achieved_ratio": round(ratio, 4),
                         "raw_ratio": round(rps / target, 4), "connection_ramp_s": round(ramp_s, 3),
                         "reason": f"achieved {rps:.1f} req/s of {expected:.0f} expected at target {target:.0f}"}

    errs = load["socket_errors"] or {}
    err_total = sum(errs.values()) + load["non_2xx"]
    gates["errors"] = {"pass": err_total == 0, "socket_errors": errs, "non_2xx": load["non_2xx"]}

    iso_ok, iso_problems, carriers = isolation_gate(out / "affinity-end.txt", a.arm, carrier_cpus,
                                                     a.carrier_name_re, len(carrier_cpus))
    gates["isolation"] = {"pass": iso_ok, "problems": iso_problems, "carriers": carriers}

    server_log = (out / "server-stdout.txt").read_text(errors="replace") if (out / "server-stdout.txt").exists() else ""
    m = re.search(r"active=([a-z-]+), ffmArmed=(true|false)", server_log)
    transport = f"active={m.group(1)}, ffmArmed={m.group(2)}" if m else "no socket backend line"
    if a.arm in ("B_pin", "B_float"):
        # The pool retires idle workers and starts new ones; each start is a fresh binding, so the
        # count says how often the pinned set changed during the trial.
        gates["isolation"]["worker_starts"] = len(re.findall(r"\[PinnedForkJoinScheduler\] \S+ started", server_log))
        gates["isolation"]["unbound_starts"] = server_log.count("NOT BOUND")
        if gates["isolation"]["unbound_starts"]:
            gates["isolation"]["pass"] = False
            gates["isolation"]["problems"].append("a worker started without a free CPU")
    props_file = out / "arm-properties.txt"
    file_props = armcfg.parse(props_file.read_text(), str(props_file)) if props_file.exists() else None
    arm_config = arm_config_gate(server_log, a.arm, file_props or {}, a.stats == "yes", a.poller_mode)
    if arm_config is not None:
        gates["arm_config"] = arm_config
    continue_file = out / "pinned-continue.txt"
    pinned_continue = continue_file.read_text().strip() if continue_file.exists() else None
    if pinned_continue is not None:
        # The scheduler echoes the mode it parsed; a trial is valid only if it ran the one it was given.
        echoed = re.search(r"\[PinnedForkJoinScheduler\] parallelism=.* continue=(\w+)", server_log)
        gates["pinned_continue"] = {"pass": bool(echoed) and echoed.group(1) == pinned_continue,
                                    "expected": pinned_continue,
                                    "observed": echoed.group(1) if echoed else "no echo"}
    gates["transport"] = {"pass": bool(m) and m.group(1) == "posix-hybrid" and m.group(2) == "true",
                          "observed": transport, "expected": "active=posix-hybrid, ffmArmed=true"}

    perturbers = ([f"async-profiler {a.profile}"] if a.profile != "none" else []) + \
                 (["perf sched record"] if a.perf_sched != "none" else [])
    perturbers += [d for d in a.diag.split(",") if d not in ("none", "") and d not in perturbers]
    gates["unperturbed"] = {"pass": not perturbers,
                            "reason": "no tracer or profiler attached" if not perturbers else ", ".join(perturbers) + " attached"}
    bench_cpus = carrier_cpus | cpu_set(a.mock_cpus) | cpu_set(a.load_cpus)
    host = parse_host(out, bench_cpus, carrier_cpus)
    gates["host_shielded"] = {"pass": host["shielded"], "problems": host["problems"]}
    # With connection tracking loaded every loopback packet passes netfilter, which raises the
    # carriers' kernel time and moves the floating arms' tail; citable trials share the state of a
    # host on which nothing has loaded it since boot. A trial that did not record its modules
    # predates the record and is not judged by it.
    modules = host["state"].get("netfilter_modules")
    gates["host_untracked"] = {
        "pass": modules is None or "nf_conntrack" not in modules.split(),
        "reason": "netfilter modules not recorded" if modules is None
        else "nf_conntrack loaded" if "nf_conntrack" in modules.split() else "nf_conntrack not loaded"}
    gates["harness_clean"] = {"pass": a.bench_dirty == "0",
                              "reason": "harness files committed" if a.bench_dirty == "0"
                              else f"{a.bench_dirty} uncommitted harness file(s)"}

    pilot = "v2 pilot" in a.diag.split(",")
    identity = json.loads((out / "kernel-identity.json").read_text())
    trial = {
        "schema": "loom-carrier-scheduler-trial/1",
        "trial_dir": out.name,
        "arm": a.arm,
        "backend": a.backend,
        "rate": a.rate,
        "connections": int(a.connections),
        "load_threads": int(a.load_threads),
        "warmup_s": int(a.warmup),
        "warmup_mode": a.warmup_mode,
        "duration_s": int(a.duration),
        "think_ms": float(a.think_ms),
        "pool": int(a.pool),
        "max_connections": a.max_connections,
        "poller_mode": a.poller_mode,
        "layout": {"carriers": a.carrier_cpus, "server_aux": a.server_aux_cpus, "mock": a.mock_cpus, "load": a.load_cpus},
        "kernel": identity,
        "bench_commit": a.bench_commit,
        "load": load,
        "pidstat": parse_pidstat(out / "pidstat-server.txt", names, a.carrier_name_re, keep_cswch=pilot),
        "perf_stat": parse_perf(out / "perf-stat.txt") if a.perf == "measured" else None,
        "perf_stat_status": a.perf,
        "profile": a.profile,
        "perf_sched": parse_perf_sched(out, names) if a.perf_sched != "none" else None,
        "diagnostics": [d for d in a.diag.split(",") if d not in ("none", "")],
        "gates": gates,
        "host": host,
        "valid": all(g["pass"] for k, g in gates.items() if k not in EVIDENCE_ONLY_GATES + OUTCOME_GATES),
        "sustained": gates["load"]["pass"],
        "evidence": all(g["pass"] for k, g in gates.items() if k not in OUTCOME_GATES),
    }
    if file_props is not None:
        trial["variant"] = a.variant or None
        trial["locality_properties"] = file_props
        trial["locality_properties_sha256"] = armcfg.digest(file_props)
    if pinned_continue is not None:
        trial["pinned_continue"] = pinned_continue
    if a.stats == "yes":
        trial["scheduler_stats"] = parse_scheduler_stats(out)
    if a.perf_threads == "measured":
        trial["perf_threads"] = parse_perf_threads(out / "perf-threads.txt", names, a.carrier_name_re)
    (out / "trial.json").write_text(json.dumps(trial, indent=2) + "\n")
    print(json.dumps({"trial": out.name, "valid": trial["valid"], "sustained": trial["sustained"],
                      "evidence": trial["evidence"],
                      "rps": rps, "p99_ms": load["percentiles_ms"].get("p99"),
                      "failed_gates": [k for k, g in gates.items() if not g["pass"]]}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
