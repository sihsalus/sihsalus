#!/usr/bin/env bash

set +x
set -euo pipefail

umask 077

fail() {
  echo "[forced-password-config] ERROR: $*" >&2
  exit 78
}

if [[ "$#" -ne 2 ]]; then
  fail "expected the OpenMRS server and runtime properties file paths"
fi

SERVER_PROPERTIES_FILE="$1"
RUNTIME_PROPERTIES_FILE="$2"
OAUTH2_MODE="${OAUTH2_ENABLED:-false}"
FORCED_PASSWORD_CHANGE_ENABLED="${SIHSALUS_FORCED_PASSWORD_CHANGE_ENABLED:-true}"
TEMPORARY_FILE=""

cleanup() {
  [[ -z "$TEMPORARY_FILE" ]] || rm -f "$TEMPORARY_FILE"
}
trap cleanup EXIT

for properties_file in "$SERVER_PROPERTIES_FILE" "$RUNTIME_PROPERTIES_FILE"; do
  case "$properties_file" in
    /*) ;;
    *) fail "OpenMRS properties file paths must be absolute" ;;
  esac
done

case "$OAUTH2_MODE" in
  false | true) ;;
  *) fail "OAUTH2_ENABLED must be exactly true or false" ;;
esac

case "$FORCED_PASSWORD_CHANGE_ENABLED" in
  false | true) ;;
  *) fail "SIHSALUS_FORCED_PASSWORD_CHANGE_ENABLED must be exactly true or false" ;;
esac

if [[ "$OAUTH2_MODE" == "false" && "$FORCED_PASSWORD_CHANGE_ENABLED" == "true" ]]; then
  support_value="true"
  include_password_change_url="true"
else
  # OAuth2 owns the interactive login flow and always takes precedence over the
  # local feature flag. Explicitly writing false also gives local/basic
  # deployments an idempotent rollback path without editing the data volume.
  support_value="false"
  include_password_change_url="false"
fi

if [[ -e "$RUNTIME_PROPERTIES_FILE" || -L "$RUNTIME_PROPERTIES_FILE" ]]; then
  [[ -f "$RUNTIME_PROPERTIES_FILE" && ! -L "$RUNTIME_PROPERTIES_FILE" ]] \
    || fail "the OpenMRS runtime properties path must be a regular file"
  target_file="$RUNTIME_PROPERTIES_FILE"
  property_prefix=""
  target_kind="runtime"
else
  [[ -f "$SERVER_PROPERTIES_FILE" && ! -L "$SERVER_PROPERTIES_FILE" ]] \
    || fail "the OpenMRS server properties path must be a regular file during installation"
  target_file="$SERVER_PROPERTIES_FILE"
  property_prefix="property."
  target_kind="installation"
fi

target_directory="${target_file%/*}"
[[ -d "$target_directory" ]] || fail "the OpenMRS properties directory does not exist"

TEMPORARY_FILE="$(mktemp "${target_directory}/.sihsalus-forced-password.XXXXXX")"

# Remove both installation-prefixed and runtime forms before appending the
# authoritative values. Parsing the Java-properties key (rather than matching
# the full line) also reconciles prior values that used ':' or whitespace as a
# separator. Other properties, including database credentials, remain intact.
awk '
  function property_key(line, normalized, separator) {
    normalized = line
    sub(/^[[:space:]]*/, "", normalized)
    if (normalized == "" || normalized ~ /^[#!]/) {
      return ""
    }
    separator = match(normalized, /[[:space:]=:]/)
    if (separator == 0) {
      return normalized
    }
    return substr(normalized, 1, separator - 1)
  }

  {
    key = property_key($0)
    if (key == "authentication.supportForcedPasswordChange" ||
        key == "authentication.passwordChangeUrl" ||
        key == "property.authentication.supportForcedPasswordChange" ||
        key == "property.authentication.passwordChangeUrl") {
      next
    }
    print
  }
' "$target_file" > "$TEMPORARY_FILE"

support_key="${property_prefix}authentication.supportForcedPasswordChange"
url_key="${property_prefix}authentication.passwordChangeUrl"

printf '%s=%s\n' "$support_key" "$support_value" >> "$TEMPORARY_FILE"
if [[ "$include_password_change_url" == "true" ]]; then
  printf '%s=%s\n' "$url_key" '/admin/users/changePassword.form' >> "$TEMPORARY_FILE"
fi

chmod 0600 "$TEMPORARY_FILE"

[[ "$(grep -Fxc "${support_key}=${support_value}" "$TEMPORARY_FILE" || true)" -eq 1 ]] \
  || fail "could not write the forced-password support property exactly once"

if [[ "$include_password_change_url" == "true" ]]; then
  [[ "$(grep -Fxc "${url_key}=/admin/users/changePassword.form" "$TEMPORARY_FILE" || true)" -eq 1 ]] \
    || fail "could not write the password-change URL property exactly once"
elif grep -qE \
  '^[[:space:]]*(property[.])?authentication[.]passwordChangeUrl([[:space:]=:]|$)' \
  "$TEMPORARY_FILE"; then
  fail "the local password-change URL remained configured in OAuth2 mode"
fi

mv -f "$TEMPORARY_FILE" "$target_file"
TEMPORARY_FILE=""

if [[ "$OAUTH2_MODE" == "true" ]]; then
  echo "[forced-password-config] disabled the local forced-password redirect for OAuth2 authentication"
elif [[ "$FORCED_PASSWORD_CHANGE_ENABLED" == "false" ]]; then
  echo "[forced-password-config] disabled the local forced-password flow by configuration"
else
  echo "[forced-password-config] configured the local forced-password flow for ${target_kind} properties"
fi
