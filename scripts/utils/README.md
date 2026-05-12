# Scripts/Utils - Utilidades Generales

Scripts de utilidad para inicialización, configuración y mantenimiento del sistema.

---

## Scripts

### `init_full.sh` - Inicialización Completa del Sistema

**Propósito**: Elimina todos los datos, volúmenes y contenedores, e inicia desde cero.

⚠️ **DESTRUCTIVO**: Borra toda la base de datos y configuración. Usar solo en desarrollo o como último recurso.

**Uso**:
```bash
./init_full.sh -m [production|development] [-d DIRECTORIO]
```

**Opciones**:
- `-m production|development` - Modo de operación (requerido)
- `-d DIRECTORIO` - Ruta a docker-compose (default: `../`)

**Ejemplos**:
```bash
# Inicialización de desarrollo
./init_full.sh -m development

# Inicialización de producción
./init_full.sh -m production -d /home/openmrs/sihsalus

# Log de salida
tail -f fullInit_log.txt
```

**Pasos que ejecuta**:
1. Detiene todos los contenedores (`docker compose down`)
2. Elimina todos los volúmenes (`docker compose down -v`)
3. Construye las imágenes
4. Inicia la pila completa
5. Guarda log en `fullInit_log.txt`

**Requisitos**:
- `docker` y `docker compose` instalados
- Permisos de `sudo`
- `.env` configurado

---

### `certificate_generate.sh` - Generación de Certificados SSL

**Propósito**: Genera certificados SSL auto-firmados para desarrollo.

**Uso**:
```bash
./certificate_generate.sh
```

**Configurable**:
```bash
CERT_NAME="sihsalus-certificate"
DAYS_VALID=365
KEY_SIZE=2048
SERVER_IP=192.168.0.200
SSL_DIR="../gateway/ssl"
```

**Salida**:
- `gateway/ssl/sihsalus-certificate.key` - Clave privada
- `gateway/ssl/sihsalus-certificate.crt` - Certificado público

**Certificate info**:
- **Validez**: 365 días
- **Algoritmo**: RSA 2048 bits
- **Domains**: 
  - localhost
  - openmrs.sihsalus.hsc
  - 127.0.0.1
  - 192.168.0.200

**Uso en docker-compose**:
```yaml
gateway:
  volumes:
    - ./gateway/ssl:/etc/nginx/ssl:ro
```

---

### `logs_creation.sh` - Obtención de Logs de Initializer

**Propósito**: Extrae y muestra logs del módulo Initializer de OpenMRS.

**Uso**:
```bash
./logs_creation.sh
```

**Salida**:
- Logs de inicialización de OpenMRS
- Información de carga de módulos
- Errores de configuración

**Útil para**:
- Debugging de startup
- Verificar que la configuración se cargó correctamente
- Problemas con módulos

---

### `globalproperties_envsubst.sh` - Template Engine

**Propósito**: Procesa variables de entorno en archivos de configuración.

**Uso**:
```bash
./globalproperties_envsubst.sh
```

**Función**: 
Reemplaza todas las variables `${VAR_NAME}` en archivos `.properties` con sus valores del entorno.

**Ejemplo**:
```properties
# Entrada (globalproperties.template)
openmrs.db.username=${OMRS_DB_USER}
openmrs.db.password=${MYSQL_OPENMRS_PASSWORD}
oauth2.clientSecret=${OAUTH2_CLIENT_SECRET}

# Salida (globalproperties)
openmrs.db.username=openmrs
openmrs.db.password=SecurePass123!
oauth2.clientSecret=AbcDef123456789
```

---

### `docker-compose-app.service` - Systemd Service

**Propósito**: Archivo de servicio systemd para ejecutar docker-compose como servicio del SO.

**Instalación**:
```bash
# Copiar a systemd
sudo cp docker-compose-app.service /etc/systemd/system/

# Recargar systemd
sudo systemctl daemon-reload

# Habilitar en boot
sudo systemctl enable docker-compose-app.service

# Iniciar manualmente
sudo systemctl start docker-compose-app.service
```

**Comandos**:
```bash
# Ver estado
sudo systemctl status docker-compose-app.service

# Ver logs
sudo journalctl -u docker-compose-app.service -f

# Reiniciar
sudo systemctl restart docker-compose-app.service

# Detener
sudo systemctl stop docker-compose-app.service
```

**Configuración**:
Edita el archivo `.service` para cambiar:
- `WorkingDirectory` - Ruta a docker-compose
- `ExecStart` - Comando a ejecutar
- `User` - Usuario del servicio

---

## Flujo de inicialización típico

### Desarrollo

```bash
# 1. Copiar template
cp .env.template .env

# 2. Editar .env con valores
nano .env

# 3. Generar certificados (si necesitas SSL)
./scripts/utils/certificate_generate.sh

# 4. Iniciar sistema completo desde cero
./scripts/utils/init_full.sh -m development

# 5. Esperar a que OpenMRS esté listo
docker compose logs -f backend | grep "started"

# 6. Acceder a OpenMRS
open http://localhost/openmrs/spa

# 7. Ver logs de initializer
./scripts/utils/logs_creation.sh
```

### Producción

```bash
# 1. Generar secrets
./scripts/security/secrets_generate.sh

# 2. Crear .env desde .env.template
cp .env.template .env.production
# Editar con secretos de producción

# 3. Generar certificados Let's Encrypt
# Ver compose/ssl.yml

# 4. Inicializar en modo producción
./scripts/utils/init_full.sh -m production

# 5. Instalar systemd service para auto-start
sudo cp ./scripts/utils/docker-compose-app.service /etc/systemd/system/
sudo systemctl enable docker-compose-app.service
sudo systemctl start docker-compose-app.service

# 6. Monitorear
sudo journalctl -u docker-compose-app.service -f
```

---

## Solución de problemas

### init_full.sh falla

**Error**: `docker compose not found`
- Solución: Instalar docker-compose v2 o superior

**Error**: Permission denied
- Solución: Usar `sudo`, o agregar usuario a grupo docker: `sudo usermod -aG docker $USER`

**Error**: Volume already exists
- Solución: Eliminar manual: `docker volume rm nombre_volumen`

### Certificados inválidos

```bash
# Verificar certificado
openssl x509 -text -noout -in gateway/ssl/sihsalus-certificate.crt

# Renovar
./scripts/utils/certificate_generate.sh
docker compose restart gateway
```

### Variables no se substituyen

```bash
# Verificar variables cargadas
env | grep -i omrs

# Ejecutar template engine
./scripts/utils/globalproperties_envsubst.sh

# Verificar salida
cat openmrs/globalproperties
```

---

## Variables de Entorno Requeridas

Para que los scripts funcionen correctamente, asegúrate de que `.env` contiene:

```env
# Database
MYSQL_ROOT_PASSWORD=<password>
MYSQL_OPENMRS_PASSWORD=<password>

# OpenMRS
OMRS_CONFIG_CONNECTION_USERNAME=openmrs
OMRS_CONFIG_CONNECTION_DATABASE=openmrs
OMRS_OCL_TOKEN=<token>

# OAuth2/Keycloak (si usas auth)
OAUTH2_CLIENT_SECRET=<secret>
KEYCLOAK_ADMIN_PASSWORD=<password>

# Replicación (si usas HA)
OMRS_DB_REPL_USER=repl_user
OMRS_DB_REPL_PASSWORD=<password>
OMRS_DB_BACKUP_USER=backup_user
OMRS_DB_BACKUP_PASSWORD=<password>

# Grafana (si usas monitoring)
GRAFANA_ADMIN_PASSWORD=<password>
```

Ver [.env.template](../../.env.template) para la lista completa.

---

## Links relacionados

- [Database Scripts](../database/README.md)
- [Security Scripts](../security/README.md)
- [Backup Scripts](../backup/README.md)
- [Systemd Manual](https://www.freedesktop.org/software/systemd/man/systemd.service.html)

