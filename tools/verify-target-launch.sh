#!/usr/bin/env bash
# Assert that the process actually serving a benchmark target is the artifact we intended.
#
# WHY THIS EXISTS
# The serialisation matrix's four arms (exeris-k0101, exeris-k0101-bb, exeris-k0102,
# exeris-k0102-bb) are all built from ONE Maven module. They are kept apart by two mechanisms:
# a version-pinned build staged to targets/_staging/exeris-community-app-k<version>.jar, and a
# customizer uber-jar added to the launch classpath. If either mechanism regresses, every arm
# launches the same runtime, the campaign completes cleanly, all gates pass, and it reports four
# different numbers for one binary. Nothing anywhere raises an error. This script converts that
# silent failure into a loud one.
#
# It is also the right pre-flight for the two-exeris-instance debug verification, where the risk
# is the mirror image: the customizer arm silently starting WITHOUT the customizer, so a "Blackbird
# vs default" comparison is really "default vs default" and honestly reports no difference.
#
# Usage: tools/verify-target-launch.sh <target_id> <port> [log_file]
# Exit 0 = the running process matches the matrix; non-zero = it does not.

set -uo pipefail

TARGET_ID="${1:-}"
PORT="${2:-}"
LOG_FILE="${3:-}"

if [[ -z "$TARGET_ID" || -z "$PORT" ]]; then
  echo "usage: $0 <target_id> <port> [log_file]" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MATRIX="${REPO_ROOT}/runtime/drivers/target-asset-matrix.json"
issues=0

fail() { echo "FAIL[$TARGET_ID]: $*" >&2; issues=$((issues + 1)); }
pass() { echo "PASS[$TARGET_ID]: $*"; }

if [[ ! -f "$MATRIX" ]]; then
  echo "FATAL: target-asset-matrix.json not found at $MATRIX" >&2
  exit 2
fi

expected_jar="$(jq -r --arg id "$TARGET_ID" \
  '.targets[] | select(.target_id == $id) | .jar_path // ""' "$MATRIX" 2>/dev/null)"

# --- locate the process actually listening on the port -----------------------------------------
pid="$(ss -ltnp 2>/dev/null | grep -oE "[:.]${PORT}\b.*pid=[0-9]+" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
if [[ -z "$pid" ]]; then
  fail "no process is listening on port ${PORT}"
  echo "verify-target-launch: ${issues} issue(s)" >&2
  exit 1
fi
pass "process pid=${pid} is listening on port ${PORT}"

cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null)"
if [[ -z "$cmdline" ]]; then
  fail "cannot read /proc/${pid}/cmdline"
  echo "verify-target-launch: ${issues} issue(s)" >&2
  exit 1
fi

# --- the artifact identity check ---------------------------------------------------------------
# An empty jar_path means the matrix does not pin an artifact for this target (true of every
# pre-existing target). Skip rather than invent a requirement — but say so, because a silent skip
# is exactly the failure mode this script exists to prevent.
if [[ -z "$expected_jar" ]]; then
  echo "SKIP[$TARGET_ID]: matrix declares no jar_path; artifact identity NOT asserted"
else
  if [[ "$cmdline" == *"$expected_jar"* ]]; then
    pass "running artifact matches matrix jar_path: ${expected_jar}"
  else
    fail "artifact MISMATCH — matrix expects '${expected_jar}' but the live process runs:"
    echo "       $(echo "$cmdline" | grep -oE '(\-jar|\-cp) [^ ]+' | head -2)" >&2
  fi
fi

# --- customizer arms must prove the customizer actually applied --------------------------------
if [[ "$TARGET_ID" == *-bb || "$TARGET_ID" == *blackbird* ]]; then
  if [[ "$cmdline" == *blackbird-customizer* ]]; then
    pass "blackbird customizer jar is on the launch classpath"
  else
    fail "customizer arm launched WITHOUT the blackbird customizer on its classpath"
  fi

  # Classpath presence is necessary but not sufficient: ServiceLoader could still fail to bind
  # (e.g. a customizer compiled against a different seam). The bootstrap breadcrumb is the only
  # proof the module was actually applied to a JSON scope.
  if [[ -n "$LOG_FILE" ]]; then
    if [[ ! -f "$LOG_FILE" ]]; then
      fail "log file not found, cannot confirm the Blackbird bootstrap breadcrumb: ${LOG_FILE}"
    elif grep -q 'exeris-blackbird.*BlackbirdModule' "$LOG_FILE" 2>/dev/null; then
      pass "bootstrap breadcrumb present — BlackbirdModule was applied"
    else
      fail "no Blackbird bootstrap breadcrumb in ${LOG_FILE}: the arm is a SILENT NO-OP and its numbers are meaningless"
    fi
  else
    echo "SKIP[$TARGET_ID]: no log file given; breadcrumb NOT asserted (pass one to make this arm verifiable)"
  fi
fi

if (( issues > 0 )); then
  echo "verify-target-launch: ${issues} issue(s) for ${TARGET_ID}" >&2
  exit 1
fi
echo "verify-target-launch: ${TARGET_ID} OK"
