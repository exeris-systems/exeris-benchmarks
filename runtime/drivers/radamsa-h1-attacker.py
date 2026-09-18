#!/usr/bin/env python3
"""
radamsa-h1-attacker.py — fire radamsa-mutated HTTP/1.1 requests at a target.

REQUIRES: `radamsa` on PATH, or RADAMSA_BIN pointing at it.
Install: https://gitlab.com/akihe/radamsa

The attack engine, the outcome taxonomy, the mutant pool and the concurrency
model all live in lib/radamsa_attack.py, shared with the H2 driver. This file
supplies only what is HTTP/1-specific: the seed request and the predicate for
"does this mutant complete a request".

Output: one JSON object on stdout when the attack window closes. See
lib/radamsa_attack.run_campaign for the field list.

Exit code: 0 on clean attack-window close. Non-zero on configuration errors
(radamsa missing, target URL unparseable). NOT on target-side errors.
"""

import argparse
import json
import sys
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from radamsa_attack import (  # noqa: E402
    MutantPool, assert_loopback_or_die, radamsa_binary, run_campaign,
)

SEED_REQUEST = (
    b"GET /plaintext HTTP/1.1\r\n"
    b"Host: localhost\r\n"
    b"User-Agent: radamsa-h1-attacker\r\n"
    b"\r\n"
)


def is_complete_request(payload: bytes) -> bool:
    """Is the target OBLIGED to answer this mutant?

    Header-block termination alone is not the test, even though the seed
    carries no body. radamsa readily grows a `Content-Length:` or a
    `Transfer-Encoding: chunked` out of the header bytes, and a request
    announcing a body it never sends leaves the target correctly waiting for
    the rest -- `incomplete-wait`. Counting it as complete makes the timeout a
    `hang`, and destructive-radamsa-h1 declares max_hang_count: 0, so a
    correctly-behaved server would fail the run.

    The H2 driver had the same defect in frame-shaped clothing (a lone
    well-formed SETTINGS frame is perfectly aligned and obliges the server to
    say nothing) and it fired there, once in 400 validation iterations. These
    two drivers already drifted apart once by fixing the same idea twice, so
    the predicate is corrected on both sides even though it has not yet
    produced a wrong H1 result.

    Still deliberately conservative where the input is ambiguous: a mutant
    with a malformed or contradictory framing header counts as complete,
    because a target is obliged to answer such a request with 400 rather than
    wait on it, and a target that instead goes quiet is a finding.
    """
    idx = payload.find(b"\r\n\r\n")
    if idx < 0:
        return False
    head, body = payload[:idx], payload[idx + 4:]

    lengths, chunked, malformed = [], False, False
    for line in head.split(b"\r\n")[1:]:
        name, _, value = line.partition(b":")
        key = name.strip().lower()
        if key == b"content-length":
            try:
                lengths.append(int(value.strip()))
            except ValueError:
                malformed = True
        elif key == b"transfer-encoding":
            if b"chunked" in value.strip().lower():
                chunked = True

    if malformed or len(set(lengths)) > 1 or (chunked and lengths):
        # Framing the target must reject, not wait on. RFC 9112 s6.1/s6.3.
        return True
    if chunked:
        return body.endswith(b"0\r\n\r\n")
    if lengths:
        return len(body) >= lengths[0]
    return True


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--base-url", required=True)
    p.add_argument("--rps", type=int, default=500)
    p.add_argument("--attack-duration-seconds", type=float, default=120.0)
    p.add_argument("--socket-timeout-seconds", type=float, default=2.0)
    p.add_argument("--radamsa-seed", required=True,
                   help="Fixed seed for radamsa reproducibility")
    p.add_argument("--workers", type=int, default=64,
                   help="Concurrent connections. A timeout costs one worker "
                        "rather than the campaign. Part of the campaign's "
                        "identity — reported in the summary.")
    p.add_argument("--mutant-chunk-size", type=int, default=2048,
                   help="Mutants per radamsa invocation. With the seed, this "
                        "determines the byte stream, so changing it changes "
                        "the campaign.")
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
        print(f"ERROR: only plain http supported (got: {parsed.scheme})",
              file=sys.stderr)
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
        # radamsa's --seed accepts integers only, and rejects anything else
        # with exit 127 -- its own usage-error code, which reads like
        # "command not found" and is not. Fail here with a clear message
        # instead of at the first generation.
        print(f"ERROR: --radamsa-seed must be an integer "
              f"(got: '{args.radamsa_seed}')", file=sys.stderr)
        return 2

    pool = MutantPool(SEED_REQUEST, base_seed, args.mutant_chunk_size, binary)
    summary = run_campaign(
        host=host, port=port, pool=pool, rps=args.rps,
        duration=args.attack_duration_seconds,
        socket_timeout=args.socket_timeout_seconds,
        workers=args.workers, is_complete=is_complete_request,
    )
    summary["radamsa_seed"] = args.radamsa_seed
    summary["mutant_chunk_size"] = args.mutant_chunk_size
    json.dump(summary, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
