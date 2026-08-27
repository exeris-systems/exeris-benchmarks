#!/usr/bin/env bash
# destructive.sh — shared helpers for destructive / fuzz / chaos campaigns.
#
# All functions are side-effect-free except where documented. Source this file
# into a campaign script; assume readiness.sh has already been sourced if you
# need bench_health_http_code.
#
# Reusable helpers:
#   destructive_capture_rss <pid>
#       echoes "<rss_bytes> <vsz_bytes>" on stdout, or "unobtained unobtained"
#       if the PID is unknown / /proc entry is gone / ps output is empty.
#       Callers MUST distinguish "unobtained" from numeric 0 — emitting a
#       literal 0 here would silently classify a no-signal run as "stable".
#   destructive_jcmd_native_heap_committed <pid>
#       echoes committed-native-heap-bytes from `jcmd <pid> VM.native_memory summary`
#       requires NMT to be enabled on the target; echoes "" if unavailable
#   destructive_start_jfr <pid> <output_file> [name]
#       starts a JFR profile recording; returns 0 on success
#   destructive_stop_jfr <pid> [name]
#       stops the recording started with destructive_start_jfr
#   destructive_liveness_probe <base_url> <path> <expected_status> <max_response_ms> [h1|h2|h2c]
#       sends one curl GET to the target over the named protocol (default h1) and sets
#       DESTR_PROBE_STATUS / _DURATION_MS / _ALIVE / _HTTP_VERSION / _PROTOCOL. An h2/h2c probe
#       that is answered over HTTP/1.1 FAILS rather than passing quietly.
#   destructive_emit_findings_json <output_path> <jq-filter>
#       writes a destructive-findings.json sidecar from jq filter input

set -u

DESTR_PROBE_STATUS=""
DESTR_PROBE_DURATION_MS=""
DESTR_PROBE_ALIVE=""

destructive_capture_rss() {
  local pid="${1:-}"
  if [[ -z "$pid" || "$pid" == "0" || ! -d "/proc/$pid" ]]; then
    echo "unobtained unobtained"
    return 1
  fi
  local rss_kb vsz_kb
  read -r rss_kb vsz_kb < <(ps -o rss=,vsz= -p "$pid" 2>/dev/null | tr -s ' ' || true)
  if [[ -z "${rss_kb:-}" || -z "${vsz_kb:-}" ]]; then
    echo "unobtained unobtained"
    return 1
  fi
  printf '%d %d\n' "$((rss_kb * 1024))" "$((vsz_kb * 1024))"
}

destructive_jcmd_native_heap_committed() {
  local pid="${1:-}"
  if [[ -z "$pid" ]] || ! command -v jcmd >/dev/null 2>&1; then
    return 1
  fi
  local nmt_out
  nmt_out="$(jcmd "$pid" VM.native_memory summary scale=KB 2>/dev/null || true)"
  if [[ -z "$nmt_out" || "$nmt_out" == *"Native memory tracking is not enabled"* ]]; then
    return 1
  fi
  local committed_kb
  committed_kb="$(printf '%s' "$nmt_out" | awk '
    /Total:/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /committed=/) {
          gsub(/[^0-9]/, "", $i)
          print $i
          exit
        }
      }
    }')"
  if [[ -z "$committed_kb" || ! "$committed_kb" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  printf '%d\n' "$((committed_kb * 1024))"
}

destructive_start_jfr() {
  local pid="${1:-}"
  local output="${2:-}"
  local name="${3:-destructive}"
  if [[ -z "$pid" || -z "$output" ]] || ! command -v jcmd >/dev/null 2>&1; then
    return 1
  fi
  jcmd "$pid" JFR.start name="$name" settings=profile filename="$output" dumponexit=true \
    >/dev/null 2>&1
}

destructive_stop_jfr() {
  local pid="${1:-}"
  local name="${2:-destructive}"
  if [[ -z "$pid" ]] || ! command -v jcmd >/dev/null 2>&1; then
    return 1
  fi
  jcmd "$pid" JFR.stop name="$name" >/dev/null 2>&1
}

destructive_force_gc() {
  local pid="${1:-}"
  if [[ -z "$pid" ]] || ! command -v jcmd >/dev/null 2>&1; then
    return 1
  fi
  jcmd "$pid" GC.run >/dev/null 2>&1 || true
  sleep 1
  jcmd "$pid" GC.run >/dev/null 2>&1 || true
}

# Drive clean traffic before the RSS baseline is taken.
#
# WHY: both radamsa and slowloris sampled RSS on a target that had never served
# a request, then charged every byte of first-load growth to the attack. That is
# not a small correction. Measured on the 2026-08-26 slowloris run: RSS grew
# 183.8 -> 248.0 MB (+34.9 %) against a 5 % tolerance, so the run classified
# `leak-suspected` -- while the JFR's own post-GC heap summary put LIVE HEAP at
# 9.5 MB. Whatever those 64 MB were, Java objects retained by the attack was not
# it, and a cold baseline cannot tell the two apart.
#
# A warm-up does not make RSS a good leak signal (the scenario's own
# comparison_axis_note says so for pool-backed targets). It removes one
# confound, and it is the cheap half of the fix; NMT on the target is the other.
#
#   destructive_warmup <base_url> <path> <seconds> [rps]
destructive_warmup() {
  local base_url="${1:?destructive_warmup <base_url> <path> <seconds> [rps]}"
  local path="${2:-/health}"
  local seconds="${3:-30}"
  local rps="${4:-50}"
  local url="${base_url%/}${path}"
  local deadline=$(( $(date +%s) + seconds ))
  local period_us=$(( rps > 0 ? 1000000 / rps : 0 ))
  local n=0
  while [[ $(date +%s) -lt $deadline ]]; do
    curl -sS -o /dev/null --max-time 2 "$url" >/dev/null 2>&1 || true
    n=$((n + 1))
    [[ $period_us -gt 0 ]] && sleep "0.$(printf '%06d' "$period_us")"
  done
  echo "$n"
}

# Sample a process's RSS on an interval, in the background.
#
# WHY: arena-lifecycle-leak defines its FAIL condition as "RSS delta CORRELATES
# WITH ATTACK DURATION", but the runner recorded two points -- before and after
# -- from which no correlation can be computed. Two points fit a leak and a
# plateau equally well, and they are the two hypotheses the scenario exists to
# separate: a leak keeps climbing, first-load growth flattens.
#
# Writes "<unix_ts> <rss_bytes>" per line. Stop with destructive_stop_rss_series.
#
#   destructive_start_rss_series <pid> <outfile> [interval_seconds]
destructive_start_rss_series() {
  local pid="${1:?destructive_start_rss_series <pid> <outfile> [interval]}"
  local outfile="${2:?}"
  local interval="${3:-5}"
  : > "$outfile"
  (
    while [[ -d "/proc/$pid" ]]; do
      local rss
      rss="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')"
      [[ -n "$rss" ]] && echo "$(date +%s) $((rss * 1024))" >> "$outfile"
      sleep "$interval"
    done
  # >/dev/null is load-bearing, not tidiness. Callers use
  #   PID="$(destructive_start_rss_series ...)"
  # and command substitution waits for EVERY writer to the pipe to close --
  # including this background subshell, which inherits stdout. Without the
  # redirect the substitution blocks until the sampler exits, i.e. forever, and
  # the campaign deadlocks before its attack window opens. Observed exactly
  # once, on the first run that used it.
  ) >/dev/null 2>&1 &
  echo $!
}

destructive_stop_rss_series() {
  local sampler_pid="${1:-}"
  [[ -n "$sampler_pid" ]] && kill "$sampler_pid" >/dev/null 2>&1 || true
  wait "$sampler_pid" 2>/dev/null || true
}

# Least-squares slope of the RSS series over its second half, in bytes/second,
# plus the same over the first half. A leak keeps the late slope near the early
# one; first-load growth collapses it toward zero. Echoes
# "<early_slope> <late_slope> <n_samples>" or "unobtained unobtained 0".
destructive_rss_series_slopes() {
  local f="${1:-}"
  if [[ -z "$f" || ! -s "$f" ]]; then
    echo "unobtained unobtained 0"; return 0
  fi
  # LC_ALL=C is load-bearing: awk's %f honours the locale, and on a pl_PL box
  # this printed "200000,0" -- a decimal comma that every downstream jq and
  # shell arithmetic in this repo would reject or silently truncate.
  LC_ALL=C awk '
    { t[NR]=$1; r[NR]=$2 }
    END {
      n=NR
      if (n < 6) { print "unobtained unobtained " n; exit }
      mid=int(n/2)
      printf "%.1f %.1f %d\n", slope(1,mid), slope(mid+1,n), n
    }
    function slope(a,b,   i,st,sr,stt,str,cnt,d) {
      cnt=b-a+1
      for (i=a;i<=b;i++) { st+=t[i]; sr+=r[i] }
      for (i=a;i<=b;i++) { d=t[i]-st/cnt; stt+=d*d; str+=d*(r[i]-sr/cnt) }
      return (stt==0) ? 0 : str/stt
    }' "$f"
}

destructive_liveness_probe() {
  local base_url="${1:?destructive_liveness_probe: base_url required}"
  local path="${2:-/health}"
  local expected_status="${3:-200}"
  local max_response_ms="${4:-1000}"
  # Fifth positional argument: the protocol the probe must speak. This used to be plain curl,
  # i.e. HTTP/1.1, for EVERY campaign -- including destructive-radamsa-h2, whose scenario declares
  # an h2c probe and whose whole point is attacking the HTTP/2 frame parser and HPACK decoder. A
  # mutated-frame attack that broke the h2 path while h1 kept answering would have been recorded
  # as "target survived", which is the one case the scenario exists to catch.
  local protocol="${5:-h1}"
  local url="${base_url%/}${path}"

  DESTR_PROBE_STATUS=""
  DESTR_PROBE_DURATION_MS=""
  DESTR_PROBE_ALIVE="false"
  DESTR_PROBE_HTTP_VERSION=""
  DESTR_PROBE_PROTOCOL="$protocol"

  local curl_proto_args=()
  case "$protocol" in
    h2|h2c) curl_proto_args=(--http2-prior-knowledge) ;;
    h1)     ;;
    *) echo "destructive_liveness_probe: unknown protocol '$protocol'" >&2; return 1 ;;
  esac

  local start_ms end_ms out code version
  start_ms="$(date -u +%s%3N)"
  out="$(curl -sS "${curl_proto_args[@]}" -o /dev/null \
        -w '%{http_code} %{http_version}' --max-time 10 "$url" 2>/dev/null || echo '000 0')"
  end_ms="$(date -u +%s%3N)"
  code="${out%% *}"
  version="${out##* }"

  DESTR_PROBE_STATUS="$code"
  DESTR_PROBE_HTTP_VERSION="$version"
  DESTR_PROBE_DURATION_MS="$((end_ms - start_ms))"

  # An h2c probe that silently answered over HTTP/1.1 has not tested the path under attack.
  if [[ "$protocol" == "h2" || "$protocol" == "h2c" ]] && [[ "$version" != 2* ]]; then
    echo "destructive_liveness_probe: asked for $protocol, target answered HTTP/$version" >&2
    return 1
  fi

  if [[ "$code" == "$expected_status" ]] \
     && (( DESTR_PROBE_DURATION_MS <= max_response_ms )); then
    DESTR_PROBE_ALIVE="true"
    return 0
  fi
  return 1
}

# Compute degradation_class from collected signals.
# Usage:
#   destructive_classify <crash_count> <oom_count> <hang_count> \
#                        <rss_delta_bytes> <rss_growth_pct_max> <rss_before_bytes> \
#                        <probe_alive>
# Echoes one of: graceful-shed | timeout-flood | crash | oom | leak-suspected | stable
destructive_classify() {
  local crash="${1:-0}"
  local oom="${2:-0}"
  local hang="${3:-0}"
  local rss_delta="${4:-0}"
  local rss_growth_pct_max="${5:-5}"
  local rss_before="${6:-1}"
  local probe_alive="${7:-true}"

  if (( oom > 0 )); then
    echo "oom"; return 0
  fi
  if (( crash > 0 )); then
    echo "crash"; return 0
  fi
  if [[ "$probe_alive" != "true" ]]; then
    echo "timeout-flood"; return 0
  fi
  if (( hang > 0 )); then
    echo "graceful-shed"; return 0
  fi
  if (( rss_before > 0 )); then
    local growth_pct=$((rss_delta * 100 / rss_before))
    if (( growth_pct > rss_growth_pct_max )); then
      echo "leak-suspected"; return 0
    fi
  fi
  echo "stable"
}

# destructive_emit_json <outfile> -- read a JSON document on stdin, validate it,
# and only then place it at <outfile>.
#
# The `jq ... > "$FILE"` form truncates the target BEFORE jq runs, so a jq that
# fails leaves a 0-byte file that still looks like an artifact. That happened on
# 2026-08-26: the first destructive-radamsa-h2 campaign fired all 60 000 mutants,
# then died on two undeclared jq variables and wrote an empty
# destructive-findings.json. The attack data was recoverable only from the raw
# attacker stdout. Staging through a temp file makes a broken emitter leave the
# previous state instead of a plausible-looking empty one.
destructive_emit_json() {
  local outfile="$1"
  local tmp="${outfile}.tmp.$$"
  cat > "$tmp"
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    echo "ERROR: refusing to write empty JSON to $outfile" >&2
    return 1
  fi
  if ! jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
    echo "ERROR: emitted JSON for $outfile is not a valid object; kept at $tmp" >&2
    return 1
  fi
  mv "$tmp" "$outfile"
}

# destructive_resolve_target_pid <pid> <port> -- verify <pid> is the process that
# actually serves <port>, correcting to a descendant when it is not.
#
# Echoes the pid to sample. Returns non-zero if no defensible pid exists.
#
# WHY: --target-pid is taken on trust, and every resource_delta plus the
# degradation_class resting on it is only as good as that pid. On 2026-08-27 the
# destructive-radamsa-h2 campaign was pointed at /tmp/h2c.pid, which held the
# `bash -c "... java ..."` wrapper rather than the JVM it spawned. The artifact
# recorded rss_bytes_before == rss_bytes_after == 2 170 880 -- 2.07 MB, a shell --
# and classified the run `stable` on a delta of exactly zero. A leak scenario
# aimed at a wrapper cannot fail: it measures a process that allocates nothing.
# A sampled pid must be the one holding the listening socket.
destructive_resolve_target_pid() {
  local pid="$1" port="$2"
  if [[ -z "$pid" || ! -d "/proc/$pid" ]]; then
    echo "ERROR: --target-pid '$pid' is not a live process" >&2
    return 1
  fi
  local listener
  listener=$(ss -lntpH "sport = :$port" 2>/dev/null \
    | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
  if [[ -z "$listener" ]]; then
    echo "WARN: no listener found on port $port; sampling --target-pid $pid unverified" >&2
    echo "$pid"
    return 0
  fi
  if [[ "$listener" == "$pid" ]]; then
    echo "$pid"
    return 0
  fi
  # Walk up from the listener: a wrapper shell is a legitimate launch shape,
  # so correct to the real server rather than refusing the run.
  local cur="$listener"
  while [[ -n "$cur" && "$cur" != "1" ]]; do
    if [[ "$cur" == "$pid" ]]; then
      echo "WARN: --target-pid $pid is an ancestor of the process serving :$port." >&2
      echo "WARN: sampling $listener instead ($(cat "/proc/$listener/comm" 2>/dev/null))." >&2
      echo "$listener"
      return 0
    fi
    cur=$(awk '{print $4}' "/proc/$cur/stat" 2>/dev/null)
  done
  echo "ERROR: --target-pid $pid does not serve :$port (pid $listener does), and is not its ancestor." >&2
  return 1
}

# destructive_validate_findings <findings_file> [schema_file] -- fail the run if
# the emitted artifact does not conform to destructive-findings.schema.json.
#
# The schema is what enforces this repo's traceability invariant, and until
# 2026-08-27 none of the destructive runners checked their output against it --
# they were the only artifact-producing runners that did not. The `additionalProperties: false`
# discipline means a field added to a runner but not to the schema (or vice
# versa) is exactly the kind of silent drift the schema exists to catch, and it
# can only catch it if something runs it.
#
# Resolution order matches scripts/run-entity-read-by-id.sh: check-jsonschema,
# then ajv, then python3+jsonschema. Absence of all three is a hard failure, not
# a skip -- a validation that quietly does not run is worse than none.
destructive_validate_findings() {
  local findings="$1"
  local schema="${2:-$ROOT/schemas/destructive-findings.schema.json}"
  if [[ ! -f "$findings" ]]; then
    echo "ERROR: findings artifact '$findings' does not exist" >&2
    return 1
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    check-jsonschema --schemafile "$schema" "$findings" || return 1
  elif command -v ajv >/dev/null 2>&1; then
    ajv validate -s "$schema" -d "$findings" || return 1
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$schema" "$findings" <<'PY' || return 1
import json, sys
try:
    import jsonschema
except Exception:
    print("ERROR: python3 fallback needs the 'jsonschema' module "
          "(python3 -m pip install jsonschema)", file=sys.stderr)
    sys.exit(2)
schema = json.load(open(sys.argv[1], encoding="utf-8"))
data = json.load(open(sys.argv[2], encoding="utf-8"))
try:
    jsonschema.validate(instance=data, schema=schema)
except jsonschema.exceptions.ValidationError as e:
    where = ".".join(str(p) for p in e.path) if e.path else "$"
    print(f"ERROR: schema validation failed at {where}: {e.message}",
          file=sys.stderr)
    sys.exit(1)
PY
  else
    echo "ERROR: no JSON Schema validator available (check-jsonschema, ajv, or python3+jsonschema)" >&2
    return 1
  fi
  echo "  schema validation PASSED ($(basename "$schema"))"
}
