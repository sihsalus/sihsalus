#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "Usage: $0 <base URL> <40-character frontend git SHA> <expected node UUID> <environment label>" >&2
  exit 2
fi

BASE_URL="${1%/}"
EXPECTED_SHA="$2"
EXPECTED_NODE_ID="$3"
ENVIRONMENT_LABEL="$4"
SAMPLE_COUNT="${EXTERNAL_VERIFY_SAMPLE_COUNT:-12}"
SAMPLE_INTERVAL_SECONDS="${EXTERNAL_VERIFY_SAMPLE_INTERVAL_SECONDS:-5}"
CURL_TIMEOUT_SECONDS="${EXTERNAL_VERIFY_CURL_TIMEOUT_SECONDS:-3}"

if [[ ! "$BASE_URL" =~ ^https?://[^/?#]+$ ]]; then
  echo "[external-verify] invalid base URL: $BASE_URL" >&2
  exit 2
fi

if [[ ! "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "[external-verify] invalid expected frontend SHA" >&2
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

for command in curl jq sort awk; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "[external-verify] missing command: $command" >&2
    exit 2
  fi
done

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sihsalus-external-verify.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

SHA_OBSERVATIONS="$TEMP_ROOT/frontend-shas"
NODE_OBSERVATIONS="$TEMP_ROOT/node-identities"
REMOTE_OBSERVATIONS="$TEMP_ROOT/remote-addresses"
: >"$SHA_OBSERVATIONS"
: >"$NODE_OBSERVATIONS"
: >"$REMOTE_OBSERVATIONS"

failure_count=0

request() {
  local url="$1"
  local output_file="$2"
  local header_file="$3"

  curl \
    --http1.1 \
    --insecure \
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

record_endpoint_failure() {
  local sample="$1"
  local endpoint="$2"
  echo "::error::${ENVIRONMENT_LABEL} sample ${sample}/${SAMPLE_COUNT} failed at ${endpoint}." >&2
  failure_count=$((failure_count + 1))
}

echo "[external-verify] ${ENVIRONMENT_LABEL}: sampling ${SAMPLE_COUNT} independent connections every ${SAMPLE_INTERVAL_SECONDS}s"

for ((sample = 1; sample <= SAMPLE_COUNT; sample++)); do
  probe_id="${GITHUB_RUN_ID:-manual}-$$-${sample}"

  for endpoint in health ready openmrs/health/started; do
    if ! request \
      "${BASE_URL}/${endpoint}?external_probe=${probe_id}" \
      /dev/null \
      /dev/null >/dev/null; then
      record_endpoint_failure "$sample" "/${endpoint}"
      exit 1
    fi
  done

  body_file="$TEMP_ROOT/build-info-${sample}.json"
  header_file="$TEMP_ROOT/build-info-${sample}.headers"
  if remote_ip="$(request \
    "${BASE_URL}/openmrs/spa/build-info.json?release=${EXPECTED_SHA}&external_probe=${probe_id}" \
    "$body_file" \
    "$header_file")"; then
    actual_sha="$(jq -r '.gitSha // empty' "$body_file" 2>/dev/null || true)"
    if [[ ! "$actual_sha" =~ ^[0-9a-f]{40}$ ]]; then
      actual_sha='<invalid>'
      echo "::error::${ENVIRONMENT_LABEL} sample ${sample}/${SAMPLE_COUNT} returned invalid build-info.json." >&2
      failure_count=$((failure_count + 1))
    elif [ "$actual_sha" != "$EXPECTED_SHA" ]; then
      echo "::error::${ENVIRONMENT_LABEL} sample ${sample}/${SAMPLE_COUNT} serves frontend ${actual_sha}, expected ${EXPECTED_SHA}." >&2
      failure_count=$((failure_count + 1))
    fi
    printf '%s\n' "$actual_sha" >>"$SHA_OBSERVATIONS"

    if [[ ! "$remote_ip" =~ ^[0-9a-fA-F:.]+$ ]]; then
      remote_ip='<unknown>'
    fi
    printf '%s\n' "$remote_ip" >>"$REMOTE_OBSERVATIONS"

    node_id="$(
      awk '
        tolower($1) == "x-sihsalus-node-id:" {
          $1 = ""
          sub(/^ /, "")
          sub(/\r$/, "")
          value = $0
        }
        END { print value }
      ' "$header_file"
    )"
    if [ -z "$node_id" ]; then
      node_id='<not-exposed>'
      echo "::error::${ENVIRONMENT_LABEL} sample ${sample}/${SAMPLE_COUNT} did not expose X-SIHSALUS-Node-ID." >&2
      failure_count=$((failure_count + 1))
    elif [[ ! "$node_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
      node_id='<invalid>'
      echo "::error::${ENVIRONMENT_LABEL} sample ${sample}/${SAMPLE_COUNT} returned an invalid X-SIHSALUS-Node-ID header." >&2
      failure_count=$((failure_count + 1))
    elif [ "$node_id" != "$EXPECTED_NODE_ID" ]; then
      echo "::error::${ENVIRONMENT_LABEL} sample ${sample}/${SAMPLE_COUNT} came from node ${node_id}, expected ${EXPECTED_NODE_ID}." >&2
      failure_count=$((failure_count + 1))
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
unique_nodes="$(format_unique_observations "$NODE_OBSERVATIONS")"
unique_remotes="$(format_unique_observations "$REMOTE_OBSERVATIONS")"
unique_sha_count="$(count_unique_observations "$SHA_OBSERVATIONS")"
unique_node_count="$(count_unique_observations "$NODE_OBSERVATIONS")"
unique_remote_count="$(count_unique_observations "$REMOTE_OBSERVATIONS")"

echo "[external-verify] ${ENVIRONMENT_LABEL}: observed frontend SHA(s): ${unique_shas}"
echo "[external-verify] ${ENVIRONMENT_LABEL}: observed remote address(es): ${unique_remotes}"
echo "[external-verify] ${ENVIRONMENT_LABEL}: observed node identity/identities: ${unique_nodes}"

if [ "$unique_sha_count" -ne 1 ]; then
  echo "::error::${ENVIRONMENT_LABEL} exposed multiple or indeterminate frontend revisions during the verification window." >&2
  failure_count=$((failure_count + 1))
fi

if [ "$unique_node_count" -ne 1 ]; then
  echo "::error::${ENVIRONMENT_LABEL} exposed inconsistent node identities during the verification window." >&2
  failure_count=$((failure_count + 1))
fi

if [ "$unique_remote_count" -ne 1 ]; then
  echo "::error::${ENVIRONMENT_LABEL} resolved to inconsistent remote addresses during the verification window." >&2
  failure_count=$((failure_count + 1))
fi

if [ "$failure_count" -ne 0 ]; then
  echo "[external-verify] ${ENVIRONMENT_LABEL}: failed with ${failure_count} inconsistent or unhealthy observation(s)" >&2
  exit 1
fi

echo "[external-verify] ${ENVIRONMENT_LABEL}: all ${SAMPLE_COUNT} independent observations match ${EXPECTED_SHA}"
