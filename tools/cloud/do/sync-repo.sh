#!/usr/bin/env bash
# sync-repo.sh — Ship the repo (git HEAD archive) to a droplet at ~/exeris-benchmarks.
# Avoids needing GitHub auth on the droplet; commit local changes before syncing.
#
# Usage:
#   ./tools/cloud/do/sync-repo.sh bench@<droplet-ip> [--force-clean]
#
# DATA SAFETY (added 2026-07-20 after this script destroyed a completed campaign)
# ------------------------------------------------------------------------------
# The remote side used to run `rm -rf ~/exeris-benchmarks` before extracting. That is
# correct for CODE and catastrophic for MEASUREMENTS: campaign output under results/ is
# written on the droplet and is not in git until someone commits it, so a routine code
# sync silently deleted ~5.6 GB of finished runs — comparative results, gate artefacts and
# JFR recordings — with no backup and no warning.
#
# This script now preserves the data directories across a sync. Code still gets a clean
# replace (stale files removed from the repo do disappear), but measurements survive.
# `--force-clean` restores the old wipe-everything behaviour for when that is genuinely
# what you want; it prints what it is about to destroy first.
#
# The other half of that incident: four target env files were git-ignored, so `git add -A`
# skipped them, `git status` looked clean, and the sync shipped an incomplete change set.
# The pre-flight below now names ignored config files instead of letting them vanish.
set -euo pipefail

HOST=""
FORCE_CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --force-clean) FORCE_CLEAN=1 ;;
    -*) echo "unknown flag: $arg" >&2; exit 2 ;;
    *) HOST="$arg" ;;
  esac
done
: "${HOST:?usage: sync-repo.sh user@host [--force-clean]}"

ROOT="$(git rev-parse --show-toplevel)"
SHA="$(git -C "$ROOT" rev-parse --short HEAD)"
FULL_SHA="$(git -C "$ROOT" rev-parse HEAD)"

# Directories that hold droplet-produced data rather than repo content. Preserved across a
# sync unless --force-clean. Keep this list in sync with anything a run writes outside git.
PRESERVE_DIRS="results quarantine"

if ! git -C "$ROOT" diff --quiet HEAD 2>/dev/null; then
  echo "WARNING: uncommitted changes exist — only committed HEAD ($SHA) is synced." >&2
fi

# Pre-flight: git-ignored files under config paths are invisible to `git add -A` and to
# `git status`, so they never reach the droplet. Name them rather than letting a target
# fail later with a missing env file.
IGNORED_CONFIG="$(git -C "$ROOT" ls-files --others --ignored --exclude-standard \
  -- runtime/drivers/env scenarios micro/jmh/src 2>/dev/null || true)"
if [ -n "$IGNORED_CONFIG" ]; then
  echo "WARNING: these files are git-ignored and will NOT be shipped:" >&2
  printf '%s\n' "$IGNORED_CONFIG" | sed 's/^/    /' >&2
  echo "         If a target needs one, force-add it:  git add -f <path>" >&2
fi

echo "syncing $SHA -> $HOST:~/exeris-benchmarks"
if [ "$FORCE_CLEAN" = "1" ]; then
  echo "  --force-clean: droplet data directories ($PRESERVE_DIRS) WILL BE DESTROYED"
else
  echo "  preserving droplet data directories: $PRESERVE_DIRS"
fi

# Force LF in the archive: on Windows core.autocrlf=true would smudge shell
# scripts to CRLF, which breaks bash on the droplet (set: pipefail: invalid).
git -C "$ROOT" -c core.autocrlf=false -c core.eol=lf archive --format=tar.gz HEAD \
  | ssh -o StrictHostKeyChecking=accept-new "$HOST" \
      "FULL_SHA='$FULL_SHA' PRESERVE_DIRS='$PRESERVE_DIRS' FORCE_CLEAN='$FORCE_CLEAN' bash -s" <<'REMOTE'
set -euo pipefail
DEST="$HOME/exeris-benchmarks"
STASH="$(mktemp -d "${TMPDIR:-/tmp}/exeris-sync-preserve.XXXXXX")"
cleanup() { rm -rf "$STASH"; }
trap cleanup EXIT

if [ -d "$DEST" ]; then
  if [ "$FORCE_CLEAN" = "1" ]; then
    for d in $PRESERVE_DIRS; do
      [ -d "$DEST/$d" ] && echo "  destroying $d ($(du -sh "$DEST/$d" 2>/dev/null | cut -f1))"
    done
  else
    for d in $PRESERVE_DIRS; do
      if [ -d "$DEST/$d" ]; then
        echo "  preserving $d ($(du -sh "$DEST/$d" 2>/dev/null | cut -f1))"
        mv "$DEST/$d" "$STASH/$d"
      fi
    done
  fi
fi

rm -rf "$DEST"
mkdir -p "$DEST"
tar xz -C "$DEST"

# Restore droplet-produced data. -n so anything the archive shipped (tracked files) wins;
# untracked campaign output, which exists only here, is copied back untouched.
for d in $PRESERVE_DIRS; do
  if [ -d "$STASH/$d" ]; then
    mkdir -p "$DEST/$d"
    cp -rn "$STASH/$d/." "$DEST/$d/" 2>/dev/null || true
    echo "  restored $d"
  fi
done

cd "$DEST"
find . -name "*.sh" -exec chmod +x {} +
printf '%s\n' "$FULL_SHA" > .synced-commit-sha
echo "synced into $DEST"
REMOTE
echo "done ($SHA)"
