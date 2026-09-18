---
name: benchmark-commands
description: Concrete command invocations for running exeris-benchmarks work — JMH microbenchmarks, GitHub Packages auth for `eu.exeris:*` snapshots, wrk/wrk2/h2load/k6 runtime drivers, campaign and matrix runs, env capture, comparison, publishing, baseline updates, and the `tools/` helpers. Load when actually running, publishing, or scripting a benchmark.
---

# exeris-benchmarks command reference

The rules that govern these commands live in `CLAUDE.md` and are always loaded — this file
carries only the invocations. Where a rule and a command are inseparable (`-f 3`, publication
mode, footprint attribution), the rule is restated here too.

## JMH microbenchmarks

```bash
cd micro/jmh
mvn clean package -DskipTests          # produces target/benchmarks.jar

# All benchmarks (publishable: ≥3 forks)
java -jar target/benchmarks.jar -wi 5 -i 10 -f 3

# Single benchmark class
java -jar target/benchmarks.jar RouteRegistryBenchmark -wi 5 -i 10 -f 3

# Allocation profile (zero-alloc paths must show ≈ 0 B/op)
java -jar target/benchmarks.jar JsonCodecBenchmark -prof gc -wi 5 -i 10 -f 3

# JSON output for CI / comparison
java -jar target/benchmarks.jar -rf json -rff results.json -wi 5 -i 10 -f 3

# Repo wrapper
./scripts/run-jmh.sh RouteRegistryBenchmark
```

Standard JVM flags for the JMH module are `-XX:+UseG1GC -XX:+AlwaysPreTouch -Xms256m -Xmx256m`
(fixed heap prevents GC-mode switching across forks; bump for larger working sets).
`-f 1` is iteration-only — never for anything published into `baselines/`.

## GitHub Packages auth (required for `eu.exeris:*` snapshots)

`eu.exeris:*` snapshots resolve from GitHub Packages, not Maven Central. Local builds need a
PAT with package read access:

```bash
export GITHUB_ACTOR="<github-username>"
export GITHUB_TOKEN="ghp_xxx"
mvn -s .github/maven-settings-gpr.xml -f micro/jmh/pom.xml clean package -DskipTests
```

The settings file references server IDs `github-exeris-kernel` and `github-exeris-spring-runtime`.

## Runtime / HTTP load benchmarks

Targets must be **launched externally** before running a driver.

```bash
./scripts/run-wrk.sh         targets/exeris-community-app scenarios/plaintext
./scripts/run-wrk2.sh        targets/exeris-community-app scenarios/keepalive-steady
./scripts/run-h2load.sh      targets/exeris-community-app scenarios/multiplex-32
./scripts/run-k6.sh          targets/exeris-community-app scenarios/json-1kb
```

To synchronize two pre-launched targets:

```bash
targets/launcher-sync-wrapper.sh \
  --target-a-id <id> --target-a-port <port> \
  --target-b-id <id> --target-b-port <port> \
  --output-dir <path> [--health-path /health] [--sync-timeout-seconds 30]
```

## Campaign / matrix runs

Campaign and matrix entry points are `scripts/run-*.sh` — `ls scripts/run-*` for the current
set. Two carry non-obvious arguments:

```bash
./scripts/run-e2e-shop-order-saga-campaign.sh --targets <a,b,c> --graph-track <neo4j|...> --profile <id> ...
./scripts/run-tls-matrix.sh   # label/MUST-SHOULD-STRETCH mapping: docs/tls-zero-copy-benchmark-matrix.md
```

## Capture, validate, compare, publish

```bash
./scripts/capture-env.sh > results/raw/$(date +%Y%m%d-%H%M%S)-env.json

./scripts/compare-results.sh baselines/community/h1/laptop.json results/raw/latest.json

./scripts/validate-comparative-readiness.sh ...
./scripts/aggregate-comparative-results.sh   ...
./scripts/aggregate-phases.sh                ...
./scripts/report-protocol-matrix.sh results/normalized > results/reports/protocol-matrix.md

./scripts/publish-report.sh \
  --result results/raw/<run>.json \
  --env    results/raw/<env>.json \
  --output results/reports/ \
  --archive results/history/jdk/ \
  [--publication-mode public|internal-only|redacted] \
  [--jfr-artifact <path>]
```

`publish-report.sh` defaults to `--publication-mode public` — see `CLAUDE.md` for what each
mode permits before passing anything other than the default.

## Tools

```bash
tools/extract-jfr-metrics.sh <input.jfr> [output.json]   # uses jfr print --json
tools/compute-fairness-index.sh --result-a A.json --result-b B.json --output fairness-index.json
tools/verify-classification.sh <status.csv>              # validates runner_status / reproducibility_status / final_reason / claim_scope enums
tools/verify-target-asset-matrix.sh                      # checks runtime/drivers/target-asset-matrix.json vs scenarios/**/comparative-pair-manifest.json
tools/benchmark-runner-with-metrics.sh <cmd...>          # wraps with /usr/bin/time -v, writes <output>.with-metrics.json

# JVM footprint attribution — a pair, deliberately split by what they measure:
tools/extract-footprint-decomposition.sh <nmt-detail.txt[.gz]> <smaps.txt[.gz]> [out.json]
#   RESIDENT split: heap vs non-heap, and anonymous vs file-backed, by joining smaps Rss
#   per mapping against the Java Heap address range in NMT's virtual memory map.
tools/extract-nmt-category-breakdown.sh <nmt-capture.txt[.gz]> [out.json]
#   COMMITTED split: non-heap by NMT category (class metadata / code / GC / thread / …).
```

The two footprint tools must never be summed and RSS must never be derived by subtracting
`-Xmx` — the reasoning is in `CLAUDE.md`; read it before quoting any footprint number.

## Updating a baseline

```bash
cp results/raw/<run>.json baselines/<repo>/<mode>/<hardware-profile>.json
git commit -m "chore(baselines): update <repo>/<mode> <hardware-profile> baseline [vX.Y.Z]"
```

Follow `docs/regression-policy.md`. Never refresh a baseline to mask a regression.
