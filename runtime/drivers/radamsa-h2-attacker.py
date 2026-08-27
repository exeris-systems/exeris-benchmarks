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
    REJECTED, RESPONSE, MutantPool, assert_loopback_or_die, radamsa_binary,
    run_campaign,
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


# RFC 9113 frame types and flags.
FRAME_DATA = 0x0
FRAME_HEADERS = 0x1
FRAME_RST_STREAM = 0x3
FRAME_SETTINGS = 0x4
FRAME_GOAWAY = 0x7
FRAME_WINDOW_UPDATE = 0x8
FRAME_CONTINUATION = 0x9

FLAG_END_STREAM = 0x1
FLAG_END_HEADERS = 0x4


def is_complete_frame_sequence(payload: bytes) -> bool:
    """Is the target OBLIGED to answer this mutant?

    Two conditions, both required:

      1. the buffer ends exactly on a frame boundary, so the peer is not
         owed further bytes; and
      2. some client-initiated (odd) stream was both fully opened -- HEADERS
         reaching END_HEADERS, possibly via CONTINUATION -- and half-closed
         by END_STREAM. Only then is a response due.

    Condition 2 was missing until 2026-08-26 and frame alignment alone stood
    in for it. That was an HTTP/1 idea in HTTP/2 clothing: on H1 the
    terminating CRLFCRLF really does mean a request was completed, but on H2
    a lone well-formed SETTINGS frame is equally well aligned and obliges the
    server to say nothing at all. Such a mutant timed out at the socket
    deadline and scored `hang` -- against a scenario declaring
    max_hang_count: 0, so a correctly idle server would have failed the run.
    It fired once in a 400-iteration validation campaign.

    Erring the other way is the deliberate choice: a mutant that does open
    and half-close a stream but is semantically nonsense still counts as
    owed, so a genuinely stuck parser is still reported.
    """
    offset = 0
    n = len(payload)
    if n == 0:
        return False
    headers_done: set = set()
    pending_continuation = None
    owed = False
    while offset < n:
        if n - offset < FRAME_HEADER_LEN:
            return False
        length = struct.unpack(">I", b"\x00" + payload[offset:offset + 3])[0]
        ftype = payload[offset + 3]
        flags = payload[offset + 4]
        stream_id = struct.unpack(">I", payload[offset + 5:offset + 9])[0] & 0x7FFFFFFF
        offset += FRAME_HEADER_LEN + length

        if stream_id % 2 == 1:
            if ftype == FRAME_HEADERS:
                if flags & FLAG_END_HEADERS:
                    headers_done.add(stream_id)
                else:
                    pending_continuation = stream_id
            elif ftype == FRAME_CONTINUATION and pending_continuation == stream_id:
                if flags & FLAG_END_HEADERS:
                    headers_done.add(stream_id)
                    pending_continuation = None
            if (flags & FLAG_END_STREAM) and stream_id in headers_done:
                owed = True
    return offset == n and owed


# RFC 9113 s7 error codes, for the GOAWAY histogram.
H2_ERROR_CODES = {
    0x0: "NO_ERROR", 0x1: "PROTOCOL_ERROR", 0x2: "INTERNAL_ERROR",
    0x3: "FLOW_CONTROL_ERROR", 0x4: "SETTINGS_TIMEOUT",
    0x5: "STREAM_CLOSED", 0x6: "FRAME_SIZE_ERROR", 0x7: "REFUSED_STREAM",
    0x8: "CANCEL", 0x9: "COMPRESSION_ERROR", 0xa: "CONNECT_ERROR",
    0xb: "ENHANCE_YOUR_CALM", 0xc: "INADEQUATE_SECURITY",
    0xd: "HTTP_1_1_REQUIRED",
}

# Frames a server emits on its own initiative, independent of the mutant.
# Reading past them is the whole point of this classifier.
H2_UNPROMPTED = {FRAME_SETTINGS, FRAME_WINDOW_UPDATE}


def _read_exactly(sock, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return buf
        buf += chunk
    return buf


def read_outcome_h2(sock, framing_complete: bool):
    """Classify an H2C connection on the first frame that answers the mutant.

    The default HTTP/1 classifier -- "first bytes back means the target
    answered" -- is UNSOUND on HTTP/2 and silently reported a perfect score.
    RFC 9113 s3.4 makes the server's SETTINGS frame the mandatory first thing
    it sends after the preface, so bytes always come back. Measured against
    the kernel on 2026-08-26: an intact preface followed by pure garbage, by a
    single zero byte, and by nothing at all each returned the identical 9-byte
    empty SETTINGS frame. The campaign's `response_count: 60000 / 60000` was
    therefore a count of the target's own handshake and said nothing about any
    mutant.

    So skip the frames a server sends unprompted and decide on the next one:

      GOAWAY / RST_STREAM  the target rejected the mutant, and the error code
                           names the layer that rejected it -- FRAME_SIZE and
                           PROTOCOL come from the framing layer, COMPRESSION
                           from HPACK. Reported as `rejected`, with the code
                           in the detail histogram.
      HEADERS / DATA       the target accepted the mutant and served it.
                           `response`, and here that means something.
      clean close          `rejected` -- dropped without a diagnostic.
      timeout              `hang` if the mutant ended on a frame boundary,
                           else `incomplete-wait`, as for H1.
    """
    while True:
        hdr = _read_exactly(sock, FRAME_HEADER_LEN)
        if len(hdr) < FRAME_HEADER_LEN:
            # Closed, possibly mid-header. Nothing decisive was ever sent.
            return REJECTED if hdr == b"" else (REJECTED, "truncated-frame")
        length = struct.unpack(">I", b"\x00" + hdr[0:3])[0]
        ftype = hdr[3]
        payload = _read_exactly(sock, length) if length else b""
        if len(payload) < length:
            return (REJECTED, "truncated-frame")

        if ftype in H2_UNPROMPTED:
            continue
        if ftype == FRAME_GOAWAY:
            code = (struct.unpack(">I", payload[4:8])[0]
                    if len(payload) >= 8 else None)
            name = H2_ERROR_CODES.get(code, f"UNKNOWN_{code}")
            return (REJECTED, f"GOAWAY:{name}")
        if ftype == FRAME_RST_STREAM:
            code = (struct.unpack(">I", payload[0:4])[0]
                    if len(payload) >= 4 else None)
            name = H2_ERROR_CODES.get(code, f"UNKNOWN_{code}")
            return (REJECTED, f"RST_STREAM:{name}")
        if ftype in (FRAME_HEADERS, FRAME_DATA):
            return (RESPONSE, f"frame:{ftype:#x}")
        return (RESPONSE, f"frame:{ftype:#x}")


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
        preamble=H2C_PREFACE, read_outcome=read_outcome_h2,
    )
    summary["radamsa_seed"] = args.radamsa_seed
    summary["mutant_chunk_size"] = args.mutant_chunk_size
    json.dump(summary, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
