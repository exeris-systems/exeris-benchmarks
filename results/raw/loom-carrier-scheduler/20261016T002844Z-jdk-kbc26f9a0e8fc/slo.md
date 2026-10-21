# Capacity at p99 ≤ 5 ms, `20261016T002844Z-jdk-kbc26f9a0e8fc`

Ladder base (median `A_iso` saturation): 74531 req/s. A rate passes when at least 4 trials are valid, every valid trial sustained the rate, and their median p99 is at most 5 ms. Capacity is the highest rate up to which every rate passes.

| arm | capacity | highest passing rate |
|:--|--:|--:|
| A_iso | 37300 (50%) | 37300 (50%) |
| B_pin | 70800 (95%) | 70800 (95%) |
| C_iso | 37300 (50%) | 37300 (50%) |
| D | 70800 (95%) | 70800 (95%) |

| arm | rate | of base | valid / sustained | p99 median | p99, sorted | verdict |
|:--|--:|--:|:--|--:|:--|:--|
| A_iso | 37300 | 50% | 5 / 5 of 5 | 2.65 | 2.63, 2.64, 2.65, 2.66, 2.69 | pass |
| A_iso | 52200 | 70% | 5 / 5 of 5 | 9.81 | 4.23, 5.88, 9.81, 10.88, 13.63 | fail (p99 above SLO) |
| A_iso | 55900 | 75% | 5 / 5 of 5 | 9.06 | 6.39, 8.59, 9.06, 10.70, 17.22 | fail (p99 above SLO) |
| A_iso | 59600 | 80% | 5 / 5 of 5 | 17.90 | 11.18, 16.05, 17.90, 22.33, 50.08 | fail (p99 above SLO) |
| A_iso | 63400 | 85% | 5 / 5 of 5 | 26.27 | 18.78, 23.71, 26.27, 46.37, 56.45 | fail (p99 above SLO) |
| A_iso | 67100 | 90% | 5 / 5 of 5 | 42.53 | 28.06, 32.14, 42.53, 46.40, 52.19 | fail (p99 above SLO) |
| A_iso | 70800 | 95% | 5 / 5 of 5 | 66.88 | 51.52, 52.10, 66.88, 95.23, 109.76 | fail (p99 above SLO) |
| A_iso | 74500 | 100% | 5 / 5 of 5 | 201.85 | 48.86, 97.15, 201.85, 234.62, 247.04 | fail (p99 above SLO) |
| B_pin | 37300 | 50% | 5 / 5 of 5 | 2.62 | 2.60, 2.62, 2.62, 2.63, 2.65 | pass |
| B_pin | 52200 | 70% | 5 / 5 of 5 | 2.52 | 2.52, 2.52, 2.52, 2.57, 2.57 | pass |
| B_pin | 55900 | 75% | 5 / 5 of 5 | 2.62 | 2.60, 2.61, 2.62, 2.63, 2.65 | pass |
| B_pin | 59600 | 80% | 5 / 5 of 5 | 2.67 | 2.65, 2.66, 2.67, 2.68, 2.72 | pass |
| B_pin | 63400 | 85% | 5 / 5 of 5 | 2.75 | 2.69, 2.74, 2.75, 2.76, 2.76 | pass |
| B_pin | 67100 | 90% | 5 / 5 of 5 | 3.12 | 2.74, 2.78, 3.12, 3.26, 15.65 | pass |
| B_pin | 70800 | 95% | 5 / 5 of 5 | 2.92 | 2.89, 2.90, 2.92, 3.24, 3.54 | pass |
| B_pin | 74500 | 100% | 5 / 5 of 5 | 38.21 | 3.23, 17.71, 38.21, 105.73, 128.57 | fail (p99 above SLO) |
| C_iso | 37300 | 50% | 5 / 5 of 5 | 2.68 | 2.65, 2.67, 2.68, 2.69, 2.69 | pass |
| C_iso | 52200 | 70% | 5 / 5 of 5 | 14.16 | 8.34, 12.52, 14.16, 23.22, 24.62 | fail (p99 above SLO) |
| C_iso | 55900 | 75% | 5 / 5 of 5 | 26.46 | 15.97, 19.28, 26.46, 40.93, 44.67 | fail (p99 above SLO) |
| C_iso | 59600 | 80% | 5 / 5 of 5 | 41.31 | 18.74, 28.43, 41.31, 46.24, 61.34 | fail (p99 above SLO) |
| C_iso | 63400 | 85% | 5 / 5 of 5 | 98.43 | 51.17, 61.34, 98.43, 107.78, 112.13 | fail (p99 above SLO) |
| C_iso | 67100 | 90% | 5 / 5 of 5 | 162.69 | 54.33, 121.73, 162.69, 216.96, 243.07 | fail (p99 above SLO) |
| C_iso | 70800 | 95% | 5 / 1 of 5 | 796.67 | 491.01, 612.35, 796.67, 1050.00, 2270.00 | fail (rate not sustained) |
| C_iso | 74500 | 100% | 5 / 0 of 5 | 1740.00 | 1420.00, 1670.00, 1740.00, 1820.00, 2120.00 | fail (rate not sustained) |
| D | 37300 | 50% | 5 / 5 of 5 | 2.68 | 2.66, 2.67, 2.68, 2.72, 2.72 | pass |
| D | 52200 | 70% | 5 / 5 of 5 | 2.53 | 2.52, 2.53, 2.53, 2.56, 2.94 | pass |
| D | 55900 | 75% | 5 / 5 of 5 | 2.56 | 2.54, 2.56, 2.56, 2.58, 2.82 | pass |
| D | 59600 | 80% | 5 / 5 of 5 | 2.64 | 2.63, 2.63, 2.64, 2.67, 2.90 | pass |
| D | 63400 | 85% | 5 / 5 of 5 | 2.63 | 2.59, 2.62, 2.63, 2.63, 2.71 | pass |
| D | 67100 | 90% | 5 / 5 of 5 | 2.71 | 2.64, 2.67, 2.71, 2.72, 3.17 | pass |
| D | 70800 | 95% | 5 / 5 of 5 | 2.78 | 2.72, 2.77, 2.78, 2.88, 3.09 | pass |
| D | 74500 | 100% | 5 / 5 of 5 | 59.39 | 5.51, 59.07, 59.39, 88.45, 231.55 | fail (p99 above SLO) |

## Reproduction check: B_float against A_iso

Accepted when the exact two-sided Mann-Whitney p >= 0.05 and B_float's median p99 lies inside A_iso's range; if not, B_pin is read against B_float.

| rate | B_float p99, sorted | A_iso p99, sorted | sustained B_float / A_iso | p | verdict |
|--:|:--|:--|:--|--:|:--|
| 63400 | 23.01, 29.44, 38.94, 44.86, 102.33 | 18.78, 23.71, 26.27, 46.37, 56.45 | 5 / 5 | 0.69 | accepted |
