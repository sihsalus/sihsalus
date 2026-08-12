#!/usr/bin/env bash

set -Eeuo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <40-character backend git SHA> <sha256 image digest>" >&2
  exit 2
fi

TARGET_BACKEND_SHA="$1"
TARGET_BACKEND_DIGEST="$2"
TARGET_BACKEND_TAG="sha-${TARGET_BACKEND_SHA}"
BACKEND_REPOSITORY="ghcr.io/sihsalus/sihsalus-backend"
TARGET_BACKEND_REFERENCE="${TARGET_BACKEND_TAG}@${TARGET_BACKEND_DIGEST}"
EXPECTED_BACKEND_IMAGE="${BACKEND_REPOSITORY}:${TARGET_BACKEND_REFERENCE}"
SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEAN_CHECKOUT_HELPER="$SCRIPT_DIRECTORY/check-clean-checkout.sh"

if [[ ! "$TARGET_BACKEND_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "[redeploy-environment] invalid backend SHA" >&2
  exit 2
fi

if [[ ! "$TARGET_BACKEND_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "[redeploy-environment] invalid backend image digest" >&2
  exit 2
fi

REDEPLOY_OFFLINE="${REDEPLOY_OFFLINE:-false}"
case "$REDEPLOY_OFFLINE" in
  true | false)
    ;;
  *)
    echo "[redeploy-environment] REDEPLOY_OFFLINE must be true or false" >&2
    exit 2
    ;;
esac

for command in docker git awk chmod mktemp mv rm grep head seq sleep; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "[redeploy-environment] missing command: $command" >&2
    exit 2
  }
done

if [ ! -f docker-compose.yml ] || [ ! -f .env ]; then
  echo "[redeploy-environment] run from the sihsalus repository root" >&2
  exit 2
fi

NODE_ID="${SIHSALUS_NODE_ID:-}"
if [[ ! "$NODE_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  echo "[redeploy-environment] SIHSALUS_NODE_ID is required and must be a lowercase UUID" >&2
  exit 2
fi

write_env_value() {
  local key="$1"
  local value="$2"
  local temporary_file
  temporary_file="$(mktemp ./.env.redeploy.XXXXXX)"

  if ! awk -v key="$key" -v value="$value" '
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
  ' .env >"$temporary_file"; then
    rm -f "$temporary_file"
    return 1
  fi

  if ! chmod --reference=.env "$temporary_file" || ! mv -f "$temporary_file" .env; then
    rm -f "$temporary_file"
    return 1
  fi
}

if [ ! -r "$CLEAN_CHECKOUT_HELPER" ]; then
  echo "[redeploy-environment] clean-checkout helper is not readable" >&2
  exit 2
fi
bash "$CLEAN_CHECKOUT_HELPER" redeploy-environment

diagnose_failure() {
  local exit_code="${1:-$?}"
  trap - ERR HUP INT TERM
  echo "[redeploy-environment] redeploy failed; current container state follows" >&2
  docker compose ps --all >&2 || true
  exit "$exit_code"
}

trap 'diagnose_failure $?' ERR
trap 'diagnose_failure 129' HUP
trap 'diagnose_failure 130' INT
trap 'diagnose_failure 143' TERM

service_is_active() {
  local service="$1"
  grep -Fxq "$service" <<<"$ACTIVE_SERVICES"
}

service_allows_successful_exit() {
  case "$1" in
    backend-oauth2-config | certbot | loki-init)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

container_health() {
  local container="$1"
  docker inspect "$container" \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
    2>/dev/null || true
}

wait_for_container_health() {
  local container="$1"
  local timeout_seconds="$2"
  local elapsed=0
  local health

  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    health="$(container_health "$container")"
    case "$health" in
      healthy | running)
        echo "[redeploy-environment] ${container} is ${health}"
        return 0
        ;;
      unhealthy | exited | dead)
        echo "[redeploy-environment] ${container} entered state: ${health}" >&2
        return 1
        ;;
    esac
    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo "[redeploy-environment] ${container} did not become healthy within ${timeout_seconds}s" >&2
  return 1
}

wait_for_openmrs() {
  local timeout_seconds="$1"
  local elapsed=0
  local health

  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    if docker exec sihsalus-backend \
      curl --fail --silent --show-error --max-time 10 \
      http://127.0.0.1:8080/openmrs/health/started >/dev/null 2>&1; then
      echo "[redeploy-environment] OpenMRS reports started"
      return 0
    fi

    health="$(container_health sihsalus-backend)"
    case "$health" in
      unhealthy | exited | dead)
        echo "[redeploy-environment] OpenMRS entered state: ${health}" >&2
        return 1
        ;;
    esac

    if [ $((elapsed % 60)) -eq 0 ]; then
      echo "[redeploy-environment] waiting for OpenMRS (${elapsed}s/${timeout_seconds}s)"
    fi
    sleep 15
    elapsed=$((elapsed + 15))
  done

  echo "[redeploy-environment] OpenMRS did not report started within ${timeout_seconds}s" >&2
  return 1
}

wait_for_active_services() {
  local timeout_seconds="$1"
  local elapsed=0
  local service
  local container_id
  local state
  local health
  local exit_code
  local pending

  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    pending=false

    while IFS= read -r service; do
      [ -n "$service" ] || continue
      container_id="$(docker compose ps --all --quiet "$service" | head -n 1)"
      if [ -z "$container_id" ]; then
        pending=true
        continue
      fi

      state="$(docker inspect "$container_id" --format '{{.State.Status}}')"
      health="$(docker inspect "$container_id" --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}')"
      exit_code="$(docker inspect "$container_id" --format '{{.State.ExitCode}}')"

      if service_allows_successful_exit "$service" &&
        [ "$state" = "exited" ] &&
        [ "$exit_code" = "0" ]; then
        continue
      fi
      case "$state" in
        running)
          if [ -n "$health" ] && [ "$health" != "healthy" ]; then
            pending=true
          fi
          ;;
        created | restarting)
          pending=true
          ;;
        *)
          echo "[redeploy-environment] ${service} is ${state} (exit ${exit_code})" >&2
          return 1
          ;;
      esac
    done <<<"$ACTIVE_SERVICES"

    if [ "$pending" = false ]; then
      echo "[redeploy-environment] every active service is ready"
      return 0
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo "[redeploy-environment] active services did not become ready within ${timeout_seconds}s" >&2
  return 1
}

resolve_fua_database_volume_name() {
  docker compose config |
    awk '
      $0 == "volumes:" {
        in_volumes = 1
        next
      }
      in_volumes && $0 == "  db-fua-generator:" {
        in_target_volume = 1
        next
      }
      in_target_volume && $1 == "name:" {
        print $2
        in_target_volume = 0
        next
      }
      in_target_volume && $0 ~ /^  [^[:space:]][^:]*:/ {
        in_target_volume = 0
      }
      in_volumes && $0 ~ /^[^[:space:]]/ {
        in_volumes = 0
      }
    '
}

preflight_fua_database_authentication() {
  local check_code
  local container_id
  local existing_volumes
  local state
  local volume_exists=false
  local volume_name

  if ! service_is_active fua-generator-db; then
    return 0
  fi

  if ! volume_name="$(resolve_fua_database_volume_name)" || [ -z "$volume_name" ]; then
    echo "[redeploy-environment] could not resolve the FUA database volume from the active Compose configuration; refusing to recreate services" >&2
    return 1
  fi

  if ! existing_volumes="$(docker volume ls --quiet 2>/dev/null)"; then
    echo "[redeploy-environment] could not inspect Docker volumes before the FUA authentication check; refusing to recreate services" >&2
    return 1
  fi
  if grep -Fxq "$volume_name" <<<"$existing_volumes"; then
    volume_exists=true
  fi

  if ! container_id="$(docker compose ps --all --quiet fua-generator-db 2>/dev/null | head -n 1)"; then
    echo "[redeploy-environment] could not inspect the FUA database container; refusing to recreate services" >&2
    return 1
  fi
  if [ -z "$container_id" ]; then
    if [ "$volume_exists" = false ]; then
      echo "[redeploy-environment] no existing FUA database volume or container; first-install authentication is delegated to its healthcheck"
      return 0
    fi

    echo "[redeploy-environment] the persistent FUA database volume exists without a database container; refusing to recreate services" >&2
    echo "[redeploy-environment] recover or start the database with the last known configuration, verify a backup, and retry; never delete the FUA volume" >&2
    return 1
  fi

  if [ "$volume_exists" = false ]; then
    echo "[redeploy-environment] a FUA database container exists without its configured persistent volume; refusing to recreate services" >&2
    return 1
  fi

  if ! state="$(docker inspect "$container_id" --format '{{.State.Status}}' 2>/dev/null)"; then
    echo "[redeploy-environment] could not inspect the FUA database state; refusing to recreate services" >&2
    return 1
  fi
  if [ "$state" != "running" ]; then
    echo "[redeploy-environment] the persistent FUA database exists but its container is ${state}; refusing to recreate services" >&2
    echo "[redeploy-environment] recover or start the database with the last known configuration, verify a backup, and retry; never delete the FUA volume" >&2
    return 1
  fi

  echo "[redeploy-environment] verifying configured FUA database identity against the existing volume"
  if docker compose run \
    --quiet \
    --rm \
    --no-deps \
    --pull never \
    --cap-drop ALL \
    --entrypoint node \
    fua-generator \
    - >/dev/null 2>&1 <<'NODE'
const { Client } = require('pg');

const IDENTITY_ERROR_CODES = new Set(['28000', '28P01', '3D000']);
const OPERATION_TIMEOUT_MS = 10000;
const HARD_TIMEOUT_MS = 15000;

async function authenticate() {
  const hardTimeout = setTimeout(() => process.exit(75), HARD_TIMEOUT_MS);
  const client = new Client({
    host: process.env.DB_HOST,
    port: Number(process.env.DB_PORT || '5432'),
    database: process.env.DB_NAME,
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    connectionTimeoutMillis: OPERATION_TIMEOUT_MS,
    query_timeout: OPERATION_TIMEOUT_MS,
  });

  try {
    await client.connect();
    await client.query('SELECT 1');
    await client.end();
    clearTimeout(hardTimeout);
  } catch (error) {
    try {
      client.end().catch(() => {});
    } catch {
      // The one-off process exits immediately below; cleanup is best-effort.
    }
    process.exit(IDENTITY_ERROR_CODES.has(error?.code) ? 78 : 75);
  }
}

authenticate();
NODE
  then
    echo "[redeploy-environment] configured FUA database identity authenticated successfully"
    return 0
  else
    check_code="$?"
  fi

  if [ "$check_code" -eq 75 ]; then
    echo "[redeploy-environment] the FUA authentication probe was inconclusive because the database was unavailable or timed out; refusing to recreate services" >&2
    echo "[redeploy-environment] verify database reachability and authenticated health, then retry" >&2
    return 1
  fi

  if [ "$check_code" -ne 78 ]; then
    echo "[redeploy-environment] isolated FUA authentication probe is unavailable; refusing to recreate services" >&2
    echo "[redeploy-environment] ensure the configured FUA image is present and the probe can run, then retry" >&2
    return 1
  fi

  echo "[redeploy-environment] configured FUA database identity could not authenticate; refusing to recreate services" >&2
  echo "[redeploy-environment] POSTGRES_PASSWORD initializes only an empty PostgreSQL volume; changing .env does not rotate the existing role" >&2
  echo "[redeploy-environment] restore the last valid credential, take a backup, then rotate the role in an audited maintenance procedure; never delete the FUA volume" >&2
  return 1
}
# End preflight_fua_database_authentication

if [ "$REDEPLOY_OFFLINE" = true ]; then
  echo "[redeploy-environment] offline mode: using the prevalidated local checkout and images"
else
  echo "[redeploy-environment] updating distro checkout"
  git fetch origin main
  git merge --ff-only origin/main
fi

# Override a stale server .env for every Compose operation. The same immutable
# reference is persisted only after the complete environment is healthy.
export BACKEND_TAG="$TARGET_BACKEND_REFERENCE"

docker compose config --quiet
ACTIVE_SERVICES="$(docker compose config --services)"

if service_is_active seed; then
  echo "[redeploy-environment] the destructive seed profile must not be active during a redeploy" >&2
  false
fi

echo "[redeploy-environment] active services"
printf '%s\n' "$ACTIVE_SERVICES"

if [ "$REDEPLOY_OFFLINE" = false ]; then
  echo "[redeploy-environment] pulling the configured classic OpenMRS backend"
  docker compose pull backend

  echo "[redeploy-environment] pulling registry images for active non-buildable services"
  docker compose pull --ignore-buildable --ignore-pull-failures
fi

preflight_fua_database_authentication

BACKEND_SOURCE_REVISION="$(
  docker image inspect "${BACKEND_REPOSITORY}@${TARGET_BACKEND_DIGEST}" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}'
)"
if [ "$BACKEND_SOURCE_REVISION" != "$TARGET_BACKEND_SHA" ]; then
  echo "[redeploy-environment] backend image revision does not match requested SHA" >&2
  false
fi

if [ "$REDEPLOY_OFFLINE" = false ]; then
  BUILD_SERVICES=(frontend gateway)
  for build_service in certbot keycloak; do
    if service_is_active "$build_service"; then
      BUILD_SERVICES+=("$build_service")
    fi
  done

  echo "[redeploy-environment] rebuilding local runtime services sequentially without cache: ${BUILD_SERVICES[*]}"
  for build_service in "${BUILD_SERVICES[@]}"; do
    echo "[redeploy-environment] rebuilding ${build_service}"
    docker compose build --pull --no-cache "$build_service"
  done
else
  echo "[redeploy-environment] offline mode: using prevalidated local runtime images without rebuilding"
fi

echo "[redeploy-environment] recreating every active service without deleting volumes"
docker compose up \
  --detach \
  --force-recreate \
  --remove-orphans \
  --no-build \
  --pull never

wait_for_container_health sihsalus-db-master 300
wait_for_container_health sihsalus-frontend 600
wait_for_openmrs 2400
wait_for_container_health sihsalus-backend 120
wait_for_container_health sihsalus-gateway 600

wait_for_active_services 600

BACKEND_IMAGE="$(docker inspect sihsalus-backend --format '{{.Config.Image}}')"
if [ "$BACKEND_IMAGE" != "$EXPECTED_BACKEND_IMAGE" ]; then
  echo "[redeploy-environment] backend image is not the requested immutable release: ${BACKEND_IMAGE}" >&2
  false
fi

BACKEND_IMAGE_ID="$(docker inspect sihsalus-backend --format '{{.Image}}')"
BACKEND_REVISION="$(
  docker image inspect "$BACKEND_IMAGE_ID" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}'
)"
if [ "$BACKEND_REVISION" != "$TARGET_BACKEND_SHA" ]; then
  echo "[redeploy-environment] deployed backend revision does not match requested SHA" >&2
  false
fi

FRONTEND_SHA="$(
  docker exec sihsalus-frontend wget -qO- http://127.0.0.1/build-info.json |
    awk -F'"' '/"gitSha"[[:space:]]*:/ { print $4; exit }'
)"
if [[ ! "$FRONTEND_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "[redeploy-environment] frontend build-info does not contain a valid SHA" >&2
  false
fi

FRONTEND_NODE_ID="$(docker inspect sihsalus-frontend --format '{{index .Config.Labels "org.sihsalus.node-id"}}')"
if [ "$FRONTEND_NODE_ID" != "$NODE_ID" ]; then
  echo "[redeploy-environment] frontend wrapper does not contain the expected node identity" >&2
  false
fi

write_env_value BACKEND_TAG "$TARGET_BACKEND_REFERENCE"
write_env_value SIHSALUS_NODE_ID "$NODE_ID"
echo "[redeploy-environment] persisted immutable backend reference"

trap - ERR HUP INT TERM
echo "[redeploy-environment] usable"
echo "[redeploy-environment] distro=$(git rev-parse HEAD)"
echo "[redeploy-environment] backend=${BACKEND_IMAGE}"
echo "[redeploy-environment] frontend=${FRONTEND_SHA}"
echo "[redeploy-environment] node=${FRONTEND_NODE_ID}"
docker compose ps
