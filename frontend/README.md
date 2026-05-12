# Frontend - Interfaz de Usuario OpenMRS 3.x SPA

El frontend es una Single Page Application (SPA) moderna construida con React y micro-frontends (ESM).

## Stack

- **Framework**: OpenMRS 3.x SPA (React)
- **Bundler**: Webpack Module Federation (micro-frontends)
- **Servidor web**: Nginx 1.28 Alpine
- **Locale**: Español (es) por defecto
- **Build output**: Artefacto estático servido desde `/spa`

---

## Estructura

```
frontend/
├── nginx.conf         # Configuración Nginx para SPA
└── (otros archivos)   # Configuración adicional si existe
```

## Componentes

### `frontend-init` (Inicializador)

Imagen: `ghcr.io/sihsalus/sihsalus-frontend:latest`

**Rol**: Construye/compila la SPA y guarda artefactos en volumen compartido `spa-data`.

**Variables de entorno**:
```env
SPA_OUTPUT_DIR=/spa                         # Directorio de salida
SPA_PATH=/openmrs/spa                       # Path de la SPA en gateway
API_URL=/openmrs                            # URL base de API
SPA_CONFIG_URLS=/openmrs/spa/frontend.json  # URL de configuración
SPA_DEFAULT_LOCALE=es                       # Idioma por defecto (español)
```

**Ciclo de vida**: 
- Corre **una sola vez** al inicio (`restart: "no"`)
- `gateway` espera a que termine para servir el contenido
- No requiere salud constante

### `frontend` (Servidor web)

Imagen: `nginx:1.28-alpine`

**Rol**: Servidor HTTP ligero que sirve archivos estáticos de la SPA.

**Volúmenes**:
- `spa-data:/usr/share/nginx/html:ro` - Artefactos compilados (solo lectura)
- `./frontend/nginx.conf:/etc/nginx/nginx.conf:ro` - Configuración nginx

**Puertos**: 80 (interno, accesible solo desde gateway)

**Health check**: Verifica que Nginx responda a `GET /`

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

### Variables de Entorno para Inicializador

| Variable | Ejemplo | Descripción |
|----------|---------|-------------|
| `SPA_OUTPUT_DIR` | `/spa` | Donde guardar los archivos compilados |
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

### Build local (desarrollo)

```bash
# La imagen frontend-init automatiza esto
docker compose build frontend-init

# O manual (si lo necesitas):
npm install
npm run build
```

### Volumen compartido `spa-data`

- **frontend-init** escribe: artefactos compilados
- **frontend** lee: archivos HTML, JS, CSS, etc.
- **gateway** sirve: en `http://localhost/openmrs/spa`

---

## Troubleshooting

### "404 not found en /openmrs/spa"

1. Verifica que `frontend-init` completó exitosamente:
   ```bash
   docker compose logs frontend-init
   ```
2. Verifica que el volumen `spa-data` contiene archivos:
   ```bash
   docker volume inspect sihsalus_spa-data
   docker run -it --rm -v sihsalus_spa-data:/data busybox ls -la /data
   ```
3. Revisa logs del gateway:
   ```bash
   docker compose logs gateway
   ```

### Cambios en configuración no aparecen

- **Assets versionados** (`.js`, `.css`): Limpiar caché del navegador (Ctrl+Shift+Delete)
- **frontend.json**: Reconstruir frontend-init o hacer hard refresh (Ctrl+F5)
- **nginx.conf**: Reiniciar contenedor frontend
  ```bash
  docker compose restart frontend
  ```

### Errores JavaScript en SPA

```bash
# Ver logs del navegador
# F12 → Console → Errors

# Revisar que los micro-frontends se cargan
# F12 → Network → Type: script

# Log de inicialización
docker compose logs frontend-init
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
