# MariaDB: inicialización y réplica

El core usa MariaDB como servicio `db`. El profile opcional `replica` agrega `db-replic` como réplica read-only mediante GTID.

La réplica mejora recuperación y permite ejecutar backups fuera del master, pero no implementa failover, promoción automática ni alta disponibilidad por sí sola.

## Servicios y scripts

| Recurso | Función |
| --- | --- |
| `db` | MariaDB principal, server ID 1 |
| `db-replic` | Réplica read-only, server ID 2 |
| `db_init_master.sh` | Crea usuarios de replicación y backup durante la primera inicialización |
| `db_init_slave.sh` | Configura GTID y conecta `db-replic` con `db` durante la primera inicialización |
| `db_replica_entrypoint.sh` | Verifica variables requeridas antes de iniciar la réplica |

Los scripts bajo `/docker-entrypoint-initdb.d` solo se ejecutan cuando el volumen de datos está vacío. Cambiar variables después no modifica usuarios existentes automáticamente.

## Variables

```env
MYSQL_ROOT_PASSWORD=<password-seguro>
OMRS_DB_REPL_USER=openmrs_repl
OMRS_DB_REPL_PASSWORD=<password-seguro>
OMRS_DB_BACKUP_USER=openmrs_backup
OMRS_DB_BACKUP_PASSWORD=<password-seguro>
```

`MYSQL_ROOT_PASSWORD` y `OMRS_DB_REPL_PASSWORD` son obligatorias al activar `replica`. El usuario de backup solo se crea cuando usuario y contraseña están definidos.

## Despliegue nuevo

```bash
docker compose --profile replica config --quiet
docker compose --profile replica up -d
docker compose --profile replica ps
```

Verifica el estado sin interpolar la contraseña en el host:

```bash
docker compose --profile replica exec db-replic sh -lc \
  'mariadb --user=root --password="$MYSQL_ROOT_PASSWORD" --execute="SHOW SLAVE STATUS\\G"'
```

Las señales esperadas son:

```text
Slave_IO_Running: Yes
Slave_SQL_Running: Yes
Seconds_Behind_Master: 0
```

## Agregar una réplica a un master con datos

No inicies una réplica vacía contra un master clínico existente. El procedimiento seguro es:

1. Crear un backup consistente del master.
2. Restaurarlo en el volumen `db-replica-data`.
3. Conservar la posición GTID incluida en el backup.
4. Iniciar el profile `replica`.
5. Confirmar ambos threads y ausencia de errores antes de usarla para backups.

Los scripts de backup y restore están documentados en [backup/README.md](../backup/README.md).

## Diagnóstico

```bash
# Estado del master
docker compose exec db sh -lc \
  'mariadb --user=root --password="$MYSQL_ROOT_PASSWORD" --execute="SHOW MASTER STATUS"'

# Estado completo de la réplica
docker compose --profile replica exec db-replic sh -lc \
  'mariadb --user=root --password="$MYSQL_ROOT_PASSWORD" --execute="SHOW SLAVE STATUS\\G"'

# Logs
docker compose --profile replica logs --tail 200 db db-replic
```

Revisa primero `Last_IO_Error`, `Last_SQL_Error`, conectividad DNS hacia `db` y que las credenciales coincidan con el usuario creado en el master.

## Recuperación

La promoción de `db-replic` no está automatizada. Requiere una ventana de incidente, verificación de integridad, actualización del endpoint usado por OpenMRS y un plan para resincronizar el antiguo master. No uses comandos genéricos de `RESET SLAVE` en producción sin registrar previamente GTID, backup y plan de rollback.

## Seguridad

- No pases contraseñas directamente en la línea de comandos del host.
- Mantén MariaDB sin puertos publicados; los servicios se conectan mediante DNS de Compose.
- Usa credenciales distintas por ambiente.
- Verifica periódicamente un restore, no solo la creación del backup.

Referencias: [MariaDB replication](https://mariadb.com/kb/en/standard-replication/) y [GTID](https://mariadb.com/kb/en/gtid/).
