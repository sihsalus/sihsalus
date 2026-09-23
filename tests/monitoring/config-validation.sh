#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

if [[ "$#" -gt 1 || ( "$#" -eq 1 && "$1" != "--static" ) ]]; then
  echo "Usage: $0 [--static]" >&2
  exit 2
fi

for dashboard in monitoring/grafana/dashboards/*.json; do
  jq empty "$dashboard"
done

jq -e '
  .version >= 4
  and (([.panels[].id] | length) == ([.panels[].id] | unique | length))
  and ([.panels[].title] | index("Boots observados · 24 h") != null)
  and ([.panels[].title] | index("Arranques o recreaciones por servicio · 24 h") != null)
  and ([.panels[].title] | index("Continuidad correlacionada") != null)
  and ([.panels[] | select(.id == 12) | .fieldConfig.defaults.thresholds.steps[].value] | index(35) != null)
' monitoring/grafana/dashboards/resilience-overview.json >/dev/null

jq -e '
  [.. | objects | .expr? // empty]
  | any(contains("container_label_com_docker_compose_project=~\"sihsalus|sihsalus-samba-backup\""))
' monitoring/grafana/dashboards/infrastructure-overview.json >/dev/null
grep -Fq 'alert: HostRebootLoop' monitoring/prometheus/alerts/basic-alerts.yml
grep -Fq 'alert: ContainerRestartLoop' monitoring/prometheus/alerts/basic-alerts.yml
grep -Fq 'expr: max(sihsalus_network_interface_present{device=~"tun0|tun1"}) == 0' \
  monitoring/prometheus/alerts/basic-alerts.yml
if grep -Fq 'tun0 corresponde a CloudConnexa' monitoring/grafana/dashboards/resilience-overview.json; then
  echo "[FAIL] El dashboard no debe inferir el proveedor VPN a partir del indice tunN" >&2
  exit 1
fi
grep -Fq 'expr: (sihsalus_ups_battery_charge_percent < 40) and (sihsalus_ups_battery_charge_percent >= 35)' \
  monitoring/prometheus/alerts/basic-alerts.yml
grep -Fq 'expr: sihsalus_ups_battery_charge_percent < 35' \
  monitoring/prometheus/alerts/basic-alerts.yml
grep -Fq 'Type=simple' scripts/utils/viewpower.service
grep -Fq 'Restart=always' scripts/utils/viewpower.service
grep -Fq 'ExecStop=/home/hii1sc/ViewPower/StopMain' scripts/utils/viewpower.service
grep -Fq 'IPAddressDeny=any' scripts/utils/viewpower.service

python3 -B -m unittest discover -s tests/monitoring -p 'test_*.py'

if [[ "${1:-}" == "--static" ]]; then
  echo "[OK] Grafana JSON, alert contracts and ViewPower unit tests"
  exit 0
fi

GATUS_TEST_CONTAINER=""
cleanup() {
  if [ -n "$GATUS_TEST_CONTAINER" ]; then
    docker rm -f "$GATUS_TEST_CONTAINER" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Use the service images from Compose so dependency updates are tested too.
monitoring_model="$(
  unset COMPOSE_FILE COMPOSE_PROFILES
  docker compose --env-file /dev/null -f docker-compose.yml -f compose/status.yml \
    --profile monitoring --profile logs --profile status config --format json
)"
alloy_image="$(jq -er '.services.alloy.image' <<<"$monitoring_model")"
prometheus_image="$(jq -er '.services.prometheus.image' <<<"$monitoring_model")"
gatus_image="$(jq -er '.services.gatus.image' <<<"$monitoring_model")"
unset monitoring_model

docker run --rm \
  --entrypoint /bin/alloy \
  -v "$ROOT_DIR/monitoring/alloy/config.alloy:/etc/alloy/config.alloy:ro" \
  "$alloy_image" \
  validate /etc/alloy/config.alloy

docker run --rm \
  --entrypoint /bin/promtool \
  -v "$ROOT_DIR/monitoring/prometheus:/etc/prometheus:ro" \
  "$prometheus_image" \
  check config /etc/prometheus/prometheus.yml

docker run --rm \
  --entrypoint /bin/promtool \
  -v "$ROOT_DIR:/workspace:ro" \
  -w /workspace \
  "$prometheus_image" \
  test rules tests/monitoring/vpn-alerts.test.yml

GATUS_TEST_CONTAINER="$(docker run -d --rm \
  -e GATUS_CONFIG_PATH=/config/config.yaml \
  --tmpfs /data \
  -v "$ROOT_DIR/monitoring/status/gatus/config.yaml:/config/config.yaml:ro" \
  "$gatus_image")"
sleep 2

if [ "$(docker inspect --format '{{.State.Running}}' "$GATUS_TEST_CONTAINER")" != "true" ]; then
  docker logs "$GATUS_TEST_CONTAINER" >&2
  echo "[FAIL] Gatus rejected monitoring/status/gatus/config.yaml" >&2
  exit 1
fi

echo "[OK] Grafana JSON, ViewPower unit, Alloy, Prometheus rules (including VPN failover) and Gatus configuration"
