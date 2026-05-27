# Backup y Restore

Scripts para respaldar y restaurar la base **PostgreSQL** del backend `sihsalus-core`.

## Scripts disponibles

| Script | Tipo | Downtime | Descripcion |
|--------|------|----------|-------------|
| `backup_dump.sh` | Lógico (caliente) | No | `pg_dump` en formato custom (`.dump`, comprimido) |
| `restore_dump.sh` | Lógico (caliente) | Solo backend | Restaura un `.dump` con `pg_restore --clean` |
| `backup_all.sh` | Sistema completo | No | DB + Keycloak + Orthanc + Prometheus + Grafana + configs |

## Uso rapido

```bash
# Backup del backend
./scripts/backup/backup_dump.sh

# Restore interactivo (lista dumps disponibles)
./scripts/backup/restore_dump.sh

# Restore directo
./scripts/backup/restore_dump.sh --file ~/sihsalus-dumps/dump_2026-05-27.dump
```

## Opciones comunes

```
--container NOMBRE    Contenedor PostgreSQL (default: sihsalus-postgres)
--dir DIRECTORIO      Directorio de backups (default: ~/sihsalus-dumps)
--file ARCHIVO        Archivo especifico (omitir para seleccion interactiva)
--max N               Maximo de backups a retener (solo backup_dump.sh)
```

## Variables de entorno

Los scripts toman la conexión del mismo `.env` del stack:

```env
SIHSALUS_POSTGRES_DB=sihsalus
SIHSALUS_POSTGRES_USER=sihsalus
SIHSALUS_POSTGRES_PASSWORD=<password>   # obligatorio
```

## Cifrado

Los backups se cifran con AES-256 si la variable `BACKUP_ENCRYPTION_PASSWORD` está definida.
El restore descifra automáticamente archivos `.enc` (pide la clave si no está en el entorno).

## Notas

- `pg_dump --format=custom` produce un dump consistente por snapshot (sin bloquear
  escrituras) y ya comprimido; no necesita `gzip`.
- `restore_dump.sh` usa `pg_restore --clean --if-exists`, por lo que es idempotente
  sobre una base existente. Detiene el backend durante la carga para evitar conflictos.
