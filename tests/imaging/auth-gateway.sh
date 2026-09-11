#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d "$ROOT_DIR/.tmp-imaging-auth.XXXXXX")"
PREFIX="sihsalus-imaging-auth-test-$$"
NETWORK="${PREFIX}-network"
UPSTREAM="${PREFIX}-upstream"
AUTH="${PREFIX}-auth"
GATEWAY="${PREFIX}-gateway"
ORTHANC_PROXY="${PREFIX}-orthanc-proxy"
DENIED_GATEWAY="${PREFIX}-denied-gateway"
NGINX_TEST_IMAGE="${GATEWAY_TEST_IMAGE:-nginx:1.28-alpine}"
CREATED_CONTAINERS=()
NETWORK_CREATED=false

cleanup() {
  local result=$?
  trap - EXIT
  for container in "${CREATED_CONTAINERS[@]}"; do
    docker rm -f "$container" >/dev/null || result=1
  done
  if "$NETWORK_CREATED"; then
    docker network rm "$NETWORK" >/dev/null || result=1
  fi
  if [ "$result" -eq 0 ]; then
    rm -rf "$TMP_DIR"
  else
    echo "[FAIL] Imaging test evidence retained at $TMP_DIR" >&2
  fi
  exit "$result"
}
trap cleanup EXIT

# Validate every oauth2-proxy option without contacting an identity provider.
docker run --rm \
  -e OAUTH2_PROXY_PROVIDER=keycloak-oidc \
  -e OAUTH2_PROXY_CLIENT_ID=sihsalus-imaging \
  -e OAUTH2_PROXY_CLIENT_SECRET=ci-imaging-client-secret \
  -e OAUTH2_PROXY_COOKIE_SECRET=QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE= \
  -e OAUTH2_PROXY_COOKIE_SECURE=false \
  -e OAUTH2_PROXY_COOKIE_NAME=_sihsalus_imaging_session \
  -e OAUTH2_PROXY_SESSION_STORE_TYPE=redis \
  -e OAUTH2_PROXY_REDIS_CONNECTION_URL=redis://imaging-session-store:6379/0 \
  -e OAUTH2_PROXY_REDIS_PASSWORD=0123456789abcdef0123456789abcdef0123456789abcdef \
  -e OAUTH2_PROXY_PROXY_PREFIX=/imaging/oauth2 \
  -e OAUTH2_PROXY_REDIRECT_URL=http://localhost/imaging/oauth2/callback \
  -e OAUTH2_PROXY_OIDC_ISSUER_URL=http://localhost/keycloak/realms/openmrs \
  -e OAUTH2_PROXY_SKIP_OIDC_DISCOVERY=true \
  -e OAUTH2_PROXY_LOGIN_URL=http://localhost/keycloak/realms/openmrs/protocol/openid-connect/auth \
  -e OAUTH2_PROXY_REDEEM_URL=http://keycloak:8080/realms/openmrs/protocol/openid-connect/token \
  -e OAUTH2_PROXY_PROFILE_URL=http://keycloak:8080/realms/openmrs/protocol/openid-connect/userinfo \
  -e OAUTH2_PROXY_OIDC_JWKS_URL=http://keycloak:8080/realms/openmrs/protocol/openid-connect/certs \
  -e 'OAUTH2_PROXY_BACKEND_LOGOUT_URL=http://keycloak:8080/realms/openmrs/protocol/openid-connect/logout?id_token_hint={id_token}' \
  -e OAUTH2_PROXY_ALLOWED_ROLES=imaging-access \
  -e OAUTH2_PROXY_EMAIL_DOMAINS='*' \
  -e OAUTH2_PROXY_CODE_CHALLENGE_METHOD=S256 \
  -e OAUTH2_PROXY_UPSTREAMS=static://202 \
  quay.io/oauth2-proxy/oauth2-proxy:v7.15.3 \
  --config-test

cat > "$TMP_DIR/upstream.conf" <<'EOF'
server {
  listen 80;
  listen 8080;
  listen 8042;
  location / {
    add_header X-Test-Upstream-URI $request_uri always;
    add_header X-Test-Upstream-Method $request_method always;
    add_header X-Test-Upstream-Host $http_host always;
    add_header X-Test-Upstream-Proto $http_x_forwarded_proto always;
    add_header X-Test-Upstream-Forwarded $http_forwarded always;
    add_header X-Test-Upstream-Cookie $http_cookie always;
    add_header X-Test-Upstream-Authorization $http_authorization always;
    default_type text/plain;
    return 200 'mock imaging upstream';
  }
}
EOF

cat > "$TMP_DIR/auth.conf" <<'EOF'
# Match oauth2-proxy's Redis ticket format and its actual Max-Age attributes.
map $http_x_test_session $session_cookie {
  default "";
  renewed "_sihsalus_imaging_session=synthetic-ticket; Path=/; Max-Age=28800; HttpOnly; Secure; SameSite=Lax";
  expired "_sihsalus_imaging_session=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax";
}
server {
  listen 4180;

  location = /imaging/oauth2/auth {
    add_header Set-Cookie $session_cookie always;
    if ($http_x_test_session = "forbidden") { return 403; }
    if ($http_x_test_session = "unavailable") { return 503; }
    if ($http_x_test_session = "expired") { return 401; }
    if ($cookie__sihsalus_imaging_session = "allowed") { return 202; }
    return 401;
  }

  location = /imaging/oauth2/start {
    add_header X-Test-Auth-Return $http_x_auth_request_redirect always;
    add_header X-Test-Auth-Method $request_method always;
    add_header X-Test-Auth-Content-Length $http_content_length always;
    add_header Set-Cookie "synthetic_csrf=created; Path=/; HttpOnly; SameSite=Lax" always;
    return 302 /keycloak/realms/openmrs/protocol/openid-connect/auth;
  }

  location = /imaging/oauth2/sign_out {
    add_header Set-Cookie "_sihsalus_imaging_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax" always;
    return 302 /;
  }
}
EOF

docker network create "$NETWORK" >/dev/null
NETWORK_CREATED=true
docker run -d --name "$UPSTREAM" --network "$NETWORK" \
  --network-alias backend --network-alias frontend --network-alias ohif --network-alias orthanc \
  -v "$TMP_DIR/upstream.conf:/etc/nginx/conf.d/default.conf:ro" \
  --entrypoint nginx "$NGINX_TEST_IMAGE" -g 'daemon off;' >/dev/null
CREATED_CONTAINERS+=("$UPSTREAM")
docker run -d --name "$ORTHANC_PROXY" --network "$NETWORK" --network-alias orthanc-proxy \
  -v "$ROOT_DIR/gateway/orthanc-proxy.conf:/etc/nginx/conf.d/default.conf:ro" \
  --entrypoint nginx "$NGINX_TEST_IMAGE" -g 'daemon off;' >/dev/null
CREATED_CONTAINERS+=("$ORTHANC_PROXY")
docker run -d --name "$AUTH" --network "$NETWORK" --network-alias imaging-auth \
  -v "$TMP_DIR/auth.conf:/etc/nginx/conf.d/default.conf:ro" \
  --entrypoint nginx "$NGINX_TEST_IMAGE" -g 'daemon off;' >/dev/null
CREATED_CONTAINERS+=("$AUTH")
docker run -d --name "$GATEWAY" --network "$NETWORK" -p 127.0.0.1::80 \
  -e FRAME_ANCESTORS= \
  -e 'IMAGING_NETWORK_ACCESS_CONTROL=allow 127.0.0.1; allow 10.0.0.0/8; allow 172.16.0.0/12; allow 192.168.0.0/16; deny all;' \
  -e 'IMAGING_ACCESS_CONTROL=allow 127.0.0.1; allow 10.0.0.0/8; allow 172.16.0.0/12; allow 192.168.0.0/16; deny all; auth_request /imaging/oauth2/auth; error_page 401 = @imaging_oauth_signin;' \
  -v "$ROOT_DIR/gateway:/etc/nginx/includes:ro" \
  -v "$ROOT_DIR/gateway/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$ROOT_DIR/gateway/templates:/etc/nginx/conf-templates:ro" \
  -v "$ROOT_DIR/gateway/docker-entrypoint.sh:/usr/local/bin/docker-entrypoint.sh:ro" \
  --entrypoint /usr/local/bin/docker-entrypoint.sh "$NGINX_TEST_IMAGE" nginx -g 'daemon off;' >/dev/null
CREATED_CONTAINERS+=("$GATEWAY")

PORT="$(docker port "$GATEWAY" 80/tcp | awk -F: 'END { print $NF }')"
BASE_URL="http://127.0.0.1:${PORT}"

for _ in $(seq 1 30); do
  curl --fail --silent --show-error "$BASE_URL/health" >/dev/null 2>&1 && break
  sleep 1
done
curl --fail --silent --show-error "$BASE_URL/health" >/dev/null

# Unconfigured Grafana stays denied even when Imaging is authorized. Exercise
# the real entrypoint fallback rather than supplying the new variable here.
for path in /grafana /grafana/ /grafana/api/health; do
  status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --header 'X-Real-IP: 127.0.0.1' --cookie '_sihsalus_imaging=allowed' "$BASE_URL$path")"
  [ "$status" = "403" ]
done

heartbeat_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --request POST \
  --header 'User-Agent: sihsalus-privacy-probe' \
  "$BASE_URL/_sihsalus/clinical-activity?privacy_probe=must_not_be_logged")"
[ "$heartbeat_status" = "204" ]
heartbeat_log="$(docker exec "$GATEWAY" cat /var/log/nginx/clinical-activity.log)"
[ "$(printf '%s\n' "$heartbeat_log" | wc -l | tr -d '[:space:]')" = "1" ]
printf '%s\n' "$heartbeat_log" | grep -Eq '^[0-9]+\.[0-9]{3}$'

# Legacy secret-question recovery is not an approved credential-recovery
# channel. Exercise the real Nginx parser and request matcher, including the
# path-parameter forms that Tomcat would otherwise normalize before mapping.
for method in GET POST; do
  for path in \
    '/openmrs/forgotPassword.form' \
    '/openmrs/forgotPassword.form;jsessionid=test' \
    '/openmrs;jsessionid=test/forgotPassword.form'; do
    status="$(curl --path-as-is --request "$method" --silent --show-error \
      --output /dev/null --write-out '%{http_code}' "$BASE_URL$path")"
    [ "$status" = "404" ]
  done
done

status="$(curl --path-as-is --silent --show-error --output /dev/null \
  --write-out '%{http_code}' "$BASE_URL/openmrs/admin/users/changePassword.form")"
[ "$status" = "200" ]

startup_headers="$TMP_DIR/startup.headers"
startup_body="$TMP_DIR/startup.body"
status="$(curl --http1.1 --max-time 5 --silent --show-error \
  --output "$startup_body" --dump-header "$startup_headers" \
  --write-out '%{http_code}' "$BASE_URL/startup")"
[ "$status" = "200" ]
startup_bytes="$(wc -c < "$startup_body" | tr -d '[:space:]')"
content_lengths="$(awk 'tolower($1) == "content-length:" { gsub(/\r/, "", $2); print $2 }' "$startup_headers")"
[ "$content_lengths" = "$startup_bytes" ]
grep -qi '^X-Content-Type-Options: nosniff' "$startup_headers"

for path in /imaging/ /orthanc/ /dicom-web/studies /wado /imaging/dicom-web/studies /imaging/wado; do
  headers="$TMP_DIR/anonymous.headers"
  status="$(curl --silent --show-error --output /dev/null --dump-header "$headers" --write-out '%{http_code}' "$BASE_URL$path")"
  [ "$status" = "302" ]
  grep -qi '^Location: /keycloak/realms/openmrs/protocol/openid-connect/auth' "$headers"

  status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --cookie '_sihsalus_imaging_session=allowed' "$BASE_URL$path")"
  [ "$status" = "200" ]
done

python3 - "$BASE_URL" <<'PY'
from http.cookies import SimpleCookie
import sys
import urllib.error
import urllib.request

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None

base = sys.argv[1]
client = urllib.request.build_opener(NoRedirect())

def request(path, headers=None, data=None, method=None):
    req = urllib.request.Request(base + path, headers=headers or {}, data=data, method=method)
    try:
        return client.open(req, timeout=15)
    except urllib.error.HTTPError as response:
        return response

def cookies(response):
    parsed = SimpleCookie()
    for value in response.headers.get_all("Set-Cookie", []):
        parsed.load(value)
    return parsed

def assert_cleared(response, name):
    matching = [value for value in response.headers.get_all("Set-Cookie", [])
                if value.startswith(name + "=")]
    assert len(matching) == 1, (name, len(matching))
    header = matching[0].lower()
    assert header.count("max-age=") == 1, name
    assert "expires=" not in header, name
    value = cookies(response)[name]
    assert value.value == "" and value["max-age"] == "0", name
    assert value["path"] == "/" and value["secure"] and value["httponly"], name
    assert value["samesite"] == "Lax", name

for path in ("/imaging/", "/orthanc/", "/dicom-web/studies", "/wado", "/imaging/dicom-web/studies"):
    for mode, expected in (("forbidden", 403), ("unavailable", 500)):
        with request(path, {"X-Test-Session": mode, "Cookie": "_sihsalus_imaging_session=allowed"}) as response:
            assert response.status == expected, (path, mode, response.status)
            assert "X-Test-Upstream-URI" not in response.headers

    with request(path, {"X-Test-Session": "renewed", "Cookie": "_sihsalus_imaging_session=allowed"}) as response:
        assert response.status == 200
        headers = response.headers.get_all("Set-Cookie", [])
        assert len(headers) == 1
        value = cookies(response)["_sihsalus_imaging_session"]
        assert value.value == "synthetic-ticket" and value["secure"] and value["httponly"]
        assert value["path"] == "/" and value["samesite"] == "Lax"
        assert value["max-age"] == "28800" and value["expires"] == ""
        assert headers[0].lower().count("max-age=") == 1
        assert response.headers["X-Content-Type-Options"] == "nosniff"
        assert "Content-Security-Policy" in response.headers

    with request(path, {"X-Test-Session": "expired", "Cookie": "_sihsalus_imaging_session=allowed"}) as response:
        assert response.status == 302
        assert_cleared(response, "_sihsalus_imaging_session")
        assert cookies(response)["synthetic_csrf"].value == "created"

# Old encrypted payloads and fragments do not authenticate a Redis session.
with request("/imaging/", {"Cookie": "_sihsalus_imaging=allowed; _sihsalus_imaging_0=old; _sihsalus_imaging_1=old"}) as response:
    assert response.status == 302
with request("/imaging/", {"Cookie": "_sihsalus_imaging_session=allowed; _sihsalus_imaging=old"}) as response:
    assert response.status == 200

# Login preserves query structure and escaping, and never submits a clinical
# search body to the identity provider.
path = "/imaging/viewer?StudyInstanceUIDs=1.2.3&SeriesInstanceUIDs=4.5.6&label=a%26b%3Dc"
with request(path) as response:
    assert response.status == 302
    assert response.headers["X-Test-Auth-Return"] == path
with request("/orthanc/tools/find?mode=one&next=two", data=b'{"Level":"Study","Query":{"PatientID":"SYNTHETIC"}}') as response:
    assert response.status == 302
    assert response.headers["X-Test-Auth-Method"] == "GET"
    assert response.headers["X-Test-Auth-Return"] == "/orthanc/tools/find?mode=one&next=two"
    assert "X-Test-Auth-Content-Length" not in response.headers

# Public imaging routes only read. OpenMRS continues to receive mutation
# requests so the module can enforce its finer clinical privileges.
for path in ("/orthanc/instances", "/orthanc/studies/synthetic", "/orthanc/tools/find/extra",
             "/orthanc/tools/count", "/orthanc/tools/reset", "/dicom-web", "/dicom-web/",
             "/dicom-web/studies", "/imaging/dicom-web", "/imaging/dicom-web/studies",
             "/wado", "/imaging/wado"):
    for method in ("POST", "PUT", "PATCH", "DELETE", "OPTIONS"):
        for headers in ({}, {"Cookie": "_sihsalus_imaging_session=allowed"}):
            with request(path, headers, method=method) as response:
                assert response.status == 403, (path, method, response.status)
                assert "X-Test-Upstream-URI" not in response.headers

for path in ("/orthanc/system", "/orthanc/studies", "/dicom-web/studies", "/wado",
             "/imaging/dicom-web/studies", "/imaging/wado"):
    for method in ("GET", "HEAD"):
        with request(path, {"Cookie": "_sihsalus_imaging_session=allowed"}, method=method) as response:
            assert response.status == 200, (path, method, response.status)
            assert response.headers["X-Test-Upstream-Method"] == method

for endpoint in ("find", "count-resources", "lookup"):
    with request("/orthanc/tools/" + endpoint + "?limit=1",
                 {"Cookie": "_sihsalus_imaging_session=allowed", "Content-Type": "application/json"},
                 data=b'{}') as response:
        assert response.status == 200, (endpoint, response.status)
        assert response.headers["X-Test-Upstream-Method"] == "POST"
        assert response.headers["X-Test-Upstream-URI"] == "/tools/" + endpoint + "?limit=1"

with request("/openmrs/ws/rest/v1/synthetic-imaging-write", data=b"synthetic clinical mutation") as response:
    assert response.status == 200
    assert response.headers["X-Test-Upstream-Method"] == "POST"

with request("/orthanc/ui/app?StudyInstanceUIDs=1.2.3&label=a%26b") as response:
    assert response.status == 301
    assert response.headers["Location"].endswith("/orthanc/ui/app/?StudyInstanceUIDs=1.2.3&label=a%26b")

# Preserve HTTPS and a nonstandard public port over both proxy hops. The
# caller's forged Forwarded value must not override the gateway's origin.
for external, internal in (("/dicom-web/studies?limit=1&PatientID=SYNTHETIC", "/dicom-web/studies?limit=1&PatientID=SYNTHETIC"),
                           ("/imaging/dicom-web/studies?limit=1", "/dicom-web/studies?limit=1"),
                           ("/orthanc/system", "/system"),
                           ("/imaging/wado?requestType=WADO", "/wado?requestType=WADO")):
    with request(external, {"Host": "imaging.test:9443", "X-Forwarded-Proto": "https",
                            "Forwarded": 'proto=http;host="untrusted.test"',
                            "Authorization": "Bearer synthetic-unused", "Origin": "https://untrusted.test",
                            "Cookie": "_sihsalus_imaging_session=allowed; JSESSIONID=synthetic-unused"}) as response:
        assert response.status == 200
        assert response.headers["X-Test-Upstream-URI"] == internal
        assert response.headers["X-Test-Upstream-Host"] == "imaging.test:9443"
        assert response.headers["X-Test-Upstream-Proto"] == "https"
        assert response.headers["X-Test-Upstream-Forwarded"] == 'proto=https;host="imaging.test:9443"'
        for absent in ("X-Test-Upstream-Cookie", "X-Test-Upstream-Authorization", "Access-Control-Allow-Origin"):
            assert absent not in response.headers, absent

with request("/orthanc/system", {"Host": "[::1]:9443", "X-Forwarded-Proto": "https",
                                "Cookie": "_sihsalus_imaging_session=allowed"}) as response:
    assert response.status == 200
    assert response.headers["X-Test-Upstream-Forwarded"] == 'proto=https;host="[::1]:9443"'
for host in ('imaging.test";proto=http', "imaging.test;other=value", "imaging.test,other.test"):
    with request("/orthanc/system", {"Host": host, "Cookie": "_sihsalus_imaging_session=allowed"}) as response:
        assert response.status == 400
        assert "X-Test-Upstream-URI" not in response.headers

with request("/imaging/", {"Cookie": "_sihsalus_imaging_session=" + "x" * 8300}) as response:
    assert response.status == 400
    assert "X-Test-Upstream-URI" not in response.headers
with request("/imaging/oauth2/auth") as response:
    assert response.status == 404
print("[OK] Imaging origin, read-only routes, authorization, Redis ticket cookies, return URLs and header limits")
PY

logout_headers="$TMP_DIR/logout.headers"
status="$(curl --silent --show-error --output /dev/null --dump-header "$logout_headers" --write-out '%{http_code}' \
  --cookie '_sihsalus_imaging_session=allowed' "$BASE_URL/imaging/logout")"
[ "$status" = "302" ]
grep -qi '^Location: /imaging/oauth2/sign_out?rd=/' "$logout_headers"

signout_headers="$TMP_DIR/signout.headers"
status="$(curl --silent --show-error --output /dev/null --dump-header "$signout_headers" --write-out '%{http_code}' \
  --cookie '_sihsalus_imaging_session=allowed' "$BASE_URL/imaging/oauth2/sign_out")"
[ "$status" = "302" ]
grep -Eqi '^Set-Cookie: _sihsalus_imaging_session=.*Max-Age=0' "$signout_headers"

docker run -d --name "$DENIED_GATEWAY" --network "$NETWORK" -p 127.0.0.1::80 \
  -e FRAME_ANCESTORS= \
  -e 'IMAGING_NETWORK_ACCESS_CONTROL=deny all;' \
  -e 'IMAGING_ACCESS_CONTROL=deny all;' \
  -v "$ROOT_DIR/gateway:/etc/nginx/includes:ro" \
  -v "$ROOT_DIR/gateway/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$ROOT_DIR/gateway/templates:/etc/nginx/conf-templates:ro" \
  -v "$ROOT_DIR/gateway/docker-entrypoint.sh:/usr/local/bin/docker-entrypoint.sh:ro" \
  --entrypoint /usr/local/bin/docker-entrypoint.sh "$NGINX_TEST_IMAGE" nginx -g 'daemon off;' >/dev/null
CREATED_CONTAINERS+=("$DENIED_GATEWAY")
DENIED_PORT="$(docker port "$DENIED_GATEWAY" 80/tcp | awk -F: 'END { print $NF }')"
for _ in $(seq 1 30); do
  curl --fail --silent --show-error "http://127.0.0.1:$DENIED_PORT/health" >/dev/null 2>&1 && break
  sleep 1
done
for path in /imaging/ /orthanc/ /dicom-web/studies /wado /imaging/dicom-web/studies /imaging/wado; do
  status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --cookie '_sihsalus_imaging_session=allowed' "http://127.0.0.1:$DENIED_PORT$path")"
  [ "$status" = "403" ]
done

# Start the replacement before disconnecting the old endpoint, so it must
# receive another address. No fixed subnet or assumed Docker IP reuse is needed.
OLD_IP="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$UPSTREAM")"
docker run -d --name "${PREFIX}-replacement" --network "$NETWORK" --network-alias orthanc \
  -v "$TMP_DIR/upstream.conf:/etc/nginx/conf.d/default.conf:ro" \
  --entrypoint nginx "$NGINX_TEST_IMAGE" -g 'daemon off;' >/dev/null
CREATED_CONTAINERS+=("${PREFIX}-replacement")
NEW_IP="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${PREFIX}-replacement")"
[ "$OLD_IP" != "$NEW_IP" ]
docker network disconnect "$NETWORK" "$UPSTREAM"
status=0
for _ in $(seq 1 15); do
  if ! status="$(curl --max-time 15 --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --cookie '_sihsalus_imaging_session=allowed' "$BASE_URL/orthanc/system")"; then
    status=0
  fi
  [ "$status" = "200" ] && break
  sleep 1
done
[ "$status" = "200" ]

echo "[OK] Gateway startup framing and imaging authorization routes"
