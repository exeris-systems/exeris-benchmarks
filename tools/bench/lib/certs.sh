#!/usr/bin/env bash
# Helper functions for TLS certificate management
set -u

# ensure_smoke_cert_key(cert_path, key_path) — generates or validates smoke TLS cert/key pair
ensure_smoke_cert_key() {
  local cert_path="$1"
  local key_path="$2"
  local cert_dir
  cert_dir="$(dirname "$cert_path")"

  mkdir -p "$cert_dir" || {
    echo "ERROR: Unable to create certificate directory: $cert_dir" >&2
    return 1
  }

  if [[ ! -f "$cert_path" || ! -f "$key_path" ]]; then
    echo "Generating smoke TLS cert/key: $cert_path / $key_path"
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "$key_path" \
      -out "$cert_path" \
      -days 30 \
      -subj "/CN=exeris-bench-smoke" >/dev/null 2>&1 || {
      echo "ERROR: Failed to generate smoke cert/key via openssl." >&2
      return 1
    }
  fi

  if [[ ! -r "$cert_path" ]]; then
    echo "ERROR: Certificate file is missing or unreadable: $cert_path" >&2
    return 1
  fi
  if [[ ! -r "$key_path" ]]; then
    echo "ERROR: Private key file is missing or unreadable: $key_path" >&2
    return 1
  fi

  if ! grep -q '^-----BEGIN CERTIFICATE-----' "$cert_path"; then
    echo "ERROR: Invalid PEM certificate header in: $cert_path" >&2
    return 1
  fi

  if ! grep -Eq '^-----BEGIN (RSA |EC |PRIVATE )?PRIVATE KEY-----' "$key_path"; then
    echo "ERROR: Invalid PEM private key header in: $key_path" >&2
    return 1
  fi

  local cert_pub
  local key_pub
  cert_pub="$(openssl x509 -in "$cert_path" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform PEM 2>/dev/null)"
  key_pub="$(openssl pkey -in "$key_path" -pubout -outform PEM 2>/dev/null)"

  if [[ -z "$cert_pub" || -z "$key_pub" ]]; then
    echo "ERROR: Unable to parse cert/key material with openssl: $cert_path / $key_path" >&2
    return 1
  fi

  if [[ "$cert_pub" != "$key_pub" ]]; then
    echo "ERROR: Certificate and private key do not match: $cert_path / $key_path" >&2
    return 1
  fi
}

# cert_key_type(key_path) — returns normalized key type (rsa|ec|ed25519|ed448|unknown)
cert_key_type() {
  local key_path="$1"
  local key_info
  key_info=$(openssl pkey -in "$key_path" -text -noout -traditional 2>/dev/null | head -n 6 | tr '[:upper:]' '[:lower:]')
  if [[ -z "$key_info" ]]; then
    key_info=$(openssl pkey -in "$key_path" -text -noout 2>/dev/null | head -n 8 | tr '[:upper:]' '[:lower:]')
  fi
  if [[ "$key_info" == *"rsa private-key"* || "$key_info" == *"2 primes"* ]]; then
    echo "rsa"
  elif [[ "$key_info" == *"ec private-key"* || "$key_info" == *"asn1 oid"* ]]; then
    echo "ec"
  elif [[ "$key_info" == *"ed25519"* ]]; then
    echo "ed25519"
  elif [[ "$key_info" == *"ed448"* ]]; then
    echo "ed448"
  else
    echo "unknown"
  fi
}

# cert_key_bits(key_path) — returns key size in bits, or 0 when unknown
cert_key_bits() {
  local key_path="$1"
  local line
  line=$(openssl pkey -in "$key_path" -text -noout 2>/dev/null | awk 'NR==1 || /Private-Key:/ {print; exit}')
  if [[ "$line" =~ \(([0-9]+)\ bit ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "0"
  fi
}

# cert_key_type_and_size(key_path) — returns normalized key spec like rsa-2048
cert_key_type_and_size() {
  local key_path="$1"
  local actual_type
  local actual_bits
  actual_type=$(cert_key_type "$key_path")
  actual_bits=$(cert_key_bits "$key_path")
  echo "${actual_type}-${actual_bits}"
}

# assert_cert_key_type_and_size(key_path, expected_type, expected_bits)
assert_cert_key_type_and_size() {
  local key_path="$1"
  local expected_type="$2"
  local expected_bits="$3"
  local actual_type
  local actual_bits

  actual_type=$(cert_key_type "$key_path")
  actual_bits=$(cert_key_bits "$key_path")

  if [[ "$actual_type" != "$expected_type" ]]; then
    echo "ERROR: Expected key type '$expected_type' but got '$actual_type' for $key_path" >&2
    return 1
  fi

  if [[ ! "$actual_bits" =~ ^[0-9]+$ ]] || [[ "$actual_bits" -le 0 ]]; then
    echo "ERROR: Unable to determine key size for $key_path (got '$actual_bits')" >&2
    return 1
  fi

  if [[ "$actual_bits" -ne "$expected_bits" ]]; then
    echo "ERROR: Expected key size ${expected_bits} bits but got ${actual_bits} bits for $key_path" >&2
    return 1
  fi
}

# get_cert_fingerprint(cert_path) — returns SHA256 fingerprint of cert
get_cert_fingerprint() {
  local cert_path="$1"
  if [[ ! -r "$cert_path" ]]; then
    echo "" >&2
    return 1
  fi
  openssl x509 -in "$cert_path" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*Fingerprint=//'
}

# write_cert_metadata(cert_path, key_path, output_json) — writes cert metadata to JSON
write_cert_metadata() {
  local cert_path="$1"
  local key_path="$2"
  local output_json="$3"

  local fingerprint
  fingerprint="$(get_cert_fingerprint "$cert_path")" || fingerprint="UNKNOWN"

  cat > "$output_json" <<EOF
{
  "cert_path": "$cert_path",
  "key_path": "$key_path",
  "fingerprint_sha256": "$fingerprint",
  "generated_timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}
