# Hardware Profiles

Canonical hardware classes used to qualify benchmark results.
Each result JSON must reference one of these profile identifiers.

---

## dev-laptop

A developer machine. Results in this class are useful for detecting regressions
between two runs on the same machine, but **must not** be published as performance
claims.

| Field | Example value |
|---|---|
| `profile_id` | `dev-laptop` |
| CPU | Any modern x86-64 mobile CPU |
| Cores | 4–16 physical / 8–32 logical |
| RAM | 16–64 GB |
| Storage | NVMe SSD |
| Network | loopback (benchmarks run locally) |
| OS | Linux (any recent kernel), macOS |
| Notes | Turbo Boost likely enabled; background processes possible |

---

## dev-isolated

A developer-controlled Linux machine prepared for low-noise benchmarking.
Used for exploratory and pre-publication runs when a dedicated bare-metal perf box
is not available.

| Field | Example value |
|---|---|
| `profile_id` | `dev-isolated` |
| CPU | Modern x86-64 desktop/workstation CPU |
| Cores | Recorded exactly |
| RAM | Recorded exactly |
| Storage | Local NVMe SSD |
| Network | loopback |
| OS | Linux ≥ 5.15 |
| GUI | Disabled during benchmark run |
| CPU governor | `performance` preferred |
| Background processes | Minimized; browser/IDE/desktop session closed |
| Notes | Lower noise than `dev-laptop`, but still not equivalent to `perf-box-amd64`. Absolute publication claims require explicit caveat unless later confirmed on dedicated hardware. |

### Target-bound local measurement (CPU pinning)

On a loopback box the driver (wrk/h2load), the target JVM, and Postgres all share the same
cores, so a CPU-efficiency improvement in the target does **not** show up as throughput — the
driver just steals back the freed cycles, and run-to-run variance swamps the signal. To make a
local run **target-bound** (target = the bottleneck, so rps tracks target efficiency), pin the
target and the driver to **disjoint** cpusets:

- `run-entity-read-by-id.sh --cpu-affinity <target-cpuset> --client-cpu-affinity <driver-cpuset>`
  (or answer the two affinity prompts in `run-guided.sh`, LOCAL + unconstrained).
- Recommended split on a 12-core box: **target `0-2`** (3 cores — the bottleneck), **driver `3-9`**
  (7 cores — enough to saturate the target), leaving `10-11` for the OS and Postgres. Give the
  target the *smaller* budget so it saturates first.
- Both pins are recorded in the run (`cpuAffinity` / `clientCpuAffinity` in `result.json` notes
  and the guided profile). Keep the two cpusets disjoint — overlapping them reintroduces the
  contention this is meant to remove.

Even target-bound, treat a single run as noisy: take 2–3 repetitions before concluding, and
prefer the JFR CPU-profile share (per-method) as the primary signal for transport/allocation
efficiency work.

---

## ci-runner

GitHub Actions or similar hosted runner. Used only for smoke / regression-detection
runs, never for absolute-number baselines. Hardware is not guaranteed stable between
runs.

| Field | Example value |
|---|---|
| `profile_id` | `ci-runner` |
| CPU | 2–8 vCPU (shared, no pinning) |
| RAM | 7–16 GB |
| Storage | SSD or ephemeral |
| Network | loopback |
| OS | ubuntu-latest |
| Notes | High variance expected; compare only relative to same runner class |

---

## perf-box-amd64

Dedicated bare-metal performance machine, x86-64. Baseline results published
for Community and Enterprise use this profile.

| Field | Required |
|---|---|
| `profile_id` | `perf-box-amd64` |
| CPU model | Recorded exactly (e.g., `AMD EPYC 7763 64-Core`) |
| Physical cores | Recorded |
| Logical threads | Recorded |
| RAM | Recorded (e.g., `128 GB DDR4-3200`) |
| Storage | NVMe SSD (local, not SAN) |
| Network | **Direct L2/VLAN, bare-metal / SR-IOV passthrough** (see network decisions below) |
| OS | Linux ≥ 5.15, `performance` CPU governor |
| Kernel version | **Recorded exactly** (`uname -r`) — the profile id does NOT pin the kernel |
| OS scheduler | **Recorded** (`cfs` / `eevdf`) — see scheduler note below |
| Turbo / Boost | **Disabled** for latency baselines |
| Kernel args | `isolcpus`, `nohz_full` if used — recorded |
| Notes | No other workloads during measurement |

### Network decisions (explicit constraints, not omissions)

`perf-box-amd64` fixes the network shape so packet-processing noise does not leak
into runtime numbers. These are recorded as part of the profile so a reader knows
exactly what was traded away:

- **Direct L2 / VLAN** — no VPN, no VM overlay between load generator and target.
- **`nftables` bypass** — host firewall chains are bypassed on the benchmark path.
  **This is temporary**: it removes `nft_do_chain` cost from the hot path but is
  not a production-representative configuration. Treat any absolute number gathered
  with the bypass as an upper bound, not a production figure.
- **Bare-metal / SR-IOV passthrough** — NIC is passed through directly; no bridge,
  no `docker-proxy` on the target↔client path.

**Trade-off (state it, do not hide it):** this configuration removes virtualization
and packet-processing variance, which is what makes the numbers reproducible — but
it moves *away* from a production-shaped network. Cross-environment claims ("X req/s
in production") are out of scope for this profile. What we trust here: relative
within-profile comparisons. What we do not trust here: absolute production capacity,
and anything involving the bypassed firewall path.

### Kernel and scheduler are not pinned by the profile id

Two runs both labelled `perf-box-amd64` can differ materially with **no code change**
if the kernel or CPU scheduler differs — the CFS→EEVDF switch (kernel default since
6.6) alone can move worst-case throughput by tens of percent. Therefore
`kernel_version` and `os_scheduler` are captured per run (`scripts/capture-env.sh`
into `env.json`; also surfaced in `reproducibility-metadata`). **Never** compare
across differing `kernel_version` / `os_scheduler` without calling out the difference.

### Backend container network mode

When a scenario uses containerized stateful backends (Postgres / Neo4j / Axon),
record `backend_network_mode` (`host` vs `bridge`). Bridge/NAT adds an asymmetric
tax across stacks of differing DB-chattiness — a fairness hazard, not hygiene. See
`docs/methodology.md` → "Backend container networking is a fairness gate".

---

## perf-box-arm64

Dedicated bare-metal performance machine, ARM64 (AArch64). Used for
cross-architecture comparison runs.

| Field | Required |
|---|---|
| `profile_id` | `perf-box-arm64` |
| CPU model | Recorded exactly (e.g., `AWS Graviton3`, `Ampere Altra`) |
| Physical cores | Recorded |
| RAM | Recorded |
| Storage | NVMe SSD |
| Network | loopback or dedicated NIC |
| OS | Linux ≥ 5.15 |

---

## cloud-vm-do-cpu-optimized

DigitalOcean CPU-Optimized droplet (dedicated vCPUs) used as a **single-box campaign
runner**: target JVM, databases, and load driver co-located on one droplet, separated
by **disjoint taskset cpusets** exactly as described under `dev-isolated` →
"Target-bound local measurement". Used for exploratory and cross-runtime campaign
runs when a dedicated bare-metal perf box is not available. Provisioning tooling:
`tools/cloud/do/`.

| Field | Value |
|---|---|
| `profile_id` | `cloud-vm-do-cpu-optimized` |
| CPU | Dedicated cloud vCPU (Intel 2.6 GHz+); model string **recorded exactly per run** |
| Cores | Recorded exactly (e.g., 8 vCPU) |
| RAM | Recorded exactly (e.g., 16 GB) |
| Storage | Virtualized SSD/NVMe |
| Network | loopback (driver and target co-located) |
| CPU pinning | **Required** — disjoint `--cpu-affinity` / `--client-cpu-affinity` cpusets, both recorded per run |
| OS | Ubuntu 24.04 LTS; kernel version recorded exactly (`uname -r`) |
| CPU governor | Not controllable (hypervisor-managed) — recorded as such |
| Notes | See trade-offs below |

Example split on an 8 vCPU droplet (target gets the *smaller* budget so it saturates
first): target `0-1`, driver `2-5`, OS + containers `6-7`.

### Trade-offs (state them, do not hide them)

- **Hypervisor present**: no turbo/governor control, no `isolcpus`, and residual
  neighbor noise is possible despite dedicated vCPUs. Two droplets on the same slug
  can land on different physical CPU models — record the CPU model per run and never
  compare across differing models without calling it out.
- **Loopback, same box** — all `dev-isolated` local-measurement caveats apply
  (pinning removes core-stealing, not cache/memory-bandwidth sharing).
- Running two campaigns in parallel on **two separate droplets** is fine (they share
  nothing); running two campaigns on **one** droplet concurrently is not.
- A driver-split variant over the VPC private network (low-level drivers with
  `*_BASE_URL_OVERRIDE` against a target on a second droplet) is a **different
  measurement class** — different network model, no local PID access for
  resource/JFR sampling. Do not mix its numbers with single-box runs of this
  profile without an explicit caveat.
- What we trust here: **relative within-profile comparisons** (same droplet, same
  pinning split, same run window). What we do not trust: absolute production
  capacity claims, or promotion of numbers to `perf-box-amd64`-grade baselines.
  Absolute publication claims require an explicit caveat.

---

## cloud-vm-do-shared

DigitalOcean Basic (shared vCPU) droplet — the fallback class when CPU-Optimized
sizes are not unlocked on the account. Same tooling and topology options as
`cloud-vm-do-cpu-optimized`, but vCPUs are **shared with neighbors**: steal time
is possible and unmeasurable in advance. **Exploratory-only**: soak/drift runs and
relative trends within a single run window. Never comparison-eligible, never a
baseline source.

| Field | Value |
|---|---|
| `profile_id` | `cloud-vm-do-shared` |
| CPU | Shared cloud vCPU (e.g. `s-4vcpu-8gb-intel`); model + steal-time recorded per run |
| Cores | Recorded exactly |
| RAM | Recorded exactly |
| Network | loopback or VPC private subnet (recorded; axes as in `cloud-vm-do-cpu-optimized`) |
| OS | Ubuntu 24.04 LTS; kernel recorded exactly |
| Notes | `vmstat` steal sample captured by `capture-env.sh`; claims limited to descriptive/trend statements |

---

## docker-container

Containerized target run. Used for compat/ and scenario/ benchmarks where
the application under test runs inside Docker.

| Field | Value |
|---|---|
| `profile_id` | `docker-container` |
| Container runtime | Docker ≥ 24 or containerd |
| CPU limit | Recorded (e.g., `--cpus 4`) |
| Memory limit | Recorded (e.g., `--memory 1g`) |
| Network mode | `host` preferred; `bridge` if noted |
| Host profile | Reference to one of the above profiles |

---

## Adding a new profile

Add a new section to this file. All fields must be documented. Reference the
new `profile_id` from result JSON files.
