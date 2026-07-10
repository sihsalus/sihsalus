#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v docker >/dev/null 2>&1; then
  echo "[FAIL] docker is required" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "[FAIL] python3 is required for semantic checks" >&2
  exit 1
fi

for gateway_template in gateway/default.conf.template gateway/default-ssl.conf.template; do
  if grep -Eq 'proxy_pass http://backend(/|:)' "$gateway_template"; then
    echo "[FAIL] $gateway_template must resolve backend health routes dynamically" >&2
    exit 1
  fi
  if [ "$(grep -c 'set \$backend_health http://backend:8080;' "$gateway_template")" -ne 2 ]; then
    echo "[FAIL] $gateway_template must define dynamic startup and readiness upstreams" >&2
    exit 1
  fi
  if grep -q 'proxy_method HEAD;' "$gateway_template"; then
    echo "[FAIL] $gateway_template must not discard the startup response body" >&2
    exit 1
  fi
done
echo "[OK] gateway health routes use dynamic Docker DNS and valid startup framing"

if [ "$#" -gt 1 ]; then
  echo "Usage: $0 [evidence-directory]" >&2
  exit 2
fi

if [ "$#" -eq 1 ]; then
  EVIDENCE_DIR="$1"
  mkdir -p "$EVIDENCE_DIR"
else
  EVIDENCE_DIR="$(mktemp -d)"
  trap 'rm -rf "$EVIDENCE_DIR"' EXIT
fi

# Profiles are applied after interpolation. The core must therefore render
# without any optional-profile credentials in the process environment.
env -i PATH="$PATH" HOME="${HOME:-/tmp}" \
  docker compose --env-file /dev/null -f docker-compose.yml config --quiet
echo "[OK] core without optional-profile secrets"

# Deterministic non-production values. /dev/null prevents a local .env from
# changing which files/profiles are validated or leaking secrets to artifacts.
export MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-ci-root-password-123}"
export OMRS_DB_REPL_PASSWORD="${OMRS_DB_REPL_PASSWORD:-ci-replica-password-123}"
export SIHSALUS_FUA_GEN_DB_PASSWORD="${SIHSALUS_FUA_GEN_DB_PASSWORD:-ci-fua-db-password-123}"
export SIHSALUS_FUA_GEN_TOKEN="${SIHSALUS_FUA_GEN_TOKEN:-ci-fua-token-123}"
export SIHSALUS_FUA_GEN_SECRET_KEY="${SIHSALUS_FUA_GEN_SECRET_KEY:-ci-fua-secret-123}"
export SIHSALUS_FUA_GEN_ENCRYPTION_KEY="${SIHSALUS_FUA_GEN_ENCRYPTION_KEY:-123456789012}"
export HAPI_DB_PASSWORD="${HAPI_DB_PASSWORD:-ci-hapi-password-123}"
export SIHSALUS_REPORTES_SQL_DB_PASSWORD="${SIHSALUS_REPORTES_SQL_DB_PASSWORD:-ci-reportes-password-123}"
export KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-ci-keycloak-admin-123}"
export KC_DB_PASSWORD="${KC_DB_PASSWORD:-ci-keycloak-db-123}"
export OAUTH2_CLIENT_SECRET="${OAUTH2_CLIENT_SECRET:-ci-oauth2-secret-123}"
export IMAGING_OIDC_CLIENT_SECRET="${IMAGING_OIDC_CLIENT_SECRET:-ci-imaging-client-secret-123}"
export IMAGING_OAUTH_COOKIE_SECRET="${IMAGING_OAUTH_COOKIE_SECRET:-QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE=}"
export GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-ci-grafana-password-123}"
export OMRS_OCL_TOKEN="${OMRS_OCL_TOKEN:-}"
export SIHSALUS_SEED_URL="${SIHSALUS_SEED_URL:-https://example.test/sihsalus-seed.tar.gz.enc}"
export SIHSALUS_SEED_SHA256="${SIHSALUS_SEED_SHA256:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
export SIHSALUS_SEED_PASSPHRASE_FILE="${SIHSALUS_SEED_PASSPHRASE_FILE:-/dev/null}"
unset FUA_GENERATOR_IMAGE FUA_GENERATOR_TAG

validate() {
  local name="$1"
  shift
  docker compose --env-file /dev/null "$@" config --format json > "$EVIDENCE_DIR/$name.json"
  echo "[OK] $name"
}

validate core -f docker-compose.yml
validate ci-no-volumes -f docker-compose-no-volumes.yml
validate fua -f docker-compose.yml --profile fua
validate hapi -f docker-compose.yml --profile hapi
validate imaging -f docker-compose.yml --profile imaging
validate indicadores -f docker-compose.yml --profile indicadores
validate monitoring-logs -f docker-compose.yml --profile monitoring --profile logs
validate replica -f docker-compose.yml --profile replica
validate keycloak -f docker-compose.yml -f compose/keycloak.yml --profile keycloak
validate imaging-auth -f docker-compose.yml -f compose/keycloak.yml -f compose/imaging-auth.yml --profile keycloak --profile imaging
validate status -f docker-compose.yml -f compose/status.yml --profile status
validate ssl -f docker-compose.yml -f compose/ssl.yml --profile ssl
validate seed -f docker-compose.yml -f compose/seed.yml --profile seed --profile fua
KEYCLOAK_MODE=production \
KEYCLOAK_PUBLIC_URL=https://sihsalus.example.test/keycloak \
KC_HOSTNAME=https://sihsalus.example.test/keycloak \
OPENMRS_REDIRECT_URI=https://sihsalus.example.test/openmrs/* \
IMAGING_OAUTH_REDIRECT_URI=https://sihsalus.example.test/imaging/oauth2/callback \
validate keycloak-ssl -f docker-compose.yml -f compose/keycloak.yml -f compose/ssl.yml --profile keycloak --profile ssl
KEYCLOAK_MODE=production \
KEYCLOAK_PUBLIC_URL=https://sihsalus.example.test/keycloak \
KC_HOSTNAME=https://sihsalus.example.test/keycloak \
OPENMRS_REDIRECT_URI=https://sihsalus.example.test/openmrs/* \
IMAGING_OAUTH_REDIRECT_URI=https://sihsalus.example.test/imaging/oauth2/callback \
IMAGING_OAUTH_COOKIE_SECURE=true \
validate imaging-auth-ssl -f docker-compose.yml -f compose/keycloak.yml -f compose/imaging-auth.yml -f compose/ssl.yml --profile keycloak --profile imaging --profile ssl

python3 - "$EVIDENCE_DIR/core.json" "$EVIDENCE_DIR/fua.json" "$EVIDENCE_DIR/keycloak.json" "$EVIDENCE_DIR/ssl.json" "$EVIDENCE_DIR/ci-no-volumes.json" "$EVIDENCE_DIR/imaging.json" "$EVIDENCE_DIR/keycloak-ssl.json" "$EVIDENCE_DIR/monitoring-logs.json" "$EVIDENCE_DIR/imaging-auth.json" "$EVIDENCE_DIR/imaging-auth-ssl.json" "$EVIDENCE_DIR/seed.json" keycloak/realm-export.json <<'PY'
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


core, fua, keycloak, ssl, ci, imaging, keycloak_ssl, monitoring, imaging_auth, imaging_auth_ssl, seed, realm = map(load, sys.argv[1:])
core_backend = service(core, "backend")
core_generator = service(core, "backend-oauth2-config")

if core_backend.get("environment", {}).get("OAUTH2_ENABLED") != "false":
    fail("core backend must keep OAuth2 disabled")
if core_generator.get("environment", {}).get("OAUTH2_ENABLED") != "false":
    fail("core OAuth2 config generator must keep OAuth2 disabled")
if "keycloak" in core.get("services", {}):
    fail("core must not start Keycloak without the explicit override")
if core_backend.get("depends_on", {}).get("backend-oauth2-config", {}).get("condition") != "service_completed_successfully":
    fail("backend must wait for OAuth2 config generation")

seed_service = service(seed, "seed")
if seed_service.get("environment", {}).get("SIHSALUS_SEED_PASSPHRASE_FILE") != "/run/secrets/seed_passphrase":
    fail("seed restore must read its passphrase from the mounted Compose secret")
for writer in ("db", "backend-oauth2-config", "fua-generator-db"):
    if service(seed, writer).get("depends_on", {}).get("seed", {}).get("condition") != "service_completed_successfully":
        fail(f"{writer} must wait for the seed restore")

fua_generator = service(fua, "fua-generator")
fua_database = service(fua, "fua-generator-db")
fua_image = fua_generator.get("image", "")
if not fua_image.startswith("ghcr.io/sihsalus/generador-de-fua:sha-"):
    fail("FUA generator must default to an immutable official GHCR image")

fua_environment = fua_generator.get("environment", {})
fua_database_environment = fua_database.get("environment", {})
if fua_environment.get("NODE_ENV") != "production":
    fail("FUA generator must run with NODE_ENV=production")
if len(fua_environment.get("ENCRYPTION_KEY", "").encode("utf-8")) != 12:
    fail("FUA generator ENCRYPTION_KEY must be exactly 12 bytes")

fua_database_variables = {
    "DB_USER": "POSTGRES_USER",
    "DB_PASSWORD": "POSTGRES_PASSWORD",
    "DB_NAME": "POSTGRES_DB",
}
for application_variable, database_variable in fua_database_variables.items():
    if fua_environment.get(application_variable) != fua_database_environment.get(database_variable):
        fail(f"FUA database wiring mismatch: {application_variable} != {database_variable}")

fua_healthcheck = "\n".join(map(str, fua_generator.get("healthcheck", {}).get("test", [])))
if "http://localhost:3000/health" not in fua_healthcheck:
    fail("FUA healthcheck must use the database-aware readiness endpoint")

keycloak_backend = service(keycloak, "backend")
keycloak_generator = service(keycloak, "backend-oauth2-config")
service(keycloak, "keycloak")
service(keycloak, "keycloak-db")

if keycloak_backend.get("environment", {}).get("OAUTH2_ENABLED") != "true":
    fail("Keycloak override must enable OAuth2 in backend")
if keycloak_generator.get("environment", {}).get("OAUTH2_ENABLED") != "true":
    fail("Keycloak override must enable generated OAuth2 configuration")
if keycloak_backend.get("depends_on", {}).get("keycloak", {}).get("condition") != "service_healthy":
    fail("backend must wait for healthy Keycloak")

spa_urls = service(keycloak, "frontend").get("build", {}).get("args", {}).get("SPA_CONFIG_URLS", "")
if "frontend-keycloak.json" not in spa_urls:
    fail("Keycloak override must include the frontend OAuth2 configuration")

keycloak_ports = service(keycloak, "keycloak").get("ports", [])
if not any(str(port.get("target")) == "8080" and port.get("host_ip") == "127.0.0.1" for port in keycloak_ports):
    fail("Keycloak direct port must bind to localhost")

production_keycloak_env = service(keycloak_ssl, "keycloak").get("environment", {})
if production_keycloak_env.get("KEYCLOAK_MODE") != "production":
    fail("Keycloak+SSL model must use production mode")
if not production_keycloak_env.get("KC_HOSTNAME", "").startswith("https://"):
    fail("production Keycloak hostname must use HTTPS")
if not production_keycloak_env.get("OPENMRS_REDIRECT_URI", "").startswith("https://"):
    fail("production OpenMRS redirect URI must use HTTPS")
if not production_keycloak_env.get("IMAGING_OAUTH_REDIRECT_URI", "").startswith("https://"):
    fail("production Imaging redirect URI must use HTTPS")

ssl_ports = service(ssl, "gateway").get("ports", [])
if not any(str(port.get("target")) == "443" for port in ssl_ports):
    fail("SSL override must publish gateway port 443")

orthanc_ports = service(imaging, "orthanc").get("ports", [])
if not any(str(port.get("target")) == "4242" and port.get("host_ip") == "127.0.0.1" for port in orthanc_ports):
    fail("DICOM port must bind to localhost by default")

imaging_acl = service(imaging, "gateway").get("environment", {}).get("IMAGING_ACCESS_CONTROL", "")
if imaging_acl.strip() != "deny all;":
    fail("Imaging gateway routes must stay closed without the auth override")

imaging_auth_service = service(imaging_auth, "imaging-auth")
if imaging_auth_service.get("image") != "quay.io/oauth2-proxy/oauth2-proxy:v7.15.3":
    fail("Imaging auth proxy must use the reviewed pinned version")
if imaging_auth_service.get("ports"):
    fail("Imaging auth proxy must not publish host ports")

auth_env = imaging_auth_service.get("environment", {})
if auth_env.get("OAUTH2_PROXY_PROVIDER") != "keycloak-oidc":
    fail("Imaging auth must use the Keycloak OIDC provider")
if auth_env.get("OAUTH2_PROXY_ALLOWED_ROLES") != "imaging-access":
    fail("Imaging auth must require the explicit imaging-access role")
if auth_env.get("OAUTH2_PROXY_CODE_CHALLENGE_METHOD") != "S256":
    fail("Imaging auth must require PKCE S256")
if "{id_token}" not in auth_env.get("OAUTH2_PROXY_BACKEND_LOGOUT_URL", ""):
    fail("Imaging logout must terminate the Keycloak session")
if auth_env.get("OAUTH2_PROXY_PASS_ACCESS_TOKEN") != "false":
    fail("Imaging auth must not pass reusable access tokens to browser applications")

protected_acl = service(imaging_auth, "gateway").get("environment", {}).get("IMAGING_ACCESS_CONTROL", "")
if "deny all" not in protected_acl or "auth_request /imaging/oauth2/auth" not in protected_acl:
    fail("Imaging auth override must combine network ACL and individual authentication")
if service(imaging_auth, "gateway").get("depends_on", {}).get("imaging-auth", {}).get("condition") != "service_started":
    fail("gateway must start with the Imaging auth proxy")

production_auth_env = service(imaging_auth_ssl, "imaging-auth").get("environment", {})
if production_auth_env.get("OAUTH2_PROXY_COOKIE_SECURE") != "true":
    fail("production Imaging cookies must be HTTPS-only")
if not production_auth_env.get("OAUTH2_PROXY_REDIRECT_URL", "").startswith("https://"):
    fail("production Imaging callback must use HTTPS")

realm_roles = {role.get("name") for role in realm.get("roles", {}).get("realm", [])}
if "imaging-access" not in realm_roles:
    fail("Keycloak realm must define imaging-access")

imaging_clients = [client for client in realm.get("clients", []) if client.get("clientId") == "sihsalus-imaging"]
if len(imaging_clients) != 1:
    fail("Keycloak realm must define one dedicated Imaging client")
imaging_client = imaging_clients[0]
if imaging_client.get("directAccessGrantsEnabled") is not False:
    fail("Imaging client must disable password grants")
if imaging_client.get("secret") != "${IMAGING_OIDC_CLIENT_SECRET}":
    fail("Imaging client must use its dedicated injected secret")
if imaging_client.get("attributes", {}).get("pkce.code.challenge.method") != "S256":
    fail("Imaging client must require PKCE S256")

if ci.get("volumes"):
    fail("docker-compose-no-volumes.yml must not declare named volumes")

alloy = service(monitoring, "alloy")
socket_proxy = service(monitoring, "docker-socket-proxy")

for volume in alloy.get("volumes", []):
    if volume.get("source") == "/var/run/docker.sock":
        fail("Alloy must not mount the Docker socket directly")

if socket_proxy.get("environment", {}).get("POST") != "0":
    fail("Docker socket proxy must reject POST requests")
if not any(volume.get("source") == "/var/run/docker.sock" for volume in socket_proxy.get("volumes", [])):
    fail("Docker socket proxy must own the socket mount")

print("[OK] semantic Compose invariants")
PY
