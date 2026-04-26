#!/usr/bin/env bash
# Portable filesystem helpers for GNU/BSD stat differences.
set -u

# portable_stat_size(path) -> file size in bytes, or 0 when unavailable.
portable_stat_size() {
  local path="$1"
  stat -c%s "$path" 2>/dev/null || stat -f%z "$path" 2>/dev/null || echo 0
}

# portable_stat_mtime(path) -> file mtime epoch seconds, or 0 when unavailable.
portable_stat_mtime() {
  local path="$1"
  stat -c%Y "$path" 2>/dev/null || stat -f%m "$path" 2>/dev/null || echo 0
}

# Backward-compatible aliases.
stat_size() {
  portable_stat_size "$1"
}

stat_mtime() {
  portable_stat_mtime "$1"
}
