#!/usr/bin/env bash
# sync-repo.sh — Ship the repo (git HEAD archive) to a droplet at ~/exeris-benchmarks.
# Avoids needing GitHub auth on the droplet; commit local changes before syncing.
#
# Usage:
#   ./tools/cloud/do/sync-repo.sh bench@<droplet-ip> [--force-clean]
#
# DATA SAFETY — read before editing (2026-07-20)
# ----------------------------------------------
# This script has destroyed measurements twice. Both failure modes are guarded now; do not
# reintroduce either.
#
#   1. It used to `rm -rf ~/exeris-benchmarks` before extracting. Correct for code,
#      catastrophic for measurements: campaign output under results/ is produced ON the
#      droplet and is not in git until committed, so a routine code sync deleted ~5.6 GB of
#      finished runs. Data directories are now moved aside and restored around the extract.
#
#   2. The first attempt at that fix was worse. The remote script was fed over a heredoc
#      while stdin already carried the tarball, so `tar` read the script text and failed —
#      AFTER the data had been moved aside — and an EXIT trap then deleted the stash. A
#      cleanup trap that removes preserved data on the error path is worse than no
#      preservation at all.
#
# Invariants that keep this safe:
#   - stdin belongs to the tarball. The remote script travels as a base64 argument, never
#     over stdin.
#   - the stash is deleted ONLY after a verified successful restore. On any failure the
#     data is restored in place, and if even that fails the stash path is printed and left
#     on disk for manual recovery.
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

# Directories holding droplet-produced data rather than repo content.
PRESERVE_DIRS="results quarantine"

if ! git -C "$ROOT" diff --quiet HEAD 2>/dev/null; then
  echo "WARNING: uncommitted changes exist — only committed HEAD ($SHA) is synced." >&2
fi

# git-ignored files under config paths are invisible to `git add -A` AND to `git status`,
# so they never reach the droplet and the sync still reports success. Name them.
IGNORED_CONFIG="$(git -C "$ROOT" ls-files --others --ignored --exclude-standard \
  -- runtime/drivers/env scenarios micro/jmh/src 2>/dev/null || true)"
if [ -n "$IGNORED_CONFIG" ]; then
  echo "WARNING: these files are git-ignored and will NOT be shipped:" >&2
  printf '%s\n' "$IGNORED_CONFIG" | sed 's/^/    /' >&2
  echo "         If a target needs one, force-add it:  git add -f <path>" >&2
fi

REMOTE_SCRIPT=$(cat <<'EOS'
set -uo pipefail
DEST="$HOME/exeris-benchmarks"
STASH=""

restore_and_die() {
  local msg="$1"
  echo "ERROR: $msg" >&2
  if [ -n "$STASH" ] && [ -d "$STASH" ]; then
    echo "  restoring preserved data from $STASH ..." >&2
    mkdir -p "$DEST"
    local failed=0
    for d in $PRESERVE_DIRS; do
      if [ -d "$STASH/$d" ]; then
        mkdir -p "$DEST/$d"
        cp -rn "$STASH/$d/." "$DEST/$d/" 2>/dev/null || failed=1
      fi
    done
    if [ "$failed" = "0" ]; then
      rm -rf "$STASH"
      echo "  preserved data restored." >&2
    else
      echo "  RESTORE INCOMPLETE — data left at: $STASH  (do not delete it)" >&2
    fi
  fi
  exit 1
}

if [ -d "$DEST" ] && [ "$FORCE_CLEAN" != "1" ]; then
  STASH="$(mktemp -d "${TMPDIR:-/tmp}/exeris-sync-preserve.XXXXXX")" || exit 1
  for d in $PRESERVE_DIRS; do
    if [ -d "$DEST/$d" ]; then
      echo "  preserving $d ($(du -sh "$DEST/$d" 2>/dev/null | cut -f1))"
      mv "$DEST/$d" "$STASH/$d" || restore_and_die "could not move $d aside"
    fi
  done
elif [ -d "$DEST" ] && [ "$FORCE_CLEAN" = "1" ]; then
  for d in $PRESERVE_DIRS; do
    [ -d "$DEST/$d" ] && echo "  --force-clean: destroying $d ($(du -sh "$DEST/$d" 2>/dev/null | cut -f1))"
  done
fi

rm -rf "$DEST" || restore_and_die "could not clear $DEST"
mkdir -p "$DEST" || restore_and_die "could not create $DEST"

# stdin is the tarball. If this fails the archive never arrived; restore and abort.
tar xz -C "$DEST" || restore_and_die "tar extract failed (archive did not arrive on stdin)"

# Sanity-check the extract before trusting it enough to drop the stash.
[ -f "$DEST/CLAUDE.md" ] || restore_and_die "extract looks empty (CLAUDE.md missing)"

restore_failed=0
for d in $PRESERVE_DIRS; do
  if [ -n "$STASH" ] && [ -d "$STASH/$d" ]; then
    mkdir -p "$DEST/$d"
    # -n so anything the archive shipped (tracked files) wins; only droplet-produced
    # files are carried over.
    cp -rn "$STASH/$d/." "$DEST/$d/" 2>/dev/null || restore_failed=1
    echo "  restored $d"
  fi
done

if [ -n "$STASH" ]; then
  if [ "$restore_failed" = "0" ]; then
    rm -rf "$STASH"
  else
    echo "  WARNING: restore incomplete — data left at: $STASH  (do not delete it)" >&2
  fi
fi

cd "$DEST" || exit 1
find . -name "*.sh" -exec chmod +x {} +
printf '%s\n' "$FULL_SHA" > .synced-commit-sha
echo "synced into $DEST"
EOS
)

REMOTE_B64="$(printf '%s' "$REMOTE_SCRIPT" | base64 | tr -d '\n')"

echo "syncing $SHA -> $HOST:~/exeris-benchmarks"
if [ "$FORCE_CLEAN" = "1" ]; then
  echo "  --force-clean: droplet data directories ($PRESERVE_DIRS) WILL BE DESTROYED"
else
  echo "  preserving droplet data directories: $PRESERVE_DIRS"
fi

# Force LF in the archive: on Windows core.autocrlf=true would smudge shell scripts to
# CRLF, which breaks bash on the droplet (set: pipefail: invalid).
#
# The remote script arrives base64-encoded as part of the COMMAND, decoded to a temp file
# and run from there — stdin stays reserved for the tarball. Feeding the script over stdin
# is what broke this before.
git -C "$ROOT" -c core.autocrlf=false -c core.eol=lf archive --format=tar.gz HEAD \
  | ssh -o StrictHostKeyChecking=accept-new "$HOST" \
      "set -e; _s=\$(mktemp); printf %s '$REMOTE_B64' | base64 -d > \"\$_s\"; \
       FULL_SHA='$FULL_SHA' PRESERVE_DIRS='$PRESERVE_DIRS' FORCE_CLEAN='$FORCE_CLEAN' \
       bash \"\$_s\"; _rc=\$?; rm -f \"\$_s\"; exit \$_rc"
echo "done ($SHA)"
