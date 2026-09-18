#!/usr/bin/env bash
# run-fuzz-campaign.sh — drive a Jazzer fuzz campaign and emit conforming artifacts.
#
# Usage:
#   ./scripts/run-fuzz-campaign.sh <scenario-dir> --kernel-version <v> --kernel-commit <sha>
#                                                 [--harness-sha <sha>] [--java-release <n>]
#                                                 [--output <dir>]
#
# Campaign length is NOT a flag — it comes from @FuzzTest(maxDuration = "...") on the test class.
# See the note above the --duration handling for the three override routes that were tried and
# measured not to work with Jazzer 0.22.1.
#
# Emits to <output>/ (default: results/raw/<scenario-id>-<timestamp>/):
#   - result.json                  — benchmark-result.schema.json conforming
#   - destructive-findings.json    — destructive-findings.schema.json conforming
#   - surefire-output.txt          — raw Surefire stdout (debug aid)
#   - crash-* / hang-*             — if Jazzer found anything (NEVER publish)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SCENARIO_DIR="${1:?Usage: run-fuzz-campaign.sh <scenario-dir> --kernel-version <v> --kernel-commit <sha> [--harness-sha <sha>] [--java-release <n>] [--output <dir>]}"
shift

DURATION="${FUZZ_DURATION:-60s}"
OUTPUT_DIR=""
# micro/fuzz/pom.xml deliberately has NO default for exeris.kernel.version: a floating
# -SNAPSHOT makes a finding impossible to re-bisect, so the pom aborts at validate unless
# the pin is supplied. This runner never supplied it, which is why it could not run at all
# until 2026-08-26 — the documented entry point in docs/scenario-catalog.md failed on every
# invocation. Required here rather than defaulted, for the same reason the pom refuses one.
KERNEL_VERSION_PIN="${EXERIS_KERNEL_VERSION:-}"
KERNEL_COMMIT="${EXERIS_KERNEL_COMMIT:-}"
HARNESS_SHA_ARG=""
# The pom targets a fixed java.version. Override when the campaign must run on a different
# feature release than the pom's default (e.g. pinning the LTS the kernel actually ships on).
JAVA_RELEASE="${FUZZ_JAVA_RELEASE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration)       DURATION="$2"; DURATION_EXPLICIT=1; shift 2 ;;
    --output)         OUTPUT_DIR="$2"; shift 2 ;;
    --kernel-version) KERNEL_VERSION_PIN="$2"; shift 2 ;;
    --kernel-commit)  KERNEL_COMMIT="$2"; shift 2 ;;
    --harness-sha)    BENCH_HARNESS_SHA="$2"; export BENCH_HARNESS_SHA; shift 2 ;;
    --java-release)   JAVA_RELEASE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$KERNEL_VERSION_PIN" ]]; then
  echo "ERROR: --kernel-version is required (or set EXERIS_KERNEL_VERSION)." >&2
  echo "       micro/fuzz/pom.xml has no default; a floating -SNAPSHOT would make any" >&2
  echo "       finding impossible to re-bisect. Pass a release or a timestamped snapshot," >&2
  echo "       e.g. --kernel-version 0.11.0" >&2
  exit 2
fi
if [[ "$KERNEL_VERSION_PIN" == *-SNAPSHOT ]]; then
  echo "ERROR: --kernel-version $KERNEL_VERSION_PIN is a floating snapshot." >&2
  echo "       Use the timestamped form (0.x.y-YYYYMMDD.HHMMSS-N) or a release." >&2
  exit 2
fi

MVN_PIN_ARGS=(-Dexeris.kernel.version="$KERNEL_VERSION_PIN")
[[ -n "$JAVA_RELEASE" ]] && MVN_PIN_ARGS+=(-Djava.version="$JAVA_RELEASE")



if [[ ! -d "$SCENARIO_DIR" ]]; then
  echo "ERROR: scenario dir not found: $SCENARIO_DIR" >&2; exit 1
fi
SCENARIO_JSON="$SCENARIO_DIR/scenario.json"
if [[ ! -f "$SCENARIO_JSON" ]]; then
  echo "ERROR: scenario.json missing in $SCENARIO_DIR" >&2; exit 1
fi
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 1; }
command -v mvn >/dev/null 2>&1 || { echo "ERROR: mvn required" >&2; exit 1; }

SCENARIO_ID="$(jq -r '.scenario_id' "$SCENARIO_JSON")"
TEST_CLASS_FQN="$(jq -r '.fuzz.test_class' "$SCENARIO_JSON")"
TEST_CLASS_SHORT="${TEST_CLASS_FQN##*.}"

# Campaign length is NOT settable from here. It comes from @FuzzTest(maxDuration = "...") on the
# test class, and three routes to override it were tried and measured on 2026-08-26: -Djazzer.*
# on the command line never reaches the forked test JVM; jazzer.duration is not a property Jazzer
# reads; and jazzer.internal.arg.0=-max_total_time does reach the fork but is overridden by the
# annotation's own argument, which libFuzzer sees last (a 20s request still ran 66s).
#
# Until 2026-08-26 this runner accepted --duration, printed it in the header and wrote it into the
# artifact, while the campaign ran for whatever the annotation said. Refusing is better than
# recording a number that did not happen.
EFFECTIVE_DURATION="$(grep -oE 'maxDuration[[:space:]]*=[[:space:]]*"[^"]+"' \
  "$ROOT/micro/fuzz/src/test/java/${TEST_CLASS_FQN//.//}.java" 2>/dev/null \
  | head -1 | grep -oE '"[^"]+"' | tr -d '"')"
EFFECTIVE_DURATION="${EFFECTIVE_DURATION:-unknown}"

if [[ -n "${DURATION_EXPLICIT:-}" ]]; then
  echo "ERROR: --duration cannot be honoured by Jazzer 0.22.1's JUnit engine." >&2
  echo "       Campaign length comes from @FuzzTest(maxDuration = \"$EFFECTIVE_DURATION\") in" >&2
  echo "       ${TEST_CLASS_FQN}. Edit the annotation, then re-run without --duration." >&2
  exit 2
fi
DURATION="$EFFECTIVE_DURATION"

TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
# Two different repositories are involved and they were conflated until 2026-08-26: the harness
# SHA was written into target.commit_sha, a field whose sibling says repo: "exeris-kernel". And
# when git failed it silently wrote the literal "nogit", producing a result that satisfies the
# schema while violating the reproducibility rule it exists to enforce. The perf-box copy of this
# repo is an rsync target, not a checkout, so that fallback fired on every real run.
#
#   target.commit_sha              -> the KERNEL commit the fuzzed code came from
#   tool_versions.exeris-benchmarks -> the HARNESS commit that drove the campaign
#
# Neither is allowed to be absent. A fuzz finding against an unidentified build cannot be
# re-bisected, which is the same reason micro/fuzz/pom.xml refuses an unpinned kernel version.
HARNESS_SHA="${BENCH_HARNESS_SHA:-$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || true)}"
if [[ -z "$HARNESS_SHA" ]]; then
  echo "ERROR: cannot determine the harness commit ($ROOT is not a git checkout)." >&2
  echo "       Pass --harness-sha <sha> or set BENCH_HARNESS_SHA. Refusing to record 'nogit':" >&2
  echo "       a result that cannot be traced to a harness revision is not reproducible." >&2
  exit 2
fi
if [[ -z "$KERNEL_COMMIT" ]]; then
  echo "ERROR: --kernel-commit is required (or set EXERIS_KERNEL_COMMIT)." >&2
  echo "       target.commit_sha describes repo \"exeris-kernel\", so it must be the kernel" >&2
  echo "       commit behind --kernel-version $KERNEL_VERSION_PIN, not the harness revision." >&2
  echo "       e.g. --kernel-commit \$(git -C <exeris-kernel> rev-parse --short=12 v0.11.0^{commit})" >&2
  exit 2
fi
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 && \
   [[ -n "$(git -C "$ROOT" status --porcelain -- micro/fuzz scripts/run-fuzz-campaign.sh 2>/dev/null)" ]]; then
  echo "WARNING: micro/fuzz or the runner has uncommitted changes; $HARNESS_SHA does not fully" >&2
  echo "         describe what ran." >&2
fi
GIT_SHA7="$HARNESS_SHA"
RUN_ID="${SCENARIO_ID}-${TIMESTAMP}-${HARNESS_SHA}"

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$ROOT/results/raw/${SCENARIO_ID}-${TIMESTAMP}"
fi
mkdir -p "$OUTPUT_DIR"

SUREFIRE_OUT="$OUTPUT_DIR/surefire-output.txt"
JAZZER_WORK="$OUTPUT_DIR/jazzer-work"
mkdir -p "$JAZZER_WORK"

echo "=== Jazzer fuzz campaign ==="
echo "  scenario   : $SCENARIO_ID"
echo "  test class : $TEST_CLASS_FQN"
echo "  duration   : $DURATION"
echo "  output     : $OUTPUT_DIR"
echo ""

START_EPOCH_MS="$(date -u +%s%3N)"

set +e
(
  cd "$ROOT/micro/fuzz"
  # JAZZER_FUZZ=1 is what makes this a fuzz campaign. Without it Jazzer's JUnit integration
  # runs @FuzzTest in REGRESSION mode: it replays the seed corpus, passes, and exits — measured
  # at 1.3s for a run declared as 60s, with zero mutation. Every artifact this family produced
  # before 2026-08-26 was a seed replay labelled as a campaign.
  export JAZZER_FUZZ=1
  mvn -s "$ROOT/.github/maven-settings-gpr.xml" \
      -B test \
      "${MVN_PIN_ARGS[@]}" \
      -Dtest="$TEST_CLASS_SHORT" \
      -Djazzer.duration="$DURATION"
) > "$SUREFIRE_OUT" 2>&1
SUREFIRE_RC=$?
set -e

END_EPOCH_MS="$(date -u +%s%3N)"
DURATION_SEC=$(( (END_EPOCH_MS - START_EPOCH_MS) / 1000 ))

# Jazzer emits crash-* / hang-* in CWD. Move them next to the campaign output
# so they're easy to attach as --destructive-artifact paths.
shopt -s nullglob
for f in "$ROOT/micro/fuzz"/crash-* "$ROOT/micro/fuzz"/hang-*; do
  mv "$f" "$JAZZER_WORK/"
done
shopt -u nullglob

# All numeric counters below are fed to jq --argjson, which aborts on an empty
# string. Apply ${VAR:-0} + regex sanitization so a missing/unreadable
# $SUREFIRE_OUT never causes the whole run to crash at the reporting step.
CRASH_COUNT=$(find "$JAZZER_WORK" -maxdepth 1 -name 'crash-*' 2>/dev/null | wc -l | tr -d ' ')
HANG_COUNT=$(find "$JAZZER_WORK" -maxdepth 1 -name 'hang-*' 2>/dev/null | wc -l | tr -d ' ')
OOM_COUNT=$(grep -c 'OutOfMemoryError' "$SUREFIRE_OUT" 2>/dev/null || echo 0)
[[ "$CRASH_COUNT" =~ ^[0-9]+$ ]] || CRASH_COUNT=0
[[ "$HANG_COUNT"  =~ ^[0-9]+$ ]] || HANG_COUNT=0
[[ "$OOM_COUNT"   =~ ^[0-9]+$ ]] || OOM_COUNT=0

# A campaign that never executed must NOT emit artifacts. Until 2026-08-26 this block
# classified purely on crash/oom/hang counters and never looked at the Maven exit code, so a
# BUILD FAILURE produced "0 crashes -> stable" and a schema-conforming destructive-findings.json
# claiming the target absorbed everything. That is worse than emitting nothing: the file reads
# as evidence, and a fuzz family that reports green when it never ran lets a real crash ship.
#
# Order matters. A genuine finding also fails the build, so the crash/oom/hang artifacts are
# checked FIRST; only a non-zero exit with no artifacts at all means the campaign did not run.
# There is deliberately no "did-not-run" degradation_class: the schema does not have one, and
# adding it would create a value that aggregators must learn to distrust. No artifact, non-zero
# exit, and the raw Surefire log left in place is the honest outcome.
if (( SUREFIRE_RC != 0 )) && (( CRASH_COUNT == 0 )) && (( OOM_COUNT == 0 )) && (( HANG_COUNT == 0 )); then
  echo "" >&2
  echo "ERROR: the fuzz campaign did not execute (Maven exited $SUREFIRE_RC, no crash/hang/OOM" >&2
  echo "       artifacts produced). NOT writing result.json or destructive-findings.json —" >&2
  echo "       a findings file from a campaign that never ran would be read as evidence." >&2
  echo "       Raw build output: $SUREFIRE_OUT" >&2
  tail -n 15 "$SUREFIRE_OUT" >&2 2>/dev/null || true
  exit "$SUREFIRE_RC"
fi

if (( CRASH_COUNT > 0 )); then
  DEGRADATION="crash"
elif (( OOM_COUNT > 0 )); then
  DEGRADATION="oom"
elif (( HANG_COUNT > 0 )); then
  DEGRADATION="graceful-shed"
else
  DEGRADATION="stable"
fi

# Iterations are not reliably extractable from Surefire; Jazzer's libFuzzer
# output goes to a separate log stream. Best-effort grep — empty/non-numeric
# tail must become a literal 0 or jq --argjson aborts.
ITERATIONS_TOTAL=$(grep -oE '#[0-9]+\b' "$SUREFIRE_OUT" 2>/dev/null \
  | tr -d '#' | sort -n | tail -1 || true)
[[ "$ITERATIONS_TOTAL" =~ ^[0-9]+$ ]] || ITERATIONS_TOTAL=0

# Best-effort, so this warns rather than fails: Jazzer's libFuzzer counter does not always
# reach the Surefire stream. Zero iterations on a passing build still deserves a shout, because
# "stable over 0 inputs" is vacuous however the build exited.
if (( ITERATIONS_TOTAL == 0 )); then
  echo "WARNING: no Jazzer iteration counter found in $SUREFIRE_OUT." >&2
  echo "         The build passed, so artifacts are written, but 'stable' here is only as" >&2
  echo "         strong as the evidence that the fuzzer actually drove inputs. Check the log." >&2
fi

JAZZER_VERSION="$(cd "$ROOT/micro/fuzz" && mvn -s "$ROOT/.github/maven-settings-gpr.xml" \
  "${MVN_PIN_ARGS[@]}" -B help:evaluate -Dexpression=jazzer.version -q -DforceStdout 2>/dev/null || echo "unknown")"
KERNEL_VERSION="$(cd "$ROOT/micro/fuzz" && mvn -s "$ROOT/.github/maven-settings-gpr.xml" \
  "${MVN_PIN_ARGS[@]}" -B help:evaluate -Dexpression=exeris.kernel.version -q -DforceStdout 2>/dev/null || echo "unknown")"

SEED_CORPUS_DIR="$ROOT/micro/fuzz/src/test/resources/eu/exeris/benchmarks/micro/fuzz/$TEST_CLASS_SHORT"
SEED_SHA="unknown"
if [[ -d "$SEED_CORPUS_DIR" ]]; then
  SEED_SHA="$(find "$SEED_CORPUS_DIR" -type f -print0 | sort -z \
    | xargs -0 cat | sha256sum | awk '{print $1}')"
fi

RESULT_FILE="$OUTPUT_DIR/result.json"
FINDINGS_FILE="$OUTPUT_DIR/destructive-findings.json"

jq -n \
  --arg run_id "$RUN_ID" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg scenario "$SCENARIO_ID" \
  --arg sha "$KERNEL_COMMIT" \
  --arg harness_sha "$HARNESS_SHA" \
  --arg duration "$DURATION" \
  --arg surefire_rc "$SUREFIRE_RC" \
  --argjson crash "$CRASH_COUNT" \
  --argjson hang "$HANG_COUNT" \
  --argjson oom "$OOM_COUNT" \
  --argjson iterations "$ITERATIONS_TOTAL" \
  '{
    schema_version: "1",
    run_id: $run_id,
    timestamp: $ts,
    scenario: $scenario,
    tool: "jazzer",
    env_ref: "",
    target: {
      repo: "exeris-kernel",
      commit_sha: $sha,
      mode: "pure",
      tier: "community",
      protocol: "h1"
    },
    comparison_axis: "standalone",
    execution_class: "exploratory",
    claim_scope: "exploratory",
    final_reason: (if ($surefire_rc | tonumber) == 0 then "ok" else "benchmark_exit_nonzero" end),
    runner_status: (if ($surefire_rc | tonumber) == 0 and $crash == 0 then "success" else "failed" end),
    reproducibility_status: "complete",
    run_config: {
      duration_seconds: ($duration | rtrimstr("s") | tonumber? // 0)
    },
    metrics: {
      total_requests: $iterations,
      total_errors: ($crash + $oom + $hang)
    }
  }' > "$RESULT_FILE"

jq -n \
  --arg run_id "$RUN_ID" \
  --arg scenario "$SCENARIO_ID" \
  --argjson duration_seconds "$DURATION_SEC" \
  --argjson iterations "$ITERATIONS_TOTAL" \
  --argjson crash "$CRASH_COUNT" \
  --argjson oom "$OOM_COUNT" \
  --argjson hang "$HANG_COUNT" \
  --arg degradation "$DEGRADATION" \
  --arg jazzer_v "$JAZZER_VERSION" \
  --arg kernel_v "$KERNEL_VERSION" \
  --arg harness_sha "$HARNESS_SHA" \
  --arg seed_sha "$SEED_SHA" \
  '{
    schema_version: "1",
    run_id: $run_id,
    scenario: $scenario,
    campaign_kind: "jazzer-parser",
    duration_seconds: $duration_seconds,
    claim_scope: "exploratory",
    comparison_axis: "standalone",
    findings: {
      iterations_total: $iterations,
      crash_count: $crash,
      oom_count: $oom,
      hang_count: $hang,
      unique_crash_signatures: $crash,
      mean_time_to_crash_us: null,
      leak_count_delta: 0
    },
    degradation_class: $degradation,
    tool_versions: {
      "exeris-benchmarks": $harness_sha,
      jazzer: $jazzer_v,
      "exeris-kernel": $kernel_v
    },
    seeds: {
      jazzer_seed_corpus_sha256: $seed_sha
    },
    tolerance: {
      max_unexpected_crashes: 0,
      max_hang_count: 0
    },
    publication_mode: "internal-only"
  }' > "$FINDINGS_FILE"

echo ""
echo "=== Summary ==="
echo "  iterations : $ITERATIONS_TOTAL"
echo "  crashes    : $CRASH_COUNT"
echo "  hangs      : $HANG_COUNT"
echo "  OOM        : $OOM_COUNT"
echo "  class      : $DEGRADATION"
echo ""
echo "Artifacts:"
echo "  $RESULT_FILE"
echo "  $FINDINGS_FILE"
echo "  $SUREFIRE_OUT"
if (( CRASH_COUNT > 0 || HANG_COUNT > 0 )); then
  echo ""
  echo "FINDINGS in $JAZZER_WORK — pass via --destructive-artifact to publish-report.sh,"
  echo "and ONLY in --publication-mode internal-only."
fi

exit "$SUREFIRE_RC"
