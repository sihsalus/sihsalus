# Keycloak - Autenticación OpenID Connect

Keycloak es el servidor de identidad y acceso que proporciona autenticación OAuth2/OpenID Connect para OpenMRS.

## Configuración Mínima

### Variables de entorno requeridas

```env
# En .env:
KEYCLOAK_ADMIN_PASSWORD=<password_seguro>      # Password del usuario admin
KC_DB_PASSWORD=<password_seguro>               # Password de PostgreSQL de Keycloak
OAUTH2_ENABLED=true                            # Activa oauth2login en OpenMRS
OAUTH2_CLIENT_SECRET=<secret_aleatorio>        # Secret del cliente OpenMRS
```

### Activa el profile de Keycloak

```bash
docker compose \
  -f docker-compose.yml \
  -f compose/openmrs-keycloak.yml \
  --profile keycloak \
  up -d
```

### Acceso inicial

- **URL**: `http://localhost:8180`
- **Usuario**: `admin`
- **Contraseña**: Valor de `KEYCLOAK_ADMIN_PASSWORD`

---

## Configuración

### Realm: `openmrs`

El archivo [realm-export.json](realm-export.json) contiene la configuración importada automáticamente:

- **Cliente OIDC**: `openmrs`
  - Tipo: Confidential (con client secret)
  - Flujo: Authorization Code (OAuth2 standard)
  - Redirect URIs: `http(s)://localhost/openmrs/*`

- **Roles integrados**:
  - `System Developer` - Administración del sistema
  - `Provider` - Personal médico
  - `Clerk` - Digitadores de datos

- **Usuarios iniciales**:
  - `admin` - Usuario administrador del realm

### Mapeadores de Claims

Los claims OIDC se mapean automáticamente a atributos de OpenMRS:

| Claim | Atributo Keycloak | Uso |
|-------|-----------------|-----|
| `preferred_username` | username | Identificador único en OpenMRS |
| `given_name` | firstName | Nombre del usuario |
| `family_name` | lastName | Apellido del usuario |
| `email` | email | Email de contacto |

---

## Integración con OpenMRS

El backend OpenMRS obtiene la configuración desde [oauth2.properties](oauth2.properties):

```properties
# OAuth2 endpoints
oauth2.enabled=${OAUTH2_ENABLED}
userAuthorizationUri=http://localhost:8180/realms/openmrs/protocol/openid-connect/auth
accessTokenUri=http://keycloak:8080/realms/openmrs/protocol/openid-connect/token
userInfoUri=http://keycloak:8080/realms/openmrs/protocol/openid-connect/userinfo
keysUrl=http://keycloak:8080/realms/openmrs/protocol/openid-connect/certs

# Client credentials
clientId=openmrs
clientSecret=${OAUTH2_CLIENT_SECRET}
scope=openid,profile,email

# Mapeos de claims a atributos de usuario
openmrs.mapping.user.username=preferred_username
openmrs.mapping.person.givenName=given_name
openmrs.mapping.person.familyName=family_name
openmrs.mapping.user.email=email
openmrs.mapping.user.systemId=sub
```

El frontend O3 recibe la configuración OAuth2 desde
[frontend-keycloak.json](../frontend/frontend-keycloak.json), agregada por
`compose/openmrs-keycloak.yml` a `SPA_CONFIG_URLS`.

La global property de redirección post-login se inyecta como configuración
Initializer desde
[oauth2login.xml](openmrs_config/globalproperties/oauth2login.xml).

---

## Docker Setup

### Dockerfile

- Base: `quay.io/keycloak/keycloak:26.4.1`
- BD: PostgreSQL (configurada en `keycloak-db`)

### Permisos y Seguridad

- Corre como usuario no-root (UID 1000)
- Usa Docker Secrets para credenciales en producción
- SSL requerido en modo producción

---

## Primeros pasos

### 1. Crear un usuario de prueba

1. Accede a `http://localhost:8180` como admin
2. Ve a **Realm** → **Users** → **Create new user**
3. Username: `provider1`
4. Email: `provider@hospital.local`
5. Assign roles: `Provider`
6. Set password temporal y marcar como "Not temporary"

### 2. Probar login en OpenMRS

1. Ve a `http://localhost/openmrs/spa`
2. Click en **Login with Keycloak** (u otro proveedor OAuth configurado)
3. Ingresa credenciales del usuario creado
4. Se redirige a OpenMRS con sesión activa

---

## Cambios de contraseña

### En Keycloak Admin Console

1. Realm → Users → Selecciona usuario
2. Credentials → Reset Password

### Por usuario final

1. En login de OpenMRS
2. Click **Forgot Password?** → Keycloak maneja el reset por email

---

## Solución de problemas

### "Invalid redirect URI"

Verifica que los redirect URIs en el cliente `openmrs` contengan el hostname correcto:
- Local: `http://localhost/openmrs/*`
- Con dominio: `https://yourdomain.com/openmrs/*`

### Keycloak no inicia

Revisa logs:
```bash
docker compose \
  -f docker-compose.yml \
  -f compose/openmrs-keycloak.yml \
  --profile keycloak \
  logs keycloak
```

### Usuario no puede loguearse

1. Verifica que el usuario esté **enabled**
2. Verifica que tenga al menos un rol asignado
3. Revisa logs de Keycloak y OpenMRS backend

---

## Documentación adicional

- [Keycloak Docs](https://www.keycloak.org/docs/)
- [OAuth2/OIDC en OpenMRS](https://wiki.openmrs.org/display/docs/OAuth2)
