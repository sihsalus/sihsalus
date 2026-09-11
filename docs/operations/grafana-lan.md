# Acceso de red a Grafana

Grafana conserva `/grafana/`, su autenticación local, la configuración de
subruta y las conexiones WebSocket existentes. Este cambio limita quién puede
llegar a esa autenticación: no crea usuarios, no activa Keycloak y no modifica
las rutas clínicas. La autenticación individual con Keycloak se gestiona como
un cambio opcional separado.

## Política y aislamiento

- Sin `GRAFANA_NETWORK_ALLOWLIST`, el gateway devuelve 403 para `/grafana` y
  `/grafana/`, también desde la LAN. La política es deliberadamente cerrada.
- La variable contiene entradas [Nginx geo](https://nginx.org/en/docs/http/ngx_http_geo_module.html):
  `CIDR 1;`, separadas por espacios. No usa sintaxis `allow`/`deny`. Es
  configuración confiable del operador, no un valor aceptado desde HTTP.
  Configura únicamente los rangos administrativos necesarios; no uses `default`,
  `/0` ni toda una red privada si solo necesita acceso una VLAN de soporte.
- También debe cumplirse el filtro de redes privadas existente. Autorizar una
  dirección pública en esta lista no anula esa segunda barrera.
- Ambas comprobaciones usan la dirección de la conexión TCP. Las cabeceras
  reenviadas no otorgan permisos. Si hay NAT o un proxy anterior, la IP que ve
  Nginx puede ser la del proxy: una ACL allí no distingue a sus clientes.
  El proxy anterior debe filtrar el origen real antes de autorizar su dirección.
- Solo gateway y Grafana comparten `monitoring-edge`. Grafana conserva
  `monitoring-network` para consultar sus datasources. El gateway conserva
  `default`, donde Prometheus y Blackbox ya estaban presentes; este cambio no
  afirma aislar esos dos servicios del gateway.
- El puerto directo de Grafana sigue en `127.0.0.1:3001`, no en todas las
  interfaces. La lista del gateway no sustituye el login de Grafana.

Los logs y tableros pueden contener identificadores indirectos. Restringe su
acceso al personal técnico autorizado y no copies respuestas, cookies ni logs
clínicos en evidencia pública.

## Migración coordinada

Este cambio cerrará el acceso actual por gateway si no se configura la lista.
Antes de desplegar, identifica y aprueba los rangos reales del entorno. No
copies un ejemplo a un servidor ni amplíes la lista para ocultar un problema
de NAT. Mantén una sesión administrativa alternativa durante la verificación.

Ejemplo de formato, **no una configuración aprobada de ningún hospital**:

```env
GRAFANA_NETWORK_ALLOWLIST=192.168.50.0/24 1; 127.0.0.1/32 1;
GRAFANA_ROOT_URL=https://sihsalus.example.test/grafana/
GRAFANA_COOKIE_SECURE=true
```

Conserva todos los archivos `COMPOSE_FILE` y perfiles efectivos del servidor,
incluido HTTPS. No actives Keycloak ni cambies la autenticación clínica como
parte de esta migración. Después de la aprobación del despliegue, valida el
modelo y la sintaxis de Nginx con la configuración e imagen candidatas antes
de recrear servicios. La sintaxis de `geo` no se valida con `compose config`.

En una ventana autorizada, la reconciliación afecta únicamente gateway y
Grafana para aplicar sus nuevas redes; no recrees backend, bases ni el stack
completo. Usa `--no-deps`, conserva los volúmenes y registra las referencias
de las imágenes/configuración anteriores. Fusionar este PR no constituye una
orden de ejecutar esos pasos en un servidor.

## Verificación en DEV/QLTY

Usa cuentas y tráfico sintéticos, desde clientes de prueba coordinados:

1. Confirma sin registrar tráfico clínico qué dirección TCP ve el gateway.
   Si representa un proxy o bridge, verifica su política de entrada y la
   diferencia entre un cliente permitido y otro denegado antes de habilitarlo.
2. Con la lista vacía, `/grafana`, `/grafana/`, sus recursos y API deben devolver
   403 en el listener de aplicación. El listener 80 de una instalación HTTPS
   puede responder primero 301 hacia HTTPS; no es una concesión de acceso.
3. Desde un rango autorizado, confirma el redirect canónico y el login,
   recursos estáticos, un tablero sintético y Grafana Live. La existencia de
   una pantalla de login no acredita una sesión ni permisos correctos.
4. Desde un rango no autorizado, comprueba 403 incluso enviando cabeceras
   `X-Real-IP` y `X-Forwarded-For` con una dirección permitida.
5. Confirma `/health`, `/startup`, `/ready`, SPA e Imaging sin cambios. Que
   Grafana falte o esté detenido no debe bloquear el arranque del gateway.
6. Verifica el modelo de redes efectivo: solo gateway y Grafana en la red
   dedicada, sin unir el gateway a la red interna de monitoreo.

El CI usa Nginx real con upstreams ficticios, HTTP/HTTPS y certificados
efímeros. Cubre las rutas y sus controles; no reemplaza las pruebas de IP real,
login, tablero y recuperación en la topología del establecimiento.

## Recuperación y rollback

Conserva el acceso SSH autorizado. El puerto loopback no cambia, pero una
sesión web mediante túnel depende de `GRAFANA_ROOT_URL`, las cookies, el esquema
y el navegador. No asumas que una cookie `Secure` funcionará por HTTP en todos
los navegadores: valida previamente el túnel HTTPS o el procedimiento
administrativo aprobado del entorno. Este PR no reduce la seguridad de cookies
ni cambia contraseñas para facilitar una recuperación.

Para cerrar inmediatamente la ruta en una ventana autorizada, vacía la lista
y recrea solo el gateway con la misma composición. Para volver al estado
anterior, restaura las referencias e instrucciones de Compose registradas y
reconcilia gateway/Grafana con `--no-deps`; no elimines sus volúmenes. Ese
rollback recupera también la política de acceso anterior, más amplia, por lo
que debe ser una decisión explícita del operador.
