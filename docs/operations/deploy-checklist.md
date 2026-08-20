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

El workflow también acepta `repository_dispatch` de tipo `frontend-published` y
ejecución manual. La deploy key de señal no contiene credenciales de los
servidores; esas permanecen exclusivamente en los entornos protegidos del
distro. Producción nunca recibe la señal automática: usa el workflow manual
`Promote Frontend to Production`, el entorno protegido `production` y el
[runbook específico](production-frontend-promotion.md). La ruta no queda
habilitada hasta configurar y verificar todas las identidades, secretos,
variables y revisores requeridos.

## Antes del despliegue

- PR aprobado y mergeado.
- CI requerido en verde.
- Versiones a desplegar identificadas: backend, frontend, content package y perfiles habilitados.
- Backup reciente confirmado.
- Ruta de rollback definida.
- Variables y secretos requeridos confirmados sin exponer valores.
- `COMPOSE_FILE` y `COMPOSE_PROFILES` reflejan el stack real del servidor.
- Si el entorno usa HTTPS, `COMPOSE_FILE` incluye `compose/ssl.yml` y `COMPOSE_PROFILES` incluye `ssl`.
- El checkout del servidor no contiene parches en archivos versionados; todo
  ajuste permanente tiene un pull request revisado.

## Ejecución

```bash
git pull --ff-only
./scripts/security-audit.sh .env.production
./scripts/validate-compose.sh
docker compose config --quiet
docker compose ps
```

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
| Content package | |
| Perfiles activos | |
| Backup usado como referencia | |
| Plan de rollback | |

## Smoke test posterior

- `GET /health` responde correctamente.
- `GET /startup` responde correctamente.
- `GET /ready` responde correctamente cuando OpenMRS termina bootstrap.
- `/openmrs/spa/home` carga en navegador.
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
