#!/usr/bin/env bash

set -euo pipefail

# Keep negative identity tests deterministic when this suite runs inside a
# deployment job that defines the protected environment at job scope.
unset REDEPLOY_EXPECTED_REMOTE_MAC REDEPLOY_EXPECTED_NODE_ID REDEPLOY_REMOTE_MAC_PATH

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$ROOT/scripts/deploy/run-redeploy-remote.sh"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sihsalus-remote-redeploy-test.XXXXXX")"
trap 'if [ "${KEEP_TEST_ROOT:-false}" = true ]; then echo "test files retained at $TEMP_ROOT" >&2; else rm -rf "$TEMP_ROOT"; fi' EXIT

FAKE_BIN="$TEMP_ROOT/bin"
REMOTE_REPOSITORY="$TEMP_ROOT/remote/sihsalus"
SSH_KEY="$TEMP_ROOT/deploy-key"
REMOTE_MAC_PATH="$TEMP_ROOT/remote-mac"
FAKE_PROC_ROOT="$TEMP_ROOT/proc"
EXPECTED_REMOTE_MAC='00:0c:29:ad:be:90'
EXPECTED_NODE_ID='3eb58bb0-ff08-4e2d-839c-11cedca0b043'
mkdir -p "$FAKE_BIN" "$REMOTE_REPOSITORY" "$FAKE_PROC_ROOT"
export FAKE_PROC_ROOT
export REDEPLOY_REMOTE_PROC_ROOT="$FAKE_PROC_ROOT"
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

if [ "$#" -eq 11 ] && [ "$1" = bash ] && [ "$2" = -s ] &&
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

if [ "$#" -eq 11 ] && [ "$1" = bash ] && [ "$2" = -s ] &&
  [ -n "${FAKE_SSH_FORCE_LAUNCH_ERROR:-}" ]; then
  echo 'simulated launch failure' >&2
  exit "$FAKE_SSH_FORCE_LAUNCH_ERROR"
fi

if [ "$#" -eq 9 ] && [ "$1" = bash ] && [ "$2" = -s ] &&
  [[ "${9:-}" == */launch.claim ]] &&
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

if [ "$#" -eq 11 ] && [ "$1" = bash ] && [ "$2" = -s ] &&
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

# The monitor starts its timeout clock when this launch call returns. Cases that
# exercise a two-second budget must not also race the detached worker's startup,
# which on a loaded CI runner can take longer than the budget itself, so hold the
# launch open until the worker published the evidence the case depends on.
if [ "$#" -eq 11 ] && [ "$1" = bash ] && [ "$2" = -s ] &&
  [ -n "${FAKE_SSH_LAUNCH_WAIT_LOG:-}" ]; then
  set +e
  "$@"
  launch_code="$?"
  set -e
  if [ "$launch_code" -ne 0 ]; then
    exit "$launch_code"
  fi
  for _ in $(seq 1 1200); do
    if [ -f "$FAKE_SSH_LAUNCH_WAIT_LOG" ] &&
      grep -Fq "$FAKE_SSH_LAUNCH_WAIT_PATTERN" "$FAKE_SSH_LAUNCH_WAIT_LOG"; then
      exit 0
    fi
    sleep 0.1
  done
  echo "fake SSH never observed remote evidence: $FAKE_SSH_LAUNCH_WAIT_PATTERN" >&2
  exit 1
fi

exec "$@"
FAKE_SSH

cat >"$FAKE_BIN/setsid" <<'FAKE_SETSID'
#!/usr/bin/env python3
import os
import sys

os.setsid()
pid = os.getpid()
fields = [
    str(pid),
    "(remote-redeploy-worker)",
    "S",
    str(os.getppid()),
    str(os.getpgrp()),
    str(os.getsid(0)),
] + ["0"] * 15 + [str(pid * 1000)]
proc_dir = os.path.join(os.environ["FAKE_PROC_ROOT"], str(pid))
os.makedirs(proc_dir, exist_ok=True)
with open(os.path.join(proc_dir, "stat"), "w", encoding="utf-8") as stat_file:
    stat_file.write(" ".join(fields) + "\n")
os.execvp(sys.argv[1], sys.argv[1:])
FAKE_SETSID

cat >"$FAKE_BIN/flock" <<'FAKE_FLOCK'
#!/usr/bin/env bash
set -euo pipefail
if [ "$*" = '-n 9' ] && [ -n "${FAKE_FLOCK_PRE_DEPLOY_MARKER:-}" ]; then
  : >"$FAKE_FLOCK_PRE_DEPLOY_MARKER"
  trap 'exit 0' TERM HUP
  while [ ! -e "${FAKE_FLOCK_PRE_DEPLOY_RELEASE}" ]; do
    sleep 0.1
  done
fi
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

TRANSACTION_FIXTURE="$TEMP_ROOT/transaction.sh"
cat >"$TRANSACTION_FIXTURE" <<'TRANSACTION_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
[ "${FRONTEND_EXTERNAL_BASE_URL:-}" = 'https://prod.example.test' ]
[ "${FRONTEND_EXTERNAL_ENVIRONMENT_LABEL:-}" = 'PROD' ]
[ "${FRONTEND_CURRENT_SHA:-}" = '2222222222222222222222222222222222222222' ]
[ "${FRONTEND_CURRENT_DIGEST:-}" = 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ]
[ "${DEPLOY_FRONTEND_DISTRO_SHA:-}" = 'dddddddddddddddddddddddddddddddddddddddd' ]
[ "${EXTERNAL_VERIFY_TLS_INSECURE:-}" = true ]
[ "${EXTERNAL_VERIFY_TLS_PINNED_PUBLIC_KEY:-}" = 'sha256//AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' ]
[ -z "${EXTERNAL_VERIFY_TLS_CA_CERT_PATH:-}" ]
[ "${EXTERNAL_VERIFY_SAMPLE_COUNT:-}" = 12 ]
[ "${EXTERNAL_VERIFY_SAMPLE_INTERVAL_SECONDS:-}" = 5 ]
[ "${EXTERNAL_VERIFY_CURL_TIMEOUT_SECONDS:-}" = 3 ]
[ -z "${DEPLOY_FRONTEND_EXTERNAL_VERIFIER_PATH:-}" ]
[ -x "$(dirname "$0")/verify-external-frontend.sh" ]
[ "${FRONTEND_TRANSACTION_STATE_PATH:-}" = "$(dirname "$0")/frontend-transaction.state" ]
printf '%s\n' committed >"$FRONTEND_TRANSACTION_STATE_PATH"
echo 'transaction fixture completed'
TRANSACTION_SCRIPT

DUMMY_VERIFIER="$TEMP_ROOT/verify-external-frontend.sh"
cat >"$DUMMY_VERIFIER" <<'VERIFIER_SCRIPT'
#!/usr/bin/env bash
exit 0
VERIFIER_SCRIPT

CANCELLATION_FIXTURE="$TEMP_ROOT/cancellation.sh"
cat >"$CANCELLATION_FIXTURE" <<'CANCELLATION_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
trap 'echo "fixture canceled"; exit 143' TERM HUP
echo 'cancellation fixture started'
while true; do
  sleep 1
done
CANCELLATION_SCRIPT

COMMITTED_CLEANUP_FIXTURE="$TEMP_ROOT/committed-cleanup.sh"
cat >"$COMMITTED_CLEANUP_FIXTURE" <<'COMMITTED_CLEANUP_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
trap 'echo "committed cleanup interrupted"; exit 0' TERM HUP
printf '%s\n' committed >"$FRONTEND_TRANSACTION_STATE_PATH"
echo 'public verification passed and transaction committed'
while true; do
  sleep 1
done
COMMITTED_CLEANUP_SCRIPT

COMMITTED_SIGNAL_FIXTURE="$TEMP_ROOT/committed-signal.sh"
cat >"$COMMITTED_SIGNAL_FIXTURE" <<'COMMITTED_SIGNAL_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
trap 'echo "committed release received a late signal"; exit 143' TERM HUP
printf '%s\n' committed >"$FRONTEND_TRANSACTION_STATE_PATH"
echo 'public verification passed and transaction committed'
while true; do
  sleep 1
done
COMMITTED_SIGNAL_SCRIPT

EARLY_CANCEL_FIXTURE="$TEMP_ROOT/early-cancel.sh"
cat >"$EARLY_CANCEL_FIXTURE" <<'EARLY_CANCEL_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
: >"${FAKE_EARLY_CANCEL_EXECUTED}"
printf '%s\n' committed >"$FRONTEND_TRANSACTION_STATE_PATH"
EARLY_CANCEL_SCRIPT

chmod 700 "$SUCCESS_FIXTURE" "$FAILURE_FIXTURE" "$TRANSACTION_FIXTURE" "$DUMMY_VERIFIER" \
  "$CANCELLATION_FIXTURE" "$COMMITTED_CLEANUP_FIXTURE" "$COMMITTED_SIGNAL_FIXTURE" \
  "$EARLY_CANCEL_FIXTURE"

BACKEND_SHA="1111111111111111111111111111111111111111"
BACKEND_DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
DISTRO_SHA="dddddddddddddddddddddddddddddddddddddddd"

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
grep -Eq '^[1-9][0-9]* [1-9][0-9]*$' "$REMOTE_REPOSITORY/.redeploy-runs/success-run/pid"
[ -x "$REMOTE_REPOSITORY/.redeploy-runs/success-run/check-clean-checkout.sh" ]
cmp "$ROOT/scripts/deploy/check-clean-checkout.sh" \
  "$REMOTE_REPOSITORY/.redeploy-runs/success-run/check-clean-checkout.sh"

TRANSACTION_OUTPUT="$TEMP_ROOT/transaction-output.log"
PATH="$FAKE_BIN:$PATH" \
  SSH_BIN="$FAKE_BIN/ssh" \
  REDEPLOY_SCRIPT_PATH="$TRANSACTION_FIXTURE" \
  EXTERNAL_VERIFIER_PATH="$DUMMY_VERIFIER" \
  REDEPLOY_POLL_INTERVAL_SECONDS=1 \
  REDEPLOY_TIMEOUT_SECONDS=15 \
  REDEPLOY_EXPECTED_REMOTE_MAC="$EXPECTED_REMOTE_MAC" \
  REDEPLOY_EXPECTED_NODE_ID="$EXPECTED_NODE_ID" \
  REDEPLOY_REMOTE_MAC_PATH="$REMOTE_MAC_PATH" \
  REDEPLOY_FRONTEND_BASE_URL=https://prod.example.test \
  REDEPLOY_FRONTEND_CURRENT_SHA=2222222222222222222222222222222222222222 \
  REDEPLOY_FRONTEND_CURRENT_DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  REDEPLOY_FRONTEND_DISTRO_SHA="$DISTRO_SHA" \
  REDEPLOY_FRONTEND_ENVIRONMENT_LABEL=PROD \
  REDEPLOY_FRONTEND_TLS_INSECURE=true \
  REDEPLOY_FRONTEND_TLS_PINNED_PUBLIC_KEY=sha256//AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= \
  bash "$RUNNER" \
  "$SSH_KEY" deploy@example.test "$REMOTE_REPOSITORY" \
  "$BACKEND_SHA" "$BACKEND_DIGEST" transaction-run >"$TRANSACTION_OUTPUT" 2>&1

grep -Fq 'transaction fixture completed' "$TRANSACTION_OUTPUT"
[ "$(cat "$REMOTE_REPOSITORY/.redeploy-runs/transaction-run/status")" = 0 ]
[ -x "$REMOTE_REPOSITORY/.redeploy-runs/transaction-run/verify-external-frontend.sh" ]
if grep -Fq 'sha256//AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' "$TRANSACTION_OUTPUT"; then
  echo 'protected TLS pin leaked to deployment logs' >&2
  exit 1
fi

UNPINNED_OUTPUT="$TEMP_ROOT/unpinned-output.log"
set +e
PATH="$FAKE_BIN:$PATH" \
  SSH_BIN="$FAKE_BIN/ssh" \
  REDEPLOY_SCRIPT_PATH="$TRANSACTION_FIXTURE" \
  EXTERNAL_VERIFIER_PATH="$DUMMY_VERIFIER" \
  REDEPLOY_EXPECTED_REMOTE_MAC="$EXPECTED_REMOTE_MAC" \
  REDEPLOY_EXPECTED_NODE_ID="$EXPECTED_NODE_ID" \
  REDEPLOY_REMOTE_MAC_PATH="$REMOTE_MAC_PATH" \
  REDEPLOY_FRONTEND_BASE_URL=https://prod.example.test \
  REDEPLOY_FRONTEND_CURRENT_SHA=2222222222222222222222222222222222222222 \
  REDEPLOY_FRONTEND_CURRENT_DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  REDEPLOY_FRONTEND_DISTRO_SHA="$DISTRO_SHA" \
  REDEPLOY_FRONTEND_TLS_INSECURE=true \
  bash "$RUNNER" \
  "$SSH_KEY" deploy@example.test "$REMOTE_REPOSITORY" \
  "$BACKEND_SHA" "$BACKEND_DIGEST" unpinned-run >"$UNPINNED_OUTPUT" 2>&1
unpinned_code="$?"
set -e
[ "$unpinned_code" -eq 2 ]
grep -Fq 'insecure TLS requires a protected SPKI pin' "$UNPINNED_OUTPUT"
[ ! -e "$REMOTE_REPOSITORY/.redeploy-runs/unpinned-run" ]

CANCELLATION_OUTPUT="$TEMP_ROOT/cancellation-output.log"
PATH="$FAKE_BIN:$PATH" \
  SSH_BIN="$FAKE_BIN/ssh" \
  REDEPLOY_SCRIPT_PATH="$CANCELLATION_FIXTURE" \
  REDEPLOY_POLL_INTERVAL_SECONDS=1 \
  REDEPLOY_TIMEOUT_SECONDS=30 \
  REDEPLOY_EXPECTED_REMOTE_MAC="$EXPECTED_REMOTE_MAC" \
  REDEPLOY_EXPECTED_NODE_ID="$EXPECTED_NODE_ID" \
  REDEPLOY_REMOTE_MAC_PATH="$REMOTE_MAC_PATH" \
  bash "$RUNNER" \
  "$SSH_KEY" deploy@example.test "$REMOTE_REPOSITORY" \
  "$BACKEND_SHA" "$BACKEND_DIGEST" cancellation-run >"$CANCELLATION_OUTPUT" 2>&1 &
cancellation_monitor_pid="$!"

cancellation_started=false
for _ in $(seq 1 100); do
  if [ -f "$REMOTE_REPOSITORY/.redeploy-runs/cancellation-run/redeploy.log" ] &&
    grep -Fq 'cancellation fixture started' "$REMOTE_REPOSITORY/.redeploy-runs/cancellation-run/redeploy.log"; then
    cancellation_started=true
    break
  fi
  sleep 0.1
done
if [ "$cancellation_started" != true ]; then
  echo 'remote cancellation fixture did not start' >&2
  exit 1
fi

kill -TERM "$cancellation_monitor_pid"
set +e
wait "$cancellation_monitor_pid"
cancellation_monitor_code="$?"
set -e
[ "$cancellation_monitor_code" -eq 143 ]

cancellation_finished=false
for _ in $(seq 1 100); do
  if [ -f "$REMOTE_REPOSITORY/.redeploy-runs/cancellation-run/status" ]; then
    cancellation_finished=true
    break
  fi
  sleep 0.1
done
if [ "$cancellation_finished" != true ]; then
  echo 'remote cancellation did not produce a terminal status' >&2
  exit 1
fi
[ "$(cat "$REMOTE_REPOSITORY/.redeploy-runs/cancellation-run/status")" = 143 ]
grep -Fq 'fixture canceled' "$REMOTE_REPOSITORY/.redeploy-runs/cancellation-run/redeploy.log"
grep -Eq '(local monitor stopped; terminating the detached remote run|initialization failed; terminating a possible detached run)' \
  "$CANCELLATION_OUTPUT"

TIMEOUT_OUTPUT="$TEMP_ROOT/timeout-output.log"
set +e
PATH="$FAKE_BIN:$PATH" \
  SSH_BIN="$FAKE_BIN/ssh" \
  FAKE_SSH_LAUNCH_WAIT_LOG="$REMOTE_REPOSITORY/.redeploy-runs/timeout-run/redeploy.log" \
  FAKE_SSH_LAUNCH_WAIT_PATTERN='cancellation fixture started' \
  REDEPLOY_SCRIPT_PATH="$CANCELLATION_FIXTURE" \
  REDEPLOY_POLL_INTERVAL_SECONDS=1 \
  REDEPLOY_TIMEOUT_SECONDS=2 \
  REDEPLOY_EXPECTED_REMOTE_MAC="$EXPECTED_REMOTE_MAC" \
  REDEPLOY_EXPECTED_NODE_ID="$EXPECTED_NODE_ID" \
  REDEPLOY_REMOTE_MAC_PATH="$REMOTE_MAC_PATH" \
  bash "$RUNNER" \
  "$SSH_KEY" deploy@example.test "$REMOTE_REPOSITORY" \
  "$BACKEND_SHA" "$BACKEND_DIGEST" timeout-run >"$TIMEOUT_OUTPUT" 2>&1
timeout_code="$?"
set -e
[ "$timeout_code" -eq 124 ]
grep -Fq 'remote run exceeded 2s' "$TIMEOUT_OUTPUT"
grep -Fq 'local monitor stopped; terminating the detached remote run' "$TIMEOUT_OUTPUT"

timeout_finished=false
for _ in $(seq 1 100); do
  if [ -f "$REMOTE_REPOSITORY/.redeploy-runs/timeout-run/status" ]; then
    timeout_finished=true
    break
  fi
  sleep 0.1
done
if [ "$timeout_finished" != true ]; then
  echo 'timed-out remote run did not produce a terminal status' >&2
  exit 1
fi
[ "$(cat "$REMOTE_REPOSITORY/.redeploy-runs/timeout-run/status")" = 143 ]
grep -Fq 'fixture canceled' "$REMOTE_REPOSITORY/.redeploy-runs/timeout-run/redeploy.log"

COMMITTED_TIMEOUT_OUTPUT="$TEMP_ROOT/committed-timeout-output.log"
PATH="$FAKE_BIN:$PATH" \
  SSH_BIN="$FAKE_BIN/ssh" \
  FAKE_SSH_LAUNCH_WAIT_LOG="$REMOTE_REPOSITORY/.redeploy-runs/committed-timeout-run/redeploy.log" \
  FAKE_SSH_LAUNCH_WAIT_PATTERN='public verification passed and transaction committed' \
  REDEPLOY_SCRIPT_PATH="$COMMITTED_CLEANUP_FIXTURE" \
  EXTERNAL_VERIFIER_PATH="$DUMMY_VERIFIER" \
  REDEPLOY_POLL_INTERVAL_SECONDS=1 \
  REDEPLOY_TIMEOUT_SECONDS=2 \
  REDEPLOY_CANCEL_RETRY_INTERVAL_SECONDS=1 \
  REDEPLOY_EXPECTED_REMOTE_MAC="$EXPECTED_REMOTE_MAC" \
  REDEPLOY_EXPECTED_NODE_ID="$EXPECTED_NODE_ID" \
  REDEPLOY_REMOTE_MAC_PATH="$REMOTE_MAC_PATH" \
  REDEPLOY_FRONTEND_BASE_URL=https://prod.example.test \
  REDEPLOY_FRONTEND_CURRENT_SHA=2222222222222222222222222222222222222222 \
  REDEPLOY_FRONTEND_CURRENT_DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  REDEPLOY_FRONTEND_DISTRO_SHA="$DISTRO_SHA" \
  bash "$RUNNER" \
  "$SSH_KEY" deploy@example.test "$REMOTE_REPOSITORY" \
  "$BACKEND_SHA" "$BACKEND_DIGEST" committed-timeout-run >"$COMMITTED_TIMEOUT_OUTPUT" 2>&1
[ "$(cat "$REMOTE_REPOSITORY/.redeploy-runs/committed-timeout-run/status")" = 0 ]
grep -Fq 'public verification passed and transaction committed' "$COMMITTED_TIMEOUT_OUTPUT"
grep -Fq 'confirmed durable committed transaction' "$COMMITTED_TIMEOUT_OUTPUT"
grep -Fq 'treating the transaction as successful' "$COMMITTED_TIMEOUT_OUTPUT"

# A cancellation that reaches the deployment script after it committed makes the
# script exit on the signal, which must not downgrade a publicly verified
# release to a failed run.
COMMITTED_SIGNAL_OUTPUT="$TEMP_ROOT/committed-signal-output.log"
PATH="$FAKE_BIN:$PATH" \
  SSH_BIN="$FAKE_BIN/ssh" \
  FAKE_SSH_LAUNCH_WAIT_LOG="$REMOTE_REPOSITORY/.redeploy-runs/committed-signal-run/redeploy.log" \
  FAKE_SSH_LAUNCH_WAIT_PATTERN='public verification passed and transaction committed' \
  REDEPLOY_SCRIPT_PATH="$COMMITTED_SIGNAL_FIXTURE" \
  EXTERNAL_VERIFIER_PATH="$DUMMY_VERIFIER" \
  REDEPLOY_POLL_INTERVAL_SECONDS=1 \
  REDEPLOY_TIMEOUT_SECONDS=2 \
  REDEPLOY_CANCEL_RETRY_INTERVAL_SECONDS=1 \
  REDEPLOY_EXPECTED_REMOTE_MAC="$EXPECTED_REMOTE_MAC" \
  REDEPLOY_EXPECTED_NODE_ID="$EXPECTED_NODE_ID" \
  REDEPLOY_REMOTE_MAC_PATH="$REMOTE_MAC_PATH" \
  REDEPLOY_FRONTEND_BASE_URL=https://prod.example.test \
  REDEPLOY_FRONTEND_CURRENT_SHA=2222222222222222222222222222222222222222 \
  REDEPLOY_FRONTEND_CURRENT_DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  REDEPLOY_FRONTEND_DISTRO_SHA="$DISTRO_SHA" \
  bash "$RUNNER" \
  "$SSH_KEY" deploy@example.test "$REMOTE_REPOSITORY" \
  "$BACKEND_SHA" "$BACKEND_DIGEST" committed-signal-run >"$COMMITTED_SIGNAL_OUTPUT" 2>&1
[ "$(cat "$REMOTE_REPOSITORY/.redeploy-runs/committed-signal-run/status")" = 0 ]
[ "$(cat "$REMOTE_REPOSITORY/.redeploy-runs/committed-signal-run/frontend-transaction.state")" = committed ]
grep -Fq 'committed release received a late signal' \
  "$REMOTE_REPOSITORY/.redeploy-runs/committed-signal-run/redeploy.log"
grep -Fq 'confirmed durable committed transaction' "$COMMITTED_SIGNAL_OUTPUT"
grep -Fq 'treating the transaction as successful' "$COMMITTED_SIGNAL_OUTPUT"

COMMITTED_IDENTITY_MISMATCH_OUTPUT="$TEMP_ROOT/committed-identity-mismatch-output.log"
set +e
PATH="$FAKE_BIN:$PATH" \
  SSH_BIN="$FAKE_BIN/ssh" \
  FAKE_SSH_LOG_MISMATCHES=1 \
  FAKE_SSH_LOG_COUNTER_FILE="$TEMP_ROOT/committed-identity-log-mismatches" \
  FAKE_REMOTE_MAC_PATH="$REMOTE_MAC_PATH" \
  FAKE_EXPECTED_REMOTE_MAC="$EXPECTED_REMOTE_MAC" \
  FAKE_SSH_LAUNCH_WAIT_LOG="$REMOTE_REPOSITORY/.redeploy-runs/committed-identity-mismatch-run/redeploy.log" \
  FAKE_SSH_LAUNCH_WAIT_PATTERN='public verification passed and transaction committed' \
  REDEPLOY_SCRIPT_PATH="$COMMITTED_CLEANUP_FIXTURE" \
  EXTERNAL_VERIFIER_PATH="$DUMMY_VERIFIER" \
  REDEPLOY_POLL_INTERVAL_SECONDS=1 \
  REDEPLOY_TIMEOUT_SECONDS=2 \
  REDEPLOY_CANCEL_RETRY_INTERVAL_SECONDS=1 \
  REDEPLOY_EXPECTED_REMOTE_MAC="$EXPECTED_REMOTE_MAC" \
  REDEPLOY_EXPECTED_NODE_ID="$EXPECTED_NODE_ID" \
  REDEPLOY_REMOTE_MAC_PATH="$REMOTE_MAC_PATH" \
  REDEPLOY_FRONTEND_BASE_URL=https://prod.example.test \
  REDEPLOY_FRONTEND_CURRENT_SHA=2222222222222222222222222222222222222222 \
  REDEPLOY_FRONTEND_CURRENT_DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  REDEPLOY_FRONTEND_DISTRO_SHA="$DISTRO_SHA" \
  bash "$RUNNER" \
  "$SSH_KEY" deploy@example.test "$REMOTE_REPOSITORY" \
  "$BACKEND_SHA" "$BACKEND_DIGEST" committed-identity-mismatch-run \
  >"$COMMITTED_IDENTITY_MISMATCH_OUTPUT" 2>&1
committed_identity_mismatch_code="$?"
set -e
[ "$committed_identity_mismatch_code" -eq 86 ]
[ "$(cat "$REMOTE_REPOSITORY/.redeploy-runs/committed-identity-mismatch-run/status")" = 0 ]
grep -Fq 'remote identity mismatch observed while reading logs' "$COMMITTED_IDENTITY_MISMATCH_OUTPUT"
grep -Fq 'the release committed on the expected host, but another host also answered' \
  "$COMMITTED_IDENTITY_MISMATCH_OUTPUT"
if grep -Fq 'treating the transaction as successful' "$COMMITTED_IDENTITY_MISMATCH_OUTPUT"; then
  echo 'committed cancellation ignored an observed remote identity mismatch' >&2
  exit 1
fi

EARLY_CANCEL_OUTPUT="$TEMP_ROOT/early-cancel-output.log"
EARLY_CANCEL_MARKER="$TEMP_ROOT/early-cancel-flock-entered"
EARLY_CANCEL_RELEASE="$TEMP_ROOT/early-cancel-flock-release"
EARLY_CANCEL_EXECUTED="$TEMP_ROOT/early-cancel-executed"
PATH="$FAKE_BIN:$PATH" \
  SSH_BIN="$FAKE_BIN/ssh" \
  REDEPLOY_SCRIPT_PATH="$EARLY_CANCEL_FIXTURE" \
  EXTERNAL_VERIFIER_PATH="$DUMMY_VERIFIER" \
  FAKE_FLOCK_PRE_DEPLOY_MARKER="$EARLY_CANCEL_MARKER" \
  FAKE_FLOCK_PRE_DEPLOY_RELEASE="$EARLY_CANCEL_RELEASE" \
  FAKE_EARLY_CANCEL_EXECUTED="$EARLY_CANCEL_EXECUTED" \
  REDEPLOY_POLL_INTERVAL_SECONDS=1 \
  REDEPLOY_TIMEOUT_SECONDS=30 \
  REDEPLOY_EXPECTED_REMOTE_MAC="$EXPECTED_REMOTE_MAC" \
  REDEPLOY_EXPECTED_NODE_ID="$EXPECTED_NODE_ID" \
  REDEPLOY_REMOTE_MAC_PATH="$REMOTE_MAC_PATH" \
  REDEPLOY_FRONTEND_BASE_URL=https://prod.example.test \
  REDEPLOY_FRONTEND_CURRENT_SHA=2222222222222222222222222222222222222222 \
  REDEPLOY_FRONTEND_CURRENT_DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  REDEPLOY_FRONTEND_DISTRO_SHA="$DISTRO_SHA" \
  bash "$RUNNER" \
  "$SSH_KEY" deploy@example.test "$REMOTE_REPOSITORY" \
  "$BACKEND_SHA" "$BACKEND_DIGEST" early-cancel-run >"$EARLY_CANCEL_OUTPUT" 2>&1 &
early_cancel_monitor_pid="$!"

early_cancel_ready=false
for _ in $(seq 1 100); do
  if [ -e "$EARLY_CANCEL_MARKER" ]; then
    early_cancel_ready=true
    break
  fi
  sleep 0.1
done
if [ "$early_cancel_ready" != true ]; then
  echo 'early-cancellation worker did not reach its pre-deploy boundary' >&2
  exit 1
fi

kill -TERM "$early_cancel_monitor_pid"
set +e
wait "$early_cancel_monitor_pid"
early_cancel_code="$?"
set -e
[ "$early_cancel_code" -eq 143 ]
[ ! -e "$EARLY_CANCEL_EXECUTED" ]
[ "$(cat "$REMOTE_REPOSITORY/.redeploy-runs/early-cancel-run/status")" = 143 ]
[ "$(cat "$REMOTE_REPOSITORY/.redeploy-runs/early-cancel-run/frontend-transaction.state")" = unchanged ]
grep -Fq 'cancellation was requested before deployment started' \
  "$REMOTE_REPOSITORY/.redeploy-runs/early-cancel-run/redeploy.log"

STALE_STARTTIME_OUTPUT="$TEMP_ROOT/stale-starttime-output.log"
sleep 60 &
stale_pid_sentinel="$!"
mkdir -p "$REMOTE_REPOSITORY/.redeploy-runs/stale-starttime-run"
mkdir -p "$FAKE_PROC_ROOT/$stale_pid_sentinel"
printf '%s (unrelated-sentinel) S %s %s %s 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 12345\n' \
  "$stale_pid_sentinel" "$$" "$stale_pid_sentinel" "$stale_pid_sentinel" \
  >"$FAKE_PROC_ROOT/$stale_pid_sentinel/stat"
printf '%s %s\n' "$stale_pid_sentinel" 54321 \
  >"$REMOTE_REPOSITORY/.redeploy-runs/stale-starttime-run/pid"
set +e
PATH="$FAKE_BIN:$PATH" \
  SSH_BIN="$FAKE_BIN/ssh" \
  FAKE_SSH_FORCE_LAUNCH_ERROR=87 \
  REDEPLOY_SCRIPT_PATH="$SUCCESS_FIXTURE" \
  REDEPLOY_EXPECTED_REMOTE_MAC="$EXPECTED_REMOTE_MAC" \
  REDEPLOY_EXPECTED_NODE_ID="$EXPECTED_NODE_ID" \
  REDEPLOY_REMOTE_MAC_PATH="$REMOTE_MAC_PATH" \
  bash "$RUNNER" \
  "$SSH_KEY" deploy@example.test "$REMOTE_REPOSITORY" \
  "$BACKEND_SHA" "$BACKEND_DIGEST" stale-starttime-run >"$STALE_STARTTIME_OUTPUT" 2>&1
stale_starttime_code="$?"
set -e
[ "$stale_starttime_code" -eq 87 ]
kill -0 "$stale_pid_sentinel"
grep -Fq 'refusing to signal an unverified or stale remote worker PID' "$STALE_STARTTIME_OUTPUT"

STALE_SESSION_OUTPUT="$TEMP_ROOT/stale-session-output.log"
mkdir -p "$REMOTE_REPOSITORY/.redeploy-runs/stale-session-run"
printf '%s (unrelated-sentinel) S %s %s %s 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 12345\n' \
  "$stale_pid_sentinel" "$$" "$$" "$$" \
  >"$FAKE_PROC_ROOT/$stale_pid_sentinel/stat"
printf '%s %s\n' "$stale_pid_sentinel" 12345 \
  >"$REMOTE_REPOSITORY/.redeploy-runs/stale-session-run/pid"
set +e
PATH="$FAKE_BIN:$PATH" \
  SSH_BIN="$FAKE_BIN/ssh" \
  FAKE_SSH_FORCE_LAUNCH_ERROR=87 \
  REDEPLOY_SCRIPT_PATH="$SUCCESS_FIXTURE" \
  REDEPLOY_EXPECTED_REMOTE_MAC="$EXPECTED_REMOTE_MAC" \
  REDEPLOY_EXPECTED_NODE_ID="$EXPECTED_NODE_ID" \
  REDEPLOY_REMOTE_MAC_PATH="$REMOTE_MAC_PATH" \
  bash "$RUNNER" \
  "$SSH_KEY" deploy@example.test "$REMOTE_REPOSITORY" \
  "$BACKEND_SHA" "$BACKEND_DIGEST" stale-session-run >"$STALE_SESSION_OUTPUT" 2>&1
stale_session_code="$?"
set -e
[ "$stale_session_code" -eq 87 ]
kill -0 "$stale_pid_sentinel"
kill "$stale_pid_sentinel"
wait "$stale_pid_sentinel" 2>/dev/null || true
grep -Fq 'refusing to signal an unverified or stale remote worker PID' "$STALE_SESSION_OUTPUT"

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
grep -Fq 'cancel reached an initializing run, the wrong host, or lost transport; retrying 1/3' \
  "$CANCEL_RETRY_OUTPUT"
if grep -Fq 'remote cancellation was not confirmed' "$CANCEL_RETRY_OUTPUT"; then
  echo 'cancellation retry did not reach the expected host' >&2
  exit 1
fi

echo "[OK] resilient remote redeploy runner"
