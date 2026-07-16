# syntax=docker/dockerfile:1.3
FROM certbot/certbot:v4.0.0

RUN apk --no-cache add \
    curl \
    tzdata && \
    cp /usr/share/zoneinfo/America/Lima /etc/localtime && \
    echo "America/Lima" > /etc/timezone

RUN mkdir -p /certbot/scripts /var/www/certbot/conf /etc/letsencrypt/live

COPY ./scripts /certbot/scripts
RUN chmod +x /certbot/scripts/entrypoint.sh

ENV CERT_ROOT_PATH=/etc/letsencrypt \
    CERTBOT_DATA_PATH=/var/www/certbot \
    CERT_RSA_KEY_SIZE=2048 \
    CERT_TEMP_CERT_DAYS=365 \
    CERT_NGINX_STARTUP_WAIT=10 \
    CERT_RENEWAL_INTERVAL=12h \
    CERT_PROFILE= \
    CERT_CONTACT_EMAIL= \
    SSL_STAGING=false \
    SSL_MODE=dev \
    CERT_WEB_DOMAINS=localhost,127.0.0.1 \
    CERT_ORG="Centro de Salud Santa Clotilde" \
    CERT_OU="sihsalus" \
    CERT_COUNTRY="PE" \
    CERT_STATE="Loreto" \
    CERT_LOCALITY="Maynas"

ENTRYPOINT [ "/certbot/scripts/entrypoint.sh" ]
