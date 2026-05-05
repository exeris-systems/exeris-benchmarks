#!/usr/bin/env bash
set -u

BENCH_OBSERVED_PROTOCOL_MODE="${BENCH_OBSERVED_PROTOCOL_MODE:-}"
BENCH_K6_OBSERVED_PROTOCOL_MODE="${BENCH_K6_OBSERVED_PROTOCOL_MODE:-}"
BENCH_K6_PROTO_TAGS_CSV="${BENCH_K6_PROTO_TAGS_CSV:-}"
BENCH_EFFECTIVE_PROTOCOL_MODE="${BENCH_EFFECTIVE_PROTOCOL_MODE:-}"
BENCH_EFFECTIVE_TRANSPORT_MODE="${BENCH_EFFECTIVE_TRANSPORT_MODE:-}"

bench_derive_protocol_mode_from_http_version() {
  local http_version="$1"
  local base_url="$2"
  case "$http_version" in
    2)
      if [[ "$base_url" == http://* ]]; then
        echo "h2c"
      elif [[ "$base_url" == https://* ]]; then
        echo "h2"
      else
        echo "unknown"
      fi
      ;;
    1.1|1.0)
      echo "h1"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

bench_derive_transport_mode() {
  local protocol_mode="$1"
  case "$protocol_mode" in
    h1)   echo "loopback-h1"      ;;
    h2)   echo "loopback-h2"      ;;
    h2c)  echo "loopback-h2c"     ;;
    *)    echo "loopback-unknown"  ;;
  esac
}

_bench_protocol_mode_from_asset_matrix() {
  local target_app_name="$1"
  command -v jq >/dev/null 2>&1 || return 1

  local matrix_path="${BENCH_TARGET_ASSET_MATRIX_PATH:-}"
  if [[ -z "$matrix_path" ]]; then
    local _self_dir
    _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    matrix_path="${_self_dir}/../../../runtime/drivers/target-asset-matrix.json"
  fi
  [[ -f "$matrix_path" ]] || return 1

  local mode
  mode="$(jq -r --arg id "$target_app_name" \
    '(.targets[]? | select(.target_id == $id) | .protocol_mode) // ""' \
    "$matrix_path" 2>/dev/null)"
  case "$mode" in
    h1|h2|h2c|https-h1) echo "$mode"; return 0 ;;
    *) return 1 ;;
  esac
}

bench_derive_declared_protocol_mode() {
  # Priority: explicit override > target-asset-matrix declaration > name-sniff fallback.
  # The matrix lookup prevents misclassification of targets whose names lack an
  # h1/h2/h2c token (e.g. "quarkus-app-axon"), which previously fell through to
  # the "h2" default and forced SSL onto an h2c-declared endpoint.
  if [[ -n "${BENCH_PROTOCOL_MODE_OVERRIDE:-}" ]]; then
    echo "$BENCH_PROTOCOL_MODE_OVERRIDE"
    return 0
  fi
  local target_app_name="$1"
  if _bench_protocol_mode_from_asset_matrix "$target_app_name"; then
    return 0
  fi
  local normalized
  normalized="$(printf '%s' "$target_app_name" | tr '[:upper:]' '[:lower:]')"
  if [[ "$normalized" == *"h2c"* ]]; then
    echo "h2c"
  elif [[ "$normalized" == *"h2"* ]]; then
    echo "h2"
  elif [[ "$normalized" == *"h1"* ]]; then
    echo "h1"
  else
    echo "h2"
  fi
}

bench_probe_observed_protocol_mode() {
  local base_url="$1"
  local health_url="${base_url}/health"
  local version protocol_mode

  BENCH_OBSERVED_PROTOCOL_MODE="unknown"

  if [[ "$base_url" == http://* ]]; then
    version="$(curl -sS --connect-timeout 3 --max-time 8 -o /dev/null -w '%{http_version}' \
      --http2-prior-knowledge "$health_url" 2>/dev/null || true)"
    protocol_mode="$(bench_derive_protocol_mode_from_http_version "$version" "$base_url")"
    if [[ "$protocol_mode" == "h2c" ]]; then
      BENCH_OBSERVED_PROTOCOL_MODE="h2c"
      return 0
    fi

    version="$(curl -sS --connect-timeout 3 --max-time 8 -o /dev/null -w '%{http_version}' \
      --http2 "$health_url" 2>/dev/null || true)"
    protocol_mode="$(bench_derive_protocol_mode_from_http_version "$version" "$base_url")"
    if [[ "$protocol_mode" == "h2c" ]]; then
      BENCH_OBSERVED_PROTOCOL_MODE="h2c"
      return 0
    fi

    version="$(curl -sS --connect-timeout 3 --max-time 8 -o /dev/null -w '%{http_version}' \
      "$health_url" 2>/dev/null || true)"
    BENCH_OBSERVED_PROTOCOL_MODE="$(bench_derive_protocol_mode_from_http_version "$version" "$base_url")"
    return 0
  fi

  if [[ "$base_url" == https://* ]]; then
    version="$(curl -sS -k --connect-timeout 3 --max-time 8 -o /dev/null -w '%{http_version}' \
      --http2 "$health_url" 2>/dev/null || true)"
    protocol_mode="$(bench_derive_protocol_mode_from_http_version "$version" "$base_url")"
    if [[ "$protocol_mode" == "h2" ]]; then
      BENCH_OBSERVED_PROTOCOL_MODE="h2"
      return 0
    fi

    version="$(curl -sS -k --connect-timeout 3 --max-time 8 -o /dev/null -w '%{http_version}' \
      "$health_url" 2>/dev/null || true)"
    BENCH_OBSERVED_PROTOCOL_MODE="$(bench_derive_protocol_mode_from_http_version "$version" "$base_url")"
    return 0
  fi

  BENCH_OBSERVED_PROTOCOL_MODE="unknown"
}

bench_derive_k6_protocol_mode_from_output() {
  local k6_output_json="$1"
  local base_url="$2"
  local proto_csv=""
  local has_h1="false"
  local has_h2="false"

  BENCH_K6_OBSERVED_PROTOCOL_MODE="unknown"
  BENCH_K6_PROTO_TAGS_CSV="unknown"

  if [[ -f "$k6_output_json" ]]; then
    proto_csv="$( (jq -r 'select(.type=="Point" and .data.tags.proto?) | .data.tags.proto' \
        "$k6_output_json" 2>/dev/null \
      | sed '/^null$/d;/^[[:space:]]*$/d' \
      | sort -u \
      | paste -sd, -) || true)"
    if [[ -n "$proto_csv" ]]; then
      BENCH_K6_PROTO_TAGS_CSV="$proto_csv"
    fi
  fi

  if [[ -z "$BENCH_K6_PROTO_TAGS_CSV" || "$BENCH_K6_PROTO_TAGS_CSV" == "unknown" ]]; then
    BENCH_K6_OBSERVED_PROTOCOL_MODE="unknown"
    return 0
  fi

  if printf '%s' "$BENCH_K6_PROTO_TAGS_CSV" | \
      grep -Eiq '(^|,)[[:space:]]*HTTP/1(\.[0-9]+)?([[:space:]]*|,|$)'; then
    has_h1="true"
  fi
  if printf '%s' "$BENCH_K6_PROTO_TAGS_CSV" | \
      grep -Eiq '(^|,)[[:space:]]*HTTP/2([[:space:]]*|,|$)'; then
    has_h2="true"
  fi

  if [[ "$has_h1" == "true" && "$has_h2" == "true" ]]; then
    BENCH_K6_OBSERVED_PROTOCOL_MODE="mixed"
    return 0
  fi

  if [[ "$has_h2" == "true" ]]; then
    if [[ "$base_url" == http://* ]]; then
      BENCH_K6_OBSERVED_PROTOCOL_MODE="h2c"
    else
      BENCH_K6_OBSERVED_PROTOCOL_MODE="h2"
    fi
    return 0
  fi

  if [[ "$has_h1" == "true" ]]; then
    BENCH_K6_OBSERVED_PROTOCOL_MODE="h1"
    return 0
  fi

  BENCH_K6_OBSERVED_PROTOCOL_MODE="unknown"
}

bench_finalize_protocol_mode() {
  local declared="$1"
  local observed="$2"
  local k6_observed="$3"

  BENCH_EFFECTIVE_PROTOCOL_MODE="$declared"

  if [[ "$observed" != "unknown" ]]; then
    BENCH_EFFECTIVE_PROTOCOL_MODE="$observed"
    if [[ "$observed" != "$declared" ]]; then
      echo "Warning: observed protocol '$observed' differs from declared '$declared'." >&2
    fi
  fi

  if [[ "$k6_observed" != "unknown" && "$k6_observed" != "mixed" ]]; then
    BENCH_EFFECTIVE_PROTOCOL_MODE="$k6_observed"
  elif [[ "$k6_observed" == "mixed" ]]; then
    echo "Warning: k6 observed mixed protocol tags; keeping effective protocol '$BENCH_EFFECTIVE_PROTOCOL_MODE'." >&2
  fi

  BENCH_EFFECTIVE_TRANSPORT_MODE="$(bench_derive_transport_mode "$BENCH_EFFECTIVE_PROTOCOL_MODE")"
}
