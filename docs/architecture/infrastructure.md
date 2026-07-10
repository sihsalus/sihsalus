# Arquitectura de infraestructura

SIH Salus usa Docker Compose como orquestador de un único host. El diseño prioriza despliegues reproducibles, operación offline y una ruta clara desde desarrollo hasta establecimientos con HTTPS y servicios opcionales.

## Límites del sistema

| Límite | Componentes | Responsabilidad |
| --- | --- | --- |
| Entrada | `gateway`, `certbot` | HTTP/HTTPS, CSP, proxy y certificados |
| Aplicación clínica | `frontend`, `backend`, `db` | SPA OpenMRS, API y datos clínicos |
| Identidad | `keycloak`, `keycloak-db` | OIDC opcional; no reemplaza roles de OpenMRS |
| Interoperabilidad | `hapi-fhir`, `fua-generator`, `reportes-sql` | Integraciones y reportes con bases separadas |
| Imágenes | `ohif`, `orthanc`, `orthanc-proxy` | Visualización y almacenamiento DICOM |
| Operación | `grafana`, `prometheus`, `loki`, `alloy`, `gatus` | Métricas, logs y estado local sin datos clínicos |

Los servicios se descubren por el DNS de Compose. No se fijan subredes ni direcciones de contenedor porque eso crea conflictos con redes hospitalarias y no aporta estabilidad.

## Composición

```text
docker-compose.yml
  + include: core y módulos que solo agregan servicios
  + override opcional: compose/keycloak.yml
  + override opcional: compose/ssl.yml
  + override opcional: compose/status.yml
```

Los profiles controlan servicios opcionales. Los overrides se cargan con `-f` cuando necesitan modificar `frontend`, `backend` o `gateway`.

En servidores, la composición elegida se guarda en `COMPOSE_FILE` y `COMPOSE_PROFILES`. Eso convierte la selección del stack en configuración persistente y evita que un comando posterior omita HTTPS o autenticación.

## Fuentes de verdad

| Tema | Fuente canónica |
| --- | --- |
| Servicios, redes y volúmenes | `docker-compose.yml` y `compose/*.yml` |
| Variables | `.env.template` |
| Combinaciones soportadas | `scripts/validate-compose.sh` |
| Validación de PR | `.github/workflows/ci.yml`, check `PR Gate` |
| Builds de imágenes | `docker-bake.hcl` y workflows `build-*.yml` |
| Operación de despliegue | `docs/operations/deploy-checklist.md` |
| Credenciales | `scripts/security/README.md` |

La documentación no debe copiar listas completas de variables o comandos si puede enlazar una de estas fuentes.

## Invariantes protegidas por CI

- El core mantiene OAuth2 deshabilitado.
- El override Keycloak activa OAuth2 en backend, archivo generado y frontend.
- El backend espera la configuración OAuth2 y, cuando aplica, un Keycloak saludable.
- El override TLS publica el puerto 443.
- Cada combinación soportada produce un modelo Compose válido.
- El Compose de CI no declara volúmenes persistentes.
- Los scripts de dump cifrado completan un backup/restore real sobre MariaDB efímera.

Los modelos renderizados se guardan como artifacts de CI para evidencia de cambio.

`PR Gate` siempre se publica. La validación Compose corre en todos los cambios; Maven se omite cuando el diff no toca `pom.xml` ni `backend/`. Esto permite exigir un único check sin ejecutar el build pesado en cambios solo documentales.

## Decisiones pendientes

- Las imágenes con tag `latest` siguen siendo adecuadas para desarrollo, pero producción debe fijar tags inmutables.
- `container_name` facilita scripts operativos existentes, aunque impide ejecutar dos proyectos SIH Salus en el mismo host. Su eliminación requiere actualizar primero esos scripts.
- El socket Docker solo se monta al activar el profile `logs`; aun en modo de solo lectura implica privilegios elevados y debe limitarse a hosts administrados.
