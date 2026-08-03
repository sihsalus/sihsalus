# Despliegue del frontend

`deploy-frontend.sh` actualiza exclusivamente el frontend desde una imagen
inmutable que ya fue publicada y analizada en `sihsalus-frontend`.

El script:

1. valida el SHA y digest solicitados;
2. actualiza el checkout del distro mediante fast-forward;
3. fija `FRONTEND_SOURCE_IMAGE` al digest inmutable y conserva el tag SHA como
   metadato operativo; el runtime local recibe un tag derivado del mismo digest
   para que un rebuild del mismo commit no destruya la ruta de rollback;
4. reconstruye el wrapper runtime y recrea solo `frontend`;
5. verifica salud, imagen y `build-info.json`;
6. restaura la configuración y el contenedor anterior si falla;
7. solo después de verificar el frontend, elimina imágenes antiguas de los dos
   repositorios exclusivos del frontend y conserva las imágenes fuente y
   runtime activas.

No ejecuta `docker compose pull`, `up`, `restart` ni `build` sobre el stack
completo. El único pull explícito es la imagen fuente del frontend por digest;
el build y la recreación están dirigidos exclusivamente al servicio `frontend`
con `--no-deps`. La limpieza tampoco usa `docker image prune`: enumera
únicamente `ghcr.io/sihsalus/sihsalus-frontend` y el repositorio runtime
configurado en `FRONTEND_RUNTIME_IMAGE`, por lo que no elimina imágenes de
OpenMRS, base de datos, gateway ni otros servicios.

La automatización normal vive en `.github/workflows/deploy-frontend.yml`. Una
release verificada de `sihsalus-frontend` publica el tag de señal
`frontend-release-<SHA>` en este repositorio mediante una deploy key limitada al
distro. El workflow exige que ese SHA y su digest correspondan a la imagen
`latest` promovida y los valida contra la imagen inmutable antes de desplegar.
El sondeo programado de `latest` permanece como respaldo si falla la señal
inmediata.

Para una ejecución manual:

```bash
./scripts/deploy/deploy-frontend.sh \
  0123456789abcdef0123456789abcdef01234567 \
  sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

El comando debe ejecutarse desde la raíz del repositorio. Durante una
actualización, la imagen anterior permanece disponible hasta que terminan la
verificación y la posibilidad de rollback automático. Una reversión posterior
a un despliegue exitoso vuelve a descargar por digest y reconstruir el frontend
anterior.

## Redeploy integral no destructivo

`redeploy-environment.sh` se usa para reconstruir y recrear un ambiente
completo cuando una actualización exclusiva del frontend no es suficiente.
Recibe el commit y digest ya publicados del backend para que un `BACKEND_TAG`
antiguo en el servidor no pueda degradar el despliegue:

```bash
./scripts/deploy/redeploy-environment.sh \
  0123456789abcdef0123456789abcdef01234567 \
  sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

Opera sobre los archivos y perfiles definidos por el `.env` del servidor:

1. rechaza cambios locales en archivos versionados y el perfil destructivo
   `seed`;
2. actualiza `main` únicamente mediante fast-forward;
3. descarga por digest la imagen solicitada del backend clásico
   `ghcr.io/sihsalus/sihsalus-backend`, construido desde `backend/pom.xml`, y
   valida que su revisión OCI coincida con el commit solicitado;
4. descarga las imágenes de registry de todos los perfiles activos;
5. reconstruye sin caché y de forma secuencial los runtimes locales activos
   (`frontend`, `gateway`, `certbot` y/o `keycloak`) para limitar el consumo de
   CPU, memoria y red del host;
6. recrea todos los servicios activos, pero conserva volúmenes y datos;
7. espera MariaDB, frontend, OpenMRS y gateway, y verifica el estado de todos
   los servicios antes de declarar el ambiente usable;
8. solo entonces persiste en `.env` la referencia inmutable
   `sha-<commit>@sha256:<digest>` usada por el backend.

No ejecuta `docker compose down`, no usa `-v` y no elimina volúmenes. El
workflow manual `Redeploy Non-Production` solicita el SHA y digest del backend,
ejecuta primero DEV y solo promueve a QLTY si DEV y sus verificaciones HTTP
terminan correctamente. La conexión usa keepalive con tolerancia de diez
minutos y la espera de OpenMRS emite progreso periódico para tolerar arranques
largos.

Si un establecimiento está temporalmente sin DNS o salida a Internet, se puede
usar `REDEPLOY_OFFLINE=true` únicamente después de transferir y verificar el
checkout y todas las imágenes runtime deseadas. Ese modo omite `git fetch`, los
pulls y los builds; recrea los servicios exclusivamente con las imágenes
prevalidadas que ya estén presentes. También exige el SHA y digest del backend;
la referencia por digest debe haberse descargado explícitamente o transferido
con sus metadatos de `RepoDigest`. La referencia solo se persiste después de
completar las verificaciones.
