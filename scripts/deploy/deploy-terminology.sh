#!/usr/bin/env bash
# Deploy only the dedicated terminology stack using prebuilt, verified images.
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${1:?Usage: deploy-terminology.sh /absolute/private.env [bootstrap|update] [/absolute/backup-directory]}"
MODE="${2:-update}"
BACKUP_DIR="${3:-}"
[[ "$ENV_FILE" = /* && -f "$ENV_FILE" ]] || { echo 'An absolute private env file is required.' >&2; exit 1; }
[[ "$MODE" == bootstrap || "$MODE" == update ]] || exit 2
[[ "$MODE" == bootstrap || ( "$BACKUP_DIR" = /* && -d "$BACKUP_DIR" ) ]] || {
  echo 'Updates require an absolute backup directory with recovery.key.' >&2; exit 2;
}
cd "$ROOT_DIR"
# shellcheck source=env.sh
source "$ROOT_DIR/scripts/deploy/env.sh"

fail() { printf 'Terminology deployment stopped: %s\n' "$*" >&2; exit 1; }
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || fail 'checkout has tracked changes'
EXPECTED_NODE="$(read_env_value TERMINOLOGY_MACHINE_ID "$ENV_FILE")"
[[ "$EXPECTED_NODE" =~ ^[0-9a-f]{32}$ ]] || fail 'missing expected machine ID'
[[ "$(cat /etc/machine-id)" == "$EXPECTED_NODE" ]] || fail 'target machine ID differs'
SOURCE_SHA="$(read_env_value TERMINOLOGY_SOURCE_SHA "$ENV_FILE")"
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail 'missing source commit'
[[ "$(uname -m)" == x86_64 ]] || fail 'candidate images target linux/amd64'
[[ "$(stat -c '%a' "$ENV_FILE")" == 600 ]] || fail 'env file must have mode 600'
[[ "$(df -Pk / | awk 'NR==2 {print $4}')" -ge 10485760 ]] || fail 'less than 10 GiB disk headroom'
[[ "$(awk '/MemTotal:/ {print $2}' /proc/meminfo)" -ge 7340032 ]] || fail 'less than 7 GiB host memory'
[[ "$(sysctl -n vm.max_map_count)" -ge 262144 ]] || fail 'vm.max_map_count is too small'
docker context show
timeout 15 docker info >/dev/null
[[ "$(docker info --format '{{.CgroupDriver}}')" == systemd ]] || fail 'systemd cgroup driver is required'
[[ "$(systemctl show -p MemoryMax --value sihsalus-terminology.slice)" == 5368709120 ]] \
  || fail 'install and start terminology/sihsalus-terminology.slice before deploying'

COMPOSE=(docker compose --parallel 1 --env-file "$ENV_FILE" -f docker-compose.terminology.yml)
"${COMPOSE[@]}" config --quiet
MAIL_BACKEND="$(read_env_value TERMINOLOGY_EMAIL_BACKEND "$ENV_FILE")"
case "${MAIL_BACKEND:-django.core.mail.backends.dummy.EmailBackend}" in
  django.core.mail.backends.dummy.EmailBackend) ;;
  django.core.mail.backends.smtp.EmailBackend)
    for key in EMAIL_HOST_USER EMAIL_HOST_PASSWORD DEFAULT_FROM_EMAIL COMMUNITY_EMAIL REPORTS_EMAIL; do
      [[ -n "$(read_env_value "TERMINOLOGY_$key" "$ENV_FILE")" ]] || fail "missing SMTP setting: TERMINOLOGY_$key"
    done
    ;;
  *) fail 'unsupported email backend; choose dummy or authenticated SMTP' ;;
esac
for app in API WEB POSTGRES REDIS ELASTICSEARCH; do
  ref="$(read_env_value "TERMINOLOGY_${app}_IMAGE" "$ENV_FILE")"
  [[ "$ref" =~ ^ghcr\.io/sihsalus/terminology-${app,,}@sha256:[0-9a-f]{64}$ ]] || fail 'image must use the expected repository and a verified digest'
done

STATE_DIR="$ROOT_DIR/.env.terminology-state/$(date -u +%Y%m%dT%H%M%SZ)"
ACTIVE_ENV="$ROOT_DIR/.env.terminology-state/active.env"
mkdir -p "$STATE_DIR"
cp "$ENV_FILE" "$STATE_DIR/target.env"
git rev-parse HEAD > "$STATE_DIR/distro-commit"
"${COMPOSE[@]}" images --format json > "$STATE_DIR/previous-images.json"

"${COMPOSE[@]}" pull
for app in API WEB POSTGRES REDIS ELASTICSEARCH; do
  ref="$(read_env_value "TERMINOLOGY_${app}_IMAGE" "$ENV_FILE")"
  revision="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$ref")"
  [[ "$revision" == "$SOURCE_SHA" ]] || fail 'candidate revision differs from requested source commit'
done
[[ "$(df -Pk / | awk 'NR==2 {print $4}')" -ge 10485760 ]] || fail 'pull left less than 10 GiB disk headroom'

if [[ "$MODE" == bootstrap ]]; then
  [[ -z "$("${COMPOSE[@]}" ps -aq api)" ]] || fail 'bootstrap cannot reset an existing application'
  "${COMPOSE[@]}" up -d --wait --wait-timeout 300 db redis es storage
  "${COMPOSE[@]}" --profile maintenance run --rm --no-deps bootstrap
  # Create explicit mappings before queued indexing tasks can auto-create indexes.
  "${COMPOSE[@]}" --profile maintenance run --rm --no-deps bootstrap python manage.py search_index --create
else
  [[ -f "$ACTIVE_ENV" ]] || fail 'missing configuration of the currently running deployment'
  [[ "$(read_env_value TERMINOLOGY_MACHINE_ID "$ACTIVE_ENV")" == "$EXPECTED_NODE" ]] || fail 'previous deployment belongs to a different node'
  cp "$ACTIVE_ENV" "$STATE_DIR/previous.env"
  bash scripts/terminology/backup.sh "$ACTIVE_ENV" "$BACKUP_DIR" leave-stopped > "$STATE_DIR/backup.log" 2>&1
  "${COMPOSE[@]}" stop scheduler web api importer worker
  "${COMPOSE[@]}" up -d --wait --wait-timeout 300 db redis es storage
  "${COMPOSE[@]}" --profile maintenance run --rm --no-deps bootstrap \
    python manage.py migrate --plan > "$STATE_DIR/migration-plan.log" 2>&1
  # Updates run migrations only: fixtures and setup_superuser would reset managed data.
  "${COMPOSE[@]}" --profile maintenance run --rm --no-deps bootstrap python manage.py migrate
fi

"${COMPOSE[@]}" up -d --no-deps --wait --wait-timeout 180 api
"${COMPOSE[@]}" up -d --no-deps worker importer scheduler
"${COMPOSE[@]}" up -d --no-deps --wait --wait-timeout 60 web
"${COMPOSE[@]}" ps
cp "$ENV_FILE" "$ACTIVE_ENV"
cp "$STATE_DIR/distro-commit" "$ROOT_DIR/.env.terminology-state/active-distro-commit"
printf 'Runtime started. Complete authenticated functional checks before accepting this deployment.\n'
