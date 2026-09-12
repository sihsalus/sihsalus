# Keycloak y OpenMRS OAuth2

Keycloak es opcional y se publica mediante el gateway bajo `/keycloak/`. El puerto directo `8180` queda ligado a localhost para administración de emergencia.

## Desarrollo

```env
KEYCLOAK_MODE=development
KEYCLOAK_ADMIN_PASSWORD=<password-seguro>
KC_DB_PASSWORD=<password-seguro>
OAUTH2_CLIENT_SECRET=<secret-del-cliente-openmrs>
IMAGING_OIDC_CLIENT_SECRET=<secret-del-cliente-imaging>
IMAGING_OAUTH_REDIRECT_URI=http://localhost/imaging/oauth2/callback
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
IMAGING_OAUTH_REDIRECT_URI=https://sihsalus.example.org/imaging/oauth2/callback
```

En modo `production`, el contenedor exige hostname y redirect URI HTTPS, habilita hostname estricto y arranca con `start --optimized`. Una URL HTTP provoca un fallo temprano. El realm usa Authorization Code Flow, mantiene deshabilitado Direct Access Grants/password grant y exige PKCE S256 en el cliente `sihsalus-imaging`.

## Wiring con OpenMRS

1. El core genera `oauth2.properties` con OAuth2 deshabilitado.
2. `compose/keycloak.yml` lo regenera con OAuth2 habilitado.
3. El backend espera la tarea de configuración y un Keycloak saludable.
4. El frontend incluye `frontend-keycloak.json` durante su build.

`OAUTH2_ENABLED` no se define en `.env`; core y override controlan ese estado para evitar configuraciones divergentes.

Los endpoints de token, user info y claves usan la red interna Docker. Las redirecciones del navegador usan `KEYCLOAK_PUBLIC_URL` a través del gateway.

## OpenMRS local con Keycloak para Imaging

Para usar el login local de OpenMRS y conservar Keycloak como proveedor de
identidad de Imaging, añadir `compose/openmrs-local-auth.yml` después de
`compose/keycloak.yml`. Ejemplo HTTPS persistente:

```env
COMPOSE_FILE=docker-compose.yml:compose/keycloak.yml:compose/imaging-auth.yml:compose/ssl.yml:compose/openmrs-local-auth.yml
COMPOSE_PROFILES=keycloak,imaging,ssl
```

El override fija `OAUTH2_ENABLED=false` en backend y generador, conserva solo
`frontend.json` como configuración del frontend y elimina la dependencia directa
backend→Keycloak y el montaje de `oauth2login.xml`. Mantiene `openmrs-data`, las
dependencias de MariaDB y del generador, los roles OpenMRS y la opción
`SIHSALUS_FORCED_PASSWORD_CHANGE_ENABLED`. Imaging sigue exigiendo ACL de red,
sesión OIDC y rol `imaging-access`; Redis, sus cookies y el gateway conservan sus
protecciones. El gateway todavía depende de Imaging/Keycloak durante el arranque.

Requiere **Docker Compose 2.24.4 o posterior**: `!reset` elimina la dependencia
de Keycloak y `!override` sustituye la lista de mounts para retirar la propiedad
OAuth2 sin perder el volumen OpenMRS. Es la semántica de
[merge de Compose](https://docs.docker.com/reference/compose-file/merge/).
La lista reemplazada corresponde al core actual; revisar los mounts de cualquier
override adicional antes de combinarlo, especialmente configuraciones de seed o
almacenamiento personalizado. No se debe usar esta opción para omitir requisitos
de autenticación de Imaging.

Se conservan los secretos requeridos por `compose/keycloak.yml`, incluido
`OAUTH2_CLIENT_SECRET`: Compose interpola ese archivo antes de aplicar el override
y el realm mantiene el cliente OpenMRS aunque la aplicación use login local.
No se rotan credenciales ni se modifican usuarios, roles o propiedades persistidas.

Validar primero el modelo final sin imprimir secretos:

```bash
docker compose version --short
docker compose config --quiet
./scripts/validate-compose.sh
```

Una transición desde SSO exige ventana y rollback coordinados: regenerar
`oauth2.properties` con `backend-oauth2-config` antes de recrear backend y reconstruir
el wrapper frontend con los argumentos nuevos. `up --no-deps backend` omite el
generador, y cambiar Compose no modifica un frontend ya construido. Verificar el
login local, cambio obligatorio de contraseña y acceso Imaging permitido/denegado
con cuentas sintéticas sobre el mismo build. Si el entorno ya tiene login local,
confirmar esos valores efectivos antes de actualizar imágenes. Retirar el override
vuelve a seleccionar SSO y requiere la misma coordinación; no cambia el modo de
un contenedor que ya esté ejecutándose.

## Usuarios y permisos

El usuario autenticado debe poder mapearse a un usuario OpenMRS. Mantén el mismo `username` en ambos sistemas y administra roles clínicos dentro de OpenMRS. El realm importado configura OIDC, pero no sustituye la autorización clínica. Imaging es la excepción explícita: el gateway exige además el realm role `imaging-access` antes de exponer OHIF o DICOMweb.

## Diagnóstico

```bash
./scripts/validate-compose.sh
docker compose logs backend-oauth2-config keycloak backend gateway
```

Si falla una redirección, revisa `KEYCLOAK_PUBLIC_URL`, `KC_HOSTNAME`, el certificado y los `Valid redirect URIs` del cliente `openmrs`.
