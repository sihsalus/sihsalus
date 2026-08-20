#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/deploy/redeploy-environment.sh"
CLEAN_CHECKOUT_HELPER="$ROOT/scripts/deploy/check-clean-checkout.sh"
CLEAN_CHECKOUT_HELPER_TEST="$ROOT/tests/deploy/check-clean-checkout-test.sh"
FRONTEND_SCRIPT="$ROOT/scripts/deploy/deploy-frontend.sh"
REMOTE_RUNNER="$ROOT/scripts/deploy/run-redeploy-remote.sh"
REMOTE_RUNNER_TEST="$ROOT/tests/deploy/run-redeploy-remote-test.sh"
EXTERNAL_VERIFIER="$ROOT/scripts/deploy/verify-external-frontend.sh"
WORKFLOW="$ROOT/.github/workflows/redeploy-non-production.yml"

bash -n "$SCRIPT"
bash -n "$CLEAN_CHECKOUT_HELPER"
bash -n "$CLEAN_CHECKOUT_HELPER_TEST"
bash -n "$FRONTEND_SCRIPT"
bash -n "$REMOTE_RUNNER"
bash -n "$REMOTE_RUNNER_TEST"
bash -n "$EXTERNAL_VERIFIER"

if grep -Eq 'docker compose down|docker (volume|system) (rm|prune)|docker image prune|docker compose .* (--volumes|-v)( |$)' "$SCRIPT"; then
  echo "[FAIL] full redeploy script contains a data-destructive Docker operation" >&2
  exit 1
fi

grep -Fq 'git merge --ff-only origin/main' "$SCRIPT"
grep -Fq 'bash "$CLEAN_CHECKOUT_HELPER" redeploy-environment' "$SCRIPT"
grep -Fq 'bash "$CLEAN_CHECKOUT_HELPER" deploy-frontend' "$FRONTEND_SCRIPT"
grep -Fq 'Usage: $0 <40-character backend git SHA> <sha256 image digest>' "$SCRIPT"
grep -Fq 'export BACKEND_TAG="$TARGET_BACKEND_REFERENCE"' "$SCRIPT"
grep -Fq 'docker compose pull backend' "$SCRIPT"
grep -Fq 'REDEPLOY_OFFLINE="${REDEPLOY_OFFLINE:-false}"' "$SCRIPT"
grep -Fq 'for build_service in "${BUILD_SERVICES[@]}"; do' "$SCRIPT"
grep -Fq 'docker compose build --pull --no-cache "$build_service"' "$SCRIPT"
grep -Fq 'offline mode: using prevalidated local runtime images without rebuilding' "$SCRIPT"
grep -Fq -- '--force-recreate' "$SCRIPT"
grep -Fq -- '--remove-orphans' "$SCRIPT"
grep -Fq -- '--no-build' "$SCRIPT"
grep -Fq -- '--pull never' "$SCRIPT"
grep -Fq 'wait_for_openmrs 2400' "$SCRIPT"
grep -Fq 'wait_for_active_services 600' "$SCRIPT"
grep -Fq 'backend-oauth2-config | certbot | loki-init)' "$SCRIPT"
grep -Fq 'EXPECTED_BACKEND_IMAGE="${BACKEND_REPOSITORY}:${TARGET_BACKEND_REFERENCE}"' "$SCRIPT"
grep -Fq 'BACKEND_SOURCE_REVISION' "$SCRIPT"
grep -Fq 'write_env_value BACKEND_TAG "$TARGET_BACKEND_REFERENCE"' "$SCRIPT"
grep -Fq 'FRONTEND_NODE_ID=' "$SCRIPT"
grep -Fq 'frontend wrapper does not contain the expected node identity' "$SCRIPT"
grep -Fq 'frontend wrapper does not contain the expected source digest' "$SCRIPT"
grep -Fq 'FRONTEND_SOURCE_IMAGE must already pin the frontend source by digest' "$SCRIPT"
grep -Fq 'mktemp ./.env.redeploy.XXXXXX' "$SCRIPT"
grep -Fq 'chmod --reference=.env "$temporary_file"' "$SCRIPT"
grep -Fq 'mv -f "$temporary_file" .env' "$SCRIPT"
grep -Fq 'waiting for OpenMRS' "$SCRIPT"
grep -Fq 'preflight_fua_database_authentication' "$SCRIPT"
grep -Fq 'POSTGRES_PASSWORD initializes only an empty PostgreSQL volume' "$SCRIPT"
grep -Fq -- '--cap-drop ALL' "$SCRIPT"
grep -Fq 'backend_sha:' "$WORKFLOW"
grep -Fq 'backend_digest:' "$WORKFLOW"
[ "$(grep -Fc 'scripts/deploy/run-redeploy-remote.sh' "$WORKFLOW")" -eq 2 ]
[ "$(grep -Fc 'REDEPLOY_EXPECTED_REMOTE_MAC:' "$WORKFLOW")" -eq 2 ]
[ "$(grep -Fc 'REDEPLOY_EXPECTED_NODE_ID:' "$WORKFLOW")" -eq 2 ]
[ "$(grep -Fc "REDEPLOY_TIMEOUT_SECONDS: '3000'" "$WORKFLOW")" -eq 2 ]
[ "$(grep -Fc '00:0c:29:ad:be:90' "$WORKFLOW")" -eq 1 ]
[ "$(grep -Fc '00:0c:29:1c:f7:78' "$WORKFLOW")" -eq 1 ]
[ "$(grep -Fc '3eb58bb0-ff08-4e2d-839c-11cedca0b043' "$WORKFLOW")" -eq 1 ]
[ "$(grep -Fc '0cefb0c8-c860-48c5-856f-408594775cbb' "$WORKFLOW")" -eq 1 ]
[ "$(grep -Fc 'scripts/deploy/verify-external-frontend.sh' "$WORKFLOW")" -eq 2 ]
[ "$(grep -Fc 'frontend_sha=${frontend_sha}' "$WORKFLOW")" -eq 2 ]
[ "$(grep -Fc 'frontend_digest=${frontend_digest}' "$WORKFLOW")" -eq 2 ]
grep -Fq 'TARGET_SHA: ${{ steps.redeploy.outputs.frontend_sha }}' "$WORKFLOW"
grep -Fq 'TARGET_DIGEST: ${{ steps.redeploy.outputs.frontend_digest }}' "$WORKFLOW"
if grep -Fq 'curl --insecure' "$WORKFLOW"; then
  echo '[FAIL] non-production external evidence bypasses TLS authentication' >&2
  exit 1
fi
grep -Fq 'nohup setsid bash -c' "$REMOTE_RUNNER"
grep -Fq 'tail -n "+${next_log_line}"' "$REMOTE_RUNNER"
grep -Fq 'kill -TERM -- "-${remote_pid}"' "$REMOTE_RUNNER"
grep -Fq -- '-o ServerAliveInterval=15' "$REMOTE_RUNNER"
grep -Fq -- '-o ServerAliveCountMax=3' "$REMOTE_RUNNER"
grep -Fq 'flock -n 9' "$REMOTE_RUNNER"
grep -Fq 'upload_remote_file "$CLEAN_CHECKOUT_HELPER_PATH" "$REMOTE_CLEAN_CHECKOUT_HELPER"' "$REMOTE_RUNNER"

eval "$(sed -n '/^service_allows_successful_exit() {/,/^}/p' "$SCRIPT")"
service_allows_successful_exit backend-oauth2-config
service_allows_successful_exit certbot
service_allows_successful_exit loki-init
if service_allows_successful_exit frontend; then
  echo "[FAIL] a long-running service may not exit successfully during redeploy" >&2
  exit 1
fi

test_fua_database_preflight() (
  eval "$(sed -n '/^service_is_active() {/,/^}/p' "$SCRIPT")"
  eval "$(sed -n '/^resolve_fua_database_volume_name() {/,/^}/p' "$SCRIPT")"
  eval "$(sed -n '/^preflight_fua_database_authentication() {/,/^# End preflight_fua_database_authentication$/p' "$SCRIPT")"
  ACTIVE_SERVICES=$'fua-generator-db\nfua-generator'

  docker() {
    printf 'docker %s\n' "$*" >>"$FUA_PREFLIGHT_COMMANDS"
    case "$*" in
      'compose config')
        cat <<'COMPOSE_CONFIG'
services: {}
volumes:
  db-fua-generator:
    name: test-project_db-fua-generator
COMPOSE_CONFIG
        ;;
      'volume ls --quiet')
        if [ "$FUA_PREFLIGHT_VOLUME" = existing ]; then
          printf '%s\n' test-project_db-fua-generator
        fi
        ;;
      'compose ps --all --quiet fua-generator-db')
        if [ "$FUA_PREFLIGHT_CONTAINER" != missing ]; then
          printf '%s\n' fua-database-container
        fi
        ;;
      'inspect fua-database-container --format {{.State.Status}}')
        printf '%s\n' "$FUA_PREFLIGHT_CONTAINER"
        ;;
      'compose run --quiet --rm --no-deps --pull never --cap-drop ALL --entrypoint node fua-generator '* )
        case "$FUA_PREFLIGHT_RESULT" in
          authentication-failure)
            echo 'simulated-secret-must-not-leak' >&2
            return 78
            ;;
          network-failure | timeout)
            echo 'simulated-connection-details-must-not-leak' >&2
            return 75
            ;;
          image-missing)
            echo 'simulated image is not available locally' >&2
            return 1
            ;;
        esac
        ;;
      *)
        echo "unexpected docker command: $*" >&2
        return 98
        ;;
    esac
  }

  preflight_fua_database_authentication
)

FUA_PREFLIGHT_COMMANDS="$(mktemp)"
trap 'rm -f "$FUA_PREFLIGHT_COMMANDS"' EXIT
FUA_PREFLIGHT_VOLUME=existing \
  FUA_PREFLIGHT_CONTAINER=running \
  FUA_PREFLIGHT_RESULT=success \
  test_fua_database_preflight
grep -Fq 'docker compose config' "$FUA_PREFLIGHT_COMMANDS"
grep -Fq 'docker volume ls --quiet' "$FUA_PREFLIGHT_COMMANDS"
grep -Fq 'docker compose run --quiet --rm --no-deps --pull never --cap-drop ALL --entrypoint node fua-generator' "$FUA_PREFLIGHT_COMMANDS"

: >"$FUA_PREFLIGHT_COMMANDS"
first_install_output="$(
  FUA_PREFLIGHT_VOLUME=missing \
    FUA_PREFLIGHT_CONTAINER=missing \
    FUA_PREFLIGHT_RESULT=unused \
    test_fua_database_preflight 2>&1
)"
grep -Fq 'first-install authentication is delegated to its healthcheck' <<<"$first_install_output"
if grep -Fq 'docker compose run' "$FUA_PREFLIGHT_COMMANDS"; then
  echo "[FAIL] first-install FUA preflight tried to use a database that does not exist" >&2
  exit 1
fi

: >"$FUA_PREFLIGHT_COMMANDS"
if existing_volume_output="$(
  FUA_PREFLIGHT_VOLUME=existing \
    FUA_PREFLIGHT_CONTAINER=missing \
    FUA_PREFLIGHT_RESULT=unused \
    test_fua_database_preflight 2>&1
)"; then
  echo "[FAIL] FUA preflight accepted an existing volume without a database container" >&2
  exit 1
fi
grep -Fq 'persistent FUA database volume exists without a database container' <<<"$existing_volume_output"
grep -Fq 'never delete the FUA volume' <<<"$existing_volume_output"

: >"$FUA_PREFLIGHT_COMMANDS"
if stopped_database_output="$(
  FUA_PREFLIGHT_VOLUME=existing \
    FUA_PREFLIGHT_CONTAINER=exited \
    FUA_PREFLIGHT_RESULT=unused \
    test_fua_database_preflight 2>&1
)"; then
  echo "[FAIL] FUA preflight accepted a stopped persistent database" >&2
  exit 1
fi
grep -Fq 'persistent FUA database exists but its container is exited' <<<"$stopped_database_output"
grep -Fq 'never delete the FUA volume' <<<"$stopped_database_output"

: >"$FUA_PREFLIGHT_COMMANDS"
if fua_failure_output="$(
  FUA_PREFLIGHT_VOLUME=existing \
    FUA_PREFLIGHT_CONTAINER=running \
    FUA_PREFLIGHT_RESULT=authentication-failure \
    test_fua_database_preflight 2>&1
)"; then
  echo "[FAIL] FUA preflight accepted invalid configured credentials" >&2
  exit 1
fi
grep -Fq 'could not authenticate; refusing to recreate services' <<<"$fua_failure_output"
grep -Fq 'never delete the FUA volume' <<<"$fua_failure_output"
if grep -Fq 'simulated-secret-must-not-leak' <<<"$fua_failure_output"; then
  echo "[FAIL] FUA preflight leaked the authentication command output" >&2
  exit 1
fi

for transient_result in network-failure timeout; do
  if transient_output="$(
    FUA_PREFLIGHT_VOLUME=existing \
      FUA_PREFLIGHT_CONTAINER=running \
      FUA_PREFLIGHT_RESULT="$transient_result" \
      test_fua_database_preflight 2>&1
  )"; then
    echo "[FAIL] inconclusive FUA probe allowed service recreation" >&2
    exit 1
  fi
  grep -Fq 'probe was inconclusive because the database was unavailable or timed out; refusing to recreate services' <<<"$transient_output"
  if grep -Fq 'POSTGRES_PASSWORD initializes only an empty PostgreSQL volume' <<<"$transient_output"; then
    echo "[FAIL] transient FUA failure was misdiagnosed as credential drift" >&2
    exit 1
  fi
  if grep -Fq 'simulated-connection-details-must-not-leak' <<<"$transient_output"; then
    echo "[FAIL] transient FUA probe printed internal connection output" >&2
    exit 1
  fi
done

if image_missing_output="$(
  FUA_PREFLIGHT_VOLUME=existing \
    FUA_PREFLIGHT_CONTAINER=running \
    FUA_PREFLIGHT_RESULT=image-missing \
    test_fua_database_preflight 2>&1
)"; then
  echo "[FAIL] unavailable FUA probe allowed service recreation" >&2
  exit 1
fi
grep -Fq 'probe is unavailable; refusing to recreate services' <<<"$image_missing_output"
if grep -Fq 'POSTGRES_PASSWORD initializes only an empty PostgreSQL volume' <<<"$image_missing_output"; then
  echo "[FAIL] unavailable FUA image was misdiagnosed as credential drift" >&2
  exit 1
fi
if grep -Fq 'simulated image is not available locally' <<<"$image_missing_output"; then
  echo "[FAIL] unavailable FUA probe printed internal Docker output" >&2
  exit 1
fi

grep -Fq "const IDENTITY_ERROR_CODES = new Set(['28000', '28P01', '3D000']);" "$SCRIPT"
grep -Fq 'connectionTimeoutMillis: OPERATION_TIMEOUT_MS' "$SCRIPT"
grep -Fq 'query_timeout: OPERATION_TIMEOUT_MS' "$SCRIPT"
grep -Fq 'const HARD_TIMEOUT_MS = 15000' "$SCRIPT"
grep -Fq 'process.exit(IDENTITY_ERROR_CODES.has(error?.code) ? 78 : 75)' "$SCRIPT"

bash "$CLEAN_CHECKOUT_HELPER_TEST"
bash "$REMOTE_RUNNER_TEST"

echo "[OK] full environment redeploy policy"
