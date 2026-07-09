# Keycloak y OpenMRS OAuth2

Keycloak es opcional. El core genera `oauth2.properties` con OAuth2 deshabilitado; `compose/keycloak.yml` activa OAuth2, exige credenciales y agrega la configuración del login al frontend.

## Activación

Configura como mínimo:

```env
KEYCLOAK_ADMIN_PASSWORD=<password-seguro>
KC_DB_PASSWORD=<password-seguro>
OAUTH2_CLIENT_SECRET=<secret-del-cliente-openmrs>
KC_HOSTNAME=localhost
KEYCLOAK_PUBLIC_URL=http://localhost:8180
```

Inicia el stack:

```bash
docker compose \
  -f docker-compose.yml \
  -f compose/keycloak.yml \
  --profile keycloak \
  up -d --build
```

`--build` es necesario cuando cambia la lista de configuraciones del frontend. El override agrega `frontend-keycloak.json` durante el ensamblado de la SPA.

## Flujo de configuración

1. `backend-oauth2-config` escribe la configuración efectiva en el volumen `openmrs-data`.
2. El backend espera que esa tarea termine.
3. Con el override, el backend también espera que Keycloak esté saludable.
4. El frontend muestra el proveedor OAuth2 configurado en `frontend/frontend-keycloak.json`.

`OAUTH2_ENABLED` no debe definirse en `.env`. Permitir que el ambiente lo cambie sin cargar el override produciría un backend y un archivo de configuración en estados distintos.

## URLs internas y públicas

- Los endpoints de token, user info y claves usan `http://keycloak:8080` dentro de Docker.
- Las redirecciones del navegador usan `KEYCLOAK_PUBLIC_URL`.
- `KC_HOSTNAME` debe representar el host aceptado por Keycloak.

En un entorno HTTPS, Keycloak también debe publicarse con una URL HTTPS válida o detrás de un proxy TLS. No conviene servir OpenMRS por HTTPS y enviar credenciales de identidad a Keycloak por HTTP en una red no confiable.

## Usuarios

El módulo OAuth2 de OpenMRS necesita poder mapear el usuario autenticado. Mantén el mismo `username` en OpenMRS y Keycloak y asigna los roles clínicos en OpenMRS. El realm importado es una base de configuración, no un reemplazo de la administración de permisos de OpenMRS.

## Validación y diagnóstico

```bash
./scripts/validate-compose.sh

docker compose \
  -f docker-compose.yml \
  -f compose/keycloak.yml \
  --profile keycloak \
  logs backend-oauth2-config keycloak backend
```

Si falla una redirección, revisa `KEYCLOAK_PUBLIC_URL`, `KC_HOSTNAME` y los `Valid redirect URIs` del cliente `openmrs` en el realm.
