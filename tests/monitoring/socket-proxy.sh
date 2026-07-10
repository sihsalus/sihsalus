#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

cleanup() {
  docker compose --profile monitoring --profile logs rm -sf docker-socket-proxy >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker compose --profile monitoring --profile logs up -d docker-socket-proxy

PING="$(docker run --rm \
  --network container:sihsalus-docker-socket-proxy \
  curlimages/curl:8.12.1 \
  -fsS http://localhost:2375/_ping)"

if [ "$PING" != "OK" ]; then
  echo "[FAIL] Docker proxy ping returned: $PING" >&2
  exit 1
fi

if docker run --rm \
  --network container:sihsalus-docker-socket-proxy \
  curlimages/curl:8.12.1 \
  -fsS -X POST http://localhost:2375/containers/create; then
  echo "[FAIL] Docker proxy accepted POST /containers/create" >&2
  exit 1
fi

echo "[OK] Docker proxy permits reads and rejects writes"
