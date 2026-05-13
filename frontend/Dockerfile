ARG FRONTEND_SOURCE_IMAGE=ghcr.io/sihsalus/sihsalus-frontend:latest

FROM ${FRONTEND_SOURCE_IMAGE} AS assemble

USER root

ARG SPA_PATH=/openmrs/spa
ARG API_URL=/openmrs
ARG SPA_CONFIG_URLS=/openmrs/spa/frontend.json
ARG SPA_DEFAULT_LOCALE=es

ENV SPA_OUTPUT_DIR=/tmp/spa \
    SPA_PATH=${SPA_PATH} \
    API_URL=${API_URL} \
    SPA_CONFIG_URLS=${SPA_CONFIG_URLS} \
    SPA_DEFAULT_LOCALE=${SPA_DEFAULT_LOCALE}

COPY patch-config-urls.js /app/patch-config-urls.js
COPY frontend-keycloak.json /app/config/frontend-keycloak.json

RUN rm -rf "$SPA_OUTPUT_DIR" \
    && mkdir -p "$SPA_OUTPUT_DIR" \
    && node packages/tooling/scripts/assemble-importmap.js \
    && node /app/patch-config-urls.js

FROM nginx:1.28-alpine

COPY nginx.conf /etc/nginx/nginx.conf
COPY --from=assemble /tmp/spa/ /usr/share/nginx/html/
