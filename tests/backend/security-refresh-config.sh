#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - \
  "$ROOT_DIR/backend/Dockerfile" \
  "$ROOT_DIR/.github/workflows/build-backend.yml" \
  "$ROOT_DIR/.github/workflows/ci.yml" <<'PY'
import pathlib
import sys


def require_once(text, value, source):
    if text.count(value) != 1:
        raise SystemExit(f"[FAIL] {source} must contain exactly once: {value}")


dockerfile = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
publisher = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
ci = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")

require_once(dockerfile, "ARG SECURITY_REFRESH=local", "backend/Dockerfile")
require_once(dockerfile, 'echo "Security refresh: ${SECURITY_REFRESH}"', "backend/Dockerfile")
require_once(publisher, "SECURITY_REFRESH=${{ github.sha }}", "build-backend workflow")
require_once(ci, '--build-arg SECURITY_REFRESH="${GITHUB_SHA}"', "CI workflow")

print("[OK] backend security updates are refreshed for every CI commit")
PY
