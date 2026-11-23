#!/usr/bin/env bash
# Exercise the canonical dump/restore and real encryption with an isolated Docker double.
set -euo pipefail
# The deployed hook uses GNU tools on Ubuntu. Test the same flags on macOS.
if [[ $(uname -s) == Darwin ]] && ! stat -c %a . >/dev/null 2>&1; then
  gnu_bin="$(brew --prefix coreutils)/libexec/gnubin"
  [[ -x "$gnu_bin/stat" ]] || { echo 'Install Homebrew coreutils for this test.' >&2; exit 1; }
  export PATH="$gnu_bin:$PATH"
fi
root=$(cd "$(dirname "$0")/../.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
# Resolve macOS /var symlinks consistently with Docker's project labels.
work=$(cd "$work" && pwd -P)
export HOME="$work/home" STATE="$work/state"
mkdir -p "$STATE" "$work/bin" "$HOME" "$work/checkout"
cd "$work/checkout"
ln -s "$root/scripts" scripts
printf '%s\n' 'MYSQL_ROOT_PASSWORD=source-secret-must-stay-private' > .env
export TEST_CHECKOUT="$PWD" PATH="$work/bin:$PATH"
export SOURCE_ID=$(printf '%064d' 1) TRIAL_ID=$(printf '%064d' 2)
export IMAGE_ID="sha256:$(printf '%064d' 3)"
cat > "$work/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
cmd=$1; shift
case "$cmd" in
  compose) [[ "$*" == "ps --quiet db" ]]; echo "$SOURCE_ID" ;;
  inspect)
    fmt=$2; id=$3
    case "$fmt" in
      '{{.Id}}') [[ -f "$STATE/scratch" ]]; echo "$TRIAL_ID" ;;
      '{{.Image}}') [[ "$id" == "$SOURCE_ID" ]]; echo "$IMAGE_ID" ;;
      *Config.Labels*State*|*State.Running*)
        [[ "$id" == "$SOURCE_ID" ]]; echo "true|db|${TEST_WORKDIR:-$TEST_CHECKOUT}" ;;
      *Config.Labels*) [[ "$id" == "$TRIAL_ID" && -f "$STATE/scratch" ]]; cat "$STATE/scratch" ;;
      *) exit 2 ;;
    esac ;;
  create)
    [[ "$*" == *"--network none"* && "$*" == *"--volume /var/lib/mysql"* && "$*" == *"--log-driver none"* ]]
    [[ "$*" == *"--pull never"* && "$*" == *"$IMAGE_ID"* && "$*" != *"$SOURCE_ID"* && "$*" != *"--volumes-from"* ]]
    [[ ! -f "$STATE/scratch" && -n "$MYSQL_ROOT_PASSWORD" && "$MYSQL_ROOT_PASSWORD" != *source-secret* ]]
    echo "$TEST_CHECKOUT" > "$STATE/scratch"; echo "$TRIAL_ID" ;;
  start) [[ "$*" == "$TRIAL_ID" && -f "$STATE/scratch" ]] ;;
  rm) [[ "$*" == "-fv $TRIAL_ID" ]]; rm -- "$STATE/scratch" ;;
  exec)
    # Source accepts only dump/metadata; every import must address the trial ID.
    if [[ " $* " == *" $SOURCE_ID "* ]]; then
      case "$*" in
        *'SUM(DATA_LENGTH'*) echo 4096 ;;
        *'SELECT TABLE_NAME'*) printf '%s\n' concept encounter patient ;;
        *'mariadb-dump '*)
          [[ "$*" == *"--single-transaction"* ]]
          printf '%s\n' "INSERT INTO demonstration VALUES ('synthetic-sentinel');" ;;
        *) exit 2 ;;
      esac
    else
      [[ " $* " == *" $TRIAL_ID "* && -f "$STATE/scratch" ]]
      case "$*" in
        *'SELECT 1'*|*'DROP DATABASE'*) : ;;
        *'SELECT TABLE_NAME'*)
          printf '%s\n' concept encounter
          [[ "${FAIL_AT:-}" == schema ]] || echo patient ;;
        *mariadb-check*) [[ "${FAIL_AT:-}" != check ]] ;;
        *'mariadb --user=root openmrs')
          [[ "$*" == *'-i '* ]]
          cat > "$STATE/imported"
          echo "synthetic-sentinel source-secret-must-stay-private" >&2
          [[ "${FAIL_AT:-}" != restore ]] ;;
        *) exit 2 ;;
      esac
    fi ;;
  *) exit 2 ;;
esac
DOCKER
chmod +x "$work/bin/docker"
hook="$root/scripts/deploy/qlty-pre-backend-backup.sh"
base="$HOME/.local/share/sihsalus/backups/qlty-backend-update"
key="$HOME/.sihsalus-backup-keys/qlty-backend-update.key"
run_ok() { bash "$hook" >"$STATE/public" 2>&1 || { cat "$STATE/public"; exit 1; }; }
run_blocked() {
  if bash "$hook" >"$STATE/public" 2>&1; then echo 'Expected fail-closed backup' >&2; exit 1; fi
  grep -q 'backend update blocked' "$STATE/public"
  if grep -Eq 'synthetic-sentinel|source-secret' "$STATE/public"; then exit 1; fi
}
run_ok
grep -q 'verified by isolated restore' "$STATE/public"
if grep -Eq 'synthetic-sentinel|source-secret' "$STATE/public"; then exit 1; fi
grep -q synthetic-sentinel "$STATE/imported"
[[ ! -e "$STATE/scratch" && ! -e "$base/.pending" && $(stat -c %a "$key") == 600 ]]
key_checksum=$(sha256sum "$key")
backups=("$base"/verified-*)
[[ ${#backups[@]} == 1 && -s "${backups[0]}/verification.txt" ]]
(cd "${backups[0]}" && sha256sum --check --strict SHA256SUMS)
for failure in restore schema check; do
  FAIL_AT="$failure" run_blocked
  [[ -d "${backups[0]}" && ! -e "$STATE/scratch" && ! -e "$base/.pending" ]]
done
TEST_WORKDIR=/different/checkout run_blocked
# Never delete someone else's same-named Docker container.
echo 'foreign' > "$STATE/scratch"
run_blocked
[[ $(cat "$STATE/scratch") == foreign ]]
echo "$TEST_CHECKOUT" > "$STATE/scratch"
mkdir "$base/.pending"
touch "$base/.pending/interrupted"
run_ok
run_ok
retained=("$base"/verified-*)
[[ ${#retained[@]} == 2 && "$key_checksum" == "$(sha256sum "$key")" ]]
mv "$key" "$STATE/independent-key"
ln -s "$STATE/independent-key" "$key"
run_blocked
rm -- "$key"
BACKUP_ENCRYPTION_PASSWORD=explicit-test-secret run_ok
[[ ! -e "$key" ]]
echo 'PASS: QLTY encrypted database backup, isolated restore, retention and fail-closed checks'
