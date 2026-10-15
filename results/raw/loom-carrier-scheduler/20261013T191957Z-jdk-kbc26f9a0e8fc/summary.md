# loom-carrier-scheduler campaign `20261013T191957Z-jdk-kbc26f9a0e8fc`

- backend: `jdk`, arms: `A_iso C_iso D`, reps: 10
- ladder base (median A_iso saturation): 61887 req/s; rates: 30900 43300 52600
- seed: `1791919197`; extra trial args: `--poller-mode 3 --warmup-mode open --warmup 30 --think-ms 30 --connections 5000 --pool 2048 --max-connections 16384 --duration 60`
- kernel: `bc26f9a0e8fc56bf922aa7515b8f29cc2aac869d`; JDK: OpenJDK Runtime Environment (build 28-testing-builds.shipilev.net-openjdk-jdk-loom-b18-20260917-2133)
- host shielded (host-shield.sh, no graphical session): 99 of 99 trials
- evidence-eligible (every trial's measurement valid, harness committed, host shielded): **True**

| backend | rate | arm | sustained | req/s (median) | p50 | p90 | p99 (median) | p99 all trials | worst p99 | p99.9 | carrier CPU % | carrier %wait max | CPUs (perf) | IPC | cs/s |
|:--|---:|:--|--:|--:|--:|--:|--:|:--|--:|--:|--:|--:|--:|--:|--:|
| jdk | max | A_iso | 3 of 3 | 61887 | 77.39 | 90.68 | 122.96 | 122.96, 104.06, 123.42 | 123.42 | — | 160.7 | 1.8 | 2.44 | 0.82 | 20134 |
| jdk | max | C_iso | 3 of 3 | 52413 | 93.25 | 102.67 | 120.77 | 120.01, 121.01, 120.77 | 121.01 | — | 156.7 | 1.5 | 2.49 | 0.76 | 48356 |
| jdk | max | D | 3 of 3 | 55704 | 88.04 | 91.79 | 111.48 | 113.49, 111.06, 111.48 | 113.49 | — | 168.8 | 0.0 | 2.68 | 0.74 | 54214 |
| jdk | 30900 | A_iso | 10 of 10 | 29303 | 31.78 | 33.25 | 41.23 | 38.88, 35.71, 45.09, 39.52, 51.58, 42.94, 33.85, 38.85, 43.33, 43.04 | 51.58 | 61.16 | 93.7 | 0.1 | 1.32 | 0.74 | 36861 |
| jdk | 30900 | C_iso | 10 of 10 | 29303 | 31.78 | 33.23 | 43.57 | 46.78, 51.97, 44.90, 37.95, 42.24, 40.29, 40.00, 48.80, 48.45, 38.24 | 51.97 | 72.12 | 86.7 | 0.1 | 1.26 | 0.76 | 33696 |
| jdk | 30900 | D | 10 of 10 | 29313 | 31.73 | 32.93 | 39.49 | 38.24, 40.61, 35.29, 41.95, 39.04, 38.46, 50.33, 38.75, 41.85, 39.94 | 50.33 | 64.51 | 85.8 | 0.0 | 1.25 | 0.76 | 32660 |
| jdk | 43300 | A_iso | 10 of 10 | 41052 | 32.13 | 35.39 | 65.81 | 51.01, 65.31, 66.30, 35.68, 84.03, 62.69, 53.28, 70.53, 70.08, 74.75 | 84.03 | 90.17 | 120.7 | 3.7 | 1.70 | 0.74 | 37820 |
| jdk | 43300 | C_iso | 10 of 10 | 41045 | 32.21 | 38.27 | 52.91 | 53.25, 51.94, 52.58, 54.59, 53.38, 49.89, 53.79, 51.81, 54.30, 52.29 | 54.59 | 61.48 | 115.5 | 4.2 | 1.62 | 0.73 | 36293 |
| jdk | 43300 | D | 10 of 10 | 41044 | 32.08 | 34.37 | 96.32 | 50.43, 39.33, 110.21, 94.40, 108.86, 62.14, 107.58, 59.87, 128.70, 98.24 | 128.70 | 112.32 | 117.3 | 0.0 | 1.65 | 0.74 | 39081 |
| jdk | 52600 | A_iso | 10 of 10 | 49855 | 33.66 | 91.84 | 181.25 | 177.02, 182.78, 159.10, 382.98, 232.83, 179.71, 191.10, 141.57, 167.17, 222.21 | 382.98 | 248.00 | 139.0 | 9.0 | 2.02 | 0.74 | 31352 |
| jdk | 52600 | C_iso | 9 of 10 | 49793 | 173.31 | 217.09 | 240.13 | 104.64, 210.43, 356.61, 93.18, 240.13, 162.18, 483.07, 492.03, 281.60 | 492.03 | 251.65 | 148.8 | 1.5 | 2.29 | 0.71 | 45662 |
| jdk | 52600 | D | 10 of 10 | 49851 | 32.57 | 37.68 | 52.61 | 44.80, 56.58, 44.83, 42.69, 43.36, 85.31, 87.93, 73.28, 82.94, 48.64 | 87.93 | 58.03 | 139.6 | 0.0 | 2.02 | 0.76 | 36116 |

Latencies in ms. Percentiles from wrk2 (open loop, coordinated-omission corrected) for numeric rates and from wrk (closed loop) for `max`; closed-loop latency is not a latency result.

## Trials that did not sustain the target rate

A result about the arm: counted under *sustained* in its cell, kept out of the percentiles.

- `r2-C_iso-52600` (C_iso at 52600): achieved 48884.4 req/s of 49860 expected at target 52600 (ratio 0.9804)

