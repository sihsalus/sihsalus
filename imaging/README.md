# Imaging DICOM

El profile `imaging` agrega OHIF, Orthanc y un proxy DICOMweb. Contiene imágenes médicas y debe operar únicamente en una red clínica controlada o mediante VPN.

## Arranque seguro por defecto

```bash
docker compose --profile imaging up -d
```

- OHIF y la API HTTP de Orthanc solo publican puertos en localhost.
- El gateway permite `/imaging`, `/orthanc`, `/dicom-web` y `/wado` únicamente desde localhost y rangos RFC1918.
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

Las rutas web tienen una barrera de red, no autenticación clínica individual. El valor por defecto es:

```env
IMAGING_ACCESS_CONTROL=allow 127.0.0.1; allow 10.0.0.0/8; allow 172.16.0.0/12; allow 192.168.0.0/16; deny all;
```

Para entornos con rangos distintos, reemplázalo por directivas `allow` específicas y termina siempre con `deny all;`. No habilites acceso público directo.

`ORTHANC_AUTHENTICATION_ENABLED` permanece deshabilitado porque OHIF accede mediante el proxy interno. Activarlo sin configurar credenciales en el proxy rompe DICOMweb y no protege por sí mismo las rutas del gateway.

## Persistencia y backup

- Volumen: `orthanc-data`.
- Incluye ese volumen en el plan de backup y retención DICOM.
- Verifica restores con estudios de prueba anonimizados.
- No copies estudios reales a CI, tickets o ambientes de desarrollo.

## Diagnóstico

```bash
docker compose --profile imaging ps
docker compose --profile imaging logs --tail 200 orthanc orthanc-proxy ohif gateway
docker compose --profile imaging port orthanc 4242
```

OHIF usa [app-config.js](app-config.js) y consulta DICOMweb mediante las rutas del gateway.
