#!/usr/bin/env bash
# identity.sh — run identity and revision metadata, in one place.
#
# WHY THIS EXISTS
# ---------------
# Four scripts each carried their own copy of
#
#     GIT_SHA7="$(git -C "$ROOT" rev-parse --short=7 HEAD 2>/dev/null || echo 'nogit')"
#
# and all four were wrong in the same two ways. First, the fallback WRITES A
# RESULT ANYWAY: the literal "nogit" satisfies every schema in this repo while
# carrying no traceable revision, so the artifact looks complete and cannot be
# re-bisected. Second, that value was frequently placed next to `repo:
# <target>`, where it reads as the TARGET's commit while actually holding the
# harness's.
#
# The fallback is not hypothetical. The perf box's copy of this repo is an
# rsync destination, not a checkout, so `git rev-parse` fails there on every
# run -- i.e. it failed on exactly the machine that produces the results.
#
# Three of the four copies were fixed individually in #28 and #29. This helper
# is the follow-up those fixes named, so the fourth cannot drift back.
#
# CONTRACT
#   bench_harness_sha        -> harness revision, or exits 1 with instructions.
#   bench_require_target_sha -> validates a caller-supplied target revision.
#   bench_run_id             -> "<scenario>-<timestamp>-<harness sha>"
#
# Both revisions are MANDATORY and neither is inferred from the other. They are
# two repositories with two identities, and a destructive or fuzz finding that
# cannot be tied to both cannot be reproduced.
set -u

# Harness revision. BENCH_HARNESS_SHA (or --harness-sha, which callers export
# into it) wins; otherwise read the checkout. Never returns a placeholder.
bench_harness_sha() {
  local root="${1:?bench_harness_sha <repo-root>}"
  local sha="${BENCH_HARNESS_SHA:-}"
  if [[ -z "$sha" ]]; then
    sha="$(git -C "$root" rev-parse --short=12 HEAD 2>/dev/null || true)"
  fi
  if [[ -z "$sha" ]]; then
    echo "ERROR: cannot determine the harness commit ($root is not a git checkout)." >&2
    echo "       Pass --harness-sha <sha> or set BENCH_HARNESS_SHA. Refusing to record" >&2
    echo "       'nogit': a finding that cannot be traced to a revision cannot be re-bisected." >&2
    return 1
  fi
  printf '%s\n' "$sha"
}

# Target revision. The harness cannot introspect which build is behind a socket,
# so this is supplied, never guessed -- and never defaulted to the harness sha,
# which is the confusion this helper exists to end.
bench_require_target_sha() {
  local sha="${1:-}"
  local flag="${2:---target-commit}"
  if [[ -z "$sha" ]]; then
    echo "ERROR: ${flag} is required. The harness cannot introspect the revision of a" >&2
    echo "       pre-launched target, and the harness sha is NOT a substitute for it." >&2
    return 1
  fi
  printf '%s\n' "$sha"
}

bench_run_id() {
  local scenario="${1:?bench_run_id <scenario> <timestamp> <harness-sha>}"
  local timestamp="${2:?}"
  local harness_sha="${3:?}"
  printf '%s-%s-%s\n' "$scenario" "$timestamp" "$harness_sha"
}

# radamsa lookup, matching runtime/drivers/lib/radamsa_attack.py: RADAMSA_BIN
# overrides PATH. The perf box installs it under ~/.local/bin, which a
# non-interactive shell does not have, so a bare `command -v radamsa` gate
# rejects a host where the driver itself would have found it.
bench_require_radamsa() {
  if [[ -n "${RADAMSA_BIN:-}" ]]; then
    if [[ -x "$RADAMSA_BIN" ]]; then
      printf '%s\n' "$RADAMSA_BIN"; return 0
    fi
    echo "ERROR: RADAMSA_BIN='$RADAMSA_BIN' is not executable." >&2
    return 1
  fi
  local found
  found="$(command -v radamsa 2>/dev/null || true)"
  if [[ -z "$found" ]]; then
    echo "ERROR: radamsa not found. Set RADAMSA_BIN or add it to PATH." >&2
    echo "       Install: https://gitlab.com/akihe/radamsa" >&2
    return 1
  fi
  printf '%s\n' "$found"
}
