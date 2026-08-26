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
    """Classify ONE attack outcome from the target's point of view.

    The original taxonomy returned 'crash' for an empty response, for
    ConnectionReset/BrokenPipe, and for any OSError -- i.e. it reported the
    ATTACKER's socket outcome as a target crash. Measured against a healthy
    target: 9 of 40 mutations produced a close-without-response and 8 timed out,
    while the target answered /health in 7 ms throughout and its log carried only
    whitelisted Http1ParseException. Closing the connection on an unparseable
    request is specified behaviour (RFC 9112 §2.2), not a crash, and reporting it
    as one made the scenario classify a correct rejection as a finding.

    The distinction that matters is WHERE the failure happens:

      connect() fails      -> the listener is gone. Real signal.
      fails after connect  -> the server closed on bad input. Expected.

    Returns: 'refused' | 'rejected' | 'timeout' | '5xx' | 'response'
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        try:
            sock.connect((host, port))
        except OSError:
            # No listener, backlog exhausted, or the process is gone.
            return "refused"
        try:
            sock.sendall(payload)
            data = sock.recv(4096)
            if not data:
                return "rejected"
            if data.startswith(b"HTTP/1.") and b" 5" in data[:32]:
                return "5xx"
            return "response"
        except socket.timeout:
            return "timeout"
        except (ConnectionResetError, BrokenPipeError):
            return "rejected"
        except OSError:
            return "rejected"
    finally:
        try:
            sock.close()
        except OSError:
            pass


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
    rejected = 0
    responses = 0
    hangs = 0
    five_xx = 0

    while time.monotonic() < deadline:
        loop_start = time.monotonic()
        # Each iteration mutates with a slightly different seed derived from
        # the base seed + iteration number — this keeps the campaign
        # reproducible while still exploring the mutator space.
        # radamsa's --seed accepts integers only. This was f"{seed}.{iterations}", a dotted
        # string radamsa rejects with "The argument '--seed' did not accept '424242.1'" and
        # exit 127 -- which reads like "command not found" and is not: it is radamsa's own
        # usage-error code. The driver aborted on the first iteration, so it had never run.
        # The mix keeps per-iteration seeds deterministic (same base + same index -> same
        # bytes, which is what --radamsa-seed exists to guarantee) while decorrelating
        # neighbouring campaigns instead of merely offsetting them by one.
        mutant_seed = str((int(args.radamsa_seed) * 1_000_003 + iterations) % (2**31 - 1))
        try:
            payload = mutate(SEED_REQUEST, mutant_seed)
        except subprocess.TimeoutExpired:
            hangs += 1
            iterations += 1
            continue

        outcome = fire_one(host, port, payload,
                           args.socket_timeout_seconds)
        if outcome == "timeout":
            hangs += 1
        elif outcome == "refused":
            crashes += 1
        elif outcome == "rejected":
            rejected += 1
        elif outcome == "5xx":
            five_xx += 1
        else:
            responses += 1

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
        "rejected_count": rejected,
        "response_count": responses,
        "duration_seconds": duration,
        "radamsa_seed": args.radamsa_seed,
    }, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
