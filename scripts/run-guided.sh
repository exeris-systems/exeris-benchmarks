#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: run-guided.sh [--profile-out <path>] [--execute] [--no-execute]

Interactive guided launcher for local and WAN benchmark runs.
Community track only (H1/H2); H3 and the Enterprise tier have separate tooling.

  - menu-driven selection of: connectivity (local / WAN-remote / WAN-impaired),
    scenario, load driver, target app(s), runtime env file, hardware profile,
    protocol (H1/H2), pure/compat classification, workload and fairness intent
  - captures benchmark metadata and run intent into guided-run-profile.json
  - validates the profile via runtime/drivers/validate-guided-profile.sh
  - optionally dispatches the matching run script:
      * multi-target               -> run-comparative.sh
      * entity-read-by-id (local)  -> run-entity-read-by-id.sh
      * e2e-shop-order-saga        -> run-e2e-shop-order-saga-baseline.sh
      * any scenario + a load      -> run-wrk.sh / run-wrk2.sh / run-k6.sh /
        driver (wrk/wrk2/k6/h2load)   run-h2load.sh (local or WAN endpoint)

Connectivity modes:
  local         loopback, clean path; target launched locally
  wan-remote    target reachable over the network at a remote host:port
  wan-impaired  controlled tc netem impairment (delay/loss/jitter), loopback
                or remote; impairment parameters are captured into the profile
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo "[guided] $*"
}

warn() {
  echo "WARN: $*"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VALIDATOR_SCRIPT="${REPO_ROOT}/runtime/drivers/validate-guided-profile.sh"
TARGET_MATRIX="${REPO_ROOT}/runtime/drivers/target-asset-matrix.json"
ENV_DIR="${REPO_ROOT}/runtime/drivers/env"
EXEC_PROFILES_JSON="${REPO_ROOT}/runtime/profiles/runtime-execution-profiles.json"

# topology_mode values (mirror the guided-run-profile schema enum).
readonly TOPOLOGY_LOCAL="localhost"
readonly TOPOLOGY_NETWORK="network"

PROFILE_OUT=""
EXECUTE_MODE="ask"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile-out)
      PROFILE_OUT="$2"
      shift 2
      ;;
    --execute)
      EXECUTE_MODE="yes"
      shift
      ;;
    --no-execute)
      EXECUTE_MODE="no"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

if [[ ! -x "$VALIDATOR_SCRIPT" ]]; then
  fail "Validator script not executable: $VALIDATOR_SCRIPT"
fi

if ! command -v jq >/dev/null 2>&1; then
  fail "jq is required by run-guided.sh"
fi

[[ -f "$TARGET_MATRIX" ]] || fail "Target asset matrix not found: $TARGET_MATRIX"

# ---------------------------------------------------------------------------
# Prompt helpers
# ---------------------------------------------------------------------------

choose_option() {
  local prompt="$1"
  local default="$2"
  shift 2
  local options=("$@")
  local value=""

  while true; do
    read -r -p "$prompt [$default]: " value || true
    value="${value:-$default}"
    for opt in "${options[@]}"; do
      if [[ "$value" == "$opt" ]]; then
        printf '%s\n' "$value"
        return 0
      fi
    done
    echo "Invalid value '$value'. Allowed: ${options[*]}" >&2
  done
}

# select_kv <prompt> <default-value> <val1> <label1> [<val2> <label2> ...]
# Renders a numbered menu (to stderr) and prints the chosen value (to stdout).
select_kv() {
  local prompt="$1"
  local default="$2"
  shift 2
  local -a vals=()
  local -a labels=()
  local val label
  while [[ $# -gt 0 ]]; do
    val="$1"
    label="${2:-$1}"
    vals+=("$val")
    labels+=("$label")
    shift 2
  done

  local n="${#vals[@]}"
  [[ "$n" -ge 1 ]] || fail "select_kv called with no options ($prompt)"

  local i default_idx=1
  for ((i = 0; i < n; i++)); do
    if [[ "${vals[i]}" == "$default" ]]; then
      default_idx=$((i + 1))
    fi
  done

  {
    printf '\n%s\n' "$prompt"
    for ((i = 0; i < n; i++)); do
      printf '  %2d) %s\n' "$((i + 1))" "${labels[i]}"
    done
  } >&2

  local choice
  while true; do
    read -r -p "  -> choose 1-${n} [${default_idx}]: " choice || true
    choice="${choice:-$default_idx}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )); then
      printf '%s\n' "${vals[choice - 1]}"
      return 0
    fi
    echo "  invalid selection '$choice' (enter 1-${n})" >&2
  done
}

prompt_text() {
  local prompt="$1"
  local default="$2"
  local value=""
  read -r -p "$prompt [$default]: " value || true
  value="${value:-$default}"
  printf '%s\n' "$value"
}

prompt_positive_int() {
  local prompt="$1"
  local default="$2"
  local value=""
  while true; do
    read -r -p "$prompt [$default]: " value || true
    value="${value:-$default}"
    if [[ "$value" =~ ^[0-9]+$ ]] && [[ "$value" -ge 1 ]]; then
      printf '%s\n' "$value"
      return 0
    fi
    echo "Invalid value '$value'. Enter an integer >= 1." >&2
  done
}

prompt_number() {
  local prompt="$1"
  local default="$2"
  local value=""
  while true; do
    read -r -p "$prompt [$default]: " value || true
    value="${value:-$default}"
    if [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      printf '%s\n' "$value"
      return 0
    fi
    echo "Invalid number '$value'. Enter a non-negative number." >&2
  done
}

prompt_nonneg_int() {
  local prompt="$1"
  local default="$2"
  local value=""
  while true; do
    read -r -p "$prompt [$default]: " value || true
    value="${value:-$default}"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$value"
      return 0
    fi
    echo "Invalid value '$value'. Enter an integer >= 0." >&2
  done
}

tool_version_or_unknown() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf '%s\n' "unknown"
    return 0
  fi

  local line="unknown"
  case "$tool" in
    jq)     line="$(jq --version 2>/dev/null | head -n1 || true)" ;;
    k6)     line="$(k6 version 2>/dev/null | head -n1 || true)" ;;
    wrk)    line="$(wrk --version 2>/dev/null | head -n1 || true)" ;;
    wrk2)   line="$(wrk2 --version 2>/dev/null | head -n1 || true)" ;;
    h2load) line="$(h2load --version 2>/dev/null | head -n1 || true)" ;;
    docker) line="$(docker --version 2>/dev/null | head -n1 || true)" ;;
    tc)     line="$(tc -V 2>/dev/null | head -n1 || true)" ;;
    *)      line="unknown" ;;
  esac

  line="${line//$'\r'/}"
  if [[ -z "$line" ]]; then
    line="unknown"
  fi
  printf '%s\n' "$line"
}

map_entity_runtime() {
  local target="$1"
  case "$target" in
    # Spring-on-Exeris (Compat Mode) must be matched BEFORE the generic *spring*
    # rule, otherwise it collapses onto the Tomcat/Axon spring-benchmark-app.
    *spring-runtime-on-exeris*|*spring-on-exeris*) printf '%s\n' "spring-runtime-on-exeris" ;;
    *spring*) printf '%s\n' "spring" ;;
    *quarkus*) printf '%s\n' "quarkus" ;;
    *locality*) printf '%s\n' "locality" ;;
    *community*|*enterprise*|*exeris*) printf '%s\n' "community" ;;
    *) printf '%s\n' "auto" ;;
  esac
}

map_entity_build() {
  local target="$1"
  case "$target" in
    *native*) printf '%s\n' "native" ;;
    *) printf '%s\n' "jvm" ;;
  esac
}

map_entity_backend_mode() {
  local target="$1"
  case "$target" in
    *locality*) printf '%s\n' "locality-aware" ;;
    *) printf '%s\n' "default-vt" ;;
  esac
}

# Pure vs Compatibility is an Exeris-runtime axis that is authoritatively implied
# by the target — NOT a free choice. Deriving it (instead of asking) mirrors how
# protocol_mode is handled: it stops the profile from claiming a classification
# the target does not have (e.g. the menu default "pure" was stamping the plain
# Spring/Tomcat and Quarkus baselines as "pure-mode Exeris", which is false).
#   - spring-runtime-on-exeris → compat  (Exeris compatibility mode)
#   - community / locality     → pure    (Exeris pure mode, kernel-native API)
#   - spring (Tomcat) / quarkus → baseline (not an Exeris runtime at all)
derive_target_classification() {
  case "$(map_entity_runtime "$1")" in
    spring-runtime-on-exeris) printf '%s\n' "compat" ;;
    community|locality)       printf '%s\n' "pure" ;;
    spring|quarkus)           printf '%s\n' "baseline" ;;
    *)                        printf '%s\n' "pure" ;;
  esac
}

# Best-effort target directory (used only to locate optional per-target driver
# config; base URL is supplied via *_BASE_URL_OVERRIDE for guided dispatch).
map_target_dir() {
  local tid="$1"
  local dir
  case "$tid" in
    # Spring-on-Exeris (Compat Mode) lives in its own module; match it before the
    # generic spring* rule so it is not mapped onto the Tomcat/Axon spring app.
    spring-runtime-on-exeris*|spring-on-exeris*) dir="targets/exeris-spring-runtime-app-comp" ;;
    spring*)  dir="targets/spring-benchmark-app" ;;
    quarkus*) dir="targets/quarkus-benchmark-app" ;;
    *)        dir="targets/exeris-community-app" ;;
  esac
  if [[ -d "${REPO_ROOT}/${dir}" ]]; then
    printf '%s\n' "$dir"
  else
    printf '%s\n' "targets"
  fi
}

# scheme://host:port from a target's health_url in the asset matrix.
resolve_local_base_url() {
  local tid="$1" hu
  hu="$(jq -r --arg id "$tid" '.targets[] | select(.target_id == $id) | .health_url // empty' "$TARGET_MATRIX" 2>/dev/null || true)"
  if [[ -n "$hu" ]]; then
    printf '%s\n' "$hu" | sed -E 's#(https?://[^/]+).*#\1#'
  else
    printf '%s\n' "http://localhost:8080"
  fi
}

# --- TLS / transport-security helpers -------------------------------------
# TLS is ORTHOGONAL to protocol_mode (the H1/H2 axis). The toggle composes the
# two into the runner's BENCH_PROTOCOL_MODE_OVERRIDE space (h1/https-h1/h2/h2c).
# 'auto' keeps the target's matrix-declared scheme and does NOT override anything
# (byte-identical to the pre-toggle behavior); on/off take control of both the
# launched target's transport and the load client's scheme.

# scheme (http|https) a target declares via its health_url in the asset matrix.
resolve_target_declared_scheme() {
  local tid="$1" hu
  hu="$(jq -r --arg id "$tid" '.targets[] | select(.target_id == $id) | .health_url // empty' "$TARGET_MATRIX" 2>/dev/null || true)"
  case "$hu" in
    https://*) printf 'https\n' ;;
    *)         printf 'http\n' ;;
  esac
}

# Rewrite the scheme of a base URL (http<->https), leaving host:port intact.
apply_url_scheme() {
  local url="$1" scheme="$2"
  printf '%s\n' "$url" | sed -E "s#^https?://#${scheme}://#"
}

# Compose protocol_mode (h1/h2/h3) + TLS on/off into the runner transport label.
# h2 cleartext is h2c; h2 over TLS is h2; h1 plain is h1; h1 over TLS is https-h1.
# h3 always implies TLS and is left as-is (Enterprise-only; not reachable here).
derive_effective_transport() {
  local pm="$1" tls="$2"
  case "$pm" in
    h3) printf 'h3\n' ;;
    h2) [[ "$tls" == "true" ]] && printf 'h2\n' || printf 'h2c\n' ;;
    *)  [[ "$tls" == "true" ]] && printf 'https-h1\n' || printf 'h1\n' ;;
  esac
}

# Wire the chosen transport into the dispatch environment. No-op in 'auto' mode
# (so the pre-toggle code path is untouched). When on/off, export the kernel TLS
# switches (inherited by guided-launched targets via their `env … java` exec) and
# the canonical BENCH_PROTOCOL_MODE_OVERRIDE that the protocol lib honors first;
# provision a self-signed smoke cert for HTTPS unless the caller supplied one.
tls_cert_source=""
setup_tls_runtime_env() {
  [[ "$tls_mode" != "auto" ]] || return 0
  export BENCH_PROTOCOL_MODE_OVERRIDE="$effective_transport"
  if [[ "$tls_enabled" == "true" ]]; then
    export EXERIS_SSL_ENABLED="true"
    export EXERIS_INSECURE_REQUESTS="disabled"
    export BENCHMARK_TLS_ENABLED="1"
    if [[ -n "${EXERIS_TRANSPORT_CERT_PATH:-}" && -f "${EXERIS_TRANSPORT_CERT_PATH}" \
        && -n "${EXERIS_TRANSPORT_KEY_PATH:-}" && -f "${EXERIS_TRANSPORT_KEY_PATH}" ]]; then
      tls_cert_source="caller-provided"
      info "[TLS] using caller-provided cert: $EXERIS_TRANSPORT_CERT_PATH"
    else
      local certs_lib="$REPO_ROOT/tools/bench/lib/certs.sh"
      local cert="/tmp/exeris-bench-certs/smoke-cert.pem" key="/tmp/exeris-bench-certs/smoke-key.pem"
      if [[ -f "$certs_lib" ]] && command -v openssl >/dev/null 2>&1; then
        # shellcheck source=/dev/null
        source "$certs_lib"
        if ensure_smoke_cert_key "$cert" "$key"; then
          export EXERIS_TRANSPORT_CERT_PATH="$cert"
          export EXERIS_TRANSPORT_KEY_PATH="$key"
          tls_cert_source="auto-smoke"
          info "[TLS] smoke cert provisioned: $cert"
        else
          warn "[TLS] smoke cert provisioning failed; HTTPS target launch may fail. Set EXERIS_TRANSPORT_CERT_PATH/KEY_PATH manually."
        fi
      else
        warn "[TLS] openssl/certs.sh unavailable; set EXERIS_TRANSPORT_CERT_PATH/KEY_PATH manually for HTTPS."
      fi
    fi
  else
    export EXERIS_SSL_ENABLED="false"
    export EXERIS_INSECURE_REQUESTS="enabled"
    export BENCHMARK_TLS_ENABLED="0"
  fi
}

# Pick the e2e-shop-order-saga fixed contract for a (target, graph_track) pair,
# mirroring run-e2e-shop-order-saga-campaign.sh's _derive_contract_id.
derive_saga_contract() {
  local scenario_json="$1" target="$2" track="$3" cid
  cid="$(jq -r --arg gt "$track" --arg ta "$target" '
    (.graph_tracks[$gt].required_contracts // []) as $cids
    | $cids[] as $cid
    | if .fixed_contracts[$cid].target_app == $ta then $cid else empty end' \
    "$scenario_json" 2>/dev/null | head -1)"
  printf '%s\n' "${cid:-exeris_community_h2c_v1}"
}

# Authoritatively resolve protocol_mode (h1/h2/h3) rather than asking the user:
#   1. the chosen fixed contract's protocol_mode (contract-driven runs), else
#   2. the load driver (generic runs): wrk/wrk2 -> h1, h2load -> h2, else
#   3. the scenario's first declared transport.
# Contract transport "h2c" (h2 cleartext) maps to the h2 axis (the schema enum is
# h1/h2/h3); the precise transport stays the runner's concern.
resolve_protocol_mode() {
  local scenario_json="$1" contract_id="$2" driver="$3" p=""
  p="$(jq -r --arg c "$contract_id" '.fixed_contracts[$c].protocol_mode // empty' "$scenario_json" 2>/dev/null || true)"
  if [[ -z "$p" ]]; then
    case "$driver" in
      wrk|wrk2) p="h1" ;;
      h2load)   p="h2" ;;
      *) p="$(jq -r '(.transport // [])[0] // (.protocol_support // {} | keys[0]) // empty' "$scenario_json" 2>/dev/null || true)" ;;
    esac
  fi
  case "$p" in
    h2c) p="h2" ;;
    h1|h2|h3) ;;
    *) p="h1" ;;
  esac
  printf '%s\n' "$p"
}

# --- HTTP protocol-version toggle (auto/h1/h2) ----------------------------
# ORTHOGONAL to TLS. Unlike TLS (scheme lives in the URL and every client
# honors it), the HTTP version is decided by the load-client BINARY, not the
# URL — so an honest toggle must map h1/h2 onto a driver/axis the binary can
# actually speak, never a label-only override. Capability of this repo's
# drivers (verified): wrk/wrk2 are H1-only; h2load does H1 (--h1) and H2
# (h2c cleartext, or h2-over-TLS); k6 does H1 (http://) and H2 only over TLS
# (ALPN — no cleartext h2c).
driver_supports_protocol() {
  local d="$1" p="$2"
  case "$p" in
    h1) case "$d" in wrk|wrk2|h2load|k6) return 0 ;; *) return 1 ;; esac ;;
    h2) case "$d" in h2load|k6) return 0 ;; *) return 1 ;; esac ;;
    *)  return 1 ;;
  esac
}

# First scenario-declared driver that can speak $1, in a stable preference order
# (h2: h2load before k6 — h2load needs no TLS; h1: wrk before the rest). Empty if
# the scenario declares no capable driver. Reads the SCEN_DRIVERS global.
pick_driver_for_protocol() {
  local p="$1" pref cand d
  case "$p" in
    h2) pref="h2load k6" ;;
    *)  pref="wrk k6 h2load wrk2" ;;
  esac
  for cand in $pref; do
    for d in "${SCEN_DRIVERS[@]}"; do
      if [[ "$d" == "$cand" ]] && driver_supports_protocol "$cand" "$p"; then
        printf '%s\n' "$cand"; return 0
      fi
    done
  done
  return 1
}

# Is protocol $1 offerable for the current scenario? Honors a declared
# protocol_support[$1].status gate (runnable only), then requires at least one
# scenario-declared driver capable of it. Reads scenario_json + SCEN_DRIVERS.
protocol_choice_available() {
  local p="$1" st d
  st="$(jq -r --arg p "$p" '.protocol_support[$p].status // empty' "$scenario_json" 2>/dev/null || true)"
  [[ -z "$st" || "$st" == "runnable" ]] || return 1
  for d in "${SCEN_DRIVERS[@]}"; do
    driver_supports_protocol "$d" "$p" && return 0
  done
  return 1
}

# Apply a forced protocol choice (proto_mode != auto). Mutates the globals
# protocol_mode and (if needed) driver; fails closed on an impossible combo.
# Reads: proto_mode, scenario_json, scenario_id, driver, target_mode, SCEN_DRIVERS.
validate_and_apply_protocol() {
  local proto="$proto_mode" st reason backlog new_driver

  # Comparative is H1-only by construction: run-comparative.sh hits a hardcoded
  # http:// endpoint and validates a shared protocol_mode. Forcing h2 there would
  # be a label-only claim — reject it rather than mint a false comparison.
  if [[ "$target_mode" == "multi" && "$proto" == "h2" ]]; then
    fail "Protocol override 'h2' is not available for comparative (multi-target) runs: run-comparative.sh drives both targets over cleartext HTTP/1.1 and validates a shared protocol_mode, so h2 would be a label-only claim. Run single-target h2 baselines instead."
  fi

  # Scenario-declared protocol_support gate (when present): not-runnable /
  # not-applicable protocols carry a reason + backlog ref — surface them.
  st="$(jq -r --arg p "$proto" '.protocol_support[$p].status // empty' "$scenario_json" 2>/dev/null || true)"
  if [[ -n "$st" && "$st" != "runnable" ]]; then
    reason="$(jq -r --arg p "$proto" '.protocol_support[$p].reason // "not declared runnable"' "$scenario_json" 2>/dev/null || true)"
    backlog="$(jq -r --arg p "$proto" '.protocol_support[$p].backlog_ref // empty' "$scenario_json" 2>/dev/null || true)"
    fail "Scenario '$scenario_id' declares protocol '$proto' as '$st': ${reason}${backlog:+ (backlog: $backlog)}. Pick a runnable protocol or a different scenario."
  fi

  # Map the protocol onto a capable driver. If the selected driver can't speak it,
  # switch to the scenario's declared capable driver (or fail if none exists).
  if ! driver_supports_protocol "$driver" "$proto"; then
    new_driver="$(pick_driver_for_protocol "$proto" || true)"
    if [[ -z "$new_driver" ]]; then
      fail "No load driver can speak '$proto' for scenario '$scenario_id' (declared drivers: ${SCEN_DRIVERS[*]:-none}; selected '$driver' is ${proto}-incapable)."
    fi
    warn "Driver '$driver' cannot speak $proto; switching to '$new_driver' (the scenario's $proto-capable driver)."
    driver="$new_driver"
  fi

  protocol_mode="$proto"
}

# On contract-driven paths the contract — not the user — fixes the workload
# (constrained reads it from the contract JSON; fixed_contract_v1 enforces threads
# and rejects --duration; saga uses VUs/think-time). Read the contract's workload
# so the recorded/displayed values match what actually runs. Prints:
#   "<threads> <connections> <warmup_seconds> <measurement_seconds>"
resolve_workload_from_contract() {
  local sj="$1" cid="$2" c t cn w m
  c="$(jq -c --arg id "$cid" '.fixed_contracts[$id] // {}' "$sj" 2>/dev/null || echo '{}')"
  t="$(jq -r '.threads // empty' <<<"$c" 2>/dev/null)"
  cn="$(jq -r '.connections // empty' <<<"$c" 2>/dev/null)"
  w="$(jq -r '(.warmup_seconds // (.warmup|tostring|gsub("s$";"")|select(test("^[0-9]+$")))) // empty' <<<"$c" 2>/dev/null)"
  m="$(jq -r '(.duration_seconds // .measurement_window_seconds // (.duration|tostring|gsub("s$";"")|select(test("^[0-9]+$")))) // empty' <<<"$c" 2>/dev/null)"
  printf '%s %s %s %s\n' "${t:-4}" "${cn:-128}" "${w:-60}" "${m:-120}"
}

# ---------------------------------------------------------------------------
# Discovery: scenarios, targets, env files
# ---------------------------------------------------------------------------

readarray -t SCENARIO_IDS < <(find "$REPO_ROOT/scenarios" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
[[ "${#SCENARIO_IDS[@]}" -gt 0 ]] || fail "No scenarios found under $REPO_ROOT/scenarios"

readarray -t TARGET_IDS < <(jq -r '.targets[].target_id' "$TARGET_MATRIX" 2>/dev/null | sort)
[[ "${#TARGET_IDS[@]}" -gt 0 ]] || fail "No targets found in $TARGET_MATRIX"

readarray -t ENV_FILE_NAMES < <(find "$ENV_DIR" -maxdepth 1 -type f -name '*.env' -printf '%f\n' 2>/dev/null | sort || true)

echo "=== Exeris guided benchmark launcher ==="

# ---------------------------------------------------------------------------
# Run intent + connectivity
# ---------------------------------------------------------------------------

run_type="$(select_kv "Run type" "exploratory" \
  guard       "guard       — gating/smoke probe" \
  regression  "regression  — baseline-tracked run" \
  exploratory "exploratory — descriptive investigation")"

connectivity="$(select_kv "Connectivity / topology" "local" \
  local        "local        — loopback, clean path, target launched locally" \
  wan-remote   "wan-remote   — target over the network at a remote host:port" \
  wan-impaired "wan-impaired — tc netem delay/loss/jitter (loopback or remote)")"

# Connectivity -> topology_mode (schema) + impairment intent.
topology_mode="$TOPOLOGY_LOCAL"
impairment_enabled="false"
applied_to=""
imp_profile=""
apply_netem="no"
delay_ms=0
loss_pct=0
jitter_ms=0

app_endpoint=""
db_endpoint=""
health_path=""
launch_mode=""
runtime_mode=""

configure_impairment() {
  imp_profile="$(select_kv "Network impairment profile (tc netem)" "moderate" \
    mild     "mild     — 5ms delay / 0.1% loss / 1ms jitter" \
    moderate "moderate — 20ms delay / 1.0% loss / 5ms jitter" \
    severe   "severe   — 100ms delay / 5.0% loss / 20ms jitter" \
    custom   "custom   — enter values")"
  case "$imp_profile" in
    mild)     delay_ms=5;   loss_pct=0.1; jitter_ms=1 ;;
    moderate) delay_ms=20;  loss_pct=1.0; jitter_ms=5 ;;
    severe)   delay_ms=100; loss_pct=5.0; jitter_ms=20 ;;
    custom)
      delay_ms="$(prompt_nonneg_int "netem delay_ms" "20")"
      loss_pct="$(prompt_number "netem loss_pct" "1.0")"
      jitter_ms="$(prompt_nonneg_int "netem jitter_ms" "5")"
      ;;
    *) fail "unknown impairment profile: $imp_profile" ;;
  esac
  impairment_enabled="true"
}

case "$connectivity" in
  local)
    topology_mode="$TOPOLOGY_LOCAL"
    launch_mode="$(select_kv "Launch mode" "prebuild" \
      prebuild "prebuild — use the pre-built jar/binary" \
      build    "build    — build the target from source (mvn) first")"
    # runtime_mode (jvm/native) is derived from the chosen target, not asked.
    ;;
  wan-remote)
    topology_mode="$TOPOLOGY_NETWORK"
    ;;
  wan-impaired)
    applied_to="$(select_kv "Apply impairment to" "loopback" \
      loopback "loopback — tc netem on lo, target launched locally" \
      remote   "remote   — impairment lives on the path to a remote endpoint")"
    configure_impairment
    if [[ "$applied_to" == "loopback" ]]; then
      topology_mode="$TOPOLOGY_LOCAL"
      launch_mode="$(select_kv "Launch mode" "prebuild" \
        prebuild "prebuild — use the pre-built jar/binary" \
        build    "build    — build the target from source (mvn) first")"
      # runtime_mode (jvm/native) is derived from the chosen target, not asked.
      apply_netem="$(choose_option "Apply tc netem to loopback at dispatch (requires root)?" "no" yes no)"
    else
      topology_mode="$TOPOLOGY_NETWORK"
      warn "Impairment lives on the remote network path; the guided launcher will NOT apply tc netem locally."
    fi
    ;;
  *) fail "unknown connectivity: $connectivity" ;;
esac

if [[ "$topology_mode" == "$TOPOLOGY_NETWORK" ]]; then
  wan_scheme="$(select_kv "WAN scheme" "http" http "http" https "https")"
  wan_host="$(prompt_text "WAN target host" "10.0.0.10")"
  wan_port="$(prompt_positive_int "WAN target port" "8080")"
  health_path="$(prompt_text "Health path" "/health")"
  app_endpoint="${wan_scheme}://${wan_host}:${wan_port}"
  db_endpoint="$(prompt_text "db_endpoint (no inline credentials; use env/.pgpass)" "postgresql://${wan_host}:5432/benchmark")"
  warn "Network mode: ensure the remote target is launched with scenario-compatible configuration before execution."
fi

# ---------------------------------------------------------------------------
# Scenario + driver
# ---------------------------------------------------------------------------

scenario_kv=()
for s in "${SCENARIO_IDS[@]}"; do
  desc="$(jq -r '.description // ""' "$REPO_ROOT/scenarios/$s/scenario.json" 2>/dev/null | tr '\n' ' ' | cut -c1-60)"
  if [[ -n "$desc" ]]; then
    scenario_kv+=("$s" "$s — $desc")
  else
    scenario_kv+=("$s" "$s")
  fi
done
scenario_id="$(select_kv "Scenario" "entity-read-by-id" "${scenario_kv[@]}")"

scenario_json="$REPO_ROOT/scenarios/$scenario_id/scenario.json"

is_saga="no"
[[ "$scenario_id" == "e2e-shop-order-saga" ]] && is_saga="yes"

# Saga-specific axes / options (populated only for the saga scenario).
graph_track=""
saga_auto_start_infra="no"
saga_auto_start_target="no"
saga_skip_seed_verify="no"
enable_jfr="no"
# Opt-in steady-state / fairness diagnostics (default OFF — never perturb an
# existing run shape). os_sidecars => pidstat/mpstat sampling (BENCH_OS_SIDECARS);
# jfr_steady_state => merge env/jfr-steady-state.jfc (C2 compiler events) on top
# of the base JFR config (BENCH_JFR_STEADY_STATE, only meaningful when JFR is on).
enable_os_sidecars="no"
enable_jfr_steady_state="no"

# Drivers declared by the scenario, intersected with supported load drivers.
readarray -t SCEN_DRIVERS < <(jq -r '.driver[]?' "$scenario_json" 2>/dev/null || true)

if [[ "$is_saga" == "yes" ]]; then
  # Saga is k6-driven and dispatched via the dedicated saga runner; the generic
  # load-driver menu does not apply.
  driver="k6"
  graph_track="$(select_kv "Graph track (saga orchestration backend)" "neo4j" \
    neo4j      "neo4j      — Bolt graph backend (track_a)" \
    pgq_pure   "pgq_pure   — Postgres-graph PGQ, pure mode (track_b1)" \
    age_compat "age_compat — Postgres-graph Apache AGE, compat mode (track_b2)")"
else
  driver_kv=()
  for d in "${SCEN_DRIVERS[@]}"; do
    case "$d" in
      wrk|wrk2|k6|h2load) driver_kv+=("$d" "$d") ;;
      *) ;;  # non-HTTP-load drivers (radamsa/jazzer/slowloris) are not menu options
    esac
  done

  driver="none"
  if [[ "${#driver_kv[@]}" -gt 0 ]]; then
    driver_kv+=("none" "none — generate profile only (no auto-dispatch)")
    driver="$(select_kv "Load driver (auto-dispatch for non-specialized scenarios)" "${driver_kv[0]}" "${driver_kv[@]}")"
  else
    warn "Scenario '$scenario_id' declares no HTTP load driver (uses ${SCEN_DRIVERS[*]:-a specialized harness}); no generic dispatch available."
  fi
fi

# ---------------------------------------------------------------------------
# Execution class: unconstrained vs constrained (cgroup/affinity)
# Constrained is local-only, exploratory-only, single-target, never comparative.
# ---------------------------------------------------------------------------

execution_class="unconstrained"
execution_profile_id=""
cgroup_memory_limit_mb=""
cgroup_cpu_quota_pct=""
cpu_affinity=""
client_cpu_affinity=""
constrained_contract=""

if [[ "$topology_mode" == "$TOPOLOGY_LOCAL" ]]; then
  execution_class="$(select_kv "Execution class" "unconstrained" \
    unconstrained "unconstrained — no cgroup/affinity caps" \
    constrained   "constrained   — cgroup memory/CPU caps (exploratory-only, single-target, never comparative)")"
fi

# Optional target-bound measurement pinning (LOCAL + unconstrained). Pin the target and the load
# driver to DISJOINT cpusets so the target is the bottleneck and its CPU-efficiency shows as
# throughput — loopback co-location otherwise lets the driver steal the target's cores, making
# throughput unmeasurable. Leave the target cpuset empty to keep the current (unpinned) behaviour.
if [[ "$topology_mode" == "$TOPOLOGY_LOCAL" && "$execution_class" == "unconstrained" ]]; then
  cpu_affinity="$(prompt_text "Target CPU affinity cpuset for target-bound measurement (e.g. 0-2, empty = none)" "")"
  if [[ -n "$cpu_affinity" ]]; then
    client_cpu_affinity="$(prompt_text "Load-driver CPU affinity cpuset — keep DISJOINT from target (e.g. 3-9)" "")"
  fi
fi

if [[ "$execution_class" == "constrained" ]]; then
  case "$scenario_id" in
    entity-read-by-id|e2e-shop-order-saga) : ;;
    *) warn "Constrained execution is auto-dispatched only for entity-read-by-id and e2e-shop-order-saga; '$scenario_id' will generate a profile but not auto-run (generic drivers have no cgroup enforcement)." ;;
  esac

  constrained_mode="$(select_kv "Constrained spec" "named-profile" \
    named-profile "named-profile — 128m/0.5vCPU or 256m/1vCPU (cgroup-enforced)" \
    custom        "custom        — enter memory_limit_mb + cpu_quota_pct")"

  if [[ "$constrained_mode" == "named-profile" ]]; then
    execution_profile_id="$(select_kv "Execution profile" "runtime-constrained-256m-1vcpu-v1" \
      runtime-constrained-256m-1vcpu-v1   "256 MB / 1.0 vCPU" \
      runtime-constrained-128m-0p5vcpu-v1 "128 MB / 0.5 vCPU")"
    cgroup_memory_limit_mb="$(jq -r --arg id "$execution_profile_id" '.profiles[] | select(.execution_profile_id == $id) | .memory_limit.limit_mb' "$EXEC_PROFILES_JSON" 2>/dev/null || true)"
    _vcpu="$(jq -r --arg id "$execution_profile_id" '.profiles[] | select(.execution_profile_id == $id) | .cpu_limit.vcpu' "$EXEC_PROFILES_JSON" 2>/dev/null || true)"
    # jq -r yields the string "null" for a present-but-null key; normalize it.
    [[ "$cgroup_memory_limit_mb" == "null" ]] && cgroup_memory_limit_mb=""
    [[ "$_vcpu" == "null" ]] && _vcpu=""
    if [[ -z "$cgroup_memory_limit_mb" || -z "$_vcpu" ]]; then
      fail "execution profile '$execution_profile_id' is missing memory_limit.limit_mb or cpu_limit.vcpu in $EXEC_PROFILES_JSON"
    fi
    cgroup_cpu_quota_pct="$(awk -v v="$_vcpu" 'BEGIN { printf "%.0f", v * 100 }')"
  else
    cgroup_memory_limit_mb="$(prompt_positive_int "cgroup memory_limit_mb" "256")"
    cgroup_cpu_quota_pct="$(prompt_positive_int "cgroup cpu_quota_pct (100 = 1.0 vCPU)" "100")"
  fi

  cpu_affinity="$(prompt_text "CPU affinity cpuset (e.g. 0-3, empty = none)" "")"

  # entity-read-by-id constrained runs are driven by a named execution profile +
  # its matching fixed contract; derive it so the recorded contract is honest.
  if [[ "$scenario_id" == "entity-read-by-id" && -n "$execution_profile_id" ]]; then
    constrained_contract="$(jq -r --arg id "$execution_profile_id" '.fixed_contracts | to_entries[] | select(.value.execution_profile_id == $id) | .key' "$scenario_json" 2>/dev/null | head -1)"
  fi
fi

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

# Candidate targets: full matrix, or (for saga) the saga-supported set.
if [[ "$is_saga" == "yes" ]]; then
  readarray -t CANDIDATE_TARGET_IDS < <(jq -r '.target_backend_support | keys[]' "$scenario_json" 2>/dev/null | sort)
  [[ "${#CANDIDATE_TARGET_IDS[@]}" -gt 0 ]] || CANDIDATE_TARGET_IDS=("${TARGET_IDS[@]}")
else
  CANDIDATE_TARGET_IDS=("${TARGET_IDS[@]}")
fi

target_kv=()
for t in "${CANDIDATE_TARGET_IDS[@]}"; do
  meta="$(jq -r --arg id "$t" '.targets[] | select(.target_id == $id) | "\(.tier // "?")/\(.protocol_mode // "?")  \(.health_url // "")"' "$TARGET_MATRIX" 2>/dev/null || true)"
  if [[ -n "$meta" ]]; then
    target_kv+=("$t" "$t   [$meta]")
  else
    target_kv+=("$t" "$t")
  fi
done

if [[ "$execution_class" == "constrained" ]]; then
  target_mode="single"
  info "Constrained: target_mode forced to single (comparative is forbidden for constrained runs)."
elif [[ "$is_saga" == "yes" ]]; then
  target_mode="$(select_kv "Target mode" "single" \
    single "single — one target (baseline)" \
    multi  "multi  — 2-3 targets (saga campaign)")"
else
  target_mode="$(select_kv "Target mode" "single" \
    single "single — one target" \
    multi  "multi  — two targets (comparative)")"
fi

targets=()
if [[ "$target_mode" == "single" ]]; then
  target_single="$(select_kv "Target app" "${CANDIDATE_TARGET_IDS[0]}" "${target_kv[@]}")"
  targets+=("$target_single")
else
  target_a="$(select_kv "Target A" "${CANDIDATE_TARGET_IDS[0]}" "${target_kv[@]}")"
  target_b="$(select_kv "Target B" "${CANDIDATE_TARGET_IDS[1]:-${CANDIDATE_TARGET_IDS[0]}}" "${target_kv[@]}")"
  targets+=("$target_a" "$target_b")
  if [[ "$is_saga" == "yes" && "${#CANDIDATE_TARGET_IDS[@]}" -ge 3 ]] \
     && [[ "$(choose_option "Add a third target (saga triad)?" "no" yes no)" == "yes" ]]; then
    target_c="$(select_kv "Target C" "${CANDIDATE_TARGET_IDS[2]}" "${target_kv[@]}")"
    targets+=("$target_c")
  fi
fi

# ---------------------------------------------------------------------------
# Classification axes
# ---------------------------------------------------------------------------

# Public/community track only (Enterprise has its own tooling). protocol_mode is
# NOT a free choice: it is authoritatively determined by the fixed contract for
# contract-driven runs (entity/saga/constrained/comparative) or by the load
# driver for generic runs — so it is derived later (resolve_protocol_mode), after
# the contract is known, to avoid a profile that claims a protocol the run won't use.
tier="community"

# Derived from the selected target(s), never asked — see derive_target_classification.
# For a multi-target comparative run that mixes modes (the point of a pure-vs-compat
# comparison), the run-level field is "mixed"; per-target truth stays in `targets`.
if [[ "${#targets[@]}" -gt 1 ]]; then
  _cls_first="$(derive_target_classification "${targets[0]}")"
  target_classification="$_cls_first"
  for _t in "${targets[@]:1}"; do
    [[ "$(derive_target_classification "$_t")" == "$_cls_first" ]] || { target_classification="mixed"; break; }
  done
else
  target_classification="$(derive_target_classification "${targets[0]}")"
fi
info "target_classification derived as '$target_classification' (from target '${targets[0]}'${targets[1]:+ + ${#targets[@]} targets})"

# ---------------------------------------------------------------------------
# Env file + workload + reproducibility metadata
# ---------------------------------------------------------------------------

# The runtime/drivers/env/*.env files are TARGET LAUNCH / ENDPOINT CONTRACTS
# (START_MODE / HEALTH_URL / WRK_BASE_URL / EXTERNAL_START_CMD). They are only
# coherent on the generic load-driver dispatch path, where the harness drives a
# tool against a (pre-)launched target the env describes. The managed runners
# (entity-read-by-id local, saga, comparative/multi, constrained) provision and
# seed their OWN DB+target; an external-launch env contract would point the app
# at a different, unseeded DB and break the run — so env_file is NOT offered
# there (rather than recorded-but-ignored).
env_dispatch_is_generic() {
  [[ "$execution_class" != "constrained" ]] || return 1
  [[ "$is_saga" != "yes" ]] || return 1
  [[ "$target_mode" == "single" ]] || return 1
  [[ "$driver" != "none" && -n "$driver" ]] || return 1
  [[ ! ( "$scenario_id" == "entity-read-by-id" && "$topology_mode" == "$TOPOLOGY_LOCAL" ) ]] || return 1
  return 0
}

env_file="none"
if env_dispatch_is_generic && [[ "${#ENV_FILE_NAMES[@]}" -gt 0 ]]; then
  env_kv=("none" "none — no runtime env file")
  for e in "${ENV_FILE_NAMES[@]}"; do
    env_kv+=("$e" "$e")
  done
  env_file="$(select_kv "Runtime env file (runtime/drivers/env/ — target launch/endpoint contract)" "none" "${env_kv[@]}")"
fi

contract_default="fixed_contract_v1"
if [[ "$is_saga" == "yes" ]]; then
  contract_default="$(derive_saga_contract "$scenario_json" "${targets[0]}" "$graph_track")"
elif [[ "$execution_class" == "constrained" && -n "$constrained_contract" ]]; then
  contract_default="$constrained_contract"
fi
contract_id="$(prompt_text "contract_id" "$contract_default")"

# HTTP protocol version (H1/H2), orthogonal to the TLS toggle below.
#   auto -> follow the scenario/contract (contract -> driver -> scenario transport),
#           byte-identical to the pre-toggle derivation.
#   h1/h2 -> force the version: validated against the scenario's protocol_support
#           and mapped onto a capable driver/axis (never a label-only override).
# protocol_scenario_implied is what 'auto' would resolve to with the chosen driver.
protocol_scenario_implied="$(resolve_protocol_mode "$scenario_json" "$contract_id" "$driver")"
proto_mode="auto"
protocol_overrides_scenario="false"
# Saga is contract-fixed to h2c (k6-driven); the toggle does not apply there.
if [[ "$is_saga" != "yes" ]]; then
  proto_kv=(auto "auto — follow the scenario/contract (${protocol_scenario_implied})")
  protocol_choice_available "h1" && proto_kv+=(h1 "h1   — force HTTP/1.1")
  protocol_choice_available "h2" && proto_kv+=(h2 "h2   — force HTTP/2 (h2c cleartext via h2load, or h2-over-TLS via k6)")
  if [[ "${#proto_kv[@]}" -gt 2 ]]; then
    proto_mode="$(select_kv "HTTP protocol version (orthogonal to TLS)" "auto" "${proto_kv[@]}")"
  fi
fi
if [[ "$proto_mode" == "auto" ]]; then
  protocol_mode="$protocol_scenario_implied"
else
  validate_and_apply_protocol   # sets protocol_mode, may switch driver, may fail closed
  [[ "$protocol_mode" != "$protocol_scenario_implied" ]] && protocol_overrides_scenario="true"
fi
info "protocol_mode='$protocol_mode' (toggle=$proto_mode; scenario-implied=$protocol_scenario_implied; driver=${driver:-none})"
if [[ "$protocol_overrides_scenario" == "true" ]]; then
  warn "Protocol override: forced '$protocol_mode' but the scenario/contract implies '$protocol_scenario_implied'. H1 vs H2 is a mandatory separation axis — do NOT compare this run against a '$protocol_scenario_implied' baseline without an explicit protocol-axis caveat."
fi

# TLS / transport security — orthogonal to the H1/H2 protocol_mode above.
#   auto -> follow the target's matrix-declared scheme (no override; current behavior)
#   off  -> plain HTTP (no TLS);   on -> HTTPS / TLS
# The choice composes with protocol_mode into effective_transport (h1/https-h1/h2/h2c)
# which drives BENCH_PROTOCOL_MODE_OVERRIDE + EXERIS_SSL_* and the client scheme.
if [[ "$topology_mode" == "$TOPOLOGY_NETWORK" ]]; then
  tls_target_declared_scheme="${app_endpoint%%://*}"
else
  tls_target_declared_scheme="$(resolve_target_declared_scheme "${targets[0]}")"
fi
[[ "$tls_target_declared_scheme" == "https" ]] || tls_target_declared_scheme="http"
tls_mode="$(select_kv "TLS / transport security" "auto" \
  auto "auto — follow the target's declared scheme (${tls_target_declared_scheme}); no override" \
  off  "off  — plain HTTP (no TLS)" \
  on   "on   — HTTPS / TLS (self-signed smoke cert auto-provisioned)")"
case "$tls_mode" in
  on)   tls_enabled="true" ;;
  off)  tls_enabled="false" ;;
  auto) [[ "$tls_target_declared_scheme" == "https" ]] && tls_enabled="true" || tls_enabled="false" ;;
esac
# h3 always implies TLS; community track never reaches h3, but stay consistent.
[[ "$protocol_mode" == "h3" ]] && tls_enabled="true"
tls_scheme="http"; [[ "$tls_enabled" == "true" ]] && tls_scheme="https"
effective_transport="$(derive_effective_transport "$protocol_mode" "$tls_enabled")"
tls_overrides="false"
if [[ "$tls_mode" != "auto" && "$tls_scheme" != "$tls_target_declared_scheme" ]]; then
  tls_overrides="true"
  warn "TLS override: you chose tls=$tls_mode ($tls_scheme) but target '${targets[0]}' is declared '$tls_target_declared_scheme' in the asset matrix. Guided will force guided-launched targets and the load client to '$tls_scheme'; for pre-launched/WAN/comparative targets the operator must ensure the server already serves '$tls_scheme'. Do NOT compare a TLS-overridden run against the target's declared-scheme baseline without labeling the transport difference."
fi
# Reconcile the WAN endpoint scheme with an explicit TLS choice.
if [[ "$topology_mode" == "$TOPOLOGY_NETWORK" && "$tls_mode" != "auto" ]]; then
  app_endpoint="$(apply_url_scheme "$app_endpoint" "$tls_scheme")"
fi
# k6 negotiates HTTP/2 only over TLS (ALPN); there is no cleartext h2c in k6.
# h2 + k6 therefore REQUIRES TLS. If the user explicitly chose tls=off, the two
# toggles conflict — fail closed rather than silently override an explicit choice.
# If tls is auto-resolving to off, couple them: force TLS on and re-derive transport.
if [[ "$protocol_mode" == "h2" && "$driver" == "k6" && "$tls_enabled" != "true" ]]; then
  if [[ "$tls_mode" == "off" ]]; then
    fail "Incompatible toggles: protocol h2 with the k6 driver requires TLS (k6 negotiates HTTP/2 only via ALPN; no cleartext h2c), but you set tls=off. Choose protocol h1, switch the driver to h2load (which does cleartext h2c), or set tls=on/auto."
  fi
  warn "Protocol h2 with the k6 driver requires TLS (k6 negotiates HTTP/2 only via ALPN; no cleartext h2c). Forcing tls=on for this run (tls was auto)."
  tls_mode="on"; tls_enabled="true"; tls_scheme="https"
  effective_transport="$(derive_effective_transport "$protocol_mode" "$tls_enabled")"
  tls_overrides="false"
  [[ "$tls_scheme" != "$tls_target_declared_scheme" ]] && tls_overrides="true"
  if [[ "$topology_mode" == "$TOPOLOGY_NETWORK" ]]; then
    app_endpoint="$(apply_url_scheme "$app_endpoint" "$tls_scheme")"
  fi
fi
info "tls derived: mode=$tls_mode enabled=$tls_enabled scheme=$tls_scheme effective_transport=$effective_transport (target declares $tls_target_declared_scheme)"

# entity-read-by-id protocol h2: cleartext -> h2c (h2load prior-knowledge);
# over TLS -> h2 via ALPN. The entity runner enables HTTP/2 on the launched target
# for h2 runs (h2c upgrade on cleartext, ALPN on TLS) and fails the run if the
# server does not actually negotiate h2, so neither path can be mislabeled. No
# pre-rejection needed here.

# Target build (jvm/native) for local runs. The default follows the chosen
# target's name, EXCEPT the 128m constrained profile defaults to native: the JVM
# build's irreducible ~120MB native floor (off-heap memory subsystem + native
# transport + FFM) does not fit a 128MB cgroup and OOMs, whereas native fits
# comfortably. The recorded runtime_mode is what the runner's --target-build uses.
if [[ "$topology_mode" == "$TOPOLOGY_LOCAL" ]]; then
  build_default="$(map_entity_build "${targets[0]}")"
  if [[ "$execution_class" == "constrained" && "$execution_profile_id" == "runtime-constrained-128m-0p5vcpu-v1" ]]; then
    build_default="native"
  fi
  # Only entity-read-by-id dispatch actually drives --target-build (saga uses
  # --target-app; generic drivers hit a pre-launched target). Elsewhere keep the
  # target-name-derived value for the recorded profile without a misleading prompt.
  if [[ "$scenario_id" == "entity-read-by-id" ]]; then
    runtime_mode="$(select_kv "Target build" "$build_default" \
      jvm    "jvm    — HotSpot JVM (larger footprint; community target needs >=192M/256M, OOMs at 128M)" \
      native "native — GraalVM native-image (small footprint; required to fit the 128M constrained profile)")"
    if [[ "$runtime_mode" == "native" && "$launch_mode" != "build" ]]; then
      warn "native build selected with launch_mode=$launch_mode: a prebuilt native binary must already exist (mvn -Pnative), otherwise the run fails. Pick launch_mode=build to compile it."
    fi
  else
    runtime_mode="$build_default"
  fi
fi

# launch_mode maps to the runner build toggle: build -> compile from source,
# prebuild -> use prebuilt artifacts (BENCHMARK_SKIP_TARGET_BUILD=1).
if [[ "$launch_mode" == "build" ]]; then
  skip_target_build=0
else
  skip_target_build=1
fi

if [[ "$is_saga" == "yes" ]]; then
  if [[ "$topology_mode" == "$TOPOLOGY_NETWORK" ]]; then
    saga_auto_start_infra="no"
    saga_auto_start_target="no"
    info "WAN saga: infra/target auto-start disabled (remote target is operator-managed)."
  else
    saga_auto_start_infra="$(choose_option "Auto-start saga infra (Postgres/Neo4j via docker compose)?" "yes" yes no)"
    saga_auto_start_target="$(choose_option "Auto-start target app if health preflight fails?" "yes" yes no)"
  fi
  saga_skip_seed_verify="$(choose_option "Skip seed verification?" "no" yes no)"
fi

# JFR (jcmd) recording is offered only where guided manages a local JVM target it
# can attach to: saga and entity-read-by-id, on localhost. For generic/WAN runs
# the target is pre-launched/remote, so guided can't attach a recorder. A native
# image has no jcmd attach surface, so JFR is offered for the jvm build only.
# Community track is OSS — the raw .jfr is kept as-is (no redaction).
jfr_supported() {
  [[ "$topology_mode" == "$TOPOLOGY_LOCAL" ]] || return 1
  [[ "$is_saga" == "yes" || "$scenario_id" == "entity-read-by-id" ]] || return 1
  [[ "$runtime_mode" != "native" ]] || return 1
  return 0
}
if jfr_supported; then
  enable_jfr="$(choose_option "Record JFR of the target during measurement (adds overhead)?" "no" yes no)"
fi

# OS sidecars (pidstat/mpstat) are wired into the dedicated saga and
# entity-read-by-id runners, which know the target PID to sample. Offered only on
# localhost (the host PID/CPU view must be the machine under test) and only when
# the tools exist. Default OFF — sampling is opt-in instrumentation.
os_sidecars_supported() {
  [[ "$topology_mode" == "$TOPOLOGY_LOCAL" ]] || return 1
  [[ "$is_saga" == "yes" || "$scenario_id" == "entity-read-by-id" ]] || return 1
  command -v pidstat >/dev/null 2>&1 || command -v mpstat >/dev/null 2>&1 || return 1
  return 0
}
if os_sidecars_supported; then
  enable_os_sidecars="$(choose_option "Capture OS sidecars (pidstat %wait/ctxsw + mpstat per-CPU %soft/%sys) during measurement?" "no" yes no)"
fi

# Steady-state JFR overlay (env/jfr-steady-state.jfc): adds C2 compiler events
# (CompilerStatistics/CompilerQueueUtilization/Compilation) on top of the base JFR
# config to prove the JIT settled before the measurement window. Only meaningful
# when JFR is actually being recorded, so it is gated on enable_jfr.
if [[ "$enable_jfr" == "yes" ]]; then
  enable_jfr_steady_state="$(choose_option "Merge steady-state JFR overlay (C2 compiler events, proves JIT settled)?" "no" yes no)"
fi

# Export the opt-in diagnostics into the dispatch environment so every child
# runner inherits them (the dedicated saga/entity-read runners read
# BENCH_OS_SIDECARS; the target launchers read BENCH_JFR_STEADY_STATE). Both
# compare against the literal "1"; export "0" when off so the default is explicit
# rather than relying on the unset fallback.
if [[ "$enable_os_sidecars" == "yes" ]]; then export BENCH_OS_SIDECARS=1; else export BENCH_OS_SIDECARS=0; fi
if [[ "$enable_jfr_steady_state" == "yes" ]]; then export BENCH_JFR_STEADY_STATE=1; else export BENCH_JFR_STEADY_STATE=0; fi

# ---------------------------------------------------------------------------
# Claim scope + fairness attestations (resolved before workload because the
# entity-read-by-id dispatch mode depends on it: exploratory => free run, no
# fixed contract; comparison_eligible => strict fixed contract).
# ---------------------------------------------------------------------------

claim_scope="descriptive_only"
if [[ "$execution_class" == "constrained" ]]; then
  info "Constrained: claim_scope forced to descriptive_only (constrained profiles are exploratory; comparison is forbidden)."
elif [[ "$run_type" != "exploratory" ]]; then
  claim_scope="$(select_kv "Claim scope" "descriptive_only" \
    descriptive_only    "descriptive_only    — describe results only" \
    comparison_eligible "comparison_eligible — eligible for cross-target claims")"
fi

fairness_payload_equivalent="false"
fairness_concurrency_equivalent="false"
fairness_protocol_mode_equivalent="false"
fairness_target_scope_equivalent="false"

if [[ "$claim_scope" == "comparison_eligible" ]]; then
  [[ "$(choose_option "fairness_attest_payload" "yes" yes no)" == "yes" ]] && fairness_payload_equivalent="true"
  [[ "$(choose_option "fairness_attest_concurrency" "yes" yes no)" == "yes" ]] && fairness_concurrency_equivalent="true"
  [[ "$(choose_option "fairness_attest_protocol_mode" "yes" yes no)" == "yes" ]] && fairness_protocol_mode_equivalent="true"
  [[ "$(choose_option "fairness_attest_target_scope" "yes" yes no)" == "yes" ]] && fairness_target_scope_equivalent="true"
fi

# entity-read-by-id local runs in two modes that mirror the base runner:
#   - exploratory (no fixed contract): free workload, honored by the runner;
#   - comparison_eligible: strict fixed contract that fixes workload and rejects
#     --duration / asserts threads/warmup/claim-scope/profile.
entity_local_contract_mode() {
  [[ "$scenario_id" == "entity-read-by-id" && "$topology_mode" == "$TOPOLOGY_LOCAL" \
     && "$claim_scope" == "comparison_eligible" ]]
}

# Workload is a free (honored) choice on the generic load-driver path and on
# entity-read-by-id local in exploratory free mode; otherwise the contract fixes
# it (constrained/saga/comparative/entity comparison-eligible), so read & show
# those values instead of prompting for numbers the run would ignore.
workload_is_free() {
  env_dispatch_is_generic && return 0
  [[ "$execution_class" != "constrained" \
     && "$scenario_id" == "entity-read-by-id" && "$topology_mode" == "$TOPOLOGY_LOCAL" ]] \
    && ! entity_local_contract_mode && return 0
  return 1
}

# k6 generic dispatch derives its actual load (VUs / arrival-rate / duration)
# from the scenario's k6.js — run-k6.sh receives only the scenario dir, no
# wrk-style threads/connections/duration. So the workload numbers here are
# recorded as operator-intent metadata but are NOT applied by k6; we must not
# claim them as "honored". (run-wrk/wrk2/h2load DO honor them via overrides.)
k6_workload_from_script() {
  env_dispatch_is_generic && [[ "$driver" == "k6" ]]
}

if workload_is_free; then
  warmup_seconds="$(prompt_positive_int "workload.warmup_seconds" "60")"
  measurement_seconds="$(prompt_positive_int "workload.measurement_seconds" "120")"
  threads="$(prompt_positive_int "workload.threads" "4")"
  connections="$(prompt_positive_int "workload.connections" "128")"
  if k6_workload_from_script; then
    warn "k6 derives actual load (VUs/arrival-rate/duration) from the scenario's k6.js; the workload numbers above are recorded as metadata/intent only and are NOT applied by the k6 run. To change k6 load, edit the scenario k6.js."
  fi
else
  read -r threads connections warmup_seconds measurement_seconds \
    < <(resolve_workload_from_contract "$scenario_json" "$contract_id")
  info "workload taken from contract '$contract_id' (not prompted): threads=$threads connections=$connections warmup=${warmup_seconds}s measurement=${measurement_seconds}s"
  if [[ "$is_saga" == "yes" ]]; then
    info "saga drives concurrency by virtual_users/think-time from the contract; threads/connections are not used by the saga runner."
  fi
fi
hardware_profile="$(select_kv "Hardware profile" "dev-laptop" \
  linux-generic    "linux-generic" \
  aarch64-generic  "aarch64-generic" \
  dev-laptop       "dev-laptop" \
  ci-runner        "ci-runner" \
  docker-container "docker-container")"

if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
  benchmark_commit_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
else
  benchmark_commit_sha="unknown"
fi

if command -v java >/dev/null 2>&1; then
  jdk_version="$(java -version 2>&1 | head -n1 | sed 's/"//g')"
  [[ -n "$jdk_version" ]] || jdk_version="unknown"
else
  jdk_version="unknown"
fi

jq_version="$(tool_version_or_unknown jq)"
k6_version="$(tool_version_or_unknown k6)"
wrk_version="$(tool_version_or_unknown wrk)"
h2load_version="$(tool_version_or_unknown h2load)"
docker_version="$(tool_version_or_unknown docker)"

read -r -p "jvm_flags (comma-separated, empty for none) []: " jvm_flags_raw || true
jvm_flags=()
if [[ -n "${jvm_flags_raw//[[:space:]]/}" ]]; then
  IFS=',' read -r -a raw_flags <<< "$jvm_flags_raw"
  for f in "${raw_flags[@]}"; do
    trimmed="$(echo "$f" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$trimmed" ]] && jvm_flags+=("$trimmed")
  done
fi


# ---------------------------------------------------------------------------
# Write profile
# ---------------------------------------------------------------------------

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -z "$PROFILE_OUT" ]]; then
  PROFILE_OUT="$REPO_ROOT/results/raw/guided/${timestamp}/guided-run-profile.json"
fi
mkdir -p "$(dirname "$PROFILE_OUT")"
profile_dir="$(cd "$(dirname "$PROFILE_OUT")" && pwd)"
output_dir="$profile_dir"
# Constrained results live under the dedicated namespace (comparison-forbidden).
if [[ "$execution_class" == "constrained" ]]; then
  output_dir="$REPO_ROOT/results/constrained/${scenario_id}/${timestamp}-guided"
fi
mkdir -p "$output_dir"

targets_json="$(jq -n '$ARGS.positional' --args "${targets[@]}")"
if [[ "${#jvm_flags[@]}" -gt 0 ]]; then
  jvm_flags_json="$(jq -n '$ARGS.positional' --args "${jvm_flags[@]}")"
else
  jvm_flags_json="[]"
fi

jq -n \
  --arg schema_version "1" \
  --arg benchmark_family "runtime" \
  --arg benchmark_commit_sha "$benchmark_commit_sha" \
  --arg jdk_version "$jdk_version" \
  --arg hardware_profile "$hardware_profile" \
  --arg scenario_id "$scenario_id" \
  --arg target_classification "$target_classification" \
  --arg protocol_mode "$protocol_mode" \
  --arg proto_mode "$proto_mode" \
  --arg protocol_scenario_implied "$protocol_scenario_implied" \
  --arg protocol_overrides_scenario "$protocol_overrides_scenario" \
  --arg tls_mode "$tls_mode" \
  --arg tls_enabled "$tls_enabled" \
  --arg tls_scheme "$tls_scheme" \
  --arg effective_transport "$effective_transport" \
  --arg tls_declared_scheme "$tls_target_declared_scheme" \
  --arg tls_overrides "$tls_overrides" \
  --arg tier "$tier" \
  --arg topology_mode "$topology_mode" \
  --arg connectivity "$connectivity" \
  --arg run_type "$run_type" \
  --arg target_mode "$target_mode" \
  --arg claim_scope "$claim_scope" \
  --arg driver "$driver" \
  --arg env_file "$env_file" \
  --arg app_endpoint "$app_endpoint" \
  --arg db_endpoint "$db_endpoint" \
  --arg health_path "$health_path" \
  --arg launch_mode "$launch_mode" \
  --arg runtime_mode "$runtime_mode" \
  --arg contract_id "$contract_id" \
  --arg output_dir "$output_dir" \
  --arg jq_version "$jq_version" \
  --arg k6_version "$k6_version" \
  --arg wrk_version "$wrk_version" \
  --arg h2load_version "$h2load_version" \
  --arg docker_version "$docker_version" \
  --arg fairness_payload_equivalent "$fairness_payload_equivalent" \
  --arg fairness_concurrency_equivalent "$fairness_concurrency_equivalent" \
  --arg fairness_protocol_mode_equivalent "$fairness_protocol_mode_equivalent" \
  --arg fairness_target_scope_equivalent "$fairness_target_scope_equivalent" \
  --arg impairment_enabled "$impairment_enabled" \
  --arg apply_netem "$apply_netem" \
  --arg imp_profile "$imp_profile" \
  --arg applied_to "$applied_to" \
  --arg netem_tool "tc netem" \
  --arg is_saga "$is_saga" \
  --arg graph_track "$graph_track" \
  --arg saga_auto_start_infra "$saga_auto_start_infra" \
  --arg saga_auto_start_target "$saga_auto_start_target" \
  --arg saga_skip_seed_verify "$saga_skip_seed_verify" \
  --arg enable_jfr "$enable_jfr" \
  --arg enable_os_sidecars "$enable_os_sidecars" \
  --arg enable_jfr_steady_state "$enable_jfr_steady_state" \
  --arg execution_class "$execution_class" \
  --arg execution_profile_id "$execution_profile_id" \
  --arg cgroup_memory_limit_mb "$cgroup_memory_limit_mb" \
  --arg cgroup_cpu_quota_pct "$cgroup_cpu_quota_pct" \
  --arg cpu_affinity "$cpu_affinity" \
  --arg client_cpu_affinity "$client_cpu_affinity" \
  --argjson delay_ms "${delay_ms:-0}" \
  --argjson loss_pct "${loss_pct:-0}" \
  --argjson jitter_ms "${jitter_ms:-0}" \
  --argjson targets "$targets_json" \
  --argjson jvm_flags "$jvm_flags_json" \
  --argjson warmup_seconds "$warmup_seconds" \
  --argjson measurement_seconds "$measurement_seconds" \
  --argjson threads "$threads" \
  --argjson connections "$connections" \
  '
  {
    schema_version: $schema_version,
    benchmark_family: $benchmark_family,
    benchmark_commit_sha: $benchmark_commit_sha,
    jdk_version: $jdk_version,
    tool_versions: {
      jq: $jq_version,
      k6: $k6_version,
      wrk: $wrk_version,
      h2load: $h2load_version,
      docker: $docker_version
    },
    jvm_flags: $jvm_flags,
    hardware_profile: $hardware_profile,
    scenario_id: $scenario_id,
    target_classification: $target_classification,
    protocol_mode: $protocol_mode,
    protocol_selection: {
      mode: $proto_mode,
      resolved: $protocol_mode,
      scenario_implied: $protocol_scenario_implied,
      overrides_scenario: ($protocol_overrides_scenario == "true")
    },
    transport_security: {
      mode: $tls_mode,
      tls_enabled: ($tls_enabled == "true"),
      scheme: $tls_scheme,
      effective_transport: $effective_transport,
      target_declared_scheme: $tls_declared_scheme,
      overrides_target_declared: ($tls_overrides == "true")
    },
    tier: $tier,
    topology_mode: $topology_mode,
    connectivity: $connectivity,
    run_type: $run_type,
    target_mode: $target_mode,
    claim_scope: $claim_scope,
    targets: $targets,
    contract_id: $contract_id,
    output_dir: $output_dir,
    fairness_attestations: {
      payload_equivalent: ($fairness_payload_equivalent == "true"),
      concurrency_equivalent: ($fairness_concurrency_equivalent == "true"),
      protocol_mode_equivalent: ($fairness_protocol_mode_equivalent == "true"),
      target_scope_equivalent: ($fairness_target_scope_equivalent == "true")
    },
    workload: {
      warmup_seconds: $warmup_seconds,
      measurement_seconds: $measurement_seconds,
      threads: $threads,
      connections: $connections
    }
  }
  | (if $driver != "none" and $driver != "" then . + {driver: $driver} else . end)
  | (if $env_file != "none" and $env_file != "" then . + {env_file: $env_file} else . end)
  | (if $topology_mode == "network"
       then . + {app_endpoint: $app_endpoint, db_endpoint: $db_endpoint, health_path: $health_path}
       else . + {launch_mode: $launch_mode, runtime_mode: $runtime_mode} end)
  | (if $impairment_enabled == "true"
       then . + {network_impairment: {
                   enabled: true,
                   apply_requested: ($apply_netem == "yes"),
                   applied_to: $applied_to,
                   profile: $imp_profile,
                   tool: $netem_tool,
                   delay_ms: $delay_ms,
                   loss_pct: $loss_pct,
                   jitter_ms: $jitter_ms,
                   note: (if $applied_to == "loopback"
                          then "tc netem on lo root impairs ALL loopback traffic, including local DB (Postgres/Neo4j) connections — not just client->target. Scenarios with a local DB are confounded; exploratory only."
                          else "Impairment lives on the remote network path; the guided launcher does not apply or verify it." end)
                 }}
       else . end)
  | (if $is_saga == "yes"
       then . + {
                  graph_track: $graph_track,
                  saga: {
                    auto_start_infra: ($saga_auto_start_infra == "yes"),
                    auto_start_target: ($saga_auto_start_target == "yes"),
                    skip_seed_verify: ($saga_skip_seed_verify == "yes")
                  }
                }
       else . end)
  | (. + {enable_jfr: ($enable_jfr == "yes")})
  | (. + {os_sidecars: ($enable_os_sidecars == "yes")})
  | (. + {jfr_steady_state: ($enable_jfr_steady_state == "yes")})
  | (. + {execution_class: $execution_class})
  | (if $execution_class == "constrained"
       then . + (if $execution_profile_id != "" then {execution_profile_id: $execution_profile_id} else {} end)
              + (if ($cgroup_memory_limit_mb != "" or $cgroup_cpu_quota_pct != "")
                   then {cgroup: (
                          (if $cgroup_memory_limit_mb != "" then {memory_limit_mb: ($cgroup_memory_limit_mb | tonumber)} else {} end)
                        + (if $cgroup_cpu_quota_pct != "" then {cpu_quota_pct: ($cgroup_cpu_quota_pct | tonumber)} else {} end)
                        )}
                   else {} end)
              + (if $cpu_affinity != "" then {cpu_affinity: $cpu_affinity} else {} end)
              + (if $client_cpu_affinity != "" then {client_cpu_affinity: $client_cpu_affinity} else {} end)
       else . end)
  ' > "$PROFILE_OUT"

info "Profile written: $PROFILE_OUT"
validate_args=(--profile "$PROFILE_OUT" --dispatch-compatible)
if [[ "$claim_scope" == "comparison_eligible" ]]; then
  validate_args+=(--confirm-comparison-eligibility)
fi
"$VALIDATOR_SCRIPT" "${validate_args[@]}"

# Make the dispatched run self-describing: ensure the full guided profile
# (connectivity, network_impairment, constrained, affinity, contract, …) lands
# in the run's output_dir, not only in the separate --profile-out path. Without
# this, an impaired run's artifacts are indistinguishable from a clean one.
if [[ "$(cd "$(dirname "$PROFILE_OUT")" && pwd)" != "$output_dir" ]]; then
  if cp "$PROFILE_OUT" "$output_dir/guided-run-profile.json" 2>/dev/null; then
    info "Guided profile copied into run dir: $output_dir/guided-run-profile.json"
  else
    warn "Could not copy guided profile into run dir: $output_dir"
  fi
fi

echo
echo "Guided profile summary:"
echo "  run_type           : $run_type"
echo "  connectivity       : $connectivity (topology_mode=$topology_mode)"
echo "  scenario_id        : $scenario_id"
echo "  driver             : $driver"
if [[ "$protocol_overrides_scenario" == "true" ]]; then
  echo "  protocol_mode      : $protocol_mode (toggle=$proto_mode) [OVERRIDE: scenario implies $protocol_scenario_implied]"
else
  echo "  protocol_mode      : $protocol_mode (toggle=$proto_mode)"
fi
if [[ "$tls_overrides" == "true" ]]; then
  echo "  tls                : mode=$tls_mode enabled=$tls_enabled scheme=$tls_scheme transport=$effective_transport [OVERRIDE: target declares $tls_target_declared_scheme]"
else
  echo "  tls                : mode=$tls_mode enabled=$tls_enabled scheme=$tls_scheme transport=$effective_transport"
fi
echo "  tier               : $tier"
echo "  target_classification: $target_classification"
echo "  target_mode        : $target_mode"
echo "  targets            : ${targets[*]}"
[[ "$topology_mode" == "$TOPOLOGY_LOCAL" ]] && echo "  target_build       : ${runtime_mode:-n/a}"
echo "  env_file           : $env_file"
echo "  hardware_profile   : $hardware_profile"
echo "  claim_scope        : $claim_scope"
echo "  contract_id        : $contract_id"
echo "  output_dir         : $output_dir"
if k6_workload_from_script; then
  echo "  workload           : VUs/arrival-rate/duration defined by scenario k6.js — threads/connections/measurement below are metadata only, NOT applied by k6"
  echo "  workload (metadata): warmup=$warmup_seconds measurement=$measurement_seconds threads=$threads connections=$connections"
elif workload_is_free; then
  echo "  workload           : warmup=$warmup_seconds measurement=$measurement_seconds threads=$threads connections=$connections (your values — honored)"
else
  echo "  workload           : warmup=$warmup_seconds measurement=$measurement_seconds threads=$threads connections=$connections (from contract $contract_id)"
fi
if [[ "$topology_mode" == "$TOPOLOGY_NETWORK" ]]; then
  echo "  app_endpoint       : $app_endpoint"
  echo "  db_endpoint        : $db_endpoint"
  echo "  health_path        : $health_path"
fi
if [[ "$impairment_enabled" == "true" ]]; then
  echo "  impairment         : profile=$imp_profile applied_to=$applied_to delay=${delay_ms}ms loss=${loss_pct}% jitter=${jitter_ms}ms apply_requested=$apply_netem"
  if [[ "$applied_to" == "loopback" ]]; then
    echo "  impairment caveat  : tc netem on lo root impairs ALL loopback traffic incl. local DB (Postgres/Neo4j) — local-DB scenarios are confounded; exploratory only."
  fi
fi
if [[ "$is_saga" == "yes" ]]; then
  echo "  graph_track        : $graph_track"
  echo "  saga               : auto_start_infra=$saga_auto_start_infra auto_start_target=$saga_auto_start_target skip_seed_verify=$saga_skip_seed_verify"
fi
if jfr_supported; then
  echo "  jfr                : enable_jfr=$enable_jfr (recorded into the run dir)"
  [[ "$enable_jfr" == "yes" ]] && echo "  jfr_steady_state   : $enable_jfr_steady_state (merge env/jfr-steady-state.jfc — C2 compiler events)"
fi
if os_sidecars_supported; then
  echo "  os_sidecars        : $enable_os_sidecars (pidstat/mpstat sampling during measurement)"
fi
echo "  execution_class    : $execution_class"
if [[ "$execution_class" == "constrained" ]]; then
  echo "  constrained        : profile=${execution_profile_id:-<custom>} mem=${cgroup_memory_limit_mb:-?}MB cpu=${cgroup_cpu_quota_pct:-?}% affinity=${cpu_affinity:-none}"
fi

# ---------------------------------------------------------------------------
# Execution decision
# ---------------------------------------------------------------------------

should_execute="no"
if [[ "$EXECUTE_MODE" == "yes" ]]; then
  should_execute="yes"
elif [[ "$EXECUTE_MODE" == "no" ]]; then
  should_execute="no"
else
  read -r -p "Execute now? [y/N]: " run_now || true
  if [[ "$run_now" == "y" || "$run_now" == "Y" ]]; then
    should_execute="yes"
  fi
fi

if [[ "$should_execute" != "yes" ]]; then
  info "Generate+validate complete (execution skipped)."
  exit 0
fi

# Wire the chosen transport (TLS on/off) into the dispatch environment + cert.
# No-op in 'auto' mode. Exports BENCH_PROTOCOL_MODE_OVERRIDE / EXERIS_SSL_* /
# BENCHMARK_TLS_ENABLED, inherited by guided-launched targets and honored by the
# protocol lib; the client scheme is forced per dispatch path below.
setup_tls_runtime_env

# ---------------------------------------------------------------------------
# tc netem application (loopback only, when requested)
# ---------------------------------------------------------------------------

NETEM_APPLIED=0

# True when the user asked the guided launcher to apply loopback netem.
impairment_apply_pending() {
  [[ "$impairment_enabled" == "true" && "$apply_netem" == "yes" && "$applied_to" == "loopback" ]]
}

# Loud, honest warning for dispatch paths that do NOT apply guided netem, so the
# recorded apply_requested=true never silently diverges from what actually ran.
warn_impairment_not_applied() {
  local path_label="$1"
  if impairment_apply_pending; then
    warn "network_impairment.apply_requested=true, but dispatch path '${path_label}' does not apply tc netem via the guided launcher — netem was NOT applied. This run is INVALID for impairment claims; apply netem manually before the run, or use generic single-target driver dispatch."
  fi
}

# Record the ACTUAL netem state next to the run's results, so an impaired run is
# never mistaken for a clean one. The dispatched runner does not know netem was
# applied externally — its result.json transport_mode does NOT reflect it — so
# this file is the authoritative impairment record for the run.
write_impairment_marker() {
  local applied="$1"  # true|false
  mkdir -p "$output_dir" 2>/dev/null || true
  jq -n \
    --arg tool "tc netem" \
    --arg applied_to "$applied_to" \
    --arg profile "$imp_profile" \
    --argjson delay_ms "${delay_ms:-0}" \
    --argjson loss_pct "${loss_pct:-0}" \
    --argjson jitter_ms "${jitter_ms:-0}" \
    --argjson applied "$applied" \
    '{
      enabled: true,
      tool: $tool,
      applied_to: $applied_to,
      profile: $profile,
      delay_ms: $delay_ms,
      loss_pct: $loss_pct,
      jitter_ms: $jitter_ms,
      applied: $applied,
      claim_scope: "exploratory",
      note: "tc netem on lo root impairs ALL loopback traffic incl. local DB (Postgres/Neo4j); exploratory only. The dispatched runner does not know about this impairment — its result.json transport_mode does NOT reflect netem. This file is the authoritative impairment record for the run.",
      comparability: "Do NOT compare against clean runs, nor across different netem profiles, without explicit impairment labels."
    }' > "$output_dir/network-impairment.json" 2>/dev/null \
    && info "Network impairment recorded: $output_dir/network-impairment.json"
}

maybe_apply_netem() {
  impairment_apply_pending || return 0

  if ! command -v tc >/dev/null 2>&1; then
    warn "tc not available; cannot apply netem. Run is invalid for impairment claims; metadata captured only."
    write_impairment_marker false
    return 0
  fi

  local prefix=""
  [[ "${EUID:-$(id -u)}" -ne 0 ]] && prefix="sudo"

  info "Applying tc netem to loopback: delay=${delay_ms}ms jitter=${jitter_ms}ms loss=${loss_pct}%"
  warn "tc netem on lo root impairs ALL loopback traffic, including local DB (Postgres/Neo4j) — local-DB scenarios are confounded by this. Exploratory only."
  if $prefix tc qdisc add dev lo root netem delay "${delay_ms}ms" "${jitter_ms}ms" loss "${loss_pct}%"; then
    NETEM_APPLIED=1
    trap 'if [[ "${NETEM_APPLIED:-0}" == "1" ]]; then '"$prefix"' tc qdisc del dev lo root 2>/dev/null || true; fi' EXIT
    write_impairment_marker true
  else
    warn "Failed to apply tc netem; continuing without impairment (run invalid for impairment claims)."
    write_impairment_marker false
  fi
}

# ---------------------------------------------------------------------------
# Generic single-target dispatch via the selected load driver
# ---------------------------------------------------------------------------

dispatch_generic_driver() {
  local base_url="$1"
  local target_rel
  target_rel="$(map_target_dir "${targets[0]}")"
  local scenario_rel="scenarios/$scenario_id"

  info "Dispatch: run-${driver}.sh (base_url=$base_url, target_dir=$target_rel)"
  case "$driver" in
    wrk)
      WRK_BASE_URL_OVERRIDE="$base_url" \
      WRK_THREADS_OVERRIDE="$threads" \
      WRK_CONNECTIONS_OVERRIDE="$connections" \
      WRK_DURATION_OVERRIDE="${measurement_seconds}s" \
        "$REPO_ROOT/scripts/run-wrk.sh" "$target_rel" "$scenario_rel"
      ;;
    wrk2)
      WRK_BASE_URL_OVERRIDE="$base_url" \
      WRK2_THREADS_OVERRIDE="$threads" \
      WRK2_CONNECTIONS_OVERRIDE="$connections" \
      WRK2_DURATION_OVERRIDE="${measurement_seconds}s" \
        "$REPO_ROOT/scripts/run-wrk2.sh" "$target_rel" "$scenario_rel"
      ;;
    k6)
      # Forward the requested protocol so run-k6.sh fails closed if k6 silently
      # fell back to HTTP/1.1 on an h2 run (k6 does h2 only over TLS via ALPN).
      BASE_URL="$base_url" K6_BASE_URL="$base_url" \
      BENCH_EXPECTED_PROTOCOL_MODE="$protocol_mode" \
        "$REPO_ROOT/scripts/run-k6.sh" "$scenario_rel"
      ;;
    h2load)
      H2LOAD_BASE_URL_OVERRIDE="$base_url" \
      H2LOAD_CLIENTS="$connections" \
        "$REPO_ROOT/scripts/run-h2load.sh" "$target_rel" "$scenario_rel"
      ;;
    *)
      echo "No load driver selected for generic dispatch (driver=$driver)." >&2
      return 3
      ;;
  esac
}

# Source the selected env contract into the dispatch environment for real, so
# its vars (WRK_BASE_URL / H2LOAD_BASE_URL / HEALTH_URL / driver knobs) actually
# take effect in the run-{wrk,wrk2,k6,h2load}.sh child. Only called on the
# generic path (the only place env_file is offered).
apply_env_file_for_generic() {
  [[ "$env_file" != "none" && -n "$env_file" ]] || return 0
  local path="$ENV_DIR/$env_file"
  if [[ ! -f "$path" ]]; then
    warn "env_file not found: $path (skipping)"
    return 0
  fi
  info "Forwarding runtime env contract into dispatch (sourced + exported): $path"
  set -a
  # shellcheck source=/dev/null
  source "$path"
  set +a
  if [[ -n "${START_MODE:-}" && "$START_MODE" != "none" ]]; then
    warn "env_file declares START_MODE=$START_MODE (its own launch contract). The guided generic path does NOT auto-launch the target — ensure the target is already running and reachable at the env's endpoint."
  fi
}

resolve_dispatch_base_url() {
  if [[ "$topology_mode" == "$TOPOLOGY_NETWORK" ]]; then
    printf '%s\n' "$app_endpoint"
  elif [[ -n "${WRK_BASE_URL:-}" ]]; then
    # honored from the sourced env contract
    printf '%s\n' "$WRK_BASE_URL"
  elif [[ -n "${HEALTH_URL:-}" ]]; then
    printf '%s\n' "$HEALTH_URL" | sed -E 's#(https?://[^/]+).*#\1#'
  else
    resolve_local_base_url "${targets[0]}"
  fi
}

# ---- Constrained (cgroup/affinity): local, single, exploratory-only ----
if [[ "$execution_class" == "constrained" ]]; then
  case "$scenario_id" in
    entity-read-by-id)
      if [[ -z "$execution_profile_id" ]]; then
        echo "Constrained entity-read-by-id requires a named execution profile (the constrained runner is profile-driven; custom cgroup is not supported here)."
        echo "Re-run and pick a named profile, or use saga for custom cgroup limits. Profile generated; not dispatched."
        exit 0
      fi
      if [[ -z "$constrained_contract" ]]; then
        echo "No fixed contract maps to execution_profile_id='$execution_profile_id'. Profile generated; not dispatched." >&2
        exit 3
      fi
      maybe_apply_netem
      info "Dispatch: run-entity-read-by-id-constrained.sh (profile=$execution_profile_id contract=$contract_id affinity=${cpu_affinity:-none} launch_mode=$launch_mode)"
      erbid_constrained_cmd=(
        env "BENCHMARK_SKIP_TARGET_BUILD=$skip_target_build"
        "$REPO_ROOT/scripts/run-entity-read-by-id-constrained.sh"
        --execution-profile-id "$execution_profile_id"
        --contract-id "$contract_id"
        --target-runtime "$(map_entity_runtime "${targets[0]}")"
        --target-build "$runtime_mode"
        --output-dir "$output_dir"
      )
      [[ -n "$cpu_affinity" ]] && erbid_constrained_cmd+=(--cpu-affinity "$cpu_affinity")
      [[ "$enable_jfr" == "yes" ]] && erbid_constrained_cmd+=(--enable-jfr)
      "${erbid_constrained_cmd[@]}"
      exit $?
      ;;
    e2e-shop-order-saga)
      # run-e2e-shop-order-saga-baseline.sh does not honor BENCH_SERVER_CPU_AFFINITY
      # (only the campaign runner does), so don't export a dead env var — warn instead.
      [[ -n "$cpu_affinity" ]] && warn "CPU affinity '$cpu_affinity' is not applied by run-e2e-shop-order-saga-baseline.sh (server pinning is only honored by the saga campaign runner); ignoring."
      maybe_apply_netem
      info "Dispatch: run-e2e-shop-order-saga-baseline.sh (constrained: mem=${cgroup_memory_limit_mb}MB cpu=${cgroup_cpu_quota_pct}%)"
      cmd=(
        "$REPO_ROOT/scripts/run-e2e-shop-order-saga-baseline.sh"
        --contract-id "$contract_id"
        --target-app "${targets[0]}"
        --graph-track "$graph_track"
        --profile "$hardware_profile"
        --output-dir "$output_dir"
      )
      if [[ "$tls_mode" != "auto" ]]; then
        cmd+=(--base-url "$(apply_url_scheme "$(resolve_local_base_url "${targets[0]}")" "$tls_scheme")")
      fi
      [[ -n "$cgroup_memory_limit_mb" ]] && cmd+=(--cgroup-memory-limit-mb "$cgroup_memory_limit_mb")
      [[ -n "$cgroup_cpu_quota_pct" ]] && cmd+=(--cgroup-cpu-quota-pct "$cgroup_cpu_quota_pct")
      if [[ "$saga_auto_start_infra" == "yes" ]]; then cmd+=(--auto-start-infra); else cmd+=(--no-auto-start-infra); fi
      if [[ "$saga_auto_start_target" == "yes" ]]; then cmd+=(--auto-start-target); else cmd+=(--no-auto-start-target); fi
      [[ "$saga_skip_seed_verify" == "yes" ]] && cmd+=(--skip-seed-verify)
      if [[ "$enable_jfr" == "yes" ]]; then cmd+=(--enable-jfr); else cmd+=(--no-jfr); fi
      "${cmd[@]}"
      exit $?
      ;;
    *)
      echo "Constrained execution is not auto-dispatched for scenario '$scenario_id' (generic wrk/k6/h2load drivers have no cgroup enforcement)."
      echo "Profile generated under results/constrained; not dispatched."
      exit 0
      ;;
  esac
fi

# ---- e2e-shop-order-saga: dedicated baseline (single) / campaign (multi) ----
if [[ "$is_saga" == "yes" ]]; then
  warn_impairment_not_applied "e2e-shop-order-saga"
  if [[ "$target_mode" == "multi" ]]; then
    if [[ "$topology_mode" == "$TOPOLOGY_NETWORK" ]]; then
      warn "Saga campaign (run-e2e-shop-order-saga-campaign.sh) is local-only and auto-starts targets; it cannot drive remote WAN endpoints."
      echo "For WAN saga, run a single-target baseline against each remote endpoint. Profile generated; multi-target WAN saga not dispatched."
      exit 0
    fi
    if [[ "$tls_mode" != "auto" ]]; then
      warn "TLS toggle (tls=$tls_mode) on a saga campaign: BENCH_PROTOCOL_MODE_OVERRIDE/EXERIS_SSL_* are exported and apply to campaign-launched targets, but the campaign derives each target's health-check scheme from the asset matrix (no per-target --base-url). If a target's matrix scheme differs from '$tls_scheme', its readiness probe may not match the forced transport. For a clean TLS sweep run single-target baselines, or align the targets' matrix health_url scheme first."
    fi
    targets_csv="$(IFS=,; echo "${targets[*]}")"
    info "Dispatch: run-e2e-shop-order-saga-campaign.sh (targets=$targets_csv graph_track=$graph_track)"
    cmd=(
      "$REPO_ROOT/scripts/run-e2e-shop-order-saga-campaign.sh"
      --targets "$targets_csv"
      --graph-track "$graph_track"
      --profile "$hardware_profile"
      --output-dir "$output_dir"
    )
    [[ "$saga_skip_seed_verify" == "yes" ]] && cmd+=(--skip-seed-verify)
    "${cmd[@]}"
    exit $?
  fi

  info "Dispatch: run-e2e-shop-order-saga-baseline.sh (target=${targets[0]} graph_track=$graph_track contract=$contract_id)"
  cmd=(
    "$REPO_ROOT/scripts/run-e2e-shop-order-saga-baseline.sh"
    --contract-id "$contract_id"
    --target-app "${targets[0]}"
    --graph-track "$graph_track"
    --profile "$hardware_profile"
    --output-dir "$output_dir"
  )
  if [[ "$topology_mode" == "$TOPOLOGY_NETWORK" ]]; then
    cmd+=(--base-url "$app_endpoint")
  elif [[ "$tls_mode" != "auto" ]]; then
    cmd+=(--base-url "$(apply_url_scheme "$(resolve_local_base_url "${targets[0]}")" "$tls_scheme")")
  fi
  if [[ "$saga_auto_start_infra" == "yes" ]]; then cmd+=(--auto-start-infra); else cmd+=(--no-auto-start-infra); fi
  if [[ "$saga_auto_start_target" == "yes" ]]; then cmd+=(--auto-start-target); else cmd+=(--no-auto-start-target); fi
  [[ "$saga_skip_seed_verify" == "yes" ]] && cmd+=(--skip-seed-verify)
  if [[ "$enable_jfr" == "yes" ]]; then cmd+=(--enable-jfr); else cmd+=(--no-jfr); fi
  "${cmd[@]}"
  exit $?
fi

# ---- Multi-target: comparative ----
if [[ "$target_mode" == "multi" ]]; then
  warn_impairment_not_applied "run-comparative.sh (multi-target)"
  if [[ "$tls_mode" != "auto" ]]; then
    warn "TLS toggle (tls=$tls_mode) on a comparative run: run-comparative.sh drives pre-launched (launcher_mode=external) targets and derives each scheme from its asset-matrix health_url — the guided launcher cannot force TLS on externally-launched targets. Launch both targets with '$tls_scheme'/'$effective_transport' (or align their matrix health_url scheme) before this run, or the comparison is INVALID."
  fi
  info "Dispatch: run-comparative.sh"
  "$REPO_ROOT/scripts/run-comparative.sh" \
    --target-a "${targets[0]}" \
    --target-b "${targets[1]}" \
    --scenario-id "$scenario_id" \
    --contract-id "$contract_id" \
    --output-dir "$output_dir" \
    --measurement-seconds "$measurement_seconds" \
    --warmup-seconds "$warmup_seconds" \
    --threads "$threads" \
    --connections "$connections"
  exit $?
fi

# ---- entity-read-by-id (local): specialized runner ----
if [[ "$scenario_id" == "entity-read-by-id" && "$topology_mode" == "$TOPOLOGY_LOCAL" ]]; then
  warn_impairment_not_applied "run-entity-read-by-id.sh"
  mapped_runtime="$(map_entity_runtime "${targets[0]}")"
  # Honor the build chosen above (runtime_mode), not the target-name heuristic, so
  # a jvm-named community target can still be run as native and vice versa.
  mapped_build="$runtime_mode"
  mapped_backend_mode="$(map_entity_backend_mode "${targets[0]}")"

  # Forward the chosen load driver so the runner actually drives it (the runner
  # supports wrk + h2load; wrk2/k6 have dedicated runners and the runner will
  # reject them with guidance rather than silently running wrk). Profile-only /
  # no-driver selections fall back to the runner's historical wrk default.
  entity_driver="$driver"
  case "$entity_driver" in
    ""|none) entity_driver="wrk" ;;
  esac
  # The fixed contract is wrk-defined and comparison-eligible; h2load (and any
  # non-wrk driver) is exploratory-only and not comparable to wrk H1. Reject the
  # mismatch up front instead of minting a misleading comparison-eligible run.
  if [[ "$entity_driver" != "wrk" ]] && entity_local_contract_mode; then
    warn "Driver '$entity_driver' is exploratory-only for entity-read-by-id (fixed contract '$contract_id' is wrk-defined and comparison-eligible)."
    echo "Re-run without the fixed contract (exploratory) to use driver '$entity_driver'. Profile generated; not dispatched." >&2
    exit 3
  fi

  erbid_cmd=(
    env "BENCHMARK_SKIP_TARGET_BUILD=$skip_target_build"
    "$REPO_ROOT/scripts/run-entity-read-by-id.sh"
    --profile "$hardware_profile"
    --output-dir "$output_dir"
    --threads "$threads"
    --connections "$connections"
    --warmup "${warmup_seconds}s"
    --driver "$entity_driver"
    --target-runtime "$mapped_runtime"
    --target-build "$mapped_build"
    --backend-mode "$mapped_backend_mode"
  )
  # Map the resolved protocol onto the h2load axis so the run's HTTP version
  # matches the recorded protocol_mode (h2 = h2c cleartext prior-knowledge,
  # exploratory-only; h1 = loopback-h1). wrk is H1-only and takes no axis.
  if [[ "$entity_driver" == "h2load" ]]; then
    case "$protocol_mode" in
      h2) erbid_cmd+=(--h2load-axis h2c) ;;
      *)  erbid_cmd+=(--h2load-axis h1) ;;
    esac
  fi
  if entity_local_contract_mode; then
    # Strict fixed contract: workload/claim-scope/profile are contract-fixed and
    # --duration is rejected; the runner enforces its requirements (perf-box,
    # cpu-affinity). Workload was read from the contract above.
    erbid_cmd+=(--contract "$contract_id" --claim-scope comparison-eligible)
    [[ -n "$cpu_affinity" ]] && erbid_cmd+=(--cpu-affinity "$cpu_affinity")
    [[ -n "$client_cpu_affinity" ]] && erbid_cmd+=(--client-cpu-affinity "$client_cpu_affinity")
    info "Dispatch: run-entity-read-by-id.sh (contract=$contract_id, comparison-eligible, launch_mode=$launch_mode)"
  else
    # Free exploratory mode: no fixed contract, workload (incl. duration) honored.
    erbid_cmd+=(--claim-scope exploratory --duration "${measurement_seconds}s")
    [[ -n "$cpu_affinity" ]] && erbid_cmd+=(--cpu-affinity "$cpu_affinity")
    [[ -n "$client_cpu_affinity" ]] && erbid_cmd+=(--client-cpu-affinity "$client_cpu_affinity")
    info "Dispatch: run-entity-read-by-id.sh (exploratory free run, no fixed contract, launch_mode=$launch_mode)"
  fi
  [[ "$enable_jfr" == "yes" ]] && erbid_cmd+=(--enable-jfr)
  "${erbid_cmd[@]}"
  exit $?
fi

# ---- Generic driver dispatch (local or WAN) ----
if [[ "$driver" != "none" && -n "$driver" ]]; then
  if [[ "$scenario_id" == "entity-read-by-id" && "$topology_mode" == "$TOPOLOGY_NETWORK" ]]; then
    warn "WAN entity-read-by-id: skipping specialized seeding/preflight/gates — ensure the remote target is seeded and ready."
  fi
  apply_env_file_for_generic
  base_url="$(resolve_dispatch_base_url)"
  if [[ "$tls_mode" != "auto" ]]; then
    base_url="$(apply_url_scheme "$base_url" "$tls_scheme")"
    warn "TLS toggle (tls=$tls_mode): the load client targets '$base_url', but the generic driver path does NOT launch the target — ensure the pre-launched target is already serving '$tls_scheme' ($effective_transport)."
  fi
  maybe_apply_netem
  dispatch_generic_driver "$base_url"
  exit $?
fi

warn_impairment_not_applied "no auto-dispatch for scenario=$scenario_id"
echo "Dispatch is not implemented for scenario=$scenario_id with driver=$driver (target_mode=$target_mode)."
echo "This scenario uses a specialized harness (e.g. radamsa/jazzer/slowloris); use the dedicated run-*.sh script."
exit 0
