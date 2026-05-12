#!/bin/bash
set -e

: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD no definido}"

echo "Initializing master db container"
mariadb -u root -p"${MYSQL_ROOT_PASSWORD}" -e "SHOW MASTER STATUS;"

if [ -n "${OMRS_DB_REPL_USER:-}" ] && [ -n "${OMRS_DB_REPL_PASSWORD:-}" ]; then
    mariadb -u root -p"${MYSQL_ROOT_PASSWORD}" -e "
        SELECT '=== Creating replication user before initialization ===';
        CREATE USER IF NOT EXISTS '${OMRS_DB_REPL_USER}'@'%' IDENTIFIED BY '${OMRS_DB_REPL_PASSWORD}';
        SELECT '=== Granting replication user before initialization ===';
        GRANT RELOAD, LOCK TABLES, PROCESS, REPLICATION SLAVE, BINLOG MONITOR ON *.* TO '${OMRS_DB_REPL_USER}'@'%';
        FLUSH PRIVILEGES;
    "
else
    echo "Skipping replication user creation; OMRS_DB_REPL_USER/OMRS_DB_REPL_PASSWORD not fully defined."
fi

if [ -n "${OMRS_DB_BACKUP_USER:-}" ] && [ -n "${OMRS_DB_BACKUP_PASSWORD:-}" ]; then
    mariadb -u root -p"${MYSQL_ROOT_PASSWORD}" -e "
        SELECT '=== Create backup user ===';
        CREATE USER IF NOT EXISTS '${OMRS_DB_BACKUP_USER}'@'%' IDENTIFIED BY '${OMRS_DB_BACKUP_PASSWORD}';
        SELECT '=== Granting permissions backup user ===';
        GRANT RELOAD, PROCESS, LOCK TABLES, REPLICATION CLIENT, REPLICA MONITOR, REPLICATION SLAVE ADMIN ON *.* TO '${OMRS_DB_BACKUP_USER}'@'%';
        FLUSH PRIVILEGES;
    "
else
    echo "Skipping backup user creation; OMRS_DB_BACKUP_USER/OMRS_DB_BACKUP_PASSWORD not fully defined."
fi
