# Runtime del frontend SIH Salus

Este directorio ensambla y sirve la SPA publicada por `sihsalus-frontend`.
El código de los microfrontends se mantiene en ese repositorio; aquí se configura
su imagen runtime y su integración con el gateway.

## Fuentes de configuración

| Archivo | Responsabilidad |
| --- | --- |
| [Dockerfile](Dockerfile) | Ensamblado desde la imagen fuente y copia al runtime Nginx |
| [nginx.conf](nginx.conf) | Servicio de archivos, caché e identidad del nodo |
| [patch-config-urls.js](patch-config-urls.js) | Validación del bootstrap actual y adaptación de shells heredados |
| [frontend-keycloak.json](frontend-keycloak.json) | Configuración del login OIDC |
| [compose/core.yml](../compose/core.yml) | Imagen, argumentos de build y healthcheck del servicio |

La etapa `assemble` parte de `FRONTEND_SOURCE_IMAGE` y ejecuta
`packages/tooling/scripts/assemble-importmap.js` de la imagen fuente. Genera el
shell, importmap, rutas, configuración y assets en `/tmp/spa`. La etapa final usa
`nginx:1.28-alpine` y sirve ese resultado desde `/usr/share/nginx/html`.

El [gateway](../gateway/README.md) publica `/openmrs/spa/`, elimina ese prefijo y
envía la solicitud al puerto interno 80 del frontend. Esto incluye
`frontend.json`; su contenido está en la imagen frontend.

## Configuración de la SPA

Los argumentos de build del core fijan `/openmrs/spa` como ruta de la SPA,
`/openmrs` como API, `es` como idioma y `/openmrs/spa/frontend.json` como
configuración. Cambiar esos valores requiere ajustar la composición y reconstruir
el runtime. El inventario de variables está en [.env.template](../.env.template).

`SPA_CONFIG_URLS` es obligatorio y admite varios JSON separados por comas, sin
duplicados. El [override Keycloak](../compose/keycloak.yml) añade
`frontend-keycloak.json`; para combinar Imaging con login local de OpenMRS, seguir
el [contrato de autenticación](../keycloak/README.md#openmrs-local-con-keycloak-para-imaging).

`patch-config-urls.js` exige que el bootstrap externo
`sihsalus-spa-bootstrap.js` ya contenga las URLs solicitadas. Una discrepancia
detiene el build, sin reescribir ese artefacto. Para una imagen heredada con
inicialización inline, adapta el único inicializador de `index.html`.

`STRIP_SOURCE_MAPS=true` elimina los archivos `*.map` del runtime por defecto.
`SIHSALUS_NODE_ID` se incorpora a la imagen y a la cabecera
`X-SIHSALUS-Node-ID` de los archivos de control; la operación de despliegue valida
la identidad esperada del entorno.

## Caché y rutas

La política canónica está en [nginx.conf](nginx.conf):

- Los archivos de control, incluidos `service-worker.js`, `importmap.json`,
  `frontend.json` y `build-info.json`, usan `no-cache, no-store, must-revalidate`.
- Los assets JS/CSS con hash de contenido usan
  `public, max-age=31536000, immutable`. Los JS/CSS sin hash y los demás archivos
  estáticos usan `no-cache, no-store, must-revalidate`.
- Los archivos estáticos ausentes devuelven 404. Las rutas de navegación de la
  SPA sirven `index.html` con la misma política de no almacenamiento.

Las cabeceras de seguridad, CSP y HTTPS se mantienen en el
[gateway](../gateway/README.md) y en el [runbook HTTPS](../docs/operations/https.md).

## Build y operación

Desde la raíz del repositorio, conservando la
[composición del entorno](../compose/README.md#configuración-persistente-en-servidores):

```sh
docker compose build frontend
```

El target `frontend` de [Docker Bake](../docker-bake.hcl) también construye el
wrapper con sus propios argumentos declarados.

Para actualizar o revertir un entorno, seguir la
[guía de despliegue](../scripts/deploy/README.md). El procedimiento valida el SHA y
digest de la imagen fuente, reconstruye y recrea exclusivamente `frontend`,
comprueba salud, revisión e identidad del nodo y conserva la recuperación de la
imagen anterior.

El healthcheck busca `initializeSpa` en el bootstrap externo y admite el HTML
heredado para conservar el rollback. La aceptación de la SPA requiere además
comprobar en el navegador el login, los assets y los errores JavaScript de la
revisión desplegada.

## Pruebas

Desde la raíz:

```sh
node --test frontend/patch-config-urls.test.js
```

La prueba [cache-policy.sh](../tests/frontend/cache-policy.sh) usa Nginx real con
fixtures locales y requiere Docker activo. Cubre archivos mutables, assets con
hash, rutas SPA y adaptación de metadatos sociales al host. Ambas comprobaciones
forman parte de CI.
