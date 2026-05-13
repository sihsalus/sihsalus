#!/bin/bash
set -e

: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD no definido}"
: "${OMRS_DB_REPL_USER:?OMRS_DB_REPL_USER no definido}"
: "${OMRS_DB_REPL_PASSWORD:?OMRS_DB_REPL_PASSWORD no definido}"

echo "Initializing replic db container"
mariadb -u root -p"${MYSQL_ROOT_PASSWORD}" -e "
  SELECT '=== Connecting using replication user before initialization ===';
  STOP SLAVE;
  RESET SLAVE ALL;
  CHANGE MASTER TO 
    MASTER_HOST='db',
    MASTER_USER='${OMRS_DB_REPL_USER}',
    MASTER_PASSWORD='${OMRS_DB_REPL_PASSWORD}',
    MASTER_PORT=3306,
    MASTER_USE_GTID=slave_pos;
  FLUSH PRIVILEGES;
  SELECT '=== Starting replication process ===';
  START SLAVE;
  SELECT '=== Showing replication status before initialization ===';
  SHOW SLAVE STATUS\G;
"
