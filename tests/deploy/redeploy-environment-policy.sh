#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/deploy/redeploy-environment.sh"

bash -n "$SCRIPT"

if grep -Eq 'docker compose down|docker (volume|system) (rm|prune)|docker image prune|docker compose .* (--volumes|-v)( |$)' "$SCRIPT"; then
  echo "[FAIL] full redeploy script contains a data-destructive Docker operation" >&2
  exit 1
fi

grep -Fq 'git merge --ff-only origin/main' "$SCRIPT"
grep -Fq 'docker compose pull backend' "$SCRIPT"
grep -Fq 'REDEPLOY_OFFLINE="${REDEPLOY_OFFLINE:-false}"' "$SCRIPT"
grep -Fq 'docker compose build --pull --no-cache "${BUILD_SERVICES[@]}"' "$SCRIPT"
grep -Fq 'offline mode: using prevalidated local runtime images without rebuilding' "$SCRIPT"
grep -Fq -- '--force-recreate' "$SCRIPT"
grep -Fq -- '--remove-orphans' "$SCRIPT"
grep -Fq -- '--no-build' "$SCRIPT"
grep -Fq -- '--pull never' "$SCRIPT"
grep -Fq 'wait_for_openmrs 2400' "$SCRIPT"
grep -Fq 'wait_for_active_services 600' "$SCRIPT"
grep -Fq 'backend-oauth2-config | certbot)' "$SCRIPT"
grep -Fq 'ghcr.io/sihsalus/sihsalus-backend:' "$SCRIPT"

echo "[OK] full environment redeploy policy"
