# Result Interpretation

## Reading a JMH result

JMH outputs results per benchmark method in the following form:

```
Benchmark                        Mode  Cnt     Score    Error  Units
RouteRegistryBenchmark.lookup   avgt   30   123.456 ±  4.567  ns/op
```

| Column | Meaning |
|---|---|
| `Mode` | `avgt` = average time, `thrpt` = throughput, `sample` = latency distribution |
| `Cnt` | Total measurement samples (forks × iterations) |
| `Score` | Mean of all samples |
| `Error` | 99% confidence interval half-width |
| `Units` | e.g., `ns/op`, `ops/s` |

A large `Error` relative to `Score` means the benchmark is noisy. Investigate
before storing as baseline.

## B3/B4/B5/B6/B7 publication legend

Use these labels in reports so profile metrics are interpreted against the correct transport model.

| Label | Meaning |
|---|---|
| `B3` | JDK `SSLEngine` baseline |
| `B4` | Netty tcNative baseline |
| `B5` | Exeris OffHeapTlsEngine engine-level benchmark via neutral in-process Memory-BIO harness |
| `B6` | Exeris Community FD-owner/socket path (includes kernel crossing) |
| `B7` | Exeris Enterprise Memory-BIO path (in-process) |

Use `B3`/`B4`/`B5` for engine-level claims and `B6`/`B7` for integration-level claims.
GC and heap comparisons are valid only when each result is explicitly labeled with its model (`B3`/`B4`/`B5`/`B6`/`B7`) and tier/protocol context. Do not interpret cross-model GC/heap deltas as equivalent engine overhead without those labels.

---

## Reading a wrk result

```
Running 30s test @ http://localhost:8080/plaintext
  4 threads and 100 connections

  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   312.45us  112.34us   5.23ms   89.12%
    Req/Sec    78.34k     3.21k   82.10k    71.23%

  9380443 requests in 30.04s, 1.32GB read
Requests/sec: 312345.67
Transfer/sec:     44.96MB
```

Key numbers to record:

| Metric | Where |
|---|---|
| `Requests/sec` | Primary throughput number |
| `Latency Avg` | Mean latency |
| `Latency Stdev` | Spread — high stdev = instability |
| `Latency Max` | Worst observed; tail sensitivity |
| `+/- Stdev %` | If > 90%, distribution is right-skewed (many fast + few very slow) |

Use `--latency` flag for full percentile breakdown (p50/p75/p90/p99).

---

## Reading an h2load result

```
finished in 10.01s, 99821.18 req/s, 14.49MB/s
requests: 1000000 total, 1000000 started, 1000000 done, 1000000 succeeded, 0 failed
status codes: 1000000 2xx
traffic: 144.90MB (151930000) total, 58.59MB (61449000) headers, 74.46MB (78054000) data
                     min         max         mean         sd        +/- sd
time for request:   183us       5.63ms      1.00ms    290.38us    89.11%
time for connect:    66us       5.09ms      2.89ms      1.93ms    56.91%
time to 1st byte:  1.16ms       6.94ms      4.31ms      1.94ms    58.93%
req/s           : 9982.25   10018.43    9999.18      12.43    66.67%
```

Key numbers: `req/s` (throughput), `time for request` mean and p99, failed count.

---

## Reading a k6 result

```
http_req_duration............: avg=1.2ms   min=200µs med=900µs   max=45ms    p(90)=2.1ms p(99)=8.3ms
http_req_failed..............: 0.00%  ✓ 0     ✗ 100000
http_reqs....................: 100000 3333.33/s
```

Key numbers: `http_req_duration` p90 and p99, `http_req_failed` percentage,
`http_reqs` throughput.

---

## Comparing two runs

Use `scripts/compare-results.sh` to produce a diff table:

```bash
./scripts/compare-results.sh baselines/community/perf-box-amd64.json results/raw/2026-03-15-abc1234.json
```

Output format:

```
Scenario          | Baseline (req/s) | Current (req/s) | Delta
plaintext         | 312,345          | 318,901         | +2.1%  ✓
json-1kb          | 145,230          | 141,100         | -2.8%  ✓
json-10kb         | 62,440           | 55,000          | -11.9% ✗  REGRESSION
```

A result is flagged as a regression according to the thresholds in
[regression-policy.md](regression-policy.md).

---

## Common pitfalls

| Symptom | Likely cause |
|---|---|
| High JMH `Error` (> 10% of Score) | GC pressure, thread migration, Turbo Boost variation |
| wrk `Max` latency >> `Avg` | TCP accept queue saturation or GC pause |
| k6 errors > 0% | Target not ready, port conflict, or connection limit |
| Score better on fork 1 than fork 3 | Code cache filling up — expected; use mean across forks |
| h2load `time for connect` high | TLS handshake cost included; separate connection establishment if needed |

---

## Mode comparison rules

When reporting Pure Mode vs Compatibility Mode:

- Both must run against identical hardware and environment.
- Both must use the same scenario and payload.
- The overhead percentage = `(compat_mean - pure_mean) / pure_mean x 100`.
- Always state whether the overhead is latency or throughput.
- Never use "N times slower" without citing the base latency -- 2x of 10 us is not 2x of 1 ms.

---

## Publication Gate

Before publishing or citing a benchmark result, verify all of the following:

- **Publication mode is explicit for any JFR handling** in `scripts/publish-report.sh`.
  The default `public` mode is default-deny for raw JFR and blocks detected raw JFR
  via case-insensitive `.jfr` extension checks and content-level signature checks (`FLR\0`).
  Use `--publication-mode internal-only` for restricted internal publication, or
  `--publication-mode redacted` with non-raw redacted artifacts. Redacted mode uses
  the same case-insensitive extension/signature checks and blocks detected raw JFR.
- **Confidentiality labels** must be present in report metadata and aligned with
  publication intent:
  `publication_mode`, `confidentiality_status`, and `jfr_handling`.
- **Raw JFR in public outputs is disallowed**. If raw traces are required for
  analysis, keep publication internal-only until redaction is complete.

- **Comparative wording** is only permitted when `claim_scope = comparison_eligible`.
  Results with `claim_scope = exploratory_only` or an absent `claim_scope` must use
  non-comparative language (descriptive or regression-guard only).
- **Exploratory runs** must be explicitly labeled as exploratory in every publication
  artifact. Non-regression language ("no degradation observed") is acceptable;
  headline throughput comparisons are not.
- **Cross-tier claims** (Community vs Enterprise) require: same protocol mode, same
  payload and concurrency level, same hardware profile, and an explicit tier label on
  both sides. A missing tier label on either side blocks the cross-tier claim.
- **Protocol and family constraints**: claims comparing H1 vs H2, micro vs runtime,
  or pure vs compatibility require explicit labels on both sides and must not be
  collapsed into a single headline without caveats.
- **Guard runs** (EXECUTION_CLASS=guard, forks >= 2) are the minimum bar for
  `comparison_eligible` status. Single-fork or exploratory runs cannot carry that
  designation regardless of other metadata completeness.
