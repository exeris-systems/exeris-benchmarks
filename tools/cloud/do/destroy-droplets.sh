#!/usr/bin/env bash
# destroy-droplets.sh — Destroy every droplet tagged 'exeris-bench'.
# Droplets bill per-second while they exist (even powered off) — destroy when idle.
# The VPC and the registered SSH key are kept (both are free).
#
# Usage:
#   ./tools/cloud/do/destroy-droplets.sh --yes
set -euo pipefail

TAG="exeris-bench"

[[ "${1:-}" == "--yes" ]] || {
  echo "Refusing to destroy without --yes. Droplets currently tagged '$TAG':" >&2
  DOCTL_LIST_ONLY=1
}

DOCTL="${DOCTL:-}"
if [[ -z "$DOCTL" ]]; then
  for cand in doctl "$HOME/.local/bin/doctl" "$HOME/.local/bin/doctl.exe"; do
    if command -v "$cand" >/dev/null 2>&1; then DOCTL="$cand"; break; fi
  done
fi
[[ -n "$DOCTL" ]] || { echo "ERROR: doctl not found (set DOCTL=/path/to/doctl)" >&2; exit 1; }

"$DOCTL" compute droplet list --tag-name "$TAG" --format ID,Name,PublicIPv4,Status

if [[ "${DOCTL_LIST_ONLY:-}" == "1" ]]; then
  exit 1
fi

"$DOCTL" compute droplet delete --tag-name "$TAG" --force
echo "All '$TAG' droplets destroyed."
