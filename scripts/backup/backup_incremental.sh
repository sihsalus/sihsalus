#!/bin/bash
# ------------------------------------------------------------------------------
# Script: backup_incremental.sh
# Descripción: Realiza un backup incremental de la base de datos MariaDB del contenedor especificado.
# Uso: ./backup_incremental.sh [--container NOMBRE] [--dir DIRECTORIO] [--max N]
# Autor: Equipo SIHSALUS
# Fecha: 2025-10-20
# ------------------------------------------------------------------------------

set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-sihsalus-db-master}"
FULL_BACKUP_DIR="${FULL_BACKUP_DIR:-/home/${USER}/sihsalus-fullBackups}"
MAX_BACKUPS="${MAX_BACKUPS:-10}"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
BACKUP_NAME="incr_$TIMESTAMP"
TEMP_FULL_BACKUP_PATH="/backup/full"
TEMP_INCR_BACKUP_PATH="/backup/inc"

# Leer credenciales sensibles desde Docker secrets si existen
if [ -f /run/secrets/OMRS_DB_R_PASSWORD ]; then
  export OMRS_DB_R_PASSWORD="$(cat /run/secrets/OMRS_DB_R_PASSWORD)"
fi
if [ -f /run/secrets/OMRS_DB_BACKUP_PASSWORD ]; then
  export OMRS_DB_BACKUP_PASSWORD="$(cat /run/secrets/OMRS_DB_BACKUP_PASSWORD)"
fi
if [ -f /run/secrets/BACKUP_ENCRYPTION_PASSWORD ]; then
  export BACKUP_ENCRYPTION_PASSWORD="$(cat /run/secrets/BACKUP_ENCRYPTION_PASSWORD)"
fi

if [ -n "${OMRS_DB_BACKUP_USER:-}" ] || [ -n "${OMRS_DB_BACKUP_PASSWORD:-}" ]; then
    : "${OMRS_DB_BACKUP_USER:?OMRS_DB_BACKUP_USER requerido si defines OMRS_DB_BACKUP_PASSWORD}"
    : "${OMRS_DB_BACKUP_PASSWORD:?OMRS_DB_BACKUP_PASSWORD requerido si defines OMRS_DB_BACKUP_USER}"
    DB_BACKUP_USER="$OMRS_DB_BACKUP_USER"
    DB_BACKUP_PASSWORD="$OMRS_DB_BACKUP_PASSWORD"
else
    DB_BACKUP_USER="root"
    DB_BACKUP_PASSWORD="${MYSQL_ROOT_PASSWORD:-${OMRS_DB_R_PASSWORD:-}}"
fi

# Parseo de argumentos
while [[ $# -gt 0 ]]; do
    case $1 in
        --container)
            CONTAINER_NAME="$2"; shift 2;;
        --dir)
            FULL_BACKUP_DIR="$2"; shift 2;;
        --max)
            MAX_BACKUPS="$2"; shift 2;;
        *)
            echo "Uso: $0 [--container NOMBRE] [--dir DIRECTORIO] [--max N]"; exit 1;;
    esac
done


# Rotación de logs: mantener solo los últimos 5 logs
LOG_FILE="$FULL_BACKUP_DIR/incrementalBackup_log.txt"
mkdir -p "$FULL_BACKUP_DIR"
mapfile -t LOG_FILES < <(find "$FULL_BACKUP_DIR" -maxdepth 1 -type f -name 'incrementalBackup_log.txt*' -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
if [ "${#LOG_FILES[@]}" -gt 5 ]; then
    printf '%s\0' "${LOG_FILES[@]:5}" | xargs -0 rm -f
fi
# Renombrar log anterior si existe
if [ -f "$LOG_FILE" ]; then
    mv "$LOG_FILE" "$LOG_FILE.$(date +%Y%m%d%H%M%S)"
fi
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[INFO] Iniciando backup incremental $TIMESTAMP para contenedor $CONTAINER_NAME"

if [ -z "$DB_BACKUP_PASSWORD" ]; then
    echo "[ERROR] Define OMRS_DB_BACKUP_USER/OMRS_DB_BACKUP_PASSWORD o MYSQL_ROOT_PASSWORD antes de ejecutar el backup." >&2
    exit 2
fi

if ! docker ps -a --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
    echo "[ERROR] Contenedor '$CONTAINER_NAME' no encontrado."; exit 1
fi

# Verificar directorio de backups
if [ ! -d "$FULL_BACKUP_DIR" ]; then
    echo "[ERROR] Directorio '$FULL_BACKUP_DIR' no existe."; exit 1
fi

# Crear backup incremental dentro del contenedor
docker exec --user root "$CONTAINER_NAME" rm -rf "$TEMP_INCR_BACKUP_PATH"
docker exec --user root "$CONTAINER_NAME" mariadb-backup --user="$DB_BACKUP_USER" --password="$DB_BACKUP_PASSWORD" --backup --incremental-basedir="$TEMP_FULL_BACKUP_PATH" --target-dir="$TEMP_INCR_BACKUP_PATH"

# Copiar backup al host
docker cp "$CONTAINER_NAME:$TEMP_INCR_BACKUP_PATH" "$FULL_BACKUP_DIR/$BACKUP_NAME"

# Comprimir backup
# Comprimir backup
tar -czf "$FULL_BACKUP_DIR/$BACKUP_NAME.tar.gz" -C "$FULL_BACKUP_DIR" "$BACKUP_NAME"
rm -rf "$FULL_BACKUP_DIR/$BACKUP_NAME"

# Cifrar backup con openssl (AES-256)
if [ -z "${BACKUP_ENCRYPTION_PASSWORD:-}" ]; then
    echo "[ERROR] Variable BACKUP_ENCRYPTION_PASSWORD no definida. Abortando cifrado." >&2
    exit 2
fi
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

# Rotar backups antiguos
BACKUP_COUNT=$(ls -1 "$FULL_BACKUP_DIR"/*.tar.gz.enc 2>/dev/null | wc -l)
if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
    ls -1t "$FULL_BACKUP_DIR"/*.tar.gz.enc | tail -n +$((MAX_BACKUPS+1)) | xargs rm -f
    echo "[INFO] Se eliminaron backups antiguos, manteniendo los últimos $MAX_BACKUPS."
fi

echo "[OK] Backup incremental realizado en '$FULL_BACKUP_DIR/$BACKUP_NAME.tar.gz.enc'"
