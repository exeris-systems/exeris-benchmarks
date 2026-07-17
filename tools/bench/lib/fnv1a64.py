#!/usr/bin/env python3
"""Deterministic decline oracle for e2e-shop-order-saga (CONTRACT-v2 section 4.1).

Single source of truth for the expected-compensation count used by the
harness correctness gate. Every stack MUST implement the identical rule;
this helper regenerates the client-side orderId population and applies it.

Normative constants (identical in every stack -- deviation is a correctness bug):
  stableHash64(s) = FNV-1a 64-bit over the UTF-8 bytes of s
    offset_basis = 0xcbf29ce484222325
    prime        = 0x100000001b3
    unsigned 64-bit arithmetic (Python: mask to 64 bits per step)
  decline(orderId) := stableHash64(orderId) mod 1000 < 30
    (mod on the UNSIGNED interpretation; Java: Long.remainderUnsigned(h, 1000))
  -> exactly 3.0% of a deterministic orderId population.

orderId derivation (MUST stay in lockstep with generateOrderId() in
scenarios/e2e-shop-order-saga/k6.js):
    `${ORDER_SEED}-${exec.scenario.name}-i${exec.scenario.iterationInTest}`
i.e. format template "{seed}-{scenario}-i{index}" with default seed
"exeris-saga-v2" (K6_ORDER_SEED). exec.scenario.iterationInTest is a
zero-based dense PER-SCENARIO index, so the issued population is the union
of one dense 0..N-1 sequence per k6 scenario (warmup/measurement/cooldown)
-- a single global count is NOT enough to regenerate it; pass per-scenario
counts via --counts. Regeneration assumes every started iteration issued an
order (dense index set); if any iteration aborts before order creation the
issued set is no longer dense and count-based regeneration diverges from
the real population; pass the actual ids via --ids-file in that case.

Usage:
  fnv1a64.py --counts warmup=240,measurement=540,cooldown=90 \
             [--seed S] [--format TPL] [--list] [--json]
  fnv1a64.py --count <n> --scenario <name> [--seed S] [--format TPL] [--list] [--json]
  fnv1a64.py --ids-file <path> [--list] [--json]
  fnv1a64.py --self-test

Output:
  default    : expected_declines count (single integer) on stdout
  --list     : declined orderIds, one per line, instead of the count
  --json     : JSON object (count, params, per-population breakdown, and
               declined_ids when --list)
"""

import argparse
import json
import re
import sys

FNV_OFFSET_BASIS = 0xCBF29CE484222325
FNV_PRIME = 0x100000001B3
MASK64 = 0xFFFFFFFFFFFFFFFF
DECLINE_MODULUS = 1000
DECLINE_THRESHOLD = 30

# Must match the orderId derivation in scenarios/e2e-shop-order-saga/k6.js
# (generateOrderId: `${ORDER_SEED}-${exec.scenario.name}-i${iterationInTest}`,
# ORDER_SEED default 'exeris-saga-v2'). Keep the two in lockstep.
DEFAULT_ORDER_ID_FORMAT = "{seed}-{scenario}-i{index}"
DEFAULT_ORDER_SEED = "exeris-saga-v2"


def fnv1a64(value: str) -> int:
    """FNV-1a 64-bit hash of the UTF-8 bytes of value (unsigned)."""
    h = FNV_OFFSET_BASIS
    for byte in value.encode("utf-8"):
        h ^= byte
        h = (h * FNV_PRIME) & MASK64
    return h


def decline(order_id: str) -> bool:
    """CONTRACT-v2 section 4.1 terminal-decline predicate."""
    return fnv1a64(order_id) % DECLINE_MODULUS < DECLINE_THRESHOLD


def generate_order_ids(seed: str, scenario: str, count: int, fmt: str):
    for index in range(count):
        yield fmt.format(seed=seed, scenario=scenario, index=index)


# The scenario name is hashed verbatim inside every orderId; whitespace or
# control characters (e.g. a stray CR from a CRLF-emitting pipeline) would
# silently change the hashes and corrupt the exact oracle. Fail loudly instead.
_SCENARIO_NAME_RE = re.compile(r"^[^\s\x00-\x1f\x7f]+$")


def validate_scenario_name(scenario: str) -> str:
    if not _SCENARIO_NAME_RE.match(scenario):
        raise ValueError(
            "scenario name %r contains whitespace or control characters; "
            "it is hashed verbatim inside every orderId, so this would "
            "silently corrupt the exact oracle" % scenario
        )
    return scenario


def parse_counts(spec: str):
    """Parse 'warmup=240,measurement=540,...' into [(scenario, count), ...]."""
    populations = []
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        scenario, sep, raw_count = part.partition("=")
        if not sep or not scenario:
            raise ValueError("malformed --counts entry: %r (want scenario=count)" % part)
        validate_scenario_name(scenario)
        try:
            count = int(raw_count)
        except ValueError:
            raise ValueError("non-integer count in --counts entry: %r" % part)
        if count < 0:
            raise ValueError("negative count in --counts entry: %r" % part)
        populations.append((scenario, count))
    if not populations:
        raise ValueError("--counts is empty")
    return populations


def self_test() -> int:
    failures = 0
    # Canonical FNV-1a 64 test vectors (Fowler/Noll/Vo reference implementation).
    vectors = {
        "": 0xCBF29CE484222325,
        "a": 0xAF63DC4C8601EC8C,
        "foobar": 0x85944171F73967E8,
    }
    for text, expected in vectors.items():
        actual = fnv1a64(text)
        if actual != expected:
            print(
                "self-test FAIL: fnv1a64(%r) = 0x%016x, expected 0x%016x"
                % (text, actual, expected),
                file=sys.stderr,
            )
            failures += 1
    # Lockstep guard: the default template must render the exact orderId shape
    # produced by generateOrderId() in scenarios/e2e-shop-order-saga/k6.js.
    rendered = DEFAULT_ORDER_ID_FORMAT.format(
        seed=DEFAULT_ORDER_SEED, scenario="measurement", index=42
    )
    expected_id = "exeris-saga-v2-measurement-i42"
    if rendered != expected_id:
        print(
            "self-test FAIL: default orderId template rendered %r, expected %r"
            % (rendered, expected_id),
            file=sys.stderr,
        )
        failures += 1
    if failures:
        return 1
    print("self-test OK: %d hash vectors + orderId template lockstep" % len(vectors))
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="FNV-1a 64-bit deterministic decline oracle (CONTRACT-v2 section 4.1)"
    )
    parser.add_argument("--seed", default=DEFAULT_ORDER_SEED,
                        help="order seed (K6_ORDER_SEED; default: %(default)s)")
    parser.add_argument("--counts", default=None,
                        help="per-scenario issued counts, e.g. "
                             "'warmup=240,measurement=540,cooldown=90'; each scenario "
                             "regenerates its dense index sequence 0..count-1")
    parser.add_argument("--count", type=int, default=None,
                        help="issued order count for a SINGLE population; "
                             "requires --scenario when the format uses {scenario}")
    parser.add_argument("--scenario", default=None,
                        help="scenario name for --count mode (k6 exec.scenario.name)")
    parser.add_argument("--format", dest="fmt", default=DEFAULT_ORDER_ID_FORMAT,
                        help="orderId template with {seed}, {scenario} and {index} "
                             "placeholders (default: %(default)s)")
    parser.add_argument("--ids-file", default=None,
                        help="file with actual issued orderIds, one per line "
                             "(overrides --seed/--counts regeneration)")
    parser.add_argument("--list", action="store_true",
                        help="emit the declined orderId list instead of the count")
    parser.add_argument("--json", action="store_true",
                        help="emit a JSON object instead of plain text")
    parser.add_argument("--self-test", action="store_true",
                        help="verify FNV-1a 64 against canonical vectors and exit")
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()

    populations = None  # [(scenario, [order_ids...])] for the JSON breakdown
    if args.ids_file is not None:
        try:
            with open(args.ids_file, "r", encoding="utf-8") as handle:
                order_ids = [line.strip() for line in handle if line.strip()]
        except OSError as exc:
            print("error: cannot read --ids-file: %s" % exc, file=sys.stderr)
            return 2
        population_source = "ids_file"
        issued = len(order_ids)
    elif args.counts is not None:
        if args.count is not None:
            print("error: --counts and --count are mutually exclusive", file=sys.stderr)
            return 2
        try:
            pairs = parse_counts(args.counts)
        except ValueError as exc:
            print("error: %s" % exc, file=sys.stderr)
            return 2
        populations = [
            (scenario, list(generate_order_ids(args.seed, scenario, count, args.fmt)))
            for scenario, count in pairs
        ]
        order_ids = [oid for _, ids in populations for oid in ids]
        population_source = "regenerated"
        issued = len(order_ids)
    elif args.count is not None:
        if args.count < 0:
            print("error: --count must be >= 0", file=sys.stderr)
            return 2
        if args.scenario is None and "{scenario}" in args.fmt:
            print("error: --count requires --scenario (the orderId format embeds "
                  "the k6 scenario name)", file=sys.stderr)
            return 2
        if args.scenario is not None:
            try:
                validate_scenario_name(args.scenario)
            except ValueError as exc:
                print("error: %s" % exc, file=sys.stderr)
                return 2
        scenario = args.scenario or ""
        populations = [
            (scenario, list(generate_order_ids(args.seed, scenario, args.count, args.fmt)))
        ]
        order_ids = populations[0][1]
        population_source = "regenerated"
        issued = args.count
    else:
        parser.print_usage(sys.stderr)
        print("error: one of --counts, --count or --ids-file is required", file=sys.stderr)
        return 2

    declined_ids = [oid for oid in order_ids if decline(oid)]
    expected_declines = len(declined_ids)

    if args.json:
        payload = {
            "expected_declines": expected_declines,
            "issued": issued,
            "population": population_source,
            "seed": args.seed if population_source == "regenerated" else None,
            "order_id_format": args.fmt if population_source == "regenerated" else None,
            "decline_rule": "fnv1a64(orderId) mod %d < %d"
                            % (DECLINE_MODULUS, DECLINE_THRESHOLD),
        }
        if populations is not None:
            payload["populations"] = [
                {
                    "scenario": scenario,
                    "count": len(ids),
                    "declines": sum(1 for oid in ids if decline(oid)),
                }
                for scenario, ids in populations
            ]
        if args.list:
            payload["declined_ids"] = declined_ids
        json.dump(payload, sys.stdout, indent=2)
        sys.stdout.write("\n")
    elif args.list:
        for oid in declined_ids:
            print(oid)
    else:
        print(expected_declines)
    return 0


if __name__ == "__main__":
    sys.exit(main())
