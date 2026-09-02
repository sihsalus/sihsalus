#!/bin/sh

set -eu

interval="${COLLECTION_INTERVAL_SECONDS:-60}"
output=/metrics/sihsalus.prom
temporary=/metrics/.sihsalus.prom.tmp

case "$interval" in
  *[!0-9]* | 0)
    echo "COLLECTION_INTERVAL_SECONDS must be a positive integer" >&2
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
  } >"$temporary"
  mv -f "$temporary" "$output"
  sleep "$interval"
done
