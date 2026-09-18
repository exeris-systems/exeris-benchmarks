# fuzz-http1-headers

Jazzer fuzz campaign against `Http1RequestParser.parseHeaders` — the HTTP/1 header block.

## Why this scenario exists

`Http1HeaderParserFuzzTest` compiled and had a seed-corpus directory, but no scenario named it,
so nothing ever ran it. Meanwhile `fuzz-http1-parser` and `docs/scenario-catalog.md` both claimed
coverage of `parseRequestLine` **and** `parseHeaders`. The 2026-08-26 campaign put 119.9 M inputs
through the request line and **zero** through the header parser, while the catalog read as though
both were covered. This scenario closes the gap; the sibling's description is narrowed to what it
actually drives.

## What it tests

- `parseHeaders(MemorySegment, long offset, long length, int maxHeaders, int maxHeaderSize, HeaderVisitor)`
  against mutated byte sequences wrapped in a confined `Arena` `MemorySegment`.
- Bounds: `MAX_HEADERS = 64`, `MAX_HEADER_SIZE = 4096` — tighter than RFC defaults, so an
  attacker-supplied length field cannot make a single iteration drag.
- The visitor is a no-op, but **the path is not allocation-free**: `parseHeaders` materialises
  each name and value as a `String` before calling the visitor, so this campaign exercises the
  header allocation path as well as the parse path.

## Pass / fail

Pass = zero unexpected throwables, zero hangs, Arena `MemoryAllocator.stats().leakCount()` delta == 0.

Fail = any throwable not in the whitelist (see `scenario.json::fuzz.expected_throwables`).
Failures emit a `crash-<sha1>` corpus file inside Jazzer's working directory — these MUST be
treated as `--destructive-artifact` paths and only published in `--publication-mode internal-only`.

## How to run

```bash
./scripts/run-fuzz-campaign.sh scenarios/fuzz-http1-headers \
    --kernel-version 0.11.0 \
    --kernel-commit <sha> \
    --harness-sha <sha> \
    --output results/raw/fuzz-http1-headers-$(date +%Y%m%d-%H%M%S)
```

Campaign length is **not** a flag. It comes from `@FuzzTest(maxDuration = "...")` on the test
class, because `--duration` could not be honoured and silently produced a shorter campaign than
the one recorded in the result.

`JAZZER_FUZZ=1` is exported by the runner. Without it Jazzer replays the seed corpus in
**regression mode**, passes, and exits — which is what a "successful" campaign looked like before
the runner set it.

## Artifacts

- `result.json` — standard `benchmark-result.json` with `tool: jazzer`, `claim_scope: exploratory`.
- `destructive-findings.json` — sidecar with crash/oom/hang counts, leak delta, classification.
- `crash-*` / `*.fuzz-input` (if any) — raw inputs, BLOCKED in public/redacted publication.

## Boundary note

This campaign is exploratory (`claim_scope=exploratory`). The companion unit-style "single-input
crash regression" tests belong in `exeris-kernel/` (product repo) — see
`docs/destructive-fuzz-methodology.md` §Boundary.
