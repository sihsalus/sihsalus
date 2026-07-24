#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

OLD_SHA='1111111111111111111111111111111111111111'
TARGET_SHA='2222222222222222222222222222222222222222'
TARGET_DIGEST='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

make_fixture() {
  local fixture="$1"
  mkdir -p "$fixture/bin" "$fixture/state"
  touch "$fixture/docker-compose.yml"
  cat >"$fixture/.env" <<EOF
FRONTEND_SOURCE_TAG=sha-${OLD_SHA}
FRONTEND_RUNTIME_TAG=sha-${OLD_SHA}
EOF
  printf '%s\n' "$OLD_SHA" >"$fixture/state/deployed_sha"
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
        printf '%s\n' "${runtime_tag#sha-}" >"${FAKE_STATE_DIR}/deployed_sha"
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
rm -f "$noop_fixture/.env.bak"
printf '%s\n' "$TARGET_SHA" >"$noop_fixture/state/deployed_sha"
printf '%s\n' "sihsalus-frontend-runtime:sha-${TARGET_SHA}" >"$noop_fixture/state/image"
run_deploy "$noop_fixture"
if grep -Eq 'docker (pull|compose build|compose up)' "$noop_fixture/state/commands"; then
  echo "idempotent deployment unexpectedly changed the frontend" >&2
  exit 1
fi

success_fixture="$TEST_ROOT/success"
make_fixture "$success_fixture"
run_deploy "$success_fixture"
assert_value "sha-${TARGET_SHA}" \
  "$(awk -F= '$1 == "FRONTEND_SOURCE_TAG" { print $2 }' "$success_fixture/.env")" \
  "source tag was not updated"
assert_value "$TARGET_SHA" \
  "$(cat "$success_fixture/state/deployed_sha")" \
  "deployed SHA was not updated"
grep -q 'docker compose build --pull frontend' "$success_fixture/state/commands"
grep -q 'docker compose up -d --no-deps --no-build --force-recreate frontend' "$success_fixture/state/commands"

rollback_fixture="$TEST_ROOT/rollback"
make_fixture "$rollback_fixture"
if (
  cd "$rollback_fixture"
  PATH="$rollback_fixture/bin:$PATH" \
    FAKE_STATE_DIR="$rollback_fixture/state" \
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

echo "frontend deployment tests passed"
