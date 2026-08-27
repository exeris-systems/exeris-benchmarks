#!/usr/bin/env python3
"""
radamsa-h2-attacker.py — fire radamsa-mutated HTTP/2 frames at an H2C target.

REQUIRES: `radamsa` on PATH, or RADAMSA_BIN pointing at it.
Install: https://gitlab.com/akihe/radamsa

The H2C connection preface is sent INTACT on every connection; only the
post-preface frame bytes (SETTINGS + HEADERS) are mutated. A mutated preface
would just be a TCP-level garbage test and would never reach the frame parser
or the HPACK decoder, which are what this scenario is about.

The attack engine, the outcome taxonomy, the mutant pool and the concurrency
model live in lib/radamsa_attack.py, shared with the H1 driver. Until
2026-08-26 this file was an unrun copy of the H1 design and still carried
every defect #29 fixed there, plus two of its own:

  * the per-iteration seed was f"{seed}.{i}" -- a dotted string radamsa
    rejects with exit 127, so the campaign died on iteration 1. Its H1 twin
    is why the H1 driver had never run either.
  * an empty response, a reset, a broken pipe and ANY OSError all returned
    "crash", so a target correctly closing on a malformed frame would have
    been reported as a crash -- and connect() failure, the one outcome that
    really does mean the listener is gone, was indistinguishable from it.
  * a radamsa generation timeout was charged to hang_count, i.e. an
    attacker-side fault reported as a target-side one.
  * the summary carried no rejected/response counts at all, so the runner's
    `notes` field had nothing to disclose.

Output: one JSON object on stdout when the attack window closes.
Exit code: 0 on clean close; non-zero on configuration errors only.
"""

import argparse
import json
import struct
import sys
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from radamsa_attack import (  # noqa: E402
    MutantPool, assert_loopback_or_die, radamsa_binary, run_campaign,
)

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


FRAME_HEADER_LEN = 9


def is_complete_frame_sequence(payload: bytes) -> bool:
    """Does this mutant end on a frame boundary?

    Walks the 9-byte headers and their declared lengths. True only when the
    last frame ends exactly at the end of the buffer -- i.e. the peer is not
    owed further bytes. A truncated final frame leaves the target correctly
    waiting, which is `incomplete-wait`, not a hang.

    Frame-level completeness is the strongest predicate available without
    modelling stream state; a well-framed but semantically incomplete
    exchange (HEADERS without END_HEADERS, say) counts as complete here, so
    the classification errs toward reporting a candidate signal rather than
    suppressing one.
    """
    offset = 0
    n = len(payload)
    if n == 0:
        return False
    while offset < n:
        if n - offset < FRAME_HEADER_LEN:
            return False
        length = struct.unpack(">I", b"\x00" + payload[offset:offset + 3])[0]
        offset += FRAME_HEADER_LEN + length
    return offset == n


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--base-url", required=True)
    p.add_argument("--rps", type=int, default=200)
    p.add_argument("--attack-duration-seconds", type=float, default=120.0)
    p.add_argument("--socket-timeout-seconds", type=float, default=2.0)
    p.add_argument("--radamsa-seed", required=True)
    p.add_argument("--workers", type=int, default=64,
                   help="Concurrent connections. Part of the campaign's "
                        "identity — reported in the summary.")
    p.add_argument("--mutant-chunk-size", type=int, default=2048,
                   help="Mutants per radamsa invocation. With the seed, this "
                        "determines the byte stream.")
    p.add_argument("--allow-non-loopback", action="store_true",
                   help="Opt-in: permit a non-loopback target. Default is "
                        "refuse — these scripts are not general-purpose "
                        "attack tools.")
    args = p.parse_args()

    binary = radamsa_binary()
    if binary is None:
        print("ERROR: radamsa not found. Set RADAMSA_BIN or add it to PATH. "
              "Install: https://gitlab.com/akihe/radamsa", file=sys.stderr)
        return 2

    parsed = urlparse(args.base_url)
    if parsed.scheme != "http":
        print("ERROR: only plain http (H2C) supported", file=sys.stderr)
        return 2
    host = parsed.hostname
    port = parsed.port or 80
    if host is None:
        print("ERROR: base-url has no hostname", file=sys.stderr)
        return 2
    assert_loopback_or_die(host, args.allow_non_loopback)

    try:
        base_seed = int(args.radamsa_seed)
    except ValueError:
        print(f"ERROR: --radamsa-seed must be an integer "
              f"(got: '{args.radamsa_seed}')", file=sys.stderr)
        return 2

    pool = MutantPool(build_seed_post_preface(), base_seed,
                      args.mutant_chunk_size, binary)
    summary = run_campaign(
        host=host, port=port, pool=pool, rps=args.rps,
        duration=args.attack_duration_seconds,
        socket_timeout=args.socket_timeout_seconds,
        workers=args.workers, is_complete=is_complete_frame_sequence,
        preamble=H2C_PREFACE,
    )
    summary["radamsa_seed"] = args.radamsa_seed
    summary["mutant_chunk_size"] = args.mutant_chunk_size
    json.dump(summary, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
