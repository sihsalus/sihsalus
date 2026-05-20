# Frontend - Interfaz de Usuario OpenMRS 3.x SPA

El frontend es una Single Page Application (SPA) moderna construida con React y micro-frontends (ESM).

## Stack

- **Framework**: OpenMRS 3.x SPA (React)
- **Bundler**: Webpack Module Federation (micro-frontends)
- **Servidor web**: Nginx 1.28 Alpine
- **Locale**: Español (es) por defecto
- **Build output**: Artefacto estático dentro de la imagen runtime, servido por gateway en `/openmrs/spa`

---

## Estructura

```
frontend/
├── Dockerfile         # Construye la imagen runtime versionada
├── nginx.conf         # Configuración Nginx para SPA
├── patch-config-urls.js
└── frontend-keycloak.json
```

## Componentes

### `frontend` (Imagen runtime versionada)

Imagen: `${FRONTEND_RUNTIME_IMAGE:-sihsalus-frontend-runtime}:${FRONTEND_RUNTIME_TAG:-latest}`

**Rol**: Servidor HTTP ligero que ya contiene los archivos estáticos de la SPA en `/usr/share/nginx/html`.

**Build**:
- Etapa `assemble`: usa `ghcr.io/sihsalus/sihsalus-frontend:${FRONTEND_SOURCE_TAG:-latest}` para generar app shell, importmap, rutas, config y assets.
- Etapa runtime: copia el resultado a `nginx:1.28-alpine`.

**Puertos**: 80 (interno, accesible solo desde gateway)

**Health check**: verifica que el HTML servido contenga `initializeSpa`, no solo que Nginx responda.

---

## Nginx Configuration

### Política de Caché

```nginx
# Service Worker - NUNCA cachear
location ~* service-worker\.js$ {
  expires -1d;
}

# JavaScript y CSS compilados - CACHEAR 1 año
location ~* (\.js|openmrs\.(\w*\.)?css)$ {
  expires 1y;
}

# Archivos estáticos (imágenes, fuentes) - Revalidar
location ~* \.(?!html?)[^.]+$ {
  add_header Cache-Control "no-cache, must-revalidate";
}

# HTML y rutas de SPA - NUNCA cachear (sirve index.html)
location / {
  try_files /index.html =404;
}
```

### Lógica de caching

1. **Service Worker** (`service-worker.js`): Nunca cachear en navegador
2. **Assets versionados** (`*.js`, `openmrs.*.css`): Cache 1 año (cambios = nuevo nombre)
3. **Archivos estáticos** (imágenes, fuentes): Revalidar siempre
4. **HTML/SPA**: No cachear - el navegador siempre pregunta (304 Not Modified si no cambió)

### Configuración Nginx

```nginx
worker_processes auto;              # Auto-detectar núcleos disponibles
worker_connections 1024;            # Max conexiones por worker
keepalive_timeout 65;               # Keepalive HTTP
sendfile on;                        # Zero-copy para archivos estáticos
```

---

## Configuración de la SPA

### Build Args

| Variable | Ejemplo | Descripción |
|----------|---------|-------------|
| `FRONTEND_SOURCE_IMAGE` | `ghcr.io/sihsalus/sihsalus-frontend:latest` | Imagen fuente con bundles y ensamblador |
| `SPA_PATH` | `/openmrs/spa` | Path en el que está disponible la SPA |
| `API_URL` | `/openmrs` | URL base para llamadas a API backend |
| `SPA_CONFIG_URLS` | `/openmrs/spa/frontend.json` | Ubicación del config JSON |
| `SPA_DEFAULT_LOCALE` | `es` | Idioma por defecto (es, en, pt, fr, etc.) |

### Archivos de Configuración SPA

**`frontend.json`** (ubicación: `${SPA_CONFIG_URLS}`)

Define:
- Micro-frontends (módulos ESM) a cargar
- Configuración de módulos
- Rutas y navegación
- Integraciones con terceros

**Ubicación típica**: `/openmrs/spa/frontend.json` (servida por backend OpenMRS)

---

## Build y Deployment

### Build local

```bash
docker compose build frontend
```

### Actualizar frontend en QA

En QA se puede usar `latest` para tomar la imagen fuente mas reciente publicada en GitHub Container Registry:

```bash
cd ~/sihsalus
git pull
docker compose build --pull frontend
docker compose up -d --no-deps --no-build frontend
docker compose restart gateway
docker compose ps frontend gateway
```

Este flujo reconstruye la imagen runtime local `sihsalus-frontend-runtime:latest` usando como base
`ghcr.io/sihsalus/sihsalus-frontend:latest`.
`--no-deps --no-build` evita que Compose intente levantar o reconstruir dependencias como `backend`.

Si necesitas validar una version especifica o hacer rollback, usa el tag SHA publicado en GHCR:

```bash
FRONTEND_SOURCE_TAG=sha-3b5b82f7b6eb78ac805df8103a932e6e9f47eaba \
FRONTEND_RUNTIME_TAG=sha-3b5b82f7b6eb78ac805df8103a932e6e9f47eaba \
docker compose build --pull frontend

FRONTEND_RUNTIME_TAG=sha-3b5b82f7b6eb78ac805df8103a932e6e9f47eaba \
docker compose up -d frontend gateway
```

Regla practica: `latest` es aceptable para QA; en produccion usa un tag SHA o digest para trazabilidad.

Con Docker Bake:

```bash
TAG=2026-05-13 FRONTEND_SOURCE_TAG=latest docker buildx bake frontend
```

### Deploy y rollback

```bash
FRONTEND_RUNTIME_TAG=2026-05-13 docker compose up -d frontend gateway
```

Rollback:

```bash
FRONTEND_RUNTIME_TAG=tag-anterior docker compose up -d frontend gateway
```

---

## Troubleshooting

### "404 not found en /openmrs/spa"

1. Verifica que `frontend` esté healthy:
   ```bash
   docker compose ps frontend
   ```
2. Revisa que la imagen tenga el shell correcto:
   ```bash
   docker compose exec frontend wget -q -O - http://127.0.0.1/ | grep initializeSpa
   ```
3. Revisa logs del gateway:
   ```bash
   docker compose logs gateway
   ```

### Cambios en configuración no aparecen

- **Assets versionados** (`.js`, `.css`): Limpiar caché del navegador (Ctrl+Shift+Delete)
- **frontend.json**: reconstruir la imagen `frontend` o hacer hard refresh (Ctrl+F5)
- **nginx.conf**: reconstruir la imagen `frontend`
  ```bash
  docker compose build frontend
  docker compose up -d frontend gateway
  ```

### Errores JavaScript en SPA

```bash
# Ver logs del navegador
# F12 → Console → Errors

# Revisar que los micro-frontends se cargan
# F12 → Network → Type: script

# Log de Nginx frontend
docker compose logs frontend
```

### Rendimiento lento

1. **Cache headers correctamente configurados**: Usa DevTools para verificar
2. **Compresión gzip**: Nginx no comprime por defecto en alpine, agregar si necesario
3. **Versionado de assets**: Los cambios en JS/CSS deben generar nuevos nombres

---

## Personalización

### Cambiar idioma por defecto

```bash
# En .env o docker-compose override:
SPA_DEFAULT_LOCALE=en    # Inglés
# Valores: es, en, pt, fr, etc.
```

### Agregar headers de seguridad

Editar [nginx.conf](nginx.conf) para agregar headers:

```nginx
add_header X-Content-Type-Options "nosniff";
add_header X-Frame-Options "SAMEORIGIN";
add_header X-XSS-Protection "1; mode=block";
add_header Referrer-Policy "no-referrer-when-downgrade";
```

### HTTPS en producción

Ver [compose/ssl.yml](../compose/ssl.yml) para agregar certificados.

---

## Desarrollo de Micro-frontends

OpenMRS 3.x permite agregar micro-frontends personalizados sin recompilar todo.

**Ubicación**: Definidos en `frontend.json` (ver configuración SPA)

**Ejemplos**:
- Forms
- Dashboards
- Módulos custom

Ver [OpenMRS ESM Documentation](https://openmrs.org/wiki/) para crear módulos.

---

## Links relacionados

- [Configuración del Gateway](../gateway/README.md)
- [Docker Compose Profiles](../compose/README.md#core-coreymlobligatorio)
- [Solución de problemas general](../README.md#solución-de-problemas)
