# Checklist de despliegue SIHSalus

Usar este checklist para cambios en `main`, despliegues de `qlty`, `staging` o producción.

## Antes del despliegue

- PR aprobado y mergeado.
- CI requerido en verde.
- Versiones a desplegar identificadas: backend, frontend, content package y perfiles habilitados.
- Backup reciente confirmado.
- Ruta de rollback definida.
- Variables y secretos requeridos confirmados sin exponer valores.
- Si el entorno usa HTTPS, todos los comandos Compose incluyen `-f compose/ssl.yml --profile ssl`.

## Ejecución

```bash
git pull --ff-only
docker compose config --quiet
docker compose ps
```

Para entornos HTTPS:

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
- Si aplica, imaging/OHIF no muestra errores de gateway/CSP.
- Logs de `gateway` y `backend` sin errores nuevos críticos.

## Cierre

- Resultado documentado.
- Incidentes o degradaciones registradas.
- Rollback ejecutado o descartado explícitamente.
- Evidencia de CI y smoke test adjuntada al cambio o bitácora operativa.
