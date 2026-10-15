#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: $0 CANDIDATE_JSON BASELINE_JSON" >&2
  exit 2
fi
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$script_directory/image-policy.py" backend-ratchet \
  "$1" "$2" "$script_directory/image-exceptions.json"
