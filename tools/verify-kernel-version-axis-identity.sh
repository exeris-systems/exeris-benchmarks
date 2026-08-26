#!/usr/bin/env bash
# Assert that the process currently serving a kernel-version-axis arm is the configuration that arm
# claims to be.
#
# WHY THIS EXISTS
# tools/verify-target-launch.sh answers "is this the right jar?". That question is not sufficient
# here. Four of the eight arms on this axis run the SAME staged jar and are separated only by which
# JDK launched it and whether --enable-preview is on:
#
#   exeris-k0110-j26   k0.11.0-r25.jar   JDK 26   no flag
#   exeris-k0110-j25   k0.11.0-r25.jar   JDK 25   no flag
#   exeris-k0110-j28   k0.11.0-r25.jar   JDK 28   no flag
#   exeris-k0110-j28f  k0.11.0-r25.jar   JDK 28   --enable-preview
#
# If the launcher resolved the wrong JAVA_HOME, all four would run one JVM, the campaign would
# complete, every gate would pass, and the axis would report a JDK effect that does not exist.
# Nothing else in the harness would raise an error. This converts that silent failure into a loud
# one, by re-deriving the (jar, JDK, flag) triple from /proc rather than from configuration.
#
# Usage: tools/verify-kernel-version-axis-identity.sh <target_id> <port>
# Exit 0 = the live process matches the manifest; non-zero = it does not.

set -uo pipefail

TARGET_ID="${1:-}"
PORT="${2:-}"

if [[ -z "$TARGET_ID" || -z "$PORT" ]]; then
  echo "usage: $0 <target_id> <port>" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${REPO_ROOT}/runtime/drivers/kernel-version-axis-arms.json"
issues=0

fail() { echo "FAIL[$TARGET_ID]: $*" >&2; issues=$((issues + 1)); }
pass() { echo "PASS[$TARGET_ID]: $*"; }

[[ -f "$MANIFEST" ]] || { echo "FATAL: manifest not found at $MANIFEST" >&2; exit 2; }

read -r ARM WANT_JAR WANT_JDK WANT_PREVIEW WANT_PORT WANT_GROUP WANT_VERSION < <(
  python3 - "$MANIFEST" "$TARGET_ID" <<'PY'
import json, sys
for a in json.load(open(sys.argv[1]))["arms"]:
    if a["target_id"] == sys.argv[2]:
        print(a["arm"], a["staged_jar"], a["jdk_feature"],
              "yes" if a["enable_preview_flag"] else "no",
              a["port"], a["kernel_group_id"], a["kernel_version"])
        sys.exit(0)
sys.exit(1)
PY
) || { echo "FATAL: '$TARGET_ID' is not an arm of the kernel-version axis" >&2; exit 2; }

if [[ "$PORT" != "$WANT_PORT" ]]; then
  fail "asked about port ${PORT}, but arm ${ARM} is declared on port ${WANT_PORT}"
fi

# Find the PID actually listening on the port, rather than trusting a pid file: a stale pid file
# pointing at a dead process, with a different arm still bound to the port, is precisely the
# mix-up this check has to catch.
PID=""
if command -v ss >/dev/null 2>&1; then
  PID="$(ss -lptnH "sport = :${PORT}" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
fi
if [[ -z "$PID" ]] && command -v lsof >/dev/null 2>&1; then
  PID="$(lsof -tiTCP:"${PORT}" -sTCP:LISTEN 2>/dev/null | head -1)"
fi
if [[ -z "$PID" ]]; then
  echo "FATAL: nothing is listening on port ${PORT}; cannot verify arm ${ARM}" >&2
  exit 2
fi

CMDLINE="$(tr '\0' ' ' < "/proc/${PID}/cmdline" 2>/dev/null)"
EXE="$(readlink -f "/proc/${PID}/exe" 2>/dev/null)"

if [[ -z "$CMDLINE" || -z "$EXE" ]]; then
  echo "FATAL: cannot read /proc/${PID}; run as the user that owns the target process" >&2
  exit 2
fi

echo "arm ${ARM} (${WANT_GROUP}:${WANT_VERSION}) pid=${PID} port=${PORT}"

# 1. staged jar
if [[ "$CMDLINE" == *"$WANT_JAR"* ]]; then
  pass "staged jar is ${WANT_JAR}"
else
  fail "expected staged jar ${WANT_JAR}; running: ${CMDLINE}"
fi

# 2. preview flag
HAS_PREVIEW="no"
[[ "$CMDLINE" == *"--enable-preview"* ]] && HAS_PREVIEW="yes"
if [[ "$HAS_PREVIEW" == "$WANT_PREVIEW" ]]; then
  pass "preview flag = ${HAS_PREVIEW}, as declared"
else
  fail "preview flag is ${HAS_PREVIEW}, arm declares ${WANT_PREVIEW}"
fi

# 3. JDK feature release of the JVM that is actually running, read from the live binary
ACTUAL_JDK="$("$EXE" -version 2>&1 | head -1 | grep -oE '"[0-9]+' | tr -d '"')"
if [[ "$ACTUAL_JDK" == "$WANT_JDK" ]]; then
  pass "JDK feature release ${ACTUAL_JDK} (${EXE})"
else
  fail "running JDK ${ACTUAL_JDK:-unknown} at ${EXE}, arm declares JDK ${WANT_JDK}"
fi

if [[ $issues -gt 0 ]]; then
  echo "IDENTITY MISMATCH: the process on :${PORT} is not arm ${ARM}. Any measurement taken from it" >&2
  echo "would be attributed to the wrong kernel line, JDK, or feature set." >&2
  exit 1
fi

echo "IDENTITY OK: arm ${ARM} is exactly (${WANT_JAR##*/}, JDK ${WANT_JDK}, preview=${WANT_PREVIEW})"
