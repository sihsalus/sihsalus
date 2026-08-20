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
SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEAN_CHECKOUT_HELPER="$SCRIPT_DIRECTORY/check-clean-checkout.sh"
EXTERNAL_VERIFIER="${DEPLOY_FRONTEND_EXTERNAL_VERIFIER_PATH:-$SCRIPT_DIRECTORY/verify-external-frontend.sh}"
EXTERNAL_BASE_URL="${FRONTEND_EXTERNAL_BASE_URL:-}"
EXTERNAL_ENVIRONMENT_LABEL="${FRONTEND_EXTERNAL_ENVIRONMENT_LABEL:-REMOTE}"
EXPECTED_CURRENT_SHA="${FRONTEND_CURRENT_SHA:-}"
EXPECTED_CURRENT_DIGEST="${FRONTEND_CURRENT_DIGEST:-}"
TRANSACTION_STATE_PATH="${FRONTEND_TRANSACTION_STATE_PATH:-}"
TRANSACTIONAL_EXTERNAL_VERIFY=false

if [[ ! "$TARGET_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "[deploy-frontend] invalid frontend SHA" >&2
  exit 2
fi

if [[ ! "$TARGET_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "[deploy-frontend] invalid frontend image digest" >&2
  exit 2
fi

if [ -n "$EXTERNAL_BASE_URL" ] || [ -n "$EXPECTED_CURRENT_SHA" ] || [ -n "$EXPECTED_CURRENT_DIGEST" ]; then
  TRANSACTIONAL_EXTERNAL_VERIFY=true
  if [[ ! "$EXTERNAL_BASE_URL" =~ ^https://[^/?#]+$ ]]; then
    echo "[deploy-frontend] FRONTEND_EXTERNAL_BASE_URL must be an HTTPS origin" >&2
    exit 2
  fi
  if [[ ! "$EXPECTED_CURRENT_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    echo "[deploy-frontend] FRONTEND_CURRENT_SHA is required for transactional external verification" >&2
    exit 2
  fi
  if [[ ! "$EXPECTED_CURRENT_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "[deploy-frontend] FRONTEND_CURRENT_DIGEST is required for transactional external verification" >&2
    exit 2
  fi
  if [ ! -x "$EXTERNAL_VERIFIER" ]; then
    echo "[deploy-frontend] external frontend verifier is not executable" >&2
    exit 2
  fi
  if [[ ! "$TRANSACTION_STATE_PATH" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
    echo "[deploy-frontend] FRONTEND_TRANSACTION_STATE_PATH must be an absolute path" >&2
    exit 2
  fi
fi

for command in docker git awk cat chmod cp df mktemp mv rm seq sleep; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "[deploy-frontend] missing command: $command" >&2
    exit 2
  }
done

if [ ! -f docker-compose.yml ] || [ ! -f .env ]; then
  echo "[deploy-frontend] run from the sihsalus repository root" >&2
  exit 2
fi

# Disk preflight: on 2026-08-17 QLTY ran out of space mid layer-extraction and
# every cron retry failed with a cryptic docker error. Fail fast, before any
# fetch or pull, with an actionable message. Assumes the Docker data-root
# shares the filesystem with this checkout (single LV on these hosts).
MINIMUM_FREE_DISK_MIB="${DEPLOY_MINIMUM_FREE_DISK_MIB:-4096}"
available_disk_mib="$(df -Pm . | awk 'NR == 2 { print $4 }')"
if [ "${available_disk_mib:-0}" -lt "$MINIMUM_FREE_DISK_MIB" ]; then
  echo "[deploy-frontend] insufficient disk space: ${available_disk_mib} MiB free, ${MINIMUM_FREE_DISK_MIB} MiB required; free space (e.g. docker builder prune -f) and retry" >&2
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

container_node_id() {
  docker inspect sihsalus-frontend \
    --format '{{index .Config.Labels "org.sihsalus.node-id"}}' \
    2>/dev/null || true
}

container_source_digest() {
  docker inspect sihsalus-frontend \
    --format '{{index .Config.Labels "org.sihsalus.frontend.source-digest"}}' \
    2>/dev/null || true
}

write_transaction_state() {
  local state="$1"
  local temporary_state

  if [ "$TRANSACTIONAL_EXTERNAL_VERIFY" != true ]; then
    return 0
  fi

  temporary_state="$(mktemp "${TRANSACTION_STATE_PATH}.tmp.XXXXXX")"
  printf '%s\n' "$state" >"$temporary_state"
  chmod 600 "$temporary_state"
  mv -f "$temporary_state" "$TRANSACTION_STATE_PATH"
}

wait_for_frontend_health() {
  local health

  for _ in $(seq 1 36); do
    health="$(container_health)"
    case "$health" in
      healthy)
        return 0
        ;;
      unhealthy | exited | dead)
        echo "[deploy-frontend] frontend entered state: $health" >&2
        return 1
        ;;
    esac
    sleep 5
  done

  echo "[deploy-frontend] frontend did not become healthy before timeout" >&2
  return 1
}

# La identidad del nodo ya vive en .env desde el primer despliegue; el script la
# reescribe alli al terminar. Leer solo el entorno obligaba a reexportarla a mano
# en cada despliegue manual y abortaba con el UUID correcto delante, en el .env.
# No se puede omitir: sin un UUID valido el compose cae a "unconfigured" y la
# verificacion externa lo rechaza, asi que se exige igual, solo que ahora tambien
# se acepta el valor ya persistido.
NODE_ID="${SIHSALUS_NODE_ID:-}"
if [ -z "$NODE_ID" ]; then
  NODE_ID="$(read_env_value SIHSALUS_NODE_ID)"
fi
if [[ ! "$NODE_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  echo "[deploy-frontend] SIHSALUS_NODE_ID must be a lowercase UUID, in the environment or in .env" >&2
  exit 2
fi

if [ ! -r "$CLEAN_CHECKOUT_HELPER" ]; then
  echo "[deploy-frontend] clean-checkout helper is not readable" >&2
  exit 2
fi
bash "$CLEAN_CHECKOUT_HELPER" deploy-frontend

CURRENT_SHA="$(deployed_sha || true)"
CURRENT_SOURCE_IMAGE="$(read_env_value FRONTEND_SOURCE_IMAGE)"
CURRENT_SOURCE_DIGEST="$(read_env_value FRONTEND_SOURCE_DIGEST)"
CURRENT_SOURCE_TAG="$(read_env_value FRONTEND_SOURCE_TAG)"
CURRENT_RUNTIME_TAG="$(read_env_value FRONTEND_RUNTIME_TAG)"
CURRENT_NODE_ID="$(container_node_id)"
CURRENT_CONTAINER_SOURCE_DIGEST="$(container_source_digest)"
CURRENT_HEALTH="$(container_health)"
CURRENT_IMAGE="$(container_image)"
RUNTIME_IMAGE_REPOSITORY="$(read_env_value FRONTEND_RUNTIME_IMAGE)"
RUNTIME_IMAGE_REPOSITORY="${RUNTIME_IMAGE_REPOSITORY:-sihsalus-frontend-runtime}"
TARGET_RUNTIME_IMAGE="${RUNTIME_IMAGE_REPOSITORY}:${RUNTIME_TAG}"

verify_external_release() {
  local expected_sha="$1"
  local expected_digest="$2"
  local label="$3"

  "$EXTERNAL_VERIFIER" \
    "$EXTERNAL_BASE_URL" \
    "$expected_sha" \
    "$expected_digest" \
    "$NODE_ID" \
    "$label"
}

verify_current_release_preflight() {
  if ! verify_external_release "$EXPECTED_CURRENT_SHA" "$EXPECTED_CURRENT_DIGEST" "${EXTERNAL_ENVIRONMENT_LABEL}-PREFLIGHT"; then
    echo "[deploy-frontend] current public release failed exact SHA, digest, and node preflight" >&2
    return 1
  fi
}

prune_repository_images_except() {
  local repository="$1"
  local active_image="$2"
  local active_image_id
  local image_id

  if ! active_image_id="$(docker image inspect "$active_image" --format '{{.Id}}' 2>/dev/null)"; then
    echo "[deploy-frontend] warning: cannot resolve active image ${active_image}; skipping ${repository} cleanup" >&2
    return 0
  fi

  while IFS= read -r image_id; do
    if [ -z "$image_id" ] || [ "$image_id" = "$active_image_id" ]; then
      continue
    fi

    if docker image rm "$image_id"; then
      echo "[deploy-frontend] removed stale frontend image ${image_id}"
    else
      echo "[deploy-frontend] warning: could not remove stale frontend image ${image_id}" >&2
    fi
  done < <(docker image ls "$repository" --quiet --no-trunc | awk 'NF && !seen[$0]++')
}

prune_stale_frontend_images() {
  # Never run a global prune on a shared clinical host. Restrict cleanup to
  # the two frontend repositories and preserve the exact active source and
  # runtime images required by the healthy container.
  prune_repository_images_except "$SOURCE_REPOSITORY" "$SOURCE_IMAGE"
  prune_repository_images_except "$RUNTIME_IMAGE_REPOSITORY" "$TARGET_RUNTIME_IMAGE"
}

ENV_BACKUP="$(mktemp)"
cp -p .env "$ENV_BACKUP"
ROLLBACK_REQUIRED=true
FRONTEND_RECREATE_ATTEMPTED=false
TRANSACTION_COMMITTED=false

rollback() {
  local exit_code="${1:-$?}"
  local rollback_failed=false
  trap - ERR HUP INT TERM

  if [ "$TRANSACTION_COMMITTED" = true ]; then
    rm -f "$ENV_BACKUP" || true
    echo "[deploy-frontend] committed transaction received a late failure or signal; the verified release remains active" >&2
    exit 0
  fi

  if [ "$ROLLBACK_REQUIRED" = true ]; then
    echo "[deploy-frontend] deployment failed; restoring previous frontend configuration" >&2
    cp -p "$ENV_BACKUP" .env
    if [ "$FRONTEND_RECREATE_ATTEMPTED" = true ]; then
      echo "[deploy-frontend] restoring previous frontend container" >&2
      if ! docker compose up -d --no-deps --no-build --pull never --force-recreate frontend; then
        echo "[deploy-frontend] previous frontend container could not be recreated" >&2
        rollback_failed=true
      elif ! wait_for_frontend_health; then
        echo "[deploy-frontend] previous frontend container did not recover health" >&2
        rollback_failed=true
      fi
    fi
    if [ "$FRONTEND_RECREATE_ATTEMPTED" = true ] &&
      [ "$TRANSACTIONAL_EXTERNAL_VERIFY" = true ] &&
      ! verify_current_release_preflight; then
      echo "[deploy-frontend] previous release could not be verified after rollback" >&2
      rollback_failed=true
    fi
  fi

  rm -f "$ENV_BACKUP" || true
  if [ "$rollback_failed" = true ]; then
    write_transaction_state rollback-failed || true
    echo "[deploy-frontend] rollback verification failed; immediate operator intervention is required" >&2
  elif [ "$FRONTEND_RECREATE_ATTEMPTED" = true ]; then
    if ! write_transaction_state rolled-back; then
      echo "[deploy-frontend] rollback completed but its terminal state could not be persisted" >&2
    fi
  else
    if ! write_transaction_state unchanged; then
      echo "[deploy-frontend] frontend was unchanged but its terminal state could not be persisted" >&2
    fi
  fi
  exit "$exit_code"
}

commit_transaction() {
  # Ignore termination only across this short critical section. A signal before
  # it rolls back; a signal after it observes the durable committed marker and
  # exits successfully without reverting a publicly verified release.
  trap '' HUP INT TERM
  write_transaction_state committed
  TRANSACTION_COMMITTED=true
  ROLLBACK_REQUIRED=false
  trap 'rollback 129' HUP
  trap 'rollback 130' INT
  trap 'rollback 143' TERM
}

trap 'rollback $?' ERR
trap 'rollback 129' HUP
trap 'rollback 130' INT
trap 'rollback 143' TERM

write_transaction_state active

if [ "$TRANSACTIONAL_EXTERNAL_VERIFY" = true ]; then
  verify_current_release_preflight
fi

if [ "$CURRENT_SHA" = "$TARGET_SHA" ] &&
  [ "$CURRENT_SOURCE_IMAGE" = "$SOURCE_IMAGE" ] &&
  [ "$CURRENT_SOURCE_DIGEST" = "$TARGET_DIGEST" ] &&
  [ "$CURRENT_SOURCE_TAG" = "$SOURCE_TAG" ] &&
  [ "$CURRENT_RUNTIME_TAG" = "$RUNTIME_TAG" ] &&
  [ "$CURRENT_NODE_ID" = "$NODE_ID" ] &&
  [ "$CURRENT_CONTAINER_SOURCE_DIGEST" = "$TARGET_DIGEST" ] &&
  [ "$CURRENT_IMAGE" = "$TARGET_RUNTIME_IMAGE" ] &&
  [ "$CURRENT_HEALTH" = "healthy" ]; then
  if [ "$TRANSACTIONAL_EXTERNAL_VERIFY" = true ]; then
    verify_external_release "$TARGET_SHA" "$TARGET_DIGEST" "$EXTERNAL_ENVIRONMENT_LABEL"
  fi
  commit_transaction
  rm -f "$ENV_BACKUP" || true
  prune_stale_frontend_images
  echo "[deploy-frontend] ${SOURCE_TAG} at ${TARGET_DIGEST} is already healthy; nothing to do"
  exit 0
fi

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
write_env_value FRONTEND_SOURCE_DIGEST "$TARGET_DIGEST"
write_env_value FRONTEND_SOURCE_TAG "$SOURCE_TAG"
write_env_value FRONTEND_RUNTIME_TAG "$RUNTIME_TAG"
write_env_value SIHSALUS_NODE_ID "$NODE_ID"

docker compose config --quiet

echo "[deploy-frontend] building runtime wrapper"
docker compose build --pull frontend

echo "[deploy-frontend] recreating frontend only"
FRONTEND_RECREATE_ATTEMPTED=true
docker compose up -d --no-deps --no-build --pull never --force-recreate frontend

wait_for_frontend_health

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

ACTUAL_NODE_ID="$(container_node_id)"
if [ "$ACTUAL_NODE_ID" != "$NODE_ID" ]; then
  echo "[deploy-frontend] deployed wrapper does not contain the expected node identity" >&2
  false
fi

ACTUAL_SOURCE_DIGEST="$(container_source_digest)"
if [ "$ACTUAL_SOURCE_DIGEST" != "$TARGET_DIGEST" ]; then
  echo "[deploy-frontend] deployed wrapper does not contain the expected source digest" >&2
  false
fi

if [ "$TRANSACTIONAL_EXTERNAL_VERIFY" = true ]; then
  echo "[deploy-frontend] verifying the exact public release before committing the transaction"
  verify_external_release "$TARGET_SHA" "$TARGET_DIGEST" "$EXTERNAL_ENVIRONMENT_LABEL"
fi

commit_transaction
if ! rm -f "$ENV_BACKUP"; then
  echo "[deploy-frontend] warning: could not remove the local transaction backup" >&2
fi

prune_stale_frontend_images

echo "[deploy-frontend] deployed ${SOURCE_TAG} from ${SOURCE_IMAGE}"
trap - ERR HUP INT TERM
