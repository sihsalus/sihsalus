# Scripts/Security - Gestion de Secretos

Scripts para generar y gestionar credenciales locales de SIHSALUS.

El stack actual de Docker Compose consume variables de entorno planas desde `.env` o `--env-file`. No usa Docker secrets ni variables `*_FILE`.

---

## Scripts

### `secrets_generate.sh` - Generacion de Secretos Seguros

**Proposito**: genera contrasenas y tokens aleatorios para el core y los profiles opcionales, y crea un `.env.production` listo para Docker Compose.

**Uso**:

```bash
./scripts/security/secrets_generate.sh
```

**Salida**:

```text
secrets/
├── sihsalus_postgres_password.txt
├── sihsalus_admin_password.txt
├── keycloak_admin_password.txt
├── keycloak_db_password.txt
├── oauth2_client_secret.txt
├── grafana_admin_password.txt
├── fua_db_password.txt
├── fua_token.txt
└── hapi_db_password.txt

.env.production
```

**Seguridad**:

- Directorio `secrets/` con permisos `700`.
- Archivos de secretos con permisos `600`.
- Valores generados con `openssl rand`.
- `.env.production` contiene secretos en texto plano y no debe commitearse.

**Requisitos**:

- `openssl` instalado.
- Permisos de escritura en el directorio raiz del proyecto.

---

## Flujo de inicializacion segura

### Paso 1: Generar secretos

```bash
./scripts/security/secrets_generate.sh
```

### Paso 2: Revisar `.env.production`

El archivo generado usa los nombres que consume el compose actual:

```env
SIHSALUS_POSTGRES_DB=sihsalus
SIHSALUS_POSTGRES_USER=sihsalus
SIHSALUS_POSTGRES_PASSWORD=<generado>
SIHSALUS_ADMIN_USERNAME=admin
SIHSALUS_ADMIN_PASSWORD=<generado>
```

Tambien incluye credenciales generadas para profiles opcionales:

```env
KEYCLOAK_ADMIN_PASSWORD=<generado>
KC_DB_PASSWORD=<generado>
OAUTH2_CLIENT_SECRET=<generado>
GRAFANA_ADMIN_PASSWORD=<generado>
SIHSALUS_FUA_GEN_DB_PASSWORD=<generado>
SIHSALUS_FUA_GEN_TOKEN=<generado>
HAPI_DB_PASSWORD=<generado>
```

### Paso 3: Iniciar con el env file generado

```bash
docker compose --env-file .env.production up -d
```

Tambien puedes usar el flujo por defecto de Docker Compose:

```bash
cp .env.production .env
docker compose up -d
```

---

## Best Practices

### Haz esto

1. **Generar secretos antes de produccion**
   ```bash
   ./scripts/security/secrets_generate.sh
   ```

2. **Mantener `secrets/` y `.env*` fuera de git**
   ```bash
   git check-ignore secrets/ .env.production
   ```

3. **Usar gestores de secretos para operar**
   ```bash
   export SIHSALUS_POSTGRES_PASSWORD="$(vault kv get -field=password secret/data/sihsalus/postgres)"
   export SIHSALUS_ADMIN_PASSWORD="$(vault kv get -field=password secret/data/sihsalus/admin)"
   docker compose up -d
   ```

4. **Rotar credenciales con control**
   ```bash
   ./scripts/security/secrets_generate.sh
   docker compose --env-file .env.production up -d
   ```

5. **Auditar que no se filtren passwords**
   ```bash
   docker compose logs | grep -i "password"
   ```

6. **Respaldar secretos cifrados**
   ```bash
   tar czf secrets.tar.gz secrets/ .env.production
   openssl enc -aes-256-cbc -salt -in secrets.tar.gz -out secrets.tar.gz.enc
   ```

### No hagas esto

1. **Hardcodear contrasenas en codigo**
   ```bash
   # Mal
   SIHSALUS_POSTGRES_PASSWORD=password123

   # Bien
   SIHSALUS_POSTGRES_PASSWORD=${SIHSALUS_POSTGRES_PASSWORD}
   ```

2. **Commitear secretos**
   ```gitignore
   secrets/
   .env
   .env.*
   ```

3. **Usar valores por defecto en produccion**
   ```env
   SIHSALUS_POSTGRES_PASSWORD=sihsalus
   SIHSALUS_ADMIN_PASSWORD=Admin123
   ```

4. **Compartir secretos sin cifrar**
   ```bash
   gpg --symmetric secrets.tar.gz
   ```

---

## Recuperacion de secretos olvidados

Si pierdes los secretos, puedes regenerarlos:

```bash
./scripts/security/secrets_generate.sh
```

Si la base de datos ya existe y solo quieres cambiar la contrasena del usuario PostgreSQL:

```bash
docker compose exec db psql -U sihsalus -d sihsalus -c \
  "ALTER USER sihsalus WITH PASSWORD 'NEWPASS';"
```

Luego actualiza `SIHSALUS_POSTGRES_PASSWORD` en `.env` o `.env.production` y reinicia los servicios que dependen de la base de datos:

```bash
docker compose up -d db backend
```

Otros servicios:

```bash
# Keycloak
docker compose exec keycloak /opt/keycloak/bin/kc.sh \
  change-admin-password --new-password NEWPASS

# Grafana
docker compose exec grafana grafana-cli admin \
  reset-admin-password NEWPASS
```

---

## Ambientes

### Desarrollo

```bash
cp .env.template .env
nano .env
docker compose up -d
```

### Produccion

```bash
./scripts/security/secrets_generate.sh
docker compose --env-file .env.production up -d
```

### Staging

```bash
./scripts/security/secrets_generate.sh
cp .env.production .env.staging
docker compose --env-file .env.staging up -d
```

---

## Integracion con CI/CD

### GitHub Actions

```yaml
- name: Cargar secretos
  env:
    SIHSALUS_POSTGRES_PASSWORD: ${{ secrets.SIHSALUS_POSTGRES_PASSWORD }}
    SIHSALUS_ADMIN_PASSWORD: ${{ secrets.SIHSALUS_ADMIN_PASSWORD }}
  run: |
    echo "SIHSALUS_POSTGRES_PASSWORD=$SIHSALUS_POSTGRES_PASSWORD" >> $GITHUB_ENV
    echo "SIHSALUS_ADMIN_PASSWORD=$SIHSALUS_ADMIN_PASSWORD" >> $GITHUB_ENV
    docker compose up -d
```

### GitLab CI

```yaml
variables:
  SIHSALUS_POSTGRES_PASSWORD: $SIHSALUS_POSTGRES_PASSWORD
  SIHSALUS_ADMIN_PASSWORD: $SIHSALUS_ADMIN_PASSWORD
```

---

## Auditoria y compliance

### Verificar exposicion de secretos

```bash
./scripts/security-audit.sh
docker compose logs | grep -i "password"
rg -n "password|secret|token" . --glob '!secrets/**' --glob '!.git/**'
```

### Rotacion periodica

```bash
# Ejemplo de cron mensual
0 0 1 * * cd /home/openmrs/sihsalus && \
  ./scripts/security/secrets_generate.sh && \
  docker compose --env-file .env.production up -d
```

---

## Recuperacion de desastres

### Backup cifrado de secretos

```bash
tar czf secrets-$(date +%Y%m%d).tar.gz secrets/ .env.production
gpg --symmetric --cipher-algo AES256 secrets-*.tar.gz
```

### Restore de secretos

```bash
gpg --decrypt secrets-20260111.tar.gz.gpg > secrets-20260111.tar.gz
tar xzf secrets-20260111.tar.gz
docker compose --env-file .env.production up -d
```

---

## Integracion con Vault

```bash
vault login -method=ldap username=admin

export SIHSALUS_POSTGRES_PASSWORD="$(vault kv get -field=password secret/data/sihsalus/postgres)"
export SIHSALUS_ADMIN_PASSWORD="$(vault kv get -field=password secret/data/sihsalus/admin)"

docker compose up -d
```

---

## Links y recursos

- [OWASP: Secrets Management](https://owasp.org/www-project-devsecops-guideline/)
- [HashiCorp Vault](https://www.vaultproject.io/)
- [OpenSSL Documentation](https://www.openssl.org/docs/)
- [NIST: Password Guidelines](https://pages.nist.gov/800-63-3/sp800-63b.html)

---

## Scripts relacionados

- [Database Scripts](../database/README.md)
- [Utilidades](../utils/README.md)
- [Backup Scripts](../backup/README.md)
