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
HPACK Huffman encoding is NOT used (HPACK literal-never-indexed for path,
:method, :scheme, :authority — keeps the seed analyzable).

Output: same JSON shape as radamsa-h1-attacker.py.
"""

import argparse
import json
import shutil
import socket
import struct
import subprocess
import sys
import time
from urllib.parse import urlparse


H2C_PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"


def build_frame(length: int, frame_type: int, flags: int, stream_id: int,
                payload: bytes) -> bytes:
    # 24-bit length, big-endian
    hdr = struct.pack(">I", length)[1:]
    hdr += struct.pack(">BBI", frame_type, flags, stream_id)
    return hdr + payload


def build_seed_post_preface() -> bytes:
    settings = build_frame(0, 0x4, 0x0, 0, b"")
    # Minimal HPACK literal headers (no indexing, no Huffman):
    # :method=GET   — index 2 in static table → 0x82
    # :scheme=http  — index 6 → 0x86
    # :path=/plaintext — literal-no-indexing-indexed-name (index 4 :path)
    #   0x04 (index 4) | 0x00 (literal w/o indexing) -> 0x04, then length-prefixed value
    # :authority=localhost — literal w/o indexing, new name
    method_get = bytes([0x82])
    scheme_http = bytes([0x86])
    path_value = b"/plaintext"
    path_literal = bytes([0x04, len(path_value)]) + path_value
    authority_value = b"localhost"
    authority_literal = (
        bytes([0x01, 0x00 | len(b":authority")]) + b":authority"
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
