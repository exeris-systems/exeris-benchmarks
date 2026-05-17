#!/usr/bin/env bash
# redact-aggregate-results.sh — strip implementation FQCNs and local filesystem paths
# from aggregate-phases.sh output (Markdown + JSON) before sharing/publishing.
#
# What gets redacted:
#   aggregate-*.md
#     - "**Run dir**: /abs/path/to/results/raw/..." → "**Run dir**: <redacted-run-dir>"
#     - any other absolute path under /home/<user>/ → "<redacted-path>"
#   aggregate-*.json
#     - .[].reproducibility_metadata.jvm_flags[] entries:
#         -Dexeris.tls.<tier>.cryptoProviderClass=... → <redacted-fqcn>
#         -Dexeris.tls.<tier>.memoryProviderClass=... → <redacted-fqcn>
#         -Dexeris.tls.<tier>.certPem=...             → <redacted-path>
#         -Dexeris.tls.<tier>.keyPem=...              → <redacted-path>
#         -XX:StartFlightRecording=filename=...       → filename=<redacted-path>
#
# Untouched:
#   - benchmark FQCN (FdOwnerTlsEngineLoopback*, OffHeapTlsEngineMemoryBio*) — these are
#     ownership-model names, intentionally exposed
#   - performance numbers (.primaryMetric, .secondaryMetrics, params)
#   - tier/mode labels (.target.tier, .target.mode) — these are public model labels
#   - JDK vendor/version, hardware profile — public reproducibility info
#
# Usage:
#   tools/ci/redact-aggregate-results.sh path/to/aggregate-*.md path/to/aggregate-*.json [...]
set -u -o pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 path/to/aggregate.md path/to/aggregate.json [...]" >&2
  exit 1
fi

REDACT_VALUE_FQCN="<redacted-fqcn>"
REDACT_VALUE_PATH="<redacted-path>"
REDACT_VALUE_RUN_DIR="<redacted-run-dir>"

redact_md() {
  local input="$1"
  local tmp
  tmp="$(mktemp)"

  # Replace "**Run dir**: <abs path>" line with redacted marker.
  # Then redact any remaining absolute filesystem paths under /home/<user>/.
  sed -E \
    -e "s#(\\*\\*Run dir\\*\\*:[[:space:]]*).*#\1${REDACT_VALUE_RUN_DIR}#" \
    -e "s#/home/[^/[:space:]\"]+/[^[:space:]\"\\\`]*#${REDACT_VALUE_PATH}#g" \
    "$input" > "$tmp"

  mv "$tmp" "$input"
}

redact_json() {
  local input="$1"
  local tmp
  tmp="$(mktemp)"

  jq '
    def redact_arg:
      if test("^-D(exeris\\.tls\\.[^=]+\\.(cryptoProviderClass|memoryProviderClass))=") then
        sub("=.*$"; "=" + "'"$REDACT_VALUE_FQCN"'")
      elif test("^-D(exeris\\.tls\\.[^=]+\\.(certPem|keyPem))=") then
        sub("=.*$"; "=" + "'"$REDACT_VALUE_PATH"'")
      elif test("^-XX:StartFlightRecording=") then
        gsub("filename=[^,]*"; "filename=" + "'"$REDACT_VALUE_PATH"'")
      else . end;

    if type == "array" then
      map(
        if (.reproducibility_metadata.jvm_flags? | type) == "array" then
          .reproducibility_metadata.jvm_flags |= map(redact_arg)
        else . end
      )
    else
      .
    end
  ' "$input" > "$tmp"

  if ! jq -e '.' "$tmp" >/dev/null 2>&1; then
    echo "ERROR: jq output invalid — refusing to overwrite $input" >&2
    rm -f "$tmp"
    return 1
  fi

  mv "$tmp" "$input"
}

emit_report() {
  local input="$1"
  local report="${input}.redaction-report.txt"
  {
    echo "Redaction applied to: $input"
    echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Replacements:"
    echo "  **Run dir**: <abs path>                      -> $REDACT_VALUE_RUN_DIR"
    echo "  /home/<user>/...                              -> $REDACT_VALUE_PATH"
    echo "  -Dexeris.tls.<tier>.cryptoProviderClass=     -> $REDACT_VALUE_FQCN"
    echo "  -Dexeris.tls.<tier>.memoryProviderClass=     -> $REDACT_VALUE_FQCN"
    echo "  -Dexeris.tls.<tier>.certPem= / keyPem=        -> $REDACT_VALUE_PATH"
    echo "  -XX:StartFlightRecording=...filename=<path>   -> filename=$REDACT_VALUE_PATH"
  } > "$report"
  echo "Redacted: $input  (report: $report)"
}

rc=0
for f in "$@"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: not a file: $f" >&2
    rc=1
    continue
  fi
  case "$f" in
    *.md)
      redact_md "$f" || { rc=1; continue; }
      emit_report "$f"
      ;;
    *.json)
      redact_json "$f" || { rc=1; continue; }
      emit_report "$f"
      ;;
    *)
      echo "ERROR: unsupported file type: $f (expected .md or .json)" >&2
      rc=1
      ;;
  esac
done
exit "$rc"
