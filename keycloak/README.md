# Keycloak y OpenMRS OAuth2

Keycloak es opcional y se publica mediante el gateway bajo `/keycloak/`. El puerto directo `8180` queda ligado a localhost para administración de emergencia.

## Desarrollo

```env
KEYCLOAK_MODE=development
KEYCLOAK_ADMIN_PASSWORD=<password-seguro>
KC_DB_PASSWORD=<password-seguro>
OAUTH2_CLIENT_SECRET=<secret-del-cliente-openmrs>
KC_HOSTNAME=http://localhost/keycloak
KEYCLOAK_PUBLIC_URL=http://localhost/keycloak
OPENMRS_REDIRECT_URI=http://localhost/openmrs/*
```

```bash
docker compose \
  -f docker-compose.yml \
  -f compose/keycloak.yml \
  --profile keycloak \
  up -d --build
```

Acceso: `http://localhost/keycloak/`.

## Producción HTTPS

Keycloak conserva HTTP únicamente dentro de Docker; el gateway termina TLS y envía headers `X-Forwarded-*`. No publiques `8180` en la red.

```env
COMPOSE_FILE=docker-compose.yml:compose/keycloak.yml:compose/ssl.yml
COMPOSE_PROFILES=keycloak,ssl
KEYCLOAK_MODE=production
KC_HOSTNAME=https://sihsalus.example.org/keycloak
KEYCLOAK_PUBLIC_URL=https://sihsalus.example.org/keycloak
OPENMRS_REDIRECT_URI=https://sihsalus.example.org/openmrs/*
```

En modo `production`, el contenedor exige hostname y redirect URI HTTPS, habilita hostname estricto y arranca con `start --optimized`. Una URL HTTP provoca un fallo temprano. El realm usa Authorization Code Flow y mantiene deshabilitado Direct Access Grants/password grant.

## Wiring con OpenMRS

1. El core genera `oauth2.properties` con OAuth2 deshabilitado.
2. `compose/keycloak.yml` lo regenera con OAuth2 habilitado.
3. El backend espera la tarea de configuración y un Keycloak saludable.
4. El frontend incluye `frontend-keycloak.json` durante su build.

`OAUTH2_ENABLED` no se define en `.env`; core y override controlan ese estado para evitar configuraciones divergentes.

Los endpoints de token, user info y claves usan la red interna Docker. Las redirecciones del navegador usan `KEYCLOAK_PUBLIC_URL` a través del gateway.

## Usuarios y permisos

El usuario autenticado debe poder mapearse a un usuario OpenMRS. Mantén el mismo `username` en ambos sistemas y administra roles clínicos dentro de OpenMRS. El realm importado configura OIDC, pero no sustituye la autorización clínica.

## Diagnóstico

```bash
./scripts/validate-compose.sh
docker compose logs backend-oauth2-config keycloak backend gateway
```

Si falla una redirección, revisa `KEYCLOAK_PUBLIC_URL`, `KC_HOSTNAME`, el certificado y los `Valid redirect URIs` del cliente `openmrs`.
