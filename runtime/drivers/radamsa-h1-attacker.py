#!/usr/bin/env python3
"""
radamsa-h1-attacker.py — fire radamsa-mutated HTTP/1.1 requests at a target.

REQUIRES: `radamsa` in PATH. Install: https://gitlab.com/akihe/radamsa

Each iteration:
  1. Pipe the seed request through `radamsa --seed <fixed>` to get a mutant.
  2. Open a fresh TCP connection.
  3. Send the mutant.
  4. Read response (best-effort) up to --socket-timeout-seconds.
  5. Close.

Output: one JSON line on stdout when the attack window closes:
    {
      "iterations_total": int,
      "crash_count": int,
      "hang_count": int,
      "five_xx_count": int,
      "duration_seconds": float,
      "radamsa_seed": str
    }

Exit code: 0 on clean attack-window close. Non-zero on configuration errors
(radamsa missing, target URL unparseable). NOT on target-side errors.
"""

import argparse
import ipaddress
import json
import shutil
import socket
import subprocess
import sys
import time
from urllib.parse import urlparse


def assert_loopback_or_die(host: str, allow_non_loopback: bool) -> None:
    """Refuse to attack anything that resolves to a non-loopback address.

    These scripts are committed attack tooling. Accepting arbitrary URLs would
    make them trivially weaponizable against unrelated hosts; require an
    explicit opt-in for non-loopback targets so the default cannot be misused.
    """
    if allow_non_loopback:
        return
    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror as e:
        print(f"ERROR: cannot resolve host '{host}': {e}", file=sys.stderr)
        sys.exit(2)
    for info in infos:
        addr = info[4][0]
        try:
            if not ipaddress.ip_address(addr).is_loopback:
                print(
                    f"ERROR: refusing to attack non-loopback host '{host}' "
                    f"(resolved to {addr}). Pass --allow-non-loopback to "
                    f"override (e.g. authorized lab targets).",
                    file=sys.stderr,
                )
                sys.exit(2)
        except ValueError:
            print(f"ERROR: cannot parse resolved address '{addr}'",
                  file=sys.stderr)
            sys.exit(2)


SEED_REQUEST = (
    b"GET /plaintext HTTP/1.1\r\n"
    b"Host: localhost\r\n"
    b"User-Agent: radamsa-h1-attacker\r\n"
    b"\r\n"
)


def mutate(seed_bytes: bytes, seed_value: str) -> bytes:
    proc = subprocess.run(
        ["radamsa", "--seed", seed_value],
        input=seed_bytes, capture_output=True, check=True, timeout=5.0,
    )
    return proc.stdout


def fire_one(host: str, port: int, payload: bytes, timeout: float) -> str:
    """Returns one of: 'response', 'hang', 'crash'."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect((host, port))
        sock.sendall(payload)
        try:
            data = sock.recv(4096)
            sock.close()
            if not data:
                return "crash"
            if data.startswith(b"HTTP/1.") and b" 5" in data[:32]:
                return "5xx"
            return "response"
        except socket.timeout:
            sock.close()
            return "hang"
    except (ConnectionResetError, BrokenPipeError):
        return "crash"
    except OSError:
        return "crash"


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--base-url", required=True)
    p.add_argument("--rps", type=int, default=500)
    p.add_argument("--attack-duration-seconds", type=float, default=120.0)
    p.add_argument("--socket-timeout-seconds", type=float, default=2.0)
    p.add_argument("--radamsa-seed", required=True,
                   help="Fixed seed for radamsa reproducibility")
    p.add_argument("--allow-non-loopback", action="store_true",
                   help="Opt-in: permit a non-loopback target. Default is "
                        "refuse — these scripts are not general-purpose "
                        "attack tools.")
    args = p.parse_args()

    if shutil.which("radamsa") is None:
        print("ERROR: radamsa not in PATH. Install: "
              "https://gitlab.com/akihe/radamsa", file=sys.stderr)
        return 2

    parsed = urlparse(args.base_url)
    if parsed.scheme != "http":
        print(f"ERROR: only plain http supported (got: {parsed.scheme})",
              file=sys.stderr)
        return 2
    host = parsed.hostname
    port = parsed.port or 80
    if host is None:
        print("ERROR: base-url has no hostname", file=sys.stderr)
        return 2
    assert_loopback_or_die(host, args.allow_non_loopback)

    start = time.monotonic()
    deadline = start + args.attack_duration_seconds
    iteration_period = 1.0 / args.rps if args.rps > 0 else 0.0

    iterations = 0
    crashes = 0
    hangs = 0
    five_xx = 0

    while time.monotonic() < deadline:
        loop_start = time.monotonic()
        # Each iteration mutates with a slightly different seed derived from
        # the base seed + iteration number — this keeps the campaign
        # reproducible while still exploring the mutator space.
        mutant_seed = f"{args.radamsa_seed}.{iterations}"
        try:
            payload = mutate(SEED_REQUEST, mutant_seed)
        except subprocess.TimeoutExpired:
            hangs += 1
            iterations += 1
            continue

        outcome = fire_one(host, port, payload,
                           args.socket_timeout_seconds)
        if outcome == "hang":
            hangs += 1
        elif outcome == "crash":
            crashes += 1
        elif outcome == "5xx":
            five_xx += 1

        iterations += 1
        elapsed = time.monotonic() - loop_start
        if iteration_period > elapsed:
            time.sleep(iteration_period - elapsed)

    duration = time.monotonic() - start
    json.dump({
        "iterations_total": iterations,
        "crash_count": crashes,
        "hang_count": hangs,
        "five_xx_count": five_xx,
        "duration_seconds": duration,
        "radamsa_seed": args.radamsa_seed,
    }, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
