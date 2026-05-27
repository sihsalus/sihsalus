#!/bin/bash
# Script para generar contraseñas seguras y crear .env.production
#
# Uso: ./scripts/security/secrets_generate.sh
# IMPORTANTE: Ejecutar ANTES de docker-compose up en producción

set -e

echo "========================================="
echo "SIHSALUS Security Setup"
echo "Generando contraseñas seguras..."
echo "========================================="
echo ""

# Crear directorio de secrets
mkdir -p secrets
chmod 700 secrets

# Función para generar password seguro
generate_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-32
}

# Generar contraseñas
echo "Generando contraseñas..."

# Core SIHSALUS / PostgreSQL
echo -n "$(generate_password)" > secrets/sihsalus_postgres_password.txt
echo -n "$(generate_password)" > secrets/sihsalus_admin_password.txt

# Keycloak
echo -n "$(generate_password)" > secrets/keycloak_admin_password.txt
echo -n "$(generate_password)" > secrets/keycloak_db_password.txt
echo -n "$(generate_password)" > secrets/oauth2_client_secret.txt

# Grafana
echo -n "$(generate_password)" > secrets/grafana_admin_password.txt

# FUA Generator
echo -n "$(generate_password)" > secrets/fua_db_password.txt
echo -n "$(generate_password)" > secrets/fua_token.txt

# HAPI FHIR
echo -n "$(generate_password)" > secrets/hapi_db_password.txt

# Ajustar permisos
chmod 600 secrets/*

echo "✅ Contraseñas generadas en ./secrets/"
echo ""

# Mostrar resumen (sin mostrar las contraseñas)
echo "========================================="
echo "Archivos de secrets creados:"
echo "========================================="
ls -lh secrets/
echo ""

# Crear archivo .env.production compatible con Docker Compose
SIHSALUS_POSTGRES_PASSWORD_VALUE=$(cat secrets/sihsalus_postgres_password.txt)
SIHSALUS_ADMIN_PASSWORD_VALUE=$(cat secrets/sihsalus_admin_password.txt)
KEYCLOAK_ADMIN_PASSWORD_VALUE=$(cat secrets/keycloak_admin_password.txt)
KC_DB_PASSWORD_VALUE=$(cat secrets/keycloak_db_password.txt)
OAUTH2_CLIENT_SECRET_VALUE=$(cat secrets/oauth2_client_secret.txt)
GRAFANA_ADMIN_PASSWORD_VALUE=$(cat secrets/grafana_admin_password.txt)
FUA_DB_PASSWORD_VALUE=$(cat secrets/fua_db_password.txt)
FUA_TOKEN_VALUE=$(cat secrets/fua_token.txt)
HAPI_DB_PASSWORD_VALUE=$(cat secrets/hapi_db_password.txt)

cat > .env.production << EOF
# .env.production
# IMPORTANTE: Este archivo contiene secretos en variables de entorno planas.
# El stack actual de Docker Compose NO usa Docker secrets.

# Core SIHSALUS / PostgreSQL
SIHSALUS_POSTGRES_DB=sihsalus
SIHSALUS_POSTGRES_USER=sihsalus
SIHSALUS_POSTGRES_PASSWORD=${SIHSALUS_POSTGRES_PASSWORD_VALUE}

# Backend bootstrap admin
SIHSALUS_ADMIN_USERNAME=admin
SIHSALUS_ADMIN_PASSWORD=${SIHSALUS_ADMIN_PASSWORD_VALUE}

# Static OCL/content import
SIHSALUS_OCL_STATIC_IMPORT_ENABLED=true
SIHSALUS_OCL_STATIC_IMPORT_FAIL_ON_ERRORS=true

# Tags de imagenes Docker
SIHSALUS_BACKEND_IMAGE=ghcr.io/sihsalus/sihsalus-core:latest
FRONTEND_SOURCE_TAG=latest
FRONTEND_RUNTIME_TAG=latest

# Keycloak
KEYCLOAK_ADMIN=admin
KEYCLOAK_ADMIN_PASSWORD=${KEYCLOAK_ADMIN_PASSWORD_VALUE}
KC_DB_DATABASE=keycloak
KC_DB_USERNAME=keycloak
KC_DB_PASSWORD=${KC_DB_PASSWORD_VALUE}
KC_HOSTNAME=localhost
KEYCLOAK_PORT=8180
KEYCLOAK_PUBLIC_URL=http://localhost:8180
OAUTH2_ENABLED=false
OAUTH2_CLIENT_SECRET=${OAUTH2_CLIENT_SECRET_VALUE}

# Grafana
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD_VALUE}

# FUA Generator
SIHSALUS_FUA_GEN_DB_USER=fuagenerator
SIHSALUS_FUA_GEN_DB_PASSWORD=${FUA_DB_PASSWORD_VALUE}
SIHSALUS_FUA_GEN_DB=fuagenerator
SIHSALUS_FUA_GEN_TOKEN=${FUA_TOKEN_VALUE}

# HAPI FHIR
HAPI_DB_USER=hapi
HAPI_DB_PASSWORD=${HAPI_DB_PASSWORD_VALUE}
HAPI_DB_NAME=hapi
EOF

echo "✅ Plantilla .env.production creada"
echo ""

# Crear .gitignore para secrets
cat > secrets/.gitignore << 'EOF'
# NO commitear secrets a Git
*
!.gitignore
EOF

echo "✅ .gitignore configurado para secrets/"
echo ""

# Instrucciones
echo "========================================="
echo "✅ Setup completado!"
echo "========================================="
echo ""
echo "PRÓXIMOS PASOS:"
echo ""
echo "1. Revisar y ajustar .env.production según tu entorno"
echo ""
echo "2. Iniciar usando el archivo generado:"
echo "   docker compose --env-file .env.production up -d"
echo ""
echo "3. Si prefieres el flujo por defecto de Docker Compose:"
echo "   cp .env.production .env"
echo "   docker compose up -d"
echo ""
echo "4. IMPORTANTE: Hacer backup de ./secrets/ en ubicación segura"
echo ""
echo "5. Documentar contraseñas en gestor de passwords (1Password, Bitwarden, etc.)"
echo ""
echo "========================================="
echo "⚠️  ADVERTENCIA DE SEGURIDAD"
echo "========================================="
echo ""
echo "- NO commitear ./secrets/ a Git"
echo "- NO compartir contraseñas por email/chat"
echo "- Usar gestor de passwords corporativo"
echo "- Cambiar contraseñas periódicamente"
echo "- Revocar acceso cuando empleados dejen el hospital"
echo ""
echo "========================================="
