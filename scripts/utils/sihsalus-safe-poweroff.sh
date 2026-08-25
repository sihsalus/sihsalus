#!/usr/bin/env bash

set -euo pipefail

readonly SP_ACTIVITY_LOG_PATH='/var/log/nginx/clinical-activity.log'
SP_ACTIVITY_AGE_SECONDS=0

sp_log() {
  local sp_level="$1"
  shift
  printf 'SIHSALUS_SAFE_POWEROFF level=%s %s\n' "$sp_level" "$*"
}

sp_parse_hhmm() {
  local sp_value="$1"
  if [[ ! "$sp_value" =~ ^([0-9]{2}):([0-9]{2})$ ]]; then
    return 1
  fi

  local sp_hour="${BASH_REMATCH[1]}"
  local sp_minute="${BASH_REMATCH[2]}"
  if ((10#$sp_hour > 23 || 10#$sp_minute > 59)); then
    return 1
  fi

  printf '%s\n' "$((10#$sp_hour * 60 + 10#$sp_minute))"
}

sp_is_inside_window() {
  local sp_now_minutes="$1"
  local sp_start_minutes="$2"
  local sp_end_minutes="$3"

  if ((sp_start_minutes <= sp_end_minutes)); then
    ((sp_now_minutes >= sp_start_minutes && sp_now_minutes <= sp_end_minutes))
    return
  fi

  # A window such as 22:00-01:00 crosses midnight.
  ((sp_now_minutes >= sp_start_minutes || sp_now_minutes <= sp_end_minutes))
}

sp_current_epoch() {
  date '+%s'
}

sp_current_local_hhmm() {
  date '+%H:%M'
}

sp_host_uptime_seconds() {
  local sp_uptime_raw
  read -r sp_uptime_raw _ < /proc/uptime
  printf '%s\n' "${sp_uptime_raw%%.*}"
}

sp_gateway_container_id() {
  local sp_gateway_service="$1"
  local sp_container_id

  command -v docker >/dev/null 2>&1 || return 1
  sp_container_id="$(docker compose ps -q "$sp_gateway_service" 2>/dev/null | head -n 1)"
  [[ -n "$sp_container_id" ]] || return 1
  printf '%s\n' "$sp_container_id"
}

sp_gateway_activity_epoch() {
  local sp_gateway_service="$1"
  local sp_container_id

  sp_container_id="$(sp_gateway_container_id "$sp_gateway_service")" || return 1
  docker exec "$sp_container_id" stat -c '%Y' "$SP_ACTIVITY_LOG_PATH" 2>/dev/null
}

sp_established_sensitive_connections() {
  local sp_gateway_service="$1"
  local sp_container_id
  local sp_host_ssh_connections
  local sp_gateway_web_connections

  command -v ss >/dev/null 2>&1 || return 1
  sp_host_ssh_connections="$(
    ss -Htn state established 2>/dev/null \
      | awk '$4 ~ /:22$/ { count += 1 } END { print count + 0 }'
  )" || return 1

  sp_container_id="$(sp_gateway_container_id "$sp_gateway_service")" || return 1
  sp_gateway_web_connections="$(
    docker exec "$sp_container_id" sh -c \
      "awk '\$4 == \"01\" && \$2 ~ /:(0050|01BB)\$/ { count += 1 } END { print count + 0 }' /proc/net/tcp /proc/net/tcp6" \
      2>/dev/null
  )" || return 1

  [[ "$sp_host_ssh_connections" =~ ^[0-9]+$ && "$sp_gateway_web_connections" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$((sp_host_ssh_connections + sp_gateway_web_connections))"
}

sp_sleep() {
  sleep "$1"
}

sp_warn_terminals() {
  local sp_seconds="$1"
  if command -v wall >/dev/null 2>&1; then
    printf 'SIH Salus evaluará un apagado seguro en %s segundos. Mantenga actividad en la aplicación o cree el inhibidor operativo si debe continuar trabajando.\n' "$sp_seconds" \
      | wall 2>/dev/null || true
  fi
}

sp_request_poweroff() {
  /usr/bin/systemctl poweroff --no-block
}

sp_require_boolean() {
  local sp_name="$1"
  local sp_value="$2"
  if [[ "$sp_value" != 'true' && "$sp_value" != 'false' ]]; then
    sp_log ERROR "reason=invalid_boolean setting=$sp_name"
    return 1
  fi
}

sp_require_nonnegative_integer() {
  local sp_name="$1"
  local sp_value="$2"
  if [[ ! "$sp_value" =~ ^[0-9]+$ ]]; then
    sp_log ERROR "reason=invalid_integer setting=$sp_name"
    return 1
  fi
}

sp_load_activity_age() {
  local sp_now_epoch="$1"
  local sp_gateway_service="$2"
  local sp_activity_epoch

  if ! sp_activity_epoch="$(sp_gateway_activity_epoch "$sp_gateway_service")"; then
    sp_log WARN 'decision=defer reason=activity_signal_unavailable'
    return 1
  fi
  if [[ ! "$sp_activity_epoch" =~ ^[0-9]+$ ]]; then
    sp_log WARN 'decision=defer reason=activity_signal_invalid'
    return 1
  fi

  SP_ACTIVITY_AGE_SECONDS="$((sp_now_epoch - sp_activity_epoch))"
  if ((SP_ACTIVITY_AGE_SECONDS < 0)); then
    sp_log WARN 'decision=defer reason=clock_moved_backwards'
    return 1
  fi
}

sp_policy_still_idle() {
  local sp_now_epoch="$1"
  local sp_idle_seconds="$2"
  local sp_gateway_service="$3"
  local sp_inhibit_file="$4"
  local sp_connection_count

  if [[ -e "$sp_inhibit_file" ]]; then
    sp_log INFO 'decision=defer reason=operator_inhibit'
    return 1
  fi

  if ! sp_connection_count="$(sp_established_sensitive_connections "$sp_gateway_service")"; then
    sp_log WARN 'decision=defer reason=connection_signal_unavailable'
    return 1
  fi
  if [[ ! "$sp_connection_count" =~ ^[0-9]+$ ]]; then
    sp_log WARN 'decision=defer reason=connection_signal_invalid'
    return 1
  fi
  if ((sp_connection_count > 0)); then
    sp_log INFO "decision=defer reason=active_connection count=$sp_connection_count"
    return 1
  fi

  if ! sp_load_activity_age "$sp_now_epoch" "$sp_gateway_service"; then
    return 1
  fi
  if ((SP_ACTIVITY_AGE_SECONDS < sp_idle_seconds)); then
    sp_log INFO "decision=defer reason=recent_clinical_activity age_seconds=$SP_ACTIVITY_AGE_SECONDS"
    return 1
  fi

  return 0
}

sp_main() {
  local sp_enabled="${SIHSALUS_SAFE_POWEROFF_ENABLED:-false}"
  local sp_dry_run="${SIHSALUS_SAFE_POWEROFF_DRY_RUN:-true}"
  local sp_not_before="${SIHSALUS_SAFE_POWEROFF_NOT_BEFORE:-}"
  local sp_not_after="${SIHSALUS_SAFE_POWEROFF_NOT_AFTER:-}"
  local sp_idle_seconds="${SIHSALUS_SAFE_POWEROFF_IDLE_SECONDS:-900}"
  local sp_boot_grace_seconds="${SIHSALUS_SAFE_POWEROFF_BOOT_GRACE_SECONDS:-1800}"
  local sp_final_grace_seconds="${SIHSALUS_SAFE_POWEROFF_FINAL_GRACE_SECONDS:-60}"
  local sp_gateway_service="${SIHSALUS_SAFE_POWEROFF_GATEWAY_SERVICE:-gateway}"
  local sp_inhibit_file="${SIHSALUS_SAFE_POWEROFF_INHIBIT_FILE:-/run/sihsalus/poweroff.inhibit}"

  sp_require_boolean SIHSALUS_SAFE_POWEROFF_ENABLED "$sp_enabled"
  sp_require_boolean SIHSALUS_SAFE_POWEROFF_DRY_RUN "$sp_dry_run"
  sp_require_nonnegative_integer SIHSALUS_SAFE_POWEROFF_IDLE_SECONDS "$sp_idle_seconds"
  sp_require_nonnegative_integer SIHSALUS_SAFE_POWEROFF_BOOT_GRACE_SECONDS "$sp_boot_grace_seconds"
  sp_require_nonnegative_integer SIHSALUS_SAFE_POWEROFF_FINAL_GRACE_SECONDS "$sp_final_grace_seconds"

  if [[ "$sp_enabled" != 'true' ]]; then
    sp_log INFO 'decision=skip reason=disabled'
    return 0
  fi

  if ((sp_idle_seconds < 60)); then
    sp_log ERROR 'reason=idle_window_too_short minimum_seconds=60'
    return 1
  fi
  if [[ "$sp_inhibit_file" != /* ]]; then
    sp_log ERROR 'reason=inhibit_path_not_absolute'
    return 1
  fi

  local sp_start_minutes
  local sp_end_minutes
  local sp_now_hhmm
  local sp_now_minutes
  if ! sp_start_minutes="$(sp_parse_hhmm "$sp_not_before")" \
    || ! sp_end_minutes="$(sp_parse_hhmm "$sp_not_after")"; then
    sp_log ERROR 'reason=invalid_or_missing_poweroff_window'
    return 1
  fi
  sp_now_hhmm="$(sp_current_local_hhmm)"
  if ! sp_now_minutes="$(sp_parse_hhmm "$sp_now_hhmm")"; then
    sp_log ERROR 'reason=invalid_system_clock'
    return 1
  fi
  if ! sp_is_inside_window "$sp_now_minutes" "$sp_start_minutes" "$sp_end_minutes"; then
    sp_log INFO "decision=skip reason=outside_window local_time=$sp_now_hhmm"
    return 0
  fi

  local sp_uptime_seconds
  if ! sp_uptime_seconds="$(sp_host_uptime_seconds)" || [[ ! "$sp_uptime_seconds" =~ ^[0-9]+$ ]]; then
    sp_log WARN 'decision=defer reason=uptime_signal_unavailable'
    return 0
  fi
  if ((sp_uptime_seconds < sp_boot_grace_seconds)); then
    sp_log INFO "decision=defer reason=boot_grace uptime_seconds=$sp_uptime_seconds"
    return 0
  fi

  local sp_now_epoch
  sp_now_epoch="$(sp_current_epoch)"
  if [[ ! "$sp_now_epoch" =~ ^[0-9]+$ ]]; then
    sp_log WARN 'decision=defer reason=clock_signal_unavailable'
    return 0
  fi
  if ! sp_policy_still_idle "$sp_now_epoch" "$sp_idle_seconds" "$sp_gateway_service" "$sp_inhibit_file"; then
    return 0
  fi

  if [[ "$sp_dry_run" == 'true' ]]; then
    sp_log INFO "decision=would_power_off dry_run=true idle_seconds=$SP_ACTIVITY_AGE_SECONDS"
    return 0
  fi

  if ((sp_final_grace_seconds > 0)); then
    sp_log INFO "decision=final_grace seconds=$sp_final_grace_seconds"
    sp_warn_terminals "$sp_final_grace_seconds"
    sp_sleep "$sp_final_grace_seconds"

    sp_now_hhmm="$(sp_current_local_hhmm)"
    sp_now_minutes="$(sp_parse_hhmm "$sp_now_hhmm")" || return 0
    if ! sp_is_inside_window "$sp_now_minutes" "$sp_start_minutes" "$sp_end_minutes"; then
      sp_log INFO "decision=defer reason=window_closed_during_grace local_time=$sp_now_hhmm"
      return 0
    fi

    sp_now_epoch="$(sp_current_epoch)"
    if [[ ! "$sp_now_epoch" =~ ^[0-9]+$ ]] \
      || ! sp_policy_still_idle "$sp_now_epoch" "$sp_idle_seconds" "$sp_gateway_service" "$sp_inhibit_file"; then
      return 0
    fi
  fi

  sp_log NOTICE "decision=power_off idle_seconds=$SP_ACTIVITY_AGE_SECONDS"
  sp_request_poweroff
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  sp_main "$@"
fi
