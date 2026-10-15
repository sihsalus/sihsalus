#!/usr/bin/env bash
# Compatibility entry point; version selection and rollback have one implementation.
set -euo pipefail
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $0 <latest|published commit SHA> [expected digest]" >&2
  exit 2
fi
arguments=(update --backend "$1")
if [ "$#" -eq 2 ]; then arguments+=(--digest "$2"); fi
exec python3 "$(dirname "${BASH_SOURCE[0]}")/deploy.py" "${arguments[@]}"
