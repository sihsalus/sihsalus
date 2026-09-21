#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <registry/image@sha256:digest> <source SHA> <new evidence directory>" >&2
  exit 2
fi

IMAGE="$1"
SOURCE_SHA="$2"
OUTPUT_DIRECTORY="$3"
SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/../.." && pwd)"
POLICY="$SCRIPT_DIRECTORY/image-policy.py"
EXCEPTIONS="$ROOT_DIRECTORY/security/image-exceptions.json"

[[ "$IMAGE" =~ ^[a-z0-9][a-z0-9.:-]*(/[a-z0-9][a-z0-9._-]*)+@sha256:[0-9a-f]{64}$ ]] || {
  echo "[image-security] an exact registry digest is required" >&2
  exit 2
}
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || {
  echo "[image-security] a complete source commit is required" >&2
  exit 2
}

for required in python3 docker trivy; do
  command -v "$required" >/dev/null || { echo "[image-security] a required tool is unavailable" >&2; exit 2; }
done
python3 "$POLICY" check-policy "$EXCEPTIONS"

# Never overwrite previous evidence. Raw scanner output can include image ENV
# and other metadata even when only the vulnerability scanner is enabled.
umask 077
mkdir "$OUTPUT_DIRECTORY"
OUTPUT_DIRECTORY="$(cd "$OUTPUT_DIRECTORY" && pwd)"
TEMP_DIRECTORY="$(mktemp -d)"
cleanup() { rm -rf -- "$TEMP_DIRECTORY"; }
trap cleanup EXIT
PHASE=version
failed() {
  echo "[image-security] ${PHASE} failed; raw image configuration and scanner output are not displayed" >&2
}
trap failed ERR

trivy --version >"$TEMP_DIRECTORY/version.txt" 2>"$TEMP_DIRECTORY/tool-error.txt"
SCANNER_VERSION="$(sed -n 's/^Version: \([0-9][0-9.]*\)$/\1/p' "$TEMP_DIRECTORY/version.txt")"
[[ "$SCANNER_VERSION" == "0.74.0" ]] || {
  echo "[image-security] Trivy 0.74.0 is required for the reviewed report contract" >&2
  exit 2
}

PHASE=index
docker buildx imagetools inspect "$IMAGE" --raw >"$TEMP_DIRECTORY/index.json" 2>"$TEMP_DIRECTORY/tool-error.txt"
python3 "$POLICY" platforms "$IMAGE" "$TEMP_DIRECTORY/index.json" >"$TEMP_DIRECTORY/platforms.tsv"
PHASE=sbom
docker buildx imagetools inspect "$IMAGE" --format '{{json .SBOM}}' >"$TEMP_DIRECTORY/sbom.json" 2>"$TEMP_DIRECTORY/tool-error.txt"
printf '{}\n' >"$TEMP_DIRECTORY/trivy.yaml"

REPOSITORY="${IMAGE%@*}"
INSECURE=false
if [[ "$REPOSITORY" =~ ^(localhost|127\.0\.0\.1):[0-9]+/ ]]; then
  # Isolated CI registry only. Public registries retain TLS verification.
  INSECURE=true
fi

while IFS=$'\t' read -r platform child_digest; do
  PHASE="scan-${platform}"
  report="$TEMP_DIRECTORY/${platform/\//-}.json"
  trivy image \
    --image-src remote \
    --platform "$platform" \
    --insecure="$INSECURE" \
    --config "$TEMP_DIRECTORY/trivy.yaml" \
    --scanners vuln \
    --pkg-types os,library \
    --severity HIGH,CRITICAL \
    --ignore-unfixed=false \
    --skip-db-update=false \
    --skip-java-db-update=false \
    --ignorefile /dev/null \
    --ignore-policy '' \
    --skip-dirs '' \
    --skip-files '' \
    --exit-code 0 \
    --timeout 15m \
    --no-progress \
    --format json \
    --output "$report" \
    "${REPOSITORY}@${child_digest}" \
    >"$TEMP_DIRECTORY/tool-output.txt" 2>"$TEMP_DIRECTORY/tool-error.txt"
done <"$TEMP_DIRECTORY/platforms.tsv"

PHASE=policy
python3 "$POLICY" evaluate \
  --image "$IMAGE" --source "$SOURCE_SHA" --scanner "$SCANNER_VERSION" \
  --index "$TEMP_DIRECTORY/index.json" --sbom "$TEMP_DIRECTORY/sbom.json" \
  --reports "$TEMP_DIRECTORY" --policy "$EXCEPTIONS" \
  --output "$OUTPUT_DIRECTORY/evidence.json"
