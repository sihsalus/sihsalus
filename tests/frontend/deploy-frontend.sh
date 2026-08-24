#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/deploy-frontend.yml"
REMOTE_RUNNER="$ROOT/scripts/deploy/run-redeploy-remote.sh"
EXTERNAL_VERIFIER="$ROOT/scripts/deploy/verify-external-frontend.sh"
EXTERNAL_VERIFIER_TEST="$ROOT/tests/deploy/verify-external-frontend-test.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

bash -n "$REMOTE_RUNNER"
bash -n "$EXTERNAL_VERIFIER"
bash -n "$EXTERNAL_VERIFIER_TEST"
[ "$(grep -Fc 'REDEPLOY_SCRIPT_PATH=scripts/deploy/deploy-frontend.sh' "$WORKFLOW")" -eq 2 ]
[ "$(grep -Fc 'REDEPLOY_EXPECTED_REMOTE_MAC:' "$WORKFLOW")" -eq 2 ]
[ "$(grep -Fc 'REDEPLOY_EXPECTED_NODE_ID:' "$WORKFLOW")" -eq 2 ]
[ "$(grep -Fc 'scripts/deploy/verify-external-frontend.sh' "$WORKFLOW")" -eq 4 ]
grep -Fq 'Verify DEV externally' "$WORKFLOW"
grep -Fq 'Verify QLTY externally' "$WORKFLOW"
grep -Fq 'https://gidis-hsc-dev.inf.pucp.edu.pe' "$WORKFLOW"
grep -Fq 'https://gidis-hsc-qlty.inf.pucp.edu.pe' "$WORKFLOW"
grep -Fq "REDEPLOY_EXPECTED_REMOTE_MAC: '00:0c:29:ad:be:90'" "$WORKFLOW"
grep -Fq "REDEPLOY_EXPECTED_REMOTE_MAC: '00:0c:29:1c:f7:78'" "$WORKFLOW"
grep -Fq "REDEPLOY_EXPECTED_NODE_ID: '3eb58bb0-ff08-4e2d-839c-11cedca0b043'" "$WORKFLOW"
grep -Fq "REDEPLOY_EXPECTED_NODE_ID: '0cefb0c8-c860-48c5-856f-408594775cbb'" "$WORKFLOW"
if grep -Fq 'actual_sha=' "$WORKFLOW"; then
  echo "frontend workflow still trusts a single external build-info response" >&2
  exit 1
fi
if grep -Fq '<scripts/deploy/deploy-frontend.sh' "$WORKFLOW"; then
  echo "frontend workflow still streams a long deployment over one SSH session" >&2
  exit 1
fi

OLD_SHA='1111111111111111111111111111111111111111'
TARGET_SHA='2222222222222222222222222222222222222222'
BAD_SHA='3333333333333333333333333333333333333333'
OLD_DIGEST='sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
TARGET_DIGEST='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
SOURCE_REPOSITORY='ghcr.io/sihsalus/sihsalus-frontend'
TARGET_SOURCE_IMAGE="${SOURCE_REPOSITORY}@${TARGET_DIGEST}"
TARGET_RUNTIME_TAG="digest-${TARGET_DIGEST#sha256:}"
TARGET_RUNTIME_IMAGE="sihsalus-frontend-runtime:${TARGET_RUNTIME_TAG}"
TARGET_SOURCE_ID='sha256:target-source-image'
TARGET_RUNTIME_ID='sha256:target-runtime-image'
OLD_SOURCE_ID='sha256:old-source-image'
OLD_RUNTIME_ID='sha256:old-runtime-image'
STALE_SOURCE_ID='sha256:stale-source-image'
STALE_RUNTIME_ID='sha256:stale-runtime-image'
OLD_NODE_ID='00000000-0000-4000-8000-000000000001'
NODE_ID='00000000-0000-4000-8000-000000000002'

make_fixture() {
  local fixture="$1"
  mkdir -p "$fixture/bin" "$fixture/state"
  touch "$fixture/docker-compose.yml"
  cat >"$fixture/.env" <<EOF
FRONTEND_SOURCE_IMAGE=${SOURCE_REPOSITORY}@${OLD_DIGEST}
FRONTEND_SOURCE_TAG=sha-${OLD_SHA}
FRONTEND_RUNTIME_TAG=sha-${OLD_SHA}
SIHSALUS_NODE_ID=${OLD_NODE_ID}
EOF
  printf '%s\n' "$OLD_SHA" >"$fixture/state/deployed_sha"
  printf '%s\n' "$TARGET_SHA" >"$fixture/state/source_sha"
  printf '%s\n' "healthy" >"$fixture/state/health"
  printf '%s\n' "sihsalus-frontend-runtime:sha-${OLD_SHA}" >"$fixture/state/image"
  printf '%s\n' "$OLD_NODE_ID" >"$fixture/state/node_id"
  printf '%s\n' "$OLD_SOURCE_ID" "$TARGET_SOURCE_ID" "$STALE_SOURCE_ID" >"$fixture/state/source_image_ids"
  printf '%s\n' "$OLD_RUNTIME_ID" "$TARGET_RUNTIME_ID" "$STALE_RUNTIME_ID" >"$fixture/state/runtime_image_ids"

  cat >"$fixture/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >>"${FAKE_STATE_DIR}/commands"
if [ "$*" = 'status --porcelain=v1 --untracked-files=no' ] &&
  [ "${FAKE_TRACKED_DRIFT:-false}" = true ]; then
  printf '%s\n' ' M compose/fua.yml'
fi
EOF

  cat >"$fixture/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >>"${FAKE_STATE_DIR}/commands"

case "${1:-}" in
  image)
    case "${2:-}" in
      inspect)
        if [[ "$*" == *'org.opencontainers.image.revision'* ]]; then
          cat "${FAKE_STATE_DIR}/source_sha"
        elif [[ "$*" == *'{{.Id}}'* ]]; then
          case "${3:-}" in
            "${FAKE_TARGET_SOURCE_IMAGE}")
              printf '%s\n' "${FAKE_TARGET_SOURCE_ID}"
              ;;
            "${FAKE_TARGET_RUNTIME_IMAGE}")
              printf '%s\n' "${FAKE_TARGET_RUNTIME_ID}"
              ;;
            *)
              echo "unexpected image inspection: $*" >&2
              exit 88
              ;;
          esac
        else
          echo "unexpected image inspection: $*" >&2
          exit 88
        fi
        ;;
      ls)
        case "${3:-}" in
          "${FAKE_SOURCE_REPOSITORY}")
            cat "${FAKE_STATE_DIR}/source_image_ids"
            ;;
          sihsalus-frontend-runtime)
            cat "${FAKE_STATE_DIR}/runtime_image_ids"
            ;;
          *)
            echo "unexpected image repository listing: $*" >&2
            exit 88
            ;;
        esac
        ;;
      rm)
        if [ "${FAKE_FAIL_CLEANUP:-false}" = true ]; then
          exit 73
        fi
        ;;
      *)
        echo "unexpected docker image command: $*" >&2
        exit 89
        ;;
    esac
    ;;
  exec)
    printf '{\n  "gitSha": "%s"\n}\n' "$(cat "${FAKE_STATE_DIR}/deployed_sha")"
    ;;
  inspect)
    if [[ "$*" == *'org.sihsalus.node-id'* ]]; then
      cat "${FAKE_STATE_DIR}/node_id"
    elif [[ "$*" == *'.Config.Image'* ]]; then
      cat "${FAKE_STATE_DIR}/image"
    else
      cat "${FAKE_STATE_DIR}/health"
    fi
    ;;
  pull)
    ;;
  compose)
    case "${2:-}" in
      config)
        ;;
      build)
        if [ "${FAKE_FAIL_BUILD:-false}" = true ]; then
          exit 42
        fi
        ;;
      up)
        runtime_tag="$(awk -F= '$1 == "FRONTEND_RUNTIME_TAG" { print $2 }' .env)"
        deployed_sha="${runtime_tag#sha-}"
        if [ "$runtime_tag" = "${FAKE_TARGET_RUNTIME_TAG}" ]; then
          deployed_sha="${FAKE_TARGET_SHA}"
        fi
        if [ "${FAKE_BAD_DEPLOY_SHA:-false}" = true ] &&
          [ "$runtime_tag" = "${FAKE_TARGET_RUNTIME_TAG}" ]; then
          deployed_sha="${FAKE_BAD_SHA}"
        fi
        printf '%s\n' "$deployed_sha" >"${FAKE_STATE_DIR}/deployed_sha"
        printf '%s\n' "healthy" >"${FAKE_STATE_DIR}/health"
        printf '%s\n' "sihsalus-frontend-runtime:${runtime_tag}" >"${FAKE_STATE_DIR}/image"
        awk -F= '$1 == "SIHSALUS_NODE_ID" { print $2 }' .env >"${FAKE_STATE_DIR}/node_id"
        ;;
      *)
        echo "unexpected docker compose command: $*" >&2
        exit 90
        ;;
    esac
    ;;
  *)
    echo "unexpected docker command: $*" >&2
    exit 91
    ;;
esac
EOF

  chmod +x "$fixture/bin/docker" "$fixture/bin/git"
}

install_low_disk_df() {
  local fixture="$1"
  cat >"$fixture/bin/df" <<'EOF_DF'
#!/usr/bin/env bash
printf 'Filesystem 1048576-blocks Used Available Capacity Mounted on\n'
printf '/dev/fake 46080 45568 512 99%% /\n'
EOF_DF
  chmod +x "$fixture/bin/df"
}

configure_healthy_target() {
  local fixture="$1"
  sed -i.bak "s/${OLD_SHA}/${TARGET_SHA}/g" "$fixture/.env"
  sed -i.bak "s/${OLD_DIGEST}/${TARGET_DIGEST}/g" "$fixture/.env"
  sed -i.bak "s/FRONTEND_RUNTIME_TAG=sha-${TARGET_SHA}/FRONTEND_RUNTIME_TAG=${TARGET_RUNTIME_TAG}/" "$fixture/.env"
  sed -i.bak "s/${OLD_NODE_ID}/${NODE_ID}/" "$fixture/.env"
  rm -f "$fixture/.env.bak"
  printf '%s\n' "$TARGET_SHA" >"$fixture/state/deployed_sha"
  printf '%s\n' "sihsalus-frontend-runtime:${TARGET_RUNTIME_TAG}" >"$fixture/state/image"
  printf '%s\n' "$NODE_ID" >"$fixture/state/node_id"
}

run_deploy() {
  local fixture="$1"
  (
    cd "$fixture"
    PATH="$fixture/bin:$PATH" \
      FAKE_STATE_DIR="$fixture/state" \
      FAKE_TARGET_RUNTIME_TAG="$TARGET_RUNTIME_TAG" \
      FAKE_TARGET_RUNTIME_IMAGE="$TARGET_RUNTIME_IMAGE" \
      FAKE_TARGET_SOURCE_IMAGE="$TARGET_SOURCE_IMAGE" \
      FAKE_TARGET_RUNTIME_ID="$TARGET_RUNTIME_ID" \
      FAKE_TARGET_SOURCE_ID="$TARGET_SOURCE_ID" \
      FAKE_SOURCE_REPOSITORY="$SOURCE_REPOSITORY" \
      FAKE_TARGET_SHA="$TARGET_SHA" \
      FAKE_BAD_SHA="$BAD_SHA" \
      SIHSALUS_NODE_ID="$NODE_ID" \
      "$ROOT/scripts/deploy/deploy-frontend.sh" "$TARGET_SHA" "$TARGET_DIGEST"
  )
}

assert_scoped_image_cleanup() {
  local commands="$1"

  grep -Fqx "docker image ls ${SOURCE_REPOSITORY} --quiet --no-trunc" "$commands"
  grep -Fqx "docker image ls sihsalus-frontend-runtime --quiet --no-trunc" "$commands"

  grep -Fqx "docker image rm ${OLD_SOURCE_ID}" "$commands"
  grep -Fqx "docker image rm ${STALE_SOURCE_ID}" "$commands"
  grep -Fqx "docker image rm ${OLD_RUNTIME_ID}" "$commands"
  grep -Fqx "docker image rm ${STALE_RUNTIME_ID}" "$commands"

  if grep -Fqx "docker image rm ${TARGET_SOURCE_ID}" "$commands" ||
    grep -Fqx "docker image rm ${TARGET_RUNTIME_ID}" "$commands"; then
    echo "cleanup attempted to remove an active frontend image" >&2
    exit 1
  fi

  if grep -Eq '^docker image prune( |$)' "$commands"; then
    echo "cleanup attempted a global image prune" >&2
    exit 1
  fi

  if grep '^docker image ls ' "$commands" |
    grep -Fvx "docker image ls ${SOURCE_REPOSITORY} --quiet --no-trunc" |
    grep -Fvx "docker image ls sihsalus-frontend-runtime --quiet --no-trunc"; then
    echo "cleanup enumerated images outside the frontend repositories" >&2
    exit 1
  fi

  if grep '^docker image rm ' "$commands" |
    grep -Fvx "docker image rm ${OLD_SOURCE_ID}" |
    grep -Fvx "docker image rm ${STALE_SOURCE_ID}" |
    grep -Fvx "docker image rm ${OLD_RUNTIME_ID}" |
    grep -Fvx "docker image rm ${STALE_RUNTIME_ID}"; then
    echo "cleanup attempted to remove an unexpected image" >&2
    exit 1
  fi
}

assert_value() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [ "$actual" != "$expected" ]; then
    echo "$message: expected '$expected', got '$actual'" >&2
    exit 1
  fi
}

assert_frontend_only_mutations() {
  local commands="$1"
  local expected_build='docker compose build --pull frontend'
  local expected_up='docker compose up -d --no-deps --no-build --pull never --force-recreate frontend'
  local expected_pull="docker pull ${TARGET_SOURCE_IMAGE}"

  if grep -Eq '^docker compose (pull|down|stop|restart)( |$)' "$commands"; then
    echo "deployment attempted a stack-wide or unrelated compose mutation" >&2
    exit 1
  fi

  if grep '^docker compose build' "$commands" | grep -Fvx "$expected_build"; then
    echo "deployment attempted to build a service other than frontend" >&2
    exit 1
  fi

  if grep '^docker compose up' "$commands" | grep -Fvx "$expected_up"; then
    echo "deployment attempted to recreate a service other than frontend" >&2
    exit 1
  fi

  if grep '^docker pull' "$commands" | grep -Fvx "$expected_pull"; then
    echo "deployment pulled an image other than the frontend source digest" >&2
    exit 1
  fi
}

invalid_fixture="$TEST_ROOT/invalid-input"
make_fixture "$invalid_fixture"
if (
  cd "$invalid_fixture"
  PATH="$invalid_fixture/bin:$PATH" \
    FAKE_STATE_DIR="$invalid_fixture/state" \
    "$ROOT/scripts/deploy/deploy-frontend.sh" "not-a-sha" "$TARGET_DIGEST"
); then
  echo "deployment should have rejected an invalid SHA" >&2
  exit 1
fi
if (
  cd "$invalid_fixture"
  PATH="$invalid_fixture/bin:$PATH" \
    FAKE_STATE_DIR="$invalid_fixture/state" \
    "$ROOT/scripts/deploy/deploy-frontend.sh" "$TARGET_SHA" "not-a-digest"
); then
  echo "deployment should have rejected an invalid image digest" >&2
  exit 1
fi
if [ -e "$invalid_fixture/state/commands" ]; then
  echo "invalid input unexpectedly invoked a deployment command" >&2
  exit 1
fi

dirty_fixture="$TEST_ROOT/dirty-checkout"
make_fixture "$dirty_fixture"
if dirty_output="$(
  cd "$dirty_fixture"
  PATH="$dirty_fixture/bin:$PATH" \
    FAKE_STATE_DIR="$dirty_fixture/state" \
    FAKE_TRACKED_DRIFT=true \
    SIHSALUS_NODE_ID="$NODE_ID" \
    "$ROOT/scripts/deploy/deploy-frontend.sh" "$TARGET_SHA" "$TARGET_DIGEST" 2>&1
)"; then
  echo "deployment should have rejected tracked local changes" >&2
  exit 1
fi
grep -Fq 'compose/fua.yml' <<<"$dirty_output"
grep -Fq 'move these changes to a pull request' <<<"$dirty_output"
if grep -Eq '^docker |^git (fetch|merge)' "$dirty_fixture/state/commands"; then
  echo "dirty checkout was mutated before deployment stopped" >&2
  exit 1
fi

noop_fixture="$TEST_ROOT/noop"
make_fixture "$noop_fixture"
configure_healthy_target "$noop_fixture"
run_deploy "$noop_fixture"
if grep -Eq 'docker (pull|compose build|compose up)' "$noop_fixture/state/commands"; then
  echo "idempotent deployment unexpectedly changed the frontend" >&2
  exit 1
fi
assert_scoped_image_cleanup "$noop_fixture/state/commands"

low_disk_noop_fixture="$TEST_ROOT/low-disk-noop"
make_fixture "$low_disk_noop_fixture"
configure_healthy_target "$low_disk_noop_fixture"
install_low_disk_df "$low_disk_noop_fixture"
run_deploy "$low_disk_noop_fixture"
if grep -Eq 'docker (pull|compose build|compose up)' "$low_disk_noop_fixture/state/commands"; then
  echo "low-disk idempotent deployment unexpectedly changed the frontend" >&2
  exit 1
fi
assert_scoped_image_cleanup "$low_disk_noop_fixture/state/commands"

success_fixture="$TEST_ROOT/success"
make_fixture "$success_fixture"
run_deploy "$success_fixture"
assert_value "$TARGET_SOURCE_IMAGE" \
  "$(awk -F= '$1 == "FRONTEND_SOURCE_IMAGE" { print $2 }' "$success_fixture/.env")" \
  "source image digest was not pinned"
assert_value "sha-${TARGET_SHA}" \
  "$(awk -F= '$1 == "FRONTEND_SOURCE_TAG" { print $2 }' "$success_fixture/.env")" \
  "source tag was not updated"
assert_value "$TARGET_RUNTIME_TAG" \
  "$(awk -F= '$1 == "FRONTEND_RUNTIME_TAG" { print $2 }' "$success_fixture/.env")" \
  "runtime tag was not pinned to the source digest"
assert_value "$NODE_ID" \
  "$(awk -F= '$1 == "SIHSALUS_NODE_ID" { print $2 }' "$success_fixture/.env")" \
  "node identity was not persisted"
assert_value "$TARGET_SHA" \
  "$(cat "$success_fixture/state/deployed_sha")" \
  "deployed SHA was not updated"
assert_value "$NODE_ID" \
  "$(cat "$success_fixture/state/node_id")" \
  "deployed wrapper did not contain the expected node identity"
grep -Fqx "docker pull ${TARGET_SOURCE_IMAGE}" "$success_fixture/state/commands"
grep -Fqx \
  "docker image inspect ${TARGET_SOURCE_IMAGE} --format {{index .Config.Labels \"org.opencontainers.image.revision\"}}" \
  "$success_fixture/state/commands"
grep -q 'docker compose build --pull frontend' "$success_fixture/state/commands"
grep -q 'docker compose up -d --no-deps --no-build --pull never --force-recreate frontend' "$success_fixture/state/commands"
assert_frontend_only_mutations "$success_fixture/state/commands"
assert_scoped_image_cleanup "$success_fixture/state/commands"

cleanup_warning_fixture="$TEST_ROOT/cleanup-warning"
make_fixture "$cleanup_warning_fixture"
if ! (
  cd "$cleanup_warning_fixture"
  PATH="$cleanup_warning_fixture/bin:$PATH" \
    FAKE_STATE_DIR="$cleanup_warning_fixture/state" \
    FAKE_TARGET_RUNTIME_TAG="$TARGET_RUNTIME_TAG" \
    FAKE_TARGET_RUNTIME_IMAGE="$TARGET_RUNTIME_IMAGE" \
    FAKE_TARGET_SOURCE_IMAGE="$TARGET_SOURCE_IMAGE" \
    FAKE_TARGET_RUNTIME_ID="$TARGET_RUNTIME_ID" \
    FAKE_TARGET_SOURCE_ID="$TARGET_SOURCE_ID" \
    FAKE_SOURCE_REPOSITORY="$SOURCE_REPOSITORY" \
    FAKE_TARGET_SHA="$TARGET_SHA" \
    FAKE_BAD_SHA="$BAD_SHA" \
    FAKE_FAIL_CLEANUP=true \
    SIHSALUS_NODE_ID="$NODE_ID" \
    "$ROOT/scripts/deploy/deploy-frontend.sh" "$TARGET_SHA" "$TARGET_DIGEST"
); then
  echo "best-effort cleanup should not invalidate a verified deployment" >&2
  exit 1
fi
assert_value "$TARGET_SHA" \
  "$(cat "$cleanup_warning_fixture/state/deployed_sha")" \
  "cleanup warning invalidated the healthy frontend"
assert_scoped_image_cleanup "$cleanup_warning_fixture/state/commands"

source_mismatch_fixture="$TEST_ROOT/source-mismatch"
make_fixture "$source_mismatch_fixture"
printf '%s\n' "$BAD_SHA" >"$source_mismatch_fixture/state/source_sha"
if run_deploy "$source_mismatch_fixture"; then
  echo "deployment should have rejected a digest with a different source revision" >&2
  exit 1
fi
if grep -Eq '^docker compose (build|up)' "$source_mismatch_fixture/state/commands"; then
  echo "source mismatch unexpectedly built or recreated frontend" >&2
  exit 1
fi
assert_frontend_only_mutations "$source_mismatch_fixture/state/commands"

rollback_fixture="$TEST_ROOT/rollback"
make_fixture "$rollback_fixture"
if (
  cd "$rollback_fixture"
  PATH="$rollback_fixture/bin:$PATH" \
    FAKE_STATE_DIR="$rollback_fixture/state" \
      FAKE_TARGET_RUNTIME_TAG="$TARGET_RUNTIME_TAG" \
      FAKE_TARGET_RUNTIME_IMAGE="$TARGET_RUNTIME_IMAGE" \
      FAKE_TARGET_SOURCE_IMAGE="$TARGET_SOURCE_IMAGE" \
      FAKE_TARGET_RUNTIME_ID="$TARGET_RUNTIME_ID" \
      FAKE_TARGET_SOURCE_ID="$TARGET_SOURCE_ID" \
      FAKE_SOURCE_REPOSITORY="$SOURCE_REPOSITORY" \
      FAKE_TARGET_SHA="$TARGET_SHA" \
      FAKE_BAD_SHA="$BAD_SHA" \
      FAKE_FAIL_BUILD=true \
      SIHSALUS_NODE_ID="$NODE_ID" \
    "$ROOT/scripts/deploy/deploy-frontend.sh" "$TARGET_SHA" "$TARGET_DIGEST"
); then
  echo "deployment should have failed when the runtime build failed" >&2
  exit 1
fi
assert_value "sha-${OLD_SHA}" \
  "$(awk -F= '$1 == "FRONTEND_SOURCE_TAG" { print $2 }' "$rollback_fixture/.env")" \
  "rollback did not restore the source tag"
assert_value "$OLD_SHA" \
  "$(cat "$rollback_fixture/state/deployed_sha")" \
  "rollback did not restore the previous frontend"
if grep -q '^docker compose up' "$rollback_fixture/state/commands"; then
  echo "build failure unexpectedly recreated the healthy frontend" >&2
  exit 1
fi
assert_frontend_only_mutations "$rollback_fixture/state/commands"

verification_fixture="$TEST_ROOT/verification-rollback"
make_fixture "$verification_fixture"
if (
  cd "$verification_fixture"
  PATH="$verification_fixture/bin:$PATH" \
    FAKE_STATE_DIR="$verification_fixture/state" \
      FAKE_TARGET_RUNTIME_TAG="$TARGET_RUNTIME_TAG" \
      FAKE_TARGET_RUNTIME_IMAGE="$TARGET_RUNTIME_IMAGE" \
      FAKE_TARGET_SOURCE_IMAGE="$TARGET_SOURCE_IMAGE" \
      FAKE_TARGET_RUNTIME_ID="$TARGET_RUNTIME_ID" \
      FAKE_TARGET_SOURCE_ID="$TARGET_SOURCE_ID" \
      FAKE_SOURCE_REPOSITORY="$SOURCE_REPOSITORY" \
      FAKE_TARGET_SHA="$TARGET_SHA" \
      FAKE_BAD_SHA="$BAD_SHA" \
      FAKE_BAD_DEPLOY_SHA=true \
      SIHSALUS_NODE_ID="$NODE_ID" \
    "$ROOT/scripts/deploy/deploy-frontend.sh" "$TARGET_SHA" "$TARGET_DIGEST"
); then
  echo "deployment should have failed when runtime verification failed" >&2
  exit 1
fi
assert_value "${SOURCE_REPOSITORY}@${OLD_DIGEST}" \
  "$(awk -F= '$1 == "FRONTEND_SOURCE_IMAGE" { print $2 }' "$verification_fixture/.env")" \
  "verification rollback did not restore the source digest"
assert_value "$OLD_SHA" \
  "$(cat "$verification_fixture/state/deployed_sha")" \
  "verification rollback did not restore the previous frontend"
assert_value "2" \
  "$(grep -c '^docker compose up -d --no-deps --no-build --pull never --force-recreate frontend$' "$verification_fixture/state/commands")" \
  "verification rollback did not recreate only the new and previous frontend"
assert_frontend_only_mutations "$verification_fixture/state/commands"

rendered_frontend="$(
  cd "$ROOT"
  FRONTEND_SOURCE_IMAGE="$TARGET_SOURCE_IMAGE" \
    FRONTEND_RUNTIME_TAG="$TARGET_RUNTIME_TAG" \
    SIHSALUS_NODE_ID="$NODE_ID" \
    docker compose config --format json
)"
assert_value "$TARGET_SOURCE_IMAGE" \
  "$(jq -r '.services.frontend.build.args.FRONTEND_SOURCE_IMAGE' <<<"$rendered_frontend")" \
  "Compose did not pass the immutable digest to the frontend build"
assert_value "sihsalus-frontend-runtime:${TARGET_RUNTIME_TAG}" \
  "$(jq -r '.services.frontend.image' <<<"$rendered_frontend")" \
  "Compose did not assign the digest-derived runtime tag"
assert_value "$NODE_ID" \
  "$(jq -r '.services.frontend.build.args.SIHSALUS_NODE_ID' <<<"$rendered_frontend")" \
  "Compose did not pass the node identity to the frontend build"
grep -Fq 'X-SIHSALUS-Node-ID "__SIHSALUS_NODE_ID__"' "$ROOT/frontend/nginx.conf"
grep -Fq 'LABEL org.sihsalus.node-id="${SIHSALUS_NODE_ID}"' "$ROOT/frontend/Dockerfile"

low_disk_fixture="$TEST_ROOT/low-disk"
make_fixture "$low_disk_fixture"
install_low_disk_df "$low_disk_fixture"
if run_deploy "$low_disk_fixture"; then
  echo "deployment should have refused to start with insufficient disk space" >&2
  exit 1
fi
if [ -f "$low_disk_fixture/state/commands" ] &&
  grep -Eq '^(docker pull|git fetch)' "$low_disk_fixture/state/commands"; then
  echo "low-disk preflight must run before fetching or pulling anything" >&2
  exit 1
fi

echo "frontend deployment tests passed"
