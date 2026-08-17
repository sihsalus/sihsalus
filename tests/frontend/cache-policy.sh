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

# index.html realista: los metatags sociales viajan relativos en la imagen
# inmutable y el nginx debe absolutizarlos con el Host de la peticion.
cat > "$FIXTURE_DIR/index.html" <<'EOF_HTML'
<!doctype html><html><head><title>SIH.SALUS</title>
<meta property="og:url" content="/openmrs/spa">
<meta property="og:image" content="/openmrs/spa/sihsalus-share.png">
<meta name="twitter:image" content="/openmrs/spa/sihsalus-share.png">
</head><body></body></html>
EOF_HTML

docker run --detach --rm \
  --name "$CONTAINER_NAME" \
  --publish 127.0.0.1::80 \
  --volume "$ROOT_DIR/frontend/nginx.conf:/etc/nginx/nginx.conf:ro" \
  --volume "$FIXTURE_DIR:/usr/share/nginx/html:ro" \
  nginx:1.28-alpine >/dev/null

PORT="$(docker port "$CONTAINER_NAME" 80/tcp | sed -E 's/.*:([0-9]+)$/\1/' | head -n 1)"
BASE_URL="http://127.0.0.1:$PORT"

ready=false
for _ in $(seq 1 30); do
  if curl --fail --silent --output /dev/null "$BASE_URL/"; then
    ready=true
    break
  fi
  sleep 0.2
done

if [ "$ready" != "true" ]; then
  echo "[FAIL] frontend nginx did not become ready" >&2
  docker logs "$CONTAINER_NAME" >&2
  exit 1
fi

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

social_preview_html="$(curl --fail --silent --header 'Host: gidis-social.example' "$BASE_URL/patient/example/chart")"
for expected in \
  'content="https://gidis-social.example/openmrs/spa"' \
  'content="https://gidis-social.example/openmrs/spa/sihsalus-share.png"'; do
  if ! grep -Fq "$expected" <<< "$social_preview_html"; then
    echo "[FAIL] social preview tags were not absolutized with the request host" >&2
    printf '%s\n' "$social_preview_html" >&2
    exit 1
  fi
done
if grep -Fq 'content="/openmrs/spa' <<< "$social_preview_html"; then
  echo "[FAIL] a relative social preview URL survived the rewrite" >&2
  exit 1
fi
echo "[OK] social preview host rewrite"
