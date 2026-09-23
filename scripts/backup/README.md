# Backup y restore MariaDB

Los scripts canónicos son:

| Script | Formato | Uso |
| --- | --- | --- |
| `backup_dump.sh` | SQL gzip, opcionalmente cifrado | Backup frecuente en caliente |
| `restore_dump.sh` | SQL gzip, opcionalmente cifrado | Restore lógico con backend detenido |
| `backup_full.sh` | `mariadb-backup`, siempre cifrado | Backup físico para recuperación completa |
| `restore_full.sh` | `mariadb-backup` | Restore físico con snapshot previo del volumen |

## Requisitos de producción

```env
MYSQL_ROOT_PASSWORD=<password-root>
BACKUP_ENCRYPTION_PASSWORD=<clave-independiente>
```

Para backup físico se recomienda el usuario dedicado:

```env
OMRS_DB_BACKUP_USER=openmrs_backup
OMRS_DB_BACKUP_PASSWORD=<password-seguro>
```

No guardes `BACKUP_ENCRYPTION_PASSWORD` dentro del repositorio ni junto al backup cifrado.

## Dump lógico

```bash
./scripts/backup/backup_dump.sh --dir /ruta/backups --max 10
./scripts/backup/restore_dump.sh --file /ruta/backups/dump_FECHA.sql.gz.enc
```

Antes de detener el backend o modificar la base, el restore descifra y
descomprime el archivo completo en un directorio temporal privado. Rechaza un
gzip inválido, truncado o vacío. Reserva espacio para el SQL descomprimido y,
si hay cifrado, también para su gzip; `TMPDIR` permite elegir el disco temporal.
Los temporales se eliminan al salir.

Después comprueba que exista un contenedor `backend` en el proyecto Compose,
incluidos los detenidos. Si falta o falla esa consulta, aborta sin tocar la base.
Luego lo detiene y comprueba que no siga ejecutándose. Si falla la parada o la
comprobación, también aborta antes de borrar la base. Importa los bytes ya
validados y, solo si termina correctamente, usa `docker compose start backend`
para reanudar el mismo contenedor, imagen y configuración. Una importación SQL
fallida deja el backend detenido y requiere recuperación antes de reabrirlo.

La validación del gzip no prueba que el SQL sea aplicable ni crea un respaldo
previo de la base destino. Confirmar el backup de recuperación y probar el dump
en una base aislada antes de una restauración operativa.

Para automatización o cuando otro runbook controla la aplicación:

```bash
./scripts/backup/restore_dump.sh \
  --file /ruta/backups/dump_FECHA.sql.gz.enc \
  --yes \
  --no-app-control
```

`--no-app-control` mantiene la validación del dump, pero delega por completo la
parada y el arranque al operador. `--yes` solo omite la confirmación interactiva.
Para recuperar un host donde todavía no existe el contenedor backend, usar
`--no-app-control` con la base disponible y la aplicación fuera de servicio;
crear y arrancar el backend por separado tras completar la importación, usando
la composición y las imágenes revisadas del entorno.

## Backup físico

El script exige las credenciales y la clave de cifrado antes de acceder a Docker
o modificar respaldos y logs. Los archivos nuevos se crean con permisos privados.

```bash
./scripts/backup/backup_full.sh --dir /ruta/backups --max 10
./scripts/backup/restore_full.sh --file /ruta/backups/backup_FECHA.tar.gz.enc
```

Para ejecutar el backup físico sobre la réplica:

```bash
./scripts/backup/backup_full.sh --container sihsalus-db-replic --dir /ruta/backups
```

`restore_full.sh` detecta el volumen real montado en `/var/lib/mysql`, crea un snapshot temporal, restaura y levanta solo `db` y `backend`. Puede recibir `DB_VOLUME` explícitamente si el contenedor de base de datos no existe.

## Verificación de restauración

Las regresiones locales de parada, integridad del archivo, importación y
reinicio usan Docker simulado y forman parte de `bash tests/run.sh`.

El workflow independiente `Backup and restore drills` comprueba semanalmente
dump cifrado, semillas, restauración física y recuperación del snapshot ante
fallo. También admite ejecución manual. Consulta la
[comprobación de restauración](../../docs/operations/physical-backup-drill.md)
y registra resultado, versiones, checksum y fecha.

## Regla operativa

Un backup no se considera válido hasta verificar al menos checksum, descifrado y restore. Programa un restore periódico con datos no clínicos o en un ambiente aislado.
