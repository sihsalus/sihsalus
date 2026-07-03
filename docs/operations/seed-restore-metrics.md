# Metricas de seed restore y arranque OpenMRS

Medicion tomada el 2026-07-03 en `gidis-dev` y comparada con arranques recientes de `gidis-qlty`.

## Baseline de contenido

- Artifact: `seed-content-6c25fe8-backend-d61608b-r2`
- Tamano descargado: 455 MB
- SHA256: `cbd4f984480ccac57b9fca0c913dd1fc797c7a45b4059ff6b3046d7eeffb620d`
- Conteos esperados despues del restore:
  - `concept`: 32376
  - `openconceptlab_item` mappings: 20003
  - OCL errors: 0
  - `patient`: 0
  - `obs`: 0
  - `encounter`: 0

## Tiempos medidos en dev

| Paso | Tiempo medido | Evidencia |
| --- | ---: | --- |
| Descargar artifact seed desde GitHub Releases | 22 s | `curl` dentro de `sihsalus-seed-1` |
| Restore completo de volumenes seed | 1 min 02 s | `StartedAt=2026-07-03T15:23:45Z`, `FinishedAt=2026-07-03T15:24:47Z` |
| Build backend local con cache Maven fria/parcial | aprox. 11-12 min | `dependency:resolve` 7m12s, `mvn install` 2m59s, export/capas aprox. 1m |
| Recreate backend despues del build | 10-15 s | Compose recreo `sihsalus-backend` y arranco contenedor |
| Startup backend/OpenMRS hasta Tomcat listo | 11 min 34 s | `StartedAt=2026-07-03T15:48:36Z`, `Server startup=2026-07-03T16:00:10Z` |
| `Refreshing Context` de OpenMRS | 7 min 59 s | `15:50:03Z` a `15:58:02Z` |
| Validacion final backend | 200 | `GET /openmrs/health/started` |

## Comparacion QLTY

Arranques recientes con contenido cargado:

| Ambiente | Refresh context | Tomcat startup total |
| --- | ---: | ---: |
| QLTY | 7 min 26 s | 10 min 42 s |
| QLTY | 8 min 04 s | 12 min 02 s |
| DEV | 7 min 59 s | 11 min 34 s |

## Regla operativa

- Seed restore desde artifact debe tomar alrededor de 1-2 minutos con red normal.
- Backend/OpenMRS puede tardar 10-12 minutos en quedar `healthy` despues de recrear imagen o contenedor.
- Durante el arranque es normal ver CPU alta y el ultimo log en `Refreshing Context`.
- No reiniciar si el proceso sigue consumiendo CPU y no hay stacktrace nuevo; reiniciar solo vuelve a empezar el warmup.
- Investigar si pasan mas de 15 minutos sin `Server startup`, si CPU cae a casi 0 sin health `200`, o si aparecen errores repetidos de Spring/beans en logs.

## Comandos rapidos

```bash
docker ps --format "table {{.Names}}\t{{.Status}}"
docker logs --tail 120 sihsalus-backend
docker exec sihsalus-backend curl --max-time 10 -sS -o /dev/null -w "BACKEND=%{http_code}\n" http://localhost:8080/openmrs/health/started
docker exec sihsalus-db-master sh -lc 'mariadb --user="$MYSQL_USER" --password="$MYSQL_PASSWORD" openmrs -N -e "SELECT COUNT(*) FROM concept; SELECT COUNT(*) FROM openconceptlab_item WHERE type=CHAR(77,65,80,80,73,78,71); SELECT COUNT(*) FROM openconceptlab_item WHERE error_message IS NOT NULL AND LENGTH(error_message)>0; SELECT COUNT(*) FROM patient; SELECT COUNT(*) FROM obs; SELECT COUNT(*) FROM encounter;"'
```
