#!/bin/sh

set -eu

interval="${COLLECTION_INTERVAL_SECONDS:-60}"
samba_quota_bytes="${SAMBA_QUOTA_BYTES:-21474836480}"
output=/metrics/sihsalus.prom
temporary=/metrics/.sihsalus.prom.tmp

case "$interval" in
  *[!0-9]* | 0)
    echo "COLLECTION_INTERVAL_SECONDS must be a positive integer" >&2
    exit 2
    ;;
esac

case "$samba_quota_bytes" in
  "" | *[!0-9]* | 0)
    echo "SAMBA_QUOTA_BYTES must be a positive integer" >&2
    exit 2
    ;;
esac

emit_latest_artifact() {
  backup="$1"
  pattern="$2"
  latest_timestamp=0
  latest_size=0
  artifact_count=0

  for artifact in $pattern; do
    [ -f "$artifact" ] || continue
    timestamp="$(stat -c %Y "$artifact")"
    size="$(stat -c %s "$artifact")"
    artifact_count=$((artifact_count + 1))
    if [ "$timestamp" -gt "$latest_timestamp" ]; then
      latest_timestamp="$timestamp"
      latest_size="$size"
    fi
  done

  printf 'sihsalus_backup_latest_timestamp_seconds{backup="%s"} %s\n' "$backup" "$latest_timestamp"
  printf 'sihsalus_backup_latest_size_bytes{backup="%s"} %s\n' "$backup" "$latest_size"
  printf 'sihsalus_backup_artifacts_total{backup="%s"} %s\n' "$backup" "$artifact_count"
}

emit_marker() {
  marker="$1"
  path="$2"
  timestamp=0
  [ -f "$path" ] && timestamp="$(stat -c %Y "$path")"
  printf 'sihsalus_backup_marker_timestamp_seconds{marker="%s"} %s\n' "$marker" "$timestamp"
}

emit_network_interface() {
  device="$1"
  interface_path="/host-sys/class/net/$device"
  present=0
  carrier=0
  receive_bytes=0
  transmit_bytes=0

  if [ -d "$interface_path" ]; then
    present=1
    [ -r "$interface_path/carrier" ] && carrier="$(cat "$interface_path/carrier")"
    [ -r "$interface_path/statistics/rx_bytes" ] && receive_bytes="$(cat "$interface_path/statistics/rx_bytes")"
    [ -r "$interface_path/statistics/tx_bytes" ] && transmit_bytes="$(cat "$interface_path/statistics/tx_bytes")"
  fi

  printf 'sihsalus_network_interface_present{device="%s"} %s\n' "$device" "$present"
  printf 'sihsalus_network_carrier{device="%s"} %s\n' "$device" "$carrier"
  printf 'sihsalus_network_receive_bytes_total{device="%s"} %s\n' "$device" "$receive_bytes"
  printf 'sihsalus_network_transmit_bytes_total{device="%s"} %s\n' "$device" "$transmit_bytes"
}

directory_size_bytes() {
  path="$1"
  size_kb="$(du -sk "$path" 2>/dev/null | awk '{print $1}' || true)"
  case "$size_kb" in
    "" | *[!0-9]*) size_kb=0 ;;
  esac
  printf '%s\n' "$((size_kb * 1024))"
}

emit_samba_share() {
  share="$1"
  path="$2"
  present=0
  size_bytes=0
  if [ -d "$path" ]; then
    present=1
    size_bytes="$(directory_size_bytes "$path")"
  fi
  printf 'sihsalus_samba_share_present{share="%s"} %s\n' "$share" "$present"
  printf 'sihsalus_samba_share_size_bytes{share="%s"} %s\n' "$share" "$size_bytes"
}

while :; do
  now="$(date +%s)"
  {
    echo '# HELP sihsalus_operations_collector_last_run_seconds Unix timestamp of the last successful collector run.'
    echo '# TYPE sihsalus_operations_collector_last_run_seconds gauge'
    printf 'sihsalus_operations_collector_last_run_seconds %s\n' "$now"
    echo '# HELP sihsalus_backup_latest_timestamp_seconds Unix timestamp of the newest encrypted backup artifact.'
    echo '# TYPE sihsalus_backup_latest_timestamp_seconds gauge'
    echo '# HELP sihsalus_backup_latest_size_bytes Size of the newest encrypted backup artifact.'
    echo '# TYPE sihsalus_backup_latest_size_bytes gauge'
    echo '# HELP sihsalus_backup_artifacts_total Number of encrypted artifacts currently retained.'
    echo '# TYPE sihsalus_backup_artifacts_total gauge'
    emit_latest_artifact mariadb '/backups/dump_*.sql.gz.enc'
    emit_latest_artifact hapi '/backups/hapi_*.dump.enc'
    emit_latest_artifact fua '/backups/fua_*.dump.enc'
    echo '# HELP sihsalus_backup_marker_timestamp_seconds Unix timestamp of a successful backup marker.'
    echo '# TYPE sihsalus_backup_marker_timestamp_seconds gauge'
    emit_marker primary /backups/.last-success
    emit_marker secondary /backups/.secondary-last-success
    echo '# HELP sihsalus_network_interface_present Whether an expected host interface exists.'
    echo '# TYPE sihsalus_network_interface_present gauge'
    echo '# HELP sihsalus_network_carrier Link carrier state reported by the host interface.'
    echo '# TYPE sihsalus_network_carrier gauge'
    echo '# HELP sihsalus_network_receive_bytes_total Bytes received by the host interface.'
    echo '# TYPE sihsalus_network_receive_bytes_total counter'
    echo '# HELP sihsalus_network_transmit_bytes_total Bytes transmitted by the host interface.'
    echo '# TYPE sihsalus_network_transmit_bytes_total counter'
    emit_network_interface eno8303
    emit_network_interface eno8403
    emit_network_interface tun0
    emit_network_interface tun1
    echo '# HELP sihsalus_samba_data_present Whether the standalone Samba data directory is mounted.'
    echo '# TYPE sihsalus_samba_data_present gauge'
    echo '# HELP sihsalus_samba_used_bytes Bytes used by the complete Samba data tree.'
    echo '# TYPE sihsalus_samba_used_bytes gauge'
    if [ -d /backups/samba ]; then
      echo 'sihsalus_samba_data_present 1'
      printf 'sihsalus_samba_used_bytes %s\n' "$(directory_size_bytes /backups/samba)"
    else
      echo 'sihsalus_samba_data_present 0'
      echo 'sihsalus_samba_used_bytes 0'
    fi
    echo '# HELP sihsalus_samba_quota_bytes Informational quota exposed to SMB clients.'
    echo '# TYPE sihsalus_samba_quota_bytes gauge'
    printf 'sihsalus_samba_quota_bytes %s\n' "$samba_quota_bytes"
    echo '# HELP sihsalus_samba_share_present Whether an expected Samba share directory exists.'
    echo '# TYPE sihsalus_samba_share_present gauge'
    echo '# HELP sihsalus_samba_share_size_bytes Bytes used by an expected Samba share.'
    echo '# TYPE sihsalus_samba_share_size_bytes gauge'
    emit_samba_share secretariaRRHH /backups/samba/secretariaRRHH
    emit_samba_share asistenteRRHH /backups/samba/asistenteRRHH
  } >"$temporary"
  mv -f "$temporary" "$output"
  sleep "$interval"
done
