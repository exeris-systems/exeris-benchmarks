#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Root of the exeris-kernel product mono-repo.
# Override with EXERIS_KERNEL_ROOT if not located 3 levels above runtime/drivers/.
ROOT_DIR="${EXERIS_KERNEL_ROOT:-$(cd -- "$SCRIPT_DIR/../../.." && pwd)}"

MODE="http"
HOST="127.0.0.1"
PORT="18080"
JDBC_URL=""
JDBC_USER=""
JDBC_PASSWORD=""

usage() {
  cat <<'EOF'
Usage:
  community-stack-launcher.sh [--mode http|h2|postgres] [--host 127.0.0.1] [--port 18080]
              [--jdbc-url <url>] [--jdbc-user <user>] [--jdbc-password <password>]

Environment:
  EXERIS_KERNEL_ROOT   Path to the exeris-kernel mono-repo root (default: 3 levels up)

Modes:
  http     -> HTTP only (/health=200, /db/ping=503)
  h2       -> HTTP + persistence on in-memory H2 (/db/ping=200)
  postgres -> HTTP + persistence on PostgreSQL (requires running DB)
EOF
}

fail() {
  echo "[launcher] ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

filter_stale_exeris_jars() {
  local classpath="$1"
  local filtered=""
  IFS=':' read -r -a parts <<< "$classpath"
  for entry in "${parts[@]}"; do
    [[ -z "$entry" ]] && continue
    if [[ "$entry" =~ /\.m2/.*/eu/exeris/exeris-kernel-(spi|core|community)/ ]]; then
      continue
    fi
    filtered="${filtered:+$filtered:}$entry"
  done
  printf '%s' "$filtered"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)        MODE="${2:-}"; shift 2 ;;
    --host)        HOST="${2:-}"; shift 2 ;;
    --port)        PORT="${2:-}"; shift 2 ;;
    --jdbc-url)    JDBC_URL="${2:-}"; shift 2 ;;
    --jdbc-user)   JDBC_USER="${2:-}"; shift 2 ;;
    --jdbc-password) JDBC_PASSWORD="${2:-}"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)             fail "Unknown argument: $1" ;;
  esac
done

[[ "$MODE" =~ ^(http|h2|postgres)$ ]] || fail "Unsupported mode: $MODE"

require_cmd java
require_cmd mvn

TARGET_LOG_DIR="${TARGET_LOG_DIR:-/tmp/exeris-bench-logs}"
mkdir -p "$TARGET_LOG_DIR"
RUN_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

CP_FILE="$ROOT_DIR/exeris-kernel-community/target/community-e2e.classpath"

pushd "$ROOT_DIR" >/dev/null
mvn -q -pl exeris-kernel-community -am -DskipTests -DskipITs compile \
  dependency:build-classpath -DincludeScope=test "-Dmdep.outputFile=$CP_FILE"
popd >/dev/null

[[ -f "$CP_FILE" ]] || fail "Failed to build classpath file: $CP_FILE"

DEPENDENCY_CP="$(filter_stale_exeris_jars "$(cat "$CP_FILE")")"
CLASSPATH="$ROOT_DIR/exeris-kernel-spi/target/classes:$ROOT_DIR/exeris-kernel-core/target/classes:$ROOT_DIR/exeris-kernel-community/target/classes:$DEPENDENCY_CP"

JAVA_ARGS=(
  --enable-preview
  --enable-native-access=ALL-UNNAMED
  "-Dexeris.http.mode=SERVER"
  "-Dexeris.http.bindHost=$HOST"
  "-Dexeris.http.port=$PORT"
  "-Xlog:gc*,safepoint:file=${TARGET_LOG_DIR}/gc-${RUN_TIMESTAMP}.log:time,uptime,level,tags"
  "-Xlog:safepoint:file=${TARGET_LOG_DIR}/safepoint-${RUN_TIMESTAMP}.log:time,uptime,level,tags"
  "-XX:StartFlightRecording=filename=${TARGET_LOG_DIR}/jfr-${RUN_TIMESTAMP}.jfr,settings=profile,duration=0,maxsize=256m,dumponexit=true"
)

# JFR ring-buffer NOTE: dumponexit=true retains only the last 256m of events.
# Early-phase GC events may be evicted. For early-phase analysis, use maxchunksize=64m.
# See docs/methodology.md: "JFR ring-buffer early-phase loss"
# GC log path uses /tmp (local fs) to avoid I/O overhead on network-backed CI filesystems.

case "$MODE" in
  http) ;;
  h2)
    JDBC_URL="${JDBC_URL:-jdbc:h2:mem:exeris;MODE=PostgreSQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}"
    JDBC_USER="${JDBC_USER:-sa}"; JDBC_PASSWORD="${JDBC_PASSWORD:-sa}"
    JAVA_ARGS+=("-Dexeris.launcher.subsystems=http,persistence"
                "-Dexeris.persistence.jdbcUrl=$JDBC_URL"
                "-Dexeris.persistence.username=$JDBC_USER"
                "-Dexeris.persistence.password=$JDBC_PASSWORD")
    ;;
  postgres)
    JDBC_URL="${JDBC_URL:-jdbc:postgresql://127.0.0.1:5432/exeris}"
    JDBC_USER="${JDBC_USER:-exeris}"; JDBC_PASSWORD="${JDBC_PASSWORD:-exeris}"
    JAVA_ARGS+=("-Dexeris.launcher.subsystems=http,persistence"
                "-Dexeris.persistence.jdbcUrl=$JDBC_URL"
                "-Dexeris.persistence.username=$JDBC_USER"
                "-Dexeris.persistence.password=$JDBC_PASSWORD")
    ;;
esac

echo "[launcher] mode=$MODE host=$HOST port=$PORT"
[[ -n "$JDBC_URL" ]] && echo "[launcher] jdbcUrl=$JDBC_URL"
echo "[launcher] GC logs: $TARGET_LOG_DIR/gc-${RUN_TIMESTAMP}.log"

exec java "${JAVA_ARGS[@]}" -cp "$CLASSPATH" eu.exeris.kernel.launcher.CommunityStackLauncher
