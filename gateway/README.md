# Gateway SIHSALUS

Nginx sirve frontend, OpenMRS y servicios opcionales desde el mismo origen.
Las rutas y políticas son compartidas por HTTP y HTTPS.

## Fuentes de configuración

| Archivo | Responsabilidad |
| --- | --- |
| `nginx.conf` | Procesos, logs y compresión |
| `templates/http.conf.template` | Listener HTTP |
| `templates/https.conf.template` | Listener HTTPS, certificados, cookies TLS y challenge ACME |
| `templates/includes/maps.conf.template` | CSP, esquema reenviado y ACL por dirección de conexión |
| `templates/includes/routes.conf.template` | Rutas, upstreams y contingencias |
| `security-headers.conf` | Cabeceras comunes; HSTS y Permissions-Policy solo en conexiones HTTPS |
| `docker-entrypoint.sh` | Selección del listener y espera inicial de certificados |
| `watch-certs.sh` | Recarga tras la señal de Certbot |

El entrypoint copia las plantillas seleccionadas a `/etc/nginx/templates`.
El `envsubst` de la imagen oficial genera `conf.d/default.conf` y los includes
bajo `conf.d/includes/`. Las plantillas compartidas se editan una sola vez.
La instalación, confianza y renovación están en el
[runbook HTTPS](../docs/operations/https.md).

## Contratos de las rutas

- `/health` responde desde Nginx; `/startup` y `/ready` consultan OpenMRS.
  Los upstreams usan Docker DNS al solicitarse, por lo que el gateway puede
  arrancar aunque el nombre del backend todavía no exista.
- `/openmrs/spa/` elimina su prefijo hacia el frontend. OpenMRS y Grafana
  conservan sus prefijos, incluidas las conexiones WebSocket y SSE.
- `/ayuda/` resuelve `docs` de forma diferida, adapta sus redirects y devuelve
  una contingencia 503 si falta, sin bloquear la aplicación.
- `/services/fua-generator/` elimina solo su prefijo, conserva subruta,
  parámetros y método, y devuelve JSON con estado 503 si falta el generador.
  La misma ruta está disponible en HTTP y HTTPS con el perfil `fua`.
- Imaging permanece cerrado hasta cargar su override de autorización.
- `POST /_sihsalus/clinical-activity` devuelve 204. Su log contiene únicamente
  un timestamp para la [política de apagado](../docs/operations/safe-poweroff.md);
  no agregar IP, cookies, rutas, cuerpos ni otros identificadores.

Las ubicaciones con un `add_header` propio vuelven a incluir
`security-headers.conf`, conforme a la
[herencia de Nginx](https://nginx.org/en/docs/http/ngx_http_headers_module.html#add_header).
La página de contingencia usa CSS local para conservar su estilo con CSP activa.

`FRAME_ANCESTORS` configura los orígenes adicionales que pueden embeber la
aplicación, separados por espacios. Las ACL de Imaging proceden de Compose.
`X-Real-IP` se conserva por compatibilidad con proxies; si falta se usa la
conexión. HTTP acepta `X-Forwarded-Proto` únicamente como `http` o `https`;
HTTPS reenvía su propio esquema. Estas cabeceras no prueban identidad: un proxy
anterior debe limpiar las cabeceras y aplicar su ACL de entrada.

## Migración

Se retiran `FUA_CONFIG` y `FUA_LOCATIONS`: no hacen falta para publicar el
perfil FUA. Elimina esas variables del entorno; si una instalación inyectaba
rutas propias, incorpora la configuración revisada en la plantilla de rutas.
Reconstruye el gateway conservando la composición efectiva del servidor.

## Pruebas

Desde la raíz, con Docker activo, Python 3 y OpenSSL 3:

```sh
python3 tests/gateway/routing.py
bash tests/imaging/auth-gateway.sh
bash tests/backend/realtime-notifications-config.sh
bash scripts/validate-compose.sh
```

Las pruebas usan el entrypoint real, certificados efímeros y upstreams
ficticios en redes separadas; sus puertos se publican solo en `127.0.0.1`.
Eliminan sus contenedores y redes al terminar. `GATEWAY_TEST_IMAGE` permite
seleccionar una imagen Nginx 1.28 disponible y `GATEWAY_CONFIG_DIR` otra
carpeta con esta estructura de configuración.
