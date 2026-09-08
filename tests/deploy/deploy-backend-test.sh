#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/deploy/deploy-backend.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

OLD_SHA='1111111111111111111111111111111111111111'
TARGET_SHA='2222222222222222222222222222222222222222'
OLD_DIGEST='sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
TARGET_DIGEST='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
REPOSITORY='ghcr.io/sihsalus/sihsalus-backend'
OLD_REFERENCE="sha-${OLD_SHA}@${OLD_DIGEST}"
TARGET_REFERENCE="sha-${TARGET_SHA}@${TARGET_DIGEST}"
OLD_IMAGE="${REPOSITORY}:${OLD_REFERENCE}"
TARGET_IMAGE="${REPOSITORY}:${TARGET_REFERENCE}"
OLD_IMAGE_ID='sha256:old-backend-image'
TARGET_IMAGE_ID='sha256:target-backend-image'

make_fixture() {
  local fixture="$1"
  mkdir -p "$fixture/bin" "$fixture/state"
  touch "$fixture/docker-compose.yml"
  printf 'BACKEND_TAG=%s\nUNCHANGED_SECRET=keep-me\n' "$OLD_REFERENCE" >"$fixture/.env"
  chmod 600 "$fixture/.env"
  printf '%s\n' "$OLD_IMAGE" >"$fixture/state/image"
  printf '%s\n' "$OLD_IMAGE_ID" >"$fixture/state/image_id"
  printf '%s\n' healthy >"$fixture/state/health"
  printf '%s\n' true >"$fixture/state/started"

  cat >"$fixture/bin/git" <<'FAKE_GIT'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >>"${FAKE_STATE_DIR}/commands"
if [ "$*" = 'status --porcelain=v1 --untracked-files=no' ] && [ "${FAKE_TRACKED_DRIFT:-false}" = true ]; then
  printf '%s\n' ' M compose/core.yml'
fi
FAKE_GIT

  cat >"$fixture/bin/df" <<'FAKE_DF'
#!/usr/bin/env bash
printf 'Filesystem 1048576-blocks Used Available Capacity Mounted on\n'
printf '/dev/fake 50000 10000 40000 20%% /\n'
FAKE_DF

  cat >"$fixture/bin/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP

  cat >"$fixture/bin/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >>"${FAKE_STATE_DIR}/commands"

case "${1:-}" in
  inspect)
    joined="$*"
    if [[ "$joined" == *'.Config.Image'* ]]; then
      cat "${FAKE_STATE_DIR}/image"
    elif [[ "$joined" == *'{{.Image}}'* ]]; then
      cat "${FAKE_STATE_DIR}/image_id"
    else
      cat "${FAKE_STATE_DIR}/health"
    fi
    ;;
  exec)
    [ "$(cat "${FAKE_STATE_DIR}/started")" = true ]
    ;;
  pull)
    [ "${FAKE_PULL_FAIL:-false}" != true ]
    ;;
  image)
    [ "${2:-}" = inspect ] || exit 90
    target="${3:-}"
    joined="$*"
    if [[ "$joined" == *'{{.Id}}'* ]]; then
      if [ "$target" = "${FAKE_TARGET_IMAGE}" ]; then
        printf '%s\n' "${FAKE_TARGET_IMAGE_ID}"
      else
        printf '%s\n' "${FAKE_OLD_IMAGE_ID}"
      fi
    elif [[ "$joined" == *'org.opencontainers.image.revision'* ]]; then
      if [ "$target" = "${FAKE_TARGET_IMAGE}" ] || [ "$target" = "${FAKE_TARGET_IMAGE_ID}" ]; then
        printf '%s\n' "${FAKE_TARGET_SHA}"
      else
        printf '%s\n' "${FAKE_OLD_SHA}"
      fi
    fi
    ;;
  compose)
    case "${2:-}" in
      config)
        ;;
      up)
        if [ "${BACKEND_TAG:-}" = "${FAKE_TARGET_REFERENCE}" ]; then
          printf '%s\n' "${FAKE_TARGET_IMAGE}" >"${FAKE_STATE_DIR}/image"
          printf '%s\n' "${FAKE_TARGET_IMAGE_ID}" >"${FAKE_STATE_DIR}/image_id"
          if [ "${FAKE_FAIL_TARGET:-false}" = true ]; then
            printf '%s\n' unhealthy >"${FAKE_STATE_DIR}/health"
            printf '%s\n' false >"${FAKE_STATE_DIR}/started"
          else
            printf '%s\n' healthy >"${FAKE_STATE_DIR}/health"
            printf '%s\n' true >"${FAKE_STATE_DIR}/started"
          fi
        elif [ "${BACKEND_TAG:-}" = "${FAKE_OLD_REFERENCE}" ]; then
          printf '%s\n' "${FAKE_OLD_IMAGE}" >"${FAKE_STATE_DIR}/image"
          printf '%s\n' "${FAKE_OLD_IMAGE_ID}" >"${FAKE_STATE_DIR}/image_id"
          printf '%s\n' healthy >"${FAKE_STATE_DIR}/health"
          printf '%s\n' true >"${FAKE_STATE_DIR}/started"
        else
          echo "unexpected BACKEND_TAG: ${BACKEND_TAG:-<empty>}" >&2
          exit 91
        fi
        ;;
      *)
        echo "unexpected docker compose command: $*" >&2
        exit 92
        ;;
    esac
    ;;
  *)
    echo "unexpected docker command: $*" >&2
    exit 93
    ;;
esac
FAKE_DOCKER

  chmod +x "$fixture/bin/docker" "$fixture/bin/git" "$fixture/bin/df" "$fixture/bin/sleep"
}

run_deploy() {
  local fixture="$1"
  local requested_sha="${2:-$TARGET_SHA}"
  (
    cd "$fixture"
    PATH="$fixture/bin:$PATH" \
      FAKE_STATE_DIR="$fixture/state" \
      FAKE_OLD_SHA="$OLD_SHA" \
      FAKE_TARGET_SHA="$TARGET_SHA" \
      FAKE_OLD_REFERENCE="$OLD_REFERENCE" \
      FAKE_TARGET_REFERENCE="$TARGET_REFERENCE" \
      FAKE_OLD_IMAGE="$OLD_IMAGE" \
      FAKE_TARGET_IMAGE="$TARGET_IMAGE" \
      FAKE_OLD_IMAGE_ID="$OLD_IMAGE_ID" \
      FAKE_TARGET_IMAGE_ID="$TARGET_IMAGE_ID" \
      BACKEND_DEPLOY_TIMEOUT_SECONDS=30 \
      "$SCRIPT" "$requested_sha" "$TARGET_DIGEST"
  )
}

assert_backend_only() {
  local commands="$1"
  local expected='docker compose up -d --no-deps --no-build --pull never --force-recreate backend'
  if grep '^docker compose up' "$commands" | grep -Fvx "$expected"; then
    echo "backend deployment attempted an unscoped Compose up" >&2
    exit 1
  fi
  if grep -Eq '^docker compose (down|stop|restart|build)( |$)' "$commands"; then
    echo "backend deployment attempted a stack-wide or unrelated mutation" >&2
    exit 1
  fi
}

bash -n "$SCRIPT"

invalid="$TEST_ROOT/invalid"
make_fixture "$invalid"
if run_deploy "$invalid" not-a-sha 2>/dev/null; then
  echo "invalid backend SHA should be rejected" >&2
  exit 1
fi
if grep -q '^docker ' "$invalid/state/commands" 2>/dev/null; then
  echo "invalid input reached Docker" >&2
  exit 1
fi

dirty="$TEST_ROOT/dirty"
make_fixture "$dirty"
if FAKE_TRACKED_DRIFT=true run_deploy "$dirty" 2>/dev/null; then
  echo "tracked drift should block backend deployment" >&2
  exit 1
fi
if grep -q '^docker ' "$dirty/state/commands"; then
  echo "tracked drift reached Docker" >&2
  exit 1
fi

unhealthy="$TEST_ROOT/unhealthy"
make_fixture "$unhealthy"
printf '%s\n' unhealthy >"$unhealthy/state/health"
if run_deploy "$unhealthy" 2>/dev/null; then
  echo "an unhealthy current backend should not be replaced" >&2
  exit 1
fi
if grep -q '^docker compose up' "$unhealthy/state/commands"; then
  echo "unhealthy preflight recreated backend" >&2
  exit 1
fi

success="$TEST_ROOT/success"
make_fixture "$success"
run_deploy "$success"
grep -Fqx "BACKEND_TAG=${TARGET_REFERENCE}" "$success/.env"
grep -Fqx 'UNCHANGED_SECRET=keep-me' "$success/.env"
grep -Fqx "$TARGET_IMAGE" "$success/state/image"
grep -Fqx "docker pull ${TARGET_IMAGE}" "$success/state/commands"
assert_backend_only "$success/state/commands"

failure="$TEST_ROOT/failure"
make_fixture "$failure"
cp -p "$failure/.env" "$failure/original.env"
if FAKE_FAIL_TARGET=true run_deploy "$failure" 2>/dev/null; then
  echo "failed target health should fail deployment" >&2
  exit 1
fi
cmp "$failure/original.env" "$failure/.env"
grep -Fqx "$OLD_IMAGE" "$failure/state/image"
[ "$(grep -Fc 'docker compose up -d --no-deps --no-build --pull never --force-recreate backend' "$failure/state/commands")" -eq 2 ]
assert_backend_only "$failure/state/commands"

noop="$TEST_ROOT/noop"
make_fixture "$noop"
printf '%s\n' "$TARGET_IMAGE" >"$noop/state/image"
printf '%s\n' "$TARGET_IMAGE_ID" >"$noop/state/image_id"
run_deploy "$noop"
grep -Fqx "BACKEND_TAG=${TARGET_REFERENCE}" "$noop/.env"
if grep -Eq '^docker (pull|compose up)' "$noop/state/commands"; then
  echo "healthy exact backend should be a no-op" >&2
  exit 1
fi

echo "Backend-only deployment and rollback tests passed."
