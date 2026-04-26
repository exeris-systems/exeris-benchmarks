#!/usr/bin/env bash
# run-primary-tls-matrix-64m.sh - run B4/B5/B6/B6b/B7 with 64m heap profile
#
# Usage:
#   MODE=all HEADLESS=1 ./scripts/run-primary-tls-matrix-64m.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_MANIFEST="$REPO_ROOT/tools/matrix/manifests/primary-tls-matrix.json"
TARGET_RUNNER="$REPO_ROOT/scripts/run-primary-tls-matrix.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but was not found in PATH." >&2
  exit 1
fi

if [[ ! -r "$BASE_MANIFEST" ]]; then
  echo "ERROR: Base manifest is not readable: $BASE_MANIFEST" >&2
  exit 1
fi

if [[ ! -x "$TARGET_RUNNER" ]]; then
  echo "ERROR: Runner script is not executable: $TARGET_RUNNER" >&2
  exit 1
fi

TMP_MANIFEST="$(mktemp "${TMPDIR:-/tmp}/primary-tls-matrix-64m.XXXXXX.json")"
trap 'rm -f "$TMP_MANIFEST"' EXIT

jq '
    .metadata.description = ((.metadata.description // "") + " [heap-profile:64m for B4/B5/B6/B6b/B7]")
  | .benchmarks |= map(
      if (.id == "B4" or .id == "B5" or .id == "B6" or .id == "B6b" or .id == "B7") then
        .common_jvm_args = (
          ((.common_jvm_args // []) | map(select((test("^-Xms") or test("^-Xmx")) | not)))
          + ["-Xms64m", "-Xmx64m"]
        )
      else
        .
      end
    )
' "$BASE_MANIFEST" > "$TMP_MANIFEST"

BENCH_FILTER="${BENCH_FILTER:-^B(4|5|6|6b|7)$}"

ENV_ARGS=("MANIFEST_FILE=$TMP_MANIFEST" "BENCH_FILTER=$BENCH_FILTER")
[[ -n "${MODE+x}" ]] && ENV_ARGS+=("MODE=$MODE")
[[ -n "${HEADLESS+x}" ]] && ENV_ARGS+=("HEADLESS=$HEADLESS")
[[ -n "${FAIL_FAST+x}" ]] && ENV_ARGS+=("FAIL_FAST=$FAIL_FAST")
[[ -n "${PHASE_FILTER+x}" ]] && ENV_ARGS+=("PHASE_FILTER=$PHASE_FILTER")
[[ -n "${AUTO_BUILD_JMH+x}" ]] && ENV_ARGS+=("AUTO_BUILD_JMH=$AUTO_BUILD_JMH")

env "${ENV_ARGS[@]}" "$TARGET_RUNNER"
