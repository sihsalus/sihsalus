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

# Never pull an image, use an external network or attach deployed data.
# --rm also removes anonymous volumes declared by the base image.
docker run --rm --pull never --network none --cap-drop ALL \
  --security-opt no-new-privileges --pids-limit 128 \
  --entrypoint /bin/sh "$image_ref" -eu -c '
    test "$(id -u)" = 1001
    test "$(id -g)" = 0
    test "${CATALINA_BASE:-$CATALINA_HOME}" = /usr/local/tomcat
    /usr/local/tomcat/bin/version.sh | grep -qF "Apache Tomcat/9.0.121"
    test -w /usr/local/tomcat/bin/setenv.sh
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

# Start only the empty Tomcat server, bypassing OpenMRS and its database setup.
# This catches missing runtime JARs and broken scripts/permissions after upgrade.
timeout 60s docker run --rm --pull never --network none --cap-drop ALL \
  --security-opt no-new-privileges --pids-limit 128 \
  --entrypoint /bin/sh "$image_ref" -eu -c '
    test -z "$(find /usr/local/tomcat/webapps -mindepth 1 -maxdepth 1 -print -quit)"
    trap "/usr/local/tomcat/bin/catalina.sh stop >/dev/null 2>&1 || true" EXIT
    /usr/local/tomcat/bin/catalina.sh start
    attempt=0
    while [ "$attempt" -lt 20 ]; do
      status="$(curl --silent --output /dev/null --write-out "%{http_code}" \
        --max-time 1 http://127.0.0.1:8080/ || true)"
      if [ "$status" = 404 ]; then
        printf "%s\n" "[OK] Updated Tomcat serves HTTP as UID 1001 with no applications or database."
        exit 0
      fi
      attempt=$((attempt + 1))
      sleep 1
    done
    cat /usr/local/tomcat/logs/catalina.out >&2
    exit 1
  '
