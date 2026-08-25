#!/usr/bin/env bash

set -euo pipefail

readonly SP_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly SP_TEST_SCRIPT="$SP_TEST_ROOT/scripts/utils/sihsalus-safe-poweroff.sh"
readonly SP_TEST_OUTPUT="$(mktemp)"
readonly SP_TEST_INHIBIT="$(mktemp)"
rm -f "$SP_TEST_INHIBIT"
trap 'rm -f "$SP_TEST_OUTPUT" "$SP_TEST_INHIBIT"' EXIT

# shellcheck source=scripts/utils/sihsalus-safe-poweroff.sh
source "$SP_TEST_SCRIPT"

SP_TEST_NOW_EPOCH=10000
SP_TEST_LOCAL_HHMM='22:30'
SP_TEST_UPTIME=7200
SP_TEST_ACTIVITY_EPOCH=8000
SP_TEST_ACTIVITY_EPOCH_AFTER_SLEEP=''
SP_TEST_CONNECTIONS=0
SP_TEST_POWEROFF_COUNT=0

sp_current_epoch() {
  printf '%s\n' "$SP_TEST_NOW_EPOCH"
}

sp_current_local_hhmm() {
  printf '%s\n' "$SP_TEST_LOCAL_HHMM"
}

sp_host_uptime_seconds() {
  printf '%s\n' "$SP_TEST_UPTIME"
}

sp_gateway_activity_epoch() {
  [[ "$SP_TEST_ACTIVITY_EPOCH" != 'unavailable' ]] || return 1
  printf '%s\n' "$SP_TEST_ACTIVITY_EPOCH"
}

sp_established_sensitive_connections() {
  [[ "$SP_TEST_CONNECTIONS" != 'unavailable' ]] || return 1
  printf '%s\n' "$SP_TEST_CONNECTIONS"
}

sp_sleep() {
  if [[ -n "$SP_TEST_ACTIVITY_EPOCH_AFTER_SLEEP" ]]; then
    SP_TEST_ACTIVITY_EPOCH="$SP_TEST_ACTIVITY_EPOCH_AFTER_SLEEP"
  fi
}

sp_warn_terminals() {
  :
}

sp_request_poweroff() {
  SP_TEST_POWEROFF_COUNT=$((SP_TEST_POWEROFF_COUNT + 1))
}

sp_reset_policy() {
  SIHSALUS_SAFE_POWEROFF_ENABLED=true
  SIHSALUS_SAFE_POWEROFF_DRY_RUN=false
  SIHSALUS_SAFE_POWEROFF_NOT_BEFORE='22:00'
  SIHSALUS_SAFE_POWEROFF_NOT_AFTER='23:00'
  SIHSALUS_SAFE_POWEROFF_IDLE_SECONDS=900
  SIHSALUS_SAFE_POWEROFF_BOOT_GRACE_SECONDS=1800
  SIHSALUS_SAFE_POWEROFF_FINAL_GRACE_SECONDS=0
  SIHSALUS_SAFE_POWEROFF_COMPOSE_DIR="$SP_TEST_ROOT"
  SIHSALUS_SAFE_POWEROFF_GATEWAY_SERVICE=gateway
  SIHSALUS_SAFE_POWEROFF_INHIBIT_FILE="$SP_TEST_INHIBIT"
  SP_TEST_NOW_EPOCH=10000
  SP_TEST_LOCAL_HHMM='22:30'
  SP_TEST_UPTIME=7200
  SP_TEST_ACTIVITY_EPOCH=8000
  SP_TEST_ACTIVITY_EPOCH_AFTER_SLEEP=''
  SP_TEST_CONNECTIONS=0
  SP_TEST_POWEROFF_COUNT=0
  rm -f "$SP_TEST_INHIBIT"
  : > "$SP_TEST_OUTPUT"
}

sp_assert_output() {
  local sp_expected="$1"
  if ! grep -Fq "$sp_expected" "$SP_TEST_OUTPUT"; then
    printf 'Expected output not found: %s\n' "$sp_expected" >&2
    cat "$SP_TEST_OUTPUT" >&2
    exit 1
  fi
}

sp_reset_policy
SIHSALUS_SAFE_POWEROFF_ENABLED=false
sp_main > "$SP_TEST_OUTPUT"
sp_assert_output 'decision=skip reason=disabled'
[[ "$SP_TEST_POWEROFF_COUNT" -eq 0 ]]

sp_reset_policy
SIHSALUS_SAFE_POWEROFF_COMPOSE_DIR='relative/path'
if sp_main > "$SP_TEST_OUTPUT"; then
  printf 'Relative Compose directory unexpectedly passed\n' >&2
  exit 1
fi
sp_assert_output 'reason=compose_dir_not_absolute'
[[ "$SP_TEST_POWEROFF_COUNT" -eq 0 ]]

sp_reset_policy
SIHSALUS_SAFE_POWEROFF_COMPOSE_DIR="$SP_TEST_ROOT/missing-compose-directory"
if sp_main > "$SP_TEST_OUTPUT"; then
  printf 'Missing Compose directory unexpectedly passed\n' >&2
  exit 1
fi
sp_assert_output 'reason=compose_dir_unavailable'
[[ "$SP_TEST_POWEROFF_COUNT" -eq 0 ]]

sp_reset_policy
SIHSALUS_SAFE_POWEROFF_NOT_BEFORE=''
if sp_main > "$SP_TEST_OUTPUT"; then
  printf 'Missing schedule unexpectedly passed\n' >&2
  exit 1
fi
sp_assert_output 'reason=invalid_or_missing_poweroff_window'
[[ "$SP_TEST_POWEROFF_COUNT" -eq 0 ]]

sp_reset_policy
SP_TEST_LOCAL_HHMM='21:30'
sp_main > "$SP_TEST_OUTPUT"
sp_assert_output 'decision=skip reason=outside_window local_time=21:30'
[[ "$SP_TEST_POWEROFF_COUNT" -eq 0 ]]

sp_reset_policy
SP_TEST_UPTIME=300
sp_main > "$SP_TEST_OUTPUT"
sp_assert_output 'decision=defer reason=boot_grace uptime_seconds=300'
[[ "$SP_TEST_POWEROFF_COUNT" -eq 0 ]]

sp_reset_policy
SP_TEST_ACTIVITY_EPOCH=9500
sp_main > "$SP_TEST_OUTPUT"
sp_assert_output 'decision=defer reason=recent_clinical_activity age_seconds=500'
[[ "$SP_TEST_POWEROFF_COUNT" -eq 0 ]]

sp_reset_policy
SP_TEST_CONNECTIONS=1
sp_main > "$SP_TEST_OUTPUT"
sp_assert_output 'decision=defer reason=active_connection count=1'
[[ "$SP_TEST_POWEROFF_COUNT" -eq 0 ]]

sp_reset_policy
SP_TEST_CONNECTIONS='unavailable'
sp_main > "$SP_TEST_OUTPUT"
sp_assert_output 'decision=defer reason=connection_signal_unavailable'
[[ "$SP_TEST_POWEROFF_COUNT" -eq 0 ]]

sp_reset_policy
SP_TEST_ACTIVITY_EPOCH='unavailable'
sp_main > "$SP_TEST_OUTPUT"
sp_assert_output 'decision=defer reason=activity_signal_unavailable'
[[ "$SP_TEST_POWEROFF_COUNT" -eq 0 ]]

sp_reset_policy
touch "$SP_TEST_INHIBIT"
sp_main > "$SP_TEST_OUTPUT"
sp_assert_output 'decision=defer reason=operator_inhibit'
[[ "$SP_TEST_POWEROFF_COUNT" -eq 0 ]]

sp_reset_policy
SIHSALUS_SAFE_POWEROFF_DRY_RUN=true
sp_main > "$SP_TEST_OUTPUT"
sp_assert_output 'decision=would_power_off dry_run=true idle_seconds=2000'
[[ "$SP_TEST_POWEROFF_COUNT" -eq 0 ]]

sp_reset_policy
sp_main > "$SP_TEST_OUTPUT"
sp_assert_output 'decision=power_off idle_seconds=2000'
[[ "$SP_TEST_POWEROFF_COUNT" -eq 1 ]]

sp_reset_policy
SIHSALUS_SAFE_POWEROFF_FINAL_GRACE_SECONDS=60
SP_TEST_ACTIVITY_EPOCH_AFTER_SLEEP=9990
sp_main > "$SP_TEST_OUTPUT"
sp_assert_output 'decision=final_grace seconds=60'
sp_assert_output 'decision=defer reason=recent_clinical_activity age_seconds=10'
[[ "$SP_TEST_POWEROFF_COUNT" -eq 0 ]]

sp_reset_policy
SP_TEST_LOCAL_HHMM='00:30'
SIHSALUS_SAFE_POWEROFF_NOT_BEFORE='22:00'
SIHSALUS_SAFE_POWEROFF_NOT_AFTER='01:00'
sp_main > "$SP_TEST_OUTPUT"
sp_assert_output 'decision=power_off idle_seconds=2000'
[[ "$SP_TEST_POWEROFF_COUNT" -eq 1 ]]

grep -Fq "log_format  clinical_activity '\$msec';" "$SP_TEST_ROOT/gateway/nginx.conf"
[[ "$(grep -l 'clinical-activity.log clinical_activity' "$SP_TEST_ROOT"/gateway/default*.conf.template | wc -l | tr -d ' ')" == '2' ]]
if grep -n 'clinical-activity' "$SP_TEST_ROOT"/gateway/default*.conf.template | grep -Eq 'proxy_pass|request_uri|cookie'; then
  printf 'Clinical activity endpoint must not proxy or log request context\n' >&2
  exit 1
fi
grep -Fq 'SIHSALUS_SAFE_POWEROFF_ENABLED=false' \
  "$SP_TEST_ROOT/scripts/utils/sihsalus-safe-poweroff.env.example"
grep -Fq 'SIHSALUS_SAFE_POWEROFF_DRY_RUN=true' \
  "$SP_TEST_ROOT/scripts/utils/sihsalus-safe-poweroff.env.example"
grep -Fq 'SIHSALUS_SAFE_POWEROFF_COMPOSE_DIR=/opt/sihsalus' \
  "$SP_TEST_ROOT/scripts/utils/sihsalus-safe-poweroff.env.example"
if grep -Fq '/opt/sihsalus' \
  "$SP_TEST_ROOT/scripts/utils/sihsalus-safe-poweroff.service" \
  "$SP_TEST_ROOT/scripts/utils/sihsalus-safe-poweroff.timer"; then
  printf 'Systemd units must not hardcode the distro checkout path\n' >&2
  exit 1
fi
grep -Fq 'WorkingDirectory=/' \
  "$SP_TEST_ROOT/scripts/utils/sihsalus-safe-poweroff.service"

printf 'safe poweroff policy tests passed\n'
