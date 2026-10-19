# Despliegue y versiones

Ejecutar desde el checkout instalado, con su `.env`. La selección de servicios,
imágenes inmutables e historial la mantiene la herramienta en el propio servidor.
No se crean releases de GitHub por ambiente ni se editan manifiestos a mano.

```bash
python3 scripts/deploy/deploy.py status
python3 scripts/deploy/deploy.py update --frontend latest
python3 scripts/deploy/deploy.py history
python3 scripts/deploy/deploy.py rollback
```

`latest` significa la última imagen **publicada**, no un candidato de CI. También
se acepta el SHA completo de una versión publicada. El digest se resuelve una
sola vez y se conserva internamente. `--digest` permite fijarlo adicionalmente en
automatizaciones. `--prepare` prepara y verifica sin recrear servicios.

Configurar `SIHSALUS_PUBLIC_URL=https://servidor` en `.env` una vez, o pasar `--url`.
Esto incorpora las comprobaciones HTTP externas al resultado de la operación.
Sin URL, se verifican las imágenes, identidad y salud internas; el resultado no
acredita acceso desde fuera del host.

## Qué ocurre al actualizar

1. Comprueba checkout limpio, selección real de Compose, ambiente, UUID y versión
   instalada. Un cambio de herramientas operativas es compatible si los archivos
   que definen el runtime siguen idénticos. Un cambio de Compose exige una
   intervención coordinada, no una actualización individual.
2. Verifica las imágenes de recuperación y la salud del componente actual.
3. Resuelve la versión publicada por digest. Para frontend construye únicamente
   su wrapper con la configuración y UUID del servidor, sin modificar `.env` aún.
4. Guarda automáticamente las versiones anterior y candidata y un registro
   privado del intento. Conserva las imágenes anteriores.
5. Usa Docker Compose `up --no-deps --no-build --pull never --wait` exclusivamente
   sobre el componente elegido. Actualizar frontend no reinicia OpenMRS, MariaDB,
   PostgreSQL, gateway ni servicios opcionales.
6. Comprueba imágenes reales, selección persistida, salud y, con URL configurada,
   acceso externo. Si falla el frontend después de empezar, recupera su imagen
   anterior y conserva la evidencia del fallo. El comando devuelve error incluso
   si recuperó correctamente.

Después de una recuperación por fallo, `rollback` no vuelve a instalar el
candidato fallido. Para reintentarlo se elige su versión explícitamente.

Dos actualizaciones no pueden ejecutarse simultáneamente. Interrumpir un proceso
con SIGKILL o perder energía puede dejar una operación pendiente: consultar
`status` e `history` y ejecutar `rollback` si corresponde. Nunca borrar el estado
privado para forzar una actualización.

La limpieza queda fuera del despliegue. El cron local conserva al menos dos
versiones y tres días, además de imágenes en uso, candidatas y recuperación.
No se ejecuta `docker image prune`, no se eliminan volúmenes y no se necesitan
commits ni PR por cada tarea de mantenimiento local.

## Backend y content

```bash
python3 scripts/deploy/deploy.py update --backend VERSION
```

Actualiza solo backend; content viaja dentro de esa imagen y su versión se lee
del artefacto. Antes, confirmar respaldo comprobado, compatibilidad de esquema
y aceptación del cambio. Si falla, conserva la evidencia y no revierte
automáticamente: una imagen anterior no deshace migraciones ya confirmadas.
`rollback` automático/manual está limitado al frontend. La recuperación de
backend y base de datos usa el [procedimiento de backups](../backup/README.md)
y una versión compatible elegida expresamente.

## GitHub Actions y conexión remota

**Deploy Frontend** pide una versión y resuelve su SHA/digest antes de acceder a
los hosts. Mantiene los environments `development` y `quality`, revisión humana
nativa, DEV como canario y QLTY solo después de sus comprobaciones.
La aprobación describe versión y ambiente; hashes y registros son evidencia
producida por la automatización, no archivos que el operador deba preparar.

`run-redeploy-remote.sh` conserva la ejecución desconectable, exclusión mutua,
registro de resultados y comprobación MAC en **cada** conexión SSH. Mantener las
identidades vigentes: DEV `00:0c:29:86:a3:3b` / UUID
`700e430a-1c32-5241-b7cf-78ccea17f8c1`; QLTY `00:0c:29:1c:f7:78` / UUID
`0cefb0c8-c860-48c5-856f-408594775cbb`. El antecedente de VMs clonadas es #243.
`verify-external-frontend.sh` comprueba 12 conexiones independientes, versión,
UUID, dirección remota y salud; una muestra HTTP no prueba aceptación clínica.

Los scripts `deploy-frontend.sh` y `deploy-backend.sh` permanecen como entradas
compatibles y delegan en la misma implementación. No mantienen flujos separados.

## Instalaciones existentes y cambios coordinados

La herramienta reconoce el estado local anterior directamente. Para una
instalación Compose sin historial, captura las imágenes reales, sus revisiones,
content, perfiles y nodo antes de la primera actualización. No cambia datos,
perfiles ni nombres de proyecto. La adopción se detiene ante información
incompleta o imágenes fuente que no se puedan verificar.

El [motor de recuperación](../../docs/operations/release-manifests.md) mantiene
compatibilidad con registros históricos y operaciones coordinadas de Compose.
Es una interfaz interna para recuperación avanzada, no un paso de la operación
cotidiana. Una migración de perfiles, volúmenes o configuración tiene su propia
revisión, respaldo y pruebas; `redeploy-environment.sh` no es el camino normal
para actualizar versiones.

Producción no se actualiza junto con DEV/QLTY. Su adopción y actualización requieren
la ventana y autorización correspondientes.

## Nombres de contenedores y volúmenes

Los archivos Compose no fijan `container_name`. Cada contenedor se llama
`<proyecto>-<servicio>-1` y el DNS interno sigue siendo el nombre del servicio.
Para operar uno, resolverlo por servicio desde el checkout con su `.env`:

```bash
docker compose ps -q backend
```

`scripts/lib/compose-container.sh` ofrece `compose_container <servicio> [directorio]`
y `require_compose_container <servicio> [directorio]` para scripts. Los cron y
comandos manuales que usaban `docker exec sihsalus-db-master` deben pasar a esta
resolución; los scripts de backup la hacen solos desde su propio checkout,
también cuando cron los inicia desde otro directorio.

Los volúmenes con nombre siguen `${COMPOSE_PROJECT_NAME:-sihsalus}-<clave>` y los
demás `<proyecto>_<clave>`. Compose interpola `COMPOSE_PROJECT_NAME` con el nombre
efectivo del proyecto (`-p`, variable de entorno, `.env` o, en su defecto, el
directorio del checkout), así que el valor que importa es
`docker compose config --format json | jq -r .name`. Con `sihsalus` los nombres
son idénticos a los históricos y no hay nada que migrar. `.env.template` fija
`COMPOSE_PROJECT_NAME=sihsalus` para que el nombre no dependa del directorio.

### Primer despliegue sin `container_name`

Antes de desplegar este cambio en cualquier host:

1. Confirmar que `docker compose config --format json | jq -r .name` imprime
   `sihsalus`. Si no, añadir `COMPOSE_PROJECT_NAME=sihsalus` a `.env` (conserva
   los nombres históricos) o completar primero la migración de abajo.
   `redeploy-environment.sh` lo comprueba antes de `docker compose up`
   (`preflight_named_volumes`) y aborta si algún volumen histórico quedaría
   huérfano; `sihsalus-compose.service` no tiene esa comprobación.
2. Auditar las tareas programadas: `sudo crontab -l; grep -R 'sihsalus-' /etc/cron*`.
   Las entradas con `docker exec sihsalus-db-master` u otro nombre fijo deben
   resolver el servicio con `docker compose ps -q <servicio>` desde el checkout;
   las que invocan `scripts/backup/*.sh` no necesitan cambios ni `cd`.
3. Planificar una ventana de reinicio completo: al desaparecer `container_name`
   cambia la configuración de todos los servicios, así que el primer
   `docker compose up` (arranque de `sihsalus-compose.service` o
   `redeploy-environment.sh`) recrea todos los contenedores a la vez, incluidos
   `db`, `keycloak-db` y la monitorización, no solo los que cambiaron de imagen.
   Los datos en volúmenes se conservan y `docker compose ps` muestra después los
   nombres `sihsalus-<servicio>-1`.

### Migrar un host a otro nombre de proyecto

Omitir la copia crea volúmenes vacíos en silencio: la base de Keycloak, los
certificados de Let's Encrypt y el historial de Grafana/Prometheus/Loki
aparecerían en blanco. Los volúmenes sin `name` (`db-data`, `openmrs-data`,
`db-fua-generator`, etc.) también cambian de `sihsalus_<clave>` a
`<proyecto>_<clave>` y requieren el mismo tratamiento.

1. Backup verificado (dump y backup físico restaurados en un ambiente aislado).
2. `docker compose down` sin `-v`, con la selección real de `COMPOSE_FILE` y
   `COMPOSE_PROFILES`.
3. Definir `COMPOSE_PROJECT_NAME=<proyecto>` en `.env` y renderizar
   `docker compose config --format json | jq '.volumes[].name'` para obtener
   los nombres nuevos. En un host gestionado por manifiestos
   (`SIHSALUS_RELEASE_MANIFEST` en `.env`) este paso no basta: `deploy.py`
   reescribe `COMPOSE_PROJECT_NAME` desde el manifiesto en cada despliegue y
   rechaza el cambio de proyecto por diseño (`verify_transition`,
   "Compose project differs from manifest"). Renombrar uno de esos hosts exige
   volver a adoptar la instalación con un procedimiento revisado aparte; este
   runbook cubre solo hosts sin manifiesto retenido.
4. Para cada volumen con nombre (misma clave, cambia el prefijo):

   | Clave | Anterior | Nuevo |
   | --- | --- | --- |
   | `orthanc-data` | `sihsalus-orthanc-data` | `<proyecto>-orthanc-data` |
   | `prometheus-data` | `sihsalus-prometheus-data` | `<proyecto>-prometheus-data` |
   | `alertmanager-data` | `sihsalus-alertmanager-data` | `<proyecto>-alertmanager-data` |
   | `operations-metrics` | `sihsalus-operations-metrics` | `<proyecto>-operations-metrics` |
   | `loki-data` | `sihsalus-loki-data` | `<proyecto>-loki-data` |
   | `alloy-data` | `sihsalus-alloy-data` | `<proyecto>-alloy-data` |
   | `grafana-data` | `sihsalus-grafana-data` | `<proyecto>-grafana-data` |
   | `keycloak-data` | `sihsalus-keycloak-data` | `<proyecto>-keycloak-data` |
   | `letsencrypt-data` | `sihsalus-letsencrypt-data` | `<proyecto>-letsencrypt-data` |
   | `certbot-data` | `sihsalus-certbot-data` | `<proyecto>-certbot-data` |
   | `gatus-data` | `sihsalus-gatus-data` | `<proyecto>-gatus-data` |

   ```bash
   docker volume create \
     --label com.docker.compose.project=<proyecto> \
     --label com.docker.compose.volume=<clave> NEW
   docker run --rm -v OLD:/src:ro -v NEW:/dst alpine cp -a /src/. /dst/
   docker run --rm -v OLD:/src:ro -v NEW:/dst:ro alpine sh -c 'du -s /src /dst'
   ```

   Las etiquetas hacen que Compose reconozca el volumen como propio; sin ellas
   cada `docker compose up` avisa `volume "NEW" already exists but was not
   created by Docker Compose`, un aviso inofensivo que no impide reutilizarlo.

5. `docker compose up -d` y aceptación funcional (login, Keycloak, HTTPS,
   Grafana con historial).
6. Eliminar los volúmenes `OLD` solo después de la aceptación.
