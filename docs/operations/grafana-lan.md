# Grafana en la LAN del establecimiento

Grafana se sirve al personal autorizado del hospital como una ruta más del
gateway, en `https://<dominio>/grafana/`. No se publica en internet ni se expone
su puerto a la red plana.

## Modelo de acceso

```
LAN del establecimiento
      │  HTTPS 443
      ▼
 sihsalus-gateway (nginx)          redes: default, monitoring-edge
      │  location /grafana/  → ACL CIDR + proxy
      ▼
 sihsalus-grafana                  redes: monitoring-edge, monitoring-network
      │
      └─ prometheus, loki          solo monitoring-network
         alloy, docker-socket-proxy  nunca alcanzables desde el gateway
```

El control se reparte en tres capas y ninguna sustituye a las otras:

| Capa | Dónde se configura | Qué contiene |
| --- | --- | --- |
| Red Docker | `monitoring-edge` en `docker-compose.yml` | Que nginx alcance Loki, Alloy o el proxy del socket de Docker |
| ACL de red | `GRAFANA_NETWORK_ACCESS_CONTROL` | Que otras VLAN o equipos de invitados lleguen a la pantalla de login |
| Identidad | Admin local de Grafana, luego Keycloak | Quién ve qué, con trazabilidad por usuario |

`monitoring-edge` existe porque unir el gateway a `monitoring-network` completa
le daría alcance al proxy del socket de Docker. El gateway es el único
contenedor que recibe tráfico de la LAN: un enlace de dos nodos mantiene esa
superficie al mínimo.

`prometheus` y `blackbox` sí están en `default` desde antes de este modelo,
porque blackbox sondea `http://gateway:80`. Eso es intencional y no cambia.

## Puesta en marcha

1. Declarar el rango autorizado y la URL pública en `.env`:

   ```env
   GRAFANA_ADMIN_USER=admin
   GRAFANA_ADMIN_PASSWORD=<openssl rand -hex 24>
   GRAFANA_ROOT_URL=https://sihsalus.hsc/grafana/
   GRAFANA_COOKIE_SECURE=true
   GRAFANA_NETWORK_ACCESS_CONTROL=allow 192.168.0.0/24; deny all;
   ```

   Sin `GRAFANA_NETWORK_ACCESS_CONTROL` la ruta responde `403` a toda la LAN.
   Es el estado por defecto y es deliberado.

2. Recrear gateway y Grafana:

   ```bash
   docker compose up -d --force-recreate gateway grafana
   ```

3. Verificar antes de darlo por cerrado (ver la sección siguiente).

## Verificación

La ACL usa `$remote_addr`, la dirección real de la conexión TCP. Según cómo
Docker publique el puerto, nginx puede ver en su lugar la dirección del bridge,
y entonces el rango configurado no filtra nada o bloquea todo. Comprobarlo con
tráfico real antes de confiar en él:

```bash
# Debe mostrar la IP del equipo del hospital, no una 172.x del bridge.
docker exec sihsalus-gateway tail -f /var/log/nginx/access.log

# envsubst no dejó marcadores sin resolver (si quedara alguno, nginx no arranca).
docker exec sihsalus-gateway grep -c '${' /etc/nginx/conf.d/default.conf   # 0

# El gateway alcanza Grafana y no alcanza el resto del stack de observabilidad.
docker exec sihsalus-gateway getent hosts grafana              # resuelve
docker exec sihsalus-gateway getent hosts docker-socket-proxy  # vacío

# La política de contenido permite la UI de Grafana.
curl -kI https://sihsalus.hsc/grafana/ | grep -i content-security-policy
```

La entrada de CSP propia de `/grafana/` es necesaria: la política por defecto
del gateway prohíbe estilos y `eval` inline, y con ella la UI de Grafana carga
en blanco. El síntoma parece un problema de red y no lo es.

## Recuperación administrativa

El puerto `127.0.0.1:3001` se conserva justamente para esto. No es una
exposición a la LAN y no debe cambiarse a `0.0.0.0`.

```bash
# 1. Túnel SSH. Funciona con el gateway caído.
ssh -N -L 3001:127.0.0.1:3001 <servidor>
#    Navegador: http://127.0.0.1:3001/grafana/
#    El subpath también aplica aquí por GF_SERVER_SERVE_FROM_SUB_PATH.

# 2. Restablecer el admin sin pasar por HTTP.
docker exec -it sihsalus-grafana grafana cli admin reset-admin-password '<nueva>'

# 3. Estado del servicio desde dentro del contenedor.
docker exec sihsalus-grafana curl -s http://localhost:3000/api/health
```

`GRAFANA_COOKIE_SECURE=true` no rompe la vía 1: los navegadores tratan
`127.0.0.1` como contexto seguro y aceptan cookies `Secure` sobre HTTP. La vía 2
no depende de cookies en absoluto.

## Autenticación con Keycloak

Una vez que `/grafana/` funciona con el admin local, `compose/monitoring-oidc.yml`
mueve la autenticación a Keycloak y da trazabilidad por usuario:

```bash
docker compose \
  -f docker-compose.yml \
  -f compose/keycloak.yml \
  -f compose/monitoring-oidc.yml \
  -f compose/ssl.yml \
  --profile keycloak --profile monitoring --profile ssl \
  up -d
```

En Keycloak hay que registrar el cliente `sihsalus-grafana` con redirect URI
`https://<dominio>/grafana/login/generic_oauth` y los roles `grafana-admin` y
`grafana-editor`. `ROLE_ATTRIBUTE_STRICT` está en `true`: quien no tenga rol
mapeado no entra, en lugar de caer en `Viewer`.

El override agrega Grafana a `auth-network` porque el intercambio de código
ocurre contra `keycloak:8080` por la red interna. Sin esa red el login falla con
un timeout opaco al volver de Keycloak.

El formulario local sigue habilitado como break-glass. Quien lo proteja es la
ACL de red, no su ausencia.

## Riesgos conocidos

- **Certificado autofirmado.** `.hsc` no es un TLD público y Let's Encrypt no
  puede emitir para él. Si la CA interna no se distribuye a los equipos del
  establecimiento, el personal se acostumbra a saltar advertencias de TLS, que
  es peor que no tener HTTPS.
- **Los tableros de Loki contienen identificadores indirectos.** El log del
  gateway registra `$uri`, y las URLs de OpenMRS llevan UUID de paciente.
  Grafana debe tratarse como un sistema con datos clínicos indirectos, no como
  una herramienta de infraestructura inocua. Es el argumento principal para
  pasar a Keycloak y no quedarse en el admin compartido.
- **Grafana como pivote SSRF.** Un Editor puede crear un datasource apuntando a
  servicios internos y usar Grafana como proxy.
  `GF_SECURITY_DATA_SOURCE_PROXY_WHITELIST` lo limita a `prometheus` y `loki`.
- **`$http_x_real_ip` es un encabezado del cliente.** El gateway lo propaga como
  `X-Real-IP`, pero la ACL no lo usa. No debe usarse para decisiones de acceso.
