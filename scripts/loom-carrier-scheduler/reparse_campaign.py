#!/usr/bin/env python3
"""Re-derive every trial.json of a campaign with the current parse_trial.py, then re-summarise.

The raw outputs a trial leaves on disk are the record; trial.json is derived from them. This
rebuilds it from the parameters the existing trial.json recorded, so a parser fix reaches a
campaign that has already run without re-running it. The harness commit and its clean/dirty state
are carried over from the original record: they describe the run, not the parser.
"""
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CARRIER_RE = {
    "A_iso": r"^ForkJoinPool-[0-9]+-worker-[0-9]+$",
    "B_pin": r"^spi-fjp-worker-[0-9]+$",
    "B_float": r"^spi-fjp-worker-[0-9]+$",
    "C_iso": r"^exeris-carrier-[0-9]+$",
    "D": r"^exeris-carrier-[0-9]+$",
}


def argv_for(t, trial_dir):
    layout = t["layout"]
    harness = t["gates"].get("harness_clean", {})
    dirty = "0" if harness.get("pass") else "1"
    return [
        sys.executable, str(HERE / "parse_trial.py"), str(trial_dir),
        "--arm", t["arm"], "--backend", t["backend"], "--rate", str(t["rate"]),
        "--connections", str(t["connections"]), "--load-threads", str(t["load_threads"]),
        "--warmup", str(t["warmup_s"]), "--warmup-mode", t.get("warmup_mode", "closed"),
        "--duration", str(t["duration_s"]), "--think-ms", str(t["think_ms"]),
        "--poller-mode", str(t["poller_mode"]),
        "--carrier-cpus", layout["carriers"], "--server-aux-cpus", layout["server_aux"],
        "--mock-cpus", layout["mock"], "--load-cpus", layout["load"],
        "--carrier-name-re", CARRIER_RE[t["arm"]],
        "--perf", t.get("perf_stat_status", "not_measured"), "--profile", t.get("profile", "none"),
        "--perf-sched", "recorded" if t.get("perf_sched") else "none",
        "--pool", str(t.get("pool", 128)), "--max-connections", str(t.get("max_connections", "default")),
        "--bench-commit", t["bench_commit"], "--bench-dirty", dirty,
        # A trial that ran with a recorder or marker stays perturbed when its record is rebuilt.
        "--diag", ",".join(t.get("diagnostics", [])) or "none",
    ]


def main(campaign_dir):
    root = Path(campaign_dir)
    changed = 0
    for path in sorted(root.glob("*/trial.json")):
        before = json.loads(path.read_text())
        proc = subprocess.run(argv_for(before, path.parent), capture_output=True, text=True)
        if proc.returncode != 0:
            print(f"{path.parent.name}: parse failed: {proc.stderr.strip()[-300:]}", file=sys.stderr)
            path.write_text(json.dumps(before, indent=2) + "\n")
            continue
        after = json.loads(path.read_text())
        if (before["valid"], before.get("sustained")) != (after["valid"], after.get("sustained")):
            changed += 1
            print(f"{path.parent.name}: valid {before['valid']} -> {after['valid']}")
    subprocess.run([sys.executable, str(HERE / "summarize.py"), str(root)], check=True)
    print(f"{changed} trial(s) changed validity")


if __name__ == "__main__":
    main(sys.argv[1])
