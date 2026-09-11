#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || -z "$1" || "$1" == -* ]]; then
  echo "Usage: bash tests/backend/tomcat-config-image.sh IMAGE" >&2
  exit 2
fi
image_ref="$1"

docker context show
docker info --format 'Docker server: {{.ServerVersion}}'
image_user="$(docker image inspect --format '{{.Config.User}}' "$image_ref")"
if [[ "$image_user" != 1001 && "$image_user" != 1001:0 ]]; then
  echo "[FAIL] Backend image must default to UID 1001, not: $image_user" >&2
  exit 1
fi

# Never start Tomcat, pull an image, use the network or attach deployed data.
# --rm also removes anonymous volumes declared by the base image.
docker run --rm --pull never --network none --cap-drop ALL \
  --security-opt no-new-privileges --pids-limit 32 \
  --entrypoint /bin/sh "$image_ref" -eu -c '
    test "$(id -u)" = 1001
    test "$(id -g)" = 0
    test "${CATALINA_BASE:-$CATALINA_HOME}" = /usr/local/tomcat
    test "$(readlink -f /usr/local/tomcat/conf/Catalina/localhost)" = /usr/local/tomcat/conf/Catalina/localhost
    test "$(stat -c "%u:%g:%a" /usr/local/tomcat/conf)" = 0:0:755
    test "$(stat -c "%u:%g:%a" /usr/local/tomcat/conf/Catalina)" = 0:0:755
    test "$(stat -c "%u:%g:%a" /usr/local/tomcat/conf/Catalina/localhost)" = 1001:0:750
    test ! -w /usr/local/tomcat/conf
    test ! -w /usr/local/tomcat/conf/Catalina
    test -r /usr/local/tomcat/conf/Catalina/localhost
    test -w /usr/local/tomcat/conf/Catalina/localhost
    test -x /usr/local/tomcat/conf/Catalina/localhost
    test -z "$(find /usr/local/tomcat/conf/Catalina/localhost -mindepth 1 -maxdepth 1 -print -quit)"
    printf "%s\n" "[OK] Empty Host config directory is usable by UID 1001; parent config remains protected."
  '
