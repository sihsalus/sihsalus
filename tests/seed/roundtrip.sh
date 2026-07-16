#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLY_SCRIPT="$ROOT_DIR/scripts/seed/apply-seed.sh"
TEST_DIR="$(mktemp -d /tmp/sihsalus-seed-test.XXXXXX)"
export COPYFILE_DISABLE=1

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

for cmd in curl openssl sha256sum tar; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "[FAIL] missing command: $cmd" >&2
    exit 1
  }
done

PASS_FILE="$TEST_DIR/passphrase"
WRONG_PASS_FILE="$TEST_DIR/wrong-passphrase"
printf '%s\n' 'roundtrip-test-passphrase' > "$PASS_FILE"
printf '%s\n' 'wrong-roundtrip-passphrase' > "$WRONG_PASS_FILE"
chmod 600 "$PASS_FILE" "$WRONG_PASS_FILE"

FIXTURE="$TEST_DIR/fixture"
mkdir -p "$FIXTURE/db" "$FIXTURE/openmrs" "$FIXTURE/fua" "$TEST_DIR/bundle"
printf '%s\n' 'db-sentinel' > "$FIXTURE/db/db.txt"
printf '%s\n' 'openmrs-sentinel' > "$FIXTURE/openmrs/openmrs.txt"
printf '%s\n' 'fua-sentinel' > "$FIXTURE/fua/fua.txt"

tar czf "$TEST_DIR/bundle/db-data.tar.gz" -C "$FIXTURE/db" .
tar czf "$TEST_DIR/bundle/openmrs-data.tar.gz" -C "$FIXTURE/openmrs" .
tar czf "$TEST_DIR/bundle/fua-db-data.tar.gz" -C "$FIXTURE/fua" .
cat > "$TEST_DIR/bundle/manifest.txt" <<'EOF'
seed_format=2
patient_count=0
obs_count=0
encounter_count=0
ocl_item_error_count=0
ocl_import_error_count=0
EOF

PLAIN="$TEST_DIR/sihsalus-seed.tar.gz"
CIPHER="$PLAIN.enc"
tar czf "$PLAIN" -C "$TEST_DIR/bundle" \
  manifest.txt db-data.tar.gz openmrs-data.tar.gz fua-db-data.tar.gz
openssl enc -aes-256-cbc -salt -pbkdf2 -iter 600000 -md sha256 \
  -pass "file:$PASS_FILE" -in "$PLAIN" -out "$CIPHER"
SHA256="$(sha256sum "$CIPHER" | awk '{print $1}')"

run_apply() {
  dest="$1"
  pass_file="$2"
  force="$3"
  checksum="$4"

  SIHSALUS_SEED_URL="file://$CIPHER" \
  SIHSALUS_SEED_SHA256="$checksum" \
  SIHSALUS_SEED_PASSPHRASE_FILE="$pass_file" \
  SIHSALUS_SEED_FORCE="$force" \
  SIHSALUS_SEED_ROOT="$dest" \
    "$APPLY_SCRIPT"
}

DEST_SUCCESS="$TEST_DIR/dest-success"
run_apply "$DEST_SUCCESS" "$PASS_FILE" false "$SHA256"
grep -qx 'db-sentinel' "$DEST_SUCCESS/db-data/db.txt"
grep -qx 'openmrs-sentinel' "$DEST_SUCCESS/openmrs-data/openmrs.txt"
grep -qx 'fua-sentinel' "$DEST_SUCCESS/fua-db-data/fua.txt"
test -s "$DEST_SUCCESS/openmrs-data/.sihsalus-seed-applied"

DEST_NONEMPTY="$TEST_DIR/dest-nonempty"
mkdir -p "$DEST_NONEMPTY/db-data" "$DEST_NONEMPTY/openmrs-data" "$DEST_NONEMPTY/fua-db-data"
printf '%s\n' 'keep-me' > "$DEST_NONEMPTY/db-data/existing.txt"
if run_apply "$DEST_NONEMPTY" "$PASS_FILE" false "$SHA256" >/dev/null 2>&1; then
  echo "[FAIL] restore unexpectedly accepted a non-empty volume" >&2
  exit 1
fi
grep -qx 'keep-me' "$DEST_NONEMPTY/db-data/existing.txt"
test ! -e "$DEST_NONEMPTY/openmrs-data/openmrs.txt"
test ! -e "$DEST_NONEMPTY/openmrs-data/.sihsalus-seed-applied"

run_apply "$DEST_NONEMPTY" "$PASS_FILE" true "$SHA256"
test ! -e "$DEST_NONEMPTY/db-data/existing.txt"
grep -qx 'db-sentinel' "$DEST_NONEMPTY/db-data/db.txt"

BAD_SHA="0${SHA256#?}"
if [ "$BAD_SHA" = "$SHA256" ]; then
  BAD_SHA="1${SHA256#?}"
fi
if run_apply "$TEST_DIR/dest-bad-sha" "$PASS_FILE" false "$BAD_SHA" >/dev/null 2>&1; then
  echo "[FAIL] restore unexpectedly accepted a bad checksum" >&2
  exit 1
fi
test ! -e "$TEST_DIR/dest-bad-sha/openmrs-data/.sihsalus-seed-applied"

if run_apply "$TEST_DIR/dest-bad-pass" "$WRONG_PASS_FILE" false "$SHA256" >/dev/null 2>&1; then
  echo "[FAIL] restore unexpectedly accepted a wrong passphrase" >&2
  exit 1
fi
test ! -e "$TEST_DIR/dest-bad-pass/openmrs-data/.sihsalus-seed-applied"

if run_apply "$TEST_DIR/../unsafe-root" "$PASS_FILE" false "$SHA256" >/dev/null 2>&1; then
  echo "[FAIL] restore unexpectedly accepted a destination containing .." >&2
  exit 1
fi

if run_apply "$TEST_DIR/dest-missing-sha" "$PASS_FILE" false "" >/dev/null 2>&1; then
  echo "[FAIL] restore unexpectedly accepted a missing checksum" >&2
  exit 1
fi

echo "[OK] encrypted seed round-trip and negative cases"
