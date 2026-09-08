# HTTPS y certificados

La configuración vive en [compose/ssl.yml](../../compose/ssl.yml) y la emisión
y renovación en [certbot/scripts/entrypoint.sh](../../certbot/scripts/entrypoint.sh).
El [gateway](../../gateway/README.md) comparte rutas entre HTTP y HTTPS.

## Configurar

El override `compose/ssl.yml` modifica el gateway y agrega `certbot`; cargar
solo `--profile ssl` no aplica ese override. Para una instalación nueva:

```bash
docker compose -f docker-compose.yml -f compose/ssl.yml --profile ssl up -d --build
```

En un servidor existente, conserva todos sus archivos `COMPOSE_FILE` y sus
`COMPOSE_PROFILES`, incluidos los de Keycloak, Imaging y observabilidad.
El [checklist de despliegue](deploy-checklist.md) describe el cambio operativo.

Para acceso por LAN o VPN, configura las direcciones reales de los clientes:

```env
SSL_MODE=dev
CERT_WEB_DOMAINS=192.168.10.5,localhost,127.0.0.1
```

`dev` genera un certificado auto-firmado y termina correctamente. Los valores
predeterminados cubren únicamente `localhost` y `127.0.0.1`; cada instalación
debe declarar sus IP y nombres. `CERT_WEB_DOMAIN_COMMON_NAME` es opcional y,
si está vacío, se utiliza el primer elemento de `CERT_WEB_DOMAINS`.

Para un dominio público con DNS y HTTP-01 accesibles:

```env
SSL_MODE=prod
CERT_WEB_DOMAINS=sihsalus.example.org
CERT_CONTACT_EMAIL=admin@example.org
SSL_STAGING=true
```

Usa staging para probar la emisión. Sus certificados no tienen la confianza
de una CA pública de producción. Para la emisión definitiva, cambia
`SSL_STAGING=false` y sigue el flujo de renovación de Certbot; conserva los
volúmenes y los respaldos. No uses `docker compose down -v` para cambiar de CA.

Los parámetros admitidos y sus valores por defecto están en
[compose/ssl.yml](../../compose/ssl.yml) y [.env.template](../../.env.template).
La clave y los parámetros DH usan `CERT_RSA_KEY_SIZE` (2048 por defecto).
`CERT_PROFILE` permite seleccionar el perfil de emisión cuando se requiere.

## Confianza y diagnóstico

Distribuye el certificado público `fullchain.pem` mediante un canal verificado
e impórtalo en el almacén de confianza administrado de los clientes. La clave
`privkey.pem` permanece en el servidor. Para comprobar un certificado interno
sin deshabilitar la validación TLS:

```bash
gateway_url=https://192.168.10.5
certificate_file=/ruta/verificada/fullchain.pem
for route in health startup ready; do
  curl --fail --show-error --silent --max-time 15 \
    --cacert "$certificate_file" "$gateway_url/$route"
done
```

Para certificados públicos, omite `--cacert` y usa el almacén del sistema.
`/health` mide Nginx; `/startup` y `/ready` comprueban OpenMRS. Un backend que
todavía está inicializando puede devolver 503 en `/ready`.

En el host, con la composición efectiva cargada:

```bash
docker compose ps -a gateway certbot
docker compose exec -T gateway nginx -t
docker compose logs --tail 50 certbot
openssl x509 -in "$certificate_file" -noout -dates -ext subjectAltName
```

El modo `prod` mantiene un proceso de renovación; no se debe exigir que el
contenedor Certbot termine como en `dev`. La caducidad se observa también en
el [monitoreo](../../monitoring/README.md) mediante las sondas HTTPS.

## Renovación

Certbot renueva cada `CERT_RENEWAL_INTERVAL` y escribe
`/var/www/certbot/.reload-nginx`; `watch-certs.sh` recibe la señal y recarga
Nginx. No es necesario recrear el backend ni las bases de datos.

Para comprobar la renovación de una instalación ya emitida por Certbot,
sobrescribe explícitamente el entrypoint del servicio:

```bash
docker compose run --rm --no-deps --entrypoint certbot certbot renew --dry-run
```

Para una migración de staging a producción, identifica primero el nombre de
la emisión y el dominio en su configuración de renovación, ejecuta la emisión
contra producción con Certbot y valida la configuración antes de recargar
Nginx. No borres los volúmenes para forzar ese proceso.

## Pruebas del código

Desde la raíz del repositorio, con Docker activo, Python 3 y OpenSSL 3:

```bash
python3 tests/gateway/routing.py
bash tests/imaging/auth-gateway.sh
bash scripts/validate-compose.sh
```

Estas pruebas arrancan Nginx con el entrypoint real, certificados efímeros y
upstreams ficticios. Comprueban rutas HTTP/HTTPS, redirección HTTP, challenge
ACME, cookies de sesión, CSP, contingencias e Imaging, sin una instalación
clínica. No solicitan certificados a una CA ni sustituyen la verificación de
login y operaciones del [smoke test de despliegue](deploy-checklist.md#smoke-test-posterior).
