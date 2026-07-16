# DigitalOcean campaign runners (`tools/cloud/do/`)

Ephemeral benchmark boxes on DigitalOcean CPU-Optimized droplets
(hardware profile: `cloud-vm-do-cpu-optimized`, see `docs/hardware-profiles.md`):

- `exeris-bench-target` — target apps + Postgres/Neo4j/Axon; campaign scripts run here
- `exeris-bench-loadgen` — k6/wrk/wrk2/h2load driver box

Both sit in a dedicated VPC in the same region, so the driver reaches the target
over the private subnet (free traffic, no public hop, same-DC RTT ≈ 0.2–0.5 ms).

Two supported measurement classes — **never mix their results**:

1. **Single-box (harness-native today):** target + DBs + driver co-located on one
   droplet with disjoint taskset cpusets (`transport_mode=loopback-*`). Works with
   the campaign scripts as-is; either droplet can serve as a standalone runner.
2. **Split (VPC network path):** driver process on `exeris-bench-loadgen`, target +
   campaign orchestration on `exeris-bench-target`, k6/wrk pointed at the target's
   private IP. Carries a distinct `transport_mode` label (network path, not
   loopback) and requires the harness's remote-driver mode — the campaign scripts
   are loopback-only until that lands.

## Prerequisites

- `doctl` authenticated (`DIGITALOCEAN_ACCESS_TOKEN` env var or `doctl auth init`)
- `~/.ssh/id_ed25519.pub` (or point `DO_SSH_PUBKEY` elsewhere)
- GitHub PAT with `read:packages` for `eu.exeris:*` snapshots (GitHub Packages),
  passed to `setup-droplet.sh` as `GITHUB_ACTOR`/`GITHUB_TOKEN`

## Flow

```bash
# 1. Create the pair (2 × c-8-intel in fra1 by default; cost guard $0.55/h/pair)
./tools/cloud/do/provision-droplets.sh          # writes do-droplets.env (gitignored)

# 2. Provision each droplet (as root; ~5 min, includes wrk2 source build + image pulls)
ssh root@<ip> "GITHUB_ACTOR=<user> GITHUB_TOKEN=<pat> bash -s" \
  < tools/cloud/do/setup-droplet.sh

# 3. Ship the repo (git HEAD archive — commit first) to the 'bench' user
./tools/cloud/do/sync-repo.sh bench@<ip>

# 4. Run campaigns as 'bench' (never root), with pinning recorded per run
ssh bench@<ip>
cd ~/exeris-benchmarks && ./scripts/run-entity-read-by-id-campaign.sh --help

# 5. Pull results back (results/raw/<scenario>/<stamp>-campaign/)
scp -r bench@<ip>:exeris-benchmarks/results/raw/entity-read-by-id/<stamp>-campaign results/raw/entity-read-by-id/

# 6. DESTROY when idle — droplets bill per-second while they EXIST (even powered off)
./tools/cloud/do/destroy-droplets.sh --yes
```

## Sizing / cost

Default slug preference: `c-8-intel` (8 dedicated vCPU / 16 GB, NVMe) then `c-8`;
both $0.25/h ⇒ $0.50/h ≈ **$12/day for the pair**. Override with `DO_SIZE=<slug>`;
the provision script aborts if the pair would exceed `DO_MAX_HOURLY_TOTAL`
(default $0.55/h).

Suggested cpuset split on 8 vCPU (target gets the smaller budget so it saturates
first): target `0-1`, driver `2-5`, OS + containers `6-7`.

## Known wrinkles

- The runtime JDK must be **26 with `--enable-preview`** (matches target poms);
  `setup-droplet.sh` installs Temurin 26 to `/opt/jdk26` and sets it system-wide
  via `/etc/environment`.
- `run-entity-read-by-id-campaign.sh` preflight requires an `exeris-kernel-community`
  jar in `~/.m2`, while `targets/exeris-community-app/pom.xml` currently declares the
  runtime-scoped `exeris-kernel-enterprise` snapshot (community dep commented out) —
  reconcile before the first campaign run; the PAT must be able to read whichever
  package the pom resolves.
- The saga baseline assumes `sudo systemctl restart docker` (self-heal) — the
  `bench` user gets exactly that one sudoers entry, nothing broader.
- k6 installs natively; if that ever breaks, the harness falls back to
  `docker run grafana/k6` on its own (`tools/bench/lib/k6.sh`).
- Confidentiality: these are Community-track runners. Do not place Enterprise
  H3/locality artifacts on public-cloud droplets beyond what the community campaign
  itself resolves, and never publish raw `.jfr` from them (`publish-report.sh`
  public mode default-denies it).
