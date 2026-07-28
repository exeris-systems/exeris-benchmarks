# Droplet measurement runbook (July 2026 window)

Budget: GitHub Student credit, ~$134 to 2026-08-01. Pair of `c-8-intel` ≈ $12/day.
Everything below assumes `tools/cloud/do/do-droplets.env` exists (written by
`provision-droplets.sh`) and both droplets are set up + synced.

## Phase 0 — bring-up (once per pair lifetime)

```bash
./tools/cloud/do/provision-droplets.sh
ssh root@$TARGET_PUBLIC_IP  "GITHUB_ACTOR=<u> GITHUB_TOKEN=<pat> bash -s" < tools/cloud/do/setup-droplet.sh
ssh root@$LOADGEN_PUBLIC_IP "GITHUB_ACTOR=<u> GITHUB_TOKEN=<pat> bash -s" < tools/cloud/do/setup-droplet.sh
./tools/cloud/do/sync-repo.sh bench@$TARGET_PUBLIC_IP
./tools/cloud/do/sync-repo.sh bench@$LOADGEN_PUBLIC_IP
```

Sanity on each box: `ssh bench@<ip> 'java -version && mvn -version && wrk2 -v; k6 version'`.

## Phase 1 — 24h mixed-traffic entity soak (split topology, exploratory)

Occupies BOTH droplets: target box serves, loadgen box drives over the VPC
private subnet. **Exploratory only** (k6 driver ≠ wrk-defined contract;
network path ≠ loopback — label accordingly, never mix with loopback rows).

Target box (`bench@TARGET`):

```bash
cd ~/exeris-benchmarks
# DB + seed (compose file used by the entity runner)
docker compose -f runtime/compose/entity-read-by-id-db.yml up -d
scenarios/entity-read-by-id/infra-setup.sh   # seed/verify path per scenario README
# Build + launch the community target pinned away from OS/DB cores
mvn -f targets/exeris-community-app/pom.xml -DskipTests package
EXERIS_DB_JDBC_URL=jdbc:postgresql://localhost:5432/benchmark_db \
EXERIS_DB_USERNAME=benchmark EXERIS_DB_PASSWORD=benchmark \
EXERIS_PORT=8080 \
nohup taskset -c 0-5 java --enable-preview -jar \
  targets/exeris-community-app/target/exeris-community-app-1.0.0-SNAPSHOT.jar \
  > ~/target-soak.log 2>&1 &
```

Loadgen box (`bench@LOADGEN`), using the TARGET's **private** IP:

```bash
cd ~/exeris-benchmarks
K6_BASE_URL=http://$TARGET_PRIVATE_IP:8080 \
K6_RATE=<sub-saturation rate> K6_DURATION=24h K6_HOT_RATIO=0.8 \
nohup ./scripts/run-k6.sh targets/exeris-community-app scenarios/entity-read-by-id \
  > ~/k6-soak.log 2>&1 &
```

Pick `K6_RATE` from a 2-minute saturation probe first, then set ~60-70% of it
(sub-saturation soak; we want steady-state behavior over time, not a stress test).
Watch: `ssh bench@LOADGEN tail -f k6-soak.log` and droplet graphs (monitoring is on).

## Phase 2 — comparison-grade entity campaign (single-box, pinned; after Phase 1)

On the target box (loadgen idle — destroy it if the wallet matters more than
convenience; recreate takes ~5 min):

```bash
cd ~/exeris-benchmarks
BENCHMARK_ENABLE_LOCALITY_MODE=1 \
MEASUREMENT_SECONDS=300 WARMUP_SECONDS=120 \
nohup ./scripts/run-entity-read-by-id-campaign.sh \
  --hardware-profile cloud-vm-do-cpu-optimized \
  --repeats 10 \
  --cpu-affinity 0-1 \
  > ~/campaign-entity.log 2>&1 &
```

2 modes × 10 repeats × ~8 min ≈ 2.7 h. Scale `MEASUREMENT_SECONDS`/`--repeats`
to fill available window; `-f`-style shortcuts do not exist here — window size
is the knob.

## Phase 3 — saga v2 runs (after v2 change set lands + resync)

```bash
./tools/cloud/do/sync-repo.sh bench@$TARGET_PUBLIC_IP   # ship the v2 HEAD
ssh bench@$TARGET_PUBLIC_IP
cd ~/exeris-benchmarks
nohup ./scripts/run-e2e-shop-order-saga-campaign.sh \
  --targets exeris-community,spring-hibernate,quarkus-hibernate \
  --graph-track neo4j \
  --profile cloud-vm-do-cpu-optimized \
  > ~/campaign-saga.log 2>&1 &
```

The v2 correctness gate (exact compensation count) fails the run loudly on
mismatch — that is a *result* (correctness finding), not a harness bug; do not
re-run to make it pass.

## Pulling results back

```bash
scp -r bench@<ip>:exeris-benchmarks/results/raw/<scenario>/<stamp>* results/raw/<scenario>/
```

Raw `.jfr` stays out of git and out of public artifacts (publication mode `public`
default-denies it).

## Cost discipline

- Droplets bill per-second **while they exist** (powered off still bills).
- Idle box → `./tools/cloud/do/destroy-droplets.sh --yes`; recreate is ~5 min.
- Check burn: `doctl balance get` / `doctl invoice list`.
