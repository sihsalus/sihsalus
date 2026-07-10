# Modelo Docker Compose

`docker-compose.yml` es el único punto de entrada. Incluye el core y los módulos que solo agregan servicios. Los archivos que modifican servicios existentes se cargan explícitamente como overrides.

## Capas

| Capa | Activación | Propósito |
| --- | --- | --- |
| Core | `docker compose up -d` | Gateway, frontend, OpenMRS y MariaDB |
| FUA | `--profile fua` | Generador FUA y PostgreSQL propio |
| HAPI | `--profile hapi` | Servidor FHIR y PostgreSQL propio |
| Imaging | `--profile imaging` | OHIF, Orthanc y proxy DICOMweb |
| Indicadores | `--profile indicadores` | Reportes SQL y PostgreSQL propio |
| Monitoring | `--profile monitoring` | Grafana, Prometheus, Loki y blackbox |
| Logs | `--profile monitoring --profile logs` | Alloy mediante proxy Docker API de solo lectura |
| Réplica | `--profile replica` | Réplica MariaDB para contingencia |
| Keycloak | `-f compose/keycloak.yml --profile keycloak` | Activa OIDC en frontend/backend y agrega Keycloak |
| HTTPS | `-f compose/ssl.yml --profile ssl` | Modifica gateway y agrega certbot |
| Status | `-f compose/status.yml --profile status` | Panel local Gatus |

Keycloak, HTTPS y Status son overrides porque cambian o dependen de servicios del core. Por eso no se agregan mediante `include`.

## Comandos comunes

```bash
# Core
docker compose up -d

# Core + un módulo incluido
docker compose --profile monitoring up -d

# Keycloak
docker compose -f docker-compose.yml -f compose/keycloak.yml --profile keycloak up -d

# HTTPS
docker compose -f docker-compose.yml -f compose/ssl.yml --profile ssl up -d

# Keycloak + HTTPS
docker compose \
  -f docker-compose.yml \
  -f compose/keycloak.yml \
  -f compose/ssl.yml \
  --profile keycloak \
  --profile ssl \
  up -d
```

## Configuración persistente en servidores

Repetir flags manualmente es propenso a errores. En un servidor, define la composición en `.env` o `.env.production`:

```env
COMPOSE_FILE=docker-compose.yml:compose/keycloak.yml:compose/ssl.yml
COMPOSE_PROFILES=keycloak,ssl
```

Después, los comandos operativos son uniformes y no degradan HTTPS accidentalmente:

```bash
docker compose config --quiet
docker compose pull
docker compose up -d
docker compose ps
```

## Variables

`.env.template` es el inventario canónico. Las reglas son:

- El core conserva defaults solo para desarrollo local.
- El core puede renderizar sin secretos de profiles opcionales. Al activar un profile, su servicio o `security-audit.sh` rechaza credenciales vacías.
- `OAUTH2_ENABLED` no se configura en `.env`: core lo fija en `false` y `compose/keycloak.yml` lo cambia a `true`.
- En producción se usan tags inmutables, no `latest`.
- HAPI y las consolas de observabilidad se publican solo en localhost.

Para generar credenciales y auditar un ambiente, ver [scripts/security/README.md](../scripts/security/README.md).

## Validación

El mismo comando se usa localmente y en CI:

```bash
./scripts/validate-compose.sh
```

Además de renderizar todas las combinaciones soportadas, valida invariantes de OAuth2, TLS y el Compose sin volúmenes. Para conservar los modelos renderizados como evidencia:

```bash
./scripts/validate-compose.sh compose-validation
```

## Reglas para cambios

1. Un servicio opcional nuevo debe vivir en `compose/<modulo>.yml` y usar un profile.
2. Un archivo que modifica el core debe ser un override explícito y documentar su comando completo.
3. Una variable nueva debe agregarse a `.env.template` y, si es secreta, al generador y auditor.
4. Una combinación soportada debe agregarse a `scripts/validate-compose.sh`.
5. Evitar subredes IP fijas; los servicios se descubren por nombre DNS de Compose.

La arquitectura y los límites de cada capa están en [docs/architecture/infrastructure.md](../docs/architecture/infrastructure.md).
