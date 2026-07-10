# Utilidades operativas

## Inventario

| Archivo | Uso |
| --- | --- |
| `certificate_generate.sh` | Certificado auto-firmado local; el flujo normal HTTPS usa `compose/ssl.yml` |
| `globalproperties_envsubst.sh` | Sustitución de variables en propiedades OpenMRS |
| `init_full.sh` | Reinicialización de desarrollo; puede eliminar volúmenes |
| `logs_creation.sh` | Extraer logs del backend/initializer |
| `sihsalus-compose.service` | Arranque del stack con systemd |

## Servicio systemd

La unidad asume que el repositorio y su `.env` operativo viven en `/opt/sihsalus`. No mata procesos que estén usando el puerto 80: si existe un conflicto, `docker compose up` falla y systemd conserva el error para diagnóstico.

```bash
sudo install -d /opt/sihsalus
# Instala o actualiza el repositorio en /opt/sihsalus.
sudo cp scripts/utils/sihsalus-compose.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now sihsalus-compose.service
```

El archivo `/opt/sihsalus/.env` debe contener `COMPOSE_FILE` y `COMPOSE_PROFILES` del servidor. La unidad ejecuta `docker compose config --quiet` antes de iniciar y, por tanto, falla temprano si faltan secretos u overrides.

Comandos:

```bash
sudo systemctl status sihsalus-compose.service
sudo systemctl reload sihsalus-compose.service
sudo systemctl restart sihsalus-compose.service
sudo journalctl -u sihsalus-compose.service -f
```

Si la instalación usa otra ruta, crea un drop-in y reemplaza `WorkingDirectory`, `EnvironmentFile` y `ConditionPathExists`:

```bash
sudo systemctl edit sihsalus-compose.service
```

## Inicialización de desarrollo

`init_full.sh` puede detener el stack y eliminar volúmenes. Úsalo solo en entornos descartables y revisa su ayuda antes de ejecutarlo:

```bash
./scripts/utils/init_full.sh --help
```

Para producción, usa el [checklist de despliegue](../../docs/operations/deploy-checklist.md), no una reinicialización completa.

## Logs

```bash
./scripts/utils/logs_creation.sh
docker compose logs --tail 200 backend gateway
```

No adjuntes logs con datos clínicos, tokens o credenciales a issues públicos.
