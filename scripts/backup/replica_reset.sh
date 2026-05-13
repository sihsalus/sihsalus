#!/bin/bash
# ------------------------------------------------------------------------------
# Script: replica_reset.sh
# Descripción: Reinicia la replicación de MariaDB/MySQL en el contenedor especificado.
# Uso: ./replica_reset.sh [--container NOMBRE] [--user USUARIO] [--password PASSWORD]
# Autor: Equipo SIHSALUS
# Fecha: 2025-10-20
# ------------------------------------------------------------------------------

set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-sihsalus-db-replic}"
MYSQL_USER="${MYSQL_USER:-openmrs_repl}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-${OMRS_DB_REPL_PASSWORD:-}}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
MYSQL_HOST="${MYSQL_HOST:-db}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MASTER_LOG_FILE="${MASTER_LOG_FILE:-}"
MASTER_LOG_POS="${MASTER_LOG_POS:-}"

# Parseo de argumentos
while [[ $# -gt 0 ]]; do
  case $1 in
    --container)
      CONTAINER_NAME="$2"; shift 2;;
    --user)
      MYSQL_USER="$2"; shift 2;;
    --password)
      MYSQL_PASSWORD="$2"; shift 2;;
    --host)
      MYSQL_HOST="$2"; shift 2;;
    --port)
      MYSQL_PORT="$2"; shift 2;;
    --master-log-file)
      MASTER_LOG_FILE="$2"; shift 2;;
    --master-log-pos)
      MASTER_LOG_POS="$2"; shift 2;;
    *)
      echo "Uso: $0 [--container NOMBRE] [--user USUARIO] [--password PASSWORD] [--host HOST] [--port PUERTO] [--master-log-file FILE] [--master-log-pos POS]"; exit 1;;
  esac
done

: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD no definido}"
: "${MYSQL_PASSWORD:?MYSQL_PASSWORD u OMRS_DB_REPL_PASSWORD no definido}"

CHANGE_MASTER="CHANGE MASTER TO MASTER_HOST='${MYSQL_HOST}', MASTER_USER='${MYSQL_USER}', MASTER_PASSWORD='${MYSQL_PASSWORD}', MASTER_PORT=${MYSQL_PORT}"
if [ -n "$MASTER_LOG_FILE" ] || [ -n "$MASTER_LOG_POS" ]; then
  : "${MASTER_LOG_FILE:?MASTER_LOG_FILE requerido si defines MASTER_LOG_POS}"
  : "${MASTER_LOG_POS:?MASTER_LOG_POS requerido si defines MASTER_LOG_FILE}"
  CHANGE_MASTER="${CHANGE_MASTER}, MASTER_LOG_FILE='${MASTER_LOG_FILE}', MASTER_LOG_POS=${MASTER_LOG_POS}"
fi

SQL_CMDS="STOP SLAVE; RESET SLAVE ALL; ${CHANGE_MASTER}; START SLAVE; SHOW SLAVE STATUS\\G;"

echo "[INFO] Reiniciando replicación en contenedor $CONTAINER_NAME..."

docker exec -i "$CONTAINER_NAME" mariadb -u root -p"$MYSQL_ROOT_PASSWORD" -e "$SQL_CMDS"

echo "[OK] Replicación reiniciada. Estado mostrado arriba."
