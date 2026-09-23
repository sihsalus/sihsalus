# Checklist de despliegue SIHSalus

Usar este checklist para cambios en `main`, despliegues de `qlty`, `staging` o producción.

## Frontend automatizado en entornos no productivos

El release de `sihsalus-frontend` publica un tag de señal
`frontend-release-<SHA>` mediante una deploy key limitada a este repositorio. El
workflow `Deploy Frontend` resuelve y verifica la imagen inmutable y despliega
secuencialmente en DEV y QLTY. DEV funciona como canario: si falla, QLTY no se
modifica. Un fallo posterior a la actualización restaura el tag y contenedor
frontend anterior. Un sondeo de `latest` cada cinco minutos conserva una ruta de
respaldo si la señal inmediata no llega. La señal solo es aceptada cuando su SHA
y digest siguen correspondiendo a `latest`, por lo que la deploy key no puede
seleccionar otra versión.

Cada servidor consume la imagen fuente mediante su digest `sha256`, reconstruye
el wrapper runtime y recrea únicamente `frontend` con `--no-deps --pull never`.
El despliegue no descarga, reconstruye ni recrea gateway, backend, bases de
datos u otros servicios; el único pull permitido es el digest inmutable de la
imagen fuente del frontend.
Conserva el checkout instalado: una release que requiera cambiar el wrapper o
Compose debe pasar primero por el procedimiento coordinado de manifiestos.

El workflow también acepta `repository_dispatch` de tipo `frontend-published` y
ejecución manual. La deploy key de señal no contiene credenciales de los
servidores; esas permanecen exclusivamente en los entornos protegidos del
distro. Producción queda fuera de esta automatización y conserva el checklist
con aprobación explícita.

## Antes del despliegue

- PR aprobado y mergeado.
- CI requerido en verde.
- La versión de content y sus migraciones fueron probadas con el estado de
  entrada admitido. Los roles declarativos provienen de `sihsalus-content`;
  no mantener copias de permisos ni parches SQL por servidor.
- El modelo Compose efectivo conserva `OMRS_EXTRA_INITIALIZER_STARTUP_LOAD=fail_on_error`.
  Verificar el valor resultante `initializer.startup.load` en las propiedades de
  runtime y que no exista un `-Dinitializer.startup.load` en las opciones JVM
  del contenedor: una propiedad del sistema tiene precedencia sobre runtime.
  No imprimir archivos completos de propiedades o entorno que contengan secretos.
- Firma, inventario y evidencia vigente de la [política de imágenes](image-security.md)
  verificados para los digests que se desplegarán; no usar tags `candidate-*` como releases.
- Versiones a desplegar identificadas: backend, frontend, portal de ayuda, content package y perfiles habilitados.
- Backup reciente confirmado.
- Último workflow `Backup and restore drills` exitoso de `main` revisado; registrar enlace, SHA y fecha, o el pendiente explícito. El resultado del dump no sustituye el del restore físico. Ver [procedimiento y alcance](physical-backup-drill.md).
- Smoke de autenticación local y Keycloak revisado para el digest candidato; registrar enlace y resultado de ambas variantes. El control diario puede haber probado otro digest. Ver [alcance y ejecución](runtime-smoke.md).
- Ruta de rollback definida.
- Distinguir recuperación de imágenes y de base de datos. Volver a una imagen
  anterior no deshace migraciones SQL ya confirmadas; una consolidación de roles
  requiere el procedimiento coordinado de restauración del respaldo.
- Para releases coordinadas, manifiestos anterior y candidato revisados,
  imágenes conservadas y [procedimiento de aplicación/reversión](release-manifests.md)
  probado en QLTY; registrar sus IDs y checksums junto a la evidencia.
- Variables y secretos requeridos confirmados sin exponer valores.
- `COMPOSE_FILE` y `COMPOSE_PROFILES` reflejan el stack real del servidor.
- Si el entorno usa HTTPS, `COMPOSE_FILE` incluye `compose/ssl.yml` y `COMPOSE_PROFILES` incluye `ssl`.
- El checkout del servidor no contiene parches en archivos versionados; todo
  ajuste permanente tiene un pull request revisado.
- Para una actualización individual, el checkout corresponde a la configuración
  instalada y es compatible con la imagen candidata. No actualizar Git durante
  el intento ni como paso automático previo a ese rollback.

## Ejecución

```bash
./scripts/security-audit.sh .env
./scripts/validate-compose.sh
docker compose config --quiet
docker compose ps
```

Elegir el comando de aplicación en la [guía de despliegue](../../scripts/deploy/README.md).
Los cambios de commit/configuración se preparan con el procedimiento coordinado;
el script individual mantiene el checkout actual. Si se usa otro archivo de
entorno, emplear ese mismo archivo al auditar y seleccionar Compose.

Si el servidor todavía no usa selección persistente, pasa los overrides en cada comando. Ejemplo HTTPS:

```bash
docker compose -f docker-compose.yml -f compose/ssl.yml --profile ssl config --quiet
docker compose -f docker-compose.yml -f compose/ssl.yml --profile ssl ps
```

### Credenciales del PostgreSQL de FUA

La imagen oficial de PostgreSQL usa `POSTGRES_USER`, `POSTGRES_PASSWORD` y
`POSTGRES_DB` solamente al inicializar un volumen vacío. Editar
`SIHSALUS_FUA_GEN_DB_PASSWORD` en `.env` y recrear el contenedor no cambia la
contraseña del rol almacenado en `db-fua-generator`.

El redeploy integral comprueba la identidad FUA configurada con una consulta
autenticada antes de recrear servicios. Una instalación realmente nueva se
reconoce porque todavía no existen ni el volumen ni el contenedor. Si el
volumen ya existe pero el contenedor está ausente o detenido, el proceso se
detiene y exige recuperar primero la base de datos. Si la comprobación de
identidad falla:

Si la sonda no puede concluir por red o timeout, el redeploy también se detiene
antes de recrear servicios; primero restablece la conectividad y confirma el
healthcheck autenticado.

1. No ejecutes `docker compose down -v`, `docker volume rm` ni recrees el
   volumen; contiene datos persistentes.
2. Restaura temporalmente en `.env` la última credencial que autenticaba y
   confirma que el servicio vuelve a estar sano.
3. Obtén y verifica un backup antes de cambiar el rol.
4. Rota la contraseña dentro de PostgreSQL durante una ventana auditada, usando
   un canal que no incluya el secreto en argumentos, historial ni logs.
5. Actualiza `.env` con la misma credencial, ejecuta nuevamente el preflight y
   verifica FUA de extremo a extremo.

La automatización no intenta adivinar cuál contraseña es la correcta ni ejecuta
`ALTER ROLE`: una rotación silenciosa podría bloquear al generador o separar la
fuente de verdad del volumen persistente.

Registrar:

| Campo | Valor |
| --- | --- |
| Fecha/hora | |
| Responsable | |
| Ambiente | |
| Commit desplegado | |
| Backend tag | |
| Frontend tag | |
| Portal de ayuda image/digest | |
| Content package | |
| Perfiles activos | |
| Backup usado como referencia | |
| Simulacro físico exitoso: URL, SHA y fecha | |
| Plan de rollback | |

## Smoke test posterior

Antes de activar el frontend nuevo, verificar en el intento actual de arranque
que Initializer terminó sin errores ni cargas abortadas. Comparar el historial
de migraciones y la política final del rol canónico con el artefacto elegido,
incluidas las asignaciones y referencias conservadas. Para llegadas no SIS,
exigir el atributo Visit `090eb9b3-a306-450f-8623-9fc00b8d82fa` activo, datatype
`org.openmrs.customdatatype.datatype.FreeTextDatatype`, cardinalidad `0..1`.
Si falla cualquiera de estos controles, detener la promoción y ejecutar la
recuperación prevista; no insertar metadata suelta ni borrar checksums para
forzar un resultado saludable. Este control complementa la salud HTTP.

Para confianza del certificado y diagnóstico HTTPS, usar el
[runbook HTTPS](https.md#confianza-y-diagnóstico).

- `GET /health` responde correctamente.
- `GET /startup` responde correctamente.
- `GET /ready` responde correctamente cuando OpenMRS termina bootstrap.
- `/openmrs/spa/home` carga en navegador.
- `/ayuda/` carga la versión esperada o, si el servicio está detenido, devuelve
  su contingencia sin afectar `/health`, `/ready` ni la SPA.
- Login funciona.
- Roles principales pueden acceder a sus superficies esperadas.
- Si aplica, Keycloak redirige a `/openmrs/spa/home`.
- Si aplica, FUA responde bajo su ruta de gateway.
- Si aplica, indicadores responde bajo `/openmrs/services/reportes-sql`.
- Si aplica, Imaging rechaza anónimos, acepta solo `imaging-access`, carga OHIF/DICOMweb y `/imaging/logout` exige un nuevo login.
- Logs de `gateway` y `backend` sin errores nuevos críticos.

## Cierre

- Resultado documentado.
- Incidentes o degradaciones registradas.
- Rollback ejecutado o descartado explícitamente.
- Evidencia de CI y smoke test adjuntada al cambio o bitácora operativa.
