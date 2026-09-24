# Manifiestos de despliegue como artefactos

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

1. Completar el [checklist de despliegue](deploy-checklist.md): PR del código aprobado y
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
6. Conservar cada JSON fuera del checkout y publicarlo como archivo adjunto a
   una GitHub Release inmutable, según el procedimiento de abajo. El código y
   las plantillas reutilizables se revisan por PR; un despliegue no añade carpetas
   por ambiente/UUID ni commits de estado operativo. `distroCommit` identifica
   el código ejecutado y también el destino del tag de la release.

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

El repositorio conserva el código de captura, validación y rollback. Los JSON
reales se guardan como assets de GitHub Releases; `.env.release-state/` sigue
reteniendo la selección y el journal privados del servidor. Publicar un registro
no ejecuta un despliegue ni acredita aceptación clínica.

Usar la inmutabilidad nativa de GitHub, ya habilitada en este repositorio. Una
release publicada protege su tag y assets y ofrece una atestación verificable;
los artefactos temporales de Actions no son el archivo de recuperación. No usar
`--clobber`, mover tags ni sobrescribir registros: una corrección crea otra release.
Ver [releases inmutables de GitHub](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases).

Preparar únicamente el manifiesto revisado y su checksum en un directorio fuera
del repositorio. No adjuntar `.env`, journals, configuraciones renderizadas,
respaldos, credenciales ni datos clínicos. Los permisos de publicación existentes
de GitHub se mantienen; CI solo necesita lectura.

```bash
artifact_dir="$(mktemp -d)"
cp /ruta/candidato.json "$artifact_dir/release-manifest.json"
python3 -B scripts/deploy/release-manifest.py validate "$artifact_dir/release-manifest.json"
release_tag="deployment-$(jq -r .releaseId "$artifact_dir/release-manifest.json")"
distro_commit="$(jq -r .sources.distroCommit "$artifact_dir/release-manifest.json")"
(cd "$artifact_dir" && sha256sum release-manifest.json > SHA256SUMS)

gh release create "$release_tag" "$artifact_dir/release-manifest.json" \
  "$artifact_dir/SHA256SUMS" --repo sihsalus/sihsalus --draft \
  --target "$distro_commit" --latest=false --notes-file /ruta/revision.md
```

Revisar los archivos, imágenes, evidencia de CI y rollback en el borrador antes
de publicarlo. La publicación conserva los bytes revisados como evidencia;
la aplicación al servidor requiere además la validación del artefacto:

```bash
gh release edit "$release_tag" --repo sihsalus/sihsalus --draft=false --latest=false
gh release verify-asset "$release_tag" "$artifact_dir/release-manifest.json" --repo sihsalus/sihsalus
gh workflow run release-manifests.yml --repo sihsalus/sihsalus --ref main \
  -f release_tag="$release_tag"
```

El workflow `Release manifests` exige una release publicada e inmutable, verifica
la atestación del archivo, su esquema, la coincidencia tag/identificador/commit,
que el commit sea parte del historial revisado y la cobertura de su Compose real.
Conservar el enlace al run aprobado junto a la revisión operativa. Un fallo
bloquea la aplicación; publicar el asset por sí solo no autoriza el despliegue.
Las comprobaciones sintéticas de perfiles, selección persistente, auditoría y
metadatos de imágenes continúan ejecutándose en cada PR sin manifiestos reales.

Para recuperar un manifiesto publicado en un directorio nuevo fuera del checkout:

```bash
gh release download "$release_tag" --repo sihsalus/sihsalus \
  --pattern release-manifest.json --pattern SHA256SUMS --dir /ruta/recuperacion
gh release verify-asset "$release_tag" /ruta/recuperacion/release-manifest.json \
  --repo sihsalus/sihsalus
(cd /ruta/recuperacion && sha256sum --check SHA256SUMS)
python3 -B scripts/deploy/release-manifest.py validate /ruta/recuperacion/release-manifest.json
```

Pasar ese archivo a `deploy` o `rollback` con los controles descritos arriba.
El traslado del catálogo histórico a assets conserva sus bytes y no cambia la
selección activa, imágenes, volúmenes ni copias de recuperación del servidor.
El historial Git anterior permanece disponible, sin reescribir commits.

Pruebas locales sin Docker:

```bash
python3 -B -m unittest discover -s tests/deploy -p 'test_release*.py' -v
bash tests/run.sh
```

En un runner con Compose disponible, la verificación de un archivo externo puede
repetirse con `python3 -B tests/deploy/release-manifest-compose.py --manifest /ruta/release-manifest.json`.
