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

El restore detiene y vuelve a iniciar únicamente `backend`; no reconcilia `gateway`, por lo que no elimina el override HTTPS.

Para automatización o cuando otro runbook controla la aplicación:

```bash
./scripts/backup/restore_dump.sh \
  --file /ruta/backups/dump_FECHA.sql.gz.enc \
  --yes \
  --no-app-control
```

## Backup físico

```bash
./scripts/backup/backup_full.sh --dir /ruta/backups --max 10
./scripts/backup/restore_full.sh --file /ruta/backups/backup_FECHA.tar.gz.enc
```

Para ejecutar el backup físico sobre la réplica:

```bash
./scripts/backup/backup_full.sh --container sihsalus-db-replic --dir /ruta/backups
```

`restore_full.sh` detecta el volumen real montado en `/var/lib/mysql`, crea un snapshot temporal, restaura y levanta solo `db` y `backend`. Puede recibir `DB_VOLUME` explícitamente si el contenedor de base de datos no existe.

## Prueba automatizada

```bash
./tests/backup/dump-roundtrip.sh
```

La prueba inicia una MariaDB efímera, inserta datos, crea un dump cifrado, muta la tabla, restaura y verifica el valor original. CI la ejecuta cuando cambian los scripts o la propia prueba.

## Regla operativa

Un backup no se considera válido hasta verificar al menos checksum, descifrado y restore. Programa un restore periódico con datos no clínicos o en un ambiente aislado.
