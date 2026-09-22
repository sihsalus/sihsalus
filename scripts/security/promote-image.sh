#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <registry/image@sha256:digest> <source SHA> <true|false: promote latest>" >&2
  exit 2
fi
IMAGE="$1"
SOURCE_SHA="$2"
PROMOTE_LATEST="$3"
[[ "$PROMOTE_LATEST" == true || "$PROMOTE_LATEST" == false ]] || exit 2

# Promotion cannot accidentally consume another image's successful evidence.
python3 - "$IMAGE" "$SOURCE_SHA" <<'PY'
import importlib.util
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location('image_policy', 'scripts/security/image-policy.py')
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)
try:
    image, source = sys.argv[1:]
    evidence = policy.read_json(Path('security-evidence/evidence.json'))
    exceptions = policy.read_json(Path('security/image-exceptions.json'))
    policy.validate_promotion(evidence, image, source, exceptions)
except (policy.PolicyError, OSError, ValueError, TypeError, KeyError):
    sys.exit('Verified image security evidence is required before promotion')
PY

REPOSITORY="${IMAGE%@*}"
EXPECTED_DIGEST="${IMAGE##*@}"
TAGS=("sha-${SOURCE_SHA}")
if [ "$PROMOTE_LATEST" = true ]; then
  TAGS+=(latest)
fi
for tag in "${TAGS[@]}"; do
  docker buildx imagetools create --prefer-index=false --tag "${REPOSITORY}:${tag}" "$IMAGE"
  actual="$(docker buildx imagetools inspect "${REPOSITORY}:${tag}" --format '{{.Manifest.Digest}}')"
  if [ "$actual" != "$EXPECTED_DIGEST" ]; then
    echo "[image-security] promoted alias differs from the scanned and signed index" >&2
    exit 1
  fi
done
