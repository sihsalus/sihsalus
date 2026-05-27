# syntax=docker/dockerfile:1.3
FROM alpine:3.19

# Install OpenSSL and other required tools
RUN apk --no-cache add \
    openssl \
    curl \
    bash \
    coreutils \
    tzdata && \
    # Set timezone to Lima
    cp /usr/share/zoneinfo/America/Lima /etc/localtime && \
    echo "America/Lima" > /etc/timezone

# Create directories
RUN mkdir -p /certbot/scripts /var/www/certbot/conf /etc/letsencrypt/live

# Copy scripts
COPY ./scripts /certbot/scripts
RUN chmod +x /certbot/scripts/entrypoint.sh

# Set environment variables with defaults
ENV CERT_ROOT_PATH=/etc/letsencrypt \
    CERTBOT_DATA_PATH=/var/www/certbot \
    CERT_RSA_KEY_SIZE=4096 \
    CERT_TEMP_CERT_DAYS=365 \
    CERT_RENEWAL_INTERVAL=30d \
    SSL_MODE=dev \
    CERT_WEB_DOMAINS=localhost,127.0.0.1 \
    CERT_ORG="Centro de Salud Santa Clotilde" \
    CERT_OU="sihsalus" \
    CERT_COUNTRY="PE" \
    CERT_STATE="Loreto" \
    CERT_LOCALITY="Maynas"

ENTRYPOINT [ "/certbot/scripts/entrypoint.sh" ]
