#!/bin/bash
# ------------------------------------------------------------------------------
# Script: backup_dump.sh
# Descripcion: Backup SQL logico en caliente (sin detener la DB).
#              Genera un .sql.gz que se puede restaurar con restore_dump.sh
# Uso: ./backup_dump.sh [--container NOMBRE|ID] [--service SERVICIO] [--dir DIRECTORIO] [--max N]
# ------------------------------------------------------------------------------

set -euo pipefail
# The checkout that owns this script selects the Compose project (.env,
# COMPOSE_FILE, COMPOSE_PROFILES), so cron may start it from any directory.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/compose-container.sh"

DB_SERVICE="${DB_SERVICE:-db}"
CONTAINER_NAME="${CONTAINER_NAME:-}"
BACKUP_DIR="${BACKUP_DIR:-/home/${USER}/sihsalus-dumps}"
MAX_BACKUPS="${MAX_BACKUPS:-10}"
DB_NAME="openmrs"
DB_USER="root"
DB_PASSWORD="${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD no definido}"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
DUMP_FILE="dump_${TIMESTAMP}.sql.gz"

while [[ $# -gt 0 ]]; do
    case $1 in
        --container) CONTAINER_NAME="$2"; shift 2;;
        --service) DB_SERVICE="$2"; shift 2;;
        --dir) BACKUP_DIR="$2"; shift 2;;
        --max) MAX_BACKUPS="$2"; shift 2;;
        --help|-h)
            echo "Uso: $0 [--container NOMBRE|ID] [--service SERVICIO] [--dir DIRECTORIO] [--max N]"
            exit 0;;
        *) echo "Opcion desconocida: $1"; exit 1;;
    esac
done

# Sin --container ni CONTAINER_NAME, el contenedor se resuelve desde el
# servicio Compose del checkout (su .env, COMPOSE_FILE y COMPOSE_PROFILES),
# sin depender del directorio desde el que se invoca el script.
if [ -z "$CONTAINER_NAME" ]; then
    CONTAINER_NAME="$(require_compose_container "$DB_SERVICE" "$REPO_ROOT")"
fi

mkdir -p "$BACKUP_DIR"

echo "[INFO] Iniciando dump SQL en caliente de '$DB_NAME' ($TIMESTAMP)"

# Dump en caliente con --single-transaction (consistente, sin bloqueo)
docker exec -e MYSQL_PWD="$DB_PASSWORD" "$CONTAINER_NAME" \
    mariadb-dump \
    --user="$DB_USER" \
    --single-transaction \
    --routines \
    --triggers \
    --events \
    --quick \
    --lock-tables=false \
    "$DB_NAME" | gzip > "$BACKUP_DIR/$DUMP_FILE"

DUMP_SIZE=$(du -h "$BACKUP_DIR/$DUMP_FILE" | cut -f1)
echo "[OK] Dump creado: $BACKUP_DIR/$DUMP_FILE ($DUMP_SIZE)"

if [ -n "${BACKUP_ENCRYPTION_PASSWORD:-}" ]; then
    openssl enc -aes-256-cbc -salt -pbkdf2 \
        -pass env:BACKUP_ENCRYPTION_PASSWORD \
        -in "$BACKUP_DIR/$DUMP_FILE" \
        -out "$BACKUP_DIR/$DUMP_FILE.enc"
    rm -f "$BACKUP_DIR/$DUMP_FILE"
    echo "[OK] Cifrado: $BACKUP_DIR/$DUMP_FILE.enc"
    DUMP_FILE="$DUMP_FILE.enc"
fi

BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/dump_*.sql.gz* 2>/dev/null | wc -l)
if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
    ls -1t "$BACKUP_DIR"/dump_*.sql.gz* | tail -n +$((MAX_BACKUPS+1)) | xargs rm -f
    echo "[INFO] Rotados, manteniendo los ultimos $MAX_BACKUPS"
fi

echo "[OK] Backup SQL completado sin downtime"
