#!/usr/bin/env python3
"""
radamsa-h2-attacker.py — fire radamsa-mutated HTTP/2 (H2C cleartext) frames.

REQUIRES: `radamsa` in PATH.

Each iteration:
  1. Open fresh TCP, send the H2C connection preface (NEVER mutated; the
     target rejects the connection otherwise — testing the preface path is
     out of scope here).
  2. Send a radamsa-mutated post-preface stream (SETTINGS + HEADERS + DATA).
  3. Read response (best-effort).
  4. Close.

The seed is a hand-built minimal valid H2C session for GET /plaintext.
HPACK Huffman encoding is NOT used. The header block uses static-table
indexed-name encoding where it exists (:method=GET, :scheme=http, :path
indexed-name) and "literal without indexing, new name" for :authority —
all to keep the seed bytewise analyzable for triage.

Output: same JSON shape as radamsa-h1-attacker.py.
"""

import argparse
import ipaddress
import json
import shutil
import socket
import struct
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


H2C_PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"


def build_frame(length: int, frame_type: int, flags: int, stream_id: int,
                payload: bytes) -> bytes:
    # 24-bit length, big-endian
    hdr = struct.pack(">I", length)[1:]
    hdr += struct.pack(">BBI", frame_type, flags, stream_id)
    return hdr + payload


def build_seed_post_preface() -> bytes:
    settings = build_frame(0, 0x4, 0x0, 0, b"")
    # Minimal HPACK header block (no indexing, no Huffman). RFC 7541 §6.
    # :method=GET   — indexed field, static table 2 → 0x82
    # :scheme=http  — indexed field, static table 6 → 0x86
    # :path=/plaintext — literal w/o indexing, indexed name 4 (:path):
    #   0x04 (prefix 0000 + index 4), then 1-byte length-prefixed value.
    # :authority=localhost — literal w/o indexing, new name:
    #   0x00 (prefix 0000 + index 0 = new name), then length-prefixed name,
    #   then length-prefixed value. (Previous code used 0x01 here, which is
    #   "literal w/o indexing, indexed name 1 (:authority)" — followed by a
    #   name literal, which is malformed by the spec.)
    method_get = bytes([0x82])
    scheme_http = bytes([0x86])
    path_value = b"/plaintext"
    path_literal = bytes([0x04, len(path_value)]) + path_value
    authority_name = b":authority"
    authority_value = b"localhost"
    authority_literal = (
        bytes([0x00])
        + bytes([len(authority_name)]) + authority_name
        + bytes([len(authority_value)]) + authority_value
    )
    hpack = method_get + scheme_http + path_literal + authority_literal
    # END_STREAM (0x1) + END_HEADERS (0x4) = 0x5
    headers_frame = build_frame(len(hpack), 0x1, 0x5, 1, hpack)
    return settings + headers_frame


def mutate(seed_bytes: bytes, seed_value: str) -> bytes:
    proc = subprocess.run(
        ["radamsa", "--seed", seed_value],
        input=seed_bytes, capture_output=True, check=True, timeout=5.0,
    )
    return proc.stdout


def fire_one(host: str, port: int, post_preface: bytes,
             timeout: float) -> str:
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect((host, port))
        sock.sendall(H2C_PREFACE + post_preface)
        try:
            data = sock.recv(4096)
            sock.close()
            if not data:
                return "crash"
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
    p.add_argument("--rps", type=int, default=200)
    p.add_argument("--attack-duration-seconds", type=float, default=120.0)
    p.add_argument("--socket-timeout-seconds", type=float, default=2.0)
    p.add_argument("--radamsa-seed", required=True)
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
        print(f"ERROR: only plain http (H2C) supported", file=sys.stderr)
        return 2
    host = parsed.hostname
    port = parsed.port or 80
    if host is None:
        print("ERROR: base-url has no hostname", file=sys.stderr)
        return 2
    assert_loopback_or_die(host, args.allow_non_loopback)

    seed = build_seed_post_preface()

    start = time.monotonic()
    deadline = start + args.attack_duration_seconds
    iteration_period = 1.0 / args.rps if args.rps > 0 else 0.0

    iterations = 0
    crashes = 0
    hangs = 0

    while time.monotonic() < deadline:
        loop_start = time.monotonic()
        mutant_seed = f"{args.radamsa_seed}.{iterations}"
        try:
            payload = mutate(seed, mutant_seed)
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

        iterations += 1
        elapsed = time.monotonic() - loop_start
        if iteration_period > elapsed:
            time.sleep(iteration_period - elapsed)

    duration = time.monotonic() - start
    json.dump({
        "iterations_total": iterations,
        "crash_count": crashes,
        "hang_count": hangs,
        "five_xx_count": 0,
        "duration_seconds": duration,
        "radamsa_seed": args.radamsa_seed,
    }, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
