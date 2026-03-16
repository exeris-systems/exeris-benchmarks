# targets/exeris-spring-runtime

This directory contains configuration for running benchmarks against the
**Exeris Spring Runtime** target in both pure mode and compatibility mode.

## Modes

| Mode | Description | `EXERIS_SPRING_MODE` value |
|---|---|---|
| Pure mode | Phase 1 — Exeris handler, Spring context, no Servlet/Tomcat | `pure` |
| Compatibility mode | Phase 2 — `@RestController` dispatch via compatibility bridge | `compat` |

## Benchmark focus

- Phase 0 bootstrap timing (startup smoke)
- Phase 1 pure mode ingress RPS and latency
- Phase 2 compat mode overhead vs pure mode
- Transaction bridge overhead (compat mode only)

## Running

```bash
# Pure mode
EXERIS_SPRING_MODE=pure ./scripts/run-wrk.sh targets/exeris-spring-runtime scenarios/plaintext

# Compat mode
EXERIS_SPRING_MODE=compat ./scripts/run-wrk.sh targets/exeris-spring-runtime scenarios/plaintext

# Compare
./scripts/compare-results.sh \
  results/raw/wrk-pure-mode.json \
  results/raw/wrk-compat-mode.json
```

## Notes

- Results for pure mode vs compat mode must be stored separately:
  `baselines/spring-runtime/pure/` and `baselines/spring-runtime/compat/`
- Report overhead as: `(compat_mean - pure_mean) / pure_mean × 100%`
- Never report compat mode numbers as "Exeris Spring Runtime" performance
  without clearly labeling them as compat mode.
