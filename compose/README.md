# Docker Compose Profiles

Este directorio contiene la configuración modular de servicios en YAML. Cada archivo corresponde a un **profile** de Docker Compose que puede ser activado opcionalmente.

## Estructura

```
compose/
├── core.yml       # Servicios base (gateway, frontend, backend, db)
├── fua.yml        # Generador de Formato Único de Atención (MINSA)
├── hapi.yml       # Servidor FHIR para interoperabilidad
├── imaging.yml    # Stack médico (OHIF + Orthanc + DICOM)
├── replica.yml    # Réplica MariaDB para redundancia/backups
├── keycloak.yml   # Autenticación OAuth2/OpenID Connect
├── monitoring.yml # Observabilidad (Grafana + Prometheus + Loki, Alloy opcional)
└── ssl.yml        # SSL/HTTPS (certificados Let's Encrypt o auto-firmados)
```

---

## Profiles

### 🔵 Core (`core.yml`) - **Obligatorio**

Servicios base necesarios para OpenMRS. Se incluye automáticamente.

**Servicios**:
- `gateway` - Reverse proxy Nginx
- `frontend-init` - Inicializador de SPA
- `frontend` - Nginx con SPA compilado
- `backend` - OpenMRS 3.6.0
- `db` - MariaDB 10.11 (master)

**Variables requeridas**:
```env
MYSQL_OPENMRS_PASSWORD=<password_fuerte>
MYSQL_ROOT_PASSWORD=<password_fuerte>
OMRS_OCL_TOKEN=<token_ocl>
BACKEND_TAG=latest
FRONTEND_TAG=latest
```

**Puertos**:
- `80` - Gateway (HTTP)

---

### 🗄️ Replica (`replica.yml`) - Redundancia MariaDB

Réplica MariaDB opcional para backups y contingencia. No publica puertos al host.

**Activar**:
```bash
docker compose --profile replica up -d
```

**Servicios**:
- `db-replic` - MariaDB 10.11 configurado como réplica read-only

**Variables requeridas**:
```env
MYSQL_ROOT_PASSWORD=<password_fuerte>
OMRS_DB_REPL_PASSWORD=<password_fuerte>
OMRS_DB_REPL_USER=openmrs_repl
```

La replicación usa GTID (`MASTER_USE_GTID=slave_pos`). Si el master ya tiene datos clínicos, inicializar `db-replic` desde un backup consistente antes de activar la replicación. El init automático solo es apropiado para despliegues nuevos o réplicas ya preparadas.

---

### 📝 FUA (`fua.yml`) - Generador de Formato Único de Atención

Generador automático de formularios FUA del MINSA.

**Activar**:
```bash
docker compose --profile fua up -d
```

**Servicios**:
- `fua-generator` - Aplicación FUA (Node.js/Express)
- `fua-generator-db` - PostgreSQL para FUA

**Variables requeridas**:
```env
SIHSALUS_FUA_GEN_DB_PASSWORD=<password>
SIHSALUS_FUA_GEN_TOKEN=<token_acceso_fua>
FUA_CONFIG=<configuracion_json>    # En gateway env vars
FUA_LOCATIONS=<ubicaciones_json>   # En gateway env vars
```

**Puertos**:
- `3000` - FUA Generator (HTTP)

**Base de datos**: PostgreSQL 17

---

### 🏥 HAPI FHIR (`hapi.yml`) - Interoperabilidad MINSA

Servidor FHIR para intercambio de datos con otros sistemas de salud.

**Activar**:
```bash
docker compose --profile hapi up -d
```

**Servicios**:
- `hapi-fhir` - Servidor FHIR completo
- `hapi-postgres` - PostgreSQL para FHIR

**Variables requeridas**:
```env
HAPI_DB_PASSWORD=<password>
HAPI_DB_USER=hapi          # Opcional
HAPI_DB_NAME=hapi          # Opcional
```

**Puertos**:
- `8085` - HAPI FHIR API (HTTP)

**Base de datos**: PostgreSQL 15

---

### 🔬 Imaging (`imaging.yml`) - Imágenes Médicas

Stack completo para DICOM (radiografías, tomografías, etc.) con visualización OHIF.

**Activar**:
```bash
docker compose --profile imaging up -d
```

**Servicios**:
- `ohif` - Viewer de imágenes DICOM
- `orthanc` - Servidor DICOM (almacenamiento)

**Configuración**:
- OHIF se configura vía [app-config.js](../imaging/app-config.js)
- Orthanc requiere autenticación deshabilitada en dev

**Puertos**:
- `3000` - OHIF Web UI (HTTP)
- `8042` - Orthanc REST API (HTTP)
- `4242` - DICOM server (TCP port 4242)

**Nota**: Sin autenticación en desarrollo. Agregar en producción.

---

### 🔐 Keycloak (`keycloak.yml`) - Autenticación OIDC/OAuth2

Sistema centralizado de identidad para OpenMRS.

**Activar**:
```bash
docker compose \
  -f docker-compose.yml \
  -f compose/openmrs-keycloak.yml \
  --profile keycloak \
  up -d
```

**Servicios**:
- `keycloak` - Servidor Keycloak 26.4.1
- `keycloak-db` - PostgreSQL 17 para Keycloak

**Variables requeridas**:
```env
KEYCLOAK_ADMIN_PASSWORD=<password_fuerte>
KC_DB_PASSWORD=<password_bd>
OAUTH2_ENABLED=true
OAUTH2_CLIENT_SECRET=<secret_cliente_openmrs>
KEYCLOAK_PORT=8180        # Opcional (puerto de escucha)
KEYCLOAK_PUBLIC_URL=http://localhost:8180
```

**Puertos**:
- `8180` - Keycloak Admin Console (HTTP)

Si se accede desde otra maquina o se combina con SSL, ajustar `KC_HOSTNAME` y `KEYCLOAK_PUBLIC_URL` al host/IP que usaran los navegadores. El realm importado incluye redirects para `localhost`; para una IP o dominio real, agregar ese origen en el cliente `openmrs` de Keycloak.

**Realm preconfigurado**: `openmrs`
- Cliente: `openmrs` (confidencial)
- Roles: System Developer, Provider, Clerk
- Usuario admin inicial con contraseña temporal

**Ver también**: [keycloak/README.md](../keycloak/README.md)

---

### 📊 Monitoring (`monitoring.yml`) - Observabilidad

Stack para métricas, dashboards y almacenamiento de logs. La recolección de logs de Docker con Alloy es opcional porque requiere montar el Docker socket.

**Activar**:
```bash
docker compose --profile monitoring up -d
```

Para habilitar recolección de logs de contenedores:
```bash
docker compose --profile monitoring --profile logs up -d
```

**Servicios**:
- `grafana` - Dashboards y alertas (v12.3)
- `prometheus` - Series de tiempo (v3.2.1)
- `loki` - Agregador de logs
- `blackbox` - Probes HTTP internos para endpoints del gateway
- `alloy` - Colector opcional de logs Docker (profile: `logs`)

**Variables requeridas**:
```env
GRAFANA_ADMIN_PASSWORD=<password>
GRAFANA_ADMIN_USER=admin   # Opcional
GRAFANA_ROOT_URL=...       # Opcional
```

**Puertos** (solo localhost):
- `3001` - Grafana (HTTP, solo localhost)
- `9090` - Prometheus (HTTP, solo localhost)
- `3100` - Loki (HTTP, solo localhost)

**Dashboards preconfigurados**:
- Docker Overview: estado de scrape y volumen/logs por contenedor
- OpenMRS Overview: disponibilidad real por `probe_success`, status HTTP y latencia
- Logs aggregation: búsqueda por `service_name`, `level` y texto libre (requiere profile `logs`)

**Documentación**: [monitoring/README.md](../monitoring/README.md)

---

### 🔒 SSL/HTTPS (`ssl.yml`) - Seguridad

Certificados y configuración HTTPS (Let's Encrypt o auto-firmados).

`ssl.yml` es un override standalone: debe cargarse con `-f compose/ssl.yml` porque modifica el servicio `gateway` para agregar HTTPS. Usar solo `--profile ssl` con `docker-compose.yml` no es suficiente, ya que ese profile no existe hasta cargar este archivo.

**Activar** (con core):
```bash
# Development (auto-firmados)
docker compose -f docker-compose.yml -f compose/ssl.yml --profile ssl up -d

# Production (Let's Encrypt)
export SSL_MODE=prod CERT_WEB_DOMAINS=yourdomain.com
docker compose -f docker-compose.yml -f compose/ssl.yml --profile ssl up -d
```

**Servicios**:
- `certbot` - Generador/renovador de certificados

**Variables**:
```env
SSL_MODE=dev                                                # dev o prod
CERT_WEB_DOMAINS=localhost,127.0.0.1,192.168.0.200        # Dominios (comma-separated)
CERT_WEB_DOMAIN_COMMON_NAME=localhost                      # CN del certificado
CERT_RSA_KEY_SIZE=2048                                     # Tamaño clave RSA y DH params
CERT_TEMP_CERT_DAYS=365                                    # Validez certs auto-firmados
```

**Nota**: Sobreescribe el servicio `gateway` para agregar HTTPS (puerto 443).

---

## Combinaciones Comunes

### Desarrollo local mínimo
```bash
# Solo core
docker compose up -d
```

### Desarrollo con auth
```bash
docker compose \
  -f docker-compose.yml \
  -f compose/openmrs-keycloak.yml \
  --profile keycloak \
  up -d
```

### Auth con SSL
```bash
docker compose \
  -f docker-compose.yml \
  -f compose/openmrs-keycloak.yml \
  -f compose/ssl.yml \
  --profile keycloak \
  --profile ssl \
  up -d
```

### Stack completo de producción
```bash
docker compose \
  -f docker-compose.yml \
  -f compose/openmrs-keycloak.yml \
  -f compose/ssl.yml \
  --profile keycloak \
  --profile monitoring \
  --profile hapi \
  --profile ssl \
  up -d
```

### Imaging + Backend
```bash
docker compose --profile imaging up -d
```

### FUA + HAPI + Monitoring
```bash
docker compose --profile fua --profile hapi --profile monitoring up -d
```

---

## Volúmenes Persistentes

Cada profile define volúmenes persistentes para datos:

| Profile | Volúmenes |
|---------|-----------|
| core | `openmrs-data`, `spa-data`, mariadb data |
| fua | `db-fua-generator` (PostgreSQL) |
| hapi | `hapi_pgdata` (PostgreSQL) |
| imaging | `orthanc-data` (DICOM files) |
| keycloak | `keycloak-data` (PostgreSQL) |
| monitoring | `grafana-data`, `prometheus-data`, `loki-data` |

---

## Redes Docker

Los servicios se comunican a través de redes específicas:

| Red | Propósito |
|-----|-----------|
| `default` | Red por defecto (todos los servicios) |
| `dicom-network` | Aislamiento DICOM (imaging) |
| `auth-network` | Aislamiento autenticación (keycloak) |
| `monitoring-network` | Aislamiento monitoring |
| `services-network` | Interconexión FUA |

---

## Troubleshooting

### Service fails to start
```bash
docker compose --profile <profile> logs <servicio>
```

### Port already in use
Cambia los puertos en `.env` o mediante variables:
```env
KEYCLOAK_PORT=8181  # En lugar de 8180
```

### Database connection issues
Revisa que los servicios de BD estén saludables:
```bash
docker compose --profile <profile> ps
```

---

## Variables de Entorno Completas

Ver [../.env.template](../.env.template) para la lista completa de variables por profile.
