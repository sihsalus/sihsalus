# Integración con Terminología

El servidor se construye, configura y despliega desde
[`sihsalus-terminology`](https://github.com/sihsalus/sihsalus-terminology).
Su [guía de operación](https://github.com/sihsalus/sihsalus-terminology/blob/main/docs/operations/terminology.md)
cubre Compose, HTTPS, SMTP, GitHub Secrets, backups y recuperación.

Esta distribución mantiene la integración de OpenMRS como consumidor:

- `OMRS_OCL_TOKEN` y su [configuración y rotación](../../backend/README.md#configuración-del-token-ocl).
- Contenido clínico versionado de `sihsalus-content`.
- Catálogos empaquetados para que las pantallas clínicas no dependan de la
  disponibilidad del servidor de terminología.

No configurar aquí las credenciales de base de datos, almacenamiento, SMTP
ni administración del servidor terminológico.
