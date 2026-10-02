# Loom Cache Locality Concurrency Sweep Report

**Date:** niedz., 27 wrz 2026, 19:57:08 CEST
**Hardware:** AMD Ryzen 5 5600 6-Core (Zen 3, single CCX, 32MB L3, 6x 512KB L2)
**Workload:** `/delayed` (20 ms simulated backend delay, 8 KB state touched per request)
**Fixed Rate:** 3,000 req/s

## Concurrency Level: 100 Connections (Estimated Working Set: ~0.8 MB)

| Config | Description | Actual RPS | p50 | p90 | p99 | Worst p99 | p99.9 | Total CPU (%) | Carrier CPU (%) | Carrier %wait |
| :---: | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **A** | Stock FJP (unconstrained, floating across 0-3,6-7) | 2961.9 [2961.8 - 2962.0] | 20.83 ms [20.83 ms - 20.83 ms] | 21.41 ms [21.41 ms - 21.42 ms] | 22.02 ms [21.98 ms - 22.05 ms] | **22.05 ms** | 23.90 ms [23.69 ms - 24.11 ms] | 24.9 [24.2 - 25.6] | 12.6 [12.4 - 12.8] | 0.2 [0.2 - 0.3] |
| **A_iso** | Stock FJP (isolated: carriers on {2,3}, aux on 0,1,6,7) | 2961.7 [2961.6 - 2961.7] | 20.82 ms [20.82 ms - 20.83 ms] | 21.39 ms [21.36 ms - 21.41 ms] | 21.93 ms [21.90 ms - 21.95 ms] | **21.95 ms** | 23.59 ms [23.42 ms - 23.76 ms] | 24.5 [23.2 - 25.8] | 11.9 [11.6 - 12.2] | 1.4 [1.2 - 1.6] |
| **C_iso** | ExerisCarrierScheduler (isolated: carriers floating on {2,3}, aux on 0,1,6,7) | 2962.0 [2961.9 - 2962.0] | 20.81 ms [20.80 ms - 20.82 ms] | 21.39 ms [21.38 ms - 21.39 ms] | 22.00 ms [22.00 ms - 22.00 ms] | **22.00 ms** | 23.81 ms [23.81 ms - 23.81 ms] | 114.5 [114.0 - 115.1] | 96.9 [95.9 - 97.9] | 0.3 [0.2 - 0.5] |
| **D** | ExerisCarrierScheduler (1:1 pinned: carrier 0 on Core 2, carrier 1 on Core 3, aux on 0,1,6,7) | 2961.9 [2961.7 - 2962.1] | 20.81 ms [20.80 ms - 20.82 ms] | 21.40 ms [21.38 ms - 21.42 ms] | 22.04 ms [21.95 ms - 22.13 ms] | **22.13 ms** | 23.91 ms [23.63 ms - 24.19 ms] | 141.6 [139.5 - 143.7] | 127.7 [126.1 - 129.4] | 0.4 [0.3 - 0.4] |

## Concurrency Level: 1000 Connections (Estimated Working Set: ~7.8 MB)

| Config | Description | Actual RPS | p50 | p90 | p99 | Worst p99 | p99.9 | Total CPU (%) | Carrier CPU (%) | Carrier %wait |
| :---: | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **A** | Stock FJP (unconstrained, floating across 0-3,6-7) | 2667.6 [2667.6 - 2667.7] | 20.82 ms [20.82 ms - 20.83 ms] | 21.40 ms [21.39 ms - 21.41 ms] | 21.99 ms [21.98 ms - 22.00 ms] | **22.00 ms** | 24.07 ms [23.76 ms - 24.37 ms] | 28.0 [26.9 - 29.2] | 13.5 [13.4 - 13.6] | 0.1 [0.1 - 0.1] |
| **A_iso** | Stock FJP (isolated: carriers on {2,3}, aux on 0,1,6,7) | 2667.4 [2667.2 - 2667.6] | 20.82 ms [20.82 ms - 20.83 ms] | 21.41 ms [21.39 ms - 21.42 ms] | 22.16 ms [21.95 ms - 22.38 ms] | **22.38 ms** | 25.39 ms [24.88 ms - 25.89 ms] | 26.8 [25.7 - 27.9] | 12.8 [12.6 - 13.0] | 1.5 [1.3 - 1.7] |
| **C_iso** | ExerisCarrierScheduler (isolated: carriers floating on {2,3}, aux on 0,1,6,7) | 2667.4 [2667.3 - 2667.5] | 20.78 ms [20.78 ms - 20.78 ms] | 21.34 ms [21.33 ms - 21.36 ms] | 22.00 ms [22.00 ms - 22.01 ms] | **22.01 ms** | 24.75 ms [24.40 ms - 25.09 ms] | 112.4 [80.0 - 144.9] | 94.8 [63.4 - 126.2] | 0.2 [0.2 - 0.3] |
| **D** | ExerisCarrierScheduler (1:1 pinned: carrier 0 on Core 2, carrier 1 on Core 3, aux on 0,1,6,7) | 2648.0 [2628.7 - 2667.4] | 20.84 ms [20.82 ms - 20.86 ms] | 21.50 ms [21.38 ms - 21.61 ms] | 22.73 ms [22.01 ms - 23.45 ms] | **23.45 ms** | 27.55 ms [25.01 ms - 30.08 ms] | 123.3 [104.1 - 142.5] | 107.9 [86.4 - 129.4] | 0.3 [0.2 - 0.5] |

## Concurrency Level: 10000 Connections (Estimated Working Set: ~78.1 MB)

| Config | Description | Actual RPS | p50 | p90 | p99 | Worst p99 | p99.9 | Total CPU (%) | Carrier CPU (%) | Carrier %wait |
| :---: | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **A** | Stock FJP (unconstrained, floating across 0-3,6-7) | 272.4 [271.8 - 273.1] | 22.25 ms [22.19 ms - 22.30 ms] | 24.79 ms [24.78 ms - 24.80 ms] | 48.43 ms [48.38 ms - 48.48 ms] | **48.48 ms** | 51.60 ms [51.55 ms - 51.65 ms] | 11.7 [11.7 - 11.7] | 2.8 [2.7 - 2.8] | 0.0 [0.0 - 0.0] |
| **A_iso** | Stock FJP (isolated: carriers on {2,3}, aux on 0,1,6,7) | 272.5 [272.4 - 272.5] | 22.28 ms [22.27 ms - 22.29 ms] | 24.70 ms [24.69 ms - 24.70 ms] | 47.94 ms [47.55 ms - 48.32 ms] | **48.32 ms** | 51.16 ms [50.75 ms - 51.58 ms] | 12.5 [12.1 - 12.9] | 2.8 [2.7 - 2.9] | 0.2 [0.1 - 0.2] |
| **C_iso** | ExerisCarrierScheduler (isolated: carriers floating on {2,3}, aux on 0,1,6,7) | 272.2 [271.9 - 272.4] | 22.35 ms [22.33 ms - 22.37 ms] | 25.03 ms [25.02 ms - 25.04 ms] | 49.02 ms [47.49 ms - 50.56 ms] | **50.56 ms** | 52.26 ms [50.85 ms - 53.66 ms] | 123.7 [111.9 - 135.6] | 112.0 [100.8 - 123.3] | 0.2 [0.1 - 0.2] |
| **D** | ExerisCarrierScheduler (1:1 pinned: carrier 0 on Core 2, carrier 1 on Core 3, aux on 0,1,6,7) | 273.1 [273.0 - 273.1] | 22.59 ms [22.24 ms - 22.94 ms] | 28.50 ms [24.72 ms - 32.27 ms] | 60.37 ms [48.22 ms - 72.51 ms] | **72.51 ms** | 63.24 ms [51.42 ms - 75.07 ms] | 111.2 [11.0 - 211.5] | 100.6 [1.5 - 199.7] | 0.1 [0.0 - 0.2] |
