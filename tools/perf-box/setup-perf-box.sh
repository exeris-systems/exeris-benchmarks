#!/usr/bin/env bash
# setup-perf-box.sh — Put a DEDICATED BARE-METAL box into a deterministic
# benchmark state for the `perf-box-amd64` hardware profile, and record exactly
# what was set. Run AFTER tools/cloud/do/setup-droplet.sh (which installs the
# generic toolchain — it is provider-agnostic and works on Hetzner/OVH too).
#
# What this does that a cloud VM cannot:
#   - CPU governor -> performance (persisted across reboot via a systemd unit)
#   - CPU boost/turbo OFF by default (latency-baseline determinism; the
#     `perf-box-amd64` profile pins boost off for latency work). Flip on for a
#     throughput campaign with PERF_BOX_BOOST=on.
#   - Transparent Huge Pages -> madvise (removes khugepaged jitter)
#   - Records boost/THP/SMT/C-state/microcode/virt into perf-box-state.json,
#     and fills turbo_boost/isolated_cpus so capture-env.sh env.json is complete.
#
# FAIRNESS GUARD: refuses to run on a virtualized guest. You cannot control
# governor/boost/C-states under a hypervisor, so stamping `perf-box-amd64` on a
# VM would be a false hardware claim. This is a structural block, not advice.
#
# Usage (as root on the bare-metal box):
#   bash setup-perf-box.sh                 # governor=performance, boost=off, THP=madvise
#   PERF_BOX_BOOST=on bash setup-perf-box.sh
#   bash setup-perf-box.sh --reset         # revert to schedutil/boost-on and remove the unit
#
# Knobs (env):
#   PERF_BOX_BOOST=off|on      (default off — latency baseline)
#   PERF_BOX_THP=madvise|never|keep  (default madvise)
#   PERF_BOX_CSTATE=default|shallow  (default default; shallow disables deep idle
#                                     states via cpupower for wakeup-latency work)
set -euo pipefail

STATE_JSON="${PERF_BOX_STATE_JSON:-/root/perf-box-state.json}"
CONF=/etc/perf-box.conf
APPLY=/usr/local/sbin/perf-box-apply.sh
UNIT=/etc/systemd/system/perf-box-tuning.service

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "ERROR: must run as root" >&2; exit 1; }

# ---- reset path -------------------------------------------------------------
if [[ "${1:-}" == "--reset" ]]; then
  systemctl disable --now perf-box-tuning.service 2>/dev/null || true
  rm -f "$UNIT" "$APPLY" "$CONF"
  systemctl daemon-reload 2>/dev/null || true
  # best-effort revert
  if command -v cpupower >/dev/null 2>&1; then cpupower frequency-set -g schedutil >/dev/null 2>&1 || true; fi
  [[ -w /sys/devices/system/cpu/cpufreq/boost ]] && echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
  [[ -w /sys/devices/system/cpu/intel_pstate/no_turbo ]] && echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
  echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
  echo "perf-box tuning reverted (governor=schedutil, boost=on, THP=madvise)."
  exit 0
fi

# ---- fairness guard: bare metal only ---------------------------------------
# NB: systemd-detect-virt EXITS 1 when it reports "none" (bare metal). A naive
# `... || echo unknown` would APPEND "unknown" to the real "none" stdout and
# false-trip this guard on real hardware — capture stdout, ignore the exit code.
VIRT="$(systemd-detect-virt 2>/dev/null || true)"
[[ -z "$VIRT" ]] && VIRT="unknown"
if [[ "$VIRT" != "none" ]]; then
  echo "ERROR: systemd-detect-virt reports '$VIRT' — this is NOT bare metal." >&2
  echo "       perf-box tuning (governor/boost/C-states) is meaningless under a" >&2
  echo "       hypervisor and stamping perf-box-amd64 on a VM is a false hardware" >&2
  echo "       claim. Use hardware_profile=cloud-vm-do-* for virtualized boxes." >&2
  echo "       Override ONLY if you know detection is wrong: PERF_BOX_FORCE=1." >&2
  [[ "${PERF_BOX_FORCE:-0}" == "1" ]] || exit 2
  echo "WARN: PERF_BOX_FORCE=1 — proceeding despite virt='$VIRT'." >&2
fi

BOOST="${PERF_BOX_BOOST:-off}"
THP="${PERF_BOX_THP:-madvise}"
CSTATE="${PERF_BOX_CSTATE:-default}"

echo "== install cpupower =="
if ! command -v cpupower >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -yq "linux-tools-$(uname -r)" 2>/dev/null || apt-get install -yq linux-tools-generic linux-tools-common
fi

# ---- write the boot-time apply helper + conf --------------------------------
cat > "$CONF" <<EOF
# Consumed by $APPLY at boot and by setup-perf-box.sh. Edit + re-run either.
PERF_BOX_BOOST=$BOOST
PERF_BOX_THP=$THP
PERF_BOX_CSTATE=$CSTATE
EOF

cat > "$APPLY" <<'APPLYEOF'
#!/usr/bin/env bash
# perf-box-apply.sh — (re)apply the perf-box tuning. Idempotent; run at boot by
# perf-box-tuning.service and by setup-perf-box.sh. Reads /etc/perf-box.conf.
set -uo pipefail
# shellcheck disable=SC1091
[[ -r /etc/perf-box.conf ]] && . /etc/perf-box.conf
BOOST="${PERF_BOX_BOOST:-off}"; THP="${PERF_BOX_THP:-madvise}"; CSTATE="${PERF_BOX_CSTATE:-default}"

# governor -> performance (all CPUs)
if command -v cpupower >/dev/null 2>&1; then
  cpupower frequency-set -g performance >/dev/null 2>&1 || true
else
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -w "$g" ]] && echo performance > "$g" 2>/dev/null || true
  done
fi

# boost/turbo
want=1; [[ "$BOOST" == "off" ]] && want=0
if [[ -w /sys/devices/system/cpu/cpufreq/boost ]]; then          # amd_pstate / acpi-cpufreq
  echo "$want" > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
elif [[ -w /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then # intel_pstate (inverted)
  echo "$(( want ^ 1 ))" > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
fi

# transparent huge pages
if [[ "$THP" != "keep" && -w /sys/kernel/mm/transparent_hugepage/enabled ]]; then
  echo "$THP" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
fi

# deep C-state limiting (opt-in): disable idle states with exit latency > 1us
if [[ "$CSTATE" == "shallow" ]] && command -v cpupower >/dev/null 2>&1; then
  cpupower idle-set -D 1 >/dev/null 2>&1 || true
fi
APPLYEOF
chmod +x "$APPLY"

cat > "$UNIT" <<EOF
[Unit]
Description=Exeris perf-box CPU tuning (governor/boost/THP)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=$APPLY
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable perf-box-tuning.service >/dev/null 2>&1 || true
echo "== apply tuning now =="
"$APPLY"

# ---- record exact state -----------------------------------------------------
read_boost() {
  if [[ -r /sys/devices/system/cpu/cpufreq/boost ]]; then
    [[ "$(cat /sys/devices/system/cpu/cpufreq/boost)" == "1" ]] && echo true || echo false
  elif [[ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
    [[ "$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)" == "0" ]] && echo true || echo false
  else echo unknown; fi
}
GOV="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
BOOST_STATE="$(read_boost)"
THP_STATE="$(sed 's/.*\[\(.*\)\].*/\1/' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo unknown)"
SMT="$(cat /sys/devices/system/cpu/smt/control 2>/dev/null || echo unknown)"
IDLE_DRIVER="$(cat /sys/devices/system/cpu/cpuidle/current_driver 2>/dev/null || echo unknown)"
ISOLATED="$(cat /sys/devices/system/cpu/isolated 2>/dev/null || echo '')"
MICROCODE="$(grep -m1 microcode /proc/cpuinfo 2>/dev/null | awk '{print $3}' || echo unknown)"
CPU_MODEL="$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
KERNEL="$(uname -r)"

cat > "$STATE_JSON" <<EOF
{
  "captured_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "hardware_profile": "perf-box-amd64",
  "topology": "single-box-loopback",
  "virt": "$VIRT",
  "cpu_model": "$CPU_MODEL",
  "microcode": "$MICROCODE",
  "kernel": "$KERNEL",
  "cpu_governor": "$GOV",
  "turbo_boost": $( [[ "$BOOST_STATE" == unknown ]] && echo '"unknown"' || echo "$BOOST_STATE" ),
  "transparent_hugepage": "$THP_STATE",
  "smt": "$SMT",
  "cpuidle_driver": "$IDLE_DRIVER",
  "isolated_cpus": "$ISOLATED",
  "boost_intent": "$BOOST",
  "note": "boost off = latency-baseline determinism; flip PERF_BOX_BOOST=on for throughput campaigns and RE-LABEL the run (mixing boost-on/off within a series is not comparable)."
}
EOF

echo "== perf-box state =="
cat "$STATE_JSON"
echo
echo "cpuset layout (lscpu -e):"
lscpu -e=CPU,CORE,SOCKET 2>/dev/null | head -20 || true
echo
echo "OK. Persisted via perf-box-tuning.service (re-applied on every boot)."
echo "Record perf-box-state.json alongside each run; capture-env.sh --profile perf-box-amd64 fills the env.json."
echo "Reminder: pin driver and target to DISJOINT cpusets (see tools/perf-box/README or RUNBOOK)."
