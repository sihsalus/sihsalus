#!/usr/bin/env bash

set -Eeuo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <40-character frontend git SHA> <sha256 image digest>" >&2
  exit 2
fi

TARGET_SHA="$1"
TARGET_DIGEST="$2"
SOURCE_TAG="sha-${TARGET_SHA}"
RUNTIME_TAG="digest-${TARGET_DIGEST#sha256:}"
SOURCE_REPOSITORY="ghcr.io/sihsalus/sihsalus-frontend"
SOURCE_IMAGE="${SOURCE_REPOSITORY}@${TARGET_DIGEST}"

if [[ ! "$TARGET_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "[deploy-frontend] invalid frontend SHA" >&2
  exit 2
fi

if [[ ! "$TARGET_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "[deploy-frontend] invalid frontend image digest" >&2
  exit 2
fi

for command in docker git awk cat cp mktemp rm seq sleep; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "[deploy-frontend] missing command: $command" >&2
    exit 2
  }
done

if [ ! -f docker-compose.yml ] || [ ! -f .env ]; then
  echo "[deploy-frontend] run from the sihsalus repository root" >&2
  exit 2
fi

read_env_value() {
  local key="$1"
  awk -F= -v key="$key" '
    $1 == key {
      sub(/^[^=]*=/, "")
      value = $0
    }
    END { print value }
  ' .env
}

write_env_value() {
  local key="$1"
  local value="$2"
  local temporary_file
  temporary_file="$(mktemp)"

  awk -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    $0 ~ ("^" key "=") {
      print key "=" value
      found = 1
      next
    }
    { print }
    END {
      if (!found) {
        print key "=" value
      }
    }
  ' .env >"$temporary_file"

  cat "$temporary_file" >.env
  rm -f "$temporary_file"
}

deployed_sha() {
  docker exec sihsalus-frontend \
    wget -qO- http://127.0.0.1/build-info.json 2>/dev/null |
    awk -F'"' '/"gitSha"[[:space:]]*:/ { print $4; exit }'
}

container_health() {
  docker inspect sihsalus-frontend \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
    2>/dev/null || true
}

container_image() {
  docker inspect sihsalus-frontend --format '{{.Config.Image}}' 2>/dev/null || true
}

CURRENT_SHA="$(deployed_sha || true)"
CURRENT_SOURCE_IMAGE="$(read_env_value FRONTEND_SOURCE_IMAGE)"
CURRENT_SOURCE_TAG="$(read_env_value FRONTEND_SOURCE_TAG)"
CURRENT_RUNTIME_TAG="$(read_env_value FRONTEND_RUNTIME_TAG)"
CURRENT_HEALTH="$(container_health)"
CURRENT_IMAGE="$(container_image)"
RUNTIME_IMAGE_REPOSITORY="$(read_env_value FRONTEND_RUNTIME_IMAGE)"
RUNTIME_IMAGE_REPOSITORY="${RUNTIME_IMAGE_REPOSITORY:-sihsalus-frontend-runtime}"
TARGET_RUNTIME_IMAGE="${RUNTIME_IMAGE_REPOSITORY}:${RUNTIME_TAG}"

if [ "$CURRENT_SHA" = "$TARGET_SHA" ] &&
  [ "$CURRENT_SOURCE_IMAGE" = "$SOURCE_IMAGE" ] &&
  [ "$CURRENT_SOURCE_TAG" = "$SOURCE_TAG" ] &&
  [ "$CURRENT_RUNTIME_TAG" = "$RUNTIME_TAG" ] &&
  [ "$CURRENT_IMAGE" = "$TARGET_RUNTIME_IMAGE" ] &&
  [ "$CURRENT_HEALTH" = "healthy" ]; then
  echo "[deploy-frontend] ${SOURCE_TAG} at ${TARGET_DIGEST} is already healthy; nothing to do"
  exit 0
fi

ENV_BACKUP="$(mktemp)"
cp -p .env "$ENV_BACKUP"
ROLLBACK_REQUIRED=true
FRONTEND_RECREATE_ATTEMPTED=false

rollback() {
  local exit_code="${1:-$?}"
  trap - ERR HUP INT TERM

  if [ "$ROLLBACK_REQUIRED" = true ]; then
    echo "[deploy-frontend] deployment failed; restoring previous frontend configuration" >&2
    cp -p "$ENV_BACKUP" .env
    if [ "$FRONTEND_RECREATE_ATTEMPTED" = true ]; then
      echo "[deploy-frontend] restoring previous frontend container" >&2
      docker compose up -d --no-deps --no-build --pull never --force-recreate frontend || true
    fi
  fi

  rm -f "$ENV_BACKUP"
  exit "$exit_code"
}

trap 'rollback $?' ERR
trap 'rollback 129' HUP
trap 'rollback 130' INT
trap 'rollback 143' TERM

echo "[deploy-frontend] updating distro checkout"
git fetch origin main
git merge --ff-only origin/main

echo "[deploy-frontend] pulling immutable source image ${SOURCE_IMAGE}"
docker pull "$SOURCE_IMAGE"

SOURCE_SHA="$(
  docker image inspect "$SOURCE_IMAGE" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}'
)"
if [ "$SOURCE_SHA" != "$TARGET_SHA" ]; then
  echo "[deploy-frontend] source image revision does not match requested SHA" >&2
  false
fi

write_env_value FRONTEND_SOURCE_IMAGE "$SOURCE_IMAGE"
write_env_value FRONTEND_SOURCE_TAG "$SOURCE_TAG"
write_env_value FRONTEND_RUNTIME_TAG "$RUNTIME_TAG"

docker compose config --quiet

echo "[deploy-frontend] building runtime wrapper"
docker compose build --pull frontend

echo "[deploy-frontend] recreating frontend only"
FRONTEND_RECREATE_ATTEMPTED=true
docker compose up -d --no-deps --no-build --pull never --force-recreate frontend

for _ in $(seq 1 36); do
  health="$(container_health)"
  case "$health" in
    healthy)
      break
      ;;
    unhealthy | exited | dead)
      echo "[deploy-frontend] frontend entered state: $health" >&2
      false
      ;;
  esac
  sleep 5
done

if [ "$(container_health)" != "healthy" ]; then
  echo "[deploy-frontend] frontend did not become healthy before timeout" >&2
  false
fi

ACTUAL_SHA="$(deployed_sha)"
if [ "$ACTUAL_SHA" != "$TARGET_SHA" ]; then
  echo "[deploy-frontend] deployed SHA does not match the requested release" >&2
  false
fi

ACTUAL_IMAGE="$(docker inspect sihsalus-frontend --format '{{.Config.Image}}')"
if [ "$ACTUAL_IMAGE" != "$TARGET_RUNTIME_IMAGE" ]; then
  echo "[deploy-frontend] deployed runtime image is not ${TARGET_RUNTIME_IMAGE}" >&2
  false
fi

ROLLBACK_REQUIRED=false
trap - ERR HUP INT TERM
rm -f "$ENV_BACKUP"

echo "[deploy-frontend] deployed ${SOURCE_TAG} from ${SOURCE_IMAGE}"
