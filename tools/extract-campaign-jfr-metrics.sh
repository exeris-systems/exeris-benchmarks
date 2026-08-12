#!/usr/bin/env bash
# extract-campaign-jfr-metrics.sh
# Batch-extract JFR resource metrics for every recording under a campaign tree.
#
# Each recording's measurement window is taken from the pg_stat_statements
# baseline/final snapshots the comparative runner writes beside it, so the
# metrics describe the measured load instead of the whole process lifetime.
# That distinction is not cosmetic: on a sample entity-read-by-id leaf the
# unwindowed maxima overstated CPU by ~49 % and GC pause max by ~74 %, because
# they swept up JIT/warmup activity that no published number should include.
#
# Recordings with no such pair — the diagnostics/ captures — are extracted
# unwindowed and keep the extractor's own "whole recording" warning, so an
# unwindowed row is always identifiable as such downstream.
#
# Output: <recording>.jfr-metrics.json beside each recording. Deliberately NOT
# resource-metrics.json, which the runner already writes from /usr/bin/time and
# result.json references.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EXTRACTOR="${SCRIPT_DIR}/extract-jfr-metrics.sh"
# Absolute, because the worker is re-invoked through xargs.
SELF="${SCRIPT_DIR}/$(basename -- "${BASH_SOURCE[0]}")"

fail() { echo "ERROR: $*" >&2; exit 1; }
log()  { echo "[extract-campaign] $*" >&2; }

# --- worker mode: one recording, invoked via xargs ---------------------------
if [[ "${1:-}" == "--worker" ]]; then
  jfr="${2:?--worker needs a jfr path}"
  force="${3:-0}"
  out="${jfr}.jfr-metrics.json"
  dir="$(dirname -- "${jfr}")"

  if [[ "${force}" != "1" && -f "${out}" ]] && jq -e . "${out}" >/dev/null 2>&1; then
    echo "SKIP ${jfr}"
    exit 0
  fi

  base="${dir}/pg_stat_statements-measurement-baseline.json"
  final="${dir}/pg_stat_statements-measurement-final.json"
  args=()
  window="none"
  if [[ -f "${base}" && -f "${final}" ]]; then
    ws="$(jq -r '.timestamp // empty' "${base}" 2>/dev/null || true)"
    we="$(jq -r '.timestamp // empty' "${final}" 2>/dev/null || true)"
    if [[ -n "${ws}" && -n "${we}" ]]; then
      args=(--window-start "${ws}" --window-end "${we}")
      window="${ws}..${we}"
    fi
  fi

  tmp="${out}.tmp.$$"
  if "${EXTRACTOR}" "${args[@]+"${args[@]}"}" "${jfr}" > "${tmp}" 2>"${tmp}.err"; then
    mv -- "${tmp}" "${out}"
    rm -f -- "${tmp}.err"
    echo "OK ${jfr} window=${window}"
  else
    rm -f -- "${tmp}"
    echo "FAIL ${jfr} :: $(tail -n 2 "${tmp}.err" 2>/dev/null | tr '\n' ' ')"
    rm -f -- "${tmp}.err"
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
    -h|--help)
      echo "Usage: $0 <campaign-dir> [--jobs N] [--force]" >&2; exit 2 ;;
    -*) fail "unknown option: $1" ;;
    *)  [[ -z "${CAMPAIGN_DIR}" ]] || fail "unexpected argument: $1"; CAMPAIGN_DIR="$1"; shift ;;
  esac
done

[[ -n "${CAMPAIGN_DIR}" ]] || fail "usage: $0 <campaign-dir> [--jobs N] [--force]"
[[ -d "${CAMPAIGN_DIR}" ]] || fail "not a directory: ${CAMPAIGN_DIR}"
[[ -x "${EXTRACTOR}" ]]    || fail "extractor not executable: ${EXTRACTOR}"
[[ "${JOBS}" =~ ^[0-9]+$ && "${JOBS}" -ge 1 ]] || fail "--jobs must be a positive integer"
command -v jq >/dev/null 2>&1 || fail "jq is required"

mapfile -t RECORDINGS < <(find "${CAMPAIGN_DIR}" -type f -name '*.jfr' | sort)
[[ "${#RECORDINGS[@]}" -gt 0 ]] || fail "no .jfr recordings under ${CAMPAIGN_DIR}"

log "recordings : ${#RECORDINGS[@]}"
log "jobs       : ${JOBS}"
log "force      : ${FORCE}"

RESULT_LOG="$(mktemp)"
trap 'rm -f "${RESULT_LOG}"' EXIT

set +e
printf '%s\0' "${RECORDINGS[@]}" \
  | xargs -0 -P "${JOBS}" -I{} "${SELF}" --worker {} "${FORCE}" \
  | tee "${RESULT_LOG}"
set -e

ok=$(grep -c '^OK '   "${RESULT_LOG}" || true)
skip=$(grep -c '^SKIP' "${RESULT_LOG}" || true)
bad=$(grep -c '^FAIL' "${RESULT_LOG}" || true)

echo
log "extracted=${ok} skipped=${skip} failed=${bad} of ${#RECORDINGS[@]}"

# Window coverage is reported explicitly: an unwindowed recording is a weaker
# artefact, not an equivalent one, and the count must be visible rather than
# inferred from reading individual files.
unwindowed=$(grep '^OK ' "${RESULT_LOG}" | grep -c 'window=none' || true)
[[ "${unwindowed}" -gt 0 ]] && log "NOTE: ${unwindowed} recording(s) extracted WITHOUT a measurement window (maxima include warmup)"

if [[ "${bad}" -gt 0 ]]; then
  log "failures:"
  grep '^FAIL' "${RESULT_LOG}" >&2
  exit 1
fi
exit 0
