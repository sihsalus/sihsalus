#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 1 ] || [[ ! "$1" =~ ^[a-z0-9-]+$ ]]; then
  echo "Usage: $0 <log-prefix>" >&2
  exit 2
fi

LOG_PREFIX="$1"
TRACKED_CHANGES="$(git status --porcelain=v1 --untracked-files=no)"

for compose_override in docker-compose.override.yml docker-compose.override.yaml compose.override.yml compose.override.yaml; do
  if [ -e "$compose_override" ] && ! git ls-files --error-unmatch -- "$compose_override" >/dev/null 2>&1; then
    echo "[${LOG_PREFIX}] untracked automatic Compose override detected: ${compose_override}; refusing to deploy" >&2
    echo "[${LOG_PREFIX}] move the override to a reviewed Compose file selected explicitly through COMPOSE_FILE" >&2
    exit 1
  fi
done

if [ -z "$TRACKED_CHANGES" ]; then
  exit 0
fi

echo "[${LOG_PREFIX}] tracked files contain local changes; refusing to deploy:" >&2
while IFS= read -r change; do
  printf '[%s]   %s\n' "$LOG_PREFIX" "$change" >&2
done <<<"$TRACKED_CHANGES"
echo "[${LOG_PREFIX}] restore the reviewed checkout or move these changes to a pull request before retrying" >&2
exit 1
