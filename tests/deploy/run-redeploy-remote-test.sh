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
  exec bash -c "$1"
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
  REDEPLOY_SCRIPT_PATH="$SUCCESS_FIXTURE" \
  REDEPLOY_POLL_INTERVAL_SECONDS=1 \
  REDEPLOY_TIMEOUT_SECONDS=15 \
  bash "$RUNNER" \
  "$SSH_KEY" deploy@example.test "$REMOTE_REPOSITORY" \
  "$BACKEND_SHA" "$BACKEND_DIGEST" success-run >"$SUCCESS_OUTPUT"

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
