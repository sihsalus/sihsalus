# Despliegue del frontend

`deploy-frontend.sh` actualiza exclusivamente el frontend desde una imagen
inmutable que ya fue publicada y analizada en `sihsalus-frontend`.

El script:

1. valida el SHA y digest solicitados;
2. actualiza el checkout del distro mediante fast-forward;
3. fija `FRONTEND_SOURCE_TAG` y `FRONTEND_RUNTIME_TAG` al tag inmutable;
4. reconstruye el wrapper runtime y recrea solo `frontend`;
5. verifica salud, imagen y `build-info.json`;
6. restaura la configuración y el contenedor anterior si falla.

La automatización normal vive en `.github/workflows/deploy-frontend.yml`.
Para una ejecución manual:

```bash
./scripts/deploy/deploy-frontend.sh \
  0123456789abcdef0123456789abcdef01234567 \
  sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

El comando debe ejecutarse desde la raíz del repositorio y requiere que el
runtime anterior siga disponible localmente para poder realizar rollback.
