# Scenario: loom-carrier-scheduler

Harness for the kernel research track `research/loom-carrier-scheduler`
(`docs/research/loom-carrier-scheduler/research.md` on that kernel branch). It compares the stock
`ForkJoinPool` virtual-thread scheduler with `ExerisCarrierScheduler`, a custom
`java.lang.Thread.VirtualThreadScheduler` from the Loom `fibers` branch, on the Community transport.

Track: Community. Family: Runtime. Mode: research. Not a comparative (cross-runtime) scenario.

The shape follows Francesco Nigro's Netty virtual-thread scheduler benchmark
(<https://github.com/franz1981/Netty-VirtualThread-Scheduler/blob/master/PERFORMANCE.md>): a request
handler on a virtual thread makes a blocking call to a mock backend on separate CPUs, and the
load generator drives it open-loop at a fixed rate below saturation, where the scheduler's
responsiveness rather than its peak throughput sets the latency.

## Request path

`wrk2` → server (`targets/exeris-loom-scheduler-app`, `/backend`) → handler virtual thread makes one
blocking request to the mock backend (`MockBackend`, think time 1 ms) → response.

The backend call is the scenario's second axis:

| `--backend` | Client | Wakes the handler's virtual thread through |
|:--|:--|:--|
| `jdk` | blocking `java.net.Socket`, pooled keep-alive connections | the JDK poller (`sun.nio.ch.Poller`, `jdk.pollerMode`) |
| `kernel` | `KernelWebClient` | the kernel's own transport reactors |

`java.net.http.HttpClient` is deliberately not used for `jdk`: it runs its own selector thread and
completes a future, so the virtual thread never meets the JDK poller.

## Arms

All arms run the same number of carriers (one per `--carrier-cpus` entry, default 2).

| Arm | Scheduler | Carrier placement |
|:--|:--|:--|
| `A_iso` | stock `ForkJoinPool` (`parallelism = maxPoolSize = carriers`) | workers share the carrier CPUs |
| `B_pin` | stock `ForkJoinPool`, same parameters (`PinnedForkJoinScheduler` in the target) | each worker binds itself to a free carrier CPU when it starts |
| `C_iso` | `ExerisCarrierScheduler`, per-carrier MPSC queue, no work stealing | carriers share the carrier CPUs |
| `D` | `ExerisCarrierScheduler` | each carrier bound to one carrier CPU (`exeris.carrier.affinity`) |

The four arms are the scheduling algorithm × pinning table: `B_pin` against `A_iso` and `D` against
`C_iso` isolate pinning; `C_iso` against `A_iso` and `D` against `B_pin` isolate the scheduler
design. `B_pin` runs in the capacity ladders.

## CPU layout (defaults, 6 cores / 12 threads, SMT siblings `n` and `n+6`)

| Role | CPUs | Physical cores |
|:--|:--|:--|
| server JVM auxiliary threads and transport reactors | 0, 6 | 0 |
| mock backend JVM | 1, 7 | 1 |
| carriers | 2, 3 | 2, 3 (siblings 8, 9 left idle) |
| load generator (`wrk` / `wrk2`, 4 threads) | 4, 5, 10, 11 | 4, 5 |

Every role is a `run-trial.sh` option. Check the host with `lscpu -e` before reusing the defaults.

## Running

```bash
# once per kernel commit (also done by run-campaign.sh)
scripts/loom-carrier-scheduler/build-kernel.sh research/loom-carrier-scheduler

# one trial
scripts/loom-carrier-scheduler/run-trial.sh --kernel-dir work/loom-carrier-scheduler/kernel-<sha12> \
  --arm D --backend jdk --rate 30000 --poller-mode 3 --out /tmp/trial-d

# a campaign: saturation probe, then 0.5 / 0.7 / 0.85 of A_iso's median saturation, 5 reps
scripts/loom-carrier-scheduler/run-campaign.sh --kernel-commit research/loom-carrier-scheduler \
  --backend jdk --poller-mode 3
```

Campaigns land in `results/raw/loom-carrier-scheduler/<UTC>-<backend>-k<sha12>/` with one directory
per trial, `campaign.json`, `order.txt` and `summary.md` / `summary.json`. Every file is `.txt` or
`.json` so the campaign can be committed as it ran.

## Regimes

| Regime | Think time | Connections | Pool | Extra options |
|:--|--:|--:|--:|:--|
| CPU-bound (default) | 1 ms | 100 | 128 | — |
| I/O-bound | 30 ms | 5,000 | 2,048 | `--max-connections 16384 --duration 60` |

The backend pool is sized to the requests in flight, not to the connection count: with a pool as
large as 5,000 connections the server keeps thousands of idle backend sockets open, and the p99 at
half load rises about fivefold in every arm, which says nothing about the scheduler.

The I/O-bound regime keeps the request latency dominated by the backend wait, so in-flight requests
(`rate × ~31 ms`) are in the hundreds to low thousands. Its connection count is above the kernel's
default connection and admission limits only with margin to spare, so `--max-connections` raises
`http.maxConnections`, `transport.maxConnections` and `transport.paqs.maxActiveStreams` on both
JVMs. The 2,000-connection ramp is 2.5 s on 4 load threads; a 60 s window keeps it a small share
of the run.

`--warmup-mode open` warms up with `wrk2` at the trial's own rate instead of `wrk` at saturation,
so the measurement starts from the load shape it measures. Whether that changes the measured
window is an open question for the campaign, not a default.

## Capacity ladders

`run-sequence.sh` with `CAMPAIGNS="cpu-slo io-slo"` runs all four arms at 70–100 % of `A_iso`'s
saturation in steps of 5 %, 5 fresh JVMs per cell, against a p99 objective recorded in
`campaign.json`: 5 ms in the CPU-bound regime, 65 ms in the I/O-bound one. `slo_ladder.py` writes
`slo.md`: a rate passes for an arm when at least 4 trials are valid, every valid trial sustained
the rate, and their median p99 is inside the objective; the arm's capacity is the highest rate up
to which every rate passes.

## Shielding the host

Run campaigns from a text console with the graphical session stopped, and with everything else
confined to the auxiliary core by `scripts/loom-carrier-scheduler/host-shield.sh`:

```bash
sudo systemctl isolate multi-user.target           # log in on a text console, start tmux
sudo scripts/loom-carrier-scheduler/host-shield.sh apply --sys-cpus 0,6 --boost off
sudo scripts/loom-carrier-scheduler/host-shield.sh run -- \
  scripts/loom-carrier-scheduler/run-campaign.sh --kernel-commit <rev> --backend jdk --poller-mode 3
sudo scripts/loom-carrier-scheduler/host-shield.sh revert
sudo systemctl isolate graphical.target
```

`apply` confines `system.slice`, `user.slice` and `init.scope` to `--sys-cpus`, moves every movable
IRQ there, sets the `performance` governor and the requested boost; `run` starts the campaign as the
invoking user in `bench.slice`, which may use every CPU; `revert` restores the saved state. All of
it is runtime only. The shield is a cgroup cpuset rather than `isolcpus`, because `isolcpus` also
disables load balancing on the isolated CPUs and would stop the kernel from moving the floating
arms' carriers between their CPUs — the behaviour those arms measure.

Every trial records the host state it ran under (`host.txt`, `host` in `trial.json`): graphical
session, slice masks, its own CPU mask, boost, governors, and the interrupts each carrier CPU took
during the measurement window. The `host_shielded` gate does not invalidate a trial; it decides
whether the campaign is evidence.

## What each trial records

| File | Content |
|:--|:--|
| `trial.json` | parameters, kernel identity, parsed results, every gate with its reason |
| `load.txt`, `warmup.txt` | `wrk2` / `wrk` output (`--latency`) |
| `pidstat-server.txt`, `pidstat-mock.txt` | per-thread `%usr %system %wait %CPU`, context switches |
| `perf-stat.txt` | task-clock, cycles, instructions, context switches, migrations — or why it was not run |
| `threads*.txt`, `affinity-*.txt` | TID → Java thread name, and each thread's allowed CPUs at start and end |
| `environment.txt` | kernel, CPU, governor, `lscpu -e`, JDK build, full server and mock command lines |
| `kernel-identity.json` | kernel commit, class-file version, JDK build |

## Gates

A trial is `valid` when every measurement gate holds (transport, errors, isolation, unperturbed);
`evidence` additionally requires the harness files to be committed and the host to be shielded.
Invalid trials stay in the campaign and are listed in `summary.md`, never used.

The load gate is an outcome, not a measurement gate. A valid trial whose arm could not carry the
target rate has measured something true about that arm: the summary counts it per cell
("sustained k of n") and lists the rate it reached, and its latency stays out of the percentiles,
which describe only runs that kept up.

- **transport** — the server log reports `active=posix-hybrid, ffmArmed=true`: socket I/O went
  through the FFM descriptor path. Without the `--add-opens` the harness passes, the transport falls
  back to NIO, which is not the path under study.
- **load** (outcome) — `wrk2` achieved at least 99 % of the rate it can report for a server that keeps up:
  wrk2 opens each thread's connections 5 ms apart and divides by the whole duration, so the
  expectation is `rate × (1 − ramp / (2 × duration))` with `ramp = 5 ms × connections / threads`.
  The latency histogram excludes the ramp: wrk2 resets it after a calibration period of
  `10 s + ramp`.
- **errors** — no socket errors and no non-2xx responses.
- **isolation** — at the end of the window: the right number of carrier threads; shared-CPU arms
  allow exactly the carrier CPUs; arms `B_pin` and `D` have each carrier on its own single CPU; no
  other server thread may run on a carrier CPU. `B_pin` also fails it when a worker started
  without a free CPU, and records how many workers started (the pool retires idle ones).
- **unperturbed** — no profiler or tracer attached. `--profile cpu|wall` (async-profiler) and
  `--perf-sched` (`perf sched record`, per-thread run time per CPU in
  `perf-sched-distribution.txt`) produce diagnostic trials only.

## Diagnostic trials

`scripts/loom-carrier-scheduler/run-diagnostics.sh` runs trials that are diagnostic by
construction, for cells a campaign could not explain. Each carries a latency probe
(`latency_probe.py`, 200 req/s on its own connections, every request's latency against its
scheduled send time on `CLOCK_MONOTONIC`) and one recorder: GC and safepoint logs only
(`light`), a scheduler trace (`sched`), an async-profiler wall-clock profile written as JFR
(`wall`), or a JFR recording of virtual-thread pinning (`jfr`). `analyze_diag.py` cuts each
recording to the windows where probe requests were slow and compares them with the rest of the
trial; `summarize_diag.py` tabulates the run. A second block compares `pollerMode=1` and `=3` on
light trials only. Results land in `results/raw/loom-carrier-scheduler-diag/`; the binary
`perf-sched*.data` recordings are not committed.

The scheduler trace records `sched_switch` and `sched_migrate_task` on the server's CPUs and
`sched_waking` aimed at them from any CPU, about 15 MB/s at the I/O-bound rates, with the
recorders on the load generator's CPUs. A JFR recording of the server needs the kernel's own
events disabled, since they fire per request; `make_pinning_jfc.py` writes that settings file from
the kernel build under test.

## Host prerequisites

- Loom EA JDK at `<workspace>/tools/jdk-loom/current`; async-profiler at
  `<workspace>/tools/async-profiler` (for `--profile`).
- `perf stat` on another process needs `kernel.perf_event_paranoid <= 1`; at a higher value the
  trial records `perf_stat_status: not_measured` instead of failing.
- `--perf-sched` needs `kernel.perf_event_paranoid = -1` and read access to `/sys/kernel/tracing`
  (`sudo chmod -R o+rx /sys/kernel/tracing`; neither setting survives a reboot).
- Latency trials and JFR or profiler runs are separate: an attached recorder inflates the tail it
  would explain.
