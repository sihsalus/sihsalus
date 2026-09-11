# syntax=docker/dockerfile:1.7

# OHIF 3.9.3. PUBLIC_URL is a webpack build input, not a runtime setting.
# Keep the commit and archive checksum together when updating the viewer.
FROM node:22.23.2-bookworm-slim AS build

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential python3 git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/ohif
ADD --checksum=sha256:1970ce0648602aa252a2df073eb5d7cbd4f04f00e26e8c68b0810499aaf3d57e \
    https://codeload.github.com/OHIF/Viewers/tar.gz/b7b53be671057e6fec1fd0055ed34882475d792e /tmp/ohif-source.tar.gz
RUN tar -xzf /tmp/ohif-source.tar.gz --strip-components=1 \
    && rm /tmp/ohif-source.tar.gz

ENV CYPRESS_INSTALL_BINARY=0 \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    HUSKY=0
RUN corepack enable \
    && corepack prepare yarn@1.22.22 --activate \
    && yarn install --frozen-lockfile --non-interactive

COPY app-config.js platform/app/public/config/sihsalus.js
COPY index.html platform/app/public/html-templates/sihsalus.html
COPY bootstrap.js platform/app/public/sihsalus-bootstrap.js
COPY prepare-source.mjs verify-dist.mjs /opt/sihsalus-imaging/

# Keep upstream production optimization enabled. The router, template, lazy
# chunks and workers all use the same compiled public prefix.
ENV PUBLIC_URL=/imaging/ \
    APP_CONFIG=config/sihsalus.js \
    HTML_TEMPLATE=sihsalus.html \
    QUICK_BUILD=false
RUN node /opt/sihsalus-imaging/prepare-source.mjs /opt/ohif
RUN yarn run build \
    && mkdir -p platform/app/dist/dicom-microscopy-viewer \
    && cp -a node_modules/dicom-microscopy-viewer/dist/dynamic-import/. platform/app/dist/dicom-microscopy-viewer/ \
    && rm -f platform/app/dist/init-service-worker.js platform/app/dist/sw.js \
    && node /opt/sihsalus-imaging/verify-dist.mjs platform/app/dist

FROM nginx:1.28-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /opt/ohif/platform/app/dist/ /usr/share/nginx/html/

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1/sihsalus-bootstrap.js || exit 1
