#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${ROOT_DIR}/backend/bin/configure-ocl-token.sh"
FIXTURE_ROOT="$(mktemp -d)"
DATA_DIR="${FIXTURE_ROOT}/data"
PROPERTIES_DIR="${DATA_DIR}/configuration/globalproperties"
CHECKSUM_DIR="${DATA_DIR}/configuration_checksums/globalproperties"
BASE_FILE="${PROPERTIES_DIR}/globalproperties-sihsalus.xml"
OVERRIDE_FILE="${PROPERTIES_DIR}/zz-runtime-ocl-token.xml"
CHECKSUM_FILE="${CHECKSUM_DIR}/zz-runtime-ocl-token.checksum"
OUTPUT_FILE="${FIXTURE_ROOT}/output.log"
TOKEN_A="$(printf 'a%.0s' {1..40})"
TOKEN_B="$(printf 'b%.0s' {1..40})"
UPPERCASE_TOKEN="$(printf 'C%.0s' {1..40})"

cleanup() {
  rm -rf "$FIXTURE_ROOT"
}
trap cleanup EXIT

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

file_digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

write_base_fixture() {
  mkdir -p "$PROPERTIES_DIR" "$CHECKSUM_DIR"
  cat > "$BASE_FILE" <<'EOF_XML'
<config>
    <globalProperties>
        <globalProperty>
            <property>application.name</property>
            <value>SIH SALUS</value>
        </globalProperty>
        <globalProperty>
            <property>openconceptlab.token</property>
            <value>${OMRS_OCL_TOKEN}</value>
        </globalProperty>
    </globalProperties>
</config>
EOF_XML
}

run_config() {
  local token="$1"
  OMRS_OCL_TOKEN="$token" \
    "$SCRIPT" "$DATA_DIR/configuration" "$DATA_DIR/configuration_checksums" \
    >> "$OUTPUT_FILE" 2>&1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  local message="$3"
  grep -qF "$expected" "$file" || fail "$message"
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  local message="$3"
  if grep -qF "$unexpected" "$file"; then
    fail "$message"
  fi
}

bash -n "$SCRIPT"

# Invalid values fail before touching copied config, overrides, or checksums.
write_base_fixture
printf '%s\n' keep-override > "$OVERRIDE_FILE"
printf '%s\n' keep-checksum > "$CHECKSUM_FILE"
base_before="$(file_digest "$BASE_FILE")"
override_before="$(file_digest "$OVERRIDE_FILE")"
checksum_before="$(file_digest "$CHECKSUM_FILE")"
set +e
OMRS_OCL_TOKEN="Token ${TOKEN_A}" \
  "$SCRIPT" "$DATA_DIR/configuration" "$DATA_DIR/configuration_checksums" \
  >> "$OUTPUT_FILE" 2>&1
invalid_status=$?
set -e
[[ "$invalid_status" -eq 78 ]] || fail "an invalid token did not exit with EX_CONFIG"
[[ "$(file_digest "$BASE_FILE")" == "$base_before" ]] || fail "invalid input changed the base XML"
[[ "$(file_digest "$OVERRIDE_FILE")" == "$override_before" ]] || fail "invalid input changed the override"
[[ "$(file_digest "$CHECKSUM_FILE")" == "$checksum_before" ]] || fail "invalid input changed the checksum"

set +e
OMRS_OCL_TOKEN="$UPPERCASE_TOKEN" \
  "$SCRIPT" "$DATA_DIR/configuration" "$DATA_DIR/configuration_checksums" \
  >> "$OUTPUT_FILE" 2>&1
uppercase_status=$?
set -e
[[ "$uppercase_status" -eq 78 ]] || fail "an uppercase token was accepted even though OCL tokens are case-sensitive"

# The hook disables inherited/explicit Bash xtrace before it reads the secret.
OMRS_OCL_TOKEN="$TOKEN_A" \
  bash -x "$SCRIPT" "$DATA_DIR/configuration" "$DATA_DIR/configuration_checksums" \
  >> "$OUTPUT_FILE" 2>&1
env SHELLOPTS=xtrace \
  OMRS_OCL_TOKEN="$TOKEN_A" \
  "$SCRIPT" "$DATA_DIR/configuration" "$DATA_DIR/configuration_checksums" \
  >> "$OUTPUT_FILE" 2>&1

# Unexpected duplicate sources fail before changing either source or the
# previously valid runtime override.
write_base_fixture
nested_properties_dir="$PROPERTIES_DIR/nested"
mkdir -p "$nested_properties_dir"
duplicate_file="$nested_properties_dir/duplicate-globalproperties.xml"
cp "$BASE_FILE" "$duplicate_file"
base_before="$(file_digest "$BASE_FILE")"
duplicate_before="$(file_digest "$duplicate_file")"
override_before="$(file_digest "$OVERRIDE_FILE")"
set +e
OMRS_OCL_TOKEN="$TOKEN_B" \
  "$SCRIPT" "$DATA_DIR/configuration" "$DATA_DIR/configuration_checksums" \
  >> "$OUTPUT_FILE" 2>&1
duplicate_status=$?
set -e
[[ "$duplicate_status" -eq 78 ]] || fail "duplicate OCL token sources were accepted"
[[ "$(file_digest "$BASE_FILE")" == "$base_before" ]] || fail "duplicate-source validation changed the base XML"
[[ "$(file_digest "$duplicate_file")" == "$duplicate_before" ]] || fail "duplicate-source validation changed the duplicate XML"
[[ "$(file_digest "$OVERRIDE_FILE")" == "$override_before" ]] || fail "duplicate-source validation changed the prior override"
rm -f "$duplicate_file"
rmdir "$nested_properties_dir"

# A clean start without a token removes the unresolved placeholder but does not
# add an empty override or invalidate a previously stored checksum.
rm -f "$OVERRIDE_FILE"
write_base_fixture
printf '%s\n' stored-token-checksum > "$CHECKSUM_FILE"
run_config ""
assert_contains "$BASE_FILE" '<property>application.name</property>' "the unrelated base property was removed"
assert_not_contains "$BASE_FILE" 'openconceptlab.token' "the copied base XML retained the OCL token property"
assert_not_contains "$BASE_FILE" '${OMRS_OCL_TOKEN}' "the copied base XML retained the placeholder"
[[ ! -e "$OVERRIDE_FILE" ]] || fail "an empty environment created an empty token override"
[[ -e "$CHECKSUM_FILE" ]] || fail "an empty environment invalidated the stored-token checksum"

# A configured token creates a private, lexically-last override and invalidates
# only its checksum so Initializer must apply it.
write_base_fixture
run_config "$TOKEN_A"
[[ -f "$OVERRIDE_FILE" ]] || fail "the runtime OCL override was not created"
[[ "$(file_mode "$OVERRIDE_FILE")" == 600 ]] || fail "the runtime OCL override is not mode 600"
assert_contains "$OVERRIDE_FILE" '<property>openconceptlab.token</property>' "the runtime override lacks the OCL property"
assert_contains "$OVERRIDE_FILE" "<value>${TOKEN_A}</value>" "the runtime override lacks the configured token"
[[ "$(grep -Fc '<property>openconceptlab.token</property>' "$OVERRIDE_FILE")" -eq 1 ]] \
  || fail "the runtime override does not contain exactly one OCL token property"
[[ ! -e "$CHECKSUM_FILE" ]] || fail "the targeted Initializer checksum was not removed"
last_xml="$(find "$PROPERTIES_DIR" -maxdepth 1 -type f -name '*.xml' -exec basename {} \; | LC_ALL=C sort | tail -n 1)"
[[ "$last_xml" == "$(basename "$OVERRIDE_FILE")" ]] || fail "the runtime override is not ordered after content XML"

# A second boot with the same value is byte-idempotent and still forces the
# override after any content XML that Initializer may reload.
override_digest_a="$(file_digest "$OVERRIDE_FILE")"
write_base_fixture
printf '%s\n' stale > "$CHECKSUM_FILE"
run_config "$TOKEN_A"
[[ "$(file_digest "$OVERRIDE_FILE")" == "$override_digest_a" ]] || fail "the same token produced different override bytes"
[[ ! -e "$CHECKSUM_FILE" ]] || fail "the second boot did not invalidate the targeted checksum"

# Rotation replaces A with B without duplicate properties or secret output.
write_base_fixture
printf '%s\n' stale > "$CHECKSUM_FILE"
run_config "$TOKEN_B"
assert_contains "$OVERRIDE_FILE" "<value>${TOKEN_B}</value>" "token rotation did not write the new value"
assert_not_contains "$OVERRIDE_FILE" "$TOKEN_A" "token rotation retained the old value"
[[ "$(grep -Fc '<property>openconceptlab.token</property>' "$OVERRIDE_FILE")" -eq 1 ]] \
  || fail "token rotation duplicated the OCL property"

# Removing the environment value on a later boot removes copied/file-based
# configuration while leaving the database value and checksum unmanaged.
write_base_fixture
printf '%s\n' prior-checksum > "$CHECKSUM_FILE"
run_config ""
[[ ! -e "$OVERRIDE_FILE" ]] || fail "an empty environment retained a file-based token override"
[[ -e "$CHECKSUM_FILE" ]] || fail "an empty environment invalidated the existing database value"
assert_not_contains "$BASE_FILE" 'openconceptlab.token' "the restart restored the unresolved OCL property"

assert_not_contains "$OUTPUT_FILE" "$TOKEN_A" "the first synthetic token leaked to logs"
assert_not_contains "$OUTPUT_FILE" "$TOKEN_B" "the rotated synthetic token leaked to logs"
assert_not_contains "$OUTPUT_FILE" "Token ${TOKEN_A}" "the invalid synthetic credential leaked to logs"
assert_not_contains "$OUTPUT_FILE" "$UPPERCASE_TOKEN" "the uppercase synthetic credential leaked to logs"

echo "[OK] OCL token runtime configuration"
