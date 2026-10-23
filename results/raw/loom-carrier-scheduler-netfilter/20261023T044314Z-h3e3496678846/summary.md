# Netfilter check `20261023T044314Z-h3e3496678846`

seed=1792730594 harness=3e34966788465b4f4aa236e9029c1553c99d5235 rate=52200 reps=5
boot_id=e9ac2233-132a-4528-8a23-d07c52986ad9 uptime_s=1470
notrack = iptables -t raw -I {PREROUTING -i lo, OUTPUT -o lo} -j CT --notrack

p99 over sustained trials; carrier CPU, wait, CPUs utilised and conntrack entries are medians over valid trials.

| arm | loopback | valid / sustained | p99 median | p99, sorted | carrier CPU % | carrier sys % | carrier wait max % | CPUs (perf) | conntrack entries |
|:--|:--|:--|--:|:--|--:|--:|--:|--:|--:|
| A_iso | notrack | 5 / 5 | 2.7 | 2.52, 2.57, 2.70, 2.79, 3.31 | 126.9 | 85.6 | 1.07 | 1.767 | 253.0 |
| A_iso | tracked | 5 / 5 | 8.59 | 5.54, 7.64, 8.59, 9.31, 12.49 | 130.07 | 89.1 | 2.77 | 1.795 | 368.0 |
| D | notrack | 5 / 5 | 2.52 | 2.50, 2.51, 2.52, 2.52, 2.72 | 123.02 | 86.94 | 0.03 | 1.764 | 199.0 |
| D | tracked | 5 / 5 | 2.56 | 2.52, 2.54, 2.56, 2.58, 2.62 | 126.1 | 89.7 | 0.03 | 1.772 | 396.0 |

## tracked against notrack

| arm | n | p99 medians | exact MW p | P(tracked > notrack) |
|:--|:--|:--|--:|--:|
| A_iso | 5 vs 5 | 8.59 vs 2.70 | 0.0079 | 1.00 |
| D | 5 vs 5 | 2.56 vs 2.52 | 0.22 | 0.76 |
