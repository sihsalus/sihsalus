#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${ROOT_DIR}/backend/bin/configure-forced-password-change.sh"
FIXTURE_ROOT="$(mktemp -d)"
SERVER_PROPERTIES="${FIXTURE_ROOT}/openmrs-server.properties"
RUNTIME_PROPERTIES="${FIXTURE_ROOT}/data/openmrs-runtime.properties"
OUTPUT_FILE="${FIXTURE_ROOT}/output.log"
SYNTHETIC_SECRET="synthetic-db-password-must-not-leak"

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

assert_exact_line_once() {
  local file="$1"
  local expected="$2"
  local message="$3"
  [[ "$(grep -Fxc "$expected" "$file" || true)" -eq 1 ]] || fail "$message"
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  local message="$3"
  if grep -qF "$unexpected" "$file"; then
    fail "$message"
  fi
}

write_server_fixture() {
  mkdir -p "${RUNTIME_PROPERTIES%/*}"
  cat > "$SERVER_PROPERTIES" <<EOF_PROPERTIES
connection.username=openmrs
connection.password=${SYNTHETIC_SECRET}
property.application.name=SIH SALUS
authentication.supportForcedPasswordChange: false
property.authentication.supportForcedPasswordChange = false
authentication.passwordChangeUrl /stale-runtime-url
property.authentication.passwordChangeUrl=/stale-install-url
EOF_PROPERTIES
}

write_runtime_fixture() {
  cat > "$RUNTIME_PROPERTIES" <<EOF_PROPERTIES
connection.username=openmrs
connection.password=${SYNTHETIC_SECRET}
authentication.supportForcedPasswordChange: false
property.authentication.supportForcedPasswordChange = false
authentication.passwordChangeUrl /stale-runtime-url
property.authentication.passwordChangeUrl=/stale-install-url
EOF_PROPERTIES
}

run_config() {
  local oauth2_enabled="$1"
  local forced_password_change_enabled="${2:-true}"
  OAUTH2_ENABLED="$oauth2_enabled" \
    SIHSALUS_FORCED_PASSWORD_CHANGE_ENABLED="$forced_password_change_enabled" \
    "$SCRIPT" "$SERVER_PROPERTIES" "$RUNTIME_PROPERTIES" \
    >> "$OUTPUT_FILE" 2>&1
}

bash -n "$SCRIPT"

# Invalid mode and path inputs fail before changing either properties file.
write_server_fixture
server_before="$(file_digest "$SERVER_PROPERTIES")"
set +e
OAUTH2_ENABLED="yes" \
  "$SCRIPT" "$SERVER_PROPERTIES" "$RUNTIME_PROPERTIES" \
  >> "$OUTPUT_FILE" 2>&1
invalid_mode_status=$?
OAUTH2_ENABLED="false" \
  SIHSALUS_FORCED_PASSWORD_CHANGE_ENABLED="sometimes" \
  "$SCRIPT" "$SERVER_PROPERTIES" "$RUNTIME_PROPERTIES" \
  >> "$OUTPUT_FILE" 2>&1
invalid_feature_status=$?
OAUTH2_ENABLED="false" \
  SIHSALUS_FORCED_PASSWORD_CHANGE_ENABLED="true" \
  "$SCRIPT" relative-server.properties relative-runtime.properties \
  >> "$OUTPUT_FILE" 2>&1
relative_path_status=$?
set -e
[[ "$invalid_mode_status" -eq 78 ]] || fail "an invalid OAuth2 mode was accepted"
[[ "$invalid_feature_status" -eq 78 ]] || fail "an invalid forced-password feature value was accepted"
[[ "$relative_path_status" -eq 78 ]] || fail "relative properties paths were accepted"
[[ "$(file_digest "$SERVER_PROPERTIES")" == "$server_before" ]] \
  || fail "invalid input changed the installation properties"

# A clean local/basic installation receives the SDK-style property prefix.
run_config false
assert_exact_line_once \
  "$SERVER_PROPERTIES" \
  'property.authentication.supportForcedPasswordChange=true' \
  "clean installation does not enable forced password change"
assert_exact_line_once \
  "$SERVER_PROPERTIES" \
  'property.authentication.passwordChangeUrl=/admin/users/changePassword.form' \
  "clean installation does not use the Legacy UI password-change URL"
assert_not_contains \
  "$SERVER_PROPERTIES" \
  'authentication.passwordChangeUrl /stale-runtime-url' \
  "clean installation retained a stale unprefixed URL"
assert_exact_line_once \
  "$SERVER_PROPERTIES" \
  "connection.password=${SYNTHETIC_SECRET}" \
  "clean installation changed an unrelated secret property"
[[ ! -e "$RUNTIME_PROPERTIES" ]] || fail "clean installation created a fake runtime properties file"
[[ "$(file_mode "$SERVER_PROPERTIES")" == 600 ]] \
  || fail "installation properties are not mode 600"

# Repeating a clean startup is byte-idempotent.
clean_local_digest="$(file_digest "$SERVER_PROPERTIES")"
run_config false
[[ "$(file_digest "$SERVER_PROPERTIES")" == "$clean_local_digest" ]] \
  || fail "repeated clean local startup changed the installation properties"

# The local/basic rollback flag and OAuth2 both explicitly disable the local
# filter and URL on a clean installation.
run_config false false
assert_exact_line_once \
  "$SERVER_PROPERTIES" \
  'property.authentication.supportForcedPasswordChange=false' \
  "clean local rollback did not disable the local filter"
assert_not_contains \
  "$SERVER_PROPERTIES" \
  'authentication.passwordChangeUrl' \
  "clean local rollback retained the local password-change URL"
clean_disabled_digest="$(file_digest "$SERVER_PROPERTIES")"
run_config false false
[[ "$(file_digest "$SERVER_PROPERTIES")" == "$clean_disabled_digest" ]] \
  || fail "repeated clean local rollback changed the installation properties"

run_config true true
assert_exact_line_once \
  "$SERVER_PROPERTIES" \
  'property.authentication.supportForcedPasswordChange=false' \
  "clean OAuth2 installation did not disable the local filter"
assert_not_contains \
  "$SERVER_PROPERTIES" \
  'authentication.passwordChangeUrl' \
  "clean OAuth2 installation retained the local password-change URL"

# Existing installations are reconciled in openmrs-runtime.properties without
# touching the installation file, which contains database credentials.
write_server_fixture
write_runtime_fixture
server_before="$(file_digest "$SERVER_PROPERTIES")"
run_config false
[[ "$(file_digest "$SERVER_PROPERTIES")" == "$server_before" ]] \
  || fail "runtime reconciliation changed the installation properties"
assert_exact_line_once \
  "$RUNTIME_PROPERTIES" \
  'authentication.supportForcedPasswordChange=true' \
  "runtime properties do not enable forced password change"
assert_exact_line_once \
  "$RUNTIME_PROPERTIES" \
  'authentication.passwordChangeUrl=/admin/users/changePassword.form' \
  "runtime properties do not use the Legacy UI password-change URL"
assert_not_contains \
  "$RUNTIME_PROPERTIES" \
  'property.authentication.supportForcedPasswordChange' \
  "runtime properties retained an installation-prefixed support value"
assert_exact_line_once \
  "$RUNTIME_PROPERTIES" \
  "connection.password=${SYNTHETIC_SECRET}" \
  "runtime reconciliation changed an unrelated secret property"
[[ "$(file_mode "$RUNTIME_PROPERTIES")" == 600 ]] \
  || fail "runtime properties are not mode 600"

runtime_local_digest="$(file_digest "$RUNTIME_PROPERTIES")"
run_config false
[[ "$(file_digest "$RUNTIME_PROPERTIES")" == "$runtime_local_digest" ]] \
  || fail "repeated local restart changed the runtime properties"

# The feature flag provides a local/basic rollback without mutating the volume
# manually. OAuth2 must also disable the flow even when the flag remains true.
run_config false false
assert_exact_line_once \
  "$RUNTIME_PROPERTIES" \
  'authentication.supportForcedPasswordChange=false' \
  "local rollback did not disable the runtime filter"
assert_not_contains \
  "$RUNTIME_PROPERTIES" \
  'authentication.passwordChangeUrl' \
  "local rollback retained the runtime password-change URL"
runtime_disabled_digest="$(file_digest "$RUNTIME_PROPERTIES")"
run_config false false
[[ "$(file_digest "$RUNTIME_PROPERTIES")" == "$runtime_disabled_digest" ]] \
  || fail "repeated local rollback changed the runtime properties"

run_config false true
assert_exact_line_once \
  "$RUNTIME_PROPERTIES" \
  'authentication.supportForcedPasswordChange=true' \
  "re-enabling the local feature did not restore the runtime filter"

run_config true true
assert_exact_line_once \
  "$RUNTIME_PROPERTIES" \
  'authentication.supportForcedPasswordChange=false' \
  "OAuth2 switch did not disable the local filter"
assert_not_contains \
  "$RUNTIME_PROPERTIES" \
  'authentication.passwordChangeUrl' \
  "OAuth2 switch retained the local password-change URL"
runtime_oauth_digest="$(file_digest "$RUNTIME_PROPERTIES")"
run_config true false
[[ "$(file_digest "$RUNTIME_PROPERTIES")" == "$runtime_oauth_digest" ]] \
  || fail "OAuth2 behavior changed when the local feature flag was false"

run_config false
assert_exact_line_once \
  "$RUNTIME_PROPERTIES" \
  'authentication.supportForcedPasswordChange=true' \
  "switching back to local authentication did not re-enable the filter"
assert_exact_line_once \
  "$RUNTIME_PROPERTIES" \
  'authentication.passwordChangeUrl=/admin/users/changePassword.form' \
  "switching back to local authentication did not restore the URL"

# A hostile symlink is rejected without changing its target.
symlink_target="${FIXTURE_ROOT}/symlink-target.properties"
printf '%s\n' 'keep=true' > "$symlink_target"
rm -f "$RUNTIME_PROPERTIES"
ln -s "$symlink_target" "$RUNTIME_PROPERTIES"
target_before="$(file_digest "$symlink_target")"
set +e
OAUTH2_ENABLED="false" \
  "$SCRIPT" "$SERVER_PROPERTIES" "$RUNTIME_PROPERTIES" \
  >> "$OUTPUT_FILE" 2>&1
symlink_status=$?
set -e
[[ "$symlink_status" -eq 78 ]] || fail "a symlinked runtime properties file was accepted"
[[ "$(file_digest "$symlink_target")" == "$target_before" ]] \
  || fail "a rejected symlink changed its target"

rm -f "$symlink_target"
set +e
OAUTH2_ENABLED="false" \
  "$SCRIPT" "$SERVER_PROPERTIES" "$RUNTIME_PROPERTIES" \
  >> "$OUTPUT_FILE" 2>&1
broken_symlink_status=$?
set -e
[[ "$broken_symlink_status" -eq 78 ]] || fail "a broken runtime properties symlink was accepted"

assert_not_contains "$OUTPUT_FILE" "$SYNTHETIC_SECRET" "a synthetic database secret leaked to logs"

# The distribution must keep the two reviewed modules that implement the
# filter and its Legacy UI destination in both demo and no-demo packages.
python3 - \
  "${ROOT_DIR}/backend/pom.xml" \
  "${ROOT_DIR}/backend/distro.properties" \
  "${ROOT_DIR}/backend/distro-no-demo.properties" <<'PY'
import pathlib
import sys
import xml.etree.ElementTree as ET


def fail(message):
    raise SystemExit(f"[FAIL] {message}")


pom_path = pathlib.Path(sys.argv[1])
namespace = {"m": "http://maven.apache.org/POM/4.0.0"}
root = ET.parse(pom_path).getroot()

dependencies = [
    (
        dependency.findtext("m:groupId", namespaces=namespace),
        dependency.findtext("m:artifactId", namespaces=namespace),
        dependency.findtext("m:scope", namespaces=namespace),
    )
    for dependency in root.findall("m:dependencies/m:dependency", namespace)
]

for artifact in ("authentication-omod", "legacyui-omod"):
    matches = [
        dependency
        for dependency in dependencies
        if dependency == ("org.openmrs.module", artifact, "provided")
    ]
    if len(matches) != 1:
        fail(f"backend/pom.xml must include one provided {artifact} dependency")

expected_distro_lines = {
    "omod.authentication=${authentication.version}",
    "omod.legacyui=${legacyui.version}",
}
for distro_path_string in sys.argv[2:]:
    distro_path = pathlib.Path(distro_path_string)
    lines = {
        line.strip()
        for line in distro_path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }
    missing = expected_distro_lines - lines
    if missing:
        fail(f"{distro_path.name} is missing required modules: {sorted(missing)}")
PY

echo "[OK] forced-password runtime configuration and module contract"
