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
    """Does this mutant terminate an HTTP/1 request?

    Header-block termination is the test, because the seed carries no body.
    A mutant that grew a Content-Length larger than its body counts as
    complete here and would be classified `hang` on a timeout rather than
    `incomplete-wait`. That is the conservative direction: it can produce a
    candidate signal to investigate, never suppress one.
    """
    return b"\r\n\r\n" in payload


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
