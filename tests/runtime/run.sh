#!/usr/bin/env bash
set -Eeuo pipefail

# A complete fresh installation belongs on an ephemeral GitHub runner. This
# entrypoint never accepts a remote Docker host, an environment URL or real data.
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted && "${RUNNER_OS:-}" == Linux ]] || {
  echo 'Runtime smoke requires an ephemeral GitHub-hosted Linux runner' >&2; exit 2;
}
[[ -z "${DOCKER_HOST:-}" && -z "${DOCKER_CONTEXT:-}" ]] || {
  echo 'Runtime smoke cannot use an alternate Docker connection' >&2; exit 2;
}
MODE="${1:?Usage: run.sh local|keycloak}"
[[ "$MODE" == local || "$MODE" == keycloak ]] || exit 2
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
docker context show
[[ "$(docker context show)" == default ]] || exit 2
docker info --format '{{.ServerVersion}}'
umask 077
STATE="$(mktemp -d "${RUNNER_TEMP:?}/runtime-smoke.XXXXXXXX")"
EVIDENCE="$ROOT/runtime-smoke-results/$MODE"
mkdir -p "$EVIDENCE"
PROJECT=''
STARTED=false
STAGE=prepare
COMPOSE=()

cleanup() {
  local result=$?
  trap - EXIT INT TERM
  if "$STARTED"; then
    timeout --kill-after=5s 30s "${COMPOSE[@]}" logs --no-color --timestamps --tail 500 >"$STATE/services.log" 2>&1 || true
    "${COMPOSE[@]}" ps --all --format json \
      | jq -s 'flatten | map({service: .Service, state: .State, health: .Health, exitCode: .ExitCode})' \
      >"$EVIDENCE/services.json" || result=1
    if ! timeout --kill-after=10s 120s "${COMPOSE[@]}" down --volumes --remove-orphans >"$STATE/cleanup.log" 2>&1; then
      result=1
    fi
    if [[ -n "$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")" \
       || -n "$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT")" ]]; then
      result=1
    fi
  fi
  if [[ -f "$STATE/fixture.json" ]]; then
    python3 -B tests/runtime/fixtures.py sanitize "$STATE" "$EVIDENCE" || result=1
  fi
  jq -n --arg stage "$STAGE" --arg mode "$MODE" --arg source "$GITHUB_SHA" --argjson exitCode "$result" \
    '{mode: $mode, sourceCommit: $source, lastStage: $stage, exitCode: $exitCode, clinicalDataUsed: false}' \
    >"$EVIDENCE/result.json"
  rm -rf -- "$STATE"
  echo "Runtime smoke ($MODE): stage=$STAGE exit=$result; only sanitized evidence retained"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

assert_no_patients() {
  local count
  count="$("${COMPOSE[@]}" exec -T db sh -c \
    'MYSQL_PWD="$MYSQL_PASSWORD" mariadb --user="$MYSQL_USER" --database=openmrs --batch --skip-column-names --execute="SELECT COUNT(*) FROM patient"' \
    2>>"$STATE/database-check.log")"
  [[ "$count" == 0 ]]
  echo 'patients=0' >>"$EVIDENCE/health.log"
}

BACKEND_DIGEST="${BACKEND_DIGEST:?the workflow must resolve a shared immutable backend digest}"
GENERATED_ENV="$(python3 -B tests/runtime/fixtures.py prepare "$STATE" "$MODE" "$BACKEND_DIGEST")"
while IFS= read -r assignment; do export "$assignment"; done <<< "$GENERATED_ENV"
unset GENERATED_ENV assignment
PROJECT="${COMPOSE_PROJECT_NAME:?synthetic project required}"
COMPOSE=(docker compose --project-name "$PROJECT" --env-file .env.template -f docker-compose.yml)
BUILD=(gateway frontend)
PULL=(backend db docs backend-oauth2-config)
if [[ "$MODE" == keycloak ]]; then
  COMPOSE+=(-f compose/keycloak.yml -f tests/runtime/compose.yml -f tests/runtime/keycloak.yml --profile keycloak)
  BUILD+=(keycloak)
  PULL+=(keycloak-db)
else
  COMPOSE+=(-f tests/runtime/compose.yml)
fi
STAGE=validate-isolation
"${COMPOSE[@]}" config --format json | python3 -B tests/runtime/fixtures.py validate "$STATE" "$ROOT"
[[ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")" ]]
[[ -z "$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT")" ]]

STAGE=pull
echo "Runtime smoke ($MODE): pull exact backend and configured core dependencies"
timeout --kill-after=10s 900s "${COMPOSE[@]}" pull "${PULL[@]}" >"$STATE/pull.log" 2>&1
STAGE=build
echo "Runtime smoke ($MODE): build current gateway, frontend wrapper and optional Keycloak"
timeout --kill-after=10s 1800s "${COMPOSE[@]}" build "${BUILD[@]}" >"$STATE/build.log" 2>&1
STAGE=bootstrap
STARTED=true
echo "Runtime smoke ($MODE): wait at most 45 minutes for fresh OpenMRS readiness"
timeout --kill-after=10s 2800s "${COMPOSE[@]}" up --no-build --pull never --wait --wait-timeout 2700 >"$STATE/startup.log" 2>&1
STAGE=health
for endpoint in startup ready; do
  status="$(curl --silent --show-error --max-time 10 --output /dev/null --write-out '%{http_code}' "http://127.0.0.1/$endpoint")"
  [[ "$status" == 200 ]]
  echo "$endpoint=$status" >>"$EVIDENCE/health.log"
done
assert_no_patients
mapfile -t containers < <("${COMPOSE[@]}" ps --all -q)
docker inspect "${containers[@]}" \
  | jq 'map({service: .Config.Labels["com.docker.compose.service"], image: .Config.Image, imageId: .Image})' \
  >"$EVIDENCE/containers.json"
mapfile -t image_ids < <(jq -r '.[].imageId' "$EVIDENCE/containers.json" | sort -u)
docker image inspect "${image_ids[@]}" \
  | jq 'map({id: .Id, digests: .RepoDigests, sourceRevision: .Config.Labels["org.opencontainers.image.revision"]})' \
  >"$EVIDENCE/images.json"
jq -n --arg backendDigest "$BACKEND_DIGEST" --arg source "$GITHUB_SHA" \
  '{backendDigest: $backendDigest, checkoutCommit: $source}' >"$EVIDENCE/sources.json"
STAGE=browser-login
echo "Runtime smoke ($MODE): verify the actual SPA and non-clinical login/logout"
SMOKE_STATE="$STATE" timeout --kill-after=10s 420s npm --prefix tests/runtime test >"$STATE/browser.log" 2>&1
assert_no_patients
STAGE=complete
