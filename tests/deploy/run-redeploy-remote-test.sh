#!/usr/bin/env bash

set -euo pipefail

# Keep negative identity tests deterministic when this suite runs inside a
# deployment job that defines the protected environment at job scope.
unset REDEPLOY_EXPECTED_REMOTE_MAC REDEPLOY_EXPECTED_NODE_ID REDEPLOY_REMOTE_MAC_PATH

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$ROOT/scripts/deploy/run-redeploy-remote.sh"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sihsalus-remote-redeploy-test.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

FAKE_BIN="$TEMP_ROOT/bin"
REMOTE_REPOSITORY="$TEMP_ROOT/remote/sihsalus"
SSH_KEY="$TEMP_ROOT/deploy-key"
REMOTE_MAC_PATH="$TEMP_ROOT/remote-mac"
EXPECTED_REMOTE_MAC='00:0c:29:ad:be:90'
EXPECTED_NODE_ID='3eb58bb0-ff08-4e2d-839c-11cedca0b043'
mkdir -p "$FAKE_BIN" "$REMOTE_REPOSITORY"
: >"$SSH_KEY"
printf '%s\n' "$EXPECTED_REMOTE_MAC" >"$REMOTE_MAC_PATH"

cat >"$FAKE_BIN/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
set -euo pipefail

while [ "$#" -gt 0 ]; do
  case "$1" in
    -i | -o)
      shift 2
      ;;
    -*)
      echo "unexpected fake SSH option: $1" >&2
      exit 2
      ;;
    *)
      shift
      break
      ;;
  esac
done

if [ "$#" -eq 1 ]; then
  if [[ "$1" == *"install -d"* ]] && [ -n "${FAKE_SSH_UPLOAD_FAILURES:-}" ]; then
    upload_attempt=0
    if [ -f "${FAKE_SSH_UPLOAD_COUNTER_FILE}" ]; then
      upload_attempt="$(cat "${FAKE_SSH_UPLOAD_COUNTER_FILE}")"
    fi
    if [ "$upload_attempt" -lt "$FAKE_SSH_UPLOAD_FAILURES" ]; then
      printf '%s\n' "$((upload_attempt + 1))" >"${FAKE_SSH_UPLOAD_COUNTER_FILE}"
      echo "simulated upload disconnect" >&2
      exit 255
    fi
  fi
  exec bash -c "$1"
fi

if [ "$#" -eq 10 ] && [ "$1" = bash ] && [ "$2" = -s ] &&
  [ "${FAKE_SSH_LAUNCH_MAC_MISMATCH:-false}" = true ]; then
  printf '%s\n' '00:0c:29:86:a3:3b' >"${FAKE_REMOTE_MAC_PATH}"
  set +e
  "$@"
  launch_code="$?"
  set -e
  printf '%s\n' "${FAKE_EXPECTED_REMOTE_MAC}" >"${FAKE_REMOTE_MAC_PATH}"
  exit "$launch_code"
fi

if [ "$#" -eq 7 ] && [ "$1" = bash ] && [ "$2" = -s ] &&
  [[ "${6:-}" == */redeploy.log ]] && [ -n "${FAKE_SSH_LOG_MISMATCHES:-}" ]; then
  log_attempt=0
  if [ -f "${FAKE_SSH_LOG_COUNTER_FILE}" ]; then
    log_attempt="$(cat "${FAKE_SSH_LOG_COUNTER_FILE}")"
  fi
  if [ "$log_attempt" -lt "$FAKE_SSH_LOG_MISMATCHES" ]; then
    printf '%s\n' "$((log_attempt + 1))" >"${FAKE_SSH_LOG_COUNTER_FILE}"
    printf '%s\n' '00:0c:29:86:a3:3b' >"${FAKE_REMOTE_MAC_PATH}"
    set +e
    "$@"
    log_code="$?"
    set -e
    printf '%s\n' "${FAKE_EXPECTED_REMOTE_MAC}" >"${FAKE_REMOTE_MAC_PATH}"
    exit "$log_code"
  fi
fi

if [ "$#" -eq 10 ] && [ "$1" = bash ] && [ "$2" = -s ] &&
  [ -n "${FAKE_SSH_FORCE_LAUNCH_ERROR:-}" ]; then
  echo 'simulated launch failure' >&2
  exit "$FAKE_SSH_FORCE_LAUNCH_ERROR"
fi

if [ "$#" -eq 7 ] && [ "$1" = bash ] && [ "$2" = -s ] &&
  [ -n "${FAKE_SSH_CANCEL_FAILURES:-}" ]; then
  cancel_attempt=0
  if [ -f "${FAKE_SSH_CANCEL_COUNTER_FILE}" ]; then
    cancel_attempt="$(cat "${FAKE_SSH_CANCEL_COUNTER_FILE}")"
  fi
  if [ "$cancel_attempt" -lt "$FAKE_SSH_CANCEL_FAILURES" ]; then
    printf '%s\n' "$((cancel_attempt + 1))" >"${FAKE_SSH_CANCEL_COUNTER_FILE}"
    echo 'simulated cancellation on the wrong host' >&2
    exit 86
  fi
fi

if [ "$#" -eq 10 ] && [ "$1" = bash ] && [ "$2" = -s ] &&
  [ -n "${FAKE_SSH_BREAK_LAUNCH_FILE:-}" ] && [ ! -f "$FAKE_SSH_BREAK_LAUNCH_FILE" ]; then
  set +e
  "$@"
  launch_code="$?"
  set -e
  : >"$FAKE_SSH_BREAK_LAUNCH_FILE"
  if [ "$launch_code" -ne 0 ]; then
    exit "$launch_code"
  fi
  echo "simulated post-launch disconnect" >&2
  exit 255
fi

exec "$@"
FAKE_SSH

cat >"$FAKE_BIN/setsid" <<'FAKE_SETSID'
#!/usr/bin/env bash
exec "$@"
FAKE_SETSID

cat >"$FAKE_BIN/flock" <<'FAKE_FLOCK'
#!/usr/bin/env bash
exit 0
FAKE_FLOCK

chmod 700 "$FAKE_BIN/ssh" "$FAKE_BIN/setsid" "$FAKE_BIN/flock"

SUCCESS_FIXTURE="$TEMP_ROOT/success.sh"
cat >"$SUCCESS_FIXTURE" <<'SUCCESS_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
[ "${SIHSALUS_NODE_ID:-}" = '3eb58bb0-ff08-4e2d-839c-11cedca0b043' ]
echo "fixture started"
sleep 1
echo "fixture completed"
SUCCESS_SCRIPT

FAILURE_FIXTURE="$TEMP_ROOT/failure.sh"
cat >"$FAILURE_FIXTURE" <<'FAILURE_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
echo "fixture failed as requested"
exit 42
FAILURE_SCRIPT

chmod 700 "$SUCCESS_FIXTURE" "$FAILURE_FIXTURE"

BACKEND_SHA="1111111111111111111111111111111111111111"
BACKEND_DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

MISSING_IDENTITY_OUTPUT="$TEMP_ROOT/missing-identity-output.log"
set +e
PATH="$FAKE_BIN:$PATH" \
  SSH_BIN="$FAKE_BIN/ssh" \
  REDEPLOY_SCRIPT_PATH="$SUCCESS_FIXTURE" \
  bash "$RUNNER" \
  "$SSH_KEY" deploy@example.test "$REMOTE_REPOSITORY" \
  "$BACKEND_SHA" "$BACKEND_DIGEST" missing-identity-run >"$MISSING_IDENTITY_OUTPUT" 2>&1
missing_identity_code="$?"
set -e

[ "$missing_identity_code" -eq 2 ]
grep -Fq 'REDEPLOY_EXPECTED_REMOTE_MAC is required' "$MISSING_IDENTITY_OUTPUT"
[ ! -e "$REMOTE_REPOSITORY/.redeploy-runs/missing-identity-run" ]

MISSING_NODE_OUTPUT="$TEMP_ROOT/missing-node-output.log"
set +e
PATH="$FAKE_BIN:$PATH" \
  SSH_BIN="$FAKE_BIN/ssh" \
  REDEPLOY_SCRIPT_PATH="$SUCCESS_FIXTURE" \
  REDEPLOY_EXPECTED_REMOTE_MAC="$EXPECTED_REMOTE_MAC" \
  REDEPLOY_REMOTE_MAC_PATH="$REMOTE_MAC_PATH" \
  bash "$RUNNER" \
  "$SSH_KEY" deploy@example.test "$REMOTE_REPOSITORY" \
  "$BACKEND_SHA" "$BACKEND_DIGEST" missing-node-run >"$MISSING_NODE_OUTPUT" 2>&1
missing_node_code="$?"
set -e

[ "$missing_node_code" -eq 2 ]
grep -Fq 'REDEPLOY_EXPECTED_NODE_ID is required' "$MISSING_NODE_OUTPUT"
[ ! -e "$REMOTE_REPOSITORY/.redeploy-runs/missing-node-run" ]

SUCCESS_OUTPUT="$TEMP_ROOT/success-output.log"
PATH="$FAKE_BIN:$PATH" \
  SSH_BIN="$FAKE_BIN/ssh" \
  FAKE_SSH_UPLOAD_FAILURES=2 \
  FAKE_SSH_UPLOAD_COUNTER_FILE="$TEMP_ROOT/upload-attempts" \
  FAKE_SSH_BREAK_LAUNCH_FILE="$TEMP_ROOT/launch-disconnect" \
  REDEPLOY_SCRIPT_PATH="$SUCCESS_FIXTURE" \
  REDEPLOY_INITIAL_TRANSPORT_ATTEMPTS=5 \
  REDEPLOY_POLL_INTERVAL_SECONDS=1 \
  REDEPLOY_TIMEOUT_SECONDS=15 \
  REDEPLOY_EXPECTED_REMOTE_MAC="$EXPECTED_REMOTE_MAC" \
  REDEPLOY_EXPECTED_NODE_ID="$EXPECTED_NODE_ID" \
  REDEPLOY_REMOTE_MAC_PATH="$REMOTE_MAC_PATH" \
  bash "$RUNNER" \
  "$SSH_KEY" deploy@example.test "$REMOTE_REPOSITORY" \
  "$BACKEND_SHA" "$BACKEND_DIGEST" success-run >"$SUCCESS_OUTPUT" 2>&1

grep -Fq 'upload transport failure 1/5; retrying' "$SUCCESS_OUTPUT"
grep -Fq 'upload transport failure 2/5; retrying' "$SUCCESS_OUTPUT"
grep -Fq 'launch transport failure 1/5; retrying' "$SUCCESS_OUTPUT"
grep -Fq 'resuming its monitor' "$SUCCESS_OUTPUT"
grep -Fq 'fixture started' "$SUCCESS_OUTPUT"
grep -Fq 'fixture completed' "$SUCCESS_OUTPUT"
grep -Fq 'detached run completed successfully' "$SUCCESS_OUTPUT"
[ "$(cat "$REMOTE_REPOSITORY/.redeploy-runs/success-run/status")" = 0 ]
[ -x "$REMOTE_REPOSITORY/.redeploy-runs/success-run/check-clean-checkout.sh" ]
cmp "$ROOT/scripts/deploy/check-clean-checkout.sh" \
  "$REMOTE_REPOSITORY/.redeploy-runs/success-run/check-clean-checkout.sh"

FAILURE_OUTPUT="$TEMP_ROOT/failure-output.log"
set +e
PATH="$FAKE_BIN:$PATH" \
  SSH_BIN="$FAKE_BIN/ssh" \
  REDEPLOY_SCRIPT_PATH="$FAILURE_FIXTURE" \
  REDEPLOY_POLL_INTERVAL_SECONDS=1 \
  REDEPLOY_TIMEOUT_SECONDS=15 \
  REDEPLOY_EXPECTED_REMOTE_MAC="$EXPECTED_REMOTE_MAC" \
  REDEPLOY_EXPECTED_NODE_ID="$EXPECTED_NODE_ID" \
  REDEPLOY_REMOTE_MAC_PATH="$REMOTE_MAC_PATH" \
  bash "$RUNNER" \
  "$SSH_KEY" deploy@example.test "$REMOTE_REPOSITORY" \
  "$BACKEND_SHA" "$BACKEND_DIGEST" failure-run >"$FAILURE_OUTPUT" 2>&1
failure_code="$?"
set -e

[ "$failure_code" -eq 42 ]
grep -Fq 'fixture failed as requested' "$FAILURE_OUTPUT"
grep -Fq 'detached run failed with exit code 42' "$FAILURE_OUTPUT"
[ "$(cat "$REMOTE_REPOSITORY/.redeploy-runs/failure-run/status")" = 42 ]

MISMATCH_OUTPUT="$TEMP_ROOT/mismatch-output.log"
set +e
PATH="$FAKE_BIN:$PATH" \
  SSH_BIN="$FAKE_BIN/ssh" \
  REDEPLOY_SCRIPT_PATH="$SUCCESS_FIXTURE" \
  REDEPLOY_POLL_INTERVAL_SECONDS=1 \
  REDEPLOY_TIMEOUT_SECONDS=15 \
  REDEPLOY_EXPECTED_REMOTE_MAC='00:0c:29:86:a3:3b' \
  REDEPLOY_EXPECTED_NODE_ID="$EXPECTED_NODE_ID" \
  REDEPLOY_REMOTE_MAC_PATH="$REMOTE_MAC_PATH" \
  REDEPLOY_CANCEL_ATTEMPTS=1 \
  bash "$RUNNER" \
  "$SSH_KEY" deploy@example.test "$REMOTE_REPOSITORY" \
  "$BACKEND_SHA" "$BACKEND_DIGEST" mismatch-run >"$MISMATCH_OUTPUT" 2>&1
mismatch_code="$?"
set -e

[ "$mismatch_code" -eq 86 ]
grep -Fq "remote MAC $EXPECTED_REMOTE_MAC does not match expected 00:0c:29:86:a3:3b" "$MISMATCH_OUTPUT"
[ ! -e "$REMOTE_REPOSITORY/.redeploy-runs/mismatch-run" ]

LAUNCH_MISMATCH_OUTPUT="$TEMP_ROOT/launch-mismatch-output.log"
set +e
PATH="$FAKE_BIN:$PATH" \
  SSH_BIN="$FAKE_BIN/ssh" \
  FAKE_SSH_LAUNCH_MAC_MISMATCH=true \
  FAKE_REMOTE_MAC_PATH="$REMOTE_MAC_PATH" \
  FAKE_EXPECTED_REMOTE_MAC="$EXPECTED_REMOTE_MAC" \
  REDEPLOY_SCRIPT_PATH="$SUCCESS_FIXTURE" \
  REDEPLOY_POLL_INTERVAL_SECONDS=1 \
  REDEPLOY_TIMEOUT_SECONDS=15 \
  REDEPLOY_EXPECTED_REMOTE_MAC="$EXPECTED_REMOTE_MAC" \
  REDEPLOY_EXPECTED_NODE_ID="$EXPECTED_NODE_ID" \
  REDEPLOY_REMOTE_MAC_PATH="$REMOTE_MAC_PATH" \
  bash "$RUNNER" \
  "$SSH_KEY" deploy@example.test "$REMOTE_REPOSITORY" \
  "$BACKEND_SHA" "$BACKEND_DIGEST" launch-mismatch-run >"$LAUNCH_MISMATCH_OUTPUT" 2>&1
launch_mismatch_code="$?"
set -e

[ "$launch_mismatch_code" -eq 86 ]
grep -Fq 'remote MAC 00:0c:29:86:a3:3b does not match expected' "$LAUNCH_MISMATCH_OUTPUT"
[ -f "$REMOTE_REPOSITORY/.redeploy-runs/launch-mismatch-run/redeploy-environment.sh" ]
[ ! -e "$REMOTE_REPOSITORY/.redeploy-runs/launch-mismatch-run/pid" ]

POLL_MISMATCH_OUTPUT="$TEMP_ROOT/poll-mismatch-output.log"
set +e
PATH="$FAKE_BIN:$PATH" \
  SSH_BIN="$FAKE_BIN/ssh" \
  FAKE_SSH_LOG_MISMATCHES=1 \
  FAKE_SSH_LOG_COUNTER_FILE="$TEMP_ROOT/log-mismatch-attempts" \
  FAKE_REMOTE_MAC_PATH="$REMOTE_MAC_PATH" \
  FAKE_EXPECTED_REMOTE_MAC="$EXPECTED_REMOTE_MAC" \
  REDEPLOY_SCRIPT_PATH="$SUCCESS_FIXTURE" \
  REDEPLOY_POLL_INTERVAL_SECONDS=1 \
  REDEPLOY_TIMEOUT_SECONDS=15 \
  REDEPLOY_EXPECTED_REMOTE_MAC="$EXPECTED_REMOTE_MAC" \
  REDEPLOY_EXPECTED_NODE_ID="$EXPECTED_NODE_ID" \
  REDEPLOY_REMOTE_MAC_PATH="$REMOTE_MAC_PATH" \
  bash "$RUNNER" \
  "$SSH_KEY" deploy@example.test "$REMOTE_REPOSITORY" \
  "$BACKEND_SHA" "$BACKEND_DIGEST" poll-mismatch-run >"$POLL_MISMATCH_OUTPUT" 2>&1
poll_mismatch_code="$?"
set -e

[ "$poll_mismatch_code" -eq 86 ]
[ "$(cat "$REMOTE_REPOSITORY/.redeploy-runs/poll-mismatch-run/status")" -eq 0 ]
grep -Fq 'remote identity mismatch observed while reading logs' "$POLL_MISMATCH_OUTPUT"
grep -Fq 'deployment completed on the expected host, but another host answered' "$POLL_MISMATCH_OUTPUT"

CANCEL_RETRY_OUTPUT="$TEMP_ROOT/cancel-retry-output.log"
set +e
PATH="$FAKE_BIN:$PATH" \
  SSH_BIN="$FAKE_BIN/ssh" \
  FAKE_SSH_FORCE_LAUNCH_ERROR=87 \
  FAKE_SSH_CANCEL_FAILURES=1 \
  FAKE_SSH_CANCEL_COUNTER_FILE="$TEMP_ROOT/cancel-attempts" \
  REDEPLOY_SCRIPT_PATH="$SUCCESS_FIXTURE" \
  REDEPLOY_POLL_INTERVAL_SECONDS=1 \
  REDEPLOY_TIMEOUT_SECONDS=15 \
  REDEPLOY_EXPECTED_REMOTE_MAC="$EXPECTED_REMOTE_MAC" \
  REDEPLOY_EXPECTED_NODE_ID="$EXPECTED_NODE_ID" \
  REDEPLOY_REMOTE_MAC_PATH="$REMOTE_MAC_PATH" \
  REDEPLOY_CANCEL_ATTEMPTS=3 \
  REDEPLOY_CANCEL_RETRY_INTERVAL_SECONDS=1 \
  bash "$RUNNER" \
  "$SSH_KEY" deploy@example.test "$REMOTE_REPOSITORY" \
  "$BACKEND_SHA" "$BACKEND_DIGEST" cancel-retry-run >"$CANCEL_RETRY_OUTPUT" 2>&1
cancel_retry_code="$?"
set -e

[ "$cancel_retry_code" -eq 87 ]
[ "$(cat "$TEMP_ROOT/cancel-attempts")" -eq 1 ]
grep -Fq 'cancel reached the wrong host or lost transport; retrying 1/3' "$CANCEL_RETRY_OUTPUT"
if grep -Fq 'remote cancellation was not confirmed' "$CANCEL_RETRY_OUTPUT"; then
  echo 'cancellation retry did not reach the expected host' >&2
  exit 1
fi

echo "[OK] resilient remote redeploy runner"
