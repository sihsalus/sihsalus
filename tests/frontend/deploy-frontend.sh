#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

OLD_SHA='1111111111111111111111111111111111111111'
TARGET_SHA='2222222222222222222222222222222222222222'
BAD_SHA='3333333333333333333333333333333333333333'
OLD_DIGEST='sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
TARGET_DIGEST='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
SOURCE_REPOSITORY='ghcr.io/sihsalus/sihsalus-frontend'
TARGET_SOURCE_IMAGE="${SOURCE_REPOSITORY}@${TARGET_DIGEST}"
TARGET_RUNTIME_TAG="digest-${TARGET_DIGEST#sha256:}"

make_fixture() {
  local fixture="$1"
  mkdir -p "$fixture/bin" "$fixture/state"
  touch "$fixture/docker-compose.yml"
  cat >"$fixture/.env" <<EOF
FRONTEND_SOURCE_IMAGE=${SOURCE_REPOSITORY}@${OLD_DIGEST}
FRONTEND_SOURCE_TAG=sha-${OLD_SHA}
FRONTEND_RUNTIME_TAG=sha-${OLD_SHA}
EOF
  printf '%s\n' "$OLD_SHA" >"$fixture/state/deployed_sha"
  printf '%s\n' "$TARGET_SHA" >"$fixture/state/source_sha"
  printf '%s\n' "healthy" >"$fixture/state/health"
  printf '%s\n' "sihsalus-frontend-runtime:sha-${OLD_SHA}" >"$fixture/state/image"

  cat >"$fixture/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >>"${FAKE_STATE_DIR}/commands"
EOF

  cat >"$fixture/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >>"${FAKE_STATE_DIR}/commands"

case "${1:-}" in
  image)
    if [ "${2:-}" != "inspect" ]; then
      echo "unexpected docker image command: $*" >&2
      exit 89
    fi
    cat "${FAKE_STATE_DIR}/source_sha"
    ;;
  exec)
    printf '{\n  "gitSha": "%s"\n}\n' "$(cat "${FAKE_STATE_DIR}/deployed_sha")"
    ;;
  inspect)
    if [[ "$*" == *'.Config.Image'* ]]; then
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

run_deploy() {
  local fixture="$1"
  (
    cd "$fixture"
    PATH="$fixture/bin:$PATH" \
      FAKE_STATE_DIR="$fixture/state" \
      FAKE_TARGET_RUNTIME_TAG="$TARGET_RUNTIME_TAG" \
      FAKE_TARGET_SHA="$TARGET_SHA" \
      FAKE_BAD_SHA="$BAD_SHA" \
      "$ROOT/scripts/deploy/deploy-frontend.sh" "$TARGET_SHA" "$TARGET_DIGEST"
  )
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
  local expected_up='docker compose up -d --no-deps --no-build --force-recreate frontend'
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

noop_fixture="$TEST_ROOT/noop"
make_fixture "$noop_fixture"
sed -i.bak "s/${OLD_SHA}/${TARGET_SHA}/g" "$noop_fixture/.env"
sed -i.bak "s/${OLD_DIGEST}/${TARGET_DIGEST}/g" "$noop_fixture/.env"
sed -i.bak "s/FRONTEND_RUNTIME_TAG=sha-${TARGET_SHA}/FRONTEND_RUNTIME_TAG=${TARGET_RUNTIME_TAG}/" "$noop_fixture/.env"
rm -f "$noop_fixture/.env.bak"
printf '%s\n' "$TARGET_SHA" >"$noop_fixture/state/deployed_sha"
printf '%s\n' "sihsalus-frontend-runtime:${TARGET_RUNTIME_TAG}" >"$noop_fixture/state/image"
run_deploy "$noop_fixture"
if grep -Eq 'docker (pull|compose build|compose up)' "$noop_fixture/state/commands"; then
  echo "idempotent deployment unexpectedly changed the frontend" >&2
  exit 1
fi

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
assert_value "$TARGET_SHA" \
  "$(cat "$success_fixture/state/deployed_sha")" \
  "deployed SHA was not updated"
grep -Fqx "docker pull ${TARGET_SOURCE_IMAGE}" "$success_fixture/state/commands"
grep -Fqx \
  "docker image inspect ${TARGET_SOURCE_IMAGE} --format {{index .Config.Labels \"org.opencontainers.image.revision\"}}" \
  "$success_fixture/state/commands"
grep -q 'docker compose build --pull frontend' "$success_fixture/state/commands"
grep -q 'docker compose up -d --no-deps --no-build --force-recreate frontend' "$success_fixture/state/commands"
assert_frontend_only_mutations "$success_fixture/state/commands"

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
    FAKE_TARGET_SHA="$TARGET_SHA" \
    FAKE_BAD_SHA="$BAD_SHA" \
    FAKE_FAIL_BUILD=true \
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
    FAKE_TARGET_SHA="$TARGET_SHA" \
    FAKE_BAD_SHA="$BAD_SHA" \
    FAKE_BAD_DEPLOY_SHA=true \
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
  "$(grep -c '^docker compose up -d --no-deps --no-build --force-recreate frontend$' "$verification_fixture/state/commands")" \
  "verification rollback did not recreate only the new and previous frontend"
assert_frontend_only_mutations "$verification_fixture/state/commands"

rendered_frontend="$(
  cd "$ROOT"
  FRONTEND_SOURCE_IMAGE="$TARGET_SOURCE_IMAGE" \
    FRONTEND_RUNTIME_TAG="$TARGET_RUNTIME_TAG" \
    docker compose config --format json
)"
assert_value "$TARGET_SOURCE_IMAGE" \
  "$(jq -r '.services.frontend.build.args.FRONTEND_SOURCE_IMAGE' <<<"$rendered_frontend")" \
  "Compose did not pass the immutable digest to the frontend build"
assert_value "sihsalus-frontend-runtime:${TARGET_RUNTIME_TAG}" \
  "$(jq -r '.services.frontend.image' <<<"$rendered_frontend")" \
  "Compose did not assign the digest-derived runtime tag"

echo "frontend deployment tests passed"
