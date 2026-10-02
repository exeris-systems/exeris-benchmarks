#!/usr/bin/env bash
# Compiles the loom-scheduler benchmark target against an explicitly supplied kernel classpath.
#
# Required environment:
#   JAVA_HOME   the JDK to compile with (the Loom EA build the kernel was compiled with)
#   KERNEL_CP   classpath of the kernel under test: the spi/core/community classes directories
#               built from one kernel commit, plus their third-party dependency jars
# Optional environment:
#   APP_TARGET_DIR  output directory (default: <this dir>/target)
#
# Output:
#   $APP_TARGET_DIR/classes            compiled application classes
#   $APP_TARGET_DIR/app-classpath.txt  $APP_TARGET_DIR/classes:$KERNEL_CP, absolute paths
#
# The kernel classpath is never discovered here: a classpath assembled from whatever happens to be
# in a local Maven repository cannot be tied to the kernel commit a measurement claims to measure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() {
    echo "build.sh: $*" >&2
    exit 1
}

[[ -n "${JAVA_HOME:-}" ]] || die "JAVA_HOME is not set"
[[ -x "${JAVA_HOME}/bin/javac" ]] || die "no javac at ${JAVA_HOME}/bin/javac"
[[ -n "${KERNEL_CP:-}" ]] || die "KERNEL_CP is not set; pass the kernel classes + dependency jars of the commit under test"

# Every classpath entry must exist and be absolute, or the app would compile against one kernel
# and run against another (or against nothing).
IFS=':' read -r -a cp_entries <<< "${KERNEL_CP}"
for entry in "${cp_entries[@]}"; do
    [[ -n "${entry}" ]] || die "KERNEL_CP contains an empty entry"
    [[ "${entry}" == /* ]] || die "KERNEL_CP entry is not absolute: ${entry}"
    [[ -e "${entry}" ]] || die "KERNEL_CP entry does not exist: ${entry}"
done

TARGET_DIR="${APP_TARGET_DIR:-${SCRIPT_DIR}/target}"
mkdir -p "${TARGET_DIR}"
TARGET_DIR="$(cd "${TARGET_DIR}" && pwd)"
CLASSES_DIR="${TARGET_DIR}/classes"
SRC_DIR="${SCRIPT_DIR}/src/main/java"

rm -rf "${CLASSES_DIR}"
mkdir -p "${CLASSES_DIR}"

mapfile -t sources < <(find "${SRC_DIR}" -name '*.java' | sort)
(( ${#sources[@]} > 0 )) || die "no sources under ${SRC_DIR}"

echo "build.sh: javac $("${JAVA_HOME}/bin/javac" -version 2>&1), ${#sources[@]} sources -> ${CLASSES_DIR}"
"${JAVA_HOME}/bin/javac" \
    --release 28 \
    -Xlint:all,-processing \
    -cp "${KERNEL_CP}" \
    -d "${CLASSES_DIR}" \
    "${sources[@]}"

printf '%s:%s\n' "${CLASSES_DIR}" "${KERNEL_CP}" > "${TARGET_DIR}/app-classpath.txt"
echo "build.sh: wrote ${TARGET_DIR}/app-classpath.txt"
