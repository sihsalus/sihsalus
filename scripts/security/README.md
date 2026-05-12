# Scripts/Security - Gestión de Secretos

Scripts para generar y gestionar secretos de seguridad (contraseñas, tokens, etc.).

---

## Scripts

### `secrets_generate.sh` - Generación de Secretos Seguros

**Propósito**: Genera contraseñas aleatorias criptográficamente seguras para todos los servicios.

⚠️ **IMPORTANTE**: Ejecutar **ANTES** de `docker compose up` en producción.

**Uso**:
```bash
./secrets_generate.sh
```

**Salida**: Crea directorio `secrets/` con archivos de texto conteniendo contraseñas:

```
secrets/
├── keycloak_admin_password.txt
├── keycloak_db_password.txt
├── grafana_admin_password.txt
├── mysql_root_password.txt
├── mysql_openmrs_password.txt
├── mysql_repl_password.txt
├── mysql_backup_password.txt
├── fua_db_password.txt
├── fua_token.txt
└── pihole_password.txt
```

**Seguridad**:
- Permisos restrictivos: `600` (solo lectura para el propietario)
- Directorio protegido: `700` (solo propietario puede acceder)
- Generadas con OpenSSL (cryptographically secure)
- 32 caracteres alfanuméricos

**Requisitos**:
- `openssl` instalado
- Permisos de escritura en directorio actual

---

## Flujo de inicialización segura (Producción)

### Paso 1: Generar secretos

```bash
# En el directorio raíz del proyecto
./scripts/security/secrets_generate.sh

# Verificar que se crearon
ls -la secrets/
```

### Paso 2: Cargar secretos en .env

```bash
# Crear .env desde template
cp .env.template .env

# Cargar secretos en .env
cat secrets/mysql_root_password.txt > MYSQL_ROOT_PASSWORD_VALUE
cat secrets/mysql_openmrs_password.txt > MYSQL_OPENMRS_PASSWORD_VALUE
# ... etc para todos

# Editar .env manualmente
nano .env

# Agregar:
MYSQL_ROOT_PASSWORD=$(cat secrets/mysql_root_password.txt)
MYSQL_OPENMRS_PASSWORD=$(cat secrets/mysql_openmrs_password.txt)
KEYCLOAK_ADMIN_PASSWORD=$(cat secrets/keycloak_admin_password.txt)
KEYCLOAK_DB_PASSWORD=$(cat secrets/keycloak_db_password.txt)
GRAFANA_ADMIN_PASSWORD=$(cat secrets/grafana_admin_password.txt)
# ... etc
```

### Paso 3: Usar Docker Secrets (Recomendado para Swarm/K8s)

```bash
# Crear secretos en Docker
for file in secrets/*.txt; do
  secret_name=$(basename "$file" .txt)
  docker secret create "$secret_name" "$file"
done

# En docker-compose.yml:
services:
  db:
    environment:
      MYSQL_ROOT_PASSWORD_FILE: /run/secrets/mysql_root_password
    secrets:
      - mysql_root_password
      
secrets:
  mysql_root_password:
    external: true
```

---

## Best Practices

### ✅ Haz esto

1. **Generar secretos antes de producción**
   ```bash
   ./scripts/security/secrets_generate.sh
   ```

2. **Mantener archivos en `secrets/` fuera de git**
   ```bash
   echo "secrets/" >> .gitignore
   ```

3. **Usar Docker Secrets o secretos del SO**
   ```bash
   # NO en variables de entorno planas
   # SÍ en /run/secrets (Docker Secrets)
   # SÍ en variables de entorno cifradas
   ```

4. **Rotar contraseñas regularmente**
   ```bash
   # Generar nuevas
   ./scripts/security/secrets_generate.sh
   
   # Actualizar servicios
   docker compose restart <servicio>
   ```

5. **Auditar acceso a secretos**
   ```bash
   # Logs de Docker
   docker logs <container> | grep password
   
   # NO debe haber passwords en logs
   ```

6. **Backup encriptado de secretos**
   ```bash
   tar czf secrets.tar.gz secrets/
   openssl enc -aes-256-cbc -in secrets.tar.gz -out secrets.tar.gz.enc
   ```

---

### ❌ No hagas esto

1. **Hardcodear contraseñas en código**
   ```bash
   # ❌ MAL
   MYSQL_PASSWORD="password123"
   
   # ✅ BIEN
   MYSQL_PASSWORD=${MYSQL_PASSWORD}  # Variable del entorno
   ```

2. **Commitear `secrets/` a git**
   ```bash
   # .gitignore debe incluir:
   secrets/
   .env*
   ```

3. **Usar contraseñas débiles o predecibles**
   ```bash
   # ❌ MAL
   KEYCLOAK_ADMIN_PASSWORD=admin123
   
   # ✅ BIEN
   # Usar script de generación
   ./scripts/security/secrets_generate.sh
   ```

4. **Compartir secretos por email/chat sin encriptar**
   ```bash
   # Siempre encriptar antes de compartir
   gpg --symmetric secrets.tar.gz
   ```

5. **Olvidar cambiar contraseñas por defecto**
   ```bash
   # Siempre reemplazar valores por defecto
   KEYCLOAK_ADMIN_PASSWORD → Generar nuevo
   GRAFANA_ADMIN_PASSWORD → Generar nuevo
   ```

---

## Recuperación de secretos olvidados

Si pierdes los secretos, puedes regenerarlos:

```bash
# OPCIÓN 1: Regenerar y reinicializar
./scripts/security/secrets_generate.sh
./scripts/utils/init_full.sh -m production

# OPCIÓN 2: Cambiar contraseña sin reinicializar
# MariaDB
docker compose exec db mariadb -u root -pOLDPASS -e "
  ALTER USER 'openmrs'@'%' IDENTIFIED BY 'NEWPASS';
  FLUSH PRIVILEGES;
"

# Keycloak
docker compose exec keycloak /opt/keycloak/bin/kc.sh \
  change-admin-password --new-password NEWPASS

# Grafana
docker compose exec grafana grafana-cli admin \
  reset-admin-password NEWPASS
```

---

## Gestión de secretos en diferentes ambientes

### Desarrollo

```bash
# Usar .env.development con secretos generados localmente
./scripts/security/secrets_generate.sh
export $(cat .env.development | xargs)
docker compose up
```

### Producción

```bash
# Usar variables de entorno del SO o Docker Secrets
export MYSQL_ROOT_PASSWORD=$(cat /secure/mysql_root_password)
export KEYCLOAK_ADMIN_PASSWORD=$(cat /secure/keycloak_admin_password)
# ...
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

### Staging

```bash
# Usar .env.staging (nunca commitear)
cp .env.template .env.staging
./scripts/security/secrets_generate.sh
# Copiar secretos a .env.staging
docker compose --env-file .env.staging up
```

---

## Integración con CI/CD

### GitHub Actions

```yaml
- name: Generar secretos
  run: ./scripts/security/secrets_generate.sh

- name: Cargar secretos en GitHub
  env:
    MYSQL_ROOT_PASSWORD: ${{ secrets.MYSQL_ROOT_PASSWORD }}
    KEYCLOAK_ADMIN_PASSWORD: ${{ secrets.KEYCLOAK_ADMIN_PASSWORD }}
  run: |
    echo "MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD" >> $GITHUB_ENV
    docker compose up
```

### GitLab CI

```yaml
secrets:
  variables:
    MYSQL_ROOT_PASSWORD: $MYSQL_ROOT_PASSWORD
    KEYCLOAK_ADMIN_PASSWORD: $KEYCLOAK_ADMIN_PASSWORD
```

---

## Auditoría y Compliance

### Verificar exposición de secretos

```bash
# Buscar passwords en logs
docker compose logs | grep -i "password"

# Buscar en archivos
grep -r "password" . --exclude-dir=.git --exclude-dir=node_modules

# Buscar en Git history (si ya fueron commiteados)
git log -S "password" --all
```

### Rotar credenciales periódicamente

```bash
# Crear cron para rotación mensual
0 0 1 * * cd /home/openmrs/sihsalus && \
  ./scripts/security/secrets_generate.sh && \
  docker compose restart backend db keycloak
```

---

## Recuperación de desastres

### Backup encriptado de secretos

```bash
#!/bin/bash
# backup-secrets.sh

# Crear backup
tar czf secrets-$(date +%Y%m%d).tar.gz secrets/

# Encriptar
gpg --symmetric --cipher-algo AES256 secrets-*.tar.gz

# Subir a almacenamiento seguro
# (S3, Azure Blob, Google Cloud Storage, etc.)
```

### Restore de secretos

```bash
# Descargar
aws s3 cp s3://backup-bucket/secrets-20260111.tar.gz.gpg .

# Desencriptar
gpg --decrypt secrets-20260111.tar.gz.gpg > secrets-20260111.tar.gz

# Restaurar
tar xzf secrets-20260111.tar.gz
./scripts/security/secrets_generate.sh  # Regenerar para actualización
```

---

## Integración con Vault (Enterprise)

Para deployments empresariales, considera Hashicorp Vault:

```bash
# Instalar cliente
apt-get install vault

# Login a Vault
vault login -method=ldap username=admin

# Leer secreto
MYSQL_PASSWORD=$(vault kv get -field=password secret/data/mysql)

# Usar en docker-compose
export MYSQL_PASSWORD=$(vault kv get -field=password secret/data/mysql)
docker compose up
```

---

## Links y recursos

- [OWASP: Secrets Management](https://owasp.org/www-project-devsecops-guideline/)
- [Docker Secrets Documentation](https://docs.docker.com/engine/swarm/secrets/)
- [HashiCorp Vault](https://www.vaultproject.io/)
- [OpenSSL Documentation](https://www.openssl.org/docs/)
- [NIST: Password Guidelines](https://pages.nist.gov/800-63-3/sp800-63b.html)

---

## Scripts relacionados

- [Database Scripts](../database/README.md)
- [Utilidades](../utils/README.md)
- [Backup Scripts](../backup/README.md)
