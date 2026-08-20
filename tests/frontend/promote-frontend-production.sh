#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/promote-frontend-production.yml"

[ -f "$WORKFLOW" ]

# Production is manual-only and serial. It must never join the automatic
# frontend-published, tag, schedule, or repository-dispatch paths.
grep -Fq 'workflow_dispatch:' "$WORKFLOW"
if grep -Eq '^  (push|schedule|repository_dispatch|workflow_run):' "$WORKFLOW"; then
  echo 'production frontend promotion must be manual-only' >&2
  exit 1
fi
grep -Fq 'group: promote-frontend-production' "$WORKFLOW"
grep -Fq 'cancel-in-progress: false' "$WORKFLOW"
grep -Fq 'Production promotion must run from the current main branch tip.' "$WORKFLOW"

# The operator must bind the action to the exact immutable artifact. Normal
# promotion additionally requires the current latest alias and QLTY evidence;
# rollback deliberately uses an older immutable artifact.
grep -Fq 'PROMOTE ${REQUESTED_SHA} TO PRODUCTION' "$WORKFLOW"
grep -Fq 'ROLLBACK ${REQUESTED_SHA} IN PRODUCTION' "$WORKFLOW"
grep -Fq 'sha256:[0-9a-f]{64}' "$WORKFLOW"
grep -Fq 'org.opencontainers.image.revision' "$WORKFLOW"
grep -Fq 'current_production_sha:' "$WORKFLOW"
grep -Fq 'current_production_digest:' "$WORKFLOW"
grep -Fq 'Verify declared current production release' "$WORKFLOW"
grep -Fq 'A production promotion must use the currently promoted latest SHA and digest.' "$WORKFLOW"
grep -Fq "if: inputs.operation == 'promote'" "$WORKFLOW"
grep -Fq 'https://gidis-hsc-qlty.inf.pucp.edu.pe' "$WORKFLOW"

# GitHub's protected environment remains the authority boundary. All host
# identity and routing details are environment-scoped and fail closed.
grep -Fq 'name: production' "$WORKFLOW"
grep -Fq '${{ secrets.SSH_PRIVATE_KEY_PROD }}' "$WORKFLOW"
for variable in \
  SSH_KNOWN_HOSTS_PROD \
  PRODUCTION_BASE_URL \
  PRODUCTION_EXPECTED_NODE_ID \
  PRODUCTION_EXPECTED_REMOTE_MAC \
  PRODUCTION_REMOTE_REPOSITORY \
  PRODUCTION_SSH_TARGET; do
  grep -Fq "$variable" "$WORKFLOW"
done

# Deployment must reuse the scoped, identity-bound frontend script and verify
# the public endpoint. It must not mutate the full stack.
grep -Fq 'REDEPLOY_SCRIPT_PATH=scripts/deploy/deploy-frontend.sh' "$WORKFLOW"
grep -Fq 'scripts/deploy/run-redeploy-remote.sh' "$WORKFLOW"
grep -Fq 'scripts/deploy/verify-external-frontend.sh' "$WORKFLOW"
grep -Fq 'Restore previous release after deployment or verification failure' "$WORKFLOW"
grep -Fq "steps.deploy.outcome == 'failure' || steps.target-verify.outcome == 'failure'" "$WORKFLOW"
grep -Fq 'PROD-ROLLBACK' "$WORKFLOW"
if grep -Eq 'docker compose (up|down|restart|pull)' "$WORKFLOW"; then
  echo 'production workflow bypasses the scoped deployment policy' >&2
  exit 1
fi

echo '[OK] production frontend promotion policy'
