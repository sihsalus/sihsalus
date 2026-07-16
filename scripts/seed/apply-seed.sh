#!/bin/sh
set -eu

umask 077

SEED_URL="${SIHSALUS_SEED_URL:-}"
SEED_SHA256="${SIHSALUS_SEED_SHA256:-}"
SEED_PASSPHRASE_FILE="${SIHSALUS_SEED_PASSPHRASE_FILE:-/run/secrets/seed_passphrase}"
SEED_FORCE="${SIHSALUS_SEED_FORCE:-false}"
SEED_ROOT="${SIHSALUS_SEED_ROOT:-/seed}"
case "$SEED_ROOT" in
  /|"") echo "[seed] invalid SIHSALUS_SEED_ROOT" >&2; exit 2 ;;
esac
case "/$SEED_ROOT/" in
  */../*) echo "[seed] SIHSALUS_SEED_ROOT must not contain .." >&2; exit 2 ;;
esac

TMP_DIR="$(mktemp -d /tmp/sihsalus-seed.XXXXXX)"
CIPHER_FILE="$TMP_DIR/sihsalus-seed.tar.gz.enc"
SEED_FILE="$TMP_DIR/sihsalus-seed.tar.gz"
WORK_DIR="$TMP_DIR/work"
RESTORE_STARTED=false
RESTORE_COMPLETE=false
FUA_INCLUDED=false

cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$RESTORE_STARTED" = "true" ] && [ "$RESTORE_COMPLETE" = "false" ]; then
    echo "[seed] restore failed; clearing partial target data" >&2
    empty_dir "$DB_DEST" || true
    empty_dir "$OMRS_DEST" || true
    [ "$FUA_INCLUDED" = "false" ] || empty_dir "$FUA_DEST" || true
  fi
  rm -rf "$TMP_DIR"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  echo "[seed] $1" >&2
  exit "${2:-1}"
}

has_data() {
  find "$1" -mindepth 1 -maxdepth 1 | read -r _unused
}

empty_dir() {
  find "$1" -mindepth 1 -maxdepth 1 -exec rm -rf {} \;
}

validate_archive_paths() {
  archive="$1"
  label="$2"
  list="$TMP_DIR/$label.list"
  verbose_list="$TMP_DIR/$label.verbose"

  tar tzf "$archive" > "$list" || fail "invalid $label archive" 3
  tar tvzf "$archive" > "$verbose_list" || fail "invalid $label archive" 3
  [ -s "$list" ] || fail "empty $label archive" 3

  while IFS= read -r entry; do
    [ "$entry" != "./" ] || continue
    clean_entry="${entry#./}"
    case "$clean_entry" in
      ""|/*|..|../*|*/../*|*/..)
        fail "unsafe path in $label archive: $entry" 3
        ;;
    esac
  done < "$list"

  while IFS= read -r entry; do
    case "$entry" in
      d*|-*) ;;
      *) fail "unsupported entry type in $label archive" 3 ;;
    esac
  done < "$verbose_list"
}

validate_outer_archive() {
  validate_archive_paths "$SEED_FILE" outer

  manifest_seen=0
  db_seen=0
  openmrs_seen=0
  fua_seen=0
  while IFS= read -r entry; do
    clean_entry="${entry#./}"
    case "$clean_entry" in
      manifest.txt) manifest_seen=$((manifest_seen + 1)) ;;
      db-data.tar.gz) db_seen=$((db_seen + 1)) ;;
      openmrs-data.tar.gz) openmrs_seen=$((openmrs_seen + 1)) ;;
      fua-db-data.tar.gz) fua_seen=$((fua_seen + 1)) ;;
      *) fail "unexpected file in seed bundle: $entry" 3 ;;
    esac
  done < "$TMP_DIR/outer.list"

  [ "$manifest_seen" -eq 1 ] || fail "seed bundle must contain one manifest.txt" 3
  [ "$db_seen" -eq 1 ] || fail "seed bundle must contain one db-data.tar.gz" 3
  [ "$openmrs_seen" -eq 1 ] || fail "seed bundle must contain one openmrs-data.tar.gz" 3
  [ "$fua_seen" -le 1 ] || fail "seed bundle contains duplicate fua-db-data.tar.gz" 3
}

[ -n "$SEED_URL" ] || fail "SIHSALUS_SEED_URL is required" 2
[ -n "$SEED_SHA256" ] || fail "SIHSALUS_SEED_SHA256 is required" 2
[ "${#SEED_SHA256}" -eq 64 ] || fail "SIHSALUS_SEED_SHA256 must contain 64 hexadecimal characters" 2
case "$SEED_SHA256" in
  *[!0-9a-fA-F]*) fail "SIHSALUS_SEED_SHA256 must contain 64 hexadecimal characters" 2 ;;
esac
[ -r "$SEED_PASSPHRASE_FILE" ] && [ -s "$SEED_PASSPHRASE_FILE" ] || \
  fail "SIHSALUS_SEED_PASSPHRASE_FILE must point to a readable, non-empty file" 2
case "$SEED_FORCE" in
  true|false) ;;
  *) fail "SIHSALUS_SEED_FORCE must be true or false" 2 ;;
esac

rm -rf "$TMP_DIR"
mkdir -p "$WORK_DIR"

echo "[seed] downloading encrypted artifact"
case "$SEED_URL" in
  https://github.com/*|https://api.github.com/*)
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      curl -fL \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/octet-stream" \
        -o "$CIPHER_FILE" \
        "$SEED_URL"
    else
      curl -fL -o "$CIPHER_FILE" "$SEED_URL"
    fi
    ;;
  *)
    curl -fL -o "$CIPHER_FILE" "$SEED_URL"
    ;;
esac

echo "$SEED_SHA256  $CIPHER_FILE" | sha256sum -c -

echo "[seed] decrypting artifact"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 \
  -pass "file:$SEED_PASSPHRASE_FILE" \
  -in "$CIPHER_FILE" \
  -out "$SEED_FILE"

validate_outer_archive
tar xzf "$SEED_FILE" -C "$WORK_DIR"
grep -qx 'seed_format=2' "$WORK_DIR/manifest.txt" || fail "unsupported seed format" 3
validate_archive_paths "$WORK_DIR/db-data.tar.gz" db-data
validate_archive_paths "$WORK_DIR/openmrs-data.tar.gz" openmrs-data
if [ -f "$WORK_DIR/fua-db-data.tar.gz" ]; then
  FUA_INCLUDED=true
  validate_archive_paths "$WORK_DIR/fua-db-data.tar.gz" fua-db-data
fi

DB_DEST="$SEED_ROOT/db-data"
OMRS_DEST="$SEED_ROOT/openmrs-data"
FUA_DEST="$SEED_ROOT/fua-db-data"
mkdir -p "$DB_DEST" "$OMRS_DEST" "$FUA_DEST"

if [ "$SEED_FORCE" = "false" ]; then
  has_data "$DB_DEST" && fail "db-data volume is not empty; use SIHSALUS_SEED_FORCE=true to replace it" 4
  has_data "$OMRS_DEST" && fail "openmrs-data volume is not empty; use SIHSALUS_SEED_FORCE=true to replace it" 4
  if [ -f "$WORK_DIR/fua-db-data.tar.gz" ]; then
    has_data "$FUA_DEST" && fail "fua-db-data volume is not empty; use SIHSALUS_SEED_FORCE=true to replace it" 4
  fi
else
  RESTORE_STARTED=true
  echo "[seed] clearing target volumes"
  empty_dir "$DB_DEST"
  empty_dir "$OMRS_DEST"
  [ ! -f "$WORK_DIR/fua-db-data.tar.gz" ] || empty_dir "$FUA_DEST"
fi

RESTORE_STARTED=true
echo "[seed] extracting db-data"
tar xzf "$WORK_DIR/db-data.tar.gz" -C "$DB_DEST"
echo "[seed] extracting openmrs-data"
tar xzf "$WORK_DIR/openmrs-data.tar.gz" -C "$OMRS_DEST"
if [ -f "$WORK_DIR/fua-db-data.tar.gz" ]; then
  echo "[seed] extracting fua-db-data"
  tar xzf "$WORK_DIR/fua-db-data.tar.gz" -C "$FUA_DEST"
fi

date -u +"%Y-%m-%dT%H:%M:%SZ" > "$OMRS_DEST/.sihsalus-seed-applied"
RESTORE_COMPLETE=true
echo "[seed] done"
