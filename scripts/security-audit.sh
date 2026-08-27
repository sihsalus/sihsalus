#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ENV_FILE="${1:-}"
ISSUES=0
WARNINGS=0

ok() { echo "[OK] $*"; }
warn() { echo "[WARN] $*"; WARNINGS=$((WARNINGS + 1)); }
fail() { echo "[FAIL] $*"; ISSUES=$((ISSUES + 1)); }

if [ -z "$ENV_FILE" ]; then
  if [ -f .env.production ]; then
    ENV_FILE=.env.production
  elif [ -f .env ]; then
    ENV_FILE=.env
  fi
fi

if [ -z "$ENV_FILE" ] || [ ! -f "$ENV_FILE" ]; then
  fail "No env file found. Pass one explicitly: $0 .env.production"
else
  ok "Auditing $ENV_FILE"
fi

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

env_value() {
  local name="$1"
  sed -n "s/^${name}=//p" "$ENV_FILE" | tail -n 1
}

check_secret() {
  local name="$1"
  local value
  local lowercase
  value="$(env_value "$name")"

  if [ -z "$value" ]; then
    fail "$name is missing or empty"
    return
  fi

  lowercase="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  case "$lowercase" in
    openmrs|root|admin|admin123|password|changeme|change-me|sihsalus|fuagenerator|reportes_sql)
      fail "$name uses a known development/default value"
      return
      ;;
  esac

  if [ "${#value}" -lt 16 ]; then
    warn "$name is shorter than 16 characters"
  else
    ok "$name is set"
  fi
}

profile_enabled() {
  local profiles
  profiles=",$(env_value COMPOSE_PROFILES | tr -d ' '),"
  [[ "$profiles" == *",$1,"* ]]
}

check_pinned_tag() {
  local name="$1"
  local value
  value="$(env_value "$name")"

  case "$value" in
    ""|latest)
      fail "$name must use an immutable tag in production"
      ;;
    *)
      ok "$name is pinned to $value"
      ;;
  esac
}

check_docs_digest() {
  local value
  value="$(env_value DOCS_IMAGE_REF)"

  if [[ "$value" =~ ^ghcr\.io/sihsalus/sihsalus-docs@sha256:[0-9a-f]{64}$ ]]; then
    ok "DOCS_IMAGE_REF uses an immutable image digest"
  else
    fail "DOCS_IMAGE_REF must use ghcr.io/sihsalus/sihsalus-docs@sha256:<64 lowercase hex> in production"
  fi
}

if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
  MODE="$(file_mode "$ENV_FILE")"
  case "$MODE" in
    600|400) ok "$ENV_FILE permissions are $MODE" ;;
    *) fail "$ENV_FILE permissions are $MODE; expected 600 or 400" ;;
  esac

  case "$ENV_FILE" in
    /*) ENV_ABSOLUTE="$ENV_FILE" ;;
    *) ENV_ABSOLUTE="$ROOT_DIR/$ENV_FILE" ;;
  esac

  if [[ "$ENV_ABSOLUTE" == "$ROOT_DIR/"* ]]; then
    GIT_PATH="${ENV_ABSOLUTE#"$ROOT_DIR/"}"
    if git ls-files --error-unmatch "$GIT_PATH" >/dev/null 2>&1; then
      fail "$ENV_FILE is tracked by Git"
    elif git check-ignore -q "$GIT_PATH"; then
      ok "$ENV_FILE is ignored by Git"
    else
      warn "$ENV_FILE is not covered by .gitignore"
    fi
  else
    ok "$ENV_FILE is outside the Git worktree"
  fi

  check_secret MYSQL_OPENMRS_PASSWORD
  check_secret MYSQL_ROOT_PASSWORD

  if [ "$(env_value DEPLOYMENT_ENV)" = "production" ]; then
    check_pinned_tag BACKEND_TAG
    check_pinned_tag FRONTEND_SOURCE_TAG
    check_pinned_tag FRONTEND_RUNTIME_TAG
    check_docs_digest

    if profile_enabled hapi; then
      check_pinned_tag HAPI_TAG
    fi
    if profile_enabled indicadores; then
      check_pinned_tag REPORTES_SQL_TAG
    fi
  fi

  if profile_enabled replica; then
    check_secret OMRS_DB_REPL_PASSWORD
  fi
  if profile_enabled keycloak; then
    check_secret KEYCLOAK_ADMIN_PASSWORD
    check_secret KC_DB_PASSWORD
    check_secret OAUTH2_CLIENT_SECRET
    check_secret IMAGING_OIDC_CLIENT_SECRET

    if [ "$(env_value KEYCLOAK_MODE)" = "production" ]; then
      case "$(env_value KEYCLOAK_PUBLIC_URL)" in
        https://*) ok "KEYCLOAK_PUBLIC_URL uses HTTPS" ;;
        *) fail "KEYCLOAK_PUBLIC_URL must use HTTPS in production mode" ;;
      esac
      case "$(env_value KC_HOSTNAME)" in
        https://*) ok "KC_HOSTNAME uses HTTPS" ;;
        *) fail "KC_HOSTNAME must be a full HTTPS URL in production mode" ;;
      esac
      case "$(env_value OPENMRS_REDIRECT_URI)" in
        https://*) ok "OPENMRS_REDIRECT_URI uses HTTPS" ;;
        *) fail "OPENMRS_REDIRECT_URI must use HTTPS in production mode" ;;
      esac
      case "$(env_value IMAGING_OAUTH_REDIRECT_URI)" in
        https://*/imaging/oauth2/callback) ok "IMAGING_OAUTH_REDIRECT_URI uses the HTTPS callback" ;;
        *) fail "IMAGING_OAUTH_REDIRECT_URI must be HTTPS and end in /imaging/oauth2/callback" ;;
      esac
    fi
  fi
  if profile_enabled imaging; then
    if profile_enabled keycloak; then
      ok "Imaging includes the Keycloak profile"
    else
      fail "Imaging requires the keycloak profile for individual authentication"
    fi
    case "$(env_value COMPOSE_FILE)" in
      *compose/imaging-auth.yml*) ok "Imaging authentication override is selected" ;;
      *) fail "COMPOSE_FILE must include compose/imaging-auth.yml when Imaging is enabled" ;;
    esac
    check_secret IMAGING_OAUTH_COOKIE_SECRET

    if [ "$(env_value DEPLOYMENT_ENV)" = "production" ]; then
      [ "$(env_value IMAGING_OAUTH_COOKIE_SECURE)" = "true" ] \
        && ok "Imaging session cookie is HTTPS-only" \
        || fail "IMAGING_OAUTH_COOKIE_SECURE must be true in production"
    fi
  fi
  if profile_enabled monitoring || profile_enabled logs; then
    check_secret GRAFANA_ADMIN_PASSWORD

    case "$(env_value GRAFANA_NETWORK_ACCESS_CONTROL)" in
      ""|*"deny all;") : ;;
      *) fail "GRAFANA_NETWORK_ACCESS_CONTROL must end in 'deny all;' so /grafana/ stays closed by default" ;;
    esac
    case "$(env_value GRAFANA_NETWORK_ACCESS_CONTROL)" in
      "") warn "GRAFANA_NETWORK_ACCESS_CONTROL is unset: /grafana/ answers 403 to the whole LAN" ;;
      *"allow 0.0.0.0/0"*) fail "GRAFANA_NETWORK_ACCESS_CONTROL must not allow every network" ;;
      *) ok "Grafana gateway route is scoped to an explicit network range" ;;
    esac

    case "$(env_value GRAFANA_ROOT_URL)" in
      */grafana/) ok "GRAFANA_ROOT_URL matches the gateway sub path" ;;
      "") warn "GRAFANA_ROOT_URL is unset: Grafana will build links for localhost" ;;
      *) fail "GRAFANA_ROOT_URL must end in /grafana/ to match the gateway route" ;;
    esac

    case "$(env_value COMPOSE_FILE)" in
      *compose/monitoring-oidc.yml*) check_secret GRAFANA_OIDC_CLIENT_SECRET ;;
    esac

    if [ "$(env_value DEPLOYMENT_ENV)" = "production" ] && profile_enabled ssl; then
      [ "$(env_value GRAFANA_COOKIE_SECURE)" = "true" ] \
        && ok "Grafana session cookie is HTTPS-only" \
        || fail "GRAFANA_COOKIE_SECURE must be true when Grafana is served over HTTPS"
    fi
  fi
  if profile_enabled fua; then
    check_secret SIHSALUS_FUA_GEN_DB_PASSWORD
    check_secret SIHSALUS_FUA_GEN_TOKEN
    check_secret SIHSALUS_FUA_GEN_SECRET_KEY
  fi
  if profile_enabled hapi; then
    check_secret HAPI_DB_PASSWORD
  fi
  if profile_enabled indicadores; then
    check_secret SIHSALUS_REPORTES_SQL_DB_PASSWORD
  fi

  if profile_enabled ssl && [ "$(env_value SSL_MODE)" = "prod" ]; then
    [ -n "$(env_value CERT_WEB_DOMAINS)" ] || fail "CERT_WEB_DOMAINS is required for production TLS"
    [ -n "$(env_value CERT_CONTACT_EMAIL)" ] || warn "CERT_CONTACT_EMAIL is recommended for Let's Encrypt"
  fi

  if docker compose --env-file "$ENV_FILE" config --quiet; then
    ok "Selected Compose model is valid"
  else
    fail "Selected Compose model is invalid"
  fi
fi

if ./scripts/validate-compose.sh >/dev/null; then
  ok "All repository Compose models and semantic invariants are valid"
else
  fail "Repository Compose validation failed; run ./scripts/validate-compose.sh"
fi

echo "Audit complete: $ISSUES issue(s), $WARNINGS warning(s)."
[ "$ISSUES" -eq 0 ]
