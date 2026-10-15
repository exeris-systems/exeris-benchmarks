# loom-carrier-scheduler campaign `20261013T062036Z-jdk-kbc26f9a0e8fc`

- backend: `jdk`, arms: `A_iso C_iso D`, reps: 10
- ladder base (median A_iso saturation): 60275 req/s; rates: 30100 42200 51200
- seed: `1791872436`; extra trial args: `--poller-mode 3 --warmup-mode open --warmup 30 --think-ms 30 --connections 5000 --pool 5000 --max-connections 16384 --duration 60`
- kernel: `bc26f9a0e8fc56bf922aa7515b8f29cc2aac869d`; JDK: OpenJDK Runtime Environment (build 28-testing-builds.shipilev.net-openjdk-jdk-loom-b18-20260917-2133)
- host shielded (host-shield.sh, no graphical session): 99 of 99 trials
- evidence-eligible (every trial's measurement valid, harness committed, host shielded): **False**

| backend | rate | arm | sustained | req/s (median) | p50 | p90 | p99 (median) | p99 all trials | worst p99 | p99.9 | carrier CPU % | carrier %wait max | CPUs (perf) | IPC | cs/s |
|:--|---:|:--|--:|--:|--:|--:|--:|:--|--:|--:|--:|--:|--:|--:|--:|
| jdk | max | A_iso | 3 of 3 | 60276 | 76.76 | 109.65 | 150.64 | 150.64, 171.45, 147.88 | 171.45 | — | 164.8 | 5.8 | 2.56 | 0.76 | 27842 |
| jdk | max | C_iso | 3 of 3 | 61450 | 75.64 | 110.18 | 128.86 | 126.31, 128.86, 137.71 | 137.71 | — | 162.1 | 9.1 | 2.54 | 0.75 | 30931 |
| jdk | max | D | 3 of 3 | 63328 | 76.08 | 95.22 | 120.89 | 123.13, 119.93, 120.89 | 123.13 | — | 167.2 | 0.1 | 2.65 | 0.74 | 34954 |
| jdk | 30100 | A_iso | 9 of 9 | 28555 | 31.69 | 32.90 | 92.16 | 92.16, 33.63, 56.96, 105.02, 55.17, 122.94, 77.44, 94.65, 168.45 | 168.45 | 257.02 | 93.5 | 0.2 | 1.32 | 0.73 | 36380 |
| jdk | 30100 | C_iso | 7 of 7 | 28544 | 31.73 | 33.22 | 76.54 | 87.04, 109.06, 76.54, 55.55, 69.76, 100.93, 74.11 | 109.06 | 234.88 | 87.4 | 0.3 | 1.26 | 0.75 | 32394 |
| jdk | 30100 | D | 8 of 8 | 28549 | 31.70 | 33.06 | 83.04 | 75.90, 53.73, 53.18, 95.61, 175.10, 73.15, 166.40, 90.18 | 175.10 | 285.44 | 86.7 | 0.0 | 1.23 | 0.74 | 32755 |
| jdk | 42200 | A_iso | 7 of 7 | 40017 | 32.17 | 36.83 | 147.07 | 89.15, 279.81, 191.36, 146.82, 161.66, 147.07, 95.29 | 279.81 | 249.60 | 122.2 | 3.8 | 1.76 | 0.74 | 39630 |
| jdk | 42200 | C_iso | 4 of 4 | 40017 | 32.23 | 43.33 | 166.91 | 132.86, 212.35, 155.90, 177.92 | 212.35 | 233.66 | 114.4 | 5.9 | 1.62 | 0.75 | 33845 |
| jdk | 42200 | D | 8 of 8 | 40002 | 32.13 | 35.40 | 260.48 | 86.01, 258.30, 212.61, 332.54, 307.71, 262.65, 282.37, 187.52 | 332.54 | 331.90 | 118.1 | 0.0 | 1.68 | 0.75 | 38668 |
| jdk | 51200 | A_iso | 8 of 8 | 48533 | 45.28 | 144.64 | 296.32 | 282.88, 279.55, 204.93, 309.76, 325.12, 319.49, 480.00, 194.69 | 480.00 | 352.64 | 140.9 | 11.2 | 2.06 | 0.72 | 32406 |
| jdk | 51200 | C_iso | 8 of 8 | 48498 | 60.37 | 148.93 | 281.21 | 291.33, 486.91, 446.46, 214.27, 254.72, 271.10, 181.76, 311.55 | 486.91 | 450.18 | 135.0 | 16.6 | 1.95 | 0.75 | 26644 |
| jdk | 51200 | D | 6 of 6 | 48531 | 32.31 | 70.72 | 307.20 | 149.89, 295.68, 376.58, 318.72, 352.77, 164.22 | 376.58 | 364.80 | 140.6 | 0.0 | 2.00 | 0.74 | 44021 |

Latencies in ms. Percentiles from wrk2 (open loop, coordinated-omission corrected) for numeric rates and from wrk (closed loop) for `max`; closed-loop latency is not a latency result.

## Invalid trials (a measurement gate failed; excluded from every statistic)

- `r1-D-51200`: failed isolation — {"isolation": {"pass": false, "problems": ["exeris-..rier-1 allowed 0,6, expected one CPU of [2, 3]"], "carriers": {"exeris-carrier-0": [2], "exeris-..rier-1": [0, 6]}}}
- `r10-A_iso-42200`: failed isolation — {"isolation": {"pass": false, "problems": ["ForkJoi..rker-1 allowed 0,6, expected [2, 3]", "ForkJoi..rker-2 allowed 0,6, expected [2, 3]"], "carriers": {"ForkJoi..rker-1": [0, 6], "ForkJoi..rker-2": [0, 6]}}}
- `r10-C_iso-42200`: failed isolation — {"isolation": {"pass": false, "problems": ["exeris-..rier-1 allowed 0,6, expected [2, 3]"], "carriers": {"exeris-carrier-0": [2, 3], "exeris-..rier-1": [0, 6]}}}
- `r10-C_iso-51200`: failed isolation — {"isolation": {"pass": false, "problems": ["exeris-..rier-0 allowed 0,6, expected [2, 3]", "exeris-..rier-1 allowed 0,6, expected [2, 3]"], "carriers": {"exeris-..rier-0": [0, 6], "exeris-..rier-1": [0, 6]}}}
- `r10-D-30100`: failed isolation — {"isolation": {"pass": false, "problems": ["exeris-..rier-1 allowed 0,6, expected one CPU of [2, 3]"], "carriers": {"exeris-carrier-0": [2], "exeris-..rier-1": [0, 6]}}}
- `r2-A_iso-51200`: failed isolation — {"isolation": {"pass": false, "problems": ["ForkJoi..rker-2 allowed 0,6, expected [2, 3]"], "carriers": {"ForkJoinPool-1-worker-1": [2, 3], "ForkJoi..rker-2": [0, 6]}}}
- `r2-C_iso-30100`: failed isolation — {"isolation": {"pass": false, "problems": ["exeris-..rier-0 allowed 0,6, expected [2, 3]"], "carriers": {"exeris-..rier-0": [0, 6], "exeris-carrier-1": [2, 3]}}}
- `r2-C_iso-42200`: failed isolation — {"isolation": {"pass": false, "problems": ["exeris-..rier-0 allowed 0,6, expected [2, 3]"], "carriers": {"exeris-..rier-0": [0, 6], "exeris-carrier-1": [2, 3]}}}
- `r2-C_iso-51200`: failed isolation — {"isolation": {"pass": false, "problems": ["exeris-..rier-0 allowed 0,6, expected [2, 3]", "exeris-..rier-1 allowed 0,6, expected [2, 3]"], "carriers": {"exeris-..rier-0": [0, 6], "exeris-..rier-1": [0, 6]}}}
- `r4-C_iso-30100`: failed isolation — {"isolation": {"pass": false, "problems": ["exeris-..rier-0 allowed 0,6, expected [2, 3]"], "carriers": {"exeris-..rier-0": [0, 6], "exeris-carrier-1": [2, 3]}}}
- `r4-C_iso-42200`: failed isolation — {"isolation": {"pass": false, "problems": ["exeris-..rier-1 allowed 0,6, expected [2, 3]"], "carriers": {"exeris-carrier-0": [2, 3], "exeris-..rier-1": [0, 6]}}}
- `r4-D-42200`: failed isolation — {"isolation": {"pass": false, "problems": ["exeris-..rier-0 allowed 0,6, expected one CPU of [2, 3]", "exeris-..rier-1 allowed 0,6, expected one CPU of [2, 3]"], "carriers": {"exeris-..rier-0": [0, 6], "exeris-..rier-1": [0, 6]}}}
- `r4-D-51200`: failed isolation — {"isolation": {"pass": false, "problems": ["exeris-..rier-0 allowed 0,6, expected one CPU of [2, 3]", "exeris-..rier-1 allowed 0,6, expected one CPU of [2, 3]"], "carriers": {"exeris-..rier-0": [0, 6], "exeris-..rier-1": [0, 6]}}}
- `r5-A_iso-42200`: failed isolation — {"isolation": {"pass": false, "problems": ["ForkJoi..rker-1 allowed 0,6, expected [2, 3]", "ForkJoi..rker-2 allowed 0,6, expected [2, 3]"], "carriers": {"ForkJoi..rker-1": [0, 6], "ForkJoi..rker-2": [0, 6]}}}
- `r5-C_iso-42200`: failed isolation — {"isolation": {"pass": false, "problems": ["exeris-..rier-0 allowed 0,6, expected [2, 3]"], "carriers": {"exeris-..rier-0": [0, 6], "exeris-carrier-1": [2, 3]}}}
- `r5-D-42200`: failed isolation — {"isolation": {"pass": false, "problems": ["exeris-..rier-0 allowed 0,6, expected one CPU of [2, 3]", "exeris-..rier-1 allowed 0,6, expected one CPU of [2, 3]"], "carriers": {"exeris-..rier-0": [0, 6], "exeris-..rier-1": [0, 6]}}}
- `r6-C_iso-30100`: failed isolation — {"isolation": {"pass": false, "problems": ["exeris-..rier-1 allowed 0,6, expected [2, 3]"], "carriers": {"exeris-carrier-0": [2, 3], "exeris-..rier-1": [0, 6]}}}
- `r6-C_iso-42200`: failed isolation — {"isolation": {"pass": false, "problems": ["exeris-..rier-0 allowed 0,6, expected [2, 3]", "exeris-..rier-1 allowed 0,6, expected [2, 3]"], "carriers": {"exeris-..rier-0": [0, 6], "exeris-..rier-1": [0, 6]}}}
- `r6-D-30100`: failed isolation — {"isolation": {"pass": false, "problems": ["exeris-..rier-0 allowed 0,6, expected one CPU of [2, 3]"], "carriers": {"exeris-..rier-0": [0, 6], "exeris-carrier-1": [3]}}}
- `r6-D-51200`: failed isolation — {"isolation": {"pass": false, "problems": ["exeris-..rier-1 allowed 0,6, expected one CPU of [2, 3]"], "carriers": {"exeris-carrier-0": [2], "exeris-..rier-1": [0, 6]}}}
- `r7-A_iso-51200`: failed isolation — {"isolation": {"pass": false, "problems": ["ForkJoi..rker-1 allowed 0,6, expected [2, 3]", "ForkJoi..rker-2 allowed 0,6, expected [2, 3]"], "carriers": {"ForkJoi..rker-1": [0, 6], "ForkJoi..rker-2": [0, 6]}}}
- `r7-D-51200`: failed isolation — {"isolation": {"pass": false, "problems": ["exeris-..rier-0 allowed 0,6, expected one CPU of [2, 3]"], "carriers": {"exeris-..rier-0": [0, 6], "exeris-carrier-1": [3]}}}
- `r9-A_iso-30100`: failed isolation — {"isolation": {"pass": false, "problems": ["ForkJoi..rker-1 allowed 0,6, expected [2, 3]"], "carriers": {"ForkJoi..rker-1": [0, 6], "ForkJoinPool-1-worker-2": [2, 3]}}}
- `r9-A_iso-42200`: failed isolation — {"isolation": {"pass": false, "problems": ["ForkJoi..rker-1 allowed 0,6, expected [2, 3]", "ForkJoi..rker-2 allowed 0,6, expected [2, 3]"], "carriers": {"ForkJoi..rker-1": [0, 6], "ForkJoi..rker-2": [0, 6]}}}
- `r9-C_iso-42200`: failed isolation — {"isolation": {"pass": false, "problems": ["exeris-..rier-1 allowed 0,6, expected [2, 3]"], "carriers": {"exeris-carrier-0": [2, 3], "exeris-..rier-1": [0, 6]}}}
