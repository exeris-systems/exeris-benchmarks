#!/usr/bin/env bash
# ==============================================================================
# targets/exeris-h1-locality-app/build.sh
#
# Compiles H1LocalityApplication using the Loom JDK compiler.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

JDK_HOME="${WORKSPACE_ROOT}/tools/jdk-loom/current"
JAVAC="${JDK_HOME}/bin/javac"
JAR="${JDK_HOME}/bin/jar"

SRC_DIR="${SCRIPT_DIR}/src/main/java"
TARGET_DIR="${SCRIPT_DIR}/target"
CLASSES_DIR="${TARGET_DIR}/classes"
OUTPUT_JAR="${TARGET_DIR}/exeris-h1-locality-app.jar"

CORE_CLASSES="${WORKSPACE_ROOT}/exeris-kernel/exeris-kernel-core/target/classes"
SPI_CLASSES="${WORKSPACE_ROOT}/exeris-kernel/exeris-kernel-spi/target/classes"
BOOTSTRAP_JAR="${WORKSPACE_ROOT}/tools/jdk-loom/bootstrap/target/exeris-loom-bootstrap.jar"
ENT_JAR="${HOME}/.m2/repository/eu/exeris/exeris-kernel-enterprise/0.6.0-SNAPSHOT/exeris-kernel-enterprise-0.6.0-SNAPSHOT.jar"

M2_REPO="${HOME}/.m2/repository"

mkdir -p "${CLASSES_DIR}"

CP="${SPI_CLASSES}:${CORE_CLASSES}:${BOOTSTRAP_JAR}:${ENT_JAR}"
if [ -f "/tmp/ent_cp.txt" ]; then
    CP="${CP}:$(cat /tmp/ent_cp.txt)"
fi
for jar in $(find "${M2_REPO}/eu/exeris/" -name "*.jar" 2>/dev/null | head -n 30); do
    CP="${CP}:${jar}"
done

echo "Compiling H1LocalityApplication with ${JAVAC}..."
find "${SRC_DIR}" -name "*.java" > "${TARGET_DIR}/sources.txt"

"${JAVAC}" \
    --enable-preview --release 28 \
    -cp "${CP}" \
    -d "${CLASSES_DIR}" \
    @"${TARGET_DIR}/sources.txt"

echo "Creating ${OUTPUT_JAR}..."
"${JAR}" --create --file "${OUTPUT_JAR}" -C "${CLASSES_DIR}" .

echo "H1 Locality App built successfully: ${OUTPUT_JAR}"
