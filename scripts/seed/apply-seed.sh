#!/bin/sh
set -eu

SEED_URL="${SIHSALUS_SEED_URL:-}"
SEED_SHA256="${SIHSALUS_SEED_SHA256:-}"
SEED_FORCE="${SIHSALUS_SEED_FORCE:-false}"
TMP_DIR="/tmp/sihsalus-seed"
SEED_FILE="$TMP_DIR/seed.tar.gz"
WORK_DIR="$TMP_DIR/work"

has_data() {
  find "$1" -mindepth 1 -maxdepth 1 | read _unused
}

empty_dir() {
  rm -rf "$1"/* "$1"/.[!.]* "$1"/..?* 2>/dev/null || true
}

extract_volume() {
  archive="$1"
  dest="$2"
  label="$3"

  if has_data "$dest"; then
    if [ "$SEED_FORCE" = "true" ]; then
      echo "[seed] clearing $label volume"
      empty_dir "$dest"
    else
      echo "[seed] $label volume already has data; set SIHSALUS_SEED_FORCE=true to replace it"
      return 0
    fi
  fi

  echo "[seed] extracting $label"
  tar xzf "$archive" -C "$dest"
}

[ -n "$SEED_URL" ] || {
  echo "[seed] SIHSALUS_SEED_URL is required"
  exit 2
}

rm -rf "$TMP_DIR"
mkdir -p "$WORK_DIR"

echo "[seed] downloading $SEED_URL"
if [ -n "${GITHUB_TOKEN:-}" ]; then
  curl -fL \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/octet-stream" \
    -o "$SEED_FILE" \
    "$SEED_URL"
else
  curl -fL -o "$SEED_FILE" "$SEED_URL"
fi

if [ -n "$SEED_SHA256" ]; then
  echo "$SEED_SHA256  $SEED_FILE" | sha256sum -c -
fi

tar xzf "$SEED_FILE" -C "$WORK_DIR"

[ -f "$WORK_DIR/db-data.tar.gz" ] || { echo "[seed] missing db-data.tar.gz"; exit 3; }
[ -f "$WORK_DIR/openmrs-data.tar.gz" ] || { echo "[seed] missing openmrs-data.tar.gz"; exit 3; }

extract_volume "$WORK_DIR/db-data.tar.gz" /seed/db-data "db-data"
extract_volume "$WORK_DIR/openmrs-data.tar.gz" /seed/openmrs-data "openmrs-data"

if [ -f "$WORK_DIR/fua-db-data.tar.gz" ]; then
  extract_volume "$WORK_DIR/fua-db-data.tar.gz" /seed/fua-db-data "fua-db-data"
fi

date -u +"%Y-%m-%dT%H:%M:%SZ" > /seed/openmrs-data/.sihsalus-seed-applied
echo "[seed] done"
