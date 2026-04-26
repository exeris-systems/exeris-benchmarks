#!/usr/bin/env bash
# Helper functions for output path management
set -u

# get_stem(log_file) — extract stem (filename without .log extension)
get_stem() {
  local log_file="$1"
  echo "${log_file%.log}"
}

# generate_output_root(base_path) — create timestamp-based root directory path with mode suffix
generate_output_root() {
  local base_path="$1"
  local timestamp
  local mode_suffix
  timestamp="$(date +%Y%m%d-%H%M%S)"
  mode_suffix="${MODE:-all}"
  echo "${base_path}/${timestamp}-${mode_suffix}"
}

# ensure_output_dirs(base_dir) — recursively create output directories
ensure_output_dirs() {
  local base_dir="$1"
  mkdir -p "$base_dir" || {
    echo "ERROR: Unable to create output directory: $base_dir" >&2
    return 1
  }
}

# get_artifact_paths(stem) — return JSON object with all artifact paths for a benchmark
# Example: get_artifact_paths "results/baseline/B6" 
#   => {"log":".../B6.log", "json":".../B6-jmh.json", "jfr":".../B6.jfr", ...}
get_artifact_paths() {
  local stem="$1"
  local log="${stem}.log"
  local json="${stem}-jmh.json"
  local jfr="${stem}.jfr"
  local metrics="${stem}-metrics.json"
  local cmd="${stem}.cmd"
  local jvm_args="${stem}.jvm-args.txt"
  local status="${stem}.status.json"
  local reproducibility="${stem}.reproducibility-metadata.json"

  cat <<EOF
{
  "log": "$log",
  "json": "$json",
  "jfr": "$jfr",
  "metrics": "$metrics",
  "cmd": "$cmd",
  "jvm_args": "$jvm_args",
  "status": "$status",
  "reproducibility_metadata": "$reproducibility"
}
EOF
}
