#!/usr/bin/env bash
set -euo pipefail

url="${1:-http://localhost/openmrs/login.htm}"
timeout_seconds="${2:-${OPENMRS_WAIT_TIMEOUT_SECONDS:-1800}}"
poll_seconds="${3:-10}"
log_container="${4:-backend}"

start_epoch="$(date +%s)"

echo "Waiting for OpenMRS at ${url}"
echo "Timeout: ${timeout_seconds}s"

while true; do
  http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "${url}" || true)"
  if [[ "${http_code}" == "200" ]]; then
    echo "OpenMRS is ready"
    exit 0
  fi

  elapsed_seconds="$(( $(date +%s) - start_epoch ))"
  if (( elapsed_seconds >= timeout_seconds )); then
    echo "ERROR: OpenMRS did not become ready within ${timeout_seconds}s" >&2
    if [[ -n "${log_container}" ]]; then
      docker logs --tail 120 "${log_container}" >&2 || true
    fi
    exit 1
  fi

  sleep "${poll_seconds}"
done
