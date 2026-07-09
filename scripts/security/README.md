# Credenciales y auditoría local

Docker Compose consume variables de entorno planas. Este repositorio no declara Docker secrets ni variables `*_FILE`; la documentación y las herramientas siguen ese modelo explícitamente.

## Generar un archivo de producción

```bash
./scripts/security/secrets_generate.sh
```

El comando crea `.env.production` con permisos `600`. No sobrescribe un archivo existente para evitar una rotación accidental. Puede recibir otra ruta:

```bash
./scripts/security/secrets_generate.sh .env.staging
```

El archivo contiene credenciales para el core y los perfiles opcionales. Antes de desplegar:

1. Configura URLs y dominios del entorno.
2. Fija tags inmutables de backend y frontend.
3. Define `COMPOSE_FILE` y `COMPOSE_PROFILES` para el stack del servidor.
4. Guarda una copia cifrada en el gestor de secretos institucional.

No se crean archivos duplicados bajo `secrets/`: `.env.production` es la única salida local y ya está excluida de Git.

## Auditar configuración

```bash
./scripts/security-audit.sh .env.production
```

Sin argumento, el auditor busca primero `.env.production` y luego `.env`. Verifica:

- permisos y exclusión de Git;
- credenciales core y de perfiles habilitados;
- valores de desarrollo conocidos;
- validez del modelo Compose seleccionado;
- validez e invariantes de todos los modelos Compose del repositorio.

El auditor nunca imprime valores de secretos. Retorna código distinto de cero si encuentra un fallo.

## Selección persistente del stack

Para HTTPS y Keycloak, guarda la selección en el archivo de entorno. Así cualquier `docker compose up`, `pull`, `ps` o `config` usa los mismos overrides:

```env
COMPOSE_FILE=docker-compose.yml:compose/keycloak.yml:compose/ssl.yml
COMPOSE_PROFILES=keycloak,ssl
```

En Windows, `COMPOSE_PATH_SEPARATOR` puede cambiar el separador de `COMPOSE_FILE`.

## Reglas operativas

- No commitear `.env`, `.env.production`, tokens, llaves ni certificados privados.
- No usar los defaults `openmrs`, `admin`, `change-me` o equivalentes fuera de desarrollo local.
- No rotar una contraseña de base de datos solo en el archivo: primero coordinar el cambio en el servicio y luego recrear sus consumidores.
- Cifrar cualquier backup del archivo de entorno.
- Usar credenciales distintas por ambiente.

Para reportar una vulnerabilidad, ver [SECURITY.md](../../SECURITY.md).
