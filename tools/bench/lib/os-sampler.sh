#!/usr/bin/env bash
# os-sampler.sh — OS-level sidecar samplers for runtime benchmarks.
#
# Two complementary signals that the per-process resource sampler cannot give:
#
#   pidstat -t -u -w   (per-thread)  → %wait per thread (direct C2-starvation
#                                      signal) + voluntary/involuntary context
#                                      switches per worker thread.
#   mpstat  -P ALL      (per-CPU)    → %usr / %sys / %soft / %idle. High %soft
#                                      (softirq = packet processing) or high %sys
#                                      means CPU is burned on the network/kernel,
#                                      not the app — the detector for the
#                                      backend-container-networking fairness hole.
#
# Both are OPT-IN and degrade gracefully: if the tool is missing, the sampler is
# a no-op and the caller continues. Raw tool output is captured to "<csv>.raw"
# and converted to CSV on stop, so a killed sampler still leaves usable data.
#
# CONTAINER NAMESPACE WRINKLE: pidstat/mpstat run on the host and see host PIDs.
# Targets launched on the host (jar mode) or in `network_mode: host` containers
# are visible directly. For a backend in a bridged container, resolve its
# host-side PID with bench_resolve_container_host_pid and pass that to the
# pidstat sampler (the kernel scheduler view is host-global regardless of the
# PID namespace the process believes it lives in).
set -u

# Convert a whitespace-delimited table to CSV: trim, collapse runs of spaces to
# a single comma. Used for both pidstat -h and mpstat output.
_os_sampler_row_to_csv() {
  sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/,/g'
}

# bench_start_pidstat_sampler <pid> <out_csv> [interval_s]
# Echoes the background sampler PID (empty string if not started).
bench_start_pidstat_sampler() {
  local pid="$1" out_csv="$2" interval="${3:-1}"
  if ! command -v pidstat >/dev/null 2>&1; then
    echo ""; return 0
  fi
  if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ || ! -d "/proc/$pid" ]]; then
    echo ""; return 0
  fi
  local raw="${out_csv}.raw"
  # -h: one sample per line, no repeated table headers (clean to convert).
  # -t: per-thread.  -u: CPU incl. %wait.  -w: context switches.
  # LC_ALL=C is REQUIRED: locales with a decimal comma (e.g. pl_PL) print "0,00",
  # which a space→comma CSV conversion would split into two fields and corrupt
  # every numeric column. Forcing C also keeps "." decimals for downstream parsers.
  # S_TIME_FORMAT=ISO gives a stable leading timestamp column.
  LC_ALL=C S_TIME_FORMAT=ISO pidstat -h -t -u -w -p "$pid" "$interval" > "$raw" 2>/dev/null &
  echo "$!"
}

# bench_stop_pidstat_sampler <bg_pid> <out_csv>
bench_stop_pidstat_sampler() {
  local bgpid="$1" out_csv="$2"
  if [[ -n "$bgpid" ]]; then
    kill "$bgpid" >/dev/null 2>&1 || true
    wait "$bgpid" 2>/dev/null || true
  fi
  local raw="${out_csv}.raw"
  [[ -f "$raw" ]] || return 0
  # pidstat -h prints a "Linux ..." banner, a "# Time ..." header, and may emit
  # "Average:" rows. Drop the banner, keep the first header (once, "#" stripped),
  # keep all per-sample data rows, drop Average rows.
  #
  # Command-column hazard: with -t, the trailing Command column holds JVM thread
  # comms that contain spaces ("C2 CompilerThread0", "G1 Young RemSet Sampling").
  # A blind whitespace->comma collapse would split those into extra fields and
  # give variable column counts on exactly the rows we care about (the C2 thread
  # for the %wait signal). So convert only the fixed leading columns to commas and
  # keep Command verbatim as a single quoted final field. The Command index is read
  # from the header; if it can't be found we fall back to the plain collapse.
  awk '
    NF==0 { next }
    /Linux/ { next }
    /^Average:/ { next }
    /^#/ {
      if (!hdr) {
        sub(/^#[ \t]*/, "")
        for (i=1; i<=NF; i++) if ($i=="Command") cmd=i
        out=$1; for (i=2; i<=NF; i++) out=out","$i
        print out; hdr=1
      }
      next
    }
    {
      if (cmd>0 && NF>=cmd) {
        out=$1; for (i=2; i<cmd; i++) out=out","$i
        c=$cmd; for (i=cmd+1; i<=NF; i++) c=c" "$i
        gsub(/"/, "\"\"", c)            # escape embedded quotes (rare)
        print out",\"" c "\""
      } else {
        gsub(/[ \t]+/, ","); sub(/^,/, ""); sub(/,$/, ""); print
      }
    }
  ' "$raw" > "$out_csv"
  rm -f "$raw" 2>/dev/null || true
}

# bench_start_mpstat_sampler <out_csv> [interval_s]
# Echoes the background sampler PID (empty string if not started).
bench_start_mpstat_sampler() {
  local out_csv="$1" interval="${2:-1}"
  if ! command -v mpstat >/dev/null 2>&1; then
    echo ""; return 0
  fi
  local raw="${out_csv}.raw"
  # LC_ALL=C: same decimal-comma hazard as pidstat (see bench_start_pidstat_sampler).
  LC_ALL=C S_TIME_FORMAT=ISO mpstat -P ALL "$interval" > "$raw" 2>/dev/null &
  echo "$!"
}

# bench_stop_mpstat_sampler <bg_pid> <out_csv>
bench_stop_mpstat_sampler() {
  local bgpid="$1" out_csv="$2"
  if [[ -n "$bgpid" ]]; then
    kill "$bgpid" >/dev/null 2>&1 || true
    wait "$bgpid" 2>/dev/null || true
  fi
  local raw="${out_csv}.raw"
  [[ -f "$raw" ]] || return 0
  # mpstat repeats a "...CPU ... %idle" header per interval and prints a banner
  # ("Linux ...") plus trailing "Average:" rows. Keep the first %idle header and
  # all per-CPU data rows; drop the banner, blank lines, and Average rows.
  awk '
    NF==0 { next }
    /Linux/ { next }
    /%idle/ { if (!hdr) { print; hdr=1 } next }
    /^Average:/ { next }
    { print }
  ' "$raw" | _os_sampler_row_to_csv > "$out_csv"
  rm -f "$raw" 2>/dev/null || true
}

# bench_resolve_container_host_pid <container_name_or_id>
# Echoes the host-side PID of a (bridged) container's main process, or "" if
# docker is unavailable / the container is not running. See namespace note above.
bench_resolve_container_host_pid() {
  local container="$1"
  command -v docker >/dev/null 2>&1 || { echo ""; return 0; }
  local hpid
  hpid="$(docker inspect -f '{{.State.Pid}}' "$container" 2>/dev/null || true)"
  [[ "$hpid" =~ ^[0-9]+$ && "$hpid" != "0" ]] && echo "$hpid" || echo ""
}
