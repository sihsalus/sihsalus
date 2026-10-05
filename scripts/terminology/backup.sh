#!/usr/bin/env bash
# Capture PostgreSQL, uploads, objects and private deployment metadata together.
set -euo pipefail
umask 077
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${1:?Usage: backup.sh /absolute/private.env /absolute/backup-directory}"
BACKUP_DIR="${2:?Backup directory required}"
[[ "$ENV_FILE" = /* && "$BACKUP_DIR" = /* ]] || exit 2
cd "$ROOT_DIR"
source scripts/deploy/env.sh
[[ "$(cat /etc/machine-id)" == "$(read_env_value TERMINOLOGY_MACHINE_ID "$ENV_FILE")" ]]
[[ -f "$BACKUP_DIR/recovery.key" && "$(stat -c '%a' "$BACKUP_DIR/recovery.key")" == 600 ]]
[[ "$(df -Pk "$BACKUP_DIR" | awk 'NR==2 {print $4}')" -ge 10485760 ]]
KEEP_COPIES="$(read_env_value TERMINOLOGY_BACKUP_KEEP "$ENV_FILE")"
KEEP_COPIES="${KEEP_COPIES:-14}"
[[ "$KEEP_COPIES" =~ ^[0-9]+$ && "$KEEP_COPIES" -ge 2 ]]
COMPOSE=(docker compose --env-file "$ENV_FILE" -f docker-compose.terminology.yml)
"${COMPOSE[@]}" config --quiet

busy="$("${COMPOSE[@]}" exec -T db psql -U postgres -d postgres -Atc \
  "SELECT count(*) FROM celery_tasks WHERE state IN ('PENDING','STARTED','RETRY')")"
[[ "$busy" == 0 ]] || { echo 'Backup deferred: background tasks are still active.' >&2; exit 75; }
STAGE="$(mktemp -d "$BACKUP_DIR/.runtime-stage-XXXXXXXX")"
OUTPUT="$BACKUP_DIR/runtime-$(date -u +%Y%m%dT%H%M%SZ).tar.enc"
stopped=false
resume() {
  result=$?
  trap - EXIT
  if [[ "$stopped" == true ]]; then
    "${COMPOSE[@]}" start storage || result=1
    "${COMPOSE[@]}" start --wait --wait-timeout 180 api worker importer scheduler web || result=1
  fi
  if [[ "$result" == 0 ]]; then
    rm -rf -- "$STAGE"
    printf 'Backup completed: %s\n' "$OUTPUT"
  else
    printf 'Backup failed; recovery files retained in %s\n' "$STAGE" >&2
  fi
  exit "$result"
}
trap resume EXIT
stopped=true
"${COMPOSE[@]}" stop scheduler web api importer worker
# A request may have queued work between the initial check and stopping the API.
busy="$("${COMPOSE[@]}" exec -T db psql -U postgres -d postgres -Atc \
  "SELECT count(*) FROM celery_tasks WHERE state IN ('PENDING','STARTED','RETRY')")"
[[ "$busy" == 0 ]] || { echo 'Backup deferred: work arrived before quiescence.' >&2; exit 75; }
cp "$ENV_FILE" "$STAGE/deployment.env"
git rev-parse HEAD > "$STAGE/distribution-commit"
"${COMPOSE[@]}" images --format json > "$STAGE/images.json"
"${COMPOSE[@]}" exec -T db pg_dump -U postgres -Fc postgres > "$STAGE/database.dump"
"${COMPOSE[@]}" exec -T db pg_restore --list < "$STAGE/database.dump" > /dev/null
"${COMPOSE[@]}" stop storage
for volume in uploads objects; do
  name="$("${COMPOSE[@]}" config --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["volumes"][sys.argv[1]]["name"])' "$volume")"
  path="$(docker volume inspect --format '{{.Mountpoint}}' "$name")"
  [[ "$path" == /var/lib/docker/volumes/sihsalus-terminology_*/* ]]
  sudo -n tar -C "$path" -cf - . | gzip -1 > "$STAGE/$volume.tar.gz"
done
tar -C "$STAGE" -cf - . | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
  -pass "file:$BACKUP_DIR/recovery.key" -out "$OUTPUT.partial"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass "file:$BACKUP_DIR/recovery.key" \
  -in "$OUTPUT.partial" | tar -tf - > /dev/null
mv "$OUTPUT.partial" "$OUTPUT"
sha256sum "$OUTPUT" > "$OUTPUT.sha256"
python3 - "$BACKUP_DIR" "$KEEP_COPIES" <<'PY'
from pathlib import Path
import re
import sys
directory = Path(sys.argv[1])
backups = sorted(path for path in directory.iterdir()
                 if re.fullmatch(r'runtime-[0-9]{8}T[0-9]{6}Z\.tar\.enc', path.name)
                 and path.is_file() and not path.is_symlink())
for old in backups[:-int(sys.argv[2])]:
    old.unlink()
    old.with_name(old.name + '.sha256').unlink(missing_ok=True)
PY
