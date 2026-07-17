#!/usr/bin/env bash
# setup-droplet.sh — Provision an Ubuntu 24.04 droplet as a single-box
# exeris-benchmarks campaign runner (target + DBs + driver co-located,
# separated by disjoint taskset cpusets).
#
# Installs: JDK 26 (Temurin), Maven, Docker + compose v2, wrk, wrk2 (source),
# h2load (nghttp2-client), k6, psql client, sysstat (pidstat/mpstat), perf,
# jq/gawk/uuid-runtime, and pre-pulls the campaign container images.
# Creates non-root user 'bench' (docker group + systemd linger for
# systemd-run --user cgroup scopes).
#
# Usage (from the repo root, GITHUB_* needed to build eu.exeris snapshots):
#   ssh root@<ip> "GITHUB_ACTOR=<user> GITHUB_TOKEN=<pat-with-read:packages> bash -s" \
#     < tools/cloud/do/setup-droplet.sh
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
# Fresh droplets run cloud-init + unattended-upgrades on first boot; both hold
# the apt/dpkg locks. Wait for them instead of racing.
APT=(apt-get -o DPkg::Lock::Timeout=600)

echo "== waiting for cloud-init to finish first-boot work =="
cloud-init status --wait >/dev/null 2>&1 || true

echo "== apt packages =="
"${APT[@]}" update -q
"${APT[@]}" install -yq --no-install-recommends \
  build-essential libssl-dev zlib1g-dev unzip git jq gawk curl ca-certificates gnupg \
  nghttp2-client wrk postgresql-client sysstat util-linux uuid-runtime openssl maven
"${APT[@]}" install -yq "linux-tools-$(uname -r)" 2>/dev/null || "${APT[@]}" install -yq linux-tools-generic

echo "== JDK 26 (Temurin) =="
if [[ ! -x /opt/jdk26/bin/java ]]; then
  mkdir -p /opt/jdk26
  curl -fsSL "https://api.adoptium.net/v3/binary/latest/26/ga/linux/x64/jdk/hotspot/normal/eclipse" \
    -o /tmp/jdk26.tar.gz
  tar xzf /tmp/jdk26.tar.gz -C /opt/jdk26 --strip-components=1
  rm -f /tmp/jdk26.tar.gz
fi
/opt/jdk26/bin/java -version
cat > /etc/environment <<'EOF'
PATH="/opt/jdk26/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
JAVA_HOME="/opt/jdk26"
EOF

echo "== Docker + compose v2 =="
"${APT[@]}" install -yq docker.io docker-compose-v2
systemctl enable --now docker

echo "== wrk2 (source build; apt has only wrk) =="
if [[ ! -x /usr/local/bin/wrk2 ]]; then
  rm -rf /tmp/wrk2
  git clone --depth 1 https://github.com/giltene/wrk2 /tmp/wrk2
  make -C /tmp/wrk2 -j"$(nproc)"
  install -m 0755 /tmp/wrk2/wrk /usr/local/bin/wrk2
  rm -rf /tmp/wrk2
fi

echo "== k6 (Grafana apt repo; docker image fallback exists in the harness) =="
if ! command -v k6 >/dev/null 2>&1; then
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://dl.k6.io/key.gpg | gpg --dearmor -o /etc/apt/keyrings/k6.gpg
  echo "deb [signed-by=/etc/apt/keyrings/k6.gpg] https://dl.k6.io/deb stable main" \
    > /etc/apt/sources.list.d/k6.list
  "${APT[@]}" update -q
  "${APT[@]}" install -yq k6
fi

echo "== bench user (non-root runner) =="
id bench >/dev/null 2>&1 || useradd -m -s /bin/bash bench
usermod -aG docker bench
mkdir -p /home/bench/.ssh
cp /root/.ssh/authorized_keys /home/bench/.ssh/authorized_keys
chmod 700 /home/bench/.ssh
chmod 600 /home/bench/.ssh/authorized_keys
chown -R bench:bench /home/bench/.ssh
# user systemd manager for systemd-run --user cgroup scopes (saga --cgroup-* flags)
loginctl enable-linger bench
# saga baseline self-heals Docker via 'sudo systemctl restart docker'
echo 'bench ALL=(root) NOPASSWD: /usr/bin/systemctl restart docker' > /etc/sudoers.d/bench-docker
chmod 440 /etc/sudoers.d/bench-docker

echo "== Maven auth for eu.exeris GitHub Packages snapshots =="
if [[ -n "${GITHUB_ACTOR:-}" && -n "${GITHUB_TOKEN:-}" ]]; then
  mkdir -p /home/bench/.m2
  # Servers AND repositories: the target poms do not declare the GPR repos
  # (only micro/jmh does), so the settings profile must supply them or
  # resolution silently consults Maven Central only.
  cat > /home/bench/.m2/settings.xml <<EOF
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
  <servers>
    <server>
      <id>github-exeris-kernel</id>
      <username>${GITHUB_ACTOR}</username>
      <password>${GITHUB_TOKEN}</password>
    </server>
    <server>
      <id>github-exeris-spring-runtime</id>
      <username>${GITHUB_ACTOR}</username>
      <password>${GITHUB_TOKEN}</password>
    </server>
  </servers>
  <profiles>
    <profile>
      <id>github-exeris</id>
      <repositories>
        <repository>
          <id>github-exeris-kernel</id>
          <url>https://maven.pkg.github.com/exeris-systems/exeris-kernel</url>
          <releases><enabled>true</enabled></releases>
          <snapshots><enabled>true</enabled></snapshots>
        </repository>
        <repository>
          <id>github-exeris-spring-runtime</id>
          <url>https://maven.pkg.github.com/exeris-systems/exeris-spring-runtime</url>
          <releases><enabled>true</enabled></releases>
          <snapshots><enabled>true</enabled></snapshots>
        </repository>
      </repositories>
    </profile>
  </profiles>
  <activeProfiles>
    <activeProfile>github-exeris</activeProfile>
  </activeProfiles>
</settings>
EOF
  chmod 600 /home/bench/.m2/settings.xml
  chown -R bench:bench /home/bench/.m2
  echo "wrote /home/bench/.m2/settings.xml (600)"
else
  echo "WARNING: GITHUB_ACTOR/GITHUB_TOKEN not provided — target builds will fail to" >&2
  echo "         resolve eu.exeris:* snapshots until ~/.m2/settings.xml is provisioned." >&2
fi

echo "== benchmark sysctls =="
cat > /etc/sysctl.d/99-exeris-bench.conf <<'EOF'
# perf stat as non-root (campaign --require-perf-stat probe)
kernel.perf_event_paranoid = 1
# load-generator connection churn headroom
net.core.somaxconn = 4096
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_tw_reuse = 1
EOF
sysctl --system >/dev/null
# harness file-descriptor headroom for wrk/h2load/k6 + JVM
cat > /etc/security/limits.d/99-exeris-bench.conf <<'EOF'
bench soft nofile 262144
bench hard nofile 262144
EOF

echo "== pre-pull campaign container images =="
docker pull -q postgres:16.2
docker pull -q neo4j:5.16-community
docker pull -q axoniq/axonserver:2024.2.22
docker pull -q grafana/k6:latest || true

echo "== summary =="
for c in java mvn docker wrk wrk2 h2load k6 jq taskset pidstat perf psql; do
  printf '%-8s: %s\n' "$c" "$(command -v "$c" || echo MISSING)"
done
echo "OK — sync the repo next: ./tools/cloud/do/sync-repo.sh bench@<this-ip>"
