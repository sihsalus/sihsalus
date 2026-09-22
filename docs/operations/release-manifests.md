# Releases inmutables por nodo

`scripts/deploy/release-manifest.py` captura y consume las mismas referencias
para despliegue y rollback. Reutiliza `redeploy-environment.sh` en modo offline:
conserva la sonda autenticada de FUA, la espera de OpenMRS y los healthchecks de
todos los servicios. No descarga ni construye imágenes durante la aplicación.

El manifiesto fija el commit del distro, commit/digest de las fuentes backend y
frontend, versión del content package, plataforma, identidad del nodo, selección
Compose y **cada servicio habilitado**, incluidos los opcionales. Los wrappers
construidos localmente, como frontend y gateway, se identifican por su ID SHA-256
real. El digest de la fuente frontend por sí solo no identifica ese wrapper.

## Preparar y revisar

1. Completar el [checklist de despliegue](deploy-checklist.md): PR aprobado y
   mergeado, CI verde, backup verificado, credenciales vigentes y ruta de
   recuperación. Mantener pausadas las automatizaciones individuales durante
   la transición a manifiestos. Producción conserva su aprobación explícita.
2. Usar Python 3.9 o posterior, Git y Docker Compose v2. El daemon debe estar
   disponible y corresponder al nodo esperado. Las operaciones remotas conservan
   la verificación MAC/UUID del runbook; el manifiesto no sustituye ese control.
3. Preparar primero QLTY. Capturar la versión anterior antes de reemplazar sus
   imágenes; conservar también las fuentes backend/frontend por digest. La
   captura inspecciona imágenes y crea contenedores detenidos, sin red ni
   volúmenes del host, para leer metadatos empaquetados; nunca arranca OpenMRS.
   Esos contenedores y sus volúmenes anónimos se eliminan al terminar la lectura.
4. Preparar un JSON de metadatos con esta estructura. Los valores entre `<...>`
   son marcadores que deben sustituirse por datos verificados, no una release:

   ```json
   {
     "schemaVersion": 1,
     "releaseId": "<identificador-nuevo>",
     "createdAt": "<YYYY-MM-DDTHH:MM:SSZ>",
     "target": {"environment": "qlty", "nodeId": "<UUID-del-nodo>"},
     "compose": {
       "project": "sihsalus",
       "files": ["docker-compose.yml", "compose/keycloak.yml", "compose/ssl.yml"],
       "profiles": ["keycloak", "ssl", "fua"],
       "platform": "linux/amd64"
     },
     "sources": {
       "distroCommit": "<SHA-completo-del-checkout>",
       "contentVersion": "<version-publicada>",
       "backend": {
         "commit": "<SHA-backend>",
         "image": "ghcr.io/sihsalus/sihsalus-backend:sha-<SHA-backend>@sha256:<digest>"
       },
       "frontend": {
         "commit": "<SHA-frontend>",
         "image": "ghcr.io/sihsalus/sihsalus-frontend:sha-<SHA-frontend>@sha256:<digest>"
       }
     }
   }
   ```

   `compose.project`, archivos y perfiles deben coincidir con la instalación
   real. La captura falla si falta un servicio o hay contenedores ajenos,
   escalados o de una operación Compose pendiente. No incorpora `seed`.

   ```bash
   python3 scripts/deploy/release-manifest.py capture /ruta/metadata.json \
     --root /srv/sihsalus --env-file /srv/sihsalus/.env \
     --output /ruta/qlty-anterior.json
   python3 scripts/deploy/release-manifest.py validate /ruta/qlty-anterior.json
   ```

5. Preparar las imágenes candidatas por digest mediante el flujo de construcción
   y validación existente. Construir el wrapper con el UUID del nodo destino;
   verificar el candidato primero en QLTY. Un manifiesto capturado en QLTY **no
   puede aplicarse a otro nodo**. Para producción se prepara otro manifiesto con
   su UUID y sus IDs de wrappers; los commits y digests de las fuentes verificadas
   deben corresponder a la promoción revisada. Se puede preparar el manifiesto
   candidato desde el anterior sustituyendo explícitamente las referencias y
   metadatos revisados; `deploy` comprobará sus bytes antes de recrear servicios.
6. Incorporar cada JSON, anterior y candidato, a `releases/<environment>/<nodeId>/`
   mediante PR. El commit `distroCommit` describe el código que se ejecutará,
   anterior al commit que publica el JSON; no debe intentarse una referencia
   circular al commit que contiene el propio manifiesto.

## Aplicar y revertir

Preparar un checkout limpio del `distroCommit` solicitado y todas las imágenes
locales del candidato **y** del anterior, incluidos los digests fuente. En `.env`
debe existir exactamente un `DEPLOYMENT_ENV` que coincida con el manifiesto. La
identidad se contrasta además con la etiqueta del frontend ya instalado. Esta
ruta actualiza instalaciones existentes; bootstrap, cambio de perfiles,
proyecto, plataforma o volúmenes requiere un procedimiento separado.

Ejecutar la herramienta desde una revisión aprobada que ya la incluya. `--root`
permite apuntar a un checkout más antiguo durante una reversión:

```bash
python3 /ruta/herramienta-revisada/scripts/deploy/release-manifest.py deploy \
  /ruta/candidato.json --previous /ruta/anterior.json --root /srv/sihsalus

# Preparar antes /srv/sihsalus en el distroCommit de anterior.json.
python3 /ruta/herramienta-revisada/scripts/deploy/release-manifest.py rollback \
  /ruta/anterior.json --previous /ruta/candidato.json --root /srv/sihsalus
```

Ambos comandos usan el mismo formato y camino de ejecución. `deploy` exige que
el runtime actual coincida con `--previous`. `rollback` admite un runtime
parcialmente actualizado, incluso contenedores ausentes, pero rechaza servicios
ajenos. Si falta el frontend, exige la identidad y el manifiesto conservados
localmente antes del intento. No exige recuperar imágenes perdidas del candidato
fallido para volver a una release anterior cuyas imágenes estén completas.
La sonda FUA conserva sus propios requisitos de recuperación del volumen/base.
Ninguno ejecuta un checkout Git automático, restaura bases de datos ni revierte
migraciones. La compatibilidad del esquema y el backup siguen siendo parte de
la decisión de reversión.

Antes de recrear servicios se verifican IDs y plataformas de todas las imágenes,
revisiones OCI fuente, `build-info.json` del wrapper y
`content.sihsalus-content` del backend empaquetado. El comando guarda ambos
manifiestos y overrides de imágenes dentro de `.env.release-state/`, protegido e
ignorado por Git, y conserva tags `sihsalus-release-retained:*` para esas imágenes.
No podar esas imágenes mientras siga vigente la ventana de recuperación. Para
recuperación ante pérdida del disco también se necesitan los backups y archivos
de imágenes locales; un ID local no puede descargarse de un registry.

La selección completa queda persistida en `.env`: archivos/perfiles Compose,
proyecto, plataforma, nodo y manifiesto. El helper de los scripts individuales
rechaza esos hosts para impedir que una actualización frontend o backend altere
una sola parte de la release o borre sus imágenes de recuperación. Toda nueva
actualización del host debe pasar por un manifiesto revisado. No quitar el
marcador `SIHSALUS_RELEASE_MANIFEST` para eludir este flujo.
Las rutas del checkout y de los artefactos deben carecer de espacios y caracteres
de shell, para mantener la selección compatible con los lectores `.env` existentes.
`security-audit.sh` contrasta la selección efectiva de Compose con el manifiesto;
un marcador válido no permite ocultar imágenes o perfiles distintos.

Cada intento tiene un directorio privado con `before.env`, `previous.json`,
`target.json` y `result.json`. Si falla, conserva la selección intentada y marca
el resultado como `failed-or-interrupted`; no declara éxito ni restaura solo
`.env` mientras los contenedores podrían haber cambiado parcialmente. Revisar
ese journal y aplicar el manifiesto anterior con `rollback`. El archivo
`before.env` contiene secretos: no adjuntarlo a un issue, PR o artefacto de CI.
Una interrupción no capturable, como pérdida de energía o `SIGKILL`, puede dejar
el estado `applying`; también requiere inspección y recuperación explícita.

Después de los healthchecks reutilizados, se verifican los IDs reales de todos
los contenedores. Completar el smoke clínico y la verificación HTTP externa del
checklist antes de promover. Un resultado `verified` de esta herramienta cubre
identidad, versiones y salud técnica; no sustituye la aceptación clínica.

## Validación y publicación

```bash
python3 -B -m unittest discover -s tests/deploy -p test_release_manifest.py -v
python3 -B tests/deploy/release-manifest-compose.py --catalog
python3 -B scripts/deploy/release-manifest.py catalog --base <SHA-base-del-PR>
```

Las pruebas locales usan un Docker simulado para las mutaciones y Compose real
sin daemon para comprobar los perfiles. CI también valida el Compose de cada
commit referenciado por un manifiesto publicado, con credenciales sintéticas.
Una prueba adicional de CI construye imágenes `scratch` con un binario mínimo,
sin descargas, para comprobar la lectura de metadatos y una secuencia real de
actualización/reversión por ID local. No arranca OpenMRS ni prueba un flujo clínico.
El workflow publica el catálogo y sus checksums solo después de integrar en
`main`; el historial versionado preserva los manifiestos anteriores sin límite
de retención de Actions. No se generan manifiestos reales a partir de los datos
sintéticos de las pruebas.
