#!/bin/bash
# ------------------------------------------------------------------------------
# Script: backup_full.sh
# Descripción: Realiza un backup completo de la base de datos MariaDB del contenedor especificado.
# Uso: ./backup_full.sh [--container NOMBRE|ID] [--service SERVICIO] [--dir DIRECTORIO] [--max N]
# ------------------------------------------------------------------------------

set -euo pipefail
# The checkout that owns this script selects the Compose project (.env,
# COMPOSE_FILE, COMPOSE_PROFILES), so cron may start it from any directory.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/compose-container.sh"

DB_SERVICE="${DB_SERVICE:-db}"
CONTAINER_NAME="${CONTAINER_NAME:-}"
FULL_BACKUP_DIR="${FULL_BACKUP_DIR:-/home/${USER}/sihsalus-fullBackups}"
MAX_BACKUPS="${MAX_BACKUPS:-10}"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
BACKUP_NAME="backup_$TIMESTAMP"
TEMP_FULL_BACKUP_PATH="/backup/full"

if [ -n "${OMRS_DB_BACKUP_USER:-}" ] || [ -n "${OMRS_DB_BACKUP_PASSWORD:-}" ]; then
    : "${OMRS_DB_BACKUP_USER:?OMRS_DB_BACKUP_USER requerido si defines OMRS_DB_BACKUP_PASSWORD}"
    : "${OMRS_DB_BACKUP_PASSWORD:?OMRS_DB_BACKUP_PASSWORD requerido si defines OMRS_DB_BACKUP_USER}"
    DB_BACKUP_USER="$OMRS_DB_BACKUP_USER"
    DB_BACKUP_PASSWORD="$OMRS_DB_BACKUP_PASSWORD"
else
    DB_BACKUP_USER="root"
    DB_BACKUP_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --container)
            CONTAINER_NAME="$2"; shift 2;;
        --service)
            DB_SERVICE="$2"; shift 2;;
        --dir)
            FULL_BACKUP_DIR="$2"; shift 2;;
        --max)
            MAX_BACKUPS="$2"; shift 2;;
        *)
            echo "Uso: $0 [--container NOMBRE|ID] [--service SERVICIO] [--dir DIRECTORIO] [--max N]"; exit 1;;
    esac
done

# Validar antes de copiar datos o modificar el directorio de respaldos.
if [ -z "${BACKUP_ENCRYPTION_PASSWORD:-}" ]; then
    echo "[ERROR] Variable BACKUP_ENCRYPTION_PASSWORD no definida. No se inició el backup." >&2
    exit 2
fi
if [ -z "$DB_BACKUP_PASSWORD" ]; then
    echo "[ERROR] Define OMRS_DB_BACKUP_USER/OMRS_DB_BACKUP_PASSWORD o MYSQL_ROOT_PASSWORD antes de ejecutar el backup." >&2
    exit 2
fi
umask 077

# Rotación de logs: mantener solo los últimos 5 logs
LOG_FILE="$FULL_BACKUP_DIR/fullBackup_log.txt"
mkdir -p "$FULL_BACKUP_DIR"
mapfile -t LOG_FILES < <(find "$FULL_BACKUP_DIR" -maxdepth 1 -type f -name 'fullBackup_log.txt*' -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
if [ "${#LOG_FILES[@]}" -gt 5 ]; then
    printf '%s\0' "${LOG_FILES[@]:5}" | xargs -0 rm -f
fi
if [ -f "$LOG_FILE" ]; then
    mv "$LOG_FILE" "$LOG_FILE.$(date +%Y%m%d%H%M%S)"
fi
exec > >(tee -a "$LOG_FILE") 2>&1

# Sin --container ni CONTAINER_NAME, el contenedor se resuelve desde el
# servicio Compose del checkout (su .env, COMPOSE_FILE y COMPOSE_PROFILES),
# sin depender del directorio desde el que se invoca el script.
if [ -z "$CONTAINER_NAME" ]; then
    CONTAINER_NAME="$(require_compose_container "$DB_SERVICE" "$REPO_ROOT")"
fi

echo "[INFO] Iniciando backup completo $TIMESTAMP para contenedor $CONTAINER_NAME"

if ! docker inspect --type container "$CONTAINER_NAME" >/dev/null 2>&1; then
    echo "[ERROR] Contenedor '$CONTAINER_NAME' no encontrado."; exit 1
fi

if [ ! -d "$FULL_BACKUP_DIR" ]; then
    echo "[ERROR] Directorio '$FULL_BACKUP_DIR' no existe."; exit 1
fi

docker exec --user root "$CONTAINER_NAME" rm -rf "$TEMP_FULL_BACKUP_PATH"
docker exec --user root -e MYSQL_PWD="$DB_BACKUP_PASSWORD" "$CONTAINER_NAME" \
    mariadb-backup --user="$DB_BACKUP_USER" --backup --target-dir="$TEMP_FULL_BACKUP_PATH"

mkdir -m 700 "$FULL_BACKUP_DIR/$BACKUP_NAME"
docker cp "$CONTAINER_NAME:$TEMP_FULL_BACKUP_PATH/." "$FULL_BACKUP_DIR/$BACKUP_NAME"

tar -czf "$FULL_BACKUP_DIR/$BACKUP_NAME.tar.gz" -C "$FULL_BACKUP_DIR" "$BACKUP_NAME"
rm -rf "$FULL_BACKUP_DIR/$BACKUP_NAME"

openssl enc -aes-256-cbc -salt -pbkdf2 -pass env:BACKUP_ENCRYPTION_PASSWORD \
    -in "$FULL_BACKUP_DIR/$BACKUP_NAME.tar.gz" \
    -out "$FULL_BACKUP_DIR/$BACKUP_NAME.tar.gz.enc"
if [ $? -eq 0 ]; then
    rm -f "$FULL_BACKUP_DIR/$BACKUP_NAME.tar.gz"
    echo "[OK] Backup cifrado exitosamente en '$FULL_BACKUP_DIR/$BACKUP_NAME.tar.gz.enc'"
else
    echo "[ERROR] Falló el cifrado del backup. El archivo sin cifrar permanece."
    exit 3
fi

BACKUP_COUNT=$(ls -1 "$FULL_BACKUP_DIR"/*.tar.gz.enc 2>/dev/null | wc -l)
if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
    ls -1t "$FULL_BACKUP_DIR"/*.tar.gz.enc | tail -n +$((MAX_BACKUPS+1)) | xargs rm -f
    echo "[INFO] Se eliminaron backups antiguos, manteniendo los últimos $MAX_BACKUPS."
fi

echo "[OK] Backup completo realizado en '$FULL_BACKUP_DIR/$BACKUP_NAME.tar.gz.enc'"
