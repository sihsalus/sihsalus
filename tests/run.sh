#!/usr/bin/env bash
# Fast local contracts: synthetic fixtures, no Docker daemon or network required.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
if [[ "$#" -ne 0 ]]; then
  echo "Usage: $0" >&2
  exit 2
fi

for required in bash python3 node git jq gzip openssl; do
  command -v "$required" >/dev/null || { echo "Missing tool: $required" >&2; exit 1; }
done
export PYTHONDONTWRITEBYTECODE=1

node --test frontend/patch-config-urls.test.js
for check in \
  tests/backend/build-backend-config.sh \
  tests/backend/ocl-token-config.sh \
  tests/backend/forced-password-config.sh \
  tests/backend/source-omods-config.sh \
  tests/backend/o3forms-release-config.sh \
  tests/backend/tomcat-config-config.sh \
  tests/backend/vulnerability-ratchet-config.sh \
  tests/deploy/deploy-backend-test.sh \
  tests/deploy/redeploy-environment-policy.sh \
  tests/frontend/deploy-frontend.sh \
  tests/utils/safe-poweroff-policy.sh; do
  echo "[CHECK] $check"
  bash "$check"
done
bash tests/monitoring/config-validation.sh --static
bash tests/backend/o3forms-release-image.sh --self-test
python3 -B tests/backend/owned-module-releases.py --self-test
python3 -B -m unittest discover -s tests/deploy -p 'test_*.py' -v
python3 -B -m unittest discover -s tests/backup -p 'test_*.py' -v
python3 -B -m unittest discover -s tests/security -p 'test_*.py' -v
python3 -B scripts/security/image-policy.py check-policy scripts/security/image-exceptions.json
