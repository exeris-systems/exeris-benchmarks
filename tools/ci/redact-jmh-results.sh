#!/usr/bin/env bash
# redact-jmh-results.sh — strip implementation FQCNs from JMH result artifacts
# before uploading or publishing them.
#
# What gets redacted (in-place):
#   - .jvmArgs[] entries that contain a provider/cert FQCN or path:
#       -Dexeris.tls.<tier>.cryptoProviderClass=eu.exeris.kernel.<impl>.crypto.X
#       -Dexeris.tls.<tier>.memoryProviderClass=eu.exeris.kernel.<impl>.memory.X
#       -Dexeris.tls.<tier>.certPem=/some/path
#       -Dexeris.tls.<tier>.keyPem=/some/path
#       (the property KEY stays so reproducibility analysis is possible; the VALUE is
#        replaced with <redacted-fqcn> / <redacted-path>)
#   - .jvm runtime path (JDK install location of the runner) → "<redacted-jvm-path>"
#
# What is intentionally NOT touched:
#   - .benchmark FQCN (the renamed ownership-model classes — FdOwnerTlsEngineLoopback*,
#     OffHeapTlsEngineMemoryBio* — describe the harness model, not the impl, so they're
#     safe to expose)
#   - .params, .primaryMetric, .secondaryMetrics — the actual numbers we want to share
#   - .jvmName, .jvmVersion — needed for env reproducibility
#   - JFR files — not handled here; do NOT upload those when sharing results publicly
#
# Usage:
#   tools/ci/redact-jmh-results.sh path/to/jmh-results.json [more.json ...]
#
# Output:
#   - rewrites each input JSON in place
#   - writes a sibling "<input>.redaction-report.txt" listing what was changed
#   - non-zero exit if any input is missing or jq fails
set -u -o pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 path/to/jmh.json [more.json ...]" >&2
  exit 1
fi

REDACT_VALUE_FQCN="<redacted-fqcn>"
REDACT_VALUE_PATH="<redacted-path>"
REDACT_VALUE_JVM="<redacted-jvm-path>"

redact_one() {
  local input="$1"
  if [[ ! -f "$input" ]]; then
    echo "ERROR: not a file: $input" >&2
    return 1
  fi

  local tmp
  tmp="$(mktemp)"

  # Redact .jvmArgs entries: keep the -Dkey= prefix, replace the value
  # for cryptoProviderClass/memoryProviderClass (FQCN) and certPem/keyPem (filesystem path).
  # Also redact .jvm runtime path. Leave benchmark FQCN intact — that's the ownership model name.
  jq '
    def redact_arg:
      if test("^-D(exeris\\.tls\\.[^=]+\\.(cryptoProviderClass|memoryProviderClass))=") then
        sub("=.*$"; "=" + "'"$REDACT_VALUE_FQCN"'")
      elif test("^-D(exeris\\.tls\\.[^=]+\\.(certPem|keyPem))=") then
        sub("=.*$"; "=" + "'"$REDACT_VALUE_PATH"'")
      else . end;

    map(
      if has("jvmArgs") then .jvmArgs |= map(redact_arg) else . end
      | if has("jvm") then .jvm = "'"$REDACT_VALUE_JVM"'" else . end
    )
  ' "$input" > "$tmp"

  if ! jq -e '. | type == "array"' "$tmp" >/dev/null 2>&1; then
    echo "ERROR: jq output is not a JSON array — refusing to overwrite $input" >&2
    rm -f "$tmp"
    return 1
  fi

  mv "$tmp" "$input"

  # Emit a small report next to the file.
  local report="${input}.redaction-report.txt"
  {
    echo "Redaction applied to: $input"
    echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Replacements:"
    echo "  -Dexeris.tls.<tier>.cryptoProviderClass=  -> $REDACT_VALUE_FQCN"
    echo "  -Dexeris.tls.<tier>.memoryProviderClass=  -> $REDACT_VALUE_FQCN"
    echo "  -Dexeris.tls.<tier>.certPem=              -> $REDACT_VALUE_PATH"
    echo "  -Dexeris.tls.<tier>.keyPem=               -> $REDACT_VALUE_PATH"
    echo "  .jvm                                       -> $REDACT_VALUE_JVM"
    echo "Untouched: .benchmark (ownership-model class), .params, .primaryMetric, .secondaryMetrics, .jvmName, .jvmVersion"
  } > "$report"

  echo "Redacted: $input  (report: $report)"
}

rc=0
for f in "$@"; do
  redact_one "$f" || rc=1
done
exit "$rc"
