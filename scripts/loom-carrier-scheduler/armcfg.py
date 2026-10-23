#!/usr/bin/env python3
"""The scheduler property sets of arms D2 and Dv, and what a trial must show of them.

An arm that runs ExerisCarrierScheduler with properties beyond arm D's takes them from a committed
file, so the set a trial ran with is a reviewed artefact and not a command line:

  arms/D2.properties            arm D2, the property set frozen after the pilot
  arms/pilot/<variant>.properties   arm Dv, one pilot cell per file

A file holds `exeris.locality.<name>=<value>` lines, blank lines and `#` comments. Two kinds of
property stay out of it: `exeris.locality.allVthreads`, which every ExerisCarrierScheduler arm sets
itself, and `exeris.locality.stats`, which is a per-trial recorder (run-trial.sh --stats).

A trial records the set it ran with (`locality_properties`) and its digest
(`locality_properties_sha256`). The digest is over the sorted `name=value` lines, so comment and
line order in a file do not change it. The summarisers refuse to pool trials whose digests differ.

CLI (used by the shell scripts):
  armcfg.py jvm-args  <arm> [variant]   one -Dname=value per line
  armcfg.py normalise <arm> [variant]   the sorted name=value lines, as a trial records them
  armcfg.py campaign-json <arm>...      {"<arm>": {"properties": {...}, "sha256": "..."}}
"""
import hashlib
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ARMS_DIR = HERE / "arms"
PREFIX = "exeris.locality."
# Arms that run ExerisCarrierScheduler; each sets this property itself.
SCHEDULER_ARMS = ("C_iso", "D", "D2", "Dv")
BASE_LOCALITY = {arm: {PREFIX + "allVthreads": "true"} for arm in SCHEDULER_ARMS}
# Arms whose properties come from a file.
FILE_ARMS = ("D2", "Dv")
FORBIDDEN_IN_FILE = (PREFIX + "allVthreads", PREFIX + "stats")

# The effective value of every flag when its property is unset, as LocalityFlags defines them and
# the flags line prints them (compared case-insensitively; a tuple lists every accepted spelling).
# A flag missing here is reported but never fails a trial: only a flag the harness knows can be
# judged.
DEFAULTS = {
    PREFIX + "allVthreads": "false",
    PREFIX + "carrierResolve": "scope",
    PREFIX + "factory.preferredCarrier": "false",
    PREFIX + "idle.spinNs": "0",
    PREFIX + "lifoSlot": "false",
    PREFIX + "place": "current",
    PREFIX + "poller.priority": "fifo",
    PREFIX + "poller.route": "name",
    PREFIX + "queue": "clq",
    PREFIX + "selfWakeup": "false",
    PREFIX + "stats": "false",
    PREFIX + "steal": "false",
    PREFIX + "steal.batch": ("half", "0"),
    PREFIX + "timer.count": "false",
    PREFIX + "wakeup": "getandset",
    PREFIX + "yield.checkEvery": "1",
    PREFIX + "yield.us": "50",
}


def arm_file(arm, variant=None, arms_dir=ARMS_DIR):
    """The property file of an arm, or None for an arm that takes none."""
    if arm == "D2":
        return Path(arms_dir) / "D2.properties"
    if arm == "Dv":
        if not variant:
            raise SystemExit("armcfg: arm Dv needs --variant <stem>")
        return Path(arms_dir) / "pilot" / f"{variant}.properties"
    if variant:
        raise SystemExit(f"armcfg: --variant applies to arm Dv only, not {arm}")
    return None


def parse(text, origin="properties"):
    props = {}
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise SystemExit(f"armcfg: {origin}:{n}: expected name=value, got '{line}'")
        key, value = (part.strip() for part in line.split("=", 1))
        if not key.startswith(PREFIX):
            raise SystemExit(f"armcfg: {origin}:{n}: '{key}' is not an {PREFIX}* property")
        if key in FORBIDDEN_IN_FILE:
            raise SystemExit(f"armcfg: {origin}:{n}: '{key}' is not set from a file")
        if not value or any(c.isspace() for c in value):
            raise SystemExit(f"armcfg: {origin}:{n}: '{key}' needs a value without whitespace")
        if key in props:
            raise SystemExit(f"armcfg: {origin}:{n}: '{key}' is set twice")
        props[key] = value
    return dict(sorted(props.items()))


def load(arm, variant=None, arms_dir=ARMS_DIR):
    """The properties an arm takes from its file; empty for arms without one."""
    path = arm_file(arm, variant, arms_dir)
    if path is None:
        return {}
    if not path.is_file():
        raise SystemExit(f"armcfg: no property file {path} for arm {arm}"
                         + (" (frozen after the pilot, not written yet)" if arm == "D2" else ""))
    return parse(path.read_text(), str(path))


def normalise(props):
    return "".join(f"{k}={v}\n" for k, v in sorted(props.items()))


def digest(props):
    return hashlib.sha256(normalise(props).encode()).hexdigest()


def expected_echo(arm, props, stats=False):
    """Every exeris.locality.* system property the server JVM is started with."""
    echo = dict(BASE_LOCALITY.get(arm, {}))
    echo.update(props)
    if stats:
        echo[PREFIX + "stats"] = "true"
    return dict(sorted(echo.items()))


def check_hashes(trials, label, campaign=None):
    """Refuse a cell whose trials ran different property sets, or a set other than the campaign's."""
    seen = {t.get("locality_properties_sha256") for t in trials}
    if len(seen) > 1:
        raise SystemExit(f"{label}: trials ran different property sets "
                         f"({', '.join(sorted(str(s)[:12] for s in seen))}); refusing to pool them")
    if campaign:
        recorded = (campaign.get("arm_properties") or {}).get(trials[0]["arm"] if trials else "")
        value = next(iter(seen), None)
        if recorded and value is not None and recorded.get("sha256") != value:
            raise SystemExit(f"{label}: property set {str(value)[:12]} differs from the campaign's "
                             f"{recorded.get('sha256', '')[:12]}; refusing to pool it")


def main(argv):
    if len(argv) < 2:
        raise SystemExit(__doc__)
    cmd = argv[1]
    if cmd in ("jvm-args", "normalise"):
        arm = argv[2]
        props = load(arm, argv[3] if len(argv) > 3 else None)
        sys.stdout.write("".join(f"-D{k}={v}\n" for k, v in props.items()) if cmd == "jvm-args" else normalise(props))
    elif cmd == "campaign-json":
        out = {}
        for arm in argv[2:]:
            if arm == "Dv":
                raise SystemExit("armcfg: arm Dv is a pilot arm and does not run in a campaign")
            props = load(arm)
            if arm in FILE_ARMS or props:
                out[arm] = {"properties": props, "sha256": digest(props)}
        print(json.dumps(out))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
