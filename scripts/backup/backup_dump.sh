#!/bin/bash
# ------------------------------------------------------------------------------
# Script: backup_dump.sh
# Descripcion: Backup logico en caliente de la base PostgreSQL del backend
#              sihsalus-core (sin downtime). Genera un .dump (formato custom de
#              pg_dump, ya comprimido) restaurable con restore_dump.sh.
# Uso: ./backup_dump.sh [--container NOMBRE] [--dir DIRECTORIO] [--max N]
# ------------------------------------------------------------------------------

set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-sihsalus-postgres}"
BACKUP_DIR="${BACKUP_DIR:-/home/${USER}/sihsalus-dumps}"
MAX_BACKUPS="${MAX_BACKUPS:-10}"
DB_NAME="${SIHSALUS_POSTGRES_DB:-sihsalus}"
DB_USER="${SIHSALUS_POSTGRES_USER:-sihsalus}"
DB_PASSWORD="${SIHSALUS_POSTGRES_PASSWORD:?SIHSALUS_POSTGRES_PASSWORD no definido}"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
DUMP_FILE="dump_${TIMESTAMP}.dump"

# Parseo de argumentos
while [[ $# -gt 0 ]]; do
    case $1 in
        --container) CONTAINER_NAME="$2"; shift 2;;
        --dir) BACKUP_DIR="$2"; shift 2;;
        --max) MAX_BACKUPS="$2"; shift 2;;
        --help|-h)
            echo "Uso: $0 [--container NOMBRE] [--dir DIRECTORIO] [--max N]"
            exit 0;;
        *) echo "Opcion desconocida: $1"; exit 1;;
    esac
done

mkdir -p "$BACKUP_DIR"

echo "[INFO] Iniciando dump PostgreSQL en caliente de '$DB_NAME' ($TIMESTAMP)"

# pg_dump en formato custom (-Fc): consistente por snapshot, sin bloqueos,
# ya comprimido y restaurable selectivamente con pg_restore.
docker exec -e PGPASSWORD="$DB_PASSWORD" "$CONTAINER_NAME" \
    pg_dump \
    --username="$DB_USER" \
    --dbname="$DB_NAME" \
    --format=custom \
    --no-owner \
    --no-privileges \
    > "$BACKUP_DIR/$DUMP_FILE"

DUMP_SIZE=$(du -h "$BACKUP_DIR/$DUMP_FILE" | cut -f1)
echo "[OK] Dump creado: $BACKUP_DIR/$DUMP_FILE ($DUMP_SIZE)"

# Cifrar si hay clave disponible
if [ -n "${BACKUP_ENCRYPTION_PASSWORD:-}" ]; then
    openssl enc -aes-256-cbc -salt -pbkdf2 \
        -pass env:BACKUP_ENCRYPTION_PASSWORD \
        -in "$BACKUP_DIR/$DUMP_FILE" \
        -out "$BACKUP_DIR/$DUMP_FILE.enc"
    rm -f "$BACKUP_DIR/$DUMP_FILE"
    echo "[OK] Cifrado: $BACKUP_DIR/$DUMP_FILE.enc"
    DUMP_FILE="$DUMP_FILE.enc"
fi

# Rotar backups antiguos
BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/dump_*.dump* 2>/dev/null | wc -l)
if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
    ls -1t "$BACKUP_DIR"/dump_*.dump* | tail -n +$((MAX_BACKUPS+1)) | xargs rm -f
    echo "[INFO] Rotados, manteniendo los ultimos $MAX_BACKUPS"
fi

echo "[OK] Backup PostgreSQL completado sin downtime"
