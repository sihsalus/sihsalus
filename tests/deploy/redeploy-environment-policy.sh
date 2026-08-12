#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/deploy/redeploy-environment.sh"
REMOTE_RUNNER="$ROOT/scripts/deploy/run-redeploy-remote.sh"
REMOTE_RUNNER_TEST="$ROOT/tests/deploy/run-redeploy-remote-test.sh"
EXTERNAL_VERIFIER="$ROOT/scripts/deploy/verify-external-frontend.sh"
WORKFLOW="$ROOT/.github/workflows/redeploy-non-production.yml"

bash -n "$SCRIPT"
bash -n "$REMOTE_RUNNER"
bash -n "$REMOTE_RUNNER_TEST"
bash -n "$EXTERNAL_VERIFIER"

if grep -Eq 'docker compose down|docker (volume|system) (rm|prune)|docker image prune|docker compose .* (--volumes|-v)( |$)' "$SCRIPT"; then
  echo "[FAIL] full redeploy script contains a data-destructive Docker operation" >&2
  exit 1
fi

grep -Fq 'git merge --ff-only origin/main' "$SCRIPT"
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
grep -Fq 'mktemp ./.env.redeploy.XXXXXX' "$SCRIPT"
grep -Fq 'chmod --reference=.env "$temporary_file"' "$SCRIPT"
grep -Fq 'mv -f "$temporary_file" .env' "$SCRIPT"
grep -Fq 'waiting for OpenMRS' "$SCRIPT"
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
grep -Fq 'TARGET_SHA: ${{ steps.redeploy.outputs.frontend_sha }}' "$WORKFLOW"
grep -Fq 'nohup setsid bash -c' "$REMOTE_RUNNER"
grep -Fq 'tail -n "+${next_log_line}"' "$REMOTE_RUNNER"
grep -Fq 'kill -TERM -- "-${remote_pid}"' "$REMOTE_RUNNER"
grep -Fq -- '-o ServerAliveInterval=15' "$REMOTE_RUNNER"
grep -Fq -- '-o ServerAliveCountMax=3' "$REMOTE_RUNNER"
grep -Fq 'flock -n 9' "$REMOTE_RUNNER"

eval "$(sed -n '/^service_allows_successful_exit() {/,/^}/p' "$SCRIPT")"
service_allows_successful_exit backend-oauth2-config
service_allows_successful_exit certbot
service_allows_successful_exit loki-init
if service_allows_successful_exit frontend; then
  echo "[FAIL] a long-running service may not exit successfully during redeploy" >&2
  exit 1
fi

bash "$REMOTE_RUNNER_TEST"

echo "[OK] full environment redeploy policy"
