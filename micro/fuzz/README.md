# exeris-benchmarks/micro/fuzz

Jazzer + JUnit 5 fuzz campaigns against the kernel's HTTP/1 and HTTP/2 parsers.

## What this module is — and isn't

This is the **campaign-style** fuzz layer. Each fuzz target runs for a bounded wall-clock window (default 60s) under `mvn test`. Findings (crashes, OOMs, hangs, Arena leaks) are emitted as `crash-*` corpora and surfaced via Surefire output, then parsed by `scripts/run-fuzz-campaign.sh` into a `destructive-findings.json` sidecar.

This is **NOT** the home for unit-style crash regression tests. Those — single-input "does parser X handle byte sequence Y" tests — belong in `exeris-kernel/` (product repo) per the boundary rule in `../../CLAUDE.md`. Adding a regression test here would let a kernel bug ship undetected.

## Layout

```
micro/fuzz/
├── pom.xml
├── README.md
└── src/
    ├── main/java/eu/exeris/benchmarks/micro/fuzz/
    │   ├── ExpectedThrowables.java      # whitelist semantics
    │   └── FuzzInputs.java              # byte[] → Arena MemorySegment
    └── test/
        ├── java/eu/exeris/benchmarks/micro/fuzz/
        │   ├── Http1RequestParserFuzzTest.java
        │   ├── Http1HeaderParserFuzzTest.java
        │   └── Http2FrameParserFuzzTest.java
        └── resources/eu/exeris/benchmarks/micro/fuzz/<TestName>/
            └── seed-*                   # seed corpus for that target
```

## Run

```bash
# Smoke
mvn -s ../../.github/maven-settings-gpr.xml test -Djazzer.duration=10s

# Single target
mvn -s ../../.github/maven-settings-gpr.xml test \
    -Dtest=Http2FrameParserFuzzTest -Djazzer.duration=60s

# Campaign with sidecar emission
cd ../..
./scripts/run-fuzz-campaign.sh scenarios/fuzz-http1-parser --duration 300s
```

## Reproducibility

The `exeris.kernel.version` property pins the kernel snapshot under test. Pin it explicitly in CI (`-Dexeris.kernel.version=0.5.0-20260512.123456-7` style) — `0.5.0-SNAPSHOT` is non-reproducible and findings against it cannot be re-bisected.

Seed corpora MUST be committed; Jazzer mutates outward from them. A campaign without committed seeds is descriptive-only.

## Confidentiality

Jazzer writes `crash-<sha1>` and `hang-<sha1>` files inside the working directory on findings. These contain the offending byte sequence (attacker-supplied input). They are NOT publication-safe. `publish-report.sh` blocks them in `public` and `redacted` modes via the basename blocklist (`crash-*`, `jazzer-crash-*`, `*.fuzz-input`). Always invoke publication with `--publication-mode internal-only` for fuzz runs.
