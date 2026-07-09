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

# Deterministic non-production values. /dev/null prevents a local .env from
# changing which files/profiles are validated or leaking secrets to artifacts.
export MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-ci-root-password-123}"
export OMRS_DB_REPL_PASSWORD="${OMRS_DB_REPL_PASSWORD:-ci-replica-password-123}"
export SIHSALUS_FUA_GEN_DB_PASSWORD="${SIHSALUS_FUA_GEN_DB_PASSWORD:-ci-fua-db-password-123}"
export SIHSALUS_FUA_GEN_TOKEN="${SIHSALUS_FUA_GEN_TOKEN:-ci-fua-token-123}"
export SIHSALUS_FUA_GEN_SECRET_KEY="${SIHSALUS_FUA_GEN_SECRET_KEY:-ci-fua-secret-123}"
export HAPI_DB_PASSWORD="${HAPI_DB_PASSWORD:-ci-hapi-password-123}"
export SIHSALUS_REPORTES_SQL_DB_PASSWORD="${SIHSALUS_REPORTES_SQL_DB_PASSWORD:-ci-reportes-password-123}"
export KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-ci-keycloak-admin-123}"
export KC_DB_PASSWORD="${KC_DB_PASSWORD:-ci-keycloak-db-123}"
export OAUTH2_CLIENT_SECRET="${OAUTH2_CLIENT_SECRET:-ci-oauth2-secret-123}"
export GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-ci-grafana-password-123}"
export OMRS_OCL_TOKEN="${OMRS_OCL_TOKEN:-}"

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
validate status -f docker-compose.yml -f compose/status.yml --profile status
validate ssl -f docker-compose.yml -f compose/ssl.yml --profile ssl
KEYCLOAK_MODE=production \
KEYCLOAK_PUBLIC_URL=https://sihsalus.example.test/keycloak \
KC_HOSTNAME=https://sihsalus.example.test/keycloak \
OPENMRS_REDIRECT_URI=https://sihsalus.example.test/openmrs/* \
validate keycloak-ssl -f docker-compose.yml -f compose/keycloak.yml -f compose/ssl.yml --profile keycloak --profile ssl

python3 - "$EVIDENCE_DIR/core.json" "$EVIDENCE_DIR/keycloak.json" "$EVIDENCE_DIR/ssl.json" "$EVIDENCE_DIR/ci-no-volumes.json" "$EVIDENCE_DIR/imaging.json" "$EVIDENCE_DIR/keycloak-ssl.json" <<'PY'
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


core, keycloak, ssl, ci, imaging, keycloak_ssl = map(load, sys.argv[1:])
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

ssl_ports = service(ssl, "gateway").get("ports", [])
if not any(str(port.get("target")) == "443" for port in ssl_ports):
    fail("SSL override must publish gateway port 443")

orthanc_ports = service(imaging, "orthanc").get("ports", [])
if not any(str(port.get("target")) == "4242" and port.get("host_ip") == "127.0.0.1" for port in orthanc_ports):
    fail("DICOM port must bind to localhost by default")

imaging_acl = service(imaging, "gateway").get("environment", {}).get("IMAGING_ACCESS_CONTROL", "")
if "deny all" not in imaging_acl:
    fail("Imaging gateway routes must deny non-private clients by default")

if ci.get("volumes"):
    fail("docker-compose-no-volumes.yml must not declare named volumes")

print("[OK] semantic Compose invariants")
PY
