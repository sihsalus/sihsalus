#!/bin/bash
set -euo pipefail

: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is required when enabling the replica profile}"
: "${MYSQL_PASSWORD:?MYSQL_OPENMRS_PASSWORD is required when enabling the replica profile}"
: "${OMRS_DB_REPL_PASSWORD:?OMRS_DB_REPL_PASSWORD is required when enabling the replica profile}"

exec docker-entrypoint.sh "$@"
