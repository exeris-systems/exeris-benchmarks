#!/usr/bin/env bash
# generate-campaign-flamegraphs.sh
# Render a windowed CPU flame graph for every recording under a campaign tree.
#
# The flame graph is the artefact that OUTLIVES the recording. A .jfr in this
# lab is hundreds of gigabytes per campaign and gets reclaimed; the derived SVG
# is ~300 KB, is publishable (derived, not raw), and is the only surviving form
# of the CPU profile. So generate the full set BEFORE reclaiming any disk —
# partial coverage silently discards the profile for every leaf it skipped.
#
# Each recording's window comes from the pg_stat_statements measurement
# baseline/final snapshots beside it, per target rather than per leaf: in an A/B
# run the two targets are measured sequentially and their windows differ.
# Unwindowed graphs would fold warmup (JIT, class loading) into the profile.
#
# Confidentiality: Community/OSS targets only, per tools/jfr-flamegraph.py.
# Do not run this over Enterprise (H3/locality) recordings for public artefacts.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RENDERER="${SCRIPT_DIR}/jfr-flamegraph.py"
SELF="${SCRIPT_DIR}/$(basename -- "${BASH_SOURCE[0]}")"

fail() { echo "ERROR: $*" >&2; exit 1; }
log()  { echo "[flamegraphs] $*" >&2; }

# --- worker mode -------------------------------------------------------------
if [[ "${1:-}" == "--worker" ]]; then
  jfr="${2:?--worker needs a jfr path}"
  outdir="${3:?--worker needs an output dir}"
  force="${4:-0}"
  dir="$(dirname -- "${jfr}")"

  # Name the SVG for its position in the campaign, not just the target: the same
  # target appears in several pairs and directions, and a bare target name would
  # collide and silently overwrite.
  rel="${jfr#*/20*/}"
  slug="$(printf '%s' "${rel%/*}" | tr '/' '-' | sed -E 's/-run[0-9]+//; s/[^A-Za-z0-9._-]/-/g')"
  base="$(basename -- "${jfr}" .jfr | sed -E 's/^target-//; s/-[0-9]{8}-[0-9]{6}$//')"
  out="${outdir}/${slug}-${base}.svg"

  if [[ "${force}" != "1" && -s "${out}" ]]; then
    echo "SKIP ${out}"
    exit 0
  fi

  args=()
  window="none"
  bl="${dir}/pg_stat_statements-measurement-baseline.json"
  fn="${dir}/pg_stat_statements-measurement-final.json"
  if [[ -f "${bl}" && -f "${fn}" ]]; then
    ws="$(jq -r '.timestamp // empty' "${bl}" 2>/dev/null || true)"
    we="$(jq -r '.timestamp // empty' "${fn}" 2>/dev/null || true)"
    if [[ -n "${ws}" && -n "${we}" ]]; then
      args=(--window-start "${ws}" --window-end "${we}")
      window="windowed"
    fi
  fi

  if python3 "${RENDERER}" "${jfr}" "${out}" \
       --title "${base} · ${slug}" "${args[@]+"${args[@]}"}" >/dev/null 2>"${out}.err"; then
    rm -f -- "${out}.err"
    echo "OK ${out} ${window}"
  else
    echo "FAIL ${jfr} :: $(tail -n 1 "${out}.err" 2>/dev/null)"
    rm -f -- "${out}.err"
    exit 1
  fi
  exit 0
fi

# --- driver mode -------------------------------------------------------------
CAMPAIGN_DIR=""
JOBS=4
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs)  [[ $# -ge 2 ]] || fail "--jobs needs a value"; JOBS="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) echo "Usage: $0 <campaign-dir> [--jobs N] [--force]" >&2; exit 2 ;;
    -*) fail "unknown option: $1" ;;
    *)  [[ -z "${CAMPAIGN_DIR}" ]] || fail "unexpected argument: $1"; CAMPAIGN_DIR="$1"; shift ;;
  esac
done

[[ -n "${CAMPAIGN_DIR}" ]] || fail "usage: $0 <campaign-dir> [--jobs N] [--force]"
[[ -d "${CAMPAIGN_DIR}" ]] || fail "not a directory: ${CAMPAIGN_DIR}"
[[ -f "${RENDERER}" ]]     || fail "renderer not found: ${RENDERER}"
[[ "${JOBS}" =~ ^[0-9]+$ && "${JOBS}" -ge 1 ]] || fail "--jobs must be a positive integer"
command -v jq >/dev/null 2>&1 || fail "jq is required"

OUTDIR="${CAMPAIGN_DIR%/}/flamegraphs"
mkdir -p "${OUTDIR}"

mapfile -t RECORDINGS < <(find "${CAMPAIGN_DIR}" -type f -name '*.jfr' | sort)
[[ "${#RECORDINGS[@]}" -gt 0 ]] || fail "no .jfr recordings under ${CAMPAIGN_DIR}"

log "recordings : ${#RECORDINGS[@]}"
log "output     : ${OUTDIR}"
log "jobs       : ${JOBS}"

RESULT_LOG="$(mktemp)"
trap 'rm -f "${RESULT_LOG}"' EXIT

set +e
printf '%s\0' "${RECORDINGS[@]}" \
  | xargs -0 -P "${JOBS}" -I{} "${SELF}" --worker {} "${OUTDIR}" "${FORCE}" \
  | tee "${RESULT_LOG}"
set -e

ok=$(grep -c '^OK '   "${RESULT_LOG}" || true)
skip=$(grep -c '^SKIP' "${RESULT_LOG}" || true)
bad=$(grep -c '^FAIL' "${RESULT_LOG}" || true)
unwindowed=$(grep '^OK ' "${RESULT_LOG}" | grep -c 'none$' || true)

echo
log "rendered=${ok} skipped=${skip} failed=${bad} of ${#RECORDINGS[@]}"
[[ "${unwindowed}" -gt 0 ]] && log "NOTE: ${unwindowed} graph(s) rendered WITHOUT a measurement window (profile includes warmup)"

# Coverage is stated rather than implied. A recording with no surviving graph
# has no surviving CPU profile once the .jfr is reclaimed, so the gap must be
# visible here and not discovered afterwards.
if [[ "${bad}" -gt 0 ]]; then
  log "recordings with NO flame graph — do not reclaim these until resolved:"
  grep '^FAIL' "${RESULT_LOG}" >&2
  exit 1
fi
exit 0
