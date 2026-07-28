# Bare-metal perf-box setup (`tools/perf-box/`)

Prepares a **dedicated bare-metal** x86-64 box (e.g. a Hetzner auction Ryzen, an
OVH RISE) for the `perf-box-amd64` hardware profile: deterministic CPU state +
complete reproducibility metadata. Provider-agnostic.

## Flow

```bash
# 1. Toolchain (same installer as the cloud path — it is provider-agnostic)
ssh root@<box> "GITHUB_ACTOR=<u> GITHUB_TOKEN=<pat> bash -s" < tools/cloud/do/setup-droplet.sh

# 2. Bare-metal tuning (governor/boost/THP + records perf-box-state.json)
ssh root@<box> "bash -s" < tools/perf-box/setup-perf-box.sh          # boost OFF (latency)
# ...or for a throughput campaign:
ssh root@<box> "PERF_BOX_BOOST=on bash -s" < tools/perf-box/setup-perf-box.sh

# 3. Ship the repo, run campaigns labelled perf-box-amd64
./tools/cloud/do/sync-repo.sh bench@<box>
```

`setup-perf-box.sh` **refuses to run on a virtualized guest** (`systemd-detect-virt`)
— you cannot control governor/boost/C-states under a hypervisor, so stamping
`perf-box-amd64` on a VM would be a false hardware claim. That guard is why the
cloud droplets carry `cloud-vm-do-*`, not `perf-box-amd64`.

## Profile labelling — `perf-box-amd64`, topology recorded

The box is dedicated bare metal (no hypervisor, no neighbours), so it earns
`perf-box-amd64` for CPU/memory determinism. Our campaigns run **single-box
loopback** (target + DBs + driver on one machine), not the separate-loadgen
direct-L2 topology the profile's network section describes. That is a *more*
deterministic network path (no wire at all), fully within the profile's intent
("what we trust: relative within-profile comparisons") — but it is recorded, not
hidden: `perf-box-state.json` stamps `topology: single-box-loopback`, and
`capture-env.sh` fills `turbo_boost` + `isolated_cpus`. Do not frame single-box
loopback numbers as network-path capacity.

## CPU pinning — the split depends on WHAT you measure

Confirm the sibling layout first (`lscpu -e=CPU,CORE,SOCKET`); SMT siblings must
be pinned as a unit. Then, on an 8C/16T Ryzen:

- **Entity-read (target-efficiency question):** pin the target to the *smaller*
  cpuset so it saturates first and rps tracks target efficiency — e.g. target
  `--cpu-affinity 0-3`, driver `--client-cpu-affinity 4-11`, OS/DB `12-15`. This
  is the `dev-isolated` "target-bound local measurement" discipline on real hardware.
- **Saga (whole-deployment question, CONTRACT-v2 §1):** the unit of comparison is
  the *minimal production-plausible deployment* — you are NOT trying to bottleneck
  the app. Do **not** starve the target; give the co-located backends (Postgres,
  Neo4j, Axon Server / restate-server) enough cores that they are not the
  artificial limit, and record Σ RSS / ops-per-core across the whole deployment.
  A workable start: app `0-5`, backends `6-11`, driver `12-15` — then check no
  single process is pegged at 100% while others idle.

Both pins land in the run metadata; keep the two cpusets **disjoint**.

## Boost is a labelled axis, not a default

`boost=off` is the latency-baseline default (deterministic clocks). A throughput
campaign may want `boost=on` — but boost-on and boost-off numbers are **not
comparable within one series**. `perf-box-state.json` records `turbo_boost` and
`boost_intent`; re-label the run when you flip it.

## Reset

```bash
ssh root@<box> "bash -s" < tools/perf-box/setup-perf-box.sh --reset
```

Reverts governor→schedutil, boost→on, THP→madvise, removes the persistence unit.
