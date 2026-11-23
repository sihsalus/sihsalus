#!/usr/bin/env bash
# Called under the release lock, from the installed QLTY checkout.
set -euo pipefail
umask 077
exec 3>&1 4>&2
# Dump/restore errors can contain SQL. Only stage names and the receipt are public.
exec >/dev/null 2>&1
stage='configuration'
pending=''
scratch=''
key_tmp=''
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$scratch" ]]; then docker rm -fv "$scratch" || status=1; fi
  if [[ -n "$key_tmp" ]]; then rm -f -- "$key_tmp" || status=1; fi
  if [[ -n "$pending" ]]; then rm -rf -- "$pending" || status=1; fi
  if ((status)); then echo "QLTY database backup failed at $stage; backend update blocked." >&4; fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# Read only selected scalar credentials, without executing host configuration.
source scripts/deploy/env.sh
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-$(read_env_value MYSQL_ROOT_PASSWORD)}
BACKUP_ENCRYPTION_PASSWORD=${BACKUP_ENCRYPTION_PASSWORD:-$(read_env_value BACKUP_ENCRYPTION_PASSWORD)}
: "${MYSQL_ROOT_PASSWORD:?}"
export MYSQL_ROOT_PASSWORD BACKUP_ENCRYPTION_PASSWORD

private_dir() {
  mkdir -p -m 700 -- "$1"
  [[ -d "$1" && ! -L "$1" && -O "$1" && $(stat -c '%a' -- "$1") == 700 ]]
}
base="$HOME/.local/share/sihsalus/backups/qlty-backend-update"
# Reject redirects even in parent components of the private storage locations.
[[ $(realpath -m -- "$base") == "$base" ]]
private_dir "$base"
key_source=BACKUP_ENCRYPTION_PASSWORD
if [[ -z "$BACKUP_ENCRYPTION_PASSWORD" ]]; then
  keys="$HOME/.sihsalus-backup-keys"
  [[ $(realpath -m -- "$keys") == "$keys" ]]
  private_dir "$keys"
  key="$keys/qlty-backend-update.key"
  if [[ ! -e "$key" && ! -L "$key" ]]; then
    # The release lock serializes this hook. Never replace a recovery key.
    key_tmp=$(mktemp -- "$keys/.qlty-backend-update.XXXXXXXX")
    openssl rand -hex 32 > "$key_tmp"
    ln -- "$key_tmp" "$key"
    rm -- "$key_tmp"
    key_tmp=''
  fi
  [[ -f "$key" && ! -L "$key" && -O "$key" && $(stat -c '%a' -- "$key") == 600 ]]
  read -r BACKUP_ENCRYPTION_PASSWORD < "$key"
  [[ "$BACKUP_ENCRYPTION_PASSWORD" =~ ^[0-9a-f]{64}$ ]]
  key_source='~/.sihsalus-backup-keys/qlty-backend-update.key'
fi

stage='live database identity'
root=$(pwd -P)
source_id=$(docker compose ps --quiet db)
[[ "$source_id" =~ ^[0-9a-f]{12,64}$ ]]
identity=$(docker inspect --format '{{.State.Running}}|{{index .Config.Labels "com.docker.compose.service"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$source_id")
[[ "$identity" == "true|db|$root" ]]
db_image=$(docker inspect --format '{{.Image}}' "$source_id")
[[ "$db_image" =~ ^sha256:[0-9a-f]{64}$ ]]

stage='isolated database cleanup'
scratch_name=sihsalus-qlty-pre-backend-restore
label=org.sihsalus.qlty-pre-backend-restore
if old_id=$(docker inspect --format '{{.Id}}' "$scratch_name"); then
  [[ "$old_id" =~ ^[0-9a-f]{64}$ && $(docker inspect --format "{{index .Config.Labels \"$label\"}}" "$old_id") == "$root" ]]
  docker rm -fv "$old_id"
fi
pending="$base/.pending"
rm -rf -- "$pending" # interrupted trial under the same release lock
mkdir -m 700 -- "$pending"

stage='backup storage capacity'
export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
db_size=$(docker exec -e MYSQL_PWD "$source_id" mariadb --user=root --batch --skip-column-names \
  --execute="SELECT COALESCE(SUM(DATA_LENGTH+INDEX_LENGTH),0) FROM information_schema.TABLES WHERE TABLE_SCHEMA='openmrs'")
[[ "$db_size" =~ ^[0-9]{1,15}$ && "$db_size" != 0 ]]
# The encrypted dump, restore staging and empty verification database can
# coexist. Leave a reserve on the host that also serves OpenMRS.
free_kib=$(df -Pk "$base" | awk 'END { print $4 }')
[[ "$free_kib" =~ ^[0-9]+$ ]]
((free_kib >= db_size / 1024 * 4 + 1048576))

stage='encrypted dump'
# Keep two completed, verified backups; never rotate an older one on failure.
bash scripts/backup/backup_dump.sh --container "$source_id" --dir "$pending" --max 1
shopt -s nullglob
dumps=("$pending"/dump_*.sql.gz.enc)
[[ ${#dumps[@]} == 1 && -s "${dumps[0]}" ]]
dump=${dumps[0]##*/}
(cd "$pending" && sha256sum -- "$dump" > SHA256SUMS)
schema_query="SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='openmrs' AND TABLE_TYPE='BASE TABLE' ORDER BY BINARY TABLE_NAME"
schema() {
  docker exec -e MYSQL_PWD "$1" mariadb --user=root --batch --skip-column-names --execute="$schema_query"
}
source_tables=$(schema "$source_id")
for table in concept encounter patient; do grep -Fxq "$table" <<< "$source_tables"; done

stage='isolated MariaDB startup'
# No published ports or live mounts. The anonymous scratch volume is removed
# together with the container, including recovery from an interrupted run.
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)
export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
scratch=$(docker create --name "$scratch_name" --label "$label=$root" --pull never \
  --network none --read-only --log-driver none --ulimit core=0 --security-opt no-new-privileges \
  --volume /var/lib/mysql --tmpfs /run/mysqld --tmpfs /tmp --memory 768m --memory-swap 768m \
  -e MYSQL_ROOT_PASSWORD "$db_image" --skip-log-bin --event-scheduler=OFF)
[[ "$scratch" =~ ^[0-9a-f]{64}$ && "$scratch" != "$source_id" ]]
docker start "$scratch"
for ((i=0; i<120; i++)); do
  if docker exec -e MYSQL_PWD "$scratch" mariadb --protocol=tcp --host=127.0.0.1 --user=root --execute='SELECT 1'; then break; fi
  sleep 1
done
((i < 120))

stage='isolated restore and verification'
(cd "$pending" && sha256sum --check --strict SHA256SUMS)
TMPDIR="$pending" bash scripts/backup/restore_dump.sh --container "$scratch" --file "${dumps[0]}" --yes --no-app-control
docker exec -e MYSQL_PWD "$scratch" mariadb-check --user=root --check --quick openmrs
[[ $(schema "$scratch") == "$source_tables" ]]
(cd "$pending" && sha256sum --check --strict SHA256SUMS)
docker rm -fv "$scratch"
scratch=''

stage='retaining verified backup'
stamp=$(date -u +%Y%m%dT%H%M%SZ)
directory="verified-$stamp-$(openssl rand -hex 4)"
printf 'timestamp=%s\nscope=openmrs-database\nsource_image=%s\nkey=%s\nchecks=sha256,decryption,isolated-restore,table-list,mariadb-check\n' \
  "$stamp" "$db_image" "$key_source" > "$pending/verification.txt"
export LC_ALL=C
retained=("$base"/verified-*)
mv -T -- "$pending" "$base/$directory"
pending=''
for ((i=0; i<${#retained[@]}-1; i++)); do
  previous=${retained[i]}
  [[ ${previous##*/} =~ ^verified-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]]
  rm -rf -- "$previous"
done
echo "OpenMRS database backup verified by isolated restore: $directory" >&3
