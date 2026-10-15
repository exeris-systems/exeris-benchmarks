# loom-carrier-scheduler campaign `20261009T040618Z-jdk-kbc26f9a0e8fc`

- backend: `jdk`, arms: `A_iso C_iso D`, reps: 10
- ladder base (median A_iso saturation): 75998 req/s; rates: 38000 53200 64600 68400
- seed: `1791518778`; extra trial args: `--poller-mode 3 --warmup-mode open --warmup 30`
- kernel: `bc26f9a0e8fc56bf922aa7515b8f29cc2aac869d`; JDK: OpenJDK Runtime Environment (build 28-testing-builds.shipilev.net-openjdk-jdk-loom-b18-20260917-2133)
- host shielded (host-shield.sh, no graphical session): 129 of 129 trials
- evidence-eligible (every trial's measurement valid, harness committed, host shielded): **True**

| backend | rate | arm | sustained | req/s (median) | p50 | p90 | p99 (median) | p99 all trials | worst p99 | p99.9 | carrier CPU % | carrier %wait max | CPUs (perf) | IPC | cs/s |
|:--|---:|:--|--:|--:|--:|--:|--:|:--|--:|--:|--:|--:|--:|--:|--:|
| jdk | max | A_iso | 3 of 3 | 75998 | 1.26 | 1.47 | 2.24 | 3.18, 2.22, 2.24 | 3.18 | — | 160.5 | 2.8 | 2.24 | 0.77 | 57211 |
| jdk | max | C_iso | 3 of 3 | 75421 | 1.25 | 1.52 | 2.32 | 2.32, 2.43, 2.23 | 2.43 | — | 159.2 | 4.4 | 2.32 | 0.76 | 67988 |
| jdk | max | D | 3 of 3 | 78381 | 1.24 | 1.35 | 1.97 | 1.96, 1.97, 2.14 | 2.14 | — | 168.6 | 0.0 | 2.46 | 0.75 | 72271 |
| jdk | 38000 | A_iso | 10 of 10 | 37922 | 1.91 | 2.42 | 2.63 | 2.58, 2.63, 2.64, 2.66, 2.65, 2.65, 2.63, 2.66, 2.62, 2.63 | 2.66 | 2.94 | 86.1 | 0.0 | 1.22 | 0.76 | 32460 |
| jdk | 38000 | C_iso | 10 of 10 | 37922 | 1.92 | 2.44 | 2.68 | 2.69, 2.64, 2.68, 2.69, 2.66, 2.68, 2.64, 2.69, 2.68, 2.66 | 2.69 | 2.99 | 84.3 | 0.1 | 1.20 | 0.75 | 33964 |
| jdk | 38000 | D | 10 of 10 | 37922 | 1.91 | 2.44 | 2.67 | 2.68, 2.68, 2.66, 2.64, 2.66, 2.64, 2.68, 2.66, 2.68, 2.68 | 2.68 | 2.92 | 84.5 | 0.0 | 1.21 | 0.76 | 34817 |
| jdk | 53200 | A_iso | 10 of 10 | 53090 | 1.78 | 2.27 | 2.46 | 2.47, 2.47, 2.46, 11.35, 2.46, 2.46, 2.52, 2.47, 2.45, 2.46 | 11.35 | 3.35 | 121.5 | 0.1 | 1.72 | 0.75 | 49507 |
| jdk | 53200 | C_iso | 10 of 10 | 53090 | 1.79 | 2.28 | 2.54 | 2.68, 2.52, 2.52, 2.55, 2.53, 2.57, 2.50, 2.54, 2.57, 2.57 | 2.68 | 3.69 | 116.6 | 0.9 | 1.68 | 0.75 | 51281 |
| jdk | 53200 | D | 10 of 10 | 53090 | 1.78 | 2.27 | 2.47 | 2.48, 2.48, 2.45, 2.55, 2.47, 2.47, 2.43, 2.47, 2.47, 2.46 | 2.55 | 2.84 | 117.3 | 0.0 | 1.68 | 0.76 | 51133 |
| jdk | 64600 | A_iso | 10 of 10 | 64467 | 1.77 | 2.42 | 11.89 | 28.58, 16.22, 11.26, 15.38, 11.98, 11.81, 9.57, 12.91, 10.26, 9.66 | 28.58 | 18.11 | 139.9 | 1.9 | 1.97 | 0.77 | 52525 |
| jdk | 64600 | C_iso | 9 of 10 | 64467 | 1.80 | 3.09 | 10.79 | 10.79, 77.12, 9.34, 15.27, 6.56, 6.20, 16.93, 36.58, 6.75 | 77.12 | 16.17 | 137.6 | 2.8 | 1.98 | 0.76 | 56581 |
| jdk | 64600 | D | 10 of 10 | 64468 | 1.73 | 2.23 | 2.58 | 2.55, 2.57, 2.83, 2.60, 2.56, 2.55, 2.65, 2.60, 2.57, 2.63 | 2.83 | 3.46 | 138.6 | 0.0 | 1.99 | 0.76 | 57472 |
| jdk | 68400 | A_iso | 9 of 10 | 68260 | 1.78 | 3.02 | 21.39 | 21.57, 18.46, 16.58, 27.42, 10.15, 10.45, 33.57, 61.82, 21.39 | 61.82 | 32.69 | 147.4 | 2.2 | 2.06 | 0.77 | 54295 |
| jdk | 68400 | C_iso | 10 of 10 | 68259 | 1.82 | 4.44 | 13.46 | 11.27, 13.90, 13.73, 13.19, 8.31, 11.02, 15.30, 38.21, 13.05, 22.61 | 38.21 | 18.19 | 144.3 | 3.7 | 2.08 | 0.76 | 59967 |
| jdk | 68400 | D | 10 of 10 | 68259 | 1.70 | 2.19 | 2.58 | 8.66, 2.53, 3.35, 2.59, 2.56, 2.55, 2.56, 2.57, 2.65, 2.62 | 8.66 | 3.06 | 146.2 | 0.0 | 2.11 | 0.76 | 60934 |

Latencies in ms. Percentiles from wrk2 (open loop, coordinated-omission corrected) for numeric rates and from wrk (closed loop) for `max`; closed-loop latency is not a latency result.

## Trials that did not sustain the target rate

A result about the arm: counted under *sustained* in its cell, kept out of the percentiles.

- `r3-A_iso-68400` (A_iso at 68400): achieved 59378.9 req/s of 68258 expected at target 68400 (ratio 0.8699)
- `r3-C_iso-64600` (C_iso at 64600): achieved 63700.2 req/s of 64465 expected at target 64600 (ratio 0.9881)

