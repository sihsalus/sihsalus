#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE_DIR="$(mktemp -d)"
CONTAINER_NAME="sihsalus-frontend-cache-test-$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  rm -rf "$FIXTURE_DIR"
}
trap cleanup EXIT

chmod 755 "$FIXTURE_DIR"
for file in \
  index.html \
  importmap.json \
  routes.registry.json \
  frontend.json \
  build-info.json \
  service-worker.js \
  openmrs-esm-odontologia-app.js \
  openmrs-esm-odontologia-app.0123456789abcdef.js \
  esm-odontologia-806-0123456789abcdef.js \
  plain-runtime.js; do
  printf '%s\n' "$file" > "$FIXTURE_DIR/$file"
done

docker run --detach --rm \
  --name "$CONTAINER_NAME" \
  --publish 127.0.0.1::80 \
  --volume "$ROOT_DIR/frontend/nginx.conf:/etc/nginx/nginx.conf:ro" \
  --volume "$FIXTURE_DIR:/usr/share/nginx/html:ro" \
  nginx:1.28-alpine >/dev/null

PORT="$(docker port "$CONTAINER_NAME" 80/tcp | sed -E 's/.*:([0-9]+)$/\1/' | head -n 1)"
BASE_URL="http://127.0.0.1:$PORT"

for _ in $(seq 1 30); do
  if curl --fail --silent --output /dev/null "$BASE_URL/"; then
    break
  fi
  sleep 0.2
done

assert_cache_control() {
  local path="$1"
  local expected="$2"
  local headers
  headers="$(curl --fail --silent --show-error --head "$BASE_URL$path")"

  if ! grep -Fqi "Cache-Control: $expected" <<< "$headers"; then
    echo "[FAIL] $path did not return Cache-Control: $expected" >&2
    echo "$headers" >&2
    exit 1
  fi
}

NO_CACHE="no-cache, no-store, must-revalidate"
IMMUTABLE="public, max-age=31536000, immutable"

assert_cache_control /service-worker.js "$NO_CACHE"
assert_cache_control /importmap.json "$NO_CACHE"
assert_cache_control /openmrs-esm-odontologia-app.js "$NO_CACHE"
assert_cache_control /plain-runtime.js "$NO_CACHE"
assert_cache_control /openmrs-esm-odontologia-app.0123456789abcdef.js "$IMMUTABLE"
assert_cache_control /esm-odontologia-806-0123456789abcdef.js "$IMMUTABLE"
assert_cache_control /patient/example/chart/atencion-odontologica "$NO_CACHE"

echo "[OK] frontend cache policy"
