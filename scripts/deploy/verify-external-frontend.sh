#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 5 ]; then
  echo "Usage: $0 <base URL> <40-character frontend git SHA> <sha256 source digest> <expected node UUID> <environment label>" >&2
  exit 2
fi

BASE_URL="${1%/}"
EXPECTED_SHA="$2"
EXPECTED_DIGEST="$3"
EXPECTED_NODE_ID="$4"
ENVIRONMENT_LABEL="$5"
SAMPLE_COUNT="${EXTERNAL_VERIFY_SAMPLE_COUNT:-12}"
SAMPLE_INTERVAL_SECONDS="${EXTERNAL_VERIFY_SAMPLE_INTERVAL_SECONDS:-5}"
CURL_TIMEOUT_SECONDS="${EXTERNAL_VERIFY_CURL_TIMEOUT_SECONDS:-10}"
CURL_ATTEMPTS="${EXTERNAL_VERIFY_CURL_ATTEMPTS:-3}"
CURL_RETRY_DELAY_SECONDS="${EXTERNAL_VERIFY_CURL_RETRY_DELAY_SECONDS:-2}"
TLS_CA_CERT_PATH="${EXTERNAL_VERIFY_TLS_CA_CERT_PATH:-}"
TLS_INSECURE="${EXTERNAL_VERIFY_TLS_INSECURE:-false}"
TLS_PINNED_PUBLIC_KEY="${EXTERNAL_VERIFY_TLS_PINNED_PUBLIC_KEY:-}"

if [[ ! "$BASE_URL" =~ ^https://[^/?#]+$ ]]; then
  echo "[external-verify] base URL must be an HTTPS origin: $BASE_URL" >&2
  exit 2
fi

if [[ ! "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "[external-verify] invalid expected frontend SHA" >&2
  exit 2
fi

if [[ ! "$EXPECTED_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "[external-verify] invalid expected frontend source digest" >&2
  exit 2
fi

if [[ ! "$EXPECTED_NODE_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  echo "[external-verify] invalid expected node UUID" >&2
  exit 2
fi

if [[ ! "$SAMPLE_COUNT" =~ ^[0-9]+$ ]] || [ "$SAMPLE_COUNT" -lt 2 ]; then
  echo "[external-verify] EXTERNAL_VERIFY_SAMPLE_COUNT must be an integer of at least 2" >&2
  exit 2
fi

if [[ ! "$SAMPLE_INTERVAL_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "[external-verify] EXTERNAL_VERIFY_SAMPLE_INTERVAL_SECONDS must be a non-negative integer" >&2
  exit 2
fi

if [[ ! "$CURL_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "[external-verify] EXTERNAL_VERIFY_CURL_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi

if [[ ! "$CURL_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
  echo "[external-verify] EXTERNAL_VERIFY_CURL_ATTEMPTS must be a positive integer" >&2
  exit 2
fi

if [[ ! "$CURL_RETRY_DELAY_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "[external-verify] EXTERNAL_VERIFY_CURL_RETRY_DELAY_SECONDS must be a non-negative integer" >&2
  exit 2
fi

case "$TLS_INSECURE" in
  true | false)
    ;;
  *)
    echo "[external-verify] EXTERNAL_VERIFY_TLS_INSECURE must be true or false" >&2
    exit 2
    ;;
esac

if [ -n "$TLS_PINNED_PUBLIC_KEY" ] &&
  [[ ! "$TLS_PINNED_PUBLIC_KEY" =~ ^sha256//[A-Za-z0-9+/]{43}=$ ]]; then
  echo "[external-verify] EXTERNAL_VERIFY_TLS_PINNED_PUBLIC_KEY must be one sha256// SPKI pin" >&2
  exit 2
fi

if [ "$TLS_INSECURE" = true ] && [ -z "$TLS_PINNED_PUBLIC_KEY" ]; then
  echo "[external-verify] TLS verification may be disabled only when a protected SPKI pin is also verified" >&2
  exit 2
fi

if [ -n "$TLS_CA_CERT_PATH" ] && [ ! -r "$TLS_CA_CERT_PATH" ]; then
  echo "[external-verify] EXTERNAL_VERIFY_TLS_CA_CERT_PATH is not readable" >&2
  exit 2
fi

for command in curl jq sort awk; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "[external-verify] missing command: $command" >&2
    exit 2
  fi
done

CURL_COMMAND=(curl)
if [ -n "$TLS_CA_CERT_PATH" ]; then
  CURL_COMMAND+=(--cacert "$TLS_CA_CERT_PATH")
fi
if [ -n "$TLS_PINNED_PUBLIC_KEY" ]; then
  CURL_COMMAND+=(--pinnedpubkey "$TLS_PINNED_PUBLIC_KEY")
fi
if [ "$TLS_INSECURE" = true ]; then
  CURL_COMMAND+=(--insecure)
fi

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sihsalus-external-verify.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

SHA_OBSERVATIONS="$TEMP_ROOT/frontend-shas"
DIGEST_OBSERVATIONS="$TEMP_ROOT/frontend-digests"
NODE_OBSERVATIONS="$TEMP_ROOT/node-identities"
REMOTE_OBSERVATIONS="$TEMP_ROOT/remote-addresses"
: >"$SHA_OBSERVATIONS"
: >"$DIGEST_OBSERVATIONS"
: >"$NODE_OBSERVATIONS"
: >"$REMOTE_OBSERVATIONS"

other_failure_count=0
missing_digest_count=0

request() {
  local url="$1"
  local output_file="$2"
  local header_file="$3"

  "${CURL_COMMAND[@]}" \
    --http1.1 \
    --fail \
    --silent \
    --show-error \
    --connect-timeout "$CURL_TIMEOUT_SECONDS" \
    --max-time "$CURL_TIMEOUT_SECONDS" \
    --header 'Cache-Control: no-cache, no-store, must-revalidate' \
    --header 'Pragma: no-cache' \
    --header 'Connection: close' \
    --dump-header "$header_file" \
    --output "$output_file" \
    --write-out '%{remote_ip}' \
    -- "$url"
}

# Un sondeo abre TCP+TLS nuevo (Connection: close) contra un host al otro lado
# del continente. La cola de latencia de ese handshake supera de vez en cuando
# el presupuesto y tumbaba el despliegue sin que nada estuviera mal: el servidor
# responde en ~20 ms medido en el propio host. Se reintenta solo el fallo de
# transporte; las garantias de contenido (SHA, node-id) siguen sin tolerancia.
request_with_retry() {
  local url="$1"
  local output_file="$2"
  local header_file="$3"
  local attempt=1
  local response=''

  while :; do
    if response="$(request "$url" "$output_file" "$header_file")"; then
      printf '%s' "$response"
      return 0
    fi

    if [ "$attempt" -ge "$CURL_ATTEMPTS" ]; then
      return 1
    fi

    echo "[external-verify] ${ENVIRONMENT_LABEL}: transport attempt ${attempt}/${CURL_ATTEMPTS} failed for ${url%%\?*}; retrying" >&2
    attempt=$((attempt + 1))
    if [ "$CURL_RETRY_DELAY_SECONDS" -gt 0 ]; then
      sleep "$CURL_RETRY_DELAY_SECONDS"
    fi
  done
}

header_value() {
  local header_name="$1"
  local header_file="$2"

  awk -v expected="${header_name}:" '
    tolower($1) == tolower(expected) {
      $1 = ""
      sub(/^ /, "")
      sub(/\r$/, "")
      value = $0
    }
    END { print value }
  ' "$header_file"
}

record_endpoint_failure() {
  local sample="$1"
  local endpoint="$2"
  echo "::error::${ENVIRONMENT_LABEL} sample ${sample}/${SAMPLE_COUNT} failed at ${endpoint}." >&2
  other_failure_count=$((other_failure_count + 1))
}

echo "[external-verify] ${ENVIRONMENT_LABEL}: sampling ${SAMPLE_COUNT} independent authenticated TLS connections every ${SAMPLE_INTERVAL_SECONDS}s"

for ((sample = 1; sample <= SAMPLE_COUNT; sample++)); do
  probe_id="${GITHUB_RUN_ID:-manual}-$$-${sample}"

  for endpoint in health ready openmrs/health/started; do
    if ! request_with_retry \
      "${BASE_URL}/${endpoint}?external_probe=${probe_id}" \
      /dev/null \
      /dev/null >/dev/null; then
      record_endpoint_failure "$sample" "/${endpoint}"
      exit 1
    fi
  done

  body_file="$TEMP_ROOT/build-info-${sample}.json"
  header_file="$TEMP_ROOT/build-info-${sample}.headers"
  if remote_ip="$(request_with_retry \
    "${BASE_URL}/openmrs/spa/build-info.json?release=${EXPECTED_SHA}&digest=${EXPECTED_DIGEST}&external_probe=${probe_id}" \
    "$body_file" \
    "$header_file")"; then
    actual_sha="$(jq -r '.gitSha // empty' "$body_file" 2>/dev/null || true)"
    if [[ ! "$actual_sha" =~ ^[0-9a-f]{40}$ ]]; then
      actual_sha='<invalid>'
      echo "::error::${ENVIRONMENT_LABEL} sample ${sample}/${SAMPLE_COUNT} returned invalid build-info.json." >&2
      other_failure_count=$((other_failure_count + 1))
    elif [ "$actual_sha" != "$EXPECTED_SHA" ]; then
      echo "::error::${ENVIRONMENT_LABEL} sample ${sample}/${SAMPLE_COUNT} serves frontend ${actual_sha}, expected ${EXPECTED_SHA}." >&2
      other_failure_count=$((other_failure_count + 1))
    fi
    printf '%s\n' "$actual_sha" >>"$SHA_OBSERVATIONS"

    actual_digest="$(header_value X-SIHSALUS-Frontend-Digest "$header_file")"
    if [ -z "$actual_digest" ]; then
      actual_digest='<not-exposed>'
      echo "::warning::${ENVIRONMENT_LABEL} sample ${sample}/${SAMPLE_COUNT} did not expose X-SIHSALUS-Frontend-Digest." >&2
      missing_digest_count=$((missing_digest_count + 1))
    elif [[ ! "$actual_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      actual_digest='<invalid>'
      echo "::error::${ENVIRONMENT_LABEL} sample ${sample}/${SAMPLE_COUNT} returned an invalid X-SIHSALUS-Frontend-Digest header." >&2
      other_failure_count=$((other_failure_count + 1))
    elif [ "$actual_digest" != "$EXPECTED_DIGEST" ]; then
      echo "::error::${ENVIRONMENT_LABEL} sample ${sample}/${SAMPLE_COUNT} serves source digest ${actual_digest}, expected ${EXPECTED_DIGEST}." >&2
      other_failure_count=$((other_failure_count + 1))
    fi
    printf '%s\n' "$actual_digest" >>"$DIGEST_OBSERVATIONS"

    if [[ ! "$remote_ip" =~ ^[0-9a-fA-F:.]+$ ]]; then
      remote_ip='<unknown>'
    fi
    printf '%s\n' "$remote_ip" >>"$REMOTE_OBSERVATIONS"

    node_id="$(header_value X-SIHSALUS-Node-ID "$header_file")"
    if [ -z "$node_id" ]; then
      node_id='<not-exposed>'
      echo "::error::${ENVIRONMENT_LABEL} sample ${sample}/${SAMPLE_COUNT} did not expose X-SIHSALUS-Node-ID." >&2
      other_failure_count=$((other_failure_count + 1))
    elif [[ ! "$node_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
      node_id='<invalid>'
      echo "::error::${ENVIRONMENT_LABEL} sample ${sample}/${SAMPLE_COUNT} returned an invalid X-SIHSALUS-Node-ID header." >&2
      other_failure_count=$((other_failure_count + 1))
    elif [ "$node_id" != "$EXPECTED_NODE_ID" ]; then
      echo "::error::${ENVIRONMENT_LABEL} sample ${sample}/${SAMPLE_COUNT} came from node ${node_id}, expected ${EXPECTED_NODE_ID}." >&2
      other_failure_count=$((other_failure_count + 1))
    fi
    printf '%s\n' "$node_id" >>"$NODE_OBSERVATIONS"
  else
    record_endpoint_failure "$sample" '/openmrs/spa/build-info.json'
    exit 1
  fi

  if [ "$sample" -lt "$SAMPLE_COUNT" ] && [ "$SAMPLE_INTERVAL_SECONDS" -gt 0 ]; then
    sleep "$SAMPLE_INTERVAL_SECONDS"
  fi
done

format_unique_observations() {
  sort -u "$1" |
    awk '{ values = values (values == "" ? "" : " ") $0 } END { print values }'
}

count_unique_observations() {
  sort -u "$1" | awk 'END { print NR }'
}

unique_shas="$(format_unique_observations "$SHA_OBSERVATIONS")"
unique_digests="$(format_unique_observations "$DIGEST_OBSERVATIONS")"
unique_nodes="$(format_unique_observations "$NODE_OBSERVATIONS")"
unique_remotes="$(format_unique_observations "$REMOTE_OBSERVATIONS")"
unique_sha_count="$(count_unique_observations "$SHA_OBSERVATIONS")"
unique_digest_count="$(count_unique_observations "$DIGEST_OBSERVATIONS")"
unique_node_count="$(count_unique_observations "$NODE_OBSERVATIONS")"
unique_remote_count="$(count_unique_observations "$REMOTE_OBSERVATIONS")"

echo "[external-verify] ${ENVIRONMENT_LABEL}: observed frontend SHA(s): ${unique_shas}"
echo "[external-verify] ${ENVIRONMENT_LABEL}: observed source digest(s): ${unique_digests}"
echo "[external-verify] ${ENVIRONMENT_LABEL}: observed remote address(es): ${unique_remotes}"
echo "[external-verify] ${ENVIRONMENT_LABEL}: observed node identity/identities: ${unique_nodes}"

if [ "$unique_sha_count" -ne 1 ]; then
  echo "::error::${ENVIRONMENT_LABEL} exposed multiple or indeterminate frontend revisions during the verification window." >&2
  other_failure_count=$((other_failure_count + 1))
fi

if [ "$unique_digest_count" -ne 1 ]; then
  echo "::error::${ENVIRONMENT_LABEL} exposed multiple or indeterminate frontend source digests during the verification window." >&2
  other_failure_count=$((other_failure_count + 1))
fi

if [ "$unique_node_count" -ne 1 ]; then
  echo "::error::${ENVIRONMENT_LABEL} exposed inconsistent node identities during the verification window." >&2
  other_failure_count=$((other_failure_count + 1))
fi

if [ "$unique_remote_count" -ne 1 ]; then
  echo "::error::${ENVIRONMENT_LABEL} resolved to inconsistent remote addresses during the verification window." >&2
  other_failure_count=$((other_failure_count + 1))
fi

if [ "$other_failure_count" -ne 0 ]; then
  echo "[external-verify] ${ENVIRONMENT_LABEL}: failed with ${other_failure_count} inconsistent or unhealthy observation(s)" >&2
  exit 1
fi

# Exit 3 is deliberately narrow: it permits the production bootstrap path to
# replace only missing digest-header evidence with an exact, identity-bound
# remote inspection. Invalid, mixed, or mismatched digest observations fail.
if [ "$missing_digest_count" -eq "$SAMPLE_COUNT" ] &&
  [ "$unique_digests" = '<not-exposed>' ]; then
  echo "[external-verify] ${ENVIRONMENT_LABEL}: digest header is not yet exposed; exact remote bootstrap evidence is required" >&2
  exit 3
fi

if [ "$missing_digest_count" -ne 0 ]; then
  echo "[external-verify] ${ENVIRONMENT_LABEL}: digest identity was exposed inconsistently" >&2
  exit 1
fi

echo "[external-verify] ${ENVIRONMENT_LABEL}: all ${SAMPLE_COUNT} observations match SHA ${EXPECTED_SHA}, digest ${EXPECTED_DIGEST}, and node ${EXPECTED_NODE_ID}"
