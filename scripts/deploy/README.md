# Despliegue del frontend

`deploy-frontend.sh` actualiza exclusivamente el frontend desde una imagen
inmutable que ya fue publicada y analizada en `sihsalus-frontend`.

El script:

1. valida el SHA y digest solicitados;
2. actualiza el checkout del distro mediante fast-forward;
3. fija `FRONTEND_SOURCE_IMAGE` al digest inmutable y conserva el tag SHA como
   metadato operativo; el runtime local recibe un tag derivado del mismo digest
   para que un rebuild del mismo commit no destruya la ruta de rollback;
4. reconstruye el wrapper runtime y recrea solo `frontend`;
5. verifica salud, imagen y `build-info.json`;
6. restaura la configuración y el contenedor anterior si falla;
7. solo después de verificar el frontend, elimina imágenes antiguas de los dos
   repositorios exclusivos del frontend y conserva las imágenes fuente y
   runtime activas.

No ejecuta `docker compose pull`, `up`, `restart` ni `build` sobre el stack
completo. El único pull explícito es la imagen fuente del frontend por digest;
el build y la recreación están dirigidos exclusivamente al servicio `frontend`
con `--no-deps`. La limpieza tampoco usa `docker image prune`: enumera
únicamente `ghcr.io/sihsalus/sihsalus-frontend` y el repositorio runtime
configurado en `FRONTEND_RUNTIME_IMAGE`, por lo que no elimina imágenes de
OpenMRS, base de datos, gateway ni otros servicios.

La automatización normal vive en `.github/workflows/deploy-frontend.yml`. Una
release verificada de `sihsalus-frontend` publica el tag de señal
`frontend-release-<SHA>` en este repositorio mediante una deploy key limitada al
distro. El workflow exige que ese SHA y su digest correspondan a la imagen
`latest` promovida y los valida contra la imagen inmutable antes de desplegar.
El sondeo programado de `latest` permanece como respaldo si falla la señal
inmediata.

Para una ejecución manual:

```bash
./scripts/deploy/deploy-frontend.sh \
  0123456789abcdef0123456789abcdef01234567 \
  sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

El comando debe ejecutarse desde la raíz del repositorio. Durante una
actualización, la imagen anterior permanece disponible hasta que terminan la
verificación y la posibilidad de rollback automático. Una reversión posterior
a un despliegue exitoso vuelve a descargar por digest y reconstruir el frontend
anterior.
