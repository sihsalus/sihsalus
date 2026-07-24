# Checklist de despliegue SIHSalus

Usar este checklist para cambios en `main`, despliegues de `qlty`, `staging` o producción.

## Frontend automatizado en entornos no productivos

El workflow `Deploy Frontend` consulta cada cinco minutos la imagen `latest`
promovida por el release de `sihsalus-frontend`, resuelve y verifica su tag
inmutable, y despliega secuencialmente en DEV y QLTY. DEV funciona como canario:
si falla, QLTY no se modifica. Un fallo posterior a la actualización restaura
el tag y contenedor frontend anterior.

Cada servidor consume la imagen fuente mediante su digest `sha256`, reconstruye
el wrapper runtime y recrea únicamente `frontend` con `--no-deps --pull never`.
El despliegue no descarga, reconstruye ni recrea gateway, backend, bases de
datos u otros servicios; el único pull permitido es el digest inmutable de la
imagen fuente del frontend.

El workflow también acepta `repository_dispatch` de tipo `frontend-published` y
ejecución manual. Producción queda fuera de esta automatización y conserva el
checklist con aprobación explícita.

## Antes del despliegue

- PR aprobado y mergeado.
- CI requerido en verde.
- Versiones a desplegar identificadas: backend, frontend, content package y perfiles habilitados.
- Backup reciente confirmado.
- Ruta de rollback definida.
- Variables y secretos requeridos confirmados sin exponer valores.
- `COMPOSE_FILE` y `COMPOSE_PROFILES` reflejan el stack real del servidor.
- Si el entorno usa HTTPS, `COMPOSE_FILE` incluye `compose/ssl.yml` y `COMPOSE_PROFILES` incluye `ssl`.

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
