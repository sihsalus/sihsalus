#!/usr/bin/env bash

set -euo pipefail

IMAGE="${1:-sihsalus-backend:ci}"
TOKEN="$(printf 'c%.0s' {1..40})"

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

[[ "$(docker image inspect --format '{{.Config.User}}' "$IMAGE")" == 1001 ]] \
  || fail "the backend candidate no longer runs as UID 1001"
[[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$IMAGE")" == '["/usr/bin/tini","--"]' ]] \
  || fail "the backend candidate no longer preserves the upstream Tini entrypoint"

set +e
output="$({
  docker run --rm \
    --entrypoint /bin/bash \
    --env "OMRS_OCL_TOKEN=${TOKEN}" \
    "$IMAGE" \
    -ceu '
      hook=/usr/local/bin/configure-ocl-token.sh
      startup=/openmrs/startup-init.sh
      test_root="$(mktemp -d)"
      trap '\''rm -rf "$test_root"'\'' EXIT

      test -x "$hook"
      test "$(grep -Fc "$hook" "$startup")" -eq 1
      test "$(tail -n 1 "$startup")" = '\''/usr/local/bin/configure-ocl-token.sh "$OMRS_CONFIG_DIR" "$OMRS_DATA_DIR/configuration_checksums"'\''

      distribution_properties="$test_root/distribution/openmrs_config/globalproperties"
      data_properties="$test_root/data/configuration/globalproperties"
      mkdir -p \
        "$distribution_properties" \
        "$test_root/data/configuration" \
        "$test_root/data/configuration_checksums"
      cat > "$distribution_properties/globalproperties-sihsalus.xml" <<'\''EOF_XML'\''
<config>
  <globalProperties>
    <globalProperty>
      <property>openconceptlab.token</property>
      <value>${OMRS_OCL_TOKEN}</value>
    </globalProperty>
  </globalProperties>
</config>
EOF_XML
      OMRS_HOME="$test_root" "$startup"

      override="$data_properties/zz-runtime-ocl-token.xml"
      test -f "$override"
      test "$(stat -c %a "$override")" = 600
      grep -qF "<value>${OMRS_OCL_TOKEN}</value>" "$override"
      ! grep -RqF '\''${OMRS_OCL_TOKEN}'\'' "$data_properties"

      invalid_log="$test_root/invalid-startup.log"
      set +e
      OMRS_HOME="$test_root" \
        OMRS_OCL_TOKEN="Token ${OMRS_OCL_TOKEN}" \
        "$startup" > "$invalid_log" 2>&1
      invalid_status=$?
      set -e
      test "$invalid_status" -eq 78
      ! grep -qF "$OMRS_OCL_TOKEN" "$invalid_log"
    '
} 2>&1)"
image_test_status=$?
set -e

if [[ "$image_test_status" -ne 0 ]]; then
  if grep -qF "$TOKEN" <<< "$output"; then
    echo "[FAIL] backend image contract failed; captured output was redacted" >&2
  else
    printf '%s\n' "$output" >&2
  fi
  fail "the backend candidate does not satisfy the OCL startup contract"
fi

if grep -qF "$TOKEN" <<< "$output"; then
  fail "the backend candidate printed the synthetic OCL token"
fi

echo "[OK] backend image OCL token contract"
