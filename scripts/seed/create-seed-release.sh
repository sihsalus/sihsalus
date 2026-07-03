#!/bin/sh
set -eu

GH_REPO="${GH_REPO:-sihsalus/sihsalus}"
COMPOSE_PROFILES="${COMPOSE_PROFILES:-fua,imaging,monitoring}"
export COMPOSE_PROFILES

for cmd in docker git gh sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "[seed] missing command: $cmd" >&2
    exit 1
  }
done

[ -f docker-compose.yml ] || {
  echo "[seed] run this from the sihsalus repo root" >&2
  exit 1
}

gh auth status --hostname github.com >/dev/null
docker compose ps
docker exec sihsalus-backend curl -fsS http://localhost:8080/openmrs/health/started >/dev/null

GIT_SHA="$(git rev-parse --short HEAD)"
TAG="${SEED_TAG:-seed-content-${GIT_SHA}-$(date -u +%Y%m%d%H%M%S)}"
OUT="${SEED_OUT_DIR:-$HOME/sihsalus-seeds/$TAG}"
mkdir -p "$OUT"

DB_VOL="$(docker inspect sihsalus-db-master --format '{{range .Mounts}}{{if eq .Destination "/var/lib/mysql"}}{{.Name}}{{end}}{{end}}')"
OMRS_VOL="$(docker inspect sihsalus-backend --format '{{range .Mounts}}{{if eq .Destination "/openmrs/data"}}{{.Name}}{{end}}{{end}}')"
FUA_VOL="$(docker inspect sihsalus-fua-generator-db --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' 2>/dev/null || true)"

[ -n "$DB_VOL" ] || { echo "[seed] db volume not found" >&2; exit 1; }
[ -n "$OMRS_VOL" ] || { echo "[seed] openmrs volume not found" >&2; exit 1; }

restart_stack() {
  docker compose up -d >/dev/null
}

RESTART_NEEDED=false
cleanup() {
  if [ "$RESTART_NEEDED" = true ]; then
    restart_stack
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

echo "[seed] stopping writers"
docker compose stop backend fua-generator >/dev/null 2>&1 || true
docker compose stop db fua-generator-db >/dev/null 2>&1 || true
RESTART_NEEDED=true

echo "[seed] archiving db-data"
docker run --rm -v "$DB_VOL":/volume:ro -v "$OUT":/backup busybox \
  sh -c 'cd /volume && tar czf /backup/db-data.tar.gz .'

echo "[seed] archiving openmrs-data"
docker run --rm -v "$OMRS_VOL":/volume:ro -v "$OUT":/backup busybox \
  sh -c 'cd /volume && tar czf /backup/openmrs-data.tar.gz .'

if [ -n "$FUA_VOL" ]; then
  echo "[seed] archiving fua-db-data"
  docker run --rm -v "$FUA_VOL":/volume:ro -v "$OUT":/backup busybox \
    sh -c 'cd /volume && tar czf /backup/fua-db-data.tar.gz .'
fi

echo "[seed] creating seed artifact"
if [ -f "$OUT/fua-db-data.tar.gz" ]; then
  tar czf "$OUT/sihsalus-seed.tar.gz" -C "$OUT" db-data.tar.gz openmrs-data.tar.gz fua-db-data.tar.gz
else
  tar czf "$OUT/sihsalus-seed.tar.gz" -C "$OUT" db-data.tar.gz openmrs-data.tar.gz
fi

sha256sum "$OUT/sihsalus-seed.tar.gz" | tee "$OUT/sihsalus-seed.tar.gz.sha256" >/dev/null
SHA256="$(awk '{print $1}' "$OUT/sihsalus-seed.tar.gz.sha256")"

cat > "$OUT/release-notes.md" <<EOF
Seed volume artifact from ${GH_REPO}.

Git commit: ${GIT_SHA}
SHA256: ${SHA256}

Restore with:

SIHSALUS_SEED_URL=https://github.com/${GH_REPO}/releases/download/${TAG}/sihsalus-seed.tar.gz
SIHSALUS_SEED_SHA256=${SHA256}
EOF

echo "[seed] restarting stack"
restart_stack
RESTART_NEEDED=false
trap - EXIT INT TERM

echo "[seed] uploading release ${TAG}"
gh release create "$TAG" \
  "$OUT/sihsalus-seed.tar.gz#sihsalus-seed.tar.gz" \
  "$OUT/sihsalus-seed.tar.gz.sha256#sihsalus-seed.tar.gz.sha256" \
  --repo "$GH_REPO" \
  --title "$TAG" \
  --notes-file "$OUT/release-notes.md"

echo "[seed] done"
echo "SIHSALUS_SEED_URL=https://github.com/${GH_REPO}/releases/download/${TAG}/sihsalus-seed.tar.gz"
echo "SIHSALUS_SEED_SHA256=${SHA256}"
