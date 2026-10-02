#!/usr/bin/env bash
# build-kernel.sh — build the exeris-kernel classes a loom-carrier-scheduler campaign measures.
#
# The kernel under test is identified by a commit, never by a working tree: the commit is exported
# with `git archive` into a fresh directory and built there, so uncommitted edits in any checkout
# cannot reach the measured classes. Nothing is installed into the local Maven repository; the
# result is a classpath file and an identity record that every trial copies into its own output.
#
# Usage:
#   scripts/loom-carrier-scheduler/build-kernel.sh <kernel-commit> [kernel-repo]
#
#   kernel-commit  any revision the kernel repository can resolve (branch, tag, SHA)
#   kernel-repo    path to an exeris-kernel clone (default: ../exeris-kernel next to this repo)
#
# Environment:
#   LOOM_JDK   JDK used to build and run (default: <workspace>/tools/jdk-loom/current)
#   WORK_ROOT  build root (default: <bench-repo>/work/loom-carrier-scheduler)
#
# Output: $WORK_ROOT/kernel-<sha12>/{kernel-cp.txt,kernel-identity.json} and prints the directory.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="$(cd "$BENCH_ROOT/.." && pwd)"
# A worktree sits deeper than the main checkout; walk up to the directory holding tools/jdk-loom.
while [[ ! -d "$WORKSPACE_ROOT/tools/jdk-loom" && "$WORKSPACE_ROOT" != "/" ]]; do
  WORKSPACE_ROOT="$(dirname "$WORKSPACE_ROOT")"
done

KERNEL_REV="${1:?usage: build-kernel.sh <kernel-commit> [kernel-repo]}"
KERNEL_REPO="${2:-$WORKSPACE_ROOT/exeris-kernel}"
LOOM_JDK="${LOOM_JDK:-$WORKSPACE_ROOT/tools/jdk-loom/current}"
WORK_ROOT="${WORK_ROOT:-$BENCH_ROOT/work/loom-carrier-scheduler}"

die() { echo "build-kernel: $*" >&2; exit 1; }

[[ -x "$LOOM_JDK/bin/javac" ]] || die "no javac under LOOM_JDK=$LOOM_JDK"
git -C "$KERNEL_REPO" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $KERNEL_REPO"

SHA="$(git -C "$KERNEL_REPO" rev-parse --verify "${KERNEL_REV}^{commit}")" || die "cannot resolve $KERNEL_REV"
OUT="$WORK_ROOT/kernel-${SHA:0:12}"
SRC="$OUT/src"

if [[ -f "$OUT/kernel-identity.json" && -f "$OUT/kernel-cp.txt" ]]; then
  echo "$OUT"
  exit 0
fi

rm -rf "$OUT"
mkdir -p "$SRC"
git -C "$KERNEL_REPO" archive --format=tar "$SHA" | tar -x -C "$SRC"

# The core module compiles a java.lang.Thread stub with the javac found on PATH, so PATH has to
# resolve to the Loom JDK as well as JAVA_HOME.
export JAVA_HOME="$LOOM_JDK"
export PATH="$LOOM_JDK/bin:$PATH"

MVN_LOG="$OUT/mvn-build.txt"
( cd "$SRC" && mvn -o -B compile -pl exeris-kernel-community -am ) >"$MVN_LOG" 2>&1 \
  || die "kernel build failed, see $MVN_LOG"
( cd "$SRC" && mvn -o -B -q dependency:build-classpath -pl exeris-kernel-community \
    -Dmdep.outputFile="$OUT/community-deps.txt" ) >>"$MVN_LOG" 2>&1 \
  || die "dependency classpath failed, see $MVN_LOG"

# Kernel modules come from this build only; any eu.exeris jar the dependency plugin resolved from
# the local repository is a different build of the same code and is dropped.
DEPS="$(tr ':' '\n' <"$OUT/community-deps.txt" | grep -v '/eu/exeris/' | paste -sd: -)"
KERNEL_CP="$SRC/exeris-kernel-spi/target/classes:$SRC/exeris-kernel-core/target/classes:$SRC/exeris-kernel-community/target/classes"
[[ -n "$DEPS" ]] && KERNEL_CP="$KERNEL_CP:$DEPS"

# The scheduler class must exist and be plain release-28 bytecode: major 72, minor 0. A preview
# minor would mean the build ran with --enable-preview, which this track excludes.
SCHED_CLASS="$SRC/exeris-kernel-core/target/classes/eu/exeris/kernel/core/transport/scheduler/locality/ExerisCarrierScheduler.class"
[[ -f "$SCHED_CLASS" ]] || die "ExerisCarrierScheduler not built at $SHA"
read -r MINOR MAJOR < <(od -An -j4 -N4 -tu1 "$SCHED_CLASS" | awk '{print $1*256+$2, $3*256+$4}')
[[ "$MAJOR" == "72" && "$MINOR" == "0" ]] || die "scheduler class is major $MAJOR minor $MINOR, expected 72/0"

JDK_BUILD="$("$LOOM_JDK/bin/java" -version 2>&1 | sed -n '2p')"
printf '%s\n' "$KERNEL_CP" >"$OUT/kernel-cp.txt"
cat >"$OUT/kernel-identity.json" <<EOF
{
  "kernel_commit": "$SHA",
  "kernel_requested_revision": "$KERNEL_REV",
  "kernel_repo": "$(git -C "$KERNEL_REPO" remote get-url origin 2>/dev/null || echo "$KERNEL_REPO")",
  "built_from": "git archive $SHA",
  "class_file_major": $MAJOR,
  "class_file_minor": $MINOR,
  "jdk_build": "$JDK_BUILD",
  "built_at_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
echo "$OUT"
