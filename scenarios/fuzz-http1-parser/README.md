# fuzz-http1-parser

Jazzer fuzz campaign against `eu.exeris.kernel.core.http.http1.Http1RequestParser`.

## What it tests

- `parseRequestLine(MemorySegment, long offset, long length)` against mutated byte sequences wrapped in a confined `Arena` `MemorySegment`.
- `parseHeaders(MemorySegment, long offset, long length, int maxHeaders, int maxHeaderSize, HeaderVisitor)` with a no-op visitor.

## Pass / fail

Pass = zero unexpected throwables, zero hangs (no iteration exceeds Jazzer's `--keep_going` per-iteration budget), Arena `MemoryAllocator.stats().leakCount()` delta == 0.

Fail = any throwable not in the whitelist (see `scenario.json::fuzz.expected_throwables`). Failures emit a `crash-<sha1>` corpus file inside Jazzer's working directory — these MUST be treated as `--destructive-artifact` paths and only published in `--publication-mode internal-only`.

## How to run

```bash
./scripts/run-fuzz-campaign.sh scenarios/fuzz-http1-parser \
    --duration 60s \
    --output results/raw/fuzz-http1-parser-$(date +%Y%m%d-%H%M%S)
```

Smoke (~10s): `FUZZ_DURATION=10s ./scripts/run-fuzz-campaign.sh scenarios/fuzz-http1-parser`.

## Artifacts

- `result.json` — standard `benchmark-result.json` with `tool: jazzer`, `claim_scope: exploratory`.
- `destructive-findings.json` — sidecar with crash/oom/hang counts, leak delta, classification.
- `crash-*` / `*.fuzz-input` (if any) — raw inputs, BLOCKED in public/redacted publication.

## Boundary note

This campaign is exploratory (`claim_scope=exploratory`). The companion unit-style "single-input crash regression" tests belong in `exeris-kernel/` (product repo) — see `docs/destructive-fuzz-methodology.md` §Boundary.
