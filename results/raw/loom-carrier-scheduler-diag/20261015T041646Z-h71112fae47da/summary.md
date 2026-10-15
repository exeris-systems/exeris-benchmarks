# Diagnostics `20261015T041646Z-h71112fae47da`

Every trial ran with a latency probe and at least one recorder: latencies here are diagnostic, not results. *Slow* means a probe request above the trial's threshold (twice its median), merged into windows; each recorder is compared inside those windows against outside them.

## Light trials by cell and pollerMode

The least perturbed trials (probe and GC log only). Across fresh JVMs; the D-at-70 % question is whether the split into fast and slow JVMs survives a change of pollerMode.

| arm | rate | pollerMode | n | wrk2 p99, sorted | probe slow ms, sorted |
|:--|--:|--:|--:|:--|:--|
| A_iso | 52600 | 3 | 3 | 113.9, 118.0, 129.7 | 6047, 8530, 9330 |
| C_iso | 52600 | 3 | 3 | 64.1, 64.7, 65.6 | 1638, 1941, 2663 |
| D | 43300 | 1 | 6 | 38.7, 39.4, 47.4, 60.5, 71.4, 100.0 | 68, 249, 582, 832, 878, 1060 |
| D | 43300 | 3 | 9 | 39.2, 39.3, 43.5, 48.1, 56.7, 56.7, 84.9, 91.1, 97.3 | 66, 106, 373, 466, 520, 728, 1210, 1349, 1398 |

## Probe and pauses

| trial | kind | wrk2 p99 | probe p99 | probe max | slow windows | slow ms | longest ms | server GC+safepoint: max ms / % of slow time | mock: max ms / % |
|:--|:--|--:|--:|--:|--:|--:|--:|:--|:--|
| r1-A_iso-52600-p3-jfr | jfr | 118.91 | 110.28 | 166.47 | 32 | 9254.4 | 782.5 | 25.26 / 2.1 | 6.3 / 0.3 |
| r2-A_iso-52600-p3-jfr | jfr | 89.47 | 89.03 | 174.01 | 28 | 6506.6 | 587.6 | 31.52 / 2.0 | 4.19 / 0.0 |
| r3-A_iso-52600-p3-jfr | jfr | 153.21 | 135.75 | 227.76 | 25 | 9286.8 | 1362.7 | 28.56 / 1.3 | 4.74 / 0.2 |
| r1-A_iso-52600-p3-light | light | 129.66 | 105.94 | 204.44 | 29 | 9330.4 | 1648.3 | 27.26 / 2.2 | 6.44 / 0.2 |
| r2-A_iso-52600-p3-light | light | 118.01 | 110.18 | 161.65 | 25 | 8530.2 | 1398.9 | 25.73 / 1.7 | 4.33 / 0.2 |
| r3-A_iso-52600-p3-light | light | 113.92 | 102.62 | 192.98 | 29 | 6047.2 | 1163.2 | 29.94 / 2.9 | 4.42 / 0.1 |
| r1-A_iso-52600-p3-sched | sched | 139.01 | 122.25 | 207.21 | 25 | 9059.9 | 1417.4 | 24.61 / 2.2 | 5.38 / 0.2 |
| r2-A_iso-52600-p3-sched | sched | 112.19 | 112.52 | 210.27 | 33 | 9995.5 | 889.9 | 30.91 / 2.8 | 5.48 / 0.2 |
| r3-A_iso-52600-p3-sched | sched | 147.46 | 126.58 | 239.63 | 29 | 8947.1 | 1453.1 | 52.19 / 4.1 | 4.95 / 0.3 |
| r1-A_iso-52600-p3-wall | wall | 121.34 | 126.03 | 210.64 | 27 | 11661.5 | 2239.3 | 29.53 / 1.7 | 5.76 / 0.1 |
| r2-A_iso-52600-p3-wall | wall | 117.06 | 105.48 | 168.48 | 32 | 7495.3 | 863.3 | 26.78 / 3.2 | 4.4 / 0.0 |
| r3-A_iso-52600-p3-wall | wall | 181.76 | 159.79 | 258.33 | 16 | 6941.9 | 1578.2 | 27.42 / 2.1 | 7.24 / 0.5 |
| r1-C_iso-52600-p3-jfr | jfr | 75.26 | 75.38 | 97.88 | 20 | 3857.4 | 484.6 | 28.01 / 8.6 | 5.63 / 0.2 |
| r2-C_iso-52600-p3-jfr | jfr | 66.24 | 64.0 | 78.89 | 10 | 1576.1 | 395.4 | 24.74 / 6.3 | 6.5 / 0.0 |
| r3-C_iso-52600-p3-jfr | jfr | 72.13 | 75.68 | 96.49 | 13 | 3283.2 | 713.4 | 26.34 / 4.1 | 4.86 / 0.9 |
| r1-C_iso-52600-p3-light | light | 65.6 | 72.51 | 97.7 | 12 | 2663.4 | 749.8 | 28.81 / 5.7 | 7.4 / 0.7 |
| r2-C_iso-52600-p3-light | light | 64.06 | 62.61 | 76.69 | 13 | 1638.2 | 293.6 | 29.56 / 13.3 | 6.98 / 0.9 |
| r3-C_iso-52600-p3-light | light | 64.74 | 70.96 | 122.43 | 9 | 1941.4 | 613.5 | 28.55 / 10.3 | 7.03 / 0.0 |
| r1-C_iso-52600-p3-sched | sched | 66.18 | 93.17 | 110.05 | 10 | 3365.1 | 905.3 | 39.28 / 6.8 | 4.63 / 0.0 |
| r2-C_iso-52600-p3-sched | sched | 63.84 | 65.25 | 90.23 | 7 | 1512.5 | 444.3 | 26.62 / 10.2 | 7.34 / 0.0 |
| r3-C_iso-52600-p3-sched | sched | 69.5 | 75.73 | 128.65 | 12 | 3126.7 | 584.3 | 28.04 / 8.0 | 6.75 / 0.2 |
| r1-C_iso-52600-p3-wall | wall | 68.54 | 69.81 | 108.2 | 9 | 1533.2 | 365.6 | 29.8 / 8.4 | 6.56 / 0.6 |
| r2-C_iso-52600-p3-wall | wall | 79.29 | 82.39 | 99.52 | 16 | 3645.9 | 720.3 | 28.79 / 5.4 | 4.21 / 0.4 |
| r3-C_iso-52600-p3-wall | wall | 69.06 | 72.5 | 90.92 | 10 | 2485.8 | 585.0 | 29.1 / 7.7 | 6.52 / 0.9 |
| r1-D-43300-p3-jfr | jfr | 143.62 | 202.42 | 249.58 | 4 | 1933.5 | 1660.4 | 29.45 / 5.5 | 9.54 / 0.8 |
| r2-D-43300-p3-jfr | jfr | 60.54 | 58.03 | 89.84 | 5 | 887.5 | 432.1 | 29.79 / 6.3 | 4.69 / 0.7 |
| r3-D-43300-p3-jfr | jfr | 155.39 | 174.62 | 246.09 | 3 | 1346.0 | 1127.5 | 31.77 / 6.6 | 6.2 / 0.0 |
| q1-D-43300-p1-light | light | 38.72 | 38.86 | 76.69 | 3 | 249.1 | 114.9 | 26.96 / 34.2 | 4.45 / 0.0 |
| q1-D-43300-p3-light | light | 56.7 | 50.22 | 79.59 | 5 | 727.8 | 341.5 | 31.39 / 19.8 | 4.49 / 1.2 |
| q2-D-43300-p1-light | light | 47.39 | 47.1 | 76.45 | 6 | 582.4 | 172.8 | 26.65 / 16.4 | 5.46 / 0.0 |
| q2-D-43300-p3-light | light | 97.28 | 94.8 | 115.96 | 3 | 1210.0 | 1081.6 | 27.11 / 9.6 | 5.72 / 0.0 |
| q3-D-43300-p1-light | light | 60.48 | 56.46 | 88.39 | 4 | 831.5 | 561.4 | 29.94 / 14.2 | 5.11 / 0.0 |
| q3-D-43300-p3-light | light | 48.1 | 45.56 | 71.34 | 5 | 520.4 | 230.2 | 28.1 / 19.6 | 5.12 / 0.0 |
| q4-D-43300-p1-light | light | 39.42 | 37.51 | 68.06 | 1 | 68.1 | 68.1 | 25.88 / 67.2 | 5.13 / 0.0 |
| q4-D-43300-p3-light | light | 39.17 | 38.52 | 70.76 | 1 | 105.8 | 105.8 | 31.92 / 56.7 | 6.79 / 0.0 |
| q5-D-43300-p1-light | light | 71.36 | 55.91 | 92.43 | 5 | 877.7 | 584.2 | 30.45 / 14.6 | 15.05 / 2.7 |
| q5-D-43300-p3-light | light | 91.14 | 71.62 | 154.32 | 4 | 1397.5 | 1117.1 | 30.83 / 7.6 | 4.63 / 0.6 |
| q6-D-43300-p1-light | light | 100.03 | 96.56 | 151.84 | 3 | 1060.0 | 887.1 | 31.54 / 12.6 | 5.49 / 0.0 |
| q6-D-43300-p3-light | light | 43.55 | 42.81 | 81.81 | 3 | 373.3 | 206.9 | 27.47 / 20.6 | 5.05 / 0.0 |
| r1-D-43300-p3-light | light | 56.67 | 53.27 | 79.07 | 3 | 466.2 | 336.4 | 33.63 / 8.8 | 4.43 / 0.0 |
| r2-D-43300-p3-light | light | 39.26 | 39.36 | 66.53 | 1 | 66.5 | 66.5 | 28.55 / 84.7 | 6.15 / 14.4 |
| r3-D-43300-p3-light | light | 84.86 | 81.59 | 93.94 | 1 | 1349.3 | 1349.3 | 24.72 / 0.0 | 6.98 / 0.0 |
| r1-D-43300-p3-sched | sched | 42.81 | 39.04 | 89.42 | 2 | 170.3 | 105.3 | 30.08 / 33.6 | 6.02 / 0.0 |
| r2-D-43300-p3-sched | sched | 70.91 | 65.7 | 96.17 | 3 | 1030.8 | 691.7 | 28.05 / 5.4 | 9.69 / 1.9 |
| r3-D-43300-p3-sched | sched | 65.28 | 53.09 | 87.47 | 4 | 750.6 | 503.1 | 27.29 / 14.0 | 6.41 / 0.0 |
| r1-D-43300-p3-wall | wall | 89.28 | 72.69 | 117.68 | 3 | 1082.5 | 947.3 | 28.53 / 8.9 | 5.69 / 0.0 |
| r2-D-43300-p3-wall | wall | 45.5 | 46.48 | 90.41 | 4 | 357.7 | 104.3 | 28.02 / 14.3 | 6.21 / 0.0 |
| r3-D-43300-p3-wall | wall | 122.5 | 129.78 | 207.83 | 2 | 1407.3 | 1298.6 | 26.9 / 5.4 | 6.01 / 0.5 |

## Scheduler trace

State shares of each thread role inside the slow windows / outside them, the longest single wait for a CPU, and what ran on the CPU it waited for during slow windows.

| trial | role | in slow: run / wait / sleep % | outside: run / wait / sleep % | wait max ms | waited behind (slow) |
|:--|:--|:--|:--|--:|:--|
| r1-A_iso-52600-p3-sched | ForkJoinPool-1-worker-1 | 60.5 / 32.7 / 6.8 | 70.0 / 5.9 / 24.1 | 4.01 | server:ForkJoinPool-1-worker-2 97.9, idle 2.0, other:kworker/2 0.0 |
| r1-A_iso-52600-p3-sched | ForkJoinPool-1-worker-2 | 60.6 / 32.7 / 6.8 | 70.0 / 5.9 / 24.1 | 4.0 | server:ForkJoinPool-1-worker-1 98.3, idle 1.7, other:ksoftirqd 0.0 |
| r1-A_iso-52600-p3-sched | Master-Poller | 1.3 / 1.9 / 96.7 | 8.4 / 5.6 / 85.9 | 3.71 | idle 35.3, server:carrier/native-tcp/reactor/1 34.1, server:carrier/native-tcp/reactor/0 30.0 |
| r1-A_iso-52600-p3-sched | VirtualThread-unparker | 0.0 / 0.0 / 100.0 | 0.0 / 0.0 / 100.0 | 0.01 | idle 100.0 |
| r1-A_iso-52600-p3-sched | Write-Poller | 0 / 0 / 0 | 0 / 0 / 0 | 0 | — |
| r1-A_iso-52600-p3-sched | carrier/native-tcp/acceptor | 0 / 0 / 0 | 0 / 0 / 0 | 0 | — |
| r1-A_iso-52600-p3-sched | carrier/native-tcp/reactor/0 | 35.3 / 2.2 / 62.5 | 22.4 / 5.5 / 72.1 | 3.7 | idle 96.3, server:Master-Poller 3.0, other:containerd 0.3 |
| r1-A_iso-52600-p3-sched | carrier/native-tcp/reactor/1 | 36.3 / 2.2 / 61.5 | 23.0 / 5.9 / 71.1 | 3.15 | idle 93.8, server:Master-Poller 3.0, other:irq/87-rtw89_pc 2.5 |
| r2-A_iso-52600-p3-sched | ForkJoinPool-1-worker-1 | 61.3 / 28.4 / 10.3 | 69.4 / 6.3 / 24.3 | 36.12 | server:ForkJoinPool-1-worker-2 96.3, idle 3.6, other:ksoftirqd 0.1 |
| r2-A_iso-52600-p3-sched | ForkJoinPool-1-worker-2 | 61.5 / 28.4 / 10.1 | 69.4 / 6.3 / 24.3 | 32.86 | server:ForkJoinPool-1-worker-1 96.9, idle 3.0, other:ksoftirqd 0.1 |
| r2-A_iso-52600-p3-sched | Master-Poller | 1.3 / 2.2 / 96.6 | 7.8 / 5.2 / 87.0 | 32.35 | server:carrier/native-tcp/reactor/0 39.7, server:carrier/native-tcp/reactor/1 31.0, idle 29.2 |
| r2-A_iso-52600-p3-sched | VirtualThread-unparker | 0.0 / 0.0 / 100.0 | 0.0 / 0.0 / 100.0 | 0.01 | — |
| r2-A_iso-52600-p3-sched | Write-Poller | 0 / 0 / 0 | 0 / 0 / 0 | 0 | — |
| r2-A_iso-52600-p3-sched | carrier/native-tcp/acceptor | 0 / 0 / 0 | 0 / 0 / 0 | 0 | — |
| r2-A_iso-52600-p3-sched | carrier/native-tcp/reactor/0 | 36.2 / 2.1 / 61.7 | 22.9 / 5.4 / 71.7 | 33.46 | idle 95.6, server:Master-Poller 2.5, other:systemd-oomd 0.8 |
| r2-A_iso-52600-p3-sched | carrier/native-tcp/reactor/1 | 36.5 / 2.0 / 61.5 | 23.0 / 5.5 / 71.5 | 31.44 | idle 92.5, server:Master-Poller 3.9, other:irq/87-rtw89_pc 3.1 |
| r3-A_iso-52600-p3-sched | ForkJoinPool-1-worker-1 | 61.0 / 32.2 / 6.8 | 68.8 / 6.1 / 25.1 | 4.02 | server:ForkJoinPool-1-worker-2 98.2, idle 1.7, other:ksoftirqd 0.1 |
| r3-A_iso-52600-p3-sched | ForkJoinPool-1-worker-2 | 61.1 / 32.2 / 6.7 | 68.9 / 6.1 / 25.0 | 4.01 | server:ForkJoinPool-1-worker-1 98.2, idle 1.7, other:ksoftirqd 0.0 |
| r3-A_iso-52600-p3-sched | Master-Poller | 1.2 / 1.7 / 97.1 | 7.6 / 5.9 / 86.5 | 2.55 | server:carrier/native-tcp/reactor/1 38.4, idle 37.1, server:carrier/native-tcp/reactor/0 22.1 |
| r3-A_iso-52600-p3-sched | VirtualThread-unparker | 0.0 / 0.0 / 100.0 | 0.0 / 0.0 / 100.0 | 0.01 | idle 100.0 |
| r3-A_iso-52600-p3-sched | Write-Poller | 0 / 0 / 0 | 0 / 0 / 0 | 0 | — |
| r3-A_iso-52600-p3-sched | carrier/native-tcp/acceptor | 0 / 0 / 0 | 0 / 0 / 0 | 0 | — |
| r3-A_iso-52600-p3-sched | carrier/native-tcp/reactor/0 | 33.5 / 2.0 / 64.5 | 25.8 / 4.3 / 69.9 | 2.96 | idle 93.8, server:Master-Poller 3.2, other:docker-registry 2.0 |
| r3-A_iso-52600-p3-sched | carrier/native-tcp/reactor/1 | 34.3 / 1.6 / 64.1 | 25.7 / 4.4 / 69.9 | 6.04 | idle 92.3, server:Master-Poller 3.9, other:irq/87-rtw89_pc 3.0 |
| r1-C_iso-52600-p3-sched | Master-Poller | 6.3 / 8.7 / 85.0 | 7.0 / 5.9 / 87.1 | 3.59 | server:carrier/native-tcp/reactor/0 38.9, idle 33.0, server:carrier/native-tcp/reactor/1 27.8 |
| r1-C_iso-52600-p3-sched | VirtualThread-unparker | 0.0 / 0.0 / 100.0 | 0.0 / 0.0 / 100.0 | 0.0 | — |
| r1-C_iso-52600-p3-sched | Write-Poller | 0 / 0 / 0 | 0 / 0 / 0 | 0 | — |
| r1-C_iso-52600-p3-sched | carrier/native-tcp/acceptor | 0 / 0 / 0 | 0 / 0 / 0 | 0 | — |
| r1-C_iso-52600-p3-sched | carrier/native-tcp/reactor/0 | 27.3 / 3.2 / 69.6 | 24.1 / 5.2 / 70.6 | 3.02 | idle 82.1, server:Master-Poller 16.4, other:containerd 0.8 |
| r1-C_iso-52600-p3-sched | carrier/native-tcp/reactor/1 | 29.6 / 2.8 / 67.6 | 27.1 / 4.3 / 68.6 | 3.8 | idle 81.9, server:Master-Poller 16.3, other:irq/87-rtw89_pc 1.3 |
| r1-C_iso-52600-p3-sched | exeris-carrier-0 | 68.9 / 5.5 / 25.6 | 68.7 / 6.3 / 25.0 | 3.56 | idle 64.4, server:exeris-carrier-1 35.1, other:ksoftirqd 0.5 |
| r1-C_iso-52600-p3-sched | exeris-carrier-1 | 69.6 / 5.7 / 24.7 | 69.1 / 6.4 / 24.5 | 3.48 | idle 66.6, server:exeris-carrier-0 32.7, other:ksoftirqd 0.7 |
| r2-C_iso-52600-p3-sched | Master-Poller | 6.2 / 6.9 / 86.9 | 7.0 / 5.9 / 87.1 | 2.96 | idle 38.7, server:carrier/native-tcp/reactor/0 31.4, server:carrier/native-tcp/reactor/1 29.7 |
| r2-C_iso-52600-p3-sched | VirtualThread-unparker | 0.0 / 0.0 / 100.0 | 0.0 / 0.0 / 100.0 | 0.01 | — |
| r2-C_iso-52600-p3-sched | Write-Poller | 0 / 0 / 0 | 0 / 0 / 0 | 0 | — |
| r2-C_iso-52600-p3-sched | carrier/native-tcp/acceptor | 0 / 0 / 0 | 0 / 0 / 0 | 0 | — |
| r2-C_iso-52600-p3-sched | carrier/native-tcp/reactor/0 | 27.4 / 3.5 / 69.1 | 24.5 / 6.2 / 69.4 | 3.11 | idle 82.3, server:Master-Poller 17.1, other:containerd 0.5 |
| r2-C_iso-52600-p3-sched | carrier/native-tcp/reactor/1 | 29.2 / 2.9 / 67.9 | 27.3 / 5.0 / 67.7 | 2.84 | idle 79.6, server:Master-Poller 16.5, other:irq/87-rtw89_pc 2.7 |
| r2-C_iso-52600-p3-sched | exeris-carrier-0 | 68.2 / 6.7 / 25.1 | 68.5 / 6.6 / 24.9 | 3.61 | server:exeris-carrier-1 53.4, idle 46.6, other:perf 0.0 |
| r2-C_iso-52600-p3-sched | exeris-carrier-1 | 68.5 / 6.8 / 24.7 | 68.5 / 6.5 / 25.1 | 3.69 | server:exeris-carrier-0 51.5, idle 48.5, other:migration 0.0 |
| r3-C_iso-52600-p3-sched | Master-Poller | 6.3 / 8.8 / 84.9 | 6.6 / 5.8 / 87.6 | 11.86 | server:carrier/native-tcp/reactor/1 35.6, idle 31.3, server:carrier/native-tcp/reactor/0 27.7 |
| r3-C_iso-52600-p3-sched | VirtualThread-unparker | 0.0 / 0.0 / 100.0 | 0.0 / 0.0 / 100.0 | 0.04 | idle 100.0, server:carrier/native-tcp/reactor/0 0.0 |
| r3-C_iso-52600-p3-sched | Write-Poller | 0 / 0 / 0 | 0 / 0 / 0 | 0 | — |
| r3-C_iso-52600-p3-sched | carrier/native-tcp/acceptor | 0 / 0 / 0 | 0 / 0 / 0 | 0 | — |
| r3-C_iso-52600-p3-sched | carrier/native-tcp/reactor/0 | 30.1 / 2.5 / 67.5 | 26.7 / 4.3 / 69.0 | 8.76 | idle 80.4, server:Master-Poller 19.4, server:VirtualThread-unparker 0.2 |
| r3-C_iso-52600-p3-sched | carrier/native-tcp/reactor/1 | 30.3 / 2.7 / 67.0 | 27.4 / 4.6 / 68.1 | 9.74 | idle 76.1, server:Master-Poller 20.9, other:irq/87-rtw89_pc 1.9 |
| r3-C_iso-52600-p3-sched | exeris-carrier-0 | 69.6 / 8.0 / 22.4 | 68.3 / 6.6 / 25.1 | 12.15 | server:exeris-carrier-1 58.3, idle 41.6, other:kworker/3 0.0 |
| r3-C_iso-52600-p3-sched | exeris-carrier-1 | 70.1 / 8.2 / 21.8 | 68.8 / 6.8 / 24.4 | 11.84 | server:exeris-carrier-0 57.7, idle 42.2, other:ksoftirqd 0.1 |
| r1-D-43300-p3-sched | Master-Poller | 0 / 0 / 0 | 6.5 / 4.5 / 89.0 | 3.28 | — |
| r1-D-43300-p3-sched | VirtualThread-unparker | 0 / 0 / 0 | 0.0 / 0.0 / 100.0 | 0.01 | — |
| r1-D-43300-p3-sched | Write-Poller | 0 / 0 / 0 | 0 / 0 / 0 | 0 | — |
| r1-D-43300-p3-sched | carrier/native-tcp/acceptor | 0 / 0 / 0 | 0 / 0 / 0 | 0 | — |
| r1-D-43300-p3-sched | carrier/native-tcp/reactor/0 | 0 / 0 / 0 | 18.9 / 5.8 / 75.2 | 3.54 | — |
| r1-D-43300-p3-sched | carrier/native-tcp/reactor/1 | 0 / 0 / 0 | 19.0 / 5.8 / 75.2 | 2.48 | — |
| r1-D-43300-p3-sched | exeris-carrier-0 | 0 / 0 / 0 | 56.5 / 3.0 / 40.5 | 1.84 | — |
| r1-D-43300-p3-sched | exeris-carrier-1 | 0 / 0 / 0 | 56.5 / 3.1 / 40.4 | 1.73 | — |
| r2-D-43300-p3-sched | Master-Poller | 0 / 0 / 0 | 6.8 / 4.4 / 88.9 | 2.65 | — |
| r2-D-43300-p3-sched | VirtualThread-unparker | 0 / 0 / 0 | 0.0 / 0.0 / 100.0 | 0.02 | — |
| r2-D-43300-p3-sched | Write-Poller | 0 / 0 / 0 | 0 / 0 / 0 | 0 | — |
| r2-D-43300-p3-sched | carrier/native-tcp/acceptor | 0 / 0 / 0 | 0 / 0 / 0 | 0 | — |
| r2-D-43300-p3-sched | carrier/native-tcp/reactor/0 | 0 / 0 / 0 | 21.4 / 4.0 / 74.6 | 5.11 | — |
| r2-D-43300-p3-sched | carrier/native-tcp/reactor/1 | 0 / 0 / 0 | 18.6 / 4.9 / 76.5 | 1.01 | — |
| r2-D-43300-p3-sched | exeris-carrier-0 | 0 / 0 / 0 | 55.1 / 2.4 / 42.5 | 0.58 | — |
| r2-D-43300-p3-sched | exeris-carrier-1 | 0 / 0 / 0 | 55.2 / 2.4 / 42.4 | 1.88 | — |
| r3-D-43300-p3-sched | Master-Poller | 0 / 0 / 0 | 7.0 / 4.2 / 88.9 | 1.08 | — |
| r3-D-43300-p3-sched | VirtualThread-unparker | 0 / 0 / 0 | 0.0 / 0.0 / 100.0 | 0.03 | — |
| r3-D-43300-p3-sched | Write-Poller | 0 / 0 / 0 | 0 / 0 / 0 | 0 | — |
| r3-D-43300-p3-sched | carrier/native-tcp/acceptor | 0 / 0 / 0 | 0 / 0 / 0 | 0 | — |
| r3-D-43300-p3-sched | carrier/native-tcp/reactor/0 | 0 / 0 / 0 | 19.5 / 5.3 / 75.2 | 3.73 | — |
| r3-D-43300-p3-sched | carrier/native-tcp/reactor/1 | 0 / 0 / 0 | 19.4 / 5.3 / 75.2 | 3.66 | — |
| r3-D-43300-p3-sched | exeris-carrier-0 | 0 / 0 / 0 | 56.3 / 2.6 / 41.1 | 0.06 | — |
| r3-D-43300-p3-sched | exeris-carrier-1 | 0 / 0 / 0 | 56.4 / 2.6 / 41.0 | 0.02 | — |

| trial | carrier CPU idle % in slow / outside | stacking ms/s in slow / outside | longest stacked ms |
|:--|:--|:--|--:|
| r1-A_iso-52600-p3-sched | cpu2 71.7 / 33.2; cpu3 7.3 / 26.4 | 639.76 / 68.08 | 4.01 |
| r2-A_iso-52600-p3-sched | cpu2 66.1 / 34.1; cpu3 11.1 / 26.6 | 548.52 / 77.12 | 4.02 |
| r3-A_iso-52600-p3-sched | cpu2 70.5 / 34.9; cpu3 7.4 / 27.0 | 631.73 / 77.84 | 4.02 |
| r1-C_iso-52600-p3-sched | cpu2 33.1 / 35.0; cpu3 28.3 / 27.1 | 37.83 / 73.75 | 3.56 |
| r2-C_iso-52600-p3-sched | cpu2 35.8 / 34.7; cpu3 27.4 / 27.4 | 70.35 / 69.06 | 3.69 |
| r3-C_iso-52600-p3-sched | cpu2 35.3 / 35.6; cpu3 25.0 / 27.1 | 93.67 / 80.75 | 3.77 |
| r1-D-43300-p3-sched | cpu2 None / 42.9; cpu3 None / 42.8 | None / 0.0 | 0.0 |
| r2-D-43300-p3-sched | cpu2 None / 44.8; cpu3 None / 44.7 | None / 0.0 | 0.0 |
| r3-D-43300-p3-sched | cpu2 None / 43.6; cpu3 None / 43.5 | None / 0.0 | 0.0 |

## Wall-clock profile

Deepest Java frame, share of samples, inside the slow windows against the whole window.

| trial | thread | in slow | whole window |
|:--|:--|:--|:--|
| r1-A_iso-52600-p3-wall | carriers | sun/nio/ch/SocketDispatcher.write0 24.5, java/lang/invoke/LambdaForm$MH.0x00000000152b4400.invoke 23.5, jdk/internal/misc/Unsafe.park 11.1, sun/nio/ch/SocketDispatcher.read0 9.9 | jdk/internal/misc/Unsafe.park 36.0, sun/nio/ch/SocketDispatcher.write0 16.8, java/lang/invoke/LambdaForm$MH.0x00000000152b4400.invoke 16.1, sun/nio/ch/SocketDispatcher.read0 6.8 |
| r1-A_iso-52600-p3-wall | Master-Poller | sun/nio/ch/EPoll.wait 100.0, java/util/concurrent/ForkJoinPool$WorkQueue.tryLockPhase 0.0 | sun/nio/ch/EPoll.wait 99.5, jdk/internal/misc/Unsafe.unpark 0.4, java/util/concurrent/ForkJoinTask.adapt 0.1, java/util/concurrent/ForkJoinPool$WorkQueue.push 0.0 |
| r1-A_iso-52600-p3-wall | carrier/native-tcp/reactor/0 | sun/nio/ch/EPoll.wait 75.5, java/lang/invoke/LambdaForm$MH.0x00000000152b4400.invoke 11.2, jdk/internal/foreign/SharedSession$SharedResourceList.add 7.1, jdk/internal/misc/Unsafe.allocateMemory0 2.7 | sun/nio/ch/EPoll.wait 86.8, java/lang/invoke/LambdaForm$MH.0x00000000152b4400.invoke 6.4, jdk/internal/foreign/SharedSession$SharedResourceList.add 1.6, sun/nio/ch/SelectorImpl.selectNow 1.6 |
| r2-A_iso-52600-p3-wall | carriers | sun/nio/ch/SocketDispatcher.write0 25.1, java/lang/invoke/LambdaForm$MH.0x00000000452b4400.invoke 23.0, sun/nio/ch/SocketDispatcher.read0 11.5, jdk/internal/misc/Unsafe.park 9.5 | jdk/internal/misc/Unsafe.park 39.5, java/lang/invoke/LambdaForm$MH.0x00000000452b4400.invoke 15.5, sun/nio/ch/SocketDispatcher.write0 15.0, sun/nio/ch/SocketDispatcher.read0 6.5 |
| r2-A_iso-52600-p3-wall | Master-Poller | sun/nio/ch/EPoll.wait 99.7, java/util/concurrent/ForkJoinTask.adapt 0.2, jdk/internal/misc/Unsafe.unpark 0.1 | sun/nio/ch/EPoll.wait 99.7, jdk/internal/misc/Unsafe.unpark 0.2, java/util/concurrent/ForkJoinTask.adapt 0.1, java/util/concurrent/ConcurrentHashMap.addCount 0.0 |
| r2-A_iso-52600-p3-wall | carrier/native-tcp/reactor/0 | sun/nio/ch/EPoll.wait 76.0, java/lang/invoke/LambdaForm$MH.0x00000000452b4400.invoke 9.9, jdk/internal/foreign/SegmentFactories.allocateNativeInternal 7.0, jdk/internal/misc/Unsafe.allocateMemory0 2.4 | sun/nio/ch/EPoll.wait 88.0, java/lang/invoke/LambdaForm$MH.0x00000000452b4400.invoke 5.0, java/util/HashMap$HashIterator.nextNode 1.3, java/util/HashMap$HashIterator.<init> 1.2 |
| r3-A_iso-52600-p3-wall | carriers | sun/nio/ch/SocketDispatcher.write0 23.8, java/lang/invoke/LambdaForm$MH.0x00000000372b4400.invoke 23.0, sun/nio/ch/SocketDispatcher.read0 12.0, jdk/internal/misc/Unsafe.park 8.5 | jdk/internal/misc/Unsafe.park 39.8, java/lang/invoke/LambdaForm$MH.0x00000000372b4400.invoke 15.0, sun/nio/ch/SocketDispatcher.write0 14.7, sun/nio/ch/SocketDispatcher.read0 7.2 |
| r3-A_iso-52600-p3-wall | Master-Poller | sun/nio/ch/EPoll.wait 99.9, jdk/internal/misc/Unsafe.unpark 0.1 | sun/nio/ch/EPoll.wait 99.6, jdk/internal/misc/Unsafe.unpark 0.3, java/util/concurrent/ForkJoinTask.adapt 0.1, java/util/concurrent/ForkJoinPool.signalWork 0.0 |
| r3-A_iso-52600-p3-wall | carrier/native-tcp/reactor/0 | sun/nio/ch/EPoll.wait 72.6, java/lang/invoke/LambdaForm$MH.0x00000000372b4400.invoke 11.4, jdk/internal/foreign/SharedSession$SharedResourceList.add 10.6, jdk/internal/misc/Unsafe.allocateMemory0 2.5 | sun/nio/ch/EPoll.wait 88.8, java/lang/invoke/LambdaForm$MH.0x00000000372b4400.invoke 4.6, jdk/internal/foreign/SharedSession$SharedResourceList.add 1.4, eu/exeris/kernel/community/transport/NativeTcpReactor.drainPendingRequests 1.2 |
| r1-C_iso-52600-p3-wall | carriers | jdk/internal/misc/Unsafe.park 33.8, sun/nio/ch/SocketDispatcher.write0 17.8, java/lang/invoke/LambdaForm$MH.0x00000000502b3c00.invoke 13.0, sun/nio/ch/SocketDispatcher.read0 8.6 | jdk/internal/misc/Unsafe.park 35.3, sun/nio/ch/SocketDispatcher.write0 18.6, java/lang/invoke/LambdaForm$MH.0x00000000502b3c00.invoke 15.6, sun/nio/ch/SocketDispatcher.read0 7.1 |
| r1-C_iso-52600-p3-wall | Master-Poller | sun/nio/ch/EPoll.wait 99.7, jdk/internal/misc/Unsafe.unpark 0.3 | sun/nio/ch/EPoll.wait 99.3, jdk/internal/misc/Unsafe.unpark 0.6, java/util/concurrent/ConcurrentLinkedQueue.offer 0.0, java/lang/Integer.valueOf 0.0 |
| r1-C_iso-52600-p3-wall | carrier/native-tcp/reactor/0 | sun/nio/ch/EPoll.wait 85.6, java/lang/invoke/LambdaForm$MH.0x00000000502b3c00.invoke 9.2, sun/nio/ch/EPoll.ctl 1.0, sun/nio/ch/EPollSelectorImpl.processEvents 0.7 | sun/nio/ch/EPoll.wait 87.4, java/lang/invoke/LambdaForm$MH.0x00000000502b3c00.invoke 7.0, java/util/HashMap$HashIterator.nextNode 1.5, java/util/HashMap$HashIterator.<init> 1.3 |
| r2-C_iso-52600-p3-wall | carriers | jdk/internal/misc/Unsafe.park 32.6, sun/nio/ch/SocketDispatcher.write0 19.8, java/lang/invoke/LambdaForm$MH.0x00000000252b3c00.invoke 15.8, sun/nio/ch/SocketDispatcher.read0 8.5 | jdk/internal/misc/Unsafe.park 38.5, java/lang/invoke/LambdaForm$MH.0x00000000252b3c00.invoke 16.5, sun/nio/ch/SocketDispatcher.write0 16.1, sun/nio/ch/SocketDispatcher.read0 6.9 |
| r2-C_iso-52600-p3-wall | Master-Poller | sun/nio/ch/EPoll.wait 99.0, jdk/internal/misc/Unsafe.unpark 0.6, java/util/concurrent/ConcurrentLinkedQueue.offer 0.4 | sun/nio/ch/EPoll.wait 99.3, jdk/internal/misc/Unsafe.unpark 0.6, java/util/concurrent/ConcurrentLinkedQueue.offer 0.1, java/util/concurrent/ThreadLocalRandom.getProbe 0.0 |
| r2-C_iso-52600-p3-wall | carrier/native-tcp/reactor/0 | sun/nio/ch/EPoll.wait 82.4, java/lang/invoke/LambdaForm$MH.0x00000000252b3c00.invoke 12.8, java/util/HashMap$HashIterator.nextNode 1.7, java/util/HashMap$HashIterator.<init> 1.0 | sun/nio/ch/EPoll.wait 89.2, java/lang/invoke/LambdaForm$MH.0x00000000252b3c00.invoke 4.8, java/util/HashMap$HashIterator.nextNode 2.4, java/util/HashMap$HashIterator.<init> 1.8 |
| r3-C_iso-52600-p3-wall | carriers | jdk/internal/misc/Unsafe.park 34.6, sun/nio/ch/SocketDispatcher.write0 19.2, java/lang/invoke/LambdaForm$MH.0x00000000102b3c00.invoke 15.1, sun/nio/ch/SocketDispatcher.read0 7.2 | jdk/internal/misc/Unsafe.park 40.9, sun/nio/ch/SocketDispatcher.write0 17.3, java/lang/invoke/LambdaForm$MH.0x00000000102b3c00.invoke 14.4, sun/nio/ch/SocketDispatcher.read0 6.4 |
| r3-C_iso-52600-p3-wall | Master-Poller | sun/nio/ch/EPoll.wait 99.1, jdk/internal/misc/Unsafe.unpark 0.4, java/util/concurrent/ConcurrentLinkedQueue.offer 0.4 | sun/nio/ch/EPoll.wait 99.4, jdk/internal/misc/Unsafe.unpark 0.5, java/util/concurrent/ConcurrentLinkedQueue.offer 0.1, eu/exeris/kernel/core/transport/scheduler/locality/ExerisCarrierThread.wakeup 0.0 |
| r3-C_iso-52600-p3-wall | carrier/native-tcp/reactor/0 | sun/nio/ch/EPoll.wait 82.3, java/lang/invoke/LambdaForm$MH.0x00000000102b3c00.invoke 10.3, java/util/HashMap$HashIterator.nextNode 2.2, java/util/HashMap$HashIterator.<init> 1.4 | sun/nio/ch/EPoll.wait 83.8, java/lang/invoke/LambdaForm$MH.0x00000000102b3c00.invoke 7.2, java/util/HashMap$HashIterator.nextNode 4.0, java/util/HashMap$HashIterator.<init> 2.2 |
| r1-D-43300-p3-wall | carriers | jdk/internal/misc/Unsafe.park 44.6, sun/nio/ch/SocketDispatcher.write0 16.2, java/lang/invoke/LambdaForm$MH.0x00000000452b3c00.invoke 11.5, sun/nio/ch/SocketDispatcher.read0 6.0 | jdk/internal/misc/Unsafe.park 38.4, sun/nio/ch/SocketDispatcher.write0 17.6, java/lang/invoke/LambdaForm$MH.0x00000000452b3c00.invoke 15.5, sun/nio/ch/SocketDispatcher.read0 6.5 |
| r1-D-43300-p3-wall | Master-Poller | sun/nio/ch/EPoll.wait 99.5, jdk/internal/misc/Unsafe.unpark 0.5 | sun/nio/ch/EPoll.wait 99.2, jdk/internal/misc/Unsafe.unpark 0.7, java/util/concurrent/ConcurrentLinkedQueue.offer 0.1, sun/nio/ch/EPollPoller.poll 0.0 |
| r1-D-43300-p3-wall | carrier/native-tcp/reactor/0 | sun/nio/ch/EPoll.wait 94.0, java/lang/invoke/LambdaForm$MH.0x00000000452b3c00.invoke 3.7, java/util/HashMap$HashIterator.<init> 0.9, jdk/internal/misc/Unsafe.unpark 0.5 | sun/nio/ch/EPoll.wait 89.8, java/util/HashMap$HashIterator.nextNode 3.3, java/lang/invoke/LambdaForm$MH.0x00000000452b3c00.invoke 2.9, java/util/HashMap$HashIterator.<init> 1.9 |
| r2-D-43300-p3-wall | carriers | jdk/internal/misc/Unsafe.park 37.3, sun/nio/ch/SocketDispatcher.write0 19.0, java/lang/invoke/LambdaForm$MH.0x000000005e2b3c00.invoke 5.6, sun/nio/ch/SocketDispatcher.read0 4.0 | jdk/internal/misc/Unsafe.park 51.2, sun/nio/ch/SocketDispatcher.write0 13.3, java/lang/invoke/LambdaForm$MH.0x000000005e2b3c00.invoke 13.0, sun/nio/ch/SocketDispatcher.read0 5.2 |
| r2-D-43300-p3-wall | Master-Poller | sun/nio/ch/EPoll.wait 88.7, java/util/concurrent/ConcurrentLinkedQueue.offer 9.4, jdk/internal/misc/Unsafe.unpark 1.9 | sun/nio/ch/EPoll.wait 99.2, jdk/internal/misc/Unsafe.unpark 0.7, java/util/concurrent/ConcurrentLinkedQueue.offer 0.1, eu/exeris/kernel/core/transport/scheduler/locality/ExerisCarrierThread.wakeup 0.0 |
| r2-D-43300-p3-wall | carrier/native-tcp/reactor/0 | sun/nio/ch/EPoll.wait 54.8, java/lang/invoke/LambdaForm$MH.0x000000005e2b3c00.invoke 9.7, sun/nio/ch/UnixDispatcher.close0 6.5, eu/exeris/kernel/community/transport/NativeTcpReactor.dispatchSelectedKey 3.2 | sun/nio/ch/EPoll.wait 92.6, java/lang/invoke/LambdaForm$MH.0x000000005e2b3c00.invoke 2.5, java/util/HashMap$HashIterator.nextNode 1.5, java/util/HashMap$HashIterator.<init> 1.2 |
| r3-D-43300-p3-wall | carriers | jdk/internal/misc/Unsafe.park 45.6, java/lang/invoke/LambdaForm$MH.0x00000000742b3c00.invoke 16.3, sun/nio/ch/SocketDispatcher.write0 13.3, sun/nio/ch/SocketDispatcher.read0 5.9 | jdk/internal/misc/Unsafe.park 38.8, sun/nio/ch/SocketDispatcher.write0 18.4, java/lang/invoke/LambdaForm$MH.0x00000000742b3c00.invoke 14.9, sun/nio/ch/SocketDispatcher.read0 6.7 |
| r3-D-43300-p3-wall | Master-Poller | sun/nio/ch/EPoll.wait 98.6, java/util/concurrent/ConcurrentLinkedQueue.offer 0.7, jdk/internal/misc/Unsafe.unpark 0.7 | sun/nio/ch/EPoll.wait 99.2, jdk/internal/misc/Unsafe.unpark 0.7, java/util/concurrent/ConcurrentLinkedQueue.offer 0.1, java/util/concurrent/ConcurrentHashMap.addCount 0.0 |
| r3-D-43300-p3-wall | carrier/native-tcp/reactor/0 | sun/nio/ch/EPoll.wait 87.9, java/lang/invoke/LambdaForm$MH.0x00000000742b3c00.invoke 7.4, java/util/HashMap.getNode 2.1, java/util/HashMap$HashIterator.<init> 0.7 | sun/nio/ch/EPoll.wait 91.3, java/lang/invoke/LambdaForm$MH.0x00000000742b3c00.invoke 3.6, java/util/HashMap$HashIterator.nextNode 1.9, java/util/HashMap$HashIterator.<init> 0.8 |

## Virtual-thread pinning (JFR, ≥ 1 ms)

| trial | events | total ms | max ms | in slow windows | top frames |
|:--|--:|--:|--:|--:|:--|
| r1-A_iso-52600-p3-jfr | 0 | — | — | — | — |
| r2-A_iso-52600-p3-jfr | 0 | — | — | — | — |
| r3-A_iso-52600-p3-jfr | 0 | — | — | — | — |
| r1-C_iso-52600-p3-jfr | 0 | — | — | — | — |
| r2-C_iso-52600-p3-jfr | 0 | — | — | — | — |
| r3-C_iso-52600-p3-jfr | 0 | — | — | — | — |
| r1-D-43300-p3-jfr | 0 | — | — | — | — |
| r2-D-43300-p3-jfr | 0 | — | — | — | — |
| r3-D-43300-p3-jfr | 0 | — | — | — | — |
