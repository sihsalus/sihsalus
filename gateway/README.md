# OpenMRS Gateway

The gateway service is a simple Nginx Docker container that routes requests either to the frontend or the backend as appropriate. Using a service like this enables us to largely ignore CORS issues since both the backend and frontend are served from the same origin.

The main configuration for the gateway can be found in the default.conf.template file. this file is processed at start-up by the NGinx Docker containers envsubst setup, which allows us to substitute  environment variables into the configuration.

## Supported Environment Variables

`FRAME_ANCESTORS`
: This should be a space separated list of origins that are allowed to embed OpenMRS in an IFRAME. For example "http://my.webpage/com http://my.webpage2.com". The syntax is described [on MDN](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Content-Security-Policy/frame-ancestors). By default, only pages served from the gateway can embed OpenMRS in an IFRAME.

## Clinical activity heartbeat

`POST /_sihsalus/clinical-activity` returns `204` without reaching OpenMRS. Its
dedicated access log contains only a Unix timestamp and is consumed by the host
[safe-poweroff policy](../docs/operations/safe-poweroff.md). Never add request
paths, IPs, cookies, identifiers, bodies, or user agents to that log format.

## Portal de ayuda

`/ayuda/` se publica desde el servicio estático `docs`. El upstream se resuelve
de forma diferida y no participa en `depends_on`: si la documentación no está
disponible, el gateway devuelve una página breve de contingencia y conserva
operativos el frontend, OpenMRS y sus señales de salud. Los redirects canónicos
del servidor estático se reescriben para conservar siempre el prefijo `/ayuda/`.

## Configuración compartida

`nginx.conf` contiene el formato de logs y la compresión común. Las plantillas
`default.conf.template` y `default-ssl.conf.template` conservan las diferencias
de HTTP y HTTPS. `security-headers.conf` reúne las cabeceras comunes;
`security-headers-ssl.conf` agrega HSTS y Permissions-Policy para HTTPS.

Una ubicación que declara su propio `add_header` debe volver a incluir la
política de cabeceras correspondiente. Nginx 1.28 deja de heredar el bloque
superior en ese caso, incluso con `always`; véase la
[documentación de Nginx](https://nginx.org/en/docs/http/ngx_http_headers_module.html#add_header).
Esto también aplica a respuestas de contingencia y al heartbeat clínico.
La página de espera carga `backend-unavailable.css` desde el propio gateway,
por lo que conserva su estilo con CSP activa y con el backend fuera de servicio.

Los upstreams se resuelven al recibir la petición mediante Docker DNS. No
agregar un bloque estático `upstream backend`: volvería a impedir el arranque
del gateway cuando el nombre del backend todavía no exista.

En HTTPS, `/services/fua-generator/` elimina únicamente ese prefijo, conserva
la subruta, los parámetros y el método, y devuelve JSON con estado 503 cuando
el servicio no está disponible. `proxy_pass` con una variable seguida de `/`
reemplaza la URI completa por `/`; véase
[proxy_pass](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_pass).
El modo HTTP todavía usa las extensiones históricas `FUA_CONFIG` y
`FUA_LOCATIONS`; no se han retirado ni migrado en este cambio.

La compatibilidad con proxies previos conserva `X-Real-IP` cuando llega
informado y utiliza la dirección de conexión cuando falta. HTTP acepta
`X-Forwarded-Proto` con valor `http` o `https`, y usa su propio esquema para
los demás valores. Esto no autentica esas cabeceras: no deben usarse como
prueba de identidad ni como ACL. Antes de publicar detrás de otro proxy,
definir qué direcciones son de confianza y cómo ese proxy limpia las cabeceras.

## Pruebas

Con Docker activo, Python 3 y OpenSSL 3:

```sh
python3 tests/gateway/routing.py
bash tests/imaging/auth-gateway.sh
bash tests/backend/realtime-notifications-config.sh
bash scripts/validate-compose.sh
```

Las pruebas de rutas usan certificados efímeros y respuestas ficticias, crean
redes separadas y publican puertos aleatorios únicamente en `127.0.0.1`.
Eliminan sus contenedores y redes al terminar. Cubren HTTP y HTTPS, cabeceras
de error, FUA, compresión, transporte de notificaciones y arranque sin DNS del
backend. `GATEWAY_TEST_IMAGE` permite usar una imagen Nginx 1.28 ya disponible;
`GATEWAY_CONFIG_DIR` permite contrastar otra versión de las plantillas.
