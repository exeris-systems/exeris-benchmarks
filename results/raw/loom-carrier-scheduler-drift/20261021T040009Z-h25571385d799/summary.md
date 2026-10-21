# Drift check `20261021T040009Z-h25571385d799`

seed=1792555209 harness=25571385d7996a146953287b72d421340c31804d rate=52200 reps=5
pool old = app at 84685a1c; pool new = this checkout's app
limits old = 1024:524288; limits new = the shield's, raised to the hard limit

p99 over sustained trials; carrier CPU, wait and CPUs utilised are medians over valid trials.

| arm | pool | limits | valid / sustained | p99 median | p99, sorted | carrier CPU % | carrier sys % | carrier wait max % | CPUs (perf) | cs/s |
|:--|:--|:--|:--|--:|:--|--:|--:|--:|--:|--:|
| A_iso | new | new | 5 / 5 | 2.46 | 2.45, 2.45, 2.46, 2.50, 2.76 | 119.9 | 79.36 | 0.1 | 1.676 | 48446.7 |
| A_iso | new | old | 5 / 5 | 2.47 | 2.45, 2.45, 2.47, 2.48, 2.51 | 119.93 | 79.14 | 0.1 | 1.707 | 50636.2 |
| A_iso | old | new | 5 / 5 | 2.46 | 2.44, 2.45, 2.46, 2.46, 2.48 | 120.0 | 79.08 | 0.1 | 1.672 | 48164.4 |
| A_iso | old | old | 5 / 5 | 2.46 | 2.45, 2.45, 2.46, 2.48, 2.52 | 119.56 | 79.23 | 0.13 | 1.675 | 49075.5 |
| D | new | new | 5 / 5 | 2.47 | 2.46, 2.46, 2.47, 2.47, 2.47 | 115.73 | 80.04 | 0.03 | 1.675 | 52802.7 |

## A_iso: each factor at its two levels

| factor | compared | n | p99 medians | exact MW p | P(first > second) |
|:--|:--|:--|:--|--:|--:|
| pool | old vs new, both limits | 10 vs 10 | 2.46 vs 2.46 | 0.53 | 0.41 |
| pool | old vs new, limits old | 5 vs 5 | 2.46 vs 2.47 | 1 | 0.50 |
| pool | old vs new, limits new | 5 vs 5 | 2.46 vs 2.46 | 0.55 | 0.36 |
| limits | old vs new, both pools | 10 vs 10 | 2.46 vs 2.46 | 0.68 | 0.56 |
| limits | old vs new, pool old | 5 vs 5 | 2.46 vs 2.46 | 0.55 | 0.62 |
| limits | old vs new, pool new | 5 vs 5 | 2.47 vs 2.46 | 1 | 0.48 |
