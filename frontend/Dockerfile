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

COPY patch-config-urls.js /app/patch-config-urls.js
COPY frontend-keycloak.json /app/config/frontend-keycloak.json

RUN test -n "$SPA_CONFIG_URLS" || { echo "SPA_CONFIG_URLS build arg is required; define it in compose/core.yml"; exit 1; } \
    && rm -rf "$SPA_OUTPUT_DIR" \
    && mkdir -p "$SPA_OUTPUT_DIR" \
    && node packages/tooling/scripts/assemble-importmap.js \
    && node /app/patch-config-urls.js \
    && if [ "$STRIP_SOURCE_MAPS" = "true" ]; then \
         find "$SPA_OUTPUT_DIR" -type f -name "*.map" -delete; \
       fi

FROM nginx:1.28-alpine

ARG SIHSALUS_NODE_ID=unconfigured

LABEL org.sihsalus.node-id="${SIHSALUS_NODE_ID}"

COPY nginx.conf /etc/nginx/nginx.conf
COPY --from=assemble /tmp/spa/ /usr/share/nginx/html/

RUN { [ "$SIHSALUS_NODE_ID" = "unconfigured" ] || \
      printf '%s\n' "$SIHSALUS_NODE_ID" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; } \
    && sed -i "s|__SIHSALUS_NODE_ID__|${SIHSALUS_NODE_ID}|g" /etc/nginx/nginx.conf \
    && ! grep -Fq '__SIHSALUS_NODE_ID__' /etc/nginx/nginx.conf
