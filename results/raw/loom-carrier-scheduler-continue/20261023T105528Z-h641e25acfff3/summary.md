# onContinue check `20261023T105528Z-h641e25acfff3`

seed=1792752928 harness=641e25acfff30777ee7d36b91b41a865465640f7 reps=5
rate_cpu=63400 rate_io=52800 cpu_args= io_args=--think-ms 30 --connections 5000 --pool 2048 --max-connections 16384 --duration 60
boot_id=a3cad3ab-df96-40ee-a417-d3ae0113bb75 uptime_s=2721
lazy = -Dloom.bench.pinned.continue=lazy; execute = -Dloom.bench.pinned.continue=execute

p99 over sustained trials; carrier CPU, CPUs utilised and context switches per request are medians over valid trials.

| regime | onContinue | valid / sustained | p99 median | p99, sorted | carrier CPU % | carrier sys % | CPUs (perf) | context switches / req |
|:--|:--|:--|--:|:--|--:|--:|--:|--:|
| cpu | execute | 5 / 5 | 2.62 | 2.59, 2.62, 2.62, 2.63, 2.67 | 137.97 | 91.70 | 1.946 | 0.845 |
| cpu | lazy | 5 / 5 | 2.65 | 2.64, 2.64, 2.65, 2.74, 6.18 | 136.30 | 90.40 | 1.935 | 0.825 |
| io | execute | 5 / 5 | 39.23 | 37.28, 37.95, 39.23, 40.00, 40.26 | 131.97 | 83.95 | 1.886 | 0.854 |
| io | lazy | 5 / 5 | 39.74 | 38.14, 38.40, 39.74, 40.13, 40.64 | 131.02 | 83.67 | 1.870 | 0.840 |

## lazy against execute

The lazy trials against the execute trials, by B_float's reproduction rule (accepted: p ≥ 0.05 and the lazy median inside the execute range).

| regime | n | p99 medians, lazy vs execute | exact MW p | P(lazy > execute) | lazy median inside range | verdict |
|:--|:--|:--|--:|--:|:--|:--|
| cpu | 5 vs 5 | 2.65 vs 2.62 | 0.056 | 0.88 | yes | **accepted** |
| io | 5 vs 5 | 39.74 vs 39.23 | 0.55 | 0.64 | yes | **accepted** |
