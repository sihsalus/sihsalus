#!/bin/bash
# Script de verificación post-instalación para sihsalus

set -e

echo "========================================"
echo "sihsalus - Verificación de Instalación"
echo "========================================"
echo ""

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Función para verificar si un contenedor está corriendo
check_container() {
    local container_name=$1
    if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo -e "${GREEN}✓${NC} ${container_name} está corriendo"
        return 0
    else
        echo -e "${RED}✗${NC} ${container_name} NO está corriendo"
        return 1
    fi
}

# Función para verificar el health status
check_health() {
    local container_name=$1
    local health=$(docker inspect --format='{{.State.Health.Status}}' ${container_name} 2>/dev/null || echo "no-healthcheck")

    if [ "$health" = "healthy" ]; then
        echo -e "  ${GREEN}✓${NC} Health: healthy"
        return 0
    elif [ "$health" = "no-healthcheck" ]; then
        echo -e "  ${YELLOW}⚠${NC} Health: sin healthcheck configurado"
        return 0
    else
        echo -e "  ${RED}✗${NC} Health: ${health}"
        return 1
    fi
}

echo "1. Verificando contenedores críticos..."
echo "----------------------------------------"

critical_containers=(
    "sihsalus-postgres"
    "sihsalus-backend"
    "sihsalus-frontend"
    "sihsalus-gateway"
    "sihsalus-keycloak"
    "sihsalus-keycloak-db"
)

all_ok=true
for container in "${critical_containers[@]}"; do
    if check_container "$container"; then
        check_health "$container" || all_ok=false
    else
        all_ok=false
    fi
done
echo ""

echo "2. Verificando conectividad a base de datos..."
echo "-----------------------------------------------"

DB_NAME="${SIHSALUS_POSTGRES_DB:-sihsalus}"
DB_USER="${SIHSALUS_POSTGRES_USER:-sihsalus}"

# Verificar que PostgreSQL acepta conexiones
if docker exec sihsalus-postgres pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} PostgreSQL acepta conexiones ($DB_USER@$DB_NAME)"
else
    echo -e "${RED}✗${NC} PostgreSQL no acepta conexiones (verificar contenedor/credenciales)"
    all_ok=false
fi

# Verificar que la base del backend existe y es consultable
if docker exec -e PGPASSWORD="${SIHSALUS_POSTGRES_PASSWORD:-}" sihsalus-postgres \
    psql -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT 1;" 2>/dev/null | grep -q 1; then
    echo -e "${GREEN}✓${NC} Base '$DB_NAME' consultable por '$DB_USER'"
else
    echo -e "${YELLOW}⚠${NC} No se pudo consultar '$DB_NAME' (define SIHSALUS_POSTGRES_PASSWORD para esta verificación)"
fi
echo ""

echo "3. Verificando puertos expuestos..."
echo "------------------------------------"
ports_to_check=(
    "80:Gateway HTTP"
    "443:Gateway HTTPS"
    "8080:Backend OpenMRS"
    "8180:Keycloak"
    "5432:PostgreSQL"
)

for port_info in "${ports_to_check[@]}"; do
    port=$(echo $port_info | cut -d':' -f1)
    service=$(echo $port_info | cut -d':' -f2)

    if netstat -tuln 2>/dev/null | grep -q ":${port} " || ss -tuln 2>/dev/null | grep -q ":${port} "; then
        echo -e "${GREEN}✓${NC} Puerto ${port} (${service}) está escuchando"
    else
        echo -e "${YELLOW}⚠${NC} Puerto ${port} (${service}) no parece estar escuchando"
    fi
done
echo ""

echo "4. Verificando logs recientes de errores..."
echo "--------------------------------------------"
error_count=$(docker logs sihsalus-backend --tail 100 2>&1 | grep -i "error\|exception\|failed" | grep -v "WARN" | wc -l)
if [ $error_count -eq 0 ]; then
    echo -e "${GREEN}✓${NC} No se encontraron errores recientes en el backend"
else
    echo -e "${YELLOW}⚠${NC} Se encontraron ${error_count} líneas con errores en el backend"
    echo "  Ejecuta: docker logs sihsalus-backend --tail 100"
fi
echo ""

echo "========================================"
if [ "$all_ok" = true ]; then
    echo -e "${GREEN}✓ Sistema verificado correctamente${NC}"
    echo ""
    echo "Accede a OpenMRS en:"
    echo "  → http://localhost/openmrs"
    echo ""
    echo "Credenciales por defecto:"
    echo "  Usuario: admin"
    echo "  Contraseña: Admin123"
else
    echo -e "${RED}✗ Se encontraron problemas en el sistema${NC}"
    echo ""
    echo "Revisa los errores arriba y consulta:"
    echo "  → docs/TROUBLESHOOTING.md"
fi
echo "========================================"
