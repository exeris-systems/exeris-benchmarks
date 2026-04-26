#!/usr/bin/env bash
set -u

bench_print_run_summary() {
  local run_metadata_json="${1:-}"
  local k6_summary_json="${2:-}"
  local resource_metrics_json="${3:-}"

  local scenario_id="n/a"  contract_id="n/a" tier="n/a" family="n/a"
  local claim_scope="n/a"  commit_sha="n/a"  output_dir="n/a"
  local protocol_mode="n/a"   protocol_mode_declared="n/a"
  local protocol_mode_observed="n/a"  protocol_mode_observed_k6="n/a"
  local transport_mode="n/a"
  local jfr_enabled="false"  jfr_file=""
  local target_app="n/a"  graph_track="n/a"  hardware_profile="n/a"
  local k6_exit_code="n/a"

  if [[ -f "$run_metadata_json" ]] && command -v jq >/dev/null 2>&1; then
    scenario_id="$(            jq -r '.scenario_id             // "n/a"' "$run_metadata_json" 2>/dev/null || echo "n/a")"
    contract_id="$(            jq -r '.contract_id             // "n/a"' "$run_metadata_json" 2>/dev/null || echo "n/a")"
    tier="$(                   jq -r '.tier                    // "n/a"' "$run_metadata_json" 2>/dev/null || echo "n/a")"
    family="$(                 jq -r '.benchmark_family // .family // "n/a"' "$run_metadata_json" 2>/dev/null || echo "n/a")"
    claim_scope="$(            jq -r '.claim_scope             // "n/a"' "$run_metadata_json" 2>/dev/null || echo "n/a")"
    commit_sha="$(             jq -r '.commit_sha              // "n/a"' "$run_metadata_json" 2>/dev/null || echo "n/a")"
    output_dir="$(             jq -r '.output_dir              // "n/a"' "$run_metadata_json" 2>/dev/null || echo "n/a")"
    protocol_mode="$(          jq -r '.protocol_mode           // "n/a"' "$run_metadata_json" 2>/dev/null || echo "n/a")"
    protocol_mode_declared="$( jq -r '.protocol_mode_declared  // "n/a"' "$run_metadata_json" 2>/dev/null || echo "n/a")"
    protocol_mode_observed="$( jq -r '.protocol_mode_observed  // "n/a"' "$run_metadata_json" 2>/dev/null || echo "n/a")"
    protocol_mode_observed_k6="$(jq -r '.protocol_mode_observed_k6 // "n/a"' "$run_metadata_json" 2>/dev/null || echo "n/a")"
    transport_mode="$(         jq -r '.transport_mode          // "n/a"' "$run_metadata_json" 2>/dev/null || echo "n/a")"
    jfr_enabled="$(            jq -r '.jfr_enabled             // false' "$run_metadata_json" 2>/dev/null || echo "false")"
    jfr_file="$(               jq -r '.jfr_file                // ""'   "$run_metadata_json" 2>/dev/null || echo "")"
    target_app="$(             jq -r '.target_app              // "n/a"' "$run_metadata_json" 2>/dev/null || echo "n/a")"
    graph_track="$(            jq -r '.graph_track             // "n/a"' "$run_metadata_json" 2>/dev/null || echo "n/a")"
    hardware_profile="$(       jq -r '.hardware_profile // "n/a"'        "$run_metadata_json" 2>/dev/null || echo "n/a")"
    k6_exit_code="$(           jq -r '.k6_exit_code    // "n/a"'        "$run_metadata_json" 2>/dev/null || echo "n/a")"
  fi

  local p99="n/a" p95="n/a" error_pct="n/a"
  local saga_rate="" saga_404="" saga_comp="" orders_s=""

  if [[ -f "$k6_summary_json" ]] && command -v jq >/dev/null 2>&1; then
    local raw_p99 raw_p95 raw_rate raw_saga raw_404 raw_comp raw_orders
    raw_p99="$(    jq -r '.metrics.http_req_duration["p(99)"]          // empty' "$k6_summary_json" 2>/dev/null || true)"
    raw_p95="$(    jq -r '.metrics.http_req_duration["p(95)"]          // empty' "$k6_summary_json" 2>/dev/null || true)"
    raw_rate="$(   jq -r '.metrics.http_req_failed.value               // empty' "$k6_summary_json" 2>/dev/null || true)"
    raw_saga="$(   jq -r '.metrics.saga_success.value                  // empty' "$k6_summary_json" 2>/dev/null || true)"
    raw_404="$(    jq -r '.metrics.saga_poll_404_exhausted.count        // empty' "$k6_summary_json" 2>/dev/null || true)"
    raw_comp="$(   jq -r '.metrics.saga_compensated.value              // empty' "$k6_summary_json" 2>/dev/null || true)"
    raw_orders="$( jq -r '.metrics.orders_initiated.rate               // empty' "$k6_summary_json" 2>/dev/null || true)"

    [[ -n "$raw_p99"    ]] && p99="$(      awk -v v="$raw_p99"    'BEGIN { printf "%.2f", v }')"
    [[ -n "$raw_p95"    ]] && p95="$(      awk -v v="$raw_p95"    'BEGIN { printf "%.2f", v }')"
    [[ -n "$raw_rate"   ]] && error_pct="$(awk -v v="$raw_rate"   'BEGIN { printf "%.2f", v * 100 }')"
    [[ -n "$raw_saga"   ]] && saga_rate="$(awk -v v="$raw_saga"   'BEGIN { printf "%.2f", v * 100 }')"
    [[ -n "$raw_404"    ]] && saga_404="$raw_404"
    [[ -n "$raw_comp"   ]] && saga_comp="$(awk -v v="$raw_comp"   'BEGIN { printf "%.2f", v * 100 }')"
    [[ -n "$raw_orders" ]] && orders_s="$( awk -v v="$raw_orders" 'BEGIN { printf "%.2f", v }')"
  fi

  local peak_rss_mb="n/a" cpu_s="n/a" cpu_util="n/a"

  if [[ -f "$resource_metrics_json" ]] && command -v jq >/dev/null 2>&1; then
    local raw_rss raw_cpu raw_util
    raw_rss="$(  jq -r '.peak_rss_kb                    // empty' "$resource_metrics_json" 2>/dev/null || true)"
    raw_cpu="$(  jq -r '.cpu_time_seconds               // empty' "$resource_metrics_json" 2>/dev/null || true)"
    raw_util="$( jq -r '.cpu_util_percent_of_one_core   // empty' "$resource_metrics_json" 2>/dev/null || true)"
    [[ -n "$raw_rss"  ]] && peak_rss_mb="$(awk -v v="$raw_rss"  'BEGIN { printf "%.1f", v / 1024 }')"
    [[ -n "$raw_cpu"  ]] && cpu_s="$(       awk -v v="$raw_cpu"  'BEGIN { printf "%.2f", v }')"
    [[ -n "$raw_util" ]] && cpu_util="$(    awk -v v="$raw_util" 'BEGIN { printf "%.2f", v }')"
  fi

  local jfr_status
  if [[ "$jfr_enabled" == "true" ]]; then
    if [[ -n "$jfr_file" && -f "$jfr_file" ]]; then
      jfr_status="collected"
    else
      jfr_status="not captured"
    fi
  else
    jfr_status="disabled"
  fi

  local scope_msg
  case "$claim_scope" in
    exploratory)         scope_msg="Not eligible for comparative claims. Promote to guard run on perf-box-amd64." ;;
    guard)               scope_msg="Guard run. Eligible for regression comparison on matching hardware." ;;
    comparison-eligible) scope_msg="Eligible for comparative claims." ;;
    *)                   scope_msg="Scope unknown - verify before publishing." ;;
  esac

  local sep="=============================================================="
  local thin="--------------------------------------------------------------"

  printf '%s\n' "$sep"
  printf '  Run Summary  ·  %s\n' "$scenario_id"
  printf '%s\n' "$sep"
  printf '  %-14s : %-28s [%s | %s]\n' "Scenario"    "$scenario_id" "$tier" "$family"
  printf '  %-14s : %s\n'              "Contract"    "$contract_id"
  printf '  %-14s : %-20s | graph: %s\n' "Target app" "$target_app" "$graph_track"
  printf '  %-14s : %s\n'              "Profile"     "$hardware_profile"
  printf '  %-14s : %s\n'              "Claim scope" "$claim_scope"
  printf '  %-14s : %s\n'              "Commit"      "$commit_sha"
  printf '  %-14s : %s  (declared: %s  observed-curl: %s  observed-k6: %s)\n' \
    "Protocol" "$protocol_mode" "$protocol_mode_declared" \
    "$protocol_mode_observed" "$protocol_mode_observed_k6"
  printf '  %-14s : %s\n' "Transport" "$transport_mode"
  printf '%s\n' "$thin"
  printf '  %-14s : %s ms\n'  "k6 p99"     "$p99"
  printf '  %-14s : %s ms\n'  "k6 p95"     "$p95"
  printf '  %-14s : %s%%\n'   "Error rate" "$error_pct"
  [[ -n "$saga_rate" ]] && \
    printf '  %-14s : %s%%    (metric: saga_success_rate)\n'      "Saga success"  "$saga_rate"
  [[ -n "$saga_comp" ]] && \
    printf '  %-14s : %s%%    (metric: saga_compensated)\n'       "Saga comp."    "$saga_comp"
  [[ -n "$saga_404" ]] && \
    printf '  %-14s : %s     (metric: saga_poll_404_exhausted)\n' "404 exhausted" "$saga_404"
  [[ -n "$orders_s" ]] && \
    printf '  %-14s : %s     (metric: orders_initiated)\n'        "Orders/s"      "$orders_s"
  printf '  %-14s : %s\n' "k6 exit code" "$k6_exit_code"
  printf '%s\n' "$thin"
  printf '  %-14s : %s MB\n' "Peak RSS"  "$peak_rss_mb"
  printf '  %-14s : %s s\n'  "CPU time"  "$cpu_s"
  printf '  %-14s : %s %%   (of one core)\n' "CPU util"  "$cpu_util"
  printf '  %-14s : %s\n'    "JFR"       "$jfr_status"
  printf '%s\n' "$thin"
  printf '  %-14s : %s\n' "Output" "$output_dir"
  printf '%s\n' "$sep"
  printf '  NOTICE: claim_scope=%s - %s\n' "$claim_scope" "$scope_msg"
  printf '%s\n' "$sep"

  return 0
}
