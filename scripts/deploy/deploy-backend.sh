#!/usr/bin/env bash

set -Eeuo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <40-character backend git SHA> <sha256 image digest>" >&2
  exit 2
fi

TARGET_SHA="$1"
TARGET_DIGEST="$2"
TARGET_TAG="sha-${TARGET_SHA}"
BACKEND_REPOSITORY="ghcr.io/sihsalus/sihsalus-backend"
TARGET_REFERENCE="${TARGET_TAG}@${TARGET_DIGEST}"
TARGET_IMAGE="${BACKEND_REPOSITORY}:${TARGET_REFERENCE}"
SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEAN_CHECKOUT_HELPER="$SCRIPT_DIRECTORY/check-clean-checkout.sh"

if [[ ! "$TARGET_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "[deploy-backend] invalid backend SHA" >&2
  exit 2
fi
if [[ ! "$TARGET_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "[deploy-backend] invalid backend image digest" >&2
  exit 2
fi

for command in docker git awk chmod cp df mktemp mv rm seq sleep stat; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "[deploy-backend] missing command: $command" >&2
    exit 2
  }
done
if [ ! -f docker-compose.yml ] || [ ! -f .env ]; then
  echo "[deploy-backend] run from the sihsalus repository root" >&2
  exit 2
fi
if [ ! -r "$CLEAN_CHECKOUT_HELPER" ]; then
  echo "[deploy-backend] clean-checkout helper is not readable" >&2
  exit 2
fi
bash "$CLEAN_CHECKOUT_HELPER" deploy-backend

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
  local env_mode
  local temporary_file
  env_mode="$(stat -c %a .env 2>/dev/null || stat -f %Lp .env)"
  temporary_file="$(mktemp ./.env.deploy-backend.XXXXXX)"
  if ! awk -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    $0 ~ ("^" key "=") {
      print key "=" value
      found = 1
      next
    }
    { print }
    END {
      if (!found) print key "=" value
    }
  ' .env >"$temporary_file"; then
    rm -f "$temporary_file"
    return 1
  fi
  chmod "$env_mode" "$temporary_file"
  mv -f "$temporary_file" .env
}

container_health() {
  docker inspect sihsalus-backend \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
    2>/dev/null || true
}

openmrs_started() {
  docker exec sihsalus-backend \
    curl --fail --silent --show-error --max-time 10 \
    http://127.0.0.1:8080/openmrs/health/started >/dev/null 2>&1
}

CURRENT_IMAGE="$(docker inspect sihsalus-backend --format '{{.Config.Image}}' 2>/dev/null || true)"
CURRENT_IMAGE_ID="$(docker inspect sihsalus-backend --format '{{.Image}}' 2>/dev/null || true)"
CURRENT_HEALTH="$(container_health)"
CURRENT_ENV_TAG="$(read_env_value BACKEND_TAG)"

if [[ "$CURRENT_IMAGE" != "${BACKEND_REPOSITORY}:"* ]] || [ -z "$CURRENT_IMAGE_ID" ]; then
  echo "[deploy-backend] current backend image is missing or outside ${BACKEND_REPOSITORY}; refusing a deployment without rollback" >&2
  exit 1
fi
if [ "$CURRENT_HEALTH" != "healthy" ] || ! openmrs_started; then
  echo "[deploy-backend] current backend is not healthy and started; refusing to replace it" >&2
  exit 1
fi
CURRENT_REFERENCE="${CURRENT_IMAGE#${BACKEND_REPOSITORY}:}"
if [[ "$CURRENT_REFERENCE" =~ [[:space:]] ]] || [ -z "$CURRENT_REFERENCE" ]; then
  echo "[deploy-backend] current backend reference is unsafe for rollback" >&2
  exit 1
fi
docker image inspect "$CURRENT_IMAGE_ID" >/dev/null

if [ "$CURRENT_IMAGE" = "$TARGET_IMAGE" ]; then
  CURRENT_REVISION="$(docker image inspect "$CURRENT_IMAGE_ID" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
  if [ "$CURRENT_REVISION" != "$TARGET_SHA" ]; then
    echo "[deploy-backend] running image reference matches, but its source revision does not" >&2
    exit 1
  fi
  if [ "$CURRENT_ENV_TAG" != "$TARGET_REFERENCE" ]; then
    write_env_value BACKEND_TAG "$TARGET_REFERENCE"
  fi
  echo "[deploy-backend] ${TARGET_TAG} at ${TARGET_DIGEST} is already healthy; nothing to do"
  exit 0
fi

MINIMUM_FREE_DISK_MIB="${DEPLOY_MINIMUM_FREE_DISK_MIB:-4096}"
AVAILABLE_DISK_MIB="$(df -Pm . | awk 'NR == 2 { print $4 }')"
if [ "${AVAILABLE_DISK_MIB:-0}" -lt "$MINIMUM_FREE_DISK_MIB" ]; then
  echo "[deploy-backend] insufficient disk space: ${AVAILABLE_DISK_MIB} MiB free, ${MINIMUM_FREE_DISK_MIB} MiB required" >&2
  exit 2
fi

ENV_BACKUP="$(mktemp)"
cp -p .env "$ENV_BACKUP"
ROLLBACK_REQUIRED=true
BACKEND_RECREATE_ATTEMPTED=false

rollback() {
  local exit_code="${1:-$?}"
  trap - ERR HUP INT TERM
  if [ "$ROLLBACK_REQUIRED" = true ]; then
    echo "[deploy-backend] deployment failed; restoring the previous backend" >&2
    cp -p "$ENV_BACKUP" .env
    if [ "$BACKEND_RECREATE_ATTEMPTED" = true ]; then
      BACKEND_TAG="$CURRENT_REFERENCE" docker compose up \
        -d --no-deps --no-build --pull never --force-recreate backend || true
    fi
  fi
  rm -f "$ENV_BACKUP"
  exit "$exit_code"
}

trap 'rollback $?' ERR
trap 'rollback 129' HUP
trap 'rollback 130' INT
trap 'rollback 143' TERM

echo "[deploy-backend] updating distro checkout"
git fetch origin main
git merge --ff-only origin/main

echo "[deploy-backend] pulling immutable image ${TARGET_IMAGE}"
docker pull "$TARGET_IMAGE"
TARGET_IMAGE_ID="$(docker image inspect "$TARGET_IMAGE" --format '{{.Id}}')"
TARGET_REVISION="$(docker image inspect "$TARGET_IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
if [ "$TARGET_REVISION" != "$TARGET_SHA" ]; then
  echo "[deploy-backend] image revision does not match requested SHA" >&2
  false
fi

export BACKEND_TAG="$TARGET_REFERENCE"
docker compose config --quiet
echo "[deploy-backend] recreating backend only"
BACKEND_RECREATE_ATTEMPTED=true
docker compose up -d --no-deps --no-build --pull never --force-recreate backend

TIMEOUT_SECONDS="${BACKEND_DEPLOY_TIMEOUT_SECONDS:-2400}"
ELAPSED_SECONDS=0
while [ "$ELAPSED_SECONDS" -lt "$TIMEOUT_SECONDS" ]; do
  HEALTH="$(container_health)"
  if [ "$HEALTH" = "healthy" ] && openmrs_started; then
    break
  fi
  case "$HEALTH" in
    unhealthy | exited | dead)
      echo "[deploy-backend] backend entered state: $HEALTH" >&2
      false
      ;;
  esac
  if [ $((ELAPSED_SECONDS % 60)) -eq 0 ]; then
    echo "[deploy-backend] waiting for OpenMRS (${ELAPSED_SECONDS}s/${TIMEOUT_SECONDS}s)"
  fi
  sleep 15
  ELAPSED_SECONDS=$((ELAPSED_SECONDS + 15))
done
if [ "$(container_health)" != "healthy" ] || ! openmrs_started; then
  echo "[deploy-backend] OpenMRS did not become healthy before timeout" >&2
  false
fi

ACTUAL_IMAGE="$(docker inspect sihsalus-backend --format '{{.Config.Image}}')"
ACTUAL_IMAGE_ID="$(docker inspect sihsalus-backend --format '{{.Image}}')"
ACTUAL_REVISION="$(docker image inspect "$ACTUAL_IMAGE_ID" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
if [ "$ACTUAL_IMAGE" != "$TARGET_IMAGE" ] || [ "$ACTUAL_IMAGE_ID" != "$TARGET_IMAGE_ID" ] || [ "$ACTUAL_REVISION" != "$TARGET_SHA" ]; then
  echo "[deploy-backend] deployed backend identity does not match the requested immutable image" >&2
  false
fi

write_env_value BACKEND_TAG "$TARGET_REFERENCE"
ROLLBACK_REQUIRED=false
trap - ERR HUP INT TERM
rm -f "$ENV_BACKUP"

echo "[deploy-backend] deployed ${TARGET_TAG} from ${TARGET_IMAGE}"
