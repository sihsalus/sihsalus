#!/bin/sh
set -eu

umask 077

GH_REPO="${GH_REPO:-sihsalus/sihsalus}"
SEED_PASSPHRASE_FILE="${SIHSALUS_SEED_PASSPHRASE_FILE:-}"
SEED_DRAFT="${SIHSALUS_SEED_DRAFT:-true}"
INCLUDE_FUA="${SIHSALUS_SEED_INCLUDE_FUA:-true}"

for cmd in awk cp docker gh git openssl sha256sum tar; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "[seed] missing command: $cmd" >&2
    exit 1
  }
done

[ -n "$SEED_PASSPHRASE_FILE" ] && [ -r "$SEED_PASSPHRASE_FILE" ] && [ -s "$SEED_PASSPHRASE_FILE" ] || {
  echo "[seed] SIHSALUS_SEED_PASSPHRASE_FILE must point to a readable, non-empty file" >&2
  exit 2
}

case "$SEED_DRAFT" in
  true|false) ;;
  *) echo "[seed] SIHSALUS_SEED_DRAFT must be true or false" >&2; exit 2 ;;
esac

case "$INCLUDE_FUA" in
  true|false) ;;
  *) echo "[seed] SIHSALUS_SEED_INCLUDE_FUA must be true or false" >&2; exit 2 ;;
esac

[ -f docker-compose.yml ] || {
  echo "[seed] run this from the sihsalus repo root" >&2
  exit 1
}

[ -z "$(git status --porcelain)" ] || {
  echo "[seed] git worktree must be clean" >&2
  exit 1
}

gh auth status --hostname github.com >/dev/null
docker exec sihsalus-backend curl -fsS \
  http://localhost:8080/openmrs/health/started >/dev/null

GIT_SHA="$(git rev-parse HEAD)"
GIT_SHA_SHORT="$(git rev-parse --short HEAD)"
CONTENT_VERSION="$(awk -F '[<>]' '/<sihsalus-content.version>/{print $3; exit}' backend/pom.xml)"
CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TAG="${SEED_TAG:-seed-content-${CONTENT_VERSION}-${GIT_SHA_SHORT}-$(date -u +%Y%m%d%H%M%S)}"
OUT="${SEED_OUT_DIR:-$HOME/sihsalus-seeds/$TAG}"
WORK_DIR="$OUT/.work-$$"
ARTIFACT_NAME="sihsalus-seed.tar.gz.enc"
CHECKSUM_NAME="$ARTIFACT_NAME.sha256"

mkdir -p "$WORK_DIR"
chmod 700 "$OUT" "$WORK_DIR"

DB_VOL="$(docker inspect sihsalus-db-master --format '{{range .Mounts}}{{if eq .Destination "/var/lib/mysql"}}{{.Name}}{{end}}{{end}}')"
OMRS_VOL="$(docker inspect sihsalus-backend --format '{{range .Mounts}}{{if eq .Destination "/openmrs/data"}}{{.Name}}{{end}}{{end}}')"
FUA_VOL=""
if [ "$INCLUDE_FUA" = "true" ]; then
  FUA_VOL="$(docker inspect sihsalus-fua-generator-db --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' 2>/dev/null || true)"
fi

[ -n "$DB_VOL" ] || { echo "[seed] db volume not found" >&2; exit 1; }
[ -n "$OMRS_VOL" ] || { echo "[seed] openmrs volume not found" >&2; exit 1; }

is_running() {
  [ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null || true)" = "true" ]
}

BACKEND_WAS_RUNNING=false
DB_WAS_RUNNING=false
FUA_WAS_RUNNING=false
FUA_DB_WAS_RUNNING=false
is_running sihsalus-backend && BACKEND_WAS_RUNNING=true
is_running sihsalus-db-master && DB_WAS_RUNNING=true
is_running sihsalus-fua-generator && FUA_WAS_RUNNING=true
is_running sihsalus-fua-generator-db && FUA_DB_WAS_RUNNING=true

wait_healthy() {
  container="$1"
  max_attempts="$2"
  attempts=0
  while [ "$attempts" -lt "$max_attempts" ]; do
    state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || true)"
    case "$state" in
      healthy|running) return 0 ;;
      exited|dead) break ;;
    esac
    attempts=$((attempts + 1))
    sleep 2
  done
  echo "[seed] $container did not become healthy" >&2
  return 1
}

restart_captured_containers() {
  restart_failed=false

  [ "$DB_WAS_RUNNING" = "false" ] || docker start sihsalus-db-master >/dev/null || restart_failed=true
  [ "$FUA_DB_WAS_RUNNING" = "false" ] || docker start sihsalus-fua-generator-db >/dev/null || restart_failed=true

  [ "$DB_WAS_RUNNING" = "false" ] || wait_healthy sihsalus-db-master 60 || restart_failed=true
  [ "$FUA_DB_WAS_RUNNING" = "false" ] || wait_healthy sihsalus-fua-generator-db 60 || restart_failed=true

  [ "$BACKEND_WAS_RUNNING" = "false" ] || docker start sihsalus-backend >/dev/null || restart_failed=true
  [ "$FUA_WAS_RUNNING" = "false" ] || docker start sihsalus-fua-generator >/dev/null || restart_failed=true

  [ "$BACKEND_WAS_RUNNING" = "false" ] || wait_healthy sihsalus-backend 450 || restart_failed=true
  [ "$FUA_WAS_RUNNING" = "false" ] || wait_healthy sihsalus-fua-generator 120 || restart_failed=true

  [ "$restart_failed" = "false" ]
}

RESTART_NEEDED=false
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  rm -rf "$WORK_DIR"
  if [ "$RESTART_NEEDED" = "true" ]; then
    restart_captured_containers || status=1
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

RESTART_NEEDED=true
echo "[seed] stopping application writers"
[ "$BACKEND_WAS_RUNNING" = "false" ] || docker stop sihsalus-backend >/dev/null
[ "$FUA_WAS_RUNNING" = "false" ] || docker stop sihsalus-fua-generator >/dev/null

echo "[seed] checking that the snapshot contains no clinical records or OCL errors"
SAFETY_COUNTS="$(docker exec sihsalus-db-master sh -ec '
  MYSQL_PWD="$MYSQL_PASSWORD" mariadb \
    --user="$MYSQL_USER" \
    --database="$MYSQL_DATABASE" \
    --batch --skip-column-names \
    --execute="SELECT
      (SELECT COUNT(*) FROM patient),
      (SELECT COUNT(*) FROM obs),
      (SELECT COUNT(*) FROM encounter),
      (SELECT COUNT(*) FROM openconceptlab_item WHERE error_message IS NOT NULL AND LENGTH(error_message) > 0),
      (SELECT COUNT(*) FROM openconceptlab_import WHERE error_message IS NOT NULL AND LENGTH(error_message) > 0);"
')"
set -- $SAFETY_COUNTS
[ "$#" -eq 5 ] || { echo "[seed] unexpected safety query result" >&2; exit 1; }
PATIENT_COUNT="$1"
OBS_COUNT="$2"
ENCOUNTER_COUNT="$3"
OCL_ITEM_ERROR_COUNT="$4"
OCL_IMPORT_ERROR_COUNT="$5"

if [ "$PATIENT_COUNT" -ne 0 ] || [ "$OBS_COUNT" -ne 0 ] || \
   [ "$ENCOUNTER_COUNT" -ne 0 ] || [ "$OCL_ITEM_ERROR_COUNT" -ne 0 ] || \
   [ "$OCL_IMPORT_ERROR_COUNT" -ne 0 ]; then
  echo "[seed] refusing snapshot: patient=$PATIENT_COUNT obs=$OBS_COUNT encounter=$ENCOUNTER_COUNT ocl_item_errors=$OCL_ITEM_ERROR_COUNT ocl_import_errors=$OCL_IMPORT_ERROR_COUNT" >&2
  exit 3
fi

echo "[seed] stopping databases"
[ "$DB_WAS_RUNNING" = "false" ] || docker stop sihsalus-db-master >/dev/null
[ "$FUA_DB_WAS_RUNNING" = "false" ] || docker stop sihsalus-fua-generator-db >/dev/null

DB_IMAGE="$(docker inspect --format '{{.Config.Image}}' sihsalus-db-master)"
BACKEND_IMAGE="$(docker inspect --format '{{.Config.Image}}' sihsalus-backend)"
DB_IMAGE_ID="$(docker inspect --format '{{.Image}}' sihsalus-db-master)"
BACKEND_IMAGE_ID="$(docker inspect --format '{{.Image}}' sihsalus-backend)"
BACKEND_REVISION="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$BACKEND_IMAGE_ID" 2>/dev/null || true)"
FUA_DB_IMAGE=""
FUA_DB_IMAGE_ID=""
if [ -n "$FUA_VOL" ]; then
  FUA_DB_IMAGE="$(docker inspect --format '{{.Config.Image}}' sihsalus-fua-generator-db)"
  FUA_DB_IMAGE_ID="$(docker inspect --format '{{.Image}}' sihsalus-fua-generator-db)"
fi

cat > "$WORK_DIR/manifest.txt" <<EOF
seed_format=2
created_at=$CREATED_AT
repository=$GH_REPO
git_sha=$GIT_SHA
content_version=$CONTENT_VERSION
backend_image=$BACKEND_IMAGE
backend_image_id=$BACKEND_IMAGE_ID
backend_revision=$BACKEND_REVISION
database_image=$DB_IMAGE
database_image_id=$DB_IMAGE_ID
fua_database_image=$FUA_DB_IMAGE
fua_database_image_id=$FUA_DB_IMAGE_ID
patient_count=$PATIENT_COUNT
obs_count=$OBS_COUNT
encounter_count=$ENCOUNTER_COUNT
ocl_item_error_count=$OCL_ITEM_ERROR_COUNT
ocl_import_error_count=$OCL_IMPORT_ERROR_COUNT
EOF
cp "$WORK_DIR/manifest.txt" "$OUT/manifest.txt"

echo "[seed] archiving db-data"
docker run --rm -v "$DB_VOL":/volume:ro -v "$WORK_DIR":/backup busybox:1.37.0 \
  sh -c 'cd /volume && tar czf /backup/db-data.tar.gz .'

echo "[seed] archiving openmrs-data"
docker run --rm -v "$OMRS_VOL":/volume:ro -v "$WORK_DIR":/backup busybox:1.37.0 \
  sh -c 'cd /volume && tar czf /backup/openmrs-data.tar.gz .'

if [ -n "$FUA_VOL" ]; then
  echo "[seed] archiving fua-db-data"
  docker run --rm -v "$FUA_VOL":/volume:ro -v "$WORK_DIR":/backup busybox:1.37.0 \
    sh -c 'cd /volume && tar czf /backup/fua-db-data.tar.gz .'
fi

echo "[seed] creating encrypted artifact"
if [ -f "$WORK_DIR/fua-db-data.tar.gz" ]; then
  tar czf "$WORK_DIR/sihsalus-seed.tar.gz" -C "$WORK_DIR" \
    manifest.txt db-data.tar.gz openmrs-data.tar.gz fua-db-data.tar.gz
else
  tar czf "$WORK_DIR/sihsalus-seed.tar.gz" -C "$WORK_DIR" \
    manifest.txt db-data.tar.gz openmrs-data.tar.gz
fi

openssl enc -aes-256-cbc -salt -pbkdf2 -iter 600000 -md sha256 \
  -pass "file:$SEED_PASSPHRASE_FILE" \
  -in "$WORK_DIR/sihsalus-seed.tar.gz" \
  -out "$OUT/$ARTIFACT_NAME.tmp"
mv "$OUT/$ARTIFACT_NAME.tmp" "$OUT/$ARTIFACT_NAME"
(cd "$OUT" && sha256sum "$ARTIFACT_NAME" > "$CHECKSUM_NAME")
SHA256="$(awk '{print $1}' "$OUT/$CHECKSUM_NAME")"

echo "[seed] verifying encrypted artifact"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 \
  -pass "file:$SEED_PASSPHRASE_FILE" \
  -in "$OUT/$ARTIFACT_NAME" \
  -out "$WORK_DIR/verified-seed.tar.gz"
tar tzf "$WORK_DIR/verified-seed.tar.gz" >/dev/null

cat > "$OUT/release-notes.md" <<EOF
Encrypted SIHSALUS seed volume artifact.

- Git commit: $GIT_SHA
- Backend revision: $BACKEND_REVISION
- Content version: $CONTENT_VERSION
- Created at: $CREATED_AT
- Patient/obs/encounter rows: $PATIENT_COUNT/$OBS_COUNT/$ENCOUNTER_COUNT
- OCL item/import errors: $OCL_ITEM_ERROR_COUNT/$OCL_IMPORT_ERROR_COUNT
- Encryption: AES-256-CBC, PBKDF2-SHA256, 600000 iterations
- SHA256 (encrypted asset): $SHA256

The encryption password is intentionally not stored in GitHub.

Restore with SIHSALUS_SEED_URL, SIHSALUS_SEED_SHA256 and
SIHSALUS_SEED_PASSPHRASE_FILE using compose/seed.yml.
EOF

echo "[seed] restoring the previous container state"
if restart_captured_containers; then
  RESTART_NEEDED=false
else
  RESTART_NEEDED=false
  echo "[seed] previous containers did not recover health; release was not created" >&2
  exit 1
fi

echo "[seed] uploading release $TAG"
if [ "$SEED_DRAFT" = "true" ]; then
  gh release create "$TAG" \
    "$OUT/$ARTIFACT_NAME#$ARTIFACT_NAME" \
    "$OUT/$CHECKSUM_NAME#$CHECKSUM_NAME" \
    "$OUT/manifest.txt#manifest.txt" \
    --repo "$GH_REPO" \
    --target "$GIT_SHA" \
    --title "$TAG" \
    --notes-file "$OUT/release-notes.md" \
    --draft
else
  gh release create "$TAG" \
    "$OUT/$ARTIFACT_NAME#$ARTIFACT_NAME" \
    "$OUT/$CHECKSUM_NAME#$CHECKSUM_NAME" \
    "$OUT/manifest.txt#manifest.txt" \
    --repo "$GH_REPO" \
    --target "$GIT_SHA" \
    --title "$TAG" \
    --notes-file "$OUT/release-notes.md" \
    --latest=false
fi

echo "[seed] done"
echo "SEED_TAG=$TAG"
echo "SIHSALUS_SEED_URL=https://github.com/$GH_REPO/releases/download/$TAG/$ARTIFACT_NAME"
echo "SIHSALUS_SEED_SHA256=$SHA256"
echo "SIHSALUS_SEED_DRAFT=$SEED_DRAFT"
