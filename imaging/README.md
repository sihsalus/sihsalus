# Imaging DICOM

El profile `imaging` agrega OHIF, Orthanc y un proxy DICOMweb. Contiene imágenes médicas, requiere autorización individual con Keycloak y debe operar únicamente en una red clínica controlada o mediante VPN.

## Arranque seguro por defecto

```env
COMPOSE_FILE=docker-compose.yml:compose/keycloak.yml:compose/imaging-auth.yml
COMPOSE_PROFILES=keycloak,imaging
IMAGING_OIDC_CLIENT_SECRET=<secret-cliente>
IMAGING_OAUTH_COOKIE_SECRET=<base64-de-32-bytes>
IMAGING_OAUTH_REDIRECT_URI=http://localhost/imaging/oauth2/callback
IMAGING_OAUTH_COOKIE_SECURE=false
```

```bash
docker compose up -d --build
```

- OHIF y la API HTTP de Orthanc solo publican puertos en localhost.
- El gateway exige el rol Keycloak `imaging-access` y además limita las rutas a localhost y rangos RFC1918.
- El puerto DICOM `4242` solo escucha en localhost.
- Orthanc exige que el Called AET coincida con `ORTHANC`.
- No se sobrescriben instancias existentes.

## Conectar modalidades de la LAN

Selecciona la IP clínica concreta del servidor; no uses `0.0.0.0` si puedes evitarlo:

```env
DICOM_BIND_ADDRESS=192.168.10.5
DICOM_PORT=4242
```

Configura la modalidad con:

```text
Host: 192.168.10.5
Port: 4242
Called AET: ORTHANC
```

Limita ese puerto en el firewall a las IPs de modalidades autorizadas. DICOM DIMSE no queda protegido por el login web de OpenMRS.

## Acceso web

Sin `compose/imaging-auth.yml`, las rutas web quedan en `deny all`. El override combina autenticación individual y esta ACL:

```env
IMAGING_NETWORK_ACCESS_CONTROL=allow 127.0.0.1; allow 10.0.0.0/8; allow 172.16.0.0/12; allow 192.168.0.0/16; deny all;
```

Para entornos con rangos distintos, reemplázalo por directivas `allow` específicas y termina siempre con `deny all;`. La ACL no reemplaza el rol. No habilites acceso público directo.

Asigna `imaging-access` solo al personal autorizado. `/imaging/logout` elimina la sesión local y solicita a Keycloak terminar la sesión OIDC. No se entregan access tokens a OHIF ni se incluyen secretos en sus assets.

En HTTPS usa `compose/ssl.yml`, una callback HTTPS exacta y `IMAGING_OAUTH_COOKIE_SECURE=true`.

`ORTHANC_AUTHENTICATION_ENABLED` permanece deshabilitado porque OHIF accede mediante el proxy interno. Activarlo sin configurar credenciales en el proxy rompe DICOMweb y no protege por sí mismo las rutas del gateway.

## Persistencia y backup

- Volumen: `orthanc-data`.
- Incluye ese volumen en el plan de backup y retención DICOM.
- Verifica restores con estudios de prueba anonimizados.
- No copies estudios reales a CI, tickets o ambientes de desarrollo.

## Diagnóstico

```bash
docker compose ps
docker compose logs --tail 200 imaging-auth keycloak orthanc orthanc-proxy ohif gateway
docker compose port orthanc 4242
```

OHIF usa [app-config.js](app-config.js) y consulta DICOMweb mediante las rutas del gateway.
