ARG FRONTEND_SOURCE_IMAGE=ghcr.io/sihsalus/sihsalus-frontend:latest
ARG STRIP_SOURCE_MAPS=true

FROM ${FRONTEND_SOURCE_IMAGE} AS assemble

USER root

ARG SPA_PATH=/openmrs/spa
ARG API_URL=/openmrs
ARG SPA_CONFIG_URLS
ARG SPA_DEFAULT_LOCALE=es
ARG STRIP_SOURCE_MAPS=true

ENV SPA_OUTPUT_DIR=/tmp/spa \
    SPA_PATH=${SPA_PATH} \
    API_URL=${API_URL} \
    SPA_CONFIG_URLS=${SPA_CONFIG_URLS} \
    SPA_DEFAULT_LOCALE=${SPA_DEFAULT_LOCALE}

COPY frontend-keycloak.json /app/config/frontend-keycloak.json

RUN test -n "$SPA_CONFIG_URLS" || { echo "SPA_CONFIG_URLS build arg is required; define it in compose/core.yml"; exit 1; } \
    && rm -rf "$SPA_OUTPUT_DIR" \
    && mkdir -p "$SPA_OUTPUT_DIR" \
    && node packages/tooling/scripts/assemble-importmap.js \
    && if [ "$STRIP_SOURCE_MAPS" = "true" ]; then \
         find "$SPA_OUTPUT_DIR" -type f -name "*.map" -delete; \
       fi

FROM nginx:1.28-alpine

COPY nginx.conf /etc/nginx/nginx.conf
COPY --from=assemble /tmp/spa/ /usr/share/nginx/html/
