#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

# This test mounts the Docker socket and uses the stack's fixed container name.
# Only run against the local daemon of a disposable GitHub-hosted runner.
if [[ "${GITHUB_ACTIONS:-}" != "true" || "${RUNNER_ENVIRONMENT:-}" != "github-hosted" ]]; then
  echo "[FAIL] Docker proxy test requires ephemeral GitHub-hosted CI" >&2
  exit 1
fi
unset DOCKER_CONTEXT DOCKER_HOST
DOCKER=(docker --host unix:///var/run/docker.sock)
COMPOSE=("${DOCKER[@]}" compose --env-file /dev/null -f docker-compose.yml
  --project-name sihsalus-monitoring-test --profile monitoring --profile logs)

cleanup() {
  "${COMPOSE[@]}" rm -sf docker-socket-proxy >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${COMPOSE[@]}" up -d docker-socket-proxy

PING="$("${DOCKER[@]}" run --rm \
  --network container:sihsalus-docker-socket-proxy \
  curlimages/curl:8.12.1 \
  -fsS --retry 10 --retry-connrefused --retry-delay 1 --max-time 5 \
  http://localhost:2375/_ping)"

if [ "$PING" != "OK" ]; then
  echo "[FAIL] Docker proxy ping returned: $PING" >&2
  exit 1
fi

STATUS="$("${DOCKER[@]}" run --rm \
  --network container:sihsalus-docker-socket-proxy \
  curlimages/curl:8.12.1 \
  -sS -o /dev/null -w '%{http_code}' --max-time 5 \
  -X POST http://localhost:2375/containers/create)"
if [[ "$STATUS" != "403" ]]; then
  echo "[FAIL] Docker proxy must reject POST /containers/create with 403; got $STATUS" >&2
  exit 1
fi

echo "[OK] Docker proxy permits reads and rejects writes"
