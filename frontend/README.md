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
la imagen Nginx fijada por digest en el Dockerfile y sirve ese resultado desde
`/usr/share/nginx/html`.

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
el [contrato de autenticación](../oauth/README.md#openmrs-local-con-keycloak-para-imaging).

`patch-config-urls.js` exige que el bootstrap externo
`sihsalus-spa-bootstrap.js` ya contenga las URLs solicitadas. Una discrepancia
detiene el build, sin reescribir ese artefacto. Para una imagen heredada con
inicialización inline, adapta el único inicializador de `index.html`.

`STRIP_SOURCE_MAPS=true` elimina los archivos `*.map` del runtime por defecto.
`SIHSALUS_NODE_ID` se incorpora a la imagen y a la cabecera
`X-SIHSALUS-Node-ID` de los archivos de control; la operación de despliegue valida
la identidad esperada del entorno.

## Notificaciones de laboratorio y farmacia

El runtime incluye `frontend-realtime.json`, pero no lo carga por defecto.
Después de verificar `sihsalusnotifications` >= 1.2.0 iniciado y sus transportes
con cuentas sintéticas en DEV/QLTY, añadirlo al final de `SPA_CONFIG_URLS` en
el entorno autorizado y reconstruir el wrapper mediante el procedimiento de
manifiestos existente:

```dotenv
# OpenMRS local; conservar todos los JSON que el entorno ya cargaba.
SPA_CONFIG_URLS=/openmrs/spa/frontend.json,/openmrs/spa/frontend-realtime.json
```

Con login OIDC, conservar también `/openmrs/spa/frontend-keycloak.json` antes
del JSON realtime. Compose core, Keycloak, login local y Bake aceptan la misma
variable; omitirla conserva los valores anteriores. No cambiar la autenticación
ni habilitarlo automáticamente en producción. El frontend utiliza SSE; el OMOD
también ofrece WebSocket con ticket de un solo uso.

La prueba manual usa cuentas nuevas con roles existentes `Laboratorio` y
`SIHSALUS Consulta Externa`, proveedores sintéticos y la misma ubicación de
sesión cuyo ancestro tenga el tag `Facility Location`. No asignar Super User ni
alterar roles existentes. Mantener credenciales y journal de recursos fuera de
Git, con permisos 0600; conservar las cuentas hasta terminar la prueba y después
retirarlas junto con sus proveedores, conservando referencias históricas.

1. Laboratorio abre su bandeja y confirma HTTP 200 y `text/event-stream` en
   `notifications/sse?topics=laboratory`.
2. Consulta Externa guarda una orden de laboratorio de un paciente sintético.
   Laboratorio debe recibir `LAB_ORDER_CREATED`, refetch de la bandeja y aviso
   sin F5. Finalizar un resultado debe producir `LAB_RESULT_READY`.
3. Comprobar reconexión al finalizar la respuesta SSE acotada (25 segundos) y
   tras un corte corto de red, sin avisos duplicados. Una respuesta pendiente
   mientras fluye SSE es normal.
4. Verificar que una cuenta sin el privilegio del departamento o de otra
   IPRESS no recibe el evento; abrir un transporte no demuestra autorización
   para recibir eventos ni aceptación clínica.

Los eventos llevan solo referencias de orden, no nombres ni resultados. La
bandeja REST sigue siendo la fuente de datos y el polling permanece como
respaldo. Para rollback, quitar el JSON adicional de `SPA_CONFIG_URLS` y aplicar
el wrapper/manifiesto anterior; no hay migración clínica. No borrar imágenes
ni artefactos privados de recuperación antes de verificar la reversión.

La suite `clinical-recovery` del frontend sigue en cuarentena: sus fixtures y
su limpieza requieren revisión independiente. Estas instrucciones no habilitan
ni eluden esa suite; distinguen la comprobación manual de transportes del smoke
clínico pendiente y no autorizan datos reales ni producción.

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

El target `frontend` de [Docker Bake](../docker-bake.hcl) usa el contexto y
los argumentos de Compose cuando se carga ese archivo. Ejecutado desde la raíz,
`docker buildx bake frontend` lee primero `docker-compose.yml`.
Para incluir Keycloak u otro override, pasar
los mismos archivos explícitamente y el HCL al final:

```sh
docker buildx bake -f docker-compose.yml -f compose/keycloak.yml -f docker-bake.hcl frontend
```

También se admite `docker buildx bake -f docker-bake.hcl frontend`: el HCL
incluye un target de respaldo cuyos argumentos y referencia fuente se comparan
con Compose en CI. Este modo usa las variables exportadas al proceso; para
cargar `.env` o overrides Compose, incluir los archivos Compose como arriba.
Cuando están presentes, sus argumentos prevalecen sobre el respaldo del HCL.

La referencia fuente canónica se mantiene en `compose/core.yml`; al actualizarla,
actualizar también `FRONTEND_DEFAULT_SOURCE_TAG` en `docker-bake.hcl`.
Copiar `.env.template` no cambia esa versión. `FRONTEND_SOURCE_TAG` permite
elegir otro tag/digest y `FRONTEND_SOURCE_IMAGE` tiene precedencia si se define.
Un build directo del Dockerfile debe proporcionar `FRONTEND_SOURCE_IMAGE` y
`SPA_CONFIG_URLS`; no tiene una segunda versión predeterminada.

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
python3 -B tests/frontend/build-config.py
```

La segunda comprobación requiere Compose y Buildx, sin daemon Docker. Compara
contexto, Dockerfile y argumentos con Bake automático, explícito y HCL aislado,
incluida la plantilla de entorno, los overrides de imagen/nodo y la precedencia
de `.env` y Keycloak; también corre en `validate-compose.sh`.

La prueba [cache-policy.sh](../tests/frontend/cache-policy.sh) usa Nginx real con
fixtures locales y requiere Docker activo. Cubre archivos mutables, assets con
hash, rutas SPA y adaptación de metadatos sociales al host. Estas comprobaciones
forman parte de CI.
