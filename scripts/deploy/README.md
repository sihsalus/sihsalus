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

Después de cada despliegue, `verify-external-frontend.sh` abre por defecto 12
conexiones HTTP/1.1 independientes durante 55 segundos. En cada muestra valida
`/health`, `/ready`, `/openmrs/health/started` y `build-info.json`, omite cachés
y exige que todas las revisiones observadas coincidan con el SHA desplegado.
También exige una única dirección remota y que `X-SIHSALUS-Node-ID` coincida
exactamente con el UUID estable configurado para el ambiente. El runner solo
entrega ese UUID al host cuya MAC fue validada y el wrapper frontend lo hornea
en la imagen local. Esto hace fallar la promoción
a QLTY si DEV alterna entre nodos o revisiones durante la ventana, en vez de
aceptar la primera respuesta saludable. El conteo, intervalo y timeout pueden
ajustarse con `EXTERNAL_VERIFY_SAMPLE_COUNT`,
`EXTERNAL_VERIFY_SAMPLE_INTERVAL_SECONDS` y
`EXTERNAL_VERIFY_CURL_TIMEOUT_SECONDS`; producción siempre debe conservar al
menos dos muestras.

Antes de subir, iniciar, monitorear o cancelar un despliegue remoto,
`run-redeploy-remote.sh` exige y valida la MAC física esperada. Los workflows
fijan la pareja MAC/UUID de DEV y QLTY; una VM clonada que comparta IP y claves
SSH no puede recibir el script ni ejecutar Docker, y tampoco puede aprobar la
verificación HTTP con otra identidad. La MAC se comprueba dentro de cada
conexión SSH porque un preflight separado no protege la siguiente conexión.

El sondeo es una defensa probabilística: una réplica que no reciba ninguna de
las conexiones dentro de la ventana todavía puede escapar. La corrección
definitiva de direcciones duplicadas y VMs clonadas sigue correspondiendo a la
infraestructura o al hipervisor.

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

Antes de consultar o modificar contenedores, el script rechaza cambios locales
en archivos versionados y muestra únicamente su estado y ruta. La salida no
muestra el contenido del archivo. Un ajuste operativo que deba persistir se
incorpora mediante un pull request; no se mantiene como parche en el checkout
del servidor.

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
   `seed`; si existe drift, muestra únicamente el estado y la ruta de cada
   archivo para poder localizarlo sin volcar configuración ni secretos;
2. actualiza `main` únicamente mediante fast-forward;
3. descarga por digest la imagen solicitada del backend clásico
   `ghcr.io/sihsalus/sihsalus-backend`, construido desde `backend/pom.xml`, y
   valida que su revisión OCI coincida con el commit solicitado;
4. descarga las imágenes de registry de todos los perfiles activos;
5. si FUA ya está activo, prueba mediante una conexión autenticada que la
   identidad configurada todavía corresponde al rol almacenado en el volumen;
6. reconstruye sin caché y de forma secuencial los runtimes locales activos
   (`frontend`, `gateway`, `certbot` y/o `keycloak`) para limitar el consumo de
   CPU, memoria y red del host;
7. recrea todos los servicios activos, pero conserva volúmenes y datos;
8. espera MariaDB, frontend, OpenMRS y gateway, y verifica el estado de todos
   los servicios antes de declarar el ambiente usable;
9. solo entonces persiste en `.env` la referencia inmutable
   `sha-<commit>@sha256:<digest>` usada por el backend.

No ejecuta `docker compose down`, no usa `-v` y no elimina volúmenes. El
workflow manual `Redeploy Non-Production` solicita el SHA y digest del backend,
ejecuta primero DEV y solo promueve a QLTY si DEV y sus verificaciones HTTP
terminan correctamente. La conexión usa keepalive con tolerancia de diez
minutos y la espera de OpenMRS emite progreso periódico para tolerar arranques
largos.

El preflight FUA es deliberadamente de solo lectura: ejecuta `SELECT 1` con la
configuración renderizada y no crea usuarios, no ejecuta `ALTER ROLE` y no
modifica el volumen. `POSTGRES_PASSWORD` solo inicializa un volumen PostgreSQL
vacío; cambiar `SIHSALUS_FUA_GEN_DB_PASSWORD` en `.env` no rota el rol que ya
existe. Si ambas credenciales divergen, el despliegue se detiene antes de
recrear servicios y remite al procedimiento de recuperación del checklist de
operaciones. La conexión y la consulta tienen límites de tiempo y solo los
errores PostgreSQL de autenticación o identidad se diagnostican como drift de
credenciales; un error transitorio también detiene el redeploy antes de recrear
servicios y exige verificar conectividad y salud autenticada.
Si la sonda aislada no puede arrancar, el despliegue también se detiene cuando
ya existe un volumen FUA; no se recrean servicios sobre una verificación
inconclusa.
En una primera instalación sin volumen ni contenedor FUA, la sonda aislada se
omite y la autenticación queda a cargo del healthcheck durante el arranque. Si
el volumen ya existe pero el contenedor está ausente o detenido, el redeploy
falla cerrado para no convertir un estado de recuperación en una recreación
general del ambiente.

Si un establecimiento está temporalmente sin DNS o salida a Internet, se puede
usar `REDEPLOY_OFFLINE=true` únicamente después de transferir y verificar el
checkout y todas las imágenes runtime deseadas. Ese modo omite `git fetch`, los
pulls y los builds; recrea los servicios exclusivamente con las imágenes
prevalidadas que ya estén presentes. También exige el SHA y digest del backend;
la referencia por digest debe haberse descargado explícitamente o transferido
con sus metadatos de `RepoDigest`. La referencia solo se persiste después de
completar las verificaciones.
