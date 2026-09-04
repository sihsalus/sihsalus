#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

cleanup() {
  if [ -n "${GATUS_TEST_CONTAINER:-}" ]; then
    docker rm -f "$GATUS_TEST_CONTAINER" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

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
grep -Fq 'expr: (sihsalus_ups_battery_charge_percent < 40) and (sihsalus_ups_battery_charge_percent >= 35)' \
  monitoring/prometheus/alerts/basic-alerts.yml
grep -Fq 'expr: sihsalus_ups_battery_charge_percent < 35' \
  monitoring/prometheus/alerts/basic-alerts.yml
grep -Fq 'Type=simple' scripts/utils/viewpower.service
grep -Fq 'Restart=always' scripts/utils/viewpower.service
grep -Fq 'ExecStop=/home/hii1sc/ViewPower/StopMain' scripts/utils/viewpower.service
grep -Fq 'IPAddressDeny=any' scripts/utils/viewpower.service

python3 -m unittest discover -s tests/monitoring -p 'test_*.py'

docker run --rm \
  --entrypoint /bin/alloy \
  -v "$ROOT_DIR/monitoring/alloy/config.alloy:/etc/alloy/config.alloy:ro" \
  grafana/alloy:v1.13.1 \
  validate /etc/alloy/config.alloy

docker run --rm \
  --entrypoint /bin/promtool \
  -v "$ROOT_DIR/monitoring/prometheus:/etc/prometheus:ro" \
  prom/prometheus:v3.2.1 \
  check config /etc/prometheus/prometheus.yml

GATUS_TEST_CONTAINER="$(docker run -d --rm \
  -e GATUS_CONFIG_PATH=/config/config.yaml \
  --tmpfs /data \
  -v "$ROOT_DIR/monitoring/status/gatus/config.yaml:/config/config.yaml:ro" \
  twinproduction/gatus:v5.20.0)"
sleep 2

if [ "$(docker inspect --format '{{.State.Running}}' "$GATUS_TEST_CONTAINER")" != "true" ]; then
  docker logs "$GATUS_TEST_CONTAINER" >&2
  echo "[FAIL] Gatus rejected monitoring/status/gatus/config.yaml" >&2
  exit 1
fi

echo "[OK] Grafana JSON, ViewPower unit, Alloy, Prometheus rules and Gatus configuration"
