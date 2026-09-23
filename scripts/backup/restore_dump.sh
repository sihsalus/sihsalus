#!/bin/bash
# ------------------------------------------------------------------------------
# Script: restore_dump.sh
# Descripcion: Restaura la DB desde un dump SQL en caliente (sin detener la DB).
#              Compatible con backups de backup_dump.sh
# Uso: ./restore_dump.sh [--container NOMBRE] [--dir DIRECTORIO] [--file ARCHIVO] [--yes] [--no-app-control]
# ------------------------------------------------------------------------------

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CONTAINER_NAME="${CONTAINER_NAME:-sihsalus-db-master}"
BACKUP_DIR="${BACKUP_DIR:-/home/${USER}/sihsalus-dumps}"
BACKUP_FILE=""
DB_NAME="openmrs"
DB_USER="root"
TEMP_DIR=""
ASSUME_YES="${RESTORE_ASSUME_YES:-false}"
MANAGE_BACKEND="${RESTORE_MANAGE_BACKEND:-true}"

# Parseo de argumentos
while [[ $# -gt 0 ]]; do
    case $1 in
        --container) CONTAINER_NAME="$2"; shift 2;;
        --dir) BACKUP_DIR="$2"; shift 2;;
        --file) BACKUP_FILE="$2"; shift 2;;
        --yes) ASSUME_YES=true; shift;;
        --no-app-control) MANAGE_BACKEND=false; shift;;
        --help|-h)
            echo "Uso: $0 [--container NOMBRE] [--dir DIRECTORIO] [--file ARCHIVO] [--yes] [--no-app-control]"
            echo ""
            echo "  --yes             No solicita confirmacion interactiva."
            echo "  --no-app-control  No detiene ni inicia el backend (CI o control externo)."
            exit 0;;
        *) echo "Opcion desconocida: $1"; exit 1;;
    esac
done

DB_PASSWORD="${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD no definido}"
for flag in "$ASSUME_YES" "$MANAGE_BACKEND"; do
    case "$flag" in true|false) ;; *) echo "[ERROR] Las opciones de control deben ser true o false" >&2; exit 2;; esac
done

cleanup() {
    if [ -n "$TEMP_DIR" ]; then rm -rf "$TEMP_DIR"; fi
}
trap cleanup EXIT

# --- Seleccion de backup ---

if [ -n "$BACKUP_FILE" ]; then
    if [ ! -f "$BACKUP_FILE" ]; then
        echo -e "${RED}[ERROR] Archivo no encontrado: $BACKUP_FILE${NC}"; exit 1
    fi
    selected_file="$BACKUP_FILE"
else
    if [ ! -d "$BACKUP_DIR" ]; then
        echo -e "${RED}[ERROR] Directorio no encontrado: $BACKUP_DIR${NC}"; exit 1
    fi

    mapfile -t backups < <(ls -t "$BACKUP_DIR"/dump_*.sql.gz* 2>/dev/null)

    if [ ${#backups[@]} -eq 0 ]; then
        echo -e "${RED}[ERROR] No se encontraron dumps en $BACKUP_DIR${NC}"; exit 1
    fi

    echo ""
    echo "Dumps disponibles (mas reciente primero):"
    echo "-----------------------------------------------------------"
    for ((i=0; i<${#backups[@]}; i++)); do
        fname=$(basename "${backups[i]}")
        fsize=$(du -h "${backups[i]}" | cut -f1)
        fdate=$(stat -c '%y' "${backups[i]}" 2>/dev/null | cut -d'.' -f1)
        printf "  %2d) %-45s %6s  %s\n" "$((i+1))" "$fname" "$fsize" "$fdate"
    done
    echo "-----------------------------------------------------------"

    while true; do
        read -p "Selecciona el dump a restaurar (1-${#backups[@]}): " selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#backups[@]} ]; then
            selected_file="${backups[$((selection-1))]}"
            break
        fi
        echo "Seleccion invalida."
    done
fi

echo -e "[INFO] Dump seleccionado: ${GREEN}$(basename "$selected_file")${NC}"

# --- Confirmacion ---

echo ""
echo -e "${YELLOW}ATENCION: Esto reemplazara la base de datos '$DB_NAME'.${NC}"
echo -e "${YELLOW}El backend deberia estar detenido para evitar conflictos.${NC}"
if [ "$ASSUME_YES" != "true" ]; then
    read -p "Continuar? (s/N): " resp
    [[ "$resp" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 0; }
fi

# Validate and stage the exact input before stopping the application or deleting data.
umask 077
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sihsalus-restore-dump.XXXXXX")"
sql_source="$selected_file"

if [[ "$selected_file" == *.enc ]]; then
    echo "[INFO] Descifrando dump..."

    if [ -z "${BACKUP_ENCRYPTION_PASSWORD:-}" ]; then
        read -sp "Ingresa la clave de cifrado: " BACKUP_ENCRYPTION_PASSWORD
        echo ""
        export BACKUP_ENCRYPTION_PASSWORD
    fi

    decrypted_file="$TEMP_DIR/$(basename "${selected_file%.enc}")"
    if ! openssl enc -aes-256-cbc -d -salt -pbkdf2 \
        -pass env:BACKUP_ENCRYPTION_PASSWORD \
        -in "$selected_file" \
        -out "$decrypted_file"; then
        echo -e "${RED}[ERROR] Fallo al descifrar. Clave incorrecta?${NC}"; exit 1
    fi
    sql_source="$decrypted_file"
    echo -e "${GREEN}[OK] Descifrado exitoso${NC}"
fi

validated_sql="$TEMP_DIR/validated.sql"
if ! gzip -dc "$sql_source" >"$validated_sql" || [ ! -s "$validated_sql" ]; then
    echo "[ERROR] Dump gzip invalido, incompleto o vacio; no se modifico la base de datos" >&2
    exit 1
fi

if [ "$MANAGE_BACKEND" = "true" ]; then
    backend_containers="$(docker compose ps --all --quiet backend)"
    if [ -z "$backend_containers" ]; then
        echo "[ERROR] No existe un contenedor backend en este proyecto Compose; restauracion cancelada antes de modificar la base" >&2
        echo "[INFO] Para recuperacion con control externo de la aplicacion, usar --no-app-control y preparar su arranque por separado" >&2
        exit 1
    fi
    echo "[INFO] Deteniendo backend para evitar escrituras..."
    if ! docker compose stop backend; then
        echo "[ERROR] No se pudo detener el backend; restauracion cancelada" >&2
        exit 1
    fi
    running_backend="$(docker compose ps --status running --quiet backend)"
    if [ -n "$running_backend" ]; then
        echo "[ERROR] El backend sigue ejecutandose; restauracion cancelada" >&2
        exit 1
    fi
else
    echo "[INFO] Control del backend deshabilitado por --no-app-control"
fi

# --- Restaurar en caliente ---

echo "[INFO] Restaurando dump en la base de datos (en caliente)..."
echo "[INFO] Esto puede tomar varios minutos segun el tamano..."

# Drop y recrear la DB, luego importar
docker exec -i -e MYSQL_PWD="$DB_PASSWORD" "$CONTAINER_NAME" mariadb \
    --user="$DB_USER" \
    -e "DROP DATABASE IF EXISTS ${DB_NAME}; CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"

# Importar el dump
docker exec -i -e MYSQL_PWD="$DB_PASSWORD" "$CONTAINER_NAME" mariadb \
    --user="$DB_USER" \
    "$DB_NAME" <"$validated_sql"

echo -e "${GREEN}[OK] Dump restaurado exitosamente${NC}"

# --- Reiniciar backend ---

if [ "$MANAGE_BACKEND" = "true" ]; then
    echo "[INFO] Reiniciando backend..."
    # Resume the existing container with its original image and configuration.
    docker compose start backend
fi

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Restauracion en caliente completada${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
if [ "$MANAGE_BACKEND" = "true" ]; then
    echo "[INFO] Verifica que el backend inicie correctamente:"
    echo "  docker compose logs -f backend"
fi
