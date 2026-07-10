#!/usr/bin/env bash
set -euo pipefail

MODE="${KEYCLOAK_MODE:-development}"

case "$MODE" in
  development)
    exec /opt/keycloak/bin/kc.sh start-dev --import-realm
    ;;
  production)
    case "${KC_HOSTNAME:-}" in
      https://*) ;;
      *)
        echo "KC_HOSTNAME must be a full https:// URL in production mode" >&2
        exit 1
        ;;
    esac

    case "${OPENMRS_REDIRECT_URI:-}" in
      https://*) ;;
      *)
        echo "OPENMRS_REDIRECT_URI must be a full https:// URI in production mode" >&2
        exit 1
        ;;
    esac

    export KC_HOSTNAME_STRICT=true
    exec /opt/keycloak/bin/kc.sh start --optimized --import-realm
    ;;
  *)
    echo "Unsupported KEYCLOAK_MODE: $MODE (use development or production)" >&2
    exit 1
    ;;
esac
