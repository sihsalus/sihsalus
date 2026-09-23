#!/usr/bin/env bash
set -Eeuo pipefail

[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted && "${RUNNER_OS:-}" == Linux ]] || {
  echo 'Physical backup drill requires an ephemeral GitHub-hosted Linux runner' >&2; exit 2;
}
[[ -z "${DOCKER_HOST:-}" && -z "${DOCKER_CONTEXT:-}" ]] || exit 2
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
[[ "$(docker context show)" == default ]] || exit 2
docker info --format '{{.ServerVersion}}'
umask 077
STATE="$(mktemp -d "${RUNNER_TEMP:?}/physical-drill.XXXXXXXX")"
COMPOSE_PROJECT_NAME="physical-drill-$(openssl rand -hex 8)"
export COMPOSE_FILE="$ROOT/tests/backup/physical-compose.yml"
MYSQL_ROOT_PASSWORD="$(openssl rand -hex 24)"
BACKUP_ENCRYPTION_PASSWORD="$(openssl rand -hex 24)"
export COMPOSE_PROJECT_NAME MYSQL_ROOT_PASSWORD BACKUP_ENCRYPTION_PASSWORD
unset COMPOSE_PROFILES DB_VOLUME CONTAINER_NAME OMRS_DB_BACKUP_USER OMRS_DB_BACKUP_PASSWORD
DB_NAME="$COMPOSE_PROJECT_NAME-db"
DB_VOLUME="$COMPOSE_PROJECT_NAME"_data
SNAPSHOT="$DB_VOLUME-pre-restore"
STARTED=false
COLLISION_CREATED=false
STAGE=prepare
START_SECONDS=$SECONDS
BACKUP_SECONDS=0
RESTORE_SECONDS=0
ROLLBACK_SECONDS=0
ARCHIVE_SHA=unavailable
IMAGE_ID=unavailable
RESTORE_VERIFIED=false
ROLLBACK_VERIFIED=false

cleanup() {
  local result=$?
  trap - EXIT INT TERM
  if "$COLLISION_CREATED"; then docker rm -f sihsalus-db-restore >/dev/null 2>&1 || result=1; fi
  if "$STARTED"; then
    if [[ "$result" != 0 ]]; then
      timeout --kill-after=5s 20s docker compose logs --no-color --tail 40 db >"$STATE/database.log" 2>&1 || true
    fi
    timeout --kill-after=5s 90s docker compose down --volumes --remove-orphans >"$STATE/cleanup.log" 2>&1 || result=1
    if docker volume inspect "$SNAPSHOT" >/dev/null 2>&1; then
      docker volume rm "$SNAPSHOT" >/dev/null 2>&1 || result=1
    fi
    if [[ -n "$(docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME")" \
       || -n "$(docker volume ls -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME")" ]]; then result=1; fi
  fi
  if [[ "$result" != 0 ]]; then
    # Failure-only diagnostics from this synthetic fixture. Never print the
    # archive, SQL contents or Docker environment; redact generated passwords.
    python3 - "$STATE" <<'PY'
import os, re, sys
from pathlib import Path
for log in sorted(Path(sys.argv[1]).glob('*.log')):
    lines = log.read_text(errors='replace').splitlines()[-20:]
    text = '\n'.join(lines)
    for key in ('MYSQL_ROOT_PASSWORD', 'BACKUP_ENCRYPTION_PASSWORD'):
        text = text.replace(os.environ[key], '[REDACTED]')
    print(log.name + ':\n' + re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', text))
PY
  fi
  rm -rf -- "$STATE" || result=1
  {
    echo '## Physical backup restore drill'
    echo "Commit: $GITHUB_SHA"
    echo "Result: exit=$result; last stage=$STAGE"
    echo "MariaDB image ID: $IMAGE_ID"
    echo "Encrypted archive SHA-256: $ARCHIVE_SHA"
    echo "Elapsed seconds: backup=$BACKUP_SECONDS; restore=$RESTORE_SECONDS; rollback=$ROLLBACK_SECONDS; total=$((SECONDS-START_SECONDS))"
    echo "Checksum and exact-row verification: restore=$RESTORE_VERIFIED; snapshot rollback=$ROLLBACK_VERIFIED"
    echo 'Failure injection: this runner owns a conflicting copy-back container name. It prevents copy-back from starting after the destination is cleared; the existing snapshot recovery must restore the pre-attempt data.'
    echo 'This does not simulate a partially completed copy, disk loss, an OpenMRS restart or a production recovery.'
    echo 'Synthetic database only. No credentials, database contents, backups or raw logs are uploaded; failure diagnostics redact both generated passwords.'
  } >> "$GITHUB_STEP_SUMMARY"
  echo "Physical backup drill: stage=$STAGE exit=$result"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sql() {
  docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$DB_NAME" \
    mariadb --user=root --database=backup_drill --batch --skip-column-names "$@"
}
fingerprint() {
  sql --execute="CHECKSUM TABLE probe EXTENDED; SELECT id, value, COALESCE(optional_value, 'NULL') FROM probe ORDER BY id;"
}
wait_for_db() {
  timeout --kill-after=5s 130s docker compose up -d --no-recreate --wait --wait-timeout 120 >"$STATE/readiness.log" 2>&1
  sql --execute='SELECT 1' >/dev/null
}

# Fixed copy-back name belongs to the current operational script (#172 tracks
# its removal). Refuse an existing owner; the negative case creates its own.
if docker container inspect sihsalus-db-restore >/dev/null 2>&1 \
   || docker volume inspect "$DB_VOLUME" >/dev/null 2>&1 \
   || docker volume inspect "$SNAPSHOT" >/dev/null 2>&1; then
  echo 'Physical drill refuses existing restore resources' >&2
  exit 2
fi
STAGE=start
timeout --kill-after=5s 180s docker compose pull >"$STATE/pull.log" 2>&1
STARTED=true
wait_for_db
[[ "$(docker inspect "$DB_NAME" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/mysql"}}{{.Name}}{{end}}{{end}}')" == "$DB_VOLUME" ]]
IMAGE_ID="$(docker inspect "$DB_NAME" --format '{{.Image}}')"
sql <<'SQL'
CREATE TABLE probe (id INT PRIMARY KEY, value VARCHAR(64) NOT NULL, optional_value INT NULL) ENGINE=InnoDB;
INSERT INTO probe VALUES (1, 'before-backup', 7), (2, 'synthetic-second-row', NULL), (3, 'synthetic-third-row', -1);
SQL
before="$(fingerprint)"
[[ "${before%%$'\n'*}" =~ ^backup_drill[.]probe$'\t'[0-9]+$ ]]
STAGE=backup
echo 'Physical drill: create encrypted backup'
phase_start=$SECONDS
timeout --kill-after=5s 180s bash scripts/backup/backup_full.sh --container "$DB_NAME" --dir "$STATE/backups" --max 2 >"$STATE/backup.log" 2>&1
BACKUP_SECONDS=$((SECONDS-phase_start))
archives=("$STATE"/backups/backup_*.tar.gz.enc)
[[ ${#archives[@]} == 1 && -s "${archives[0]}" ]]
archive="${archives[0]}"
ARCHIVE_SHA="$(sha256sum "$archive" | cut -d' ' -f1)"
sql --execute="UPDATE probe SET value='after-backup' WHERE id=1; DELETE FROM probe WHERE id=3;"
[[ "$(fingerprint)" != "$before" ]]
STAGE=restore
echo 'Physical drill: restore and compare checksum/rows'
phase_start=$SECONDS
timeout --kill-after=5s 240s bash scripts/backup/restore_full.sh --container "$DB_NAME" --file "$archive" <<<s >"$STATE/restore.log" 2>&1
wait_for_db
RESTORE_SECONDS=$((SECONDS-phase_start))
[[ "$(fingerprint)" == "$before" ]]
[[ "$(sql --execute='SELECT COUNT(*) FROM probe')" == 3 ]]
if docker volume inspect "$SNAPSHOT" >/dev/null 2>&1; then
  echo 'Successful restore unexpectedly retained its snapshot' >&2
  exit 1
fi
RESTORE_VERIFIED=true

STAGE=rollback
echo 'Physical drill: fail copy-back startup and verify snapshot recovery'
sql --execute="UPDATE probe SET value='keep-after-failed-restore' WHERE id=1; INSERT INTO probe VALUES (4, 'snapshot-only-row', 42);"
before_failure="$(fingerprint)"
[[ "$before_failure" != "$before" ]]
docker create --name sihsalus-db-restore --label "sihsalus.physical-drill=$COMPOSE_PROJECT_NAME" busybox:latest true >/dev/null
COLLISION_CREATED=true
phase_start=$SECONDS
set +e
timeout --kill-after=5s 240s bash scripts/backup/restore_full.sh --container "$DB_NAME" --file "$archive" <<<s >"$STATE/rollback.log" 2>&1
restore_exit=$?
set -e
[[ "$restore_exit" == 1 ]]
grep -Fq 'Fallo en copy-back. Restaurando snapshot anterior' "$STATE/rollback.log"
grep -Fq 'Snapshot restaurado. Reiniciando con datos anteriores' "$STATE/rollback.log"
docker rm sihsalus-db-restore >/dev/null
COLLISION_CREATED=false
wait_for_db
ROLLBACK_SECONDS=$((SECONDS-phase_start))
[[ "$(fingerprint)" == "$before_failure" ]]
[[ "$(sql --execute='SELECT COUNT(*) FROM probe')" == 4 ]]
docker volume inspect "$SNAPSHOT" >/dev/null
[[ "$(sha256sum "$archive" | cut -d' ' -f1)" == "$ARCHIVE_SHA" ]]
ROLLBACK_VERIFIED=true
STAGE=complete
