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
    m = re.search(r"Non-2xx or 3xx responses:\s+(\d+)", text)
    res["non_2xx"] = int(m.group(1)) if m else 0
    return res


def load_thread_map(path):
    names = {}
    if path.exists():
        for line in path.read_text().splitlines():
            if "\t" in line:
                tid, name = line.split("\t", 1)
                names[tid] = name
    return names


def parse_pidstat(path, names, carrier_re):
    """Average rows per thread, from both the -u and the -w report."""
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
        if re.match(carrier_re, name):
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
    return {"state": state, "shielded": not problems, "problems": problems,
            "interrupts_on_carrier_cpus_during_window": irq}


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
        if re.match(carrier_re, name):
            carriers[name] = sorted(cpus)
            if arm == "D":
                if len(cpus) != 1 or not cpus <= carrier_cpus:
                    problems.append(f"{name} allowed {allowed}, expected one CPU of {sorted(carrier_cpus)}")
            elif cpus != carrier_cpus:
                problems.append(f"{name} allowed {allowed}, expected {sorted(carrier_cpus)}")
        elif cpus & carrier_cpus:
            problems.append(f"non-carrier {name} (tid {tid}) may run on carrier CPUs: {allowed}")
    if len(carriers) != expected_carriers:
        problems.append(f"{len(carriers)} carrier threads, expected {expected_carriers}")
    if arm == "D":
        pinned = [c[0] for c in carriers.values() if len(c) == 1]
        if len(set(pinned)) != len(pinned):
            problems.append("two carriers pinned to the same CPU")
    return not problems, problems, carriers


# Gates that decide whether a valid trial may be cited, not whether its measurement is sound.
EVIDENCE_ONLY_GATES = ("harness_clean", "host_shielded")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    for opt in ("arm", "backend", "rate", "connections", "load-threads", "warmup", "duration", "think-ms",
                "poller-mode", "carrier-cpus", "server-aux-cpus", "mock-cpus", "load-cpus", "carrier-name-re",
                "perf", "profile", "perf-sched", "pool", "bench-commit", "bench-dirty"):
        ap.add_argument("--" + opt, required=True)
    a = ap.parse_args()
    out = Path(a.out)

    carrier_cpus = cpu_set(a.carrier_cpus)
    names = load_thread_map(out / "threads.txt")
    load = parse_load(out / "load.txt", a.rate)
    gates = {}

    rps = load["requests_per_sec"]
    if rps is None:
        gates["load"] = {"pass": False, "reason": "no Requests/sec in load output"}
    elif a.rate == "max":
        gates["load"] = {"pass": True, "reason": "closed loop"}
    else:
        target = float(a.rate)
        ratio = rps / target
        gates["load"] = {"pass": ratio >= 0.99, "achieved_ratio": round(ratio, 4),
                         "reason": f"achieved {rps:.1f} of {target:.0f} req/s"}

    errs = load["socket_errors"] or {}
    err_total = sum(errs.values()) + load["non_2xx"]
    gates["errors"] = {"pass": err_total == 0, "socket_errors": errs, "non_2xx": load["non_2xx"]}

    iso_ok, iso_problems, carriers = isolation_gate(out / "affinity-end.txt", a.arm, carrier_cpus,
                                                     a.carrier_name_re, len(carrier_cpus))
    gates["isolation"] = {"pass": iso_ok, "problems": iso_problems, "carriers": carriers}

    server_log = (out / "server-stdout.txt").read_text(errors="replace") if (out / "server-stdout.txt").exists() else ""
    m = re.search(r"active=([a-z-]+), ffmArmed=(true|false)", server_log)
    transport = f"active={m.group(1)}, ffmArmed={m.group(2)}" if m else "no socket backend line"
    gates["transport"] = {"pass": bool(m) and m.group(1) == "posix-hybrid" and m.group(2) == "true",
                          "observed": transport, "expected": "active=posix-hybrid, ffmArmed=true"}

    perturbers = ([f"async-profiler {a.profile}"] if a.profile != "none" else []) + \
                 (["perf sched record"] if a.perf_sched != "none" else [])
    gates["unperturbed"] = {"pass": not perturbers,
                            "reason": "no tracer or profiler attached" if not perturbers else ", ".join(perturbers) + " attached"}
    bench_cpus = carrier_cpus | cpu_set(a.mock_cpus) | cpu_set(a.load_cpus)
    host = parse_host(out, bench_cpus, carrier_cpus)
    gates["host_shielded"] = {"pass": host["shielded"], "problems": host["problems"]}
    gates["harness_clean"] = {"pass": a.bench_dirty == "0",
                              "reason": "harness files committed" if a.bench_dirty == "0"
                              else f"{a.bench_dirty} uncommitted harness file(s)"}

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
        "duration_s": int(a.duration),
        "think_ms": float(a.think_ms),
        "pool": int(a.pool),
        "poller_mode": a.poller_mode,
        "layout": {"carriers": a.carrier_cpus, "server_aux": a.server_aux_cpus, "mock": a.mock_cpus, "load": a.load_cpus},
        "kernel": identity,
        "bench_commit": a.bench_commit,
        "load": load,
        "pidstat": parse_pidstat(out / "pidstat-server.txt", names, a.carrier_name_re),
        "perf_stat": parse_perf(out / "perf-stat.txt") if a.perf == "measured" else None,
        "perf_stat_status": a.perf,
        "profile": a.profile,
        "perf_sched": parse_perf_sched(out, names) if a.perf_sched != "none" else None,
        "gates": gates,
        "host": host,
        "valid": all(g["pass"] for k, g in gates.items() if k not in EVIDENCE_ONLY_GATES),
        "evidence": all(g["pass"] for g in gates.values()),
    }
    (out / "trial.json").write_text(json.dumps(trial, indent=2) + "\n")
    print(json.dumps({"trial": out.name, "valid": trial["valid"], "evidence": trial["evidence"],
                      "rps": rps, "p99_ms": load["percentiles_ms"].get("p99"),
                      "failed_gates": [k for k, g in gates.items() if not g["pass"]]}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
