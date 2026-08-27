# fuzz-http1-parser

Jazzer fuzz campaign against `eu.exeris.kernel.core.http.http1.Http1RequestParser`.

## What it tests

- `parseRequestLine(MemorySegment, long offset, long length)` against mutated byte sequences wrapped in a confined `Arena` `MemorySegment`.

This scenario drives `Http1RequestParserFuzzTest`, i.e. the **request line only**. It used to list
`parseHeaders` here as well, while no scenario drove the header parser at all — so the 2026-08-26
campaign's 119.9 M inputs never reached it. Header-block coverage is
[`fuzz-http1-headers`](../fuzz-http1-headers/).

## Pass / fail

Pass = zero unexpected throwables, zero hangs (no iteration exceeds Jazzer's `--keep_going` per-iteration budget), Arena `MemoryAllocator.stats().leakCount()` delta == 0.

Fail = any throwable not in the whitelist (see `scenario.json::fuzz.expected_throwables`). Failures emit a `crash-<sha1>` corpus file inside Jazzer's working directory — these MUST be treated as `--destructive-artifact` paths and only published in `--publication-mode internal-only`.

## How to run

```bash
./scripts/run-fuzz-campaign.sh scenarios/fuzz-http1-parser \
    --kernel-version 0.11.0 \
    --kernel-commit <sha> \
    --harness-sha <sha> \
    --output results/raw/fuzz-http1-parser-$(date +%Y%m%d-%H%M%S)
```

Campaign length is **not** a flag — it comes from `@FuzzTest(maxDuration = "...")` on the test
class. `--duration` and `FUZZ_DURATION` are refused rather than silently ignored, which is what
they were: the runner recorded the requested duration in the result while running the annotated
one.

## Artifacts

- `result.json` — standard `benchmark-result.json` with `tool: jazzer`, `claim_scope: exploratory`.
- `destructive-findings.json` — sidecar with crash/oom/hang counts, leak delta, classification.
- `crash-*` / `*.fuzz-input` (if any) — raw inputs, BLOCKED in public/redacted publication.

## Boundary note

This campaign is exploratory (`claim_scope=exploratory`). The companion unit-style "single-input crash regression" tests belong in `exeris-kernel/` (product repo) — see `docs/destructive-fuzz-methodology.md` §Boundary.
