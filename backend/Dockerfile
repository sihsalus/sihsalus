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

# Build the SIHSALUS Bed Management patch from an immutable source revision.
# The checksum prevents a changed or substituted archive from entering the image.
ARG BEDMANAGEMENT_SOURCE_SHA=e2bb2f3f297e2cb6e292779f78c97f1fe33a917c
ADD --checksum=sha256:cc96957c0a84a19ee503cd1ad6270801215f7c47cf66c35a0583dfa7304b889e \
    https://github.com/sihsalus/openmrs-module-bedmanagement/archive/${BEDMANAGEMENT_SOURCE_SHA}.tar.gz \
    /tmp/bedmanagement-source.tar.gz
RUN --mount=type=cache,target=/root/.m2/repository \
    mkdir -p /tmp/bedmanagement-source && \
    tar -xzf /tmp/bedmanagement-source.tar.gz -C /tmp/bedmanagement-source --strip-components=1 && \
    mvn --batch-mode --show-version --no-transfer-progress \
      -Dformatter.skip=true -DskipTests -Dmaven.javadoc.skip=true \
      --file /tmp/bedmanagement-source/pom.xml install

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

# The upstream Amazon Linux 2 image is immutable, so apply the security updates
# that became available after its publication before dropping back to UID 1001.
USER root
RUN yum -y update expat glib2 libssh2 python python-libs vim-data vim-minimal && \
    yum clean all && \
    rm -rf /var/cache/yum

# The pinned OpenMRS runtime quotes the wildcard used to clear distribution
# directories, so removed modules and metadata survive in the persistent volume.
# Keep the upstream safety guard while allowing the wildcard to expand.
RUN sed -i \
      -e 's|rm -fR "${OMRS_MODULES_DIR:?}/\*"|rm -fR "${OMRS_MODULES_DIR:?}"/*|' \
      -e 's|rm -fR "${OMRS_OWA_DIR:?}/\*"|rm -fR "${OMRS_OWA_DIR:?}"/*|' \
      -e 's|rm -fR "${OMRS_CONFIG_DIR:?}/\*"|rm -fR "${OMRS_CONFIG_DIR:?}"/*|' \
      -e 's|rm -fR "${OMRS_FRONTEND_DIR:?}/\*"|rm -fR "${OMRS_FRONTEND_DIR:?}"/*|' \
      /openmrs/startup-init.sh && \
    grep -qF 'rm -fR "${OMRS_MODULES_DIR:?}"/*' /openmrs/startup-init.sh && \
    grep -qF 'rm -fR "${OMRS_OWA_DIR:?}"/*' /openmrs/startup-init.sh && \
    grep -qF 'rm -fR "${OMRS_CONFIG_DIR:?}"/*' /openmrs/startup-init.sh && \
    grep -qF 'rm -fR "${OMRS_FRONTEND_DIR:?}"/*' /openmrs/startup-init.sh

# Do not copy the war if using the correct openmrs-core image version
COPY --from=dev /openmrs/distribution/openmrs_core/openmrs.war /openmrs/distribution/openmrs_core/

COPY --from=dev /openmrs/distribution/openmrs-distro.properties /openmrs/distribution/
COPY --from=dev /openmrs/distribution/openmrs_modules /openmrs/distribution/openmrs_modules
COPY --from=dev /openmrs/distribution/openmrs_owas /openmrs/distribution/openmrs_owas
COPY --from=dev  /openmrs/distribution/openmrs_config /openmrs/distribution/openmrs_config

RUN mkdir -p /openmrs/data

USER 1001
