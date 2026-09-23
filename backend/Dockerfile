# syntax=docker/dockerfile:1

ARG OPENMRS_BUILD_IMAGE=openmrs/openmrs-core:2.8.x-dev-amazoncorretto-21
# Keep the runtime base pinned; the distribution supplies its own Core WAR.
ARG OPENMRS_RUNTIME_IMAGE=openmrs/openmrs-core:2.8.x-amazoncorretto-21@sha256:7f08dd72400c08d4fbf584cc9ac7cf17d96a2ae5fa0c43b4dc60a40ea7d0b760

### Build Stage
# The dev tag provides Maven/OpenMRS build tooling for the 2.8 line.
FROM ${OPENMRS_BUILD_IMAGE} AS dev
WORKDIR /openmrs_distro

ARG MVN_ARGS_SETTINGS="-U -P backend"
ARG MVN_ARGS="install"

# Copy build files
COPY pom.xml ./

# O3 Forms is compiled and released by its owning module repository.
# Infrastructure consumes only the immutable, checksum-pinned release binary.
ARG O3FORMS_VERSION=2.3.1-sihsalus.1
ADD --checksum=sha256:34ad1c0a9d9d924fe05697dae29a442a194a51e149e59e7f4ac8b2e6856645cf \
    https://github.com/sihsalus/openmrs-module-o3forms/releases/download/${O3FORMS_VERSION}/o3forms-${O3FORMS_VERSION}.omod \
    /tmp/o3forms.omod

# REST and EMR API own their source changes, tests and release builds separately.
# Consume only their immutable release bytes, never patch or compile them here.
ARG REST_VERSION=3.5.1-sihsalus.1
ADD --checksum=sha256:8dda51c6534a2cec362bc2a1c10d40021bb3f1ef962f5c291804f2e6840b0f96 \
    https://github.com/sihsalus/openmrs-module-webservices.rest/releases/download/${REST_VERSION}/webservices.rest-${REST_VERSION}.omod \
    /tmp/webservices.rest.omod
ARG EMRAPI_VERSION=3.5.1-sihsalus.1
ADD --checksum=sha256:963122a092828b8d7bb5a20e25d99c0383d4355ef0ae5a99c4e30b620b6ab216 \
    https://github.com/sihsalus/openmrs-module-emrapi/releases/download/${EMRAPI_VERSION}/emrapi-${EMRAPI_VERSION}.omod \
    /tmp/emrapi.omod

# Build the SIHSALUS Bed Management patch from an immutable source revision.
# The checksum prevents a changed or substituted archive from entering the image.
ARG BEDMANAGEMENT_SOURCE_SHA=f7ceac08204d4239814b9978eaf7dadd8e6a62c7
ADD --checksum=sha256:428cddc778eb382f91eafa2156117b090fc75b11202919376bb615ff3d125874 \
    https://github.com/sihsalus/openmrs-module-bedmanagement/archive/${BEDMANAGEMENT_SOURCE_SHA}.tar.gz \
    /tmp/bedmanagement-source.tar.gz
COPY backend ./backend/

# Build the private BedManagement artifact and the distro in the same cache
# mount. A cached RUN must never hide an artifact that exists only as a cache
# side effect from a later RUN.
RUN --mount=type=cache,target=/root/.m2/repository \
    mkdir -p /tmp/bedmanagement-source && \
    tar -xzf /tmp/bedmanagement-source.tar.gz -C /tmp/bedmanagement-source --strip-components=1 && \
    mvn --batch-mode --show-version --no-transfer-progress \
      -Dformatter.skip=true -DskipTests -Dmaven.javadoc.skip=true \
      --file /tmp/bedmanagement-source/pom.xml install && \
    bash backend/bin/build-source-omods.sh package && \
    mvn --batch-mode --no-transfer-progress \
      org.apache.maven.plugins:maven-install-plugin:3.1.4:install-file \
      -Dfile=/tmp/o3forms.omod -DgroupId=org.openmrs.module \
      -DartifactId=o3forms-omod -Dversion=${O3FORMS_VERSION} \
      -Dpackaging=jar -DgeneratePom=true && \
    mvn --batch-mode --no-transfer-progress \
      org.apache.maven.plugins:maven-install-plugin:3.1.4:install-file \
      -Dfile=/tmp/webservices.rest.omod -DgroupId=org.openmrs.module \
      -DartifactId=webservices.rest-omod -Dversion=${REST_VERSION} \
      -Dpackaging=jar -DgeneratePom=true && \
    mvn --batch-mode --no-transfer-progress \
      org.apache.maven.plugins:maven-install-plugin:3.1.4:install-file \
      -Dfile=/tmp/emrapi.omod -DgroupId=org.openmrs.module \
      -DartifactId=emrapi-omod -Dversion=${EMRAPI_VERSION} \
      -Dpackaging=jar -DgeneratePom=true && \
    mvn $MVN_ARGS_SETTINGS $MVN_ARGS && \
    modules_dir=/openmrs_distro/backend/target/sdk-distro/web/openmrs_modules && \
    set -- "$modules_dir"/authentication-*.omod && \
    [ "$#" -eq 1 ] && [ -f "$1" ] && \
    authentication_omod="$1" && \
    set -- "$modules_dir"/legacyui-*.omod && \
    [ "$#" -eq 1 ] && [ -f "$1" ] && \
    legacyui_omod="$1" && \
    set -- "$modules_dir"/sihsalusnotifications-*.omod && \
    [ "$#" -eq 1 ] && [ -f "$1" ] && \
    notifications_omod="$1" && \
    jar tf "$authentication_omod" \
      | grep -qxF 'org/openmrs/module/authentication/web/ForcePasswordChangeFilter.class' && \
    javap -classpath "$authentication_omod" -verbose \
      org.openmrs.module.authentication.web.ForcePasswordChangeFilter \
      | grep -qF 'authentication.supportForcedPasswordChange' && \
    jar tf "$legacyui_omod" \
      | grep -qxF 'web/module/admin/users/changePasswordForm.jsp' && \
    javap -classpath "$legacyui_omod" -verbose \
      org.openmrs.web.controller.user.ChangePasswordFormController \
      | grep -qF '/admin/users/changePassword.form' && \
    jar tf "$notifications_omod" \
      | grep -qxF 'org/openmrs/module/sihsalusnotifications/web/NotificationWebSocketEndpoint.class' && \
    jar tf "$notifications_omod" \
      | grep -qxF 'org/openmrs/module/sihsalusnotifications/web/SseNotificationFilter.class' && \
    jar tf "$notifications_omod" \
      | grep -qxF 'org/openmrs/module/sihsalusnotifications/web/WebSocketTicketFilter.class' && \
    jar tf "$notifications_omod" \
      | grep -qxF 'org/openmrs/module/sihsalusnotifications/web/NotificationStatusFilter.class' && \
    notifications_api_entry="$(jar tf "$notifications_omod" \
      | grep -Ex 'lib/sihsalusnotifications-api-[0-9]+\.[0-9]+\.[0-9]+\.jar')" && \
    [ -n "$notifications_api_entry" ] && \
    [ "$(printf '%s\n' "$notifications_api_entry" | wc -l)" -eq 1 ] && \
    mkdir -p /tmp/sihsalusnotifications-omod-check && \
    cd /tmp/sihsalusnotifications-omod-check && \
    jar xf "$notifications_omod" config.xml "$notifications_api_entry" && \
    grep -qxF \
      '  <activator>org.openmrs.module.sihsalusnotifications.SihsalusNotificationsActivator</activator>' \
      config.xml && \
    jar tf "$notifications_api_entry" \
      | grep -qxF 'org/openmrs/module/sihsalusnotifications/SihsalusNotificationsActivator.class' && \
    jar tf "$notifications_api_entry" \
      | grep -qxF 'org/openmrs/module/sihsalusnotifications/api/advice/OrderCreationNotificationAdvice.class' && \
    jar tf "$notifications_api_entry" \
      | grep -qxF 'org/openmrs/module/sihsalusnotifications/api/advice/LaboratoryResultNotificationAdvice.class'

RUN cp /openmrs_distro/backend/target/sdk-distro/web/openmrs_core/openmrs.war /openmrs/distribution/openmrs_core/ && \
    cp /openmrs_distro/backend/target/sdk-distro/web/openmrs-distro.properties /openmrs/distribution/ && \
    cp -R /openmrs_distro/backend/target/sdk-distro/web/openmrs_modules /openmrs/distribution/openmrs_modules/ && \
    cp -R /openmrs_distro/backend/target/sdk-distro/web/openmrs_owas /openmrs/distribution/openmrs_owas/ && \
    cp -R /openmrs_distro/backend/target/sdk-distro/web/openmrs_config /openmrs/distribution/openmrs_config/


# Unpack in the build image: the minimal runtime intentionally has no tar.
ADD --checksum=sha256:d1a804502cddfd1c1436c1c37809ed4cb807a9c64a8a35fe1747d3ba9a0edeab \
    https://archive.apache.org/dist/tomcat/tomcat-9/v9.0.121/bin/apache-tomcat-9.0.121.tar.gz \
    /tmp/apache-tomcat.tar.gz
RUN mkdir /tmp/tomcat-runtime && \
    tar -xzf /tmp/apache-tomcat.tar.gz -C /tmp/tomcat-runtime --strip-components=1 \
      apache-tomcat-9.0.121/bin apache-tomcat-9.0.121/lib \
      apache-tomcat-9.0.121/LICENSE apache-tomcat-9.0.121/NOTICE \
      apache-tomcat-9.0.121/RELEASE-NOTES

### Run Stage
# Keep OpenMRS startup/configuration pinned; update Tomcat independently below.
FROM ${OPENMRS_RUNTIME_IMAGE}

# The upstream Amazon Linux 2 image is immutable, so apply the security updates
# that became available after its publication before dropping back to UID 1001.
USER root
# CI supplies the commit SHA so BuildKit cannot reuse a stale package-update
# layer after the distribution repositories publish new security fixes.
ARG SECURITY_REFRESH=local
RUN echo "Security refresh: ${SECURITY_REFRESH}" && \
    yum -y update acl expat glib2 libacl libssh2 openssl-libs openssl11-libs python python-libs vim-data vim-minimal && \
    yum clean all && \
    rm -rf /var/cache/yum

# The pinned upstream runtime still contains Tomcat 9.0.120. Replace the complete
# Java runtime distribution, preserving OpenMRS's server.xml and rootless setup.
# 9.0.121 fixes CVE-2026-65182, CVE-2026-65905 and CVE-2026-68525.
ENV TOMCAT_VERSION=9.0.121 \
    TOMCAT_SHA512=16494dd4745f808d3c506807b5275521fd71044d976f441d18eeeab0f5a38bc1b5344ca395292f6f26eb7612cd8c8e746d01ccdfb29893d394052d9f4b1f4c11
RUN rm -rf /usr/local/tomcat/bin /usr/local/tomcat/lib
COPY --from=dev /tmp/tomcat-runtime/ /usr/local/tomcat/
RUN chmod -R g+rx /usr/local/tomcat/bin /usr/local/tomcat/lib && \
    touch /usr/local/tomcat/bin/setenv.sh && \
    chmod g+w /usr/local/tomcat/bin/setenv.sh && \
    /usr/local/tomcat/bin/version.sh | grep -qF 'Apache Tomcat/9.0.121'

COPY --chmod=0555 backend/bin/configure-ocl-token.sh \
    backend/bin/configure-forced-password-change.sh /usr/local/bin/

# The pinned OpenMRS runtime quotes the wildcard used to clear distribution
# directories, so removed modules and metadata survive in the persistent volume.
# Keep the upstream safety guard while allowing the wildcard to expand.
RUN bash -n /usr/local/bin/configure-ocl-token.sh && \
    bash -n /usr/local/bin/configure-forced-password-change.sh && \
    sed -i \
      -e 's|rm -fR "${OMRS_MODULES_DIR:?}/\*"|rm -fR "${OMRS_MODULES_DIR:?}"/*|' \
      -e 's|rm -fR "${OMRS_OWA_DIR:?}/\*"|rm -fR "${OMRS_OWA_DIR:?}"/*|' \
      -e 's|rm -fR "${OMRS_CONFIG_DIR:?}/\*"|rm -fR "${OMRS_CONFIG_DIR:?}"/*|' \
      -e 's|rm -fR "${OMRS_FRONTEND_DIR:?}/\*"|rm -fR "${OMRS_FRONTEND_DIR:?}"/*|' \
      /openmrs/startup-init.sh && \
    grep -qF 'rm -fR "${OMRS_MODULES_DIR:?}"/*' /openmrs/startup-init.sh && \
    grep -qF 'rm -fR "${OMRS_OWA_DIR:?}"/*' /openmrs/startup-init.sh && \
    grep -qF 'rm -fR "${OMRS_CONFIG_DIR:?}"/*' /openmrs/startup-init.sh && \
    grep -qF 'rm -fR "${OMRS_FRONTEND_DIR:?}"/*' /openmrs/startup-init.sh && \
    printf '\n%s\n%s\n' \
      '/usr/local/bin/configure-ocl-token.sh "$OMRS_CONFIG_DIR" "$OMRS_DATA_DIR/configuration_checksums"' \
      '/usr/local/bin/configure-forced-password-change.sh "$OMRS_SERVER_PROPERTIES_FILE" "$OMRS_RUNTIME_PROPERTIES_FILE"' \
      >> /openmrs/startup-init.sh && \
    [ "$(grep -Fc '/usr/local/bin/configure-ocl-token.sh' /openmrs/startup-init.sh)" -eq 1 ] && \
    [ "$(grep -Fc '/usr/local/bin/configure-forced-password-change.sh' /openmrs/startup-init.sh)" -eq 1 ] && \
    tail -n 1 /openmrs/startup-init.sh \
      | grep -qxF '/usr/local/bin/configure-forced-password-change.sh "$OMRS_SERVER_PROPERTIES_FILE" "$OMRS_RUNTIME_PROPERTIES_FILE"'

COPY --from=dev /openmrs/distribution/openmrs_core/openmrs.war /openmrs/distribution/openmrs_core/

COPY --from=dev /openmrs/distribution/openmrs-distro.properties /openmrs/distribution/
COPY --from=dev /openmrs/distribution/openmrs_modules /openmrs/distribution/openmrs_modules
COPY --from=dev /openmrs/distribution/openmrs_owas /openmrs/distribution/openmrs_owas
COPY --from=dev  /openmrs/distribution/openmrs_config /openmrs/distribution/openmrs_config

RUN mkdir -p /openmrs/data

# Prepare Tomcat's default Host XML base before dropping privileges. Keep the
# parent configuration root-owned; only this empty Host directory is writable.
RUN install -d -o 0 -g 0 -m 0755 /usr/local/tomcat/conf/Catalina && \
    install -d -o 1001 -g 0 -m 0750 /usr/local/tomcat/conf/Catalina/localhost

USER 1001
