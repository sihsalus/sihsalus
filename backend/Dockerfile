# syntax=docker/dockerfile:1

ARG OPENMRS_BUILD_IMAGE=openmrs/openmrs-core:2.8.x-dev-amazoncorretto-21
# Pin the multi-arch runtime used by Reference Application 3.7.1. The Core
# 2.8.8 WAR is copied below; its exact runtime tag contains a reverted DB check.
ARG OPENMRS_RUNTIME_IMAGE=openmrs/openmrs-core:2.8.x-amazoncorretto-21@sha256:7f08dd72400c08d4fbf584cc9ac7cf17d96a2ae5fa0c43b4dc60a40ea7d0b760

### Build Stage
# The dev tag provides Maven/OpenMRS build tooling for the 2.8 line.
FROM ${OPENMRS_BUILD_IMAGE} AS dev
WORKDIR /openmrs_distro

ARG MVN_ARGS_SETTINGS="-U -P backend"
ARG MVN_ARGS="install"

# Copy build files
COPY pom.xml ./
COPY backend/pom.xml ./backend/

# Pre-download all dependencies into the BuildKit cache.
RUN --mount=type=cache,target=/root/.m2/repository \
    mvn $MVN_ARGS_SETTINGS dependency:resolve -B || true

COPY backend ./backend/

# Build the distro
RUN --mount=type=cache,target=/root/.m2/repository \
    mvn $MVN_ARGS_SETTINGS $MVN_ARGS

RUN cp /openmrs_distro/backend/target/sdk-distro/web/openmrs_core/openmrs.war /openmrs/distribution/openmrs_core/ && \
    cp /openmrs_distro/backend/target/sdk-distro/web/openmrs-distro.properties /openmrs/distribution/ && \
    cp -R /openmrs_distro/backend/target/sdk-distro/web/openmrs_modules /openmrs/distribution/openmrs_modules/ && \
    cp -R /openmrs_distro/backend/target/sdk-distro/web/openmrs_owas /openmrs/distribution/openmrs_owas/ && \
    cp -R /openmrs_distro/backend/target/sdk-distro/web/openmrs_config /openmrs/distribution/openmrs_config/


### Run Stage
# Runtime stays pinned to the exact OpenMRS patch version used in production.
FROM ${OPENMRS_RUNTIME_IMAGE}

# Do not copy the war if using the correct openmrs-core image version
COPY --from=dev /openmrs/distribution/openmrs_core/openmrs.war /openmrs/distribution/openmrs_core/

COPY --from=dev /openmrs/distribution/openmrs-distro.properties /openmrs/distribution/
COPY --from=dev /openmrs/distribution/openmrs_modules /openmrs/distribution/openmrs_modules
COPY --from=dev /openmrs/distribution/openmrs_owas /openmrs/distribution/openmrs_owas
COPY --from=dev  /openmrs/distribution/openmrs_config /openmrs/distribution/openmrs_config

RUN mkdir -p /openmrs/data
