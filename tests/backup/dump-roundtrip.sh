#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

CONTAINER_NAME="sihsalus-backup-test-${GITHUB_RUN_ID:-$$}"
TEST_DIR="$(mktemp -d)"
MYSQL_ROOT_PASSWORD="$(openssl rand -hex 16)"
BACKUP_ENCRYPTION_PASSWORD="$(openssl rand -hex 16)"

cleanup() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

export MYSQL_ROOT_PASSWORD BACKUP_ENCRYPTION_PASSWORD

docker run -d \
  --name "$CONTAINER_NAME" \
  -e MARIADB_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" \
  -e MARIADB_DATABASE=openmrs \
  mariadb:10.11.7 >/dev/null

READY=false
for _ in $(seq 1 60); do
  if docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_NAME" \
      mariadb --user=root --execute='SELECT 1' >/dev/null 2>&1; then
    READY=true
    break
  fi
  sleep 1
done

if [ "$READY" != "true" ]; then
  docker logs "$CONTAINER_NAME" >&2 || true
  echo "[FAIL] MariaDB did not become ready" >&2
  exit 1
fi

docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_NAME" \
  mariadb --user=root openmrs -e \
  "CREATE TABLE backup_probe (id INT PRIMARY KEY, value VARCHAR(64)); INSERT INTO backup_probe VALUES (1, 'before-backup');"

./scripts/backup/backup_dump.sh --container "$CONTAINER_NAME" --dir "$TEST_DIR" --max 2
BACKUP_FILE="$(find "$TEST_DIR" -maxdepth 1 -name 'dump_*.sql.gz.enc' -print -quit)"
[ -n "$BACKUP_FILE" ]

docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_NAME" \
  mariadb --user=root openmrs -e "UPDATE backup_probe SET value='after-backup' WHERE id=1;"

./scripts/backup/restore_dump.sh \
  --container "$CONTAINER_NAME" \
  --file "$BACKUP_FILE" \
  --yes \
  --no-app-control

RESTORED_VALUE="$(docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_NAME" \
  mariadb --batch --skip-column-names --user=root openmrs -e \
  'SELECT value FROM backup_probe WHERE id=1;')"

if [ "$RESTORED_VALUE" != "before-backup" ]; then
  echo "[FAIL] expected before-backup, got: $RESTORED_VALUE" >&2
  exit 1
fi

echo "[OK] encrypted MariaDB dump/restore round-trip"
