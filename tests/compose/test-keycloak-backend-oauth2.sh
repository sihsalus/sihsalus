#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

CORE_CONFIG="$(mktemp)"
KEYCLOAK_CONFIG="$(mktemp)"
trap 'rm -f "$CORE_CONFIG" "$KEYCLOAK_CONFIG"' EXIT

export SIHSALUS_POSTGRES_PASSWORD="ci-postgres-password"
export SIHSALUS_ADMIN_PASSWORD="ci-admin-password"
export KEYCLOAK_ADMIN_PASSWORD="ci-keycloak-admin-password"
export KC_DB_PASSWORD="ci-keycloak-db-password"
export OAUTH2_CLIENT_SECRET="ci-oauth2-client-secret"
export KEYCLOAK_PUBLIC_URL="https://auth.example.test"

docker compose -f docker-compose.yml config --format json > "$CORE_CONFIG"
docker compose \
  -f docker-compose.yml \
  -f compose/openmrs-keycloak.yml \
  --profile keycloak \
  config --format json > "$KEYCLOAK_CONFIG"

python3 - "$CORE_CONFIG" "$KEYCLOAK_CONFIG" <<'PY'
import json
import sys


def fail(message):
    raise SystemExit(f"[FAIL] {message}")


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def service(config, name):
    try:
        return config["services"][name]
    except KeyError:
        fail(f"missing service: {name}")


def command_text(service_config):
    command = service_config.get("command")
    if isinstance(command, list):
        return "\n".join(command)
    if isinstance(command, str):
        return command
    return ""


def env(service_config):
    return service_config.get("environment", {})


def assert_equal(actual, expected, message):
    if actual != expected:
        fail(f"{message}: expected {expected!r}, got {actual!r}")


def assert_contains(text, expected, message):
    if expected not in text:
        fail(f"{message}: missing {expected!r}")


def assert_not_backend_oauth2_bind_mount(backend):
    for volume in backend.get("volumes", []):
        if volume.get("target") == "/openmrs/data/oauth2.properties":
            fail("backend must not bind mount oauth2.properties with unresolved placeholders")


core = load(sys.argv[1])
keycloak = load(sys.argv[2])

core_backend = service(core, "backend")
core_generator = service(core, "backend-oauth2-config")

assert_equal(
    core_backend["depends_on"]["backend-oauth2-config"]["condition"],
    "service_completed_successfully",
    "core backend must wait for oauth2 config generation",
)
assert_equal(env(core_backend)["OAUTH2_ENABLED"], "false", "core backend OAuth2 must default to disabled")
assert_contains(
    command_text(core_generator),
    "oauth2.enabled=false",
    "core oauth2 config generator must disable oauth2login",
)
assert_not_backend_oauth2_bind_mount(core_backend)

keycloak_backend = service(keycloak, "backend")
keycloak_generator = service(keycloak, "backend-oauth2-config")
service(keycloak, "keycloak")
service(keycloak, "keycloak-db")

assert_equal(
    keycloak_backend["depends_on"]["backend-oauth2-config"]["condition"],
    "service_completed_successfully",
    "keycloak backend must wait for oauth2 config generation",
)
assert_equal(
    keycloak_backend["depends_on"]["keycloak"]["condition"],
    "service_healthy",
    "keycloak backend must wait for healthy Keycloak",
)
assert_equal(env(keycloak_backend)["OAUTH2_ENABLED"], "true", "keycloak backend OAuth2 must be enabled")
assert_equal(
    env(keycloak_backend)["OAUTH2_CLIENT_SECRET"],
    "ci-oauth2-client-secret",
    "keycloak backend must receive OAUTH2_CLIENT_SECRET",
)
assert_equal(
    env(keycloak_generator)["KEYCLOAK_PUBLIC_URL"],
    "https://auth.example.test",
    "oauth2 generator must receive KEYCLOAK_PUBLIC_URL",
)
assert_equal(
    env(keycloak_generator)["OAUTH2_CLIENT_SECRET"],
    "ci-oauth2-client-secret",
    "oauth2 generator must receive OAUTH2_CLIENT_SECRET",
)

generator_command = command_text(keycloak_generator)
assert_contains(generator_command, "oauth2.enabled=true", "keycloak generator must enable oauth2login")
assert_contains(
    generator_command,
    "userAuthorizationUri=$${KEYCLOAK_PUBLIC_URL}/realms/openmrs/protocol/openid-connect/auth",
    "keycloak generator must defer public URL expansion to container runtime",
)
assert_contains(
    generator_command,
    "clientSecret=$${OAUTH2_CLIENT_SECRET}",
    "keycloak generator must defer client secret expansion to container runtime",
)
assert_not_backend_oauth2_bind_mount(keycloak_backend)

frontend = service(keycloak, "frontend")
frontend_args = frontend.get("build", {}).get("args", {})
assert_contains(
    frontend_args.get("SPA_CONFIG_URLS", ""),
    "frontend-keycloak.json",
    "keycloak profile must include frontend OAuth2 config",
)

print("[OK] Keycloak/backend OAuth2 Compose wiring is valid")
PY
