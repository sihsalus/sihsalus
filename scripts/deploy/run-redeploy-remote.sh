#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REDEPLOY_SCRIPT_PATH="${REDEPLOY_SCRIPT_PATH:-$ROOT/redeploy-environment.sh}"
CLEAN_CHECKOUT_HELPER_PATH="${CLEAN_CHECKOUT_HELPER_PATH:-$ROOT/check-clean-checkout.sh}"
SSH_BIN="${SSH_BIN:-ssh}"
POLL_INTERVAL_SECONDS="${REDEPLOY_POLL_INTERVAL_SECONDS:-10}"
TIMEOUT_SECONDS="${REDEPLOY_TIMEOUT_SECONDS:-3300}"
MAX_TRANSPORT_FAILURES="${REDEPLOY_MAX_TRANSPORT_FAILURES:-20}"
INITIAL_TRANSPORT_ATTEMPTS="${REDEPLOY_INITIAL_TRANSPORT_ATTEMPTS:-12}"
EXPECTED_REMOTE_MAC="${REDEPLOY_EXPECTED_REMOTE_MAC:-}"
EXPECTED_NODE_ID="${REDEPLOY_EXPECTED_NODE_ID:-}"
REMOTE_MAC_PATH="${REDEPLOY_REMOTE_MAC_PATH:-/sys/class/net/ens160/address}"
CANCEL_ATTEMPTS="${REDEPLOY_CANCEL_ATTEMPTS:-6}"
CANCEL_RETRY_INTERVAL_SECONDS="${REDEPLOY_CANCEL_RETRY_INTERVAL_SECONDS:-2}"
REMOTE_IDENTITY_MISMATCH_EXIT=86

usage() {
  echo "Usage: $0 <ssh-key> <user@host> <remote-repository> <backend-sha> <backend-digest> <run-token>" >&2
}

if [ "$#" -ne 6 ]; then
  usage
  exit 2
fi

SSH_KEY="$1"
REMOTE_TARGET="$2"
REMOTE_REPOSITORY="$3"
TARGET_BACKEND_SHA="$4"
TARGET_BACKEND_DIGEST="$5"
RUN_TOKEN="$6"

if [ ! -r "$SSH_KEY" ]; then
  echo "[remote-redeploy] SSH key is not readable" >&2
  exit 2
fi
if [ ! -r "$REDEPLOY_SCRIPT_PATH" ]; then
  echo "[remote-redeploy] redeploy script is not readable" >&2
  exit 2
fi
if [ ! -r "$CLEAN_CHECKOUT_HELPER_PATH" ]; then
  echo "[remote-redeploy] clean-checkout helper is not readable" >&2
  exit 2
fi
if [[ ! "$REMOTE_TARGET" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._:-]+$ ]]; then
  echo "[remote-redeploy] invalid SSH target" >&2
  exit 2
fi
if [[ ! "$REMOTE_REPOSITORY" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  echo "[remote-redeploy] invalid remote repository path" >&2
  exit 2
fi
if [[ ! "$TARGET_BACKEND_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "[remote-redeploy] invalid backend SHA" >&2
  exit 2
fi
if [[ ! "$TARGET_BACKEND_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "[remote-redeploy] invalid backend digest" >&2
  exit 2
fi
if [[ ! "$RUN_TOKEN" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "[remote-redeploy] invalid run token" >&2
  exit 2
fi
if [[ ! "$EXPECTED_REMOTE_MAC" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
  echo "[remote-redeploy] REDEPLOY_EXPECTED_REMOTE_MAC is required and must be a lowercase MAC address" >&2
  exit 2
fi
if [[ ! "$EXPECTED_NODE_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  echo "[remote-redeploy] REDEPLOY_EXPECTED_NODE_ID is required and must be a lowercase UUID" >&2
  exit 2
fi
if [[ ! "$REMOTE_MAC_PATH" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  echo "[remote-redeploy] invalid remote MAC address path" >&2
  exit 2
fi

for numeric_value in \
  "$POLL_INTERVAL_SECONDS" \
  "$TIMEOUT_SECONDS" \
  "$MAX_TRANSPORT_FAILURES" \
  "$INITIAL_TRANSPORT_ATTEMPTS" \
  "$CANCEL_ATTEMPTS" \
  "$CANCEL_RETRY_INTERVAL_SECONDS"; do
  if [[ ! "$numeric_value" =~ ^[1-9][0-9]*$ ]]; then
    echo "[remote-redeploy] polling and timeout values must be positive integers" >&2
    exit 2
  fi
done

for command in "$SSH_BIN" cat mktemp rm sleep tr wc; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "[remote-redeploy] missing command: $command" >&2
    exit 2
  }
done

SSH_COMMAND=(
  "$SSH_BIN"
  -i "$SSH_KEY"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes
  -o ConnectTimeout=15
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=3
)

REMOTE_RUN_DIRECTORY="$REMOTE_REPOSITORY/.redeploy-runs/$RUN_TOKEN"
REMOTE_SCRIPT="$REMOTE_RUN_DIRECTORY/redeploy-environment.sh"
REMOTE_CLEAN_CHECKOUT_HELPER="$REMOTE_RUN_DIRECTORY/check-clean-checkout.sh"
REMOTE_LOG="$REMOTE_RUN_DIRECTORY/redeploy.log"
REMOTE_STATUS="$REMOTE_RUN_DIRECTORY/status"
REMOTE_PID="$REMOTE_RUN_DIRECTORY/pid"

cancel_remote_run_once() {
  "${SSH_COMMAND[@]}" "$REMOTE_TARGET" bash -s -- \
    "$EXPECTED_REMOTE_MAC" "$REMOTE_MAC_PATH" \
    "$REMOTE_STATUS" "$REMOTE_PID" <<'REMOTE_CANCEL'
set -euo pipefail
expected_mac="$1"
mac_path="$2"
status_path="$3"
pid_path="$4"

if [ -n "$expected_mac" ]; then
  if [ ! -r "$mac_path" ]; then
    echo "[remote-redeploy] cannot read remote MAC address at $mac_path" >&2
    exit 86
  fi
  IFS= read -r actual_mac <"$mac_path"
  if [ "$actual_mac" != "$expected_mac" ]; then
    echo "[remote-redeploy] remote MAC $actual_mac does not match expected $expected_mac" >&2
    exit 86
  fi
fi

if [ -f "$status_path" ] || [ ! -f "$pid_path" ]; then
  exit 0
fi

remote_pid="$(cat "$pid_path")"
if [[ "$remote_pid" =~ ^[1-9][0-9]*$ ]]; then
  kill -TERM -- "-${remote_pid}" 2>/dev/null || kill -TERM "$remote_pid" 2>/dev/null || true
fi
REMOTE_CANCEL
}

cancel_remote_run() {
  local attempt=1
  local cancel_code=0

  while true; do
    if cancel_remote_run_once; then
      return 0
    else
      cancel_code="$?"
    fi

    if { [ "$cancel_code" -ne "$REMOTE_IDENTITY_MISMATCH_EXIT" ] && [ "$cancel_code" -ne 255 ]; } ||
      [ "$attempt" -ge "$CANCEL_ATTEMPTS" ]; then
      echo "[remote-redeploy] could not cancel the expected remote run after ${attempt} attempt(s)" >&2
      return "$cancel_code"
    fi

    echo "[remote-redeploy] cancel reached the wrong host or lost transport; retrying ${attempt}/${CANCEL_ATTEMPTS}" >&2
    attempt=$((attempt + 1))
    sleep "$CANCEL_RETRY_INTERVAL_SECONDS"
  done
}

cleanup_initialization() {
  local exit_code="$?"
  trap - EXIT
  if [ "$exit_code" -ne 0 ]; then
    echo "[remote-redeploy] initialization failed; terminating a possible detached run" >&2
    cancel_remote_run || echo "[remote-redeploy] warning: remote cancellation was not confirmed" >&2
  fi
  exit "$exit_code"
}

trap cleanup_initialization EXIT

upload_remote_file() {
  local source_path="$1"
  local destination_path="$2"
  "${SSH_COMMAND[@]}" "$REMOTE_TARGET" \
    "expected_mac='$EXPECTED_REMOTE_MAC'; mac_path='$REMOTE_MAC_PATH'; if [ -n \"\$expected_mac\" ]; then if [ ! -r \"\$mac_path\" ]; then echo '[remote-redeploy] cannot read remote MAC address' >&2; exit $REMOTE_IDENTITY_MISMATCH_EXIT; fi; IFS= read -r actual_mac <\"\$mac_path\"; if [ \"\$actual_mac\" != \"\$expected_mac\" ]; then echo \"[remote-redeploy] remote MAC \$actual_mac does not match expected \$expected_mac\" >&2; exit $REMOTE_IDENTITY_MISMATCH_EXIT; fi; fi; umask 077; install -d -m 700 '$REMOTE_RUN_DIRECTORY'; cat >'$destination_path'; chmod 700 '$destination_path'" \
    <"$source_path"
}

upload_remote_scripts() {
  upload_remote_file "$CLEAN_CHECKOUT_HELPER_PATH" "$REMOTE_CLEAN_CHECKOUT_HELPER" || return "$?"
  upload_remote_file "$REDEPLOY_SCRIPT_PATH" "$REMOTE_SCRIPT"
}

start_remote_run() {
  "${SSH_COMMAND[@]}" "$REMOTE_TARGET" bash -s -- \
    "$EXPECTED_REMOTE_MAC" \
    "$REMOTE_MAC_PATH" \
    "$EXPECTED_NODE_ID" \
    "$REMOTE_REPOSITORY" \
    "$RUN_TOKEN" \
    "$TARGET_BACKEND_SHA" \
    "$TARGET_BACKEND_DIGEST" <<'REMOTE_LAUNCHER'
set -Eeuo pipefail

expected_mac="$1"
mac_path="$2"
node_id="$3"
repository="$4"
run_token="$5"
backend_sha="$6"
backend_digest="$7"
run_directory="$repository/.redeploy-runs/$run_token"
script_path="$run_directory/redeploy-environment.sh"
log_path="$run_directory/redeploy.log"
status_path="$run_directory/status"
pid_path="$run_directory/pid"

if [ -n "$expected_mac" ]; then
  if [ ! -r "$mac_path" ]; then
    echo "[remote-redeploy] cannot read remote MAC address at $mac_path" >&2
    exit 86
  fi
  IFS= read -r actual_mac <"$mac_path"
  if [ "$actual_mac" != "$expected_mac" ]; then
    echo "[remote-redeploy] remote MAC $actual_mac does not match expected $expected_mac" >&2
    exit 86
  fi
fi

for command in bash flock nohup setsid; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "[remote-redeploy] missing remote command: $command" >&2
    exit 2
  }
done

if [ ! -x "$script_path" ]; then
  echo "[remote-redeploy] uploaded script is not executable" >&2
  exit 2
fi
if [ -e "$status_path" ]; then
  echo "[remote-redeploy] run token already completed; resuming its monitor"
  exit 0
fi
if [ -f "$pid_path" ]; then
  previous_pid="$(cat "$pid_path")"
  if [[ "$previous_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$previous_pid" 2>/dev/null; then
    echo "[remote-redeploy] run token is already active; resuming its monitor"
    exit 0
  fi
fi

: >"$log_path"
rm -f "$run_directory/status.tmp"

nohup setsid bash -c '
  set +e
  repository="$1"
  run_directory="$2"
  backend_sha="$3"
  backend_digest="$4"
  node_id="$5"
  log_path="$run_directory/redeploy.log"
  status_path="$run_directory/status"
  status_tmp="$run_directory/status.tmp"

  exec >"$log_path" 2>&1

  write_status() {
    exit_code="$?"
    trap - EXIT
    printf "%s\n" "$exit_code" >"$status_tmp"
    mv -f "$status_tmp" "$status_path"
  }

  trap write_status EXIT
  trap "exit 130" INT
  trap "exit 143" TERM HUP

  cd "$repository" || exit 1
  exec 9>"$repository/.redeploy-runs/redeploy.lock"
  if ! flock -n 9; then
    echo "[remote-redeploy] another environment redeploy is active" >&2
    exit 75
  fi

  export SIHSALUS_NODE_ID="$node_id"
  bash "$run_directory/redeploy-environment.sh" "$backend_sha" "$backend_digest"
  exit "$?"
' remote-redeploy-worker \
  "$repository" \
  "$run_directory" \
  "$backend_sha" \
  "$backend_digest" \
  "$node_id" \
  </dev/null >/dev/null 2>&1 &

printf '%s\n' "$!" >"$pid_path"
REMOTE_LAUNCHER
}

retry_initial_transport() {
  local operation="$1"
  local attempt=1
  local exit_code
  shift

  while true; do
    if "$@"; then
      return 0
    else
      exit_code="$?"
    fi

    if [ "$exit_code" -ne 255 ] || [ "$attempt" -ge "$INITIAL_TRANSPORT_ATTEMPTS" ]; then
      return "$exit_code"
    fi

    echo "[remote-redeploy] ${operation} transport failure ${attempt}/${INITIAL_TRANSPORT_ATTEMPTS}; retrying" >&2
    attempt=$((attempt + 1))
    sleep "$POLL_INTERVAL_SECONDS"
  done
}

echo "[remote-redeploy] uploading the validated deployment scripts"
retry_initial_transport upload upload_remote_scripts

echo "[remote-redeploy] starting detached run $RUN_TOKEN"
retry_initial_transport launch start_remote_run

REMOTE_FINISHED=false
NEXT_LOG_LINE=1
TRANSPORT_FAILURES=0
IDENTITY_MISMATCH_OBSERVED=false
START_SECONDS="$SECONDS"
CURRENT_TEMP_FILE=""

fetch_remote_log() {
  local line_count
  local fetch_code
  CURRENT_TEMP_FILE="$(mktemp "${TMPDIR:-/tmp}/sihsalus-redeploy-log.XXXXXX")"
  if "${SSH_COMMAND[@]}" "$REMOTE_TARGET" bash -s -- \
    "$EXPECTED_REMOTE_MAC" "$REMOTE_MAC_PATH" \
    "$REMOTE_LOG" "$NEXT_LOG_LINE" >"$CURRENT_TEMP_FILE" <<'REMOTE_LOG_FETCH'
set -euo pipefail
expected_mac="$1"
mac_path="$2"
log_path="$3"
next_log_line="$4"

if [ -n "$expected_mac" ]; then
  if [ ! -r "$mac_path" ]; then
    echo "[remote-redeploy] cannot read remote MAC address at $mac_path" >&2
    exit 86
  fi
  IFS= read -r actual_mac <"$mac_path"
  if [ "$actual_mac" != "$expected_mac" ]; then
    echo "[remote-redeploy] remote MAC $actual_mac does not match expected $expected_mac" >&2
    exit 86
  fi
fi

tail -n "+${next_log_line}" -- "$log_path"
REMOTE_LOG_FETCH
  then
    :
  else
    fetch_code="$?"
    rm -f "$CURRENT_TEMP_FILE"
    CURRENT_TEMP_FILE=""
    return "$fetch_code"
  fi

  cat "$CURRENT_TEMP_FILE"
  line_count="$(wc -l <"$CURRENT_TEMP_FILE" | tr -d ' ')"
  NEXT_LOG_LINE=$((NEXT_LOG_LINE + line_count))
  rm -f "$CURRENT_TEMP_FILE"
  CURRENT_TEMP_FILE=""
}

finish_local() {
  local exit_code="$?"
  trap - EXIT
  if [ -n "$CURRENT_TEMP_FILE" ]; then
    rm -f "$CURRENT_TEMP_FILE"
  fi
  if [ "$REMOTE_FINISHED" != true ]; then
    echo "[remote-redeploy] local monitor stopped; terminating the detached remote run" >&2
    cancel_remote_run || echo "[remote-redeploy] warning: remote cancellation was not confirmed" >&2
  fi
  exit "$exit_code"
}

trap finish_local EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

while true; do
  if [ $((SECONDS - START_SECONDS)) -ge "$TIMEOUT_SECONDS" ]; then
    echo "[remote-redeploy] remote run exceeded ${TIMEOUT_SECONDS}s" >&2
    exit 124
  fi

  if fetch_remote_log; then
    remote_status=""
    if remote_status="$(
      "${SSH_COMMAND[@]}" "$REMOTE_TARGET" bash -s -- \
        "$EXPECTED_REMOTE_MAC" "$REMOTE_MAC_PATH" \
        "$REMOTE_STATUS" <<'REMOTE_STATUS_CHECK'
set -euo pipefail
expected_mac="$1"
mac_path="$2"
status_path="$3"

if [ -n "$expected_mac" ]; then
  if [ ! -r "$mac_path" ]; then
    echo "[remote-redeploy] cannot read remote MAC address at $mac_path" >&2
    exit 86
  fi
  IFS= read -r actual_mac <"$mac_path"
  if [ "$actual_mac" != "$expected_mac" ]; then
    echo "[remote-redeploy] remote MAC $actual_mac does not match expected $expected_mac" >&2
    exit 86
  fi
fi

if [ -f "$status_path" ]; then
  cat "$status_path"
fi
REMOTE_STATUS_CHECK
    )"; then
      TRANSPORT_FAILURES=0
      if [ -n "$remote_status" ]; then
        if [[ ! "$remote_status" =~ ^[0-9]+$ ]] || [ "$remote_status" -gt 255 ]; then
          echo "[remote-redeploy] invalid remote status: $remote_status" >&2
          exit 1
        fi

        if fetch_remote_log; then
          :
        else
          final_log_code="$?"
          if [ "$final_log_code" -eq "$REMOTE_IDENTITY_MISMATCH_EXIT" ]; then
            IDENTITY_MISMATCH_OBSERVED=true
          fi
        fi
        REMOTE_FINISHED=true
        if [ "$remote_status" -ne 0 ]; then
          echo "[remote-redeploy] detached run failed with exit code $remote_status" >&2
          exit "$remote_status"
        fi
        if [ "$IDENTITY_MISMATCH_OBSERVED" = true ]; then
          echo "[remote-redeploy] deployment completed on the expected host, but another host answered for the same target" >&2
          exit "$REMOTE_IDENTITY_MISMATCH_EXIT"
        fi
        echo "[remote-redeploy] detached run completed successfully"
        exit 0
      fi
    else
      status_code="$?"
      TRANSPORT_FAILURES=$((TRANSPORT_FAILURES + 1))
      if [ "$status_code" -eq "$REMOTE_IDENTITY_MISMATCH_EXIT" ]; then
        IDENTITY_MISMATCH_OBSERVED=true
        echo "[remote-redeploy] remote identity mismatch observed while reading status" >&2
      else
        echo "[remote-redeploy] status transport failure ${TRANSPORT_FAILURES}/${MAX_TRANSPORT_FAILURES}" >&2
      fi
    fi
  else
    log_code="$?"
    TRANSPORT_FAILURES=$((TRANSPORT_FAILURES + 1))
    if [ "$log_code" -eq "$REMOTE_IDENTITY_MISMATCH_EXIT" ]; then
      IDENTITY_MISMATCH_OBSERVED=true
      echo "[remote-redeploy] remote identity mismatch observed while reading logs" >&2
    else
      echo "[remote-redeploy] log transport failure ${TRANSPORT_FAILURES}/${MAX_TRANSPORT_FAILURES}" >&2
    fi
  fi

  if [ "$TRANSPORT_FAILURES" -ge "$MAX_TRANSPORT_FAILURES" ]; then
    echo "[remote-redeploy] SSH transport remained unavailable" >&2
    exit 255
  fi

  sleep "$POLL_INTERVAL_SECONDS"
done
