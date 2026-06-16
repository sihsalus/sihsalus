# SIH Salus


![OpenMRS 3.x](https://img.shields.io/badge/OpenMRS-3.6.0-f26522?style=flat-square)
![Docker](https://img.shields.io/badge/Docker-compose-2496ED?style=flat-square&logo=docker&logoColor=white)
![MariaDB](https://img.shields.io/badge/MariaDB-10.11-003545?style=flat-square&logo=mariadb&logoColor=white)
![Nginx](https://img.shields.io/badge/Nginx-SSL-009639?style=flat-square&logo=nginx&logoColor=white)
![License](https://img.shields.io/badge/MPL_2.0-brightgreen?style=flat-square&label=License)

> SIH Salus es una distribución OpenMRS 3.x para establecimientos de salud del Perú.
> Certificados SSL auto-firmados, despliegue offline, backups cifrados.

---

## Tabla de Contenidos

- [Inicio Rápido](#inicio-rápido)
- [Profiles](#profiles)
- [Actualización en Producción](#actualización-en-producción)
- [Docker Bake (Build)](#docker-bake-build)
- [Configuración SSL/HTTPS](#configuración-sslhttps)
- [Backup y Restore](#backup-y-restore)
- [Políticas de Seguridad](#políticas-de-seguridad-cifrado-de-backups-y-retención-de-logs)

---

## Inicio Rápido

### 1. Configurar variables de entorno

Para desarrollo local, `docker compose up -d` puede arrancar sin `.env`: las credenciales de base usan `openmrs` por defecto.

Para producción o pruebas compartidas, crea `.env` y cambia las credenciales:

```bash
cp .env.template .env
# Editar .env con tus valores
```

```env
# Base de datos OpenMRS
MYSQL_OPENMRS_PASSWORD=<password_seguro>
MYSQL_ROOT_PASSWORD=<password_seguro>

# Token OCL para importar conceptos médicos, si vas a importar conceptos
OMRS_OCL_TOKEN=<tu_token_de_ocl>
```

> No uses los defaults `openmrs`/`openmrs` en producción.

### 2. Construir e iniciar

```bash
# Core (gateway, frontend, backend, db)
docker compose up -d

# http://localhost/openmrs/spa
```

La primera vez, OpenMRS puede tardar unos minutos en quedar listo. La señal principal de readiness es `http://localhost/openmrs/health/started` respondiendo `200`; después de eso `http://localhost/openmrs/login.htm` y la SPA en `http://localhost/openmrs/spa/` deben responder correctamente.

### Health y readiness

El gateway expone dos señales distintas:

- `GET /health`: lo responde Nginx sin tocar upstreams; indica que el gateway está vivo.
- `GET /ready`: proxy a `/openmrs/health/started`; responde `200` solo cuando OpenMRS terminó de inicializar.

Comandos útiles durante arranque o actualización:

```bash
curl -k -i https://localhost/health
curl -k -i https://localhost/ready
curl -k -i https://localhost/openmrs/health/started
curl -k -i https://localhost/openmrs/ws/rest/v1/session
curl -k -i https://localhost/openmrs/spa/home
```

## Profiles

La infraestructura se organiza en **profiles** opcionales. Solo los servicios core (gateway, frontend, backend, db) se inician por defecto.

```bash
# Core solamente
docker compose up -d

# Core + FUA Generator
docker compose --profile fua up -d

# Core + HAPI FHIR
docker compose --profile hapi up -d

# Core + Medical Imaging (OHIF/Orthanc)
docker compose --profile imaging up -d

# Core + Keycloak Auth
docker compose -f docker-compose.yml -f compose/keycloak.yml --profile keycloak up -d

# Core + Observabilidad (Grafana/Prometheus/Loki)
docker compose --profile monitoring up -d

# Combinar profiles
docker compose --profile fua --profile hapi --profile monitoring up -d

# Core + SSL/HTTPS (override especial; requiere cargar compose/ssl.yml)
docker compose -f docker-compose.yml -f compose/ssl.yml --profile ssl up -d

# Core + Keycloak Auth + SSL/HTTPS
docker compose -f docker-compose.yml -f compose/keycloak.yml -f compose/ssl.yml --profile keycloak --profile ssl up -d
```

Cada profile requiere sus variables en `.env`. Ver `.env.template` para la lista completa.

El perfil `ssl` es un caso especial: no basta con pasar `--profile ssl` si solo se usa `docker-compose.yml`, porque la configuración SSL vive en `compose/ssl.yml` y ese archivo modifica el servicio `gateway` para exponer HTTPS.

## Actualización en Producción

En producción, el objetivo es desplegar imágenes versionadas y evitar builds locales cuando la imagen runtime ya está publicada.
Mientras el runtime del frontend no se publique en un registry, el flujo actual reconstruye solo el wrapper `frontend` desde una imagen fuente versionada.

### Frontend (flujo actual)

Actualmente el frontend se despliega como una imagen runtime local (`sihsalus-frontend-runtime`) construida desde la imagen fuente publicada en GHCR (`ghcr.io/sihsalus/sihsalus-frontend`). Por eso, mientras no se publique una imagen runtime en el registry, la actualización de frontend en producción requiere reconstruir solo ese wrapper runtime.

```bash
# 1) Sincronizar cambios de infra (compose/env/docs si aplica)
git -C /ruta/a/sihsalus pull --ff-only

# 2) Definir tag fuente del frontend publicado en GHCR
export FRONTEND_SOURCE_TAG=sha-<digest>

# 3) Reconstruir y recrear solo frontend
DOCKER_BUILDKIT=1 docker compose build --pull frontend
docker compose up -d --no-deps --no-build --force-recreate frontend
docker compose ps frontend
docker compose logs --tail 100 frontend
```

Si necesitas rollback, vuelve a exportar el tag anterior en `FRONTEND_SOURCE_TAG`, reconstruye `frontend` y recrea el servicio.

### Frontend (sin build, cuando exista runtime publicado)

La práctica más reproducible es publicar también la imagen runtime y desplegar por `pull + recreate`. Ese flujo requiere que exista `ghcr.io/sihsalus/sihsalus-frontend-runtime:<tag>` o una imagen equivalente.

```bash
export FRONTEND_RUNTIME_IMAGE=ghcr.io/sihsalus/sihsalus-frontend-runtime
export FRONTEND_RUNTIME_TAG=sha-<digest>

docker compose pull frontend
docker compose up -d --no-deps --force-recreate frontend
docker compose ps frontend
docker compose logs --tail 100 frontend
```

### Frontend (producción sin `*.map`)

Por defecto, en el build de runtime del frontend se eliminan los `*.map` de producción.

`compose/core.yml` pasa `STRIP_SOURCE_MAPS` al build y el valor por defecto es `true`:

```bash
STRIP_SOURCE_MAPS=true  # true = elimina *.map, false = los conserva
```

Efecto esperado:

- Si usas `docker compose build` / `docker compose up` para reconstruir `frontend`, la imagen resultante queda sin mapas de fuente.
- Si usas una imagen preconstruida de registry, debe haberse publicado con `STRIP_SOURCE_MAPS=true` para que no lleve mapas.
- Si necesitas mapas para depuración puntual de preproducción, puedes reconstruir con `STRIP_SOURCE_MAPS=false`.



### Backend (si cambió la imagen del backend)

```bash
export BACKEND_TAG=sha-<digest>
docker compose pull backend
docker compose up -d --no-deps --force-recreate backend
```

Cuando cambie la interfaz de API entre frontend y backend, actualiza primero backend y luego frontend en el mismo ciclo de despliegue.

### Gateway (si cambió Nginx, SSL o health/readiness)

```bash
DOCKER_BUILDKIT=1 docker compose -f docker-compose.yml -f compose/ssl.yml --profile ssl build gateway
docker compose -f docker-compose.yml -f compose/ssl.yml --profile ssl up -d --no-deps --force-recreate gateway
curl -k -i https://localhost/health
curl -k -i https://localhost/ready
```

### Estructura de archivos

```
docker-compose.yml              # Entry point (include + profiles + volumes + networks)
docker-compose-no-volumes.yml   # CI/testing (standalone)
docker-bake.hcl                 # Build definitions
backend/                        # Backend (Dockerfile, pom.xml, config)
gateway/                        # Nginx gateway
frontend/                       # SPA frontend
certbot/                        # SSL certificates
keycloak/                       # Keycloak auth
imaging/                        # OHIF config
compose/
  core.yml                      # gateway, frontend, backend, db
  fua.yml                       # profile: fua
  hapi.yml                      # profile: hapi
  imaging.yml                   # profile: imaging
  keycloak.yml                  # profile: keycloak
  monitoring.yml                # profile: monitoring
  ssl.yml                       # override con -f (modifica gateway)
```

## Docker Bake (Build)

Para construir imágenes se puede usar `docker buildx bake`, que paraleliza y cachea builds:

```bash
# Build core (backend, gateway, frontend) en paralelo
docker buildx bake

# Build un target específico
docker buildx bake backend

# Build todos (+ keycloak, certbot)
docker buildx bake all

# Dry-run (ver config sin ejecutar)
docker buildx bake --print
```

Alternativamente, `docker compose build` sigue funcionando.

## Configuración SSL/HTTPS

SIHSALUS genera certificados SSL auto-firmados, pensados para redes hospitalarias internas sin acceso a internet.

No se requiere un dominio público ni una autoridad certificadora externa. El sistema genera su propio certificado al iniciar por primera vez.

### Iniciar con SSL

Agregar las variables SSL al `.env`:

```env
CERT_WEB_DOMAIN_COMMON_NAME=192.168.10.5
CERT_WEB_DOMAINS=192.168.10.5,localhost,127.0.0.1
```

```bash
docker compose -f docker-compose.yml -f compose/ssl.yml --profile ssl build
docker compose -f docker-compose.yml -f compose/ssl.yml --profile ssl up -d

# https://192.168.10.5/openmrs/spa
```

`compose/ssl.yml` debe cargarse con `-f` porque no esta incluido por defecto en `docker-compose.yml`. El flag `--profile ssl` activa el servicio `certbot` definido en ese archivo; sin el `-f compose/ssl.yml`, Compose no ve ese profile ni aplica los cambios de `gateway` para publicar el puerto 443.

### SSL con Keycloak

SSL y Keycloak se pueden usar juntos cargando ambos overrides:

```bash
docker compose \
  -f docker-compose.yml \
  -f compose/keycloak.yml \
  -f compose/ssl.yml \
  --profile keycloak \
  --profile ssl \
  up -d
```

### Variables SSL en `.env`

| Variable | Descripción | Default |
|----------|-------------|---------|
| `SSL_MODE` | `dev` (genera una vez y termina) o `prod` (renueva automáticamente) | `dev` |
| `CERT_WEB_DOMAINS` | Todas las direcciones por las que se accederá al servidor, separadas por coma (IPs y/o nombres) | `localhost,127.0.0.1` |
| `CERT_WEB_DOMAIN_COMMON_NAME` | La dirección principal del servidor (IP o nombre) | `localhost` |
| `CERT_RSA_KEY_SIZE` | Tamaño de la clave RSA y de los parámetros DH generados por certbot | `2048` |

### Ejemplo para despliegue en hospital

Si el servidor tiene IP `192.168.10.5` en la red del hospital y los equipos acceden por esa IP:

```env
CERT_WEB_DOMAIN_COMMON_NAME=192.168.10.5
CERT_WEB_DOMAINS=192.168.10.5,localhost,127.0.0.1
```

Si el hospital tiene varias VLANs y el servidor tiene más de una IP, incluirlas todas:

```env
CERT_WEB_DOMAIN_COMMON_NAME=192.168.10.5
CERT_WEB_DOMAINS=192.168.10.5,192.168.20.5,172.16.0.5,localhost,127.0.0.1
```

### Instalar el certificado en los equipos del hospital

Al ser un certificado auto-firmado, los navegadores mostrarán una advertencia de seguridad la primera vez. Para evitarlo, instalar el certificado en cada equipo cliente:

1. Copiar el archivo `fullchain.pem` del servidor (se encuentra en el volumen Docker `sihsalus-letsencrypt-data`)
2. **Windows**: Importar en "Entidades de certificación raíz de confianza"
3. **Linux**: Copiar a `/usr/local/share/ca-certificates/` y ejecutar `sudo update-ca-certificates`



## Backup y Restore

Los scripts se encuentran en `scripts/backup/`. Hay dos métodos:

### Dump SQL (en caliente, sin downtime)

```bash
# Backup - DB sigue corriendo, sin interrupciones
./scripts/backup/backup_dump.sh

# Restore - solo detiene el backend, DB sigue corriendo
./scripts/backup/restore_dump.sh
```

### Backup binario (en frío, más rápido)

```bash
# Backup con mariadb-backup
./scripts/backup/backup_full.sh

# Restore - detiene DB, crea snapshot de seguridad, restaura
./scripts/backup/restore_full.sh

# Especificar archivo directamente
./scripts/backup/restore_full.sh --file ~/sihsalus-fullBackups/backup_2026-03-01.tar.gz.enc
```

| | Dump SQL (caliente) | Binario (frío) |
|---|---|---|
| Downtime | No (solo backend) | Sí (detiene DB) |
| Velocidad | Más lento | Rápido |
| Formato | `.sql.gz` | `.tar.gz` (mariadb-backup) |
| Cifrado | Opcional (AES-256) | Obligatorio (AES-256) |
| Idempotente | Sí | Sí (snapshot pre-restore) |

> Los backups cifrados requieren la variable `BACKUP_ENCRYPTION_PASSWORD`.

## Políticas de Seguridad: Cifrado de Backups y Retención de Logs

Este proyecto implementa:
- **Cifrado automático de backups**: Los archivos de respaldo se cifran con AES-256 usando openssl. La clave se provee vía la variable de entorno `BACKUP_ENCRYPTION_PASSWORD`. El backup sin cifrar se elimina tras el cifrado exitoso.
- **Rotación y retención de logs**: Los scripts de backup mantienen solo los últimos 5 archivos de log, eliminando los más antiguos automáticamente.
