# Database Scripts - Inicialización y Replicación

Scripts para inicializar y configurar replicación master-slave de MariaDB.

---

## Descripción

### Master-Slave Replication

SIHSALUS soporta replicación de base de datos MariaDB para:

- **Alta disponibilidad**: Si el master cae, el slave puede promoverse
- **Distribución de lectura**: Slave para reportes/búsquedas, Master para escrituras
- **Backup en vivo**: Backups sin detener el master

---

## Scripts

### `db_init_master.sh`

**Propósito**: Configuración inicial del servidor Master.

**Acciones**:
1. Crear usuario de replicación (`${OMRS_DB_REPL_USER}`)
2. Otorgar permisos de replicación
3. Crear usuario de backup (`${OMRS_DB_BACKUP_USER}`)
4. Mostrar estado del binlog (Master Status)

**Requisitos**:
- Container del master debe estar corriendo
- Variables de entorno:
  ```env
  MYSQL_ROOT_PASSWORD=<password_root>
  OMRS_DB_REPL_USER=repl_user
  OMRS_DB_REPL_PASSWORD=<password_seguro>
  OMRS_DB_BACKUP_USER=backup_user
  OMRS_DB_BACKUP_PASSWORD=<password_seguro>
  ```

**Ejecución**:
```bash
# Manual (si no se ejecutó automáticamente)
docker compose exec db bash -c "source scripts/database/db_init_master.sh"

# O via script
./scripts/database/db_init_master.sh
```

**Salida esperada**:
```
=== Showing replication status before initialization ===
+------------------+----------+--------------+------------------+-------------------+
| File             | Position | Binlog_Do_DB | Binlog_Ignore_DB | Executed_Gtid_Set |
+------------------+----------+--------------+------------------+-------------------+
| mysql-bin.000001 |      695 |              |                  |                   |
+------------------+----------+--------------+------------------+-------------------+
```

---

### `db_init_slave.sh`

**Propósito**: Configuración inicial del servidor Slave.

**Acciones**:
1. Conectar al Master (usando las credenciales de replicación)
2. Iniciar proceso de sincronización SLAVE
3. Mostrar estado de la replicación

**Requisitos**:
- Container del slave (replica) debe estar corriendo
- Master debe estar corriendo y configurado
- Variables de entorno:
  ```env
  MYSQL_ROOT_PASSWORD=<password_root>
  OMRS_DB_REPL_USER=repl_user
  OMRS_DB_REPL_PASSWORD=<password_seguro>
  ```

**Ejecución**:
```bash
# Manual
docker compose exec db-slave bash -c "source scripts/database/db_init_slave.sh"

# O via script
./scripts/database/db_init_slave.sh
```

**Salida esperada**:
```
=== Showing replication status before initialization ===
Slave_IO_Running: Yes
Slave_SQL_Running: Yes
Seconds_Behind_Master: 0
```

---

## Setup Completo de Replicación

### Paso 1: Preparar variables de entorno

```env
# En .env
MYSQL_ROOT_PASSWORD=RootSecure123!
MYSQL_OPENMRS_PASSWORD=OpenmrsPass456!

# Replicación
OMRS_DB_REPL_USER=repl_user
OMRS_DB_REPL_PASSWORD=ReplPass789!
OMRS_DB_BACKUP_USER=backup_user
OMRS_DB_BACKUP_PASSWORD=BackupPass012!
```

### Paso 2: Iniciar servicios

```bash
# Solo master (sitio principal)
docker compose up -d db

# O master + slave (para HA)
# Requiere docker-compose override con servicio replica
```

### Paso 3: Inicializar Master

```bash
docker compose exec db bash -c "
  mariadb -u root -p\${MYSQL_ROOT_PASSWORD} -e \"
    CREATE USER '\${OMRS_DB_REPL_USER}'@'%' IDENTIFIED BY '\${OMRS_DB_REPL_PASSWORD}';
    GRANT RELOAD, LOCK TABLES, PROCESS, REPLICATION SLAVE, BINLOG MONITOR ON *.* TO '\${OMRS_DB_REPL_USER}'@'%';
    CREATE USER '\${OMRS_DB_BACKUP_USER}'@'%' IDENTIFIED BY '\${OMRS_DB_BACKUP_PASSWORD}';
    GRANT RELOAD, PROCESS, LOCK TABLES, REPLICATION CLIENT, REPLICA MONITOR ON *.* TO '\${OMRS_DB_BACKUP_USER}'@'%';
    FLUSH PRIVILEGES;
    SHOW MASTER STATUS;
  \"
"
```

### Paso 4: Inicializar Slave (si existe)

```bash
docker compose exec db-slave bash -c "
  mariadb -u root -p\${MYSQL_ROOT_PASSWORD} -e \"
    CHANGE MASTER TO 
      MASTER_HOST='db',
      MASTER_USER='\${OMRS_DB_REPL_USER}',
      MASTER_PASSWORD='\${OMRS_DB_REPL_PASSWORD}',
      MASTER_PORT=3306;
    START SLAVE;
    SHOW SLAVE STATUS\G;
  \"
"
```

### Paso 5: Verificar replicación

```bash
# En el master
docker compose exec db mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "SHOW MASTER STATUS;"

# En el slave
docker compose exec db-slave mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "SHOW SLAVE STATUS\G;"
```

Campos importantes:
- `Seconds_Behind_Master: 0` - Sincronizado
- `Slave_IO_Running: Yes` - Conectado al master
- `Slave_SQL_Running: Yes` - Aplicando cambios

---

## Diagnóstico

### El slave no se sincroniza

```bash
# Ver estado detallado
docker compose exec db-slave mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "SHOW SLAVE STATUS\G;"

# Buscar errores
grep -i "error" /var/log/mysql/error.log

# Reiniciar replicación
docker compose exec db-slave mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
  STOP SLAVE;
  RESET SLAVE ALL;
  -- Luego ejecutar db_init_slave.sh
"
```

### Diferencia de datos entre master y slave

```bash
# Checksum en master
docker compose exec db mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
  CHECKSUM TABLE openmrs.*;
" > master_checksum.txt

# Checksum en slave
docker compose exec db-slave mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
  CHECKSUM TABLE openmrs.*;
" > slave_checksum.txt

# Comparar
diff master_checksum.txt slave_checksum.txt
```

### Replicación atrasada

```bash
# Ver qué comando está procesando
docker compose exec db-slave mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
  SHOW FULL PROCESSLIST;
"

# Ver binlog del slave
docker compose exec db-slave mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
  SHOW BINLOG EVENTS LIMIT 20;
"
```

---

## Mantenimiento

### Cambiar usuario de replicación

```bash
# En master
docker compose exec db mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
  ALTER USER 'repl_user'@'%' IDENTIFIED BY 'NewPassword123!';
  FLUSH PRIVILEGES;
"

# En slave
docker compose exec db-slave mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
  STOP SLAVE;
  CHANGE MASTER TO MASTER_PASSWORD='NewPassword123!';
  START SLAVE;
"
```

### Pausar replicación (para mantenimiento)

```bash
# Pausar
docker compose exec db-slave mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
  STOP SLAVE;
"

# Hacer cambios en slave

# Resumir
docker compose exec db-slave mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
  START SLAVE;
"
```

### Resetear slave

```bash
docker compose exec db-slave mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
  STOP SLAVE;
  RESET SLAVE ALL;
"

# Luego re-ejecutar db_init_slave.sh
```

---

## Backups

Los backups pueden hacerse desde el slave sin interrumpir el master:

```bash
# Backup del slave en vivo
docker compose exec db-slave bash -c "
  mariadb-backup \
    --user=backup_user \
    --password=\${OMRS_DB_BACKUP_PASSWORD} \
    --backup \
    --target-dir=/tmp/backup_$(date +%s)
"

# Copiar fuera del container
docker cp sihsalus-db-slave:/tmp/backup_* ./backups/
```

Ver [scripts/backup/README.md](../backup/README.md) para más opciones de backup.

---

## Producción: Configuración Recomendada

### Sitio Principal (Master)

```yaml
services:
  db-master:
    image: mariadb:10.11
    command: mariadbd
      --character-set-server=utf8mb4
      --server-id=1
      --log-bin=mysql-bin
      --binlog-format=ROW
      --sync-binlog=1
      --log-slave-updates
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_OPENMRS_PASSWORD: ${MYSQL_OPENMRS_PASSWORD}
```

### Sitio Secundario (Slave)

```yaml
services:
  db-slave:
    image: mariadb:10.11
    command: mariadbd
      --character-set-server=utf8mb4
      --server-id=2
      --log-bin=mysql-bin
      --binlog-format=ROW
      --skip-slave-start  # No iniciar replicación automáticamente
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_OPENMRS_PASSWORD: ${MYSQL_OPENMRS_PASSWORD}
    depends_on:
      db-master:
        condition: service_healthy
```

### Monitoreo Replicación

Agregar alertas Prometheus:

```yaml
- alert: ReplicationLag
  expr: mysql_slave_lag_seconds > 5
  for: 5m
  annotations:
    summary: "Replicación atrasada > 5 segundos"

- alert: ReplicationDown
  expr: mysql_slave_running == 0
  for: 1m
  annotations:
    summary: "Replicación no activa"
```

---

## Recuperación de desastres

### Master cae, promover slave

```bash
# En el slave
docker compose exec db-slave mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
  STOP SLAVE;
  RESET SLAVE ALL;
  -- Slave ahora es el nuevo master
"

# Apuntar OpenMRS al nuevo master
# Actualizar OMRS_CONFIG_CONNECTION_SERVER en .env
docker compose restart backend
```

### Master se recupera (se convierte en slave del ex-slave)

```bash
# Obtener posición binlog del nuevo master (ex-slave)
docker compose exec db-master mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "SHOW MASTER STATUS;"

# En el master viejo (ahora slave)
docker compose exec db mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
  CHANGE MASTER TO 
    MASTER_HOST='db-master-nuevo',
    MASTER_USER='repl_user',
    MASTER_PASSWORD='\${OMRS_DB_REPL_PASSWORD}',
    MASTER_LOG_FILE='mysql-bin.XXXXX',
    MASTER_LOG_POS=YYYYY;
  START SLAVE;
"
```

---

## Documentación oficial

- [MariaDB Replication](https://mariadb.com/kb/en/replication/)
- [MariaDB CHANGE MASTER TO](https://mariadb.com/kb/en/change-master-to/)
- [Binary Log](https://mariadb.com/kb/en/binary-log/)

## Scripts relacionados

- [Backup y Restore](../backup/README.md)
- [Inicialización completa del sistema](../utils/README.md)
