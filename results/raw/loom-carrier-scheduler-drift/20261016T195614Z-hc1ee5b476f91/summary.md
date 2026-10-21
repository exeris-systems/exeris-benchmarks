# Drift check `20261016T195614Z-hc1ee5b476f91`

seed=1792180574 harness=c1ee5b476f91f68ba31cb55403469fc8f7290377 rate=52200 reps=5
pool old = app at 84685a1c; pool new = this checkout's app
limits old = 1024:524288; limits new = the shield's, raised to the hard limit

p99 over sustained trials; carrier CPU, wait and CPUs utilised are medians over valid trials.

| arm | pool | limits | valid / sustained | p99 median | p99, sorted | carrier CPU % | carrier sys % | carrier wait max % | CPUs (perf) | cs/s |
|:--|:--|:--|:--|--:|:--|--:|--:|--:|--:|--:|
| A_iso | new | new | 5 / 5 | 7.23 | 5.77, 5.92, 7.23, 7.56, 8.64 | 129.34 | 89.73 | 1.57 | 1.814 | 43968.9 |
| A_iso | old | new | 5 / 5 | 19.25 | 6.39, 6.75, 19.25, 38.01, 328.70 | 129.26 | 89.4 | 1.77 | 1.809 | 43440.5 |
| D | new | new | 5 / 5 | 5.34 | 4.00, 4.98, 5.34, 82.56, 248.32 | 126.02 | 89.73 | 0.0 | 1.797 | 45852.4 |

## A_iso: each factor at its two levels

| factor | compared | n | p99 medians | exact MW p | P(first > second) |
|:--|:--|:--|:--|--:|--:|
| pool | old vs new, both limits | 5 vs 5 | 19.25 vs 7.23 | 0.22 | 0.76 |
| pool | old vs new, limits old | 0 vs 0 | — | — | — |
| pool | old vs new, limits new | 5 vs 5 | 19.25 vs 7.23 | 0.22 | 0.76 |
| limits | old vs new, both pools | 0 vs 10 | — | — | — |
| limits | old vs new, pool old | 0 vs 5 | — | — | — |
| limits | old vs new, pool new | 0 vs 5 | — | — | — |
