#!/usr/bin/env bash
# sync-repo.sh — Ship the repo (git HEAD archive) to a droplet at ~/exeris-benchmarks.
# Avoids needing GitHub auth on the droplet; commit local changes before syncing.
#
# Usage:
#   ./tools/cloud/do/sync-repo.sh bench@<droplet-ip>
set -euo pipefail

HOST="${1:?usage: sync-repo.sh user@host}"
ROOT="$(git rev-parse --show-toplevel)"
SHA="$(git -C "$ROOT" rev-parse --short HEAD)"
FULL_SHA="$(git -C "$ROOT" rev-parse HEAD)"

if ! git -C "$ROOT" diff --quiet HEAD 2>/dev/null; then
  echo "WARNING: uncommitted changes exist — only committed HEAD ($SHA) is synced." >&2
fi

echo "syncing $SHA -> $HOST:~/exeris-benchmarks"
# Force LF in the archive: on Windows core.autocrlf=true would smudge shell
# scripts to CRLF, which breaks bash on the droplet (set: pipefail: invalid).
git -C "$ROOT" -c core.autocrlf=false -c core.eol=lf archive --format=tar.gz HEAD \
  | ssh -o StrictHostKeyChecking=accept-new "$HOST" '
      rm -rf ~/exeris-benchmarks &&
      mkdir -p ~/exeris-benchmarks &&
      tar xz -C ~/exeris-benchmarks &&
      cd ~/exeris-benchmarks &&
      find . -name "*.sh" -exec chmod +x {} + &&
      echo '"'"$FULL_SHA"'"' > .synced-commit-sha &&
      echo "synced into ~/exeris-benchmarks"'
echo "done ($SHA)"
