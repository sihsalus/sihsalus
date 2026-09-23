#!/bin/sh
#	This Source Code Form is subject to the terms of the Mozilla Public License,
#	v. 2.0. If a copy of the MPL was not distributed with this file, You can
#	obtain one at http://mozilla.org/MPL/2.0/. OpenMRS is also distributed under
#	the terms of the Healthcare Disclaimer located at http://openmrs.org/license.
#
#	Copyright (C) OpenMRS Inc. OpenMRS is a registered trademark and the OpenMRS
#	graphic logo is a trademark of OpenMRS Inc.
#
# Adapted for SIH Salus. Development mode creates self-signed certificates for
# internal hospital networks; production mode obtains and renews Let's Encrypt
# certificates using the HTTP-01 webroot challenge served by the gateway.

set -e

log_info() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $*"
}

log_warn() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [WARN] $*" >&2
}

log_error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
}

SSL_MODE=${SSL_MODE:-dev}
SSL_STAGING=${SSL_STAGING:-false}
CERT_ROOT_PATH=${CERT_ROOT_PATH:-/etc/letsencrypt}
CERTBOT_DATA_PATH=${CERTBOT_DATA_PATH:-/var/www/certbot}
CERT_RSA_KEY_SIZE=${CERT_RSA_KEY_SIZE:-2048}
CERT_TEMP_CERT_DAYS=${CERT_TEMP_CERT_DAYS:-365}
CERT_NGINX_STARTUP_WAIT=${CERT_NGINX_STARTUP_WAIT:-10}
CERT_RENEWAL_INTERVAL=${CERT_RENEWAL_INTERVAL:-12h}
CERT_PROFILE=${CERT_PROFILE:-}
CERT_CONTACT_EMAIL=${CERT_CONTACT_EMAIL:-}
CERT_ORG=${CERT_ORG:-"Centro de Salud Santa Clotilde"}
CERT_OU=${CERT_OU:-"sihsalus"}
CERT_COUNTRY=${CERT_COUNTRY:-"PE"}
CERT_STATE=${CERT_STATE:-"Loreto"}
CERT_LOCALITY=${CERT_LOCALITY:-"Maynas"}

if [ -z "${CERT_WEB_DOMAINS:-}" ]; then
    log_error "CERT_WEB_DOMAINS is required"
    exit 1
fi

OLD_IFS="$IFS"
IFS=","
set -- ${CERT_WEB_DOMAINS}
IFS=${OLD_IFS}

FIRST_DOMAIN="$1"
CERT_WEB_DOMAIN_COMMON_NAME="${CERT_WEB_DOMAIN_COMMON_NAME:-$FIRST_DOMAIN}"

HAS_IP_ADDRESS=false
for DOMAIN in "$@"; do
    if echo "$DOMAIN" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || echo "$DOMAIN" | grep -q ':'; then
        HAS_IP_ADDRESS=true
        break
    fi
done

if [ "$HAS_IP_ADDRESS" = "true" ] && [ "${SSL_MODE}" = "prod" ]; then
    if [ -z "${CERT_PROFILE}" ]; then
        log_info "IP address detected. Selecting Let's Encrypt 'shortlived' profile."
        CERT_PROFILE="shortlived"
    elif [ "${CERT_PROFILE}" != "shortlived" ]; then
        log_error "IP address detected but CERT_PROFILE is '${CERT_PROFILE}'."
        log_error "Let's Encrypt requires IP address certificates to use the 'shortlived' profile."
        exit 1
    fi
fi

log_info "=== SIH Salus Certificate Manager ==="
log_info "SSL mode: ${SSL_MODE}"
log_info "Primary domain: ${CERT_WEB_DOMAIN_COMMON_NAME}"
log_info "RSA key size: ${CERT_RSA_KEY_SIZE} bits"
if [ -n "${CERT_PROFILE}" ]; then
    log_info "Certificate profile: ${CERT_PROFILE}"
fi

ensure_tls_params() {
    mkdir -p "${CERTBOT_DATA_PATH}/conf"

    if [ ! -e "${CERTBOT_DATA_PATH}/conf/options-ssl-nginx.conf" ]; then
        log_info "Creating nginx TLS options"
        cat > "${CERTBOT_DATA_PATH}/conf/options-ssl-nginx.conf" <<'EOF'
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1440m;
ssl_session_tickets off;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
EOF
    fi

    if [ ! -e "${CERTBOT_DATA_PATH}/conf/ssl-dhparams.pem" ]; then
        log_info "Creating DH parameters (${CERT_RSA_KEY_SIZE} bits)"
        openssl dhparam -out "${CERTBOT_DATA_PATH}/conf/ssl-dhparams.pem" "${CERT_RSA_KEY_SIZE}"
    fi
}

start_renewal_daemon() {
    log_info "Starting Let's Encrypt renewal daemon"
    log_info "Renewal interval: ${CERT_RENEWAL_INTERVAL}"
    trap 'log_info "Received SIGTERM, shutting down"; exit 0' TERM
    while :; do
        certbot renew --webroot -w "${CERTBOT_DATA_PATH}" \
            --deploy-hook "touch ${CERTBOT_DATA_PATH}/.reload-nginx" || true
        sleep "${CERT_RENEWAL_INTERVAL}" &
        wait $!
    done
}

CERT_FILE="${CERT_ROOT_PATH}/live/${CERT_WEB_DOMAIN_COMMON_NAME}/fullchain.pem"
KEY_FILE="${CERT_ROOT_PATH}/live/${CERT_WEB_DOMAIN_COMMON_NAME}/privkey.pem"
RENEWAL_CONF="${CERT_ROOT_PATH}/renewal/${CERT_WEB_DOMAIN_COMMON_NAME}.conf"

ensure_tls_params

if [ -f "${CERT_FILE}" ] && [ -f "${KEY_FILE}" ]; then
    log_info "Certificates already exist for ${CERT_WEB_DOMAIN_COMMON_NAME}"
    if [ "${SSL_MODE}" = "prod" ]; then
        if [ -f "${RENEWAL_CONF}" ]; then
            start_renewal_daemon
        fi
        log_warn "Existing certificate has no certbot renewal config; replacing it with a Let's Encrypt certificate"
        rm -rf "${CERT_ROOT_PATH}/live/${CERT_WEB_DOMAIN_COMMON_NAME}"
        rm -rf "${CERT_ROOT_PATH}/archive/${CERT_WEB_DOMAIN_COMMON_NAME}"
        rm -f "${RENEWAL_CONF}"
    else
        log_info "Dev mode: certificates exist, nothing to do"
        exit 0
    fi
fi

mkdir -p "${CERT_ROOT_PATH}/live/${CERT_WEB_DOMAIN_COMMON_NAME}"

if [ "${SSL_MODE}" = "dev" ]; then
    log_info "Creating self-signed certificate for internal/development use"

    DNS_NUM=0
    IP_NUM=0
    SUBJECT_ALTERNATE_NAMES=""

    for WEB_DOMAIN in "$@"; do
        if echo "$WEB_DOMAIN" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || echo "$WEB_DOMAIN" | grep -q ':'; then
            SUBJECT_ALTERNATE_NAMES="${SUBJECT_ALTERNATE_NAMES}IP.${IP_NUM} = ${WEB_DOMAIN}
"
            IP_NUM=$((IP_NUM + 1))
            log_info "SAN IP: ${WEB_DOMAIN}"
        else
            SUBJECT_ALTERNATE_NAMES="${SUBJECT_ALTERNATE_NAMES}DNS.${DNS_NUM} = ${WEB_DOMAIN}
"
            DNS_NUM=$((DNS_NUM + 1))
            log_info "SAN DNS: ${WEB_DOMAIN}"
        fi
    done

    cat > /tmp/sslconfig.conf <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_ca
prompt = no

[req_distinguished_name]
C = ${CERT_COUNTRY}
ST = ${CERT_STATE}
L = ${CERT_LOCALITY}
O = ${CERT_ORG}
OU = ${CERT_OU}
CN = ${CERT_WEB_DOMAIN_COMMON_NAME}

[v3_ca]
subjectAltName = @alternate_names
basicConstraints = critical, CA:TRUE
keyUsage = critical, digitalSignature, keyCertSign, keyEncipherment
extendedKeyUsage = serverAuth

[alternate_names]
${SUBJECT_ALTERNATE_NAMES}
EOF

    openssl req -x509 -nodes -newkey "rsa:${CERT_RSA_KEY_SIZE}" -days "${CERT_TEMP_CERT_DAYS}" \
        -keyout "${KEY_FILE}" \
        -out "${CERT_FILE}" \
        -config /tmp/sslconfig.conf

    chmod 600 "${KEY_FILE}"
    chmod 644 "${CERT_FILE}"

    log_info "Self-signed certificate created"
    openssl x509 -noout -fingerprint -sha256 -in "${CERT_FILE}"
    touch "${CERTBOT_DATA_PATH}/.reload-nginx"
    exit 0
fi

if [ "${SSL_MODE}" != "prod" ]; then
    log_error "Unsupported SSL_MODE '${SSL_MODE}'. Use 'dev' or 'prod'."
    exit 1
fi

log_info "Setting up Let's Encrypt certificate"

log_info "Creating temporary certificate so nginx can start"
openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
    -keyout "${KEY_FILE}" \
    -out "${CERT_FILE}" \
    -subj "/CN=${CERT_WEB_DOMAIN_COMMON_NAME}"

log_info "Waiting ${CERT_NGINX_STARTUP_WAIT}s for nginx to start"
sleep "${CERT_NGINX_STARTUP_WAIT}"

mkdir -p "${CERTBOT_DATA_PATH}/.well-known/acme-challenge"
echo "ok" > "${CERTBOT_DATA_PATH}/.well-known/acme-challenge/index.html"

until curl -fsS --max-time 5 http://gateway/.well-known/acme-challenge/ >/dev/null 2>&1; do
    log_info "Waiting for nginx gateway to serve ACME challenge files"
    sleep 5
done

log_info "Gateway is ready. Requesting Let's Encrypt certificate."

rm -rf "${CERT_ROOT_PATH}/live/${CERT_WEB_DOMAIN_COMMON_NAME}"
rm -rf "${CERT_ROOT_PATH}/archive/${CERT_WEB_DOMAIN_COMMON_NAME}"
rm -f "${CERT_ROOT_PATH}/renewal/${CERT_WEB_DOMAIN_COMMON_NAME}.conf"

DOMAIN_ARGS=""
for CERT_WEB_DOMAIN in "$@"; do
    DOMAIN_ARGS="${DOMAIN_ARGS} -d ${CERT_WEB_DOMAIN}"
done

if [ -n "${CERT_CONTACT_EMAIL}" ]; then
    EMAIL_ARG="--email ${CERT_CONTACT_EMAIL}"
else
    log_warn "CERT_CONTACT_EMAIL is not set. Registering without email is not recommended."
    EMAIL_ARG="--register-unsafely-without-email"
fi

STAGING_ARG=""
if [ "${SSL_STAGING}" = "true" ]; then
    log_info "Using Let's Encrypt staging environment"
    STAGING_ARG="--staging"
fi

PROFILE_ARG=""
if [ -n "${CERT_PROFILE}" ]; then
    log_info "Requesting certificate profile: ${CERT_PROFILE}"
    PROFILE_ARG="--preferred-profile ${CERT_PROFILE}"
fi

certbot certonly --webroot -w "${CERTBOT_DATA_PATH}" \
    ${STAGING_ARG} \
    ${EMAIL_ARG} \
    ${DOMAIN_ARGS} \
    ${PROFILE_ARG} \
    --cert-name "${CERT_WEB_DOMAIN_COMMON_NAME}" \
    --rsa-key-size "${CERT_RSA_KEY_SIZE}" \
    --agree-tos \
    --no-eff-email

log_info "Let's Encrypt certificate obtained"
touch "${CERTBOT_DATA_PATH}/.reload-nginx"

start_renewal_daemon
