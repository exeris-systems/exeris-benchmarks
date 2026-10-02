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
| `C_iso` | `ExerisCarrierScheduler`, per-carrier MPSC queue, no work stealing | carriers share the carrier CPUs |
| `D` | `ExerisCarrierScheduler` | each carrier bound to one carrier CPU (`exeris.carrier.affinity`) |

`C_iso` against `D` isolates pinning; `A_iso` against `C_iso` isolates the scheduler design.

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

A trial is `valid` only if all of these hold; `evidence` additionally requires the harness files to
be committed and the host to be shielded. Invalid trials stay in the campaign and are listed in
`summary.md`, never averaged.

- **transport** — the server log reports `active=posix-hybrid, ffmArmed=true`: socket I/O went
  through the FFM descriptor path. Without the `--add-opens` the harness passes, the transport falls
  back to NIO, which is not the path under study.
- **load** — `wrk2` achieved at least 99 % of the target rate.
- **errors** — no socket errors and no non-2xx responses.
- **isolation** — at the end of the window: the right number of carrier threads; shared-CPU arms
  allow exactly the carrier CPUs; arm `D` has each carrier on its own single CPU; no other server
  thread may run on a carrier CPU.
- **unperturbed** — no profiler or tracer attached. `--profile cpu|wall` (async-profiler) and
  `--perf-sched` (`perf sched record`, per-thread run time per CPU in
  `perf-sched-distribution.txt`) produce diagnostic trials only.

## Host prerequisites

- Loom EA JDK at `<workspace>/tools/jdk-loom/current`; async-profiler at
  `<workspace>/tools/async-profiler` (for `--profile`).
- `perf stat` on another process needs `kernel.perf_event_paranoid <= 1`; at a higher value the
  trial records `perf_stat_status: not_measured` instead of failing.
- `--perf-sched` needs `kernel.perf_event_paranoid = -1` and read access to `/sys/kernel/tracing`
  (`sudo chmod -R o+rx /sys/kernel/tracing`; neither setting survives a reboot).
- Latency trials and JFR or profiler runs are separate: an attached recorder inflates the tail it
  would explain.
