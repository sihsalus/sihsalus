#!/usr/bin/env bash

set -euo pipefail

IMAGE="${1:-sihsalus-backend:ci}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXPECTED_HOOK="${ROOT_DIR}/backend/bin/configure-forced-password-change.sh"
TEMP_DIR="$(mktemp -d)"
CONTAINER_ID=""
SYNTHETIC_SECRET="synthetic-image-db-password-must-not-leak"

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$CONTAINER_ID" ]]; then
    docker rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

CONTAINER_ID="$(docker create "$IMAGE")"
docker cp \
  "${CONTAINER_ID}:/usr/local/bin/configure-forced-password-change.sh" \
  "${TEMP_DIR}/configure-forced-password-change.sh"

[[ -s "${TEMP_DIR}/configure-forced-password-change.sh" ]] \
  || fail "the published forced-password hook is empty"
cmp -s "$EXPECTED_HOOK" "${TEMP_DIR}/configure-forced-password-change.sh" \
  || fail "the published forced-password hook does not match the reviewed source"

set +e
output="$({
  docker run --rm \
    --entrypoint /bin/bash \
    --env "OMRS_CONFIG_CONNECTION_PASSWORD=${SYNTHETIC_SECRET}" \
    "$IMAGE" \
    -ceu '
      hook=/usr/local/bin/configure-forced-password-change.sh
      ocl_hook=/usr/local/bin/configure-ocl-token.sh
      startup=/openmrs/startup-init.sh
      test_root="$(mktemp -d)"
      trap '\''rm -rf "$test_root"'\'' EXIT

      test -x "$hook"
      test -s "$hook"
      test "$(stat -c %a "$hook")" = 555
      test "$(head -n 1 "$hook")" = '\''#!/usr/bin/env bash'\''
      bash -n "$hook"
      test "$(grep -Fc "$hook" "$startup")" -eq 1
      test "$(grep -Fc "$ocl_hook" "$startup")" -eq 1
      test "$(tail -n 1 "$startup")" = '\''/usr/local/bin/configure-forced-password-change.sh "$OMRS_SERVER_PROPERTIES_FILE" "$OMRS_RUNTIME_PROPERTIES_FILE"'\''

      modules=/openmrs/distribution/openmrs_modules
      set -- "$modules"/authentication-*.omod
      test "$#" -eq 1
      test -f "$1"
      set -- "$modules"/legacyui-*.omod
      test "$#" -eq 1
      test -f "$1"

      mkdir -p \
        "$test_root/distribution/openmrs_config" \
        "$test_root/data/configuration" \
        "$test_root/data/configuration_checksums"

      server_properties="$test_root/openmrs-server.properties"
      runtime_properties="$test_root/data/openmrs-runtime.properties"

      # No runtime file means a clean installation. The hook must add the
      # property.* form consumed by OpenMRS InitializationFilter.
      OAUTH2_ENABLED=false \
        SIHSALUS_FORCED_PASSWORD_CHANGE_ENABLED=true \
        OMRS_HOME="$test_root" \
        "$startup"
      test "$(grep -Fxc '\''property.authentication.supportForcedPasswordChange=true'\'' "$server_properties")" -eq 1
      test "$(grep -Fxc '\''property.authentication.passwordChangeUrl=/admin/users/changePassword.form'\'' "$server_properties")" -eq 1
      test ! -e "$runtime_properties"
      test "$(stat -c %a "$server_properties")" = 600

      clean_digest="$(sha256sum "$server_properties" | awk '\''{print $1}'\'')"
      OAUTH2_ENABLED=false \
        SIHSALUS_FORCED_PASSWORD_CHANGE_ENABLED=true \
        OMRS_HOME="$test_root" \
        "$startup"
      test "$(sha256sum "$server_properties" | awk '\''{print $1}'\'')" = "$clean_digest"

      OAUTH2_ENABLED=false \
        SIHSALUS_FORCED_PASSWORD_CHANGE_ENABLED=false \
        OMRS_HOME="$test_root" \
        "$startup"
      test "$(grep -Fxc '\''property.authentication.supportForcedPasswordChange=false'\'' "$server_properties")" -eq 1
      ! grep -qF '\''authentication.passwordChangeUrl'\'' "$server_properties"

      OAUTH2_ENABLED=false \
        SIHSALUS_FORCED_PASSWORD_CHANGE_ENABLED=true \
        OMRS_HOME="$test_root" \
        "$startup"

      # Simulate the runtime file written after installation and prove that a
      # restart updates it without exposing or changing unrelated credentials.
      cat > "$runtime_properties" <<EOF_PROPERTIES
connection.password=${OMRS_CONFIG_CONNECTION_PASSWORD}
authentication.supportForcedPasswordChange=false
authentication.passwordChangeUrl=/stale
EOF_PROPERTIES
      OAUTH2_ENABLED=false \
        SIHSALUS_FORCED_PASSWORD_CHANGE_ENABLED=true \
        OMRS_HOME="$test_root" \
        "$startup"
      test "$(grep -Fxc '\''authentication.supportForcedPasswordChange=true'\'' "$runtime_properties")" -eq 1
      test "$(grep -Fxc '\''authentication.passwordChangeUrl=/admin/users/changePassword.form'\'' "$runtime_properties")" -eq 1
      test "$(grep -Fxc "connection.password=${OMRS_CONFIG_CONNECTION_PASSWORD}" "$runtime_properties")" -eq 1
      test "$(stat -c %a "$runtime_properties")" = 600

      local_digest="$(sha256sum "$runtime_properties" | awk '\''{print $1}'\'')"
      OAUTH2_ENABLED=false \
        SIHSALUS_FORCED_PASSWORD_CHANGE_ENABLED=true \
        OMRS_HOME="$test_root" \
        "$startup"
      test "$(sha256sum "$runtime_properties" | awk '\''{print $1}'\'')" = "$local_digest"

      OAUTH2_ENABLED=false \
        SIHSALUS_FORCED_PASSWORD_CHANGE_ENABLED=false \
        OMRS_HOME="$test_root" \
        "$startup"
      test "$(grep -Fxc '\''authentication.supportForcedPasswordChange=false'\'' "$runtime_properties")" -eq 1
      ! grep -qF '\''authentication.passwordChangeUrl'\'' "$runtime_properties"

      OAUTH2_ENABLED=false \
        SIHSALUS_FORCED_PASSWORD_CHANGE_ENABLED=true \
        OMRS_HOME="$test_root" \
        "$startup"
      test "$(grep -Fxc '\''authentication.supportForcedPasswordChange=true'\'' "$runtime_properties")" -eq 1

      # The same image under the Keycloak override must explicitly disable the
      # local filter and remove its redirect URL, including after mode changes.
      OAUTH2_ENABLED=true \
        SIHSALUS_FORCED_PASSWORD_CHANGE_ENABLED=true \
        OMRS_HOME="$test_root" \
        "$startup"
      test "$(grep -Fxc '\''authentication.supportForcedPasswordChange=false'\'' "$runtime_properties")" -eq 1
      ! grep -qF '\''authentication.passwordChangeUrl'\'' "$runtime_properties"

      oauth_digest="$(sha256sum "$runtime_properties" | awk '\''{print $1}'\'')"
      OAUTH2_ENABLED=true \
        SIHSALUS_FORCED_PASSWORD_CHANGE_ENABLED=false \
        OMRS_HOME="$test_root" \
        "$startup"
      test "$(sha256sum "$runtime_properties" | awk '\''{print $1}'\'')" = "$oauth_digest"

      OAUTH2_ENABLED=false \
        SIHSALUS_FORCED_PASSWORD_CHANGE_ENABLED=true \
        OMRS_HOME="$test_root" \
        "$startup"
      test "$(grep -Fxc '\''authentication.supportForcedPasswordChange=true'\'' "$runtime_properties")" -eq 1
      test "$(grep -Fxc '\''authentication.passwordChangeUrl=/admin/users/changePassword.form'\'' "$runtime_properties")" -eq 1
    '
} 2>&1)"
image_test_status=$?
set -e

if [[ "$image_test_status" -ne 0 ]]; then
  if grep -qF "$SYNTHETIC_SECRET" <<< "$output"; then
    echo "[FAIL] backend forced-password image contract failed; captured output was redacted" >&2
  else
    printf '%s\n' "$output" >&2
  fi
  fail "the backend candidate does not satisfy the forced-password startup contract"
fi

if grep -qF "$SYNTHETIC_SECRET" <<< "$output"; then
  fail "the backend candidate printed the synthetic database password"
fi

echo "[OK] backend image forced-password startup contract"
