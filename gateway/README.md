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
