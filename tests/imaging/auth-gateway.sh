#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d "$ROOT_DIR/.tmp-imaging-auth.XXXXXX")"
PREFIX="sihsalus-imaging-auth-test-$$"
NETWORK="${PREFIX}-network"
UPSTREAM="${PREFIX}-upstream"
AUTH="${PREFIX}-auth"
GATEWAY="${PREFIX}-gateway"

cleanup() {
  docker rm -f "$GATEWAY" "$AUTH" "$UPSTREAM" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Validate every oauth2-proxy option without contacting an identity provider.
docker run --rm \
  -e OAUTH2_PROXY_PROVIDER=keycloak-oidc \
  -e OAUTH2_PROXY_CLIENT_ID=sihsalus-imaging \
  -e OAUTH2_PROXY_CLIENT_SECRET=ci-imaging-client-secret \
  -e OAUTH2_PROXY_COOKIE_SECRET=QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE= \
  -e OAUTH2_PROXY_COOKIE_SECURE=false \
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
  location / {
    default_type text/plain;
    return 200 'mock imaging upstream';
  }
}
EOF

cat > "$TMP_DIR/auth.conf" <<'EOF'
server {
  listen 4180;

  location = /imaging/oauth2/auth {
    if ($cookie__sihsalus_imaging = "allowed") { return 202; }
    return 401;
  }

  location = /imaging/oauth2/start {
    return 302 /keycloak/realms/openmrs/protocol/openid-connect/auth;
  }

  location = /imaging/oauth2/sign_out {
    add_header Set-Cookie "_sihsalus_imaging=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax" always;
    return 302 /;
  }
}
EOF

sed \
  -e 's|${FRAME_ANCESTORS}||g' \
  -e 's|${FUA_CONFIG}||g' \
  -e 's|${FUA_LOCATIONS}||g' \
  -e 's|${IMAGING_NETWORK_ACCESS_CONTROL}|allow 127.0.0.1; allow 172.16.0.0/12; deny all;|g' \
  -e 's|${IMAGING_ACCESS_CONTROL}|allow 127.0.0.1; allow 172.16.0.0/12; deny all; auth_request /imaging/oauth2/auth; error_page 401 = @imaging_oauth_signin;|g' \
  "$ROOT_DIR/gateway/default.conf.template" > "$TMP_DIR/gateway.conf"

docker network create "$NETWORK" >/dev/null
docker run -d --name "$UPSTREAM" --network "$NETWORK" \
  --network-alias backend --network-alias frontend --network-alias ohif --network-alias orthanc-proxy \
  -v "$TMP_DIR/upstream.conf:/etc/nginx/conf.d/default.conf:ro" nginx:1.27-alpine >/dev/null
docker run -d --name "$AUTH" --network "$NETWORK" --network-alias imaging-auth \
  -v "$TMP_DIR/auth.conf:/etc/nginx/conf.d/default.conf:ro" nginx:1.27-alpine >/dev/null
docker run -d --name "$GATEWAY" --network "$NETWORK" -p 127.0.0.1::80 \
  -v "$TMP_DIR/gateway.conf:/etc/nginx/conf.d/default.conf:ro" nginx:1.27-alpine >/dev/null

PORT="$(docker port "$GATEWAY" 80/tcp | awk -F: 'END { print $NF }')"
BASE_URL="http://127.0.0.1:${PORT}"

for _ in $(seq 1 30); do
  curl --fail --silent --show-error "$BASE_URL/health" >/dev/null 2>&1 && break
  sleep 1
done
curl --fail --silent --show-error "$BASE_URL/health" >/dev/null

for path in /imaging/ /orthanc/ /dicom-web/studies /wado; do
  headers="$TMP_DIR/anonymous.headers"
  status="$(curl --silent --show-error --output /dev/null --dump-header "$headers" --write-out '%{http_code}' "$BASE_URL$path")"
  [ "$status" = "302" ]
  grep -qi '^Location: /imaging/oauth2/start?' "$headers"

  status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --cookie '_sihsalus_imaging=allowed' "$BASE_URL$path")"
  [ "$status" = "200" ]
done

logout_headers="$TMP_DIR/logout.headers"
status="$(curl --silent --show-error --output /dev/null --dump-header "$logout_headers" --write-out '%{http_code}' \
  --cookie '_sihsalus_imaging=allowed' "$BASE_URL/imaging/logout")"
[ "$status" = "302" ]
grep -qi '^Location: /imaging/oauth2/sign_out?rd=/' "$logout_headers"

signout_headers="$TMP_DIR/signout.headers"
status="$(curl --silent --show-error --output /dev/null --dump-header "$signout_headers" --write-out '%{http_code}' \
  --cookie '_sihsalus_imaging=allowed' "$BASE_URL/imaging/oauth2/sign_out")"
[ "$status" = "302" ]
grep -Eqi '^Set-Cookie: _sihsalus_imaging=.*Max-Age=0' "$signout_headers"

echo "[OK] Imaging routes deny anonymous users, accept authorized sessions and clear logout cookies"
