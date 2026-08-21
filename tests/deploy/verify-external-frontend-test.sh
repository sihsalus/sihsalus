#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFIER="$ROOT/scripts/deploy/verify-external-frontend.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sihsalus-external-verify-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_BIN="$TEST_ROOT/bin"
FAKE_STATE_DIR="$TEST_ROOT/state"
mkdir -p "$FAKE_BIN" "$FAKE_STATE_DIR"

cat >"$FAKE_BIN/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail

output_file=/dev/stdout
header_file=/dev/null
write_out=''
url=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    --connect-timeout | --max-time | --header | --dump-header | --output | --write-out)
      option="$1"
      value="$2"
      shift 2
      case "$option" in
        --dump-header) header_file="$value" ;;
        --output) output_file="$value" ;;
        --write-out) write_out="$value" ;;
      esac
      ;;
    --http1.1 | --insecure | --fail | --silent | --show-error)
      shift
      ;;
    --)
      shift
      url="${1:-}"
      shift || true
      ;;
    *)
      echo "unexpected curl argument: $1" >&2
      exit 90
      ;;
  esac
done

if [ -z "$url" ]; then
  echo "fake curl did not receive a URL" >&2
  exit 91
fi

printf '%s\n' "$url" >>"$FAKE_STATE_DIR/requests"

if [ "$FAKE_CURL_MODE" = endpoint-failure ] &&
  [[ "$url" == *'/ready?'* ]] && [[ "$url" == *'-2' ]]; then
  echo 'simulated ready failure' >&2
  exit 22
fi

node_id="$FAKE_TARGET_NODE_ID"
remote_ip='203.0.113.10'
sha="$FAKE_TARGET_SHA"

if [[ "$url" == *'/openmrs/spa/build-info.json?'* ]]; then
  build_request=0
  if [ -f "$FAKE_STATE_DIR/build-requests" ]; then
    build_request="$(cat "$FAKE_STATE_DIR/build-requests")"
  fi
  build_request=$((build_request + 1))
  printf '%s\n' "$build_request" >"$FAKE_STATE_DIR/build-requests"

  case "$FAKE_CURL_MODE" in
    consistent | endpoint-failure)
      ;;
    no-node)
      node_id=''
      ;;
    unconfigured-node)
      node_id='unconfigured'
      ;;
    mismatch)
      sha="$FAKE_BAD_SHA"
      ;;
    split-sha)
      if [ $((build_request % 2)) -eq 0 ]; then
        sha="$FAKE_BAD_SHA"
        node_id="$FAKE_BAD_NODE_ID"
      fi
      ;;
    split-node)
      if [ $((build_request % 2)) -eq 0 ]; then
        node_id="$FAKE_BAD_NODE_ID"
      fi
      ;;
    mismatch-node)
      node_id="$FAKE_BAD_NODE_ID"
      ;;
    split-remote)
      if [ $((build_request % 2)) -eq 0 ]; then
        remote_ip='203.0.113.11'
      fi
      ;;
    build-request-failure)
      if [ "$build_request" -eq 2 ]; then
        echo 'simulated build-info failure' >&2
        exit 22
      fi
      ;;
    *)
      echo "unknown fake curl mode: $FAKE_CURL_MODE" >&2
      exit 92
      ;;
  esac

  {
    printf 'HTTP/1.1 200 OK\r\n'
    if [ -n "$node_id" ]; then
      printf 'X-SIHSALUS-Node-ID: %s\r\n' "$node_id"
    fi
    printf '\r\n'
  } >"$header_file"
  printf '{"gitSha":"%s"}\n' "$sha" >"$output_file"
else
  printf 'HTTP/1.1 200 OK\r\n\r\n' >"$header_file"
  if [ "$output_file" != /dev/null ]; then
    printf 'ok\n' >"$output_file"
  fi
fi

if [ -n "$write_out" ]; then
  [ "$write_out" = '%{remote_ip}' ]
  printf '%s' "$remote_ip"
fi
FAKE_CURL

chmod 700 "$FAKE_BIN/curl"

TARGET_SHA='1111111111111111111111111111111111111111'
BAD_SHA='2222222222222222222222222222222222222222'
TARGET_NODE_ID='3eb58bb0-ff08-4e2d-839c-11cedca0b043'
BAD_NODE_ID='8bdba72f-dedf-4cc0-9081-a534c564966b'

run_verifier() {
  local mode="$1"
  local output="$2"

  rm -f "$FAKE_STATE_DIR/requests" "$FAKE_STATE_DIR/build-requests"
  PATH="$FAKE_BIN:$PATH" \
    FAKE_STATE_DIR="$FAKE_STATE_DIR" \
    FAKE_CURL_MODE="$mode" \
    FAKE_TARGET_SHA="$TARGET_SHA" \
    FAKE_BAD_SHA="$BAD_SHA" \
    FAKE_TARGET_NODE_ID="$TARGET_NODE_ID" \
    FAKE_BAD_NODE_ID="$BAD_NODE_ID" \
    EXTERNAL_VERIFY_SAMPLE_COUNT=4 \
    EXTERNAL_VERIFY_SAMPLE_INTERVAL_SECONDS=0 \
    EXTERNAL_VERIFY_CURL_TIMEOUT_SECONDS=2 \
    EXTERNAL_VERIFY_CURL_ATTEMPTS="${TEST_CURL_ATTEMPTS:-3}" \
    EXTERNAL_VERIFY_CURL_RETRY_DELAY_SECONDS=0 \
    bash "$VERIFIER" https://example.test "$TARGET_SHA" "$TARGET_NODE_ID" TEST >"$output" 2>&1
}

assert_fails() {
  local mode="$1"
  local output="$TEST_ROOT/${mode}.log"

  if run_verifier "$mode" "$output"; then
    echo "verifier unexpectedly accepted mode: $mode" >&2
    exit 1
  fi
}

bash -n "$VERIFIER"

consistent_output="$TEST_ROOT/consistent.log"
run_verifier consistent "$consistent_output"
grep -Fq "observed frontend SHA(s): $TARGET_SHA" "$consistent_output"
grep -Fq "observed node identity/identities: $TARGET_NODE_ID" "$consistent_output"
grep -Fq 'all 4 independent observations match' "$consistent_output"
[ "$(wc -l <"$FAKE_STATE_DIR/requests" | tr -d ' ')" -eq 16 ]
[ "$(cat "$FAKE_STATE_DIR/build-requests")" -eq 4 ]

no_node_output="$TEST_ROOT/no-node.log"
if run_verifier no-node "$no_node_output"; then
  echo 'verifier accepted a response without node identity' >&2
  exit 1
fi
grep -Fq 'observed node identity/identities: <not-exposed>' "$no_node_output"
grep -Fq 'did not expose X-SIHSALUS-Node-ID' "$no_node_output"

assert_fails unconfigured-node
grep -Fq 'returned an invalid X-SIHSALUS-Node-ID header' "$TEST_ROOT/unconfigured-node.log"

assert_fails mismatch-node
grep -Fq "came from node $BAD_NODE_ID, expected $TARGET_NODE_ID" "$TEST_ROOT/mismatch-node.log"

assert_fails mismatch
grep -Fq "serves frontend $BAD_SHA, expected $TARGET_SHA" "$TEST_ROOT/mismatch.log"

assert_fails split-sha
grep -Fq "observed frontend SHA(s): $TARGET_SHA $BAD_SHA" "$TEST_ROOT/split-sha.log"
grep -Fq 'exposed multiple or indeterminate frontend revisions' "$TEST_ROOT/split-sha.log"

assert_fails split-node
grep -Fq "observed node identity/identities: $TARGET_NODE_ID $BAD_NODE_ID" "$TEST_ROOT/split-node.log"
grep -Fq 'exposed inconsistent node identities' "$TEST_ROOT/split-node.log"

assert_fails split-remote
grep -Fq 'observed remote address(es): 203.0.113.10 203.0.113.11' "$TEST_ROOT/split-remote.log"

assert_fails endpoint-failure
grep -Fq 'sample 2/4 failed at /ready' "$TEST_ROOT/endpoint-failure.log"

# Sin reintentos, un unico fallo de transporte sigue rechazando: la severidad
# original del gate se conserva y se puede recuperar con una variable.
TEST_CURL_ATTEMPTS=1 assert_fails build-request-failure
grep -Fq 'sample 2/4 failed at /openmrs/spa/build-info.json' "$TEST_ROOT/build-request-failure.log"

# Con reintentos (por defecto), ese mismo parpadeo puntual se tolera: el fallo
# simulado afecta solo a la segunda peticion, asi que el reintento la resuelve.
# Es el caso real que tumbaba despliegues sanos desde runners transcontinentales.
transient_output="$TEST_ROOT/build-request-transient.log"
run_verifier build-request-failure "$transient_output"
grep -Fq 'transport attempt 1/3 failed' "$transient_output"
grep -Fq 'all 4 independent observations match' "$transient_output"
# 16 peticiones nominales + el reintento.
[ "$(wc -l <"$FAKE_STATE_DIR/requests" | tr -d ' ')" -eq 17 ]

# Un fallo persistente (misma URL siempre) agota los reintentos y rechaza.
assert_fails endpoint-failure
grep -Fq 'transport attempt 2/3 failed' "$TEST_ROOT/endpoint-failure.log"
grep -Fq 'sample 2/4 failed at /ready' "$TEST_ROOT/endpoint-failure.log"

invalid_count_output="$TEST_ROOT/invalid-count.log"
if PATH="$FAKE_BIN:$PATH" \
  EXTERNAL_VERIFY_SAMPLE_COUNT=1 \
  bash "$VERIFIER" https://example.test "$TARGET_SHA" "$TARGET_NODE_ID" TEST >"$invalid_count_output" 2>&1; then
  echo 'verifier accepted a single sample' >&2
  exit 1
fi
grep -Fq 'must be an integer of at least 2' "$invalid_count_output"

echo '[OK] split-brain-resistant external frontend verification'
