# loom-carrier-scheduler campaign `20261016T034438Z-jdk-kbc26f9a0e8fc`

- backend: `jdk`, arms: `A_iso B_pin C_iso D`, reps: 5
- ladder base (median A_iso saturation): 62063 req/s; rates: 31000 43400 46500 49700 52800 55900 59000 62100
- seed: `1792122278`; extra trial args: `--poller-mode 3 --warmup-mode open --warmup 30 --think-ms 30 --connections 5000 --pool 2048 --max-connections 16384 --duration 60`
- kernel: `bc26f9a0e8fc56bf922aa7515b8f29cc2aac869d`; JDK: OpenJDK Runtime Environment (build 28-testing-builds.shipilev.net-openjdk-jdk-loom-b18-20260917-2133)
- host shielded (host-shield.sh, no graphical session): 177 of 177 trials
- evidence-eligible (every trial's measurement valid, harness committed, host shielded): **True**

| backend | rate | arm | sustained | req/s (median) | p50 | p90 | p99 (median) | p99 all trials | worst p99 | p99.9 | carrier CPU % | carrier %wait max | CPUs (perf) | IPC | cs/s |
|:--|---:|:--|--:|--:|--:|--:|--:|:--|--:|--:|--:|--:|--:|--:|--:|
| jdk | max | A_iso | 3 of 3 | 62064 | 77.30 | 90.13 | 114.96 | 114.96, 120.44, 111.52 | 120.44 | — | 163.1 | 1.0 | 2.45 | 0.82 | 19410 |
| jdk | max | B_pin | 3 of 3 | 62829 | 76.98 | 88.54 | 102.84 | 102.03, 102.84, 108.49 | 108.49 | — | 164.8 | 0.0 | 2.48 | 0.80 | 20014 |
| jdk | max | C_iso | 3 of 3 | 52048 | 93.79 | 103.85 | 122.49 | 124.00, 119.47, 122.49 | 124.00 | — | 155.6 | 1.4 | 2.42 | 0.74 | 49853 |
| jdk | max | D | 3 of 3 | 55382 | 88.33 | 92.97 | 112.83 | 112.83, 112.82, 113.37 | 113.37 | — | 167.9 | 0.0 | 2.63 | 0.73 | 56512 |
| jdk | 31000 | A_iso | 5 of 5 | 29408 | 31.71 | 32.90 | 42.75 | 47.81, 42.75, 34.69, 35.87, 47.07 | 47.81 | 68.35 | 94.2 | 0.1 | 1.34 | 0.75 | 38734 |
| jdk | 31000 | B_pin | 5 of 5 | 29397 | 31.73 | 33.09 | 37.34 | 37.34, 36.96, 33.73, 40.93, 40.35 | 40.93 | 53.28 | 92.5 | 0.0 | 1.32 | 0.75 | 37096 |
| jdk | 31000 | C_iso | 5 of 5 | 29407 | 31.69 | 32.90 | 42.46 | 39.78, 48.67, 44.13, 42.46, 40.90 | 48.67 | 70.08 | 86.2 | 0.2 | 1.25 | 0.74 | 34970 |
| jdk | 31000 | D | 5 of 5 | 29397 | 31.74 | 33.15 | 48.74 | 48.74, 62.30, 42.88, 61.76, 41.98 | 62.30 | 83.33 | 87.9 | 0.0 | 1.28 | 0.78 | 33829 |
| jdk | 43400 | A_iso | 5 of 5 | 41135 | 32.16 | 37.12 | 70.78 | 70.78, 70.33, 86.33, 66.50, 96.83 | 96.83 | 103.55 | 121.5 | 4.4 | 1.75 | 0.77 | 36197 |
| jdk | 43400 | B_pin | 5 of 5 | 41154 | 32.01 | 33.41 | 118.91 | 82.75, 137.21, 118.91, 68.93, 129.92 | 137.21 | 147.84 | 121.5 | 0.0 | 1.72 | 0.75 | 39766 |
| jdk | 43400 | C_iso | 5 of 5 | 41123 | 32.38 | 43.04 | 55.42 | 55.62, 55.42, 57.60, 53.12, 54.94 | 57.60 | 61.38 | 116.0 | 5.6 | 1.67 | 0.75 | 34922 |
| jdk | 43400 | D | 5 of 5 | 41136 | 32.05 | 33.95 | 82.88 | 66.62, 39.42, 82.88, 132.10, 164.35 | 164.35 | 132.48 | 118.4 | 0.0 | 1.68 | 0.76 | 38467 |
| jdk | 46500 | A_iso | 5 of 5 | 44077 | 32.51 | 58.85 | 152.32 | 141.05, 165.25, 136.19, 152.32, 174.98 | 174.98 | 203.65 | 126.7 | 9.6 | 1.85 | 0.75 | 34104 |
| jdk | 46500 | B_pin | 5 of 5 | 44089 | 32.06 | 33.38 | 35.94 | 38.46, 38.65, 35.13, 35.94, 35.49 | 38.65 | 44.48 | 129.5 | 0.0 | 1.82 | 0.75 | 41869 |
| jdk | 46500 | C_iso | 5 of 5 | 44076 | 33.18 | 51.23 | 64.03 | 63.46, 67.52, 64.03, 64.22, 63.13 | 67.52 | 72.38 | 126.6 | 5.1 | 1.83 | 0.77 | 35683 |
| jdk | 46500 | D | 5 of 5 | 44075 | 32.13 | 33.98 | 39.52 | 41.79, 38.85, 39.07, 39.52, 40.54 | 41.79 | 53.38 | 125.3 | 0.0 | 1.74 | 0.73 | 41319 |
| jdk | 49700 | A_iso | 5 of 5 | 47102 | 32.83 | 89.54 | 171.90 | 173.95, 154.24, 171.90, 143.36, 189.57 | 189.57 | 238.85 | 132.9 | 10.6 | 1.96 | 0.74 | 30712 |
| jdk | 49700 | B_pin | 5 of 5 | 47102 | 32.17 | 34.43 | 39.62 | 39.62, 40.03, 39.17, 39.26, 39.78 | 40.03 | 47.49 | 136.8 | 0.0 | 1.94 | 0.75 | 44553 |
| jdk | 49700 | C_iso | 5 of 5 | 47101 | 43.42 | 61.82 | 79.74 | 108.54, 79.74, 70.85, 132.61, 76.61 | 132.61 | 90.88 | 138.7 | 4.4 | 2.04 | 0.72 | 37869 |
| jdk | 49700 | D | 5 of 5 | 47121 | 32.10 | 33.38 | 40.61 | 41.50, 40.80, 40.61, 39.17, 39.39 | 41.50 | 46.56 | 133.2 | 0.0 | 1.85 | 0.72 | 42519 |
| jdk | 52800 | A_iso | 5 of 5 | 50058 | 40.42 | 111.81 | 222.98 | 210.05, 239.36, 1010.00, 222.98, 200.96 | 1010.00 | 291.07 | 140.4 | 10.8 | 2.05 | 0.74 | 28286 |
| jdk | 52800 | B_float | 5 of 5 | 50040 | 36.64 | 105.47 | 199.42 | 197.12, 158.21, 199.42, 790.53, 248.19 | 790.53 | 275.97 | 138.5 | 9.0 | 2.02 | 0.73 | 30173 |
| jdk | 52800 | B_pin | 5 of 5 | 50058 | 32.08 | 33.15 | 40.67 | 40.67, 44.74, 43.10, 37.34, 39.58 | 44.74 | 50.30 | 143.7 | 0.0 | 2.00 | 0.74 | 42220 |
| jdk | 52800 | C_iso | 4 of 5 | 49954 | 171.65 | 236.54 | 280.96 | 230.91, 315.39, 256.51, 305.41 | 315.39 | 288.12 | 149.6 | 1.8 | 2.28 | 0.71 | 47617 |
| jdk | 52800 | D | 5 of 5 | 50039 | 32.24 | 37.02 | 45.63 | 82.24, 45.57, 45.63, 83.46, 44.96 | 83.46 | 51.04 | 141.7 | 0.0 | 2.04 | 0.75 | 40544 |
| jdk | 55900 | A_iso | 5 of 5 | 52910 | 55.39 | 128.90 | 212.99 | 333.31, 174.46, 262.91, 186.49, 212.99 | 333.31 | 292.61 | 146.8 | 9.0 | 2.15 | 0.76 | 26729 |
| jdk | 55900 | B_pin | 5 of 5 | 52976 | 32.16 | 34.97 | 42.01 | 41.57, 44.90, 46.78, 41.31, 42.01 | 46.78 | 50.59 | 150.2 | 0.0 | 2.11 | 0.75 | 44604 |
| jdk | 55900 | C_iso | 0 of 5 | — | — | — | — |  | — | — | — | — | — | — | — |
| jdk | 55900 | D | 5 of 5 | 52874 | 105.66 | 123.58 | 149.38 | 149.38, 530.43, 130.37, 136.83, 304.13 | 530.43 | 154.37 | 159.7 | 0.0 | 2.54 | 0.75 | 51139 |
| jdk | 59000 | A_iso | 5 of 5 | 55888 | 91.46 | 220.29 | 330.49 | 330.49, 280.32, 394.24, 309.76, 590.85 | 590.85 | 445.44 | 151.2 | 5.8 | 2.25 | 0.77 | 23286 |
| jdk | 59000 | B_pin | 5 of 5 | 55906 | 32.35 | 36.58 | 49.02 | 45.57, 54.30, 49.02, 48.90, 55.90 | 55.90 | 57.60 | 156.4 | 0.1 | 2.21 | 0.75 | 42161 |
| jdk | 59000 | C_iso | 0 of 5 | — | — | — | — |  | — | — | — | — | — | — | — |
| jdk | 59000 | D | 0 of 5 | — | — | — | — |  | — | — | — | — | — | — | — |
| jdk | 62100 | A_iso | 3 of 5 | 58517 | 385.02 | 512.00 | 598.02 | 846.85, 598.02, 559.10 | 846.85 | 629.76 | 153.2 | 2.0 | 2.28 | 0.81 | 22429 |
| jdk | 62100 | B_pin | 5 of 5 | 58847 | 35.58 | 81.41 | 109.12 | 118.14, 411.14, 109.12, 108.54, 73.15 | 411.14 | 127.36 | 160.8 | 0.1 | 2.30 | 0.75 | 36554 |
| jdk | 62100 | C_iso | 0 of 5 | — | — | — | — |  | — | — | — | — | — | — | — |
| jdk | 62100 | D | 0 of 5 | — | — | — | — |  | — | — | — | — | — | — | — |

Latencies in ms. Percentiles from wrk2 (open loop, coordinated-omission corrected) for numeric rates and from wrk (closed loop) for `max`; closed-loop latency is not a latency result.

## Trials that did not sustain the target rate

A result about the arm: counted under *sustained* in its cell, kept out of the percentiles.

- `r1-A_iso-62100` (A_iso at 62100): achieved 58142.0 req/s of 58866 expected at target 62100 (ratio 0.9877)
- `r1-C_iso-55900` (C_iso at 55900): achieved 50391.5 req/s of 52989 expected at target 55900 (ratio 0.951)
- `r1-C_iso-59000` (C_iso at 59000): achieved 49889.2 req/s of 55927 expected at target 59000 (ratio 0.892)
- `r1-C_iso-62100` (C_iso at 62100): achieved 50034.0 req/s of 58866 expected at target 62100 (ratio 0.85)
- `r1-D-59000` (D at 59000): achieved 52806.6 req/s of 55927 expected at target 59000 (ratio 0.9442)
- `r1-D-62100` (D at 62100): achieved 53792.2 req/s of 58866 expected at target 62100 (ratio 0.9138)
- `r2-A_iso-62100` (A_iso at 62100): achieved 57101.6 req/s of 58866 expected at target 62100 (ratio 0.97)
- `r2-C_iso-55900` (C_iso at 55900): achieved 50493.9 req/s of 52989 expected at target 55900 (ratio 0.9529)
- `r2-C_iso-59000` (C_iso at 59000): achieved 50011.1 req/s of 55927 expected at target 59000 (ratio 0.8942)
- `r2-C_iso-62100` (C_iso at 62100): achieved 49983.9 req/s of 58866 expected at target 62100 (ratio 0.8491)
- `r2-D-59000` (D at 59000): achieved 54053.0 req/s of 55927 expected at target 59000 (ratio 0.9665)
- `r2-D-62100` (D at 62100): achieved 53593.9 req/s of 58866 expected at target 62100 (ratio 0.9104)
- `r3-C_iso-55900` (C_iso at 55900): achieved 50091.4 req/s of 52989 expected at target 55900 (ratio 0.9453)
- `r3-C_iso-59000` (C_iso at 59000): achieved 50203.7 req/s of 55927 expected at target 59000 (ratio 0.8977)
- `r3-C_iso-62100` (C_iso at 62100): achieved 50146.4 req/s of 58866 expected at target 62100 (ratio 0.8519)
- `r3-D-59000` (D at 59000): achieved 53360.2 req/s of 55927 expected at target 59000 (ratio 0.9541)
- `r3-D-62100` (D at 62100): achieved 53129.7 req/s of 58866 expected at target 62100 (ratio 0.9026)
- `r4-C_iso-52800` (C_iso at 52800): achieved 49346.2 req/s of 50050 expected at target 52800 (ratio 0.9859)
- `r4-C_iso-55900` (C_iso at 55900): achieved 50009.2 req/s of 52989 expected at target 55900 (ratio 0.9438)
- `r4-C_iso-59000` (C_iso at 59000): achieved 50554.6 req/s of 55927 expected at target 59000 (ratio 0.9039)
- `r4-C_iso-62100` (C_iso at 62100): achieved 50754.7 req/s of 58866 expected at target 62100 (ratio 0.8622)
- `r4-D-59000` (D at 59000): achieved 53047.1 req/s of 55927 expected at target 59000 (ratio 0.9485)
- `r4-D-62100` (D at 62100): achieved 52880.3 req/s of 58866 expected at target 62100 (ratio 0.8983)
- `r5-C_iso-55900` (C_iso at 55900): achieved 50281.0 req/s of 52989 expected at target 55900 (ratio 0.9489)
- `r5-C_iso-59000` (C_iso at 59000): achieved 49501.3 req/s of 55927 expected at target 59000 (ratio 0.8851)
- `r5-C_iso-62100` (C_iso at 62100): achieved 50634.8 req/s of 58866 expected at target 62100 (ratio 0.8602)
- `r5-D-59000` (D at 59000): achieved 52565.1 req/s of 55927 expected at target 59000 (ratio 0.9399)
- `r5-D-62100` (D at 62100): achieved 52880.3 req/s of 58866 expected at target 62100 (ratio 0.8983)

