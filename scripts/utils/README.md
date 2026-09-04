# Utilidades operativas

## Inventario

| Archivo | Uso |
| --- | --- |
| `certificate_generate.sh` | Certificado auto-firmado local; el flujo normal HTTPS usa `compose/ssl.yml` |
| `init_full.sh` | Reinicialización de desarrollo; puede eliminar volúmenes |
| `logs_creation.sh` | Extraer logs del backend/initializer |
| `sihsalus-compose.service` | Arranque del stack con systemd |
| `viewpower.service` | Arranque persistente y aislamiento de red para el controlador local de la UPS |
| `sihsalus-safe-poweroff.sh` | Evaluador fail-closed de apagado automático |
| `sihsalus-safe-poweroff.{service,timer}` | Ejecución y sondeo systemd del evaluador |

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

## Controlador UPS ViewPower

El instalador de ViewPower 1.04-21353 no reconoce Ubuntu 24.04 como una versión
con systemd y su alternativa depende de un inicio de sesión interactivo. En el
servidor de producción se usa `viewpower.service`: mantiene `StartMain` dentro
de un cgroup, lo reinicia si falla y ejecuta `StopMain` durante una parada
ordenada.

La interfaz HTTP de esa versión no requiere autenticación. La unidad la limita
a localhost y a la subred del bridge de monitoreo. Confirma primero la subred
real; si no es `172.19.0.0/24`, modifica `IPAddressAllow` antes de instalar:

```bash
docker network inspect sihsalus_monitoring-network \
  --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
sudo install -m 0644 scripts/utils/viewpower.service /etc/systemd/system/
sudo systemd-analyze verify /etc/systemd/system/viewpower.service
sudo systemctl daemon-reload
sudo systemctl enable --now viewpower.service
```

Valida el proceso, la API local y la telemetría después de cada cambio:

```bash
systemctl is-enabled viewpower.service
systemctl is-active viewpower.service
curl --fail http://127.0.0.1:15178/ViewPower/ >/dev/null
curl --fail http://127.0.0.1:9090/api/v1/query?query=sihsalus_ups_exporter_up
```

No ejecutes `runAutoStart.sh` en paralelo con esta unidad. ViewPower debe correr
como `root` porque controla el USB y ejecuta el apagado limpio configurado en la
reserva de batería; el exporter de Prometheus sigue siendo de solo lectura.

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

## Apagado automático

No programes `shutdown` directamente en cron. El mecanismo versionado exige
ventana local explícita, heartbeat del SPA, ausencia de conexiones activas,
gracia de arranque, inhibidor operativo y una segunda comprobación. Se entrega
deshabilitado y en dry-run; la instalación y aceptación están en el
[runbook de apagado seguro](../../docs/operations/safe-poweroff.md).
