# keycloak/Dockerfile
FROM quay.io/keycloak/keycloak:26.4.1

# Non-sensitive defaults. Credentials are injected by Compose at runtime.
ENV KEYCLOAK_ADMIN=admin
ENV KC_DB=postgres
ENV KC_DB_URL=jdbc:postgresql://keycloak-db:5432/keycloak
ENV KC_DB_USERNAME=keycloak
ENV KC_HOSTNAME=localhost
ENV KC_HOSTNAME_STRICT=false
# Health is a build-time option. Production starts this optimized image and
# cannot enable the management endpoint using only a runtime environment value.
ENV KC_HEALTH_ENABLED=true

# Import automático de realm
ENV KEYCLOAK_IMPORT=/opt/keycloak/data/import/realm-export.json

# Copiamos el realm duro
COPY realm-export.json /opt/keycloak/data/import/realm-export.json
COPY entrypoint.sh /opt/keycloak/bin/sihsalus-entrypoint.sh
COPY healthcheck.sh /opt/keycloak/bin/sihsalus-healthcheck.sh

# Ajustamos permisos para el usuario 1000
USER root
RUN chown -R 1000:0 /opt/keycloak/data \
    && chmod 755 /opt/keycloak/bin/sihsalus-entrypoint.sh /opt/keycloak/bin/sihsalus-healthcheck.sh
USER 1000

# Pre-compilación para PostgreSQL
RUN /opt/keycloak/bin/kc.sh build --db=${KC_DB}

ENTRYPOINT ["/opt/keycloak/bin/sihsalus-entrypoint.sh"]
