# onContinue check `20261023T101229Z-h641e25acfff3`

seed=1792750349 harness=641e25acfff30777ee7d36b91b41a865465640f7 reps=5
rate_cpu=63400 rate_io=52800 cpu_args= io_args=--think-ms 30 --connections 5000 --pool 2048 --max-connections 16384 --duration 60
boot_id=a3cad3ab-df96-40ee-a417-d3ae0113bb75 uptime_s=142
lazy = -Dloom.bench.pinned.continue=lazy; execute = -Dloom.bench.pinned.continue=execute

p99 over sustained trials; carrier CPU, CPUs utilised and context switches per request are medians over valid trials.

| regime | onContinue | valid / sustained | p99 median | p99, sorted | carrier CPU % | carrier sys % | CPUs (perf) | context switches / req |
|:--|:--|:--|--:|:--|--:|--:|--:|--:|
| cpu | execute | 5 / 5 | 2.62 | 2.60, 2.60, 2.62, 2.67, 2.68 | 137.80 | 91.30 | 1.950 | 0.843 |
| cpu | lazy | 5 / 5 | 2.63 | 2.58, 2.62, 2.63, 2.63, 3.15 | 136.43 | 90.24 | 1.930 | 0.822 |
| io | execute | 5 / 5 | 40.03 | 36.80, 39.97, 40.03, 40.45, 40.48 | 132.35 | 84.26 | 1.916 | 0.806 |
| io | lazy | 5 / 5 | 38.65 | 36.26, 36.86, 38.65, 39.90, 40.10 | 131.03 | 83.44 | 1.853 | 0.802 |

## lazy against execute

The lazy trials against the execute trials, by B_float's reproduction rule (accepted: p ≥ 0.05 and the lazy median inside the execute range).

| regime | n | p99 medians, lazy vs execute | exact MW p | P(lazy > execute) | lazy median inside range | verdict |
|:--|:--|:--|--:|--:|:--|:--|
| cpu | 5 vs 5 | 2.63 vs 2.62 | 0.84 | 0.54 | yes | **accepted** |
| io | 5 vs 5 | 38.65 vs 40.03 | 0.22 | 0.24 | yes | **accepted** |
