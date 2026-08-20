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
fi

for command in docker git awk cat cp df mktemp rm seq sleep; do
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

verify_remote_bootstrap_identity() {
  local expected_sha="$1"
  local expected_digest="$2"
  local expected_source_image="${SOURCE_REPOSITORY}@${expected_digest}"
  local actual_sha
  local actual_source_digest
  local actual_source_image
  local actual_source_tag
  local actual_runtime_tag
  local actual_node_id
  local actual_health
  local actual_image
  local expected_runtime_image
  local source_revision
  local source_repo_digests

  actual_sha="$(deployed_sha || true)"
  actual_source_image="$(read_env_value FRONTEND_SOURCE_IMAGE)"
  actual_source_digest="$(read_env_value FRONTEND_SOURCE_DIGEST)"
  actual_source_tag="$(read_env_value FRONTEND_SOURCE_TAG)"
  actual_runtime_tag="$(read_env_value FRONTEND_RUNTIME_TAG)"
  actual_node_id="$(container_node_id)"
  actual_health="$(container_health)"
  actual_image="$(container_image)"
  expected_runtime_image="${RUNTIME_IMAGE_REPOSITORY}:${actual_runtime_tag}"

  if [ "$actual_sha" != "$expected_sha" ] ||
    [ "$actual_source_image" != "$expected_source_image" ] ||
    [ "$actual_source_tag" != "sha-${expected_sha}" ] ||
    [ "$actual_node_id" != "$NODE_ID" ] ||
    [ "$actual_health" != healthy ] ||
    [ "$actual_image" != "$expected_runtime_image" ]; then
    echo "[deploy-frontend] current remote frontend does not match the declared bootstrap SHA, digest, node, health, and runtime configuration" >&2
    return 1
  fi

  if [ -n "$actual_source_digest" ] && [ "$actual_source_digest" != "$expected_digest" ]; then
    echo "[deploy-frontend] current remote FRONTEND_SOURCE_DIGEST conflicts with the declared digest" >&2
    return 1
  fi

  source_revision="$(
    docker image inspect "$expected_source_image" \
      --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null || true
  )"
  source_repo_digests="$(
    docker image inspect "$expected_source_image" \
      --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null || true
  )"
  if [ "$source_revision" != "$expected_sha" ] ||
    ! grep -Fxq "$expected_source_image" <<<"$source_repo_digests"; then
    echo "[deploy-frontend] current remote source image does not prove the declared SHA and digest" >&2
    return 1
  fi

  echo "[deploy-frontend] exact remote bootstrap evidence matches SHA ${expected_sha}, digest ${expected_digest}, and node ${NODE_ID}"
}

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
  local verify_code

  if verify_external_release "$EXPECTED_CURRENT_SHA" "$EXPECTED_CURRENT_DIGEST" "${EXTERNAL_ENVIRONMENT_LABEL}-PREFLIGHT"; then
    return 0
  else
    verify_code="$?"
  fi

  if [ "$verify_code" -ne 3 ]; then
    echo "[deploy-frontend] current public release failed exact external preflight" >&2
    return "$verify_code"
  fi

  echo "[deploy-frontend] current release predates the digest header; requiring exact remote bootstrap evidence"
  verify_remote_bootstrap_identity "$EXPECTED_CURRENT_SHA" "$EXPECTED_CURRENT_DIGEST"
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
  prune_stale_frontend_images
  echo "[deploy-frontend] ${SOURCE_TAG} at ${TARGET_DIGEST} is already healthy; nothing to do"
  exit 0
fi

ENV_BACKUP="$(mktemp)"
cp -p .env "$ENV_BACKUP"
ROLLBACK_REQUIRED=true
FRONTEND_RECREATE_ATTEMPTED=false

rollback() {
  local exit_code="${1:-$?}"
  local rollback_failed=false
  trap - ERR HUP INT TERM

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
    echo "[deploy-frontend] rollback verification failed; immediate operator intervention is required" >&2
  fi
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

ROLLBACK_REQUIRED=false
trap - ERR HUP INT TERM
if ! rm -f "$ENV_BACKUP"; then
  echo "[deploy-frontend] warning: could not remove the local transaction backup" >&2
fi

prune_stale_frontend_images

echo "[deploy-frontend] deployed ${SOURCE_TAG} from ${SOURCE_IMAGE}"
