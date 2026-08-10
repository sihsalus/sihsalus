#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$ROOT/scripts/deploy/run-redeploy-remote.sh"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sihsalus-remote-redeploy-test.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

FAKE_BIN="$TEMP_ROOT/bin"
REMOTE_REPOSITORY="$TEMP_ROOT/remote/sihsalus"
SSH_KEY="$TEMP_ROOT/deploy-key"
mkdir -p "$FAKE_BIN" "$REMOTE_REPOSITORY"
: >"$SSH_KEY"

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

if [ "$#" -eq 7 ] && [ "$1" = bash ] && [ "$2" = -s ] &&
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

FAILURE_OUTPUT="$TEMP_ROOT/failure-output.log"
set +e
PATH="$FAKE_BIN:$PATH" \
  SSH_BIN="$FAKE_BIN/ssh" \
  REDEPLOY_SCRIPT_PATH="$FAILURE_FIXTURE" \
  REDEPLOY_POLL_INTERVAL_SECONDS=1 \
  REDEPLOY_TIMEOUT_SECONDS=15 \
  bash "$RUNNER" \
  "$SSH_KEY" deploy@example.test "$REMOTE_REPOSITORY" \
  "$BACKEND_SHA" "$BACKEND_DIGEST" failure-run >"$FAILURE_OUTPUT" 2>&1
failure_code="$?"
set -e

[ "$failure_code" -eq 42 ]
grep -Fq 'fixture failed as requested' "$FAILURE_OUTPUT"
grep -Fq 'detached run failed with exit code 42' "$FAILURE_OUTPUT"
[ "$(cat "$REMOTE_REPOSITORY/.redeploy-runs/failure-run/status")" = 42 ]

echo "[OK] resilient remote redeploy runner"
