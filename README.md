# SIH Salus

Distribución OpenMRS para establecimientos de salud del Perú. Este repositorio
mantiene las imágenes, Docker Compose y las herramientas de operación. La
metadata clínica vive en `sihsalus-content` y los microfrontends en
`sihsalus-frontend`.

Antes de contribuir, seguir [AGENTS.md](AGENTS.md). Los merges y las operaciones
compartidas siguen el [procedimiento de revisión humana](docs/operations/human-review.md).

## Inicio rápido

Requiere Docker con Compose v2; Buildx permite usar los targets de Bake.
Desde la raíz del repositorio:

```bash
cp .env.template .env
# Ajustar credenciales y servicios antes de usar un entorno compartido.
docker compose up -d
```

La SPA queda en <http://localhost/openmrs/spa/> y el portal de ayuda en
<http://localhost/ayuda/>. Para desarrollo local se puede arrancar sin `.env`;
las contraseñas predeterminadas `openmrs` son solo para ese uso.

[.env.template](.env.template) documenta las variables. Copiarla conserva la
versión fuente del frontend fijada en [compose/core.yml](compose/core.yml).
El token OCL puede quedar vacío para usar la terminología empaquetada; consultar
su [configuración y rotación](backend/README.md#configuración-del-token-ocl).
Para generar credenciales, usar la [guía de seguridad](scripts/security/README.md).

El primer arranque puede tardar mientras OpenMRS carga metadata. `/health`
indica que Nginx responde; `/ready` debe responder 200 cuando OpenMRS termine
la inicialización. Ver [salud y diagnóstico del gateway](gateway/README.md).
La distribución usa `initializer.startup.load=fail_on_error`; la aceptación de
metadata y módulos requiere además el [checklist de despliegue](docs/operations/deploy-checklist.md).

## Profiles

El core incluye gateway, portal de ayuda, frontend, backend y MariaDB.
Los módulos opcionales se activan mediante profiles y overrides:

```bash
# Core con observabilidad
docker compose --profile monitoring up -d

# Core con HTTPS
docker compose -f docker-compose.yml -f compose/ssl.yml --profile ssl up -d
```

La [guía Compose](compose/README.md) mantiene la lista de perfiles, los comandos
para Keycloak/Imaging y la selección persistente de `COMPOSE_FILE` y
`COMPOSE_PROFILES`. Conservar esa selección en todas las operaciones del host.

## Construcción

```bash
# Backend, gateway y frontend
docker buildx bake

# Resolver la configuración sin construir ni iniciar contenedores
docker buildx bake --print frontend
```

Bake lee `docker-compose.yml` y después [docker-bake.hcl](docker-bake.hcl).
El frontend hereda sus argumentos de Compose; sus overrides y la construcción
directa se documentan en [frontend/README.md](frontend/README.md#build-y-operación).
El backend y sus módulos se documentan en [backend/README.md](backend/README.md).

## Validación local

```bash
# Contratos rápidos con fixtures; sin red ni daemon Docker
bash tests/run.sh

# Compose y Bake; requiere ambos plugins, sin iniciar servicios
bash scripts/validate-compose.sh
```

[tests/README.md](tests/README.md) distingue estas pruebas de las integraciones
con imágenes, autenticación y restauración real. Un resultado local correcto no
sustituye la aceptación del runtime.

## Actualizar y consultar versiones

Desde el checkout instalado:

```bash
python3 scripts/deploy/deploy.py status
python3 scripts/deploy/deploy.py update --frontend latest
python3 scripts/deploy/deploy.py history
python3 scripts/deploy/deploy.py rollback
```

La herramienta resuelve la versión publicada, conserva la recuperación y
actualiza solo el servicio elegido. El historial se guarda automáticamente en
el servidor; no hay archivos de despliegue que redactar o publicar. También
acepta un commit publicado en lugar de `latest`. Configurar `SIHSALUS_PUBLIC_URL`
una vez para incluir la comprobación HTTP externa en la actualización.

`update --backend VERSION` actualiza OpenMRS y su paquete content: exige preparar
el respaldo y revisar migraciones; nunca actualiza el backend implícitamente al
actualizar frontend. Los cambios de Compose se coordinan aparte.

En GitHub Actions, **Deploy Frontend** pide solamente la versión; resuelve sus
imágenes una vez y despliega DEV antes de QLTY con las aprobaciones nativas.
Producción es una operación separada. Ver [operación y recuperación](scripts/deploy/README.md).

## Backup y restore

La [guía de backups](scripts/backup/README.md) es la referencia para dump SQL,
backup físico, cifrado, restauración y recuperación ante fallos. El dump puede
hacerse en caliente; su restauración requiere detener el backend. El backup
físico y las semillas siempre se cifran; los dumps SQL se cifran si se configura
`BACKUP_ENCRYPTION_PASSWORD`, obligatorio para su uso en producción.

Los [simulacros](docs/operations/physical-backup-drill.md) prueban restauraciones
con datos sintéticos. Registrar la evidencia correspondiente a la versión usada.

## Documentación

El [índice de documentación](docs/README.md) organiza las guías por tarea.

| Área | Referencia |
| --- | --- |
| Arquitectura y responsabilidades | [Infraestructura](docs/architecture/infrastructure.md) |
| Servicios, perfiles y variables | [Compose](compose/README.md) |
| HTTPS y certificados | [Runbook HTTPS](docs/operations/https.md) |
| Credenciales y políticas de imágenes | [Seguridad](scripts/security/README.md) |
| Autenticación local y OIDC | [OAuth](oauth/README.md) |
| Monitoreo, logs y UPS | [Monitoreo](monitoring/README.md) |
| Scripts operativos | [Inventario](scripts/README.md) |
