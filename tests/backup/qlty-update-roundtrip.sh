#!/usr/bin/env bash
# Real MariaDB databases for the QLTY backup hook. Every row is synthetic.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted && ${RUNNER_OS:-} == Linux ]] || {
  echo 'The QLTY backup round trip requires an ephemeral GitHub-hosted Linux runner.' >&2; exit 2
}
[[ -z ${DOCKER_HOST:-} && -z ${DOCKER_CONTEXT:-} && $(docker context show) == default ]]
root=$(cd "$(dirname "$0")/../.." && pwd -P)
umask 077
state=$(mktemp -d "${RUNNER_TEMP:?}/qlty-backup.XXXXXXXX")
project=qlty-drill-$(openssl rand -hex 8)
recovery="$project-recovery"
export COMPOSE_FILE="$state/compose.yaml"
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)
export MYSQL_ROOT_PASSWORD MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
unset BACKUP_ENCRYPTION_PASSWORD
cp "$root/tests/backup/physical-compose.yml" "$COMPOSE_FILE"
ln -s "$root/scripts" "$state/scripts"
mkdir "$state/home"
cd "$state"
touch .env

compose() { COMPOSE_PROJECT_NAME="$1" docker compose "${@:2}"; }
cleanup() {
  local result=$?
  trap - EXIT
  compose "$recovery" down --volumes >/dev/null || result=1
  compose "$project" down --volumes >/dev/null || result=1
  rm -rf -- "$state"
  exit "$result"
}
trap cleanup EXIT
sql() { docker exec -e MYSQL_PWD "$1-db" mariadb --protocol=tcp --host=127.0.0.1 --user=root --batch --skip-column-names --execute="$2"; }
start() {
  compose "$1" up -d --wait --wait-timeout 120 db
  # Wait for the final server, beyond the entrypoint's socket-only bootstrap.
  for ((i=0; i<60; i++)); do
    if sql "$1" 'SELECT 1' >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}
start "$project"
sql "$project" "CREATE DATABASE openmrs; CREATE TABLE openmrs.patient(id INT PRIMARY KEY);
  CREATE TABLE openmrs.encounter(id INT PRIMARY KEY);
  CREATE TABLE openmrs.concept(id INT PRIMARY KEY, label VARCHAR(64));
  INSERT INTO openmrs.concept VALUES (1,'synthetic value before update');"
probe='SELECT label FROM openmrs.concept WHERE id=1'
identity() { docker inspect --format '{{.Id}}/{{.State.StartedAt}}' "$project-db"; }
source_before=$(identity)
volumes_before=$(docker volume ls --quiet | sort)
scratch=sihsalus-qlty-pre-backend-restore
if docker inspect "$scratch" >/dev/null 2>&1; then exit 1; fi

HOME="$state/home" COMPOSE_PROJECT_NAME="$project" bash "$root/scripts/deploy/qlty-pre-backend-backup.sh"
[[ $(identity) == "$source_before" && $(sql "$project" "$probe") == 'synthetic value before update' ]]
[[ $(docker volume ls --quiet | sort) == "$volumes_before" ]]
if docker inspect "$scratch" >/dev/null 2>&1; then exit 1; fi
base="$state/home/.local/share/sihsalus/backups/qlty-backend-update"
shopt -s nullglob
archives=("$base"/verified-*/dump_*.sql.gz.enc)
[[ ${#archives[@]} == 1 && ! -e "$base/.pending" ]]
(cd "$(dirname "${archives[0]}")" && sha256sum --check --strict SHA256SUMS)
# Independently import the retained bytes into a second Compose project and
# compare the exact value. Change the fixture first to catch accidental reads
# from the source during this verification.
sql "$project" "UPDATE openmrs.concept SET label='synthetic value after update' WHERE id=1"
start "$recovery"
read -r BACKUP_ENCRYPTION_PASSWORD < "$state/home/.sihsalus-backup-keys/qlty-backend-update.key"
export BACKUP_ENCRYPTION_PASSWORD
bash "$root/scripts/backup/restore_dump.sh" --container "$recovery-db" \
  --file "${archives[0]}" --yes --no-app-control >/dev/null
[[ $(sql "$recovery" "$probe") == 'synthetic value before update' ]]
[[ $(sql "$project" "$probe") == 'synthetic value after update' && $(identity) == "$source_before" ]]
echo 'PASS: verified encrypted OpenMRS row recovered in a separate MariaDB project; source and scratch cleanup verified'
