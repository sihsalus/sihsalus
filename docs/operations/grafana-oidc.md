# Grafana OIDC opcional con roles explícitos

Este override añade autenticación individual a Grafana 12.3, sin activar nada
en el stack por defecto. No modifica el realm importado, OpenMRS, Imaging ni
sus roles. No constituye autorización para desplegar o cambiar la identidad
clínica: `compose/keycloak.yml` también activa OAuth2 en frontend/backend, por
lo que **Keycloak debe estar previamente autorizado y operativo**.

## Contrato del cliente

El responsable de identidad debe preparar y revisar un cliente confidencial
`sihsalus-grafana` en el realm `openmrs` existente. No se importa un realm de
reemplazo ni se modifica el cliente clínico. Requisitos:

- Authorization Code habilitado; PKCE S256 obligatorio; password grant y
  service accounts deshabilitados.
- Callback exacto `https://<host>/grafana/login/generic_oauth`, sin comodines.
- Secreto exclusivo `GRAFANA_OIDC_CLIENT_SECRET`, registrado en el gestor de
  secretos y en el cliente; no reutilizar credenciales clínicas.
- Scopes `openid profile email`; `sub` estable, `preferred_username` y email.
- Mapper de roles de cliente con claim JSON
  `resource_access.sihsalus-grafana.roles` como array. Incluirlo en ID token,
  UserInfo y access token; no sustituirlo por realm roles ni grupos genéricos.
- Permitir refresh tokens según la política de sesiones del IdP; no solicitar
  `offline_access` ni sesiones permanentes para este acceso operativo.

| Rol de cliente explícito | Rol en la organización de Grafana |
| --- | --- |
| `grafana-admin` | Admin, no administrador global de Grafana |
| `grafana-editor` | Editor |
| `grafana-viewer` | Viewer |
| Ninguno, vacío, desconocido o claim escalar | Login denegado |

Solo se asignan roles explícitos. Si hay varios reconocidos, prevalece Admin,
luego Editor y luego Viewer. Se recomienda asignar únicamente Viewer salvo
necesidad aprobada. Grafana evalúa ID token, UserInfo y access token en ese
orden; el primer rol válido prevalece. Los mappers deben ser coherentes entre
fuentes. Si ninguna contiene un rol válido, strict rechaza el login. No se
asigna `GrafanaAdmin`; los administradores globales locales existentes no se
convierten ni revocan mediante este override.

La creación automática de una cuenta OAuth requiere ese rol; el registro local
público permanece deshabilitado. Los roles de organización se sincronizan al
login. La validación de roles no es una revocación instantánea de todas las
sesiones abiertas: al retirar acceso, coordinar la revocación en Grafana y el
IdP. `use_refresh_token=true` habilita el control de expiración de access tokens;
la duración y renovación efectiva requieren comprobar el cliente Keycloak real.

## Selección y preflight, sin activación implícita

Conservar todos los overrides/perfiles existentes. Añadir OIDC solo después de
aprobar el cliente, HTTPS, acceso LAN y prueba de recuperación local:

```env
COMPOSE_FILE=docker-compose.yml:compose/keycloak.yml:compose/monitoring-oidc.yml:compose/ssl.yml
COMPOSE_PROFILES=keycloak,monitoring,ssl
GRAFANA_ROOT_URL=https://<host>/grafana/
KEYCLOAK_PUBLIC_URL=https://<host>/keycloak
```

El secreto se configura fuera de Git; el generador lo crea sin habilitar el
override. No ejecutar un recreate genérico ni omitir HTTPS para recuperar acceso.

```bash
# Solo render y auditoría local, no arranca servicios.
docker compose --env-file .env.production \
  -f docker-compose.yml -f compose/keycloak.yml \
  -f compose/monitoring-oidc.yml -f compose/ssl.yml \
  --profile keycloak --profile monitoring --profile ssl config --quiet
./scripts/security-audit.sh .env.production
```

`root_url` debe incluir `/grafana/`; el override fija cookies Secure y SameSite
Lax para el retorno OAuth. Conservar el gateway/ACL de red existente. No abrir
el puerto directo 3001 a la LAN. La red interna `auth-network` permite a Grafana
usar token/UserInfo de Keycloak sin publicar esos servicios directamente.

## Salida y contingencia

El botón de salida invalida la sesión local de Grafana. **No cierra la sesión
SSO de Keycloak**: el usuario debe salir también del IdP si corresponde. No se
configura una redirección de logout sin el contrato completo del cliente; una
sesión SSO aún abierta puede iniciar un nuevo login autorizado.

El formulario local permanece disponible (`auto_login=false`) para una cuenta
de contingencia controlada, con contraseña exclusiva. Probar esa cuenta por la
ruta HTTPS autorizada antes de habilitar OIDC. Si se usa túnel SSH, conservar
HTTPS mediante el procedimiento operativo aprobado: no asumir que todos los
navegadores envían cookies Secure por HTTP loopback ni desactivar Secure como
recuperación rutinaria. No pegar contraseñas o tokens en comandos, logs o PRs.

## Rollback coordinado

Para volver al login local en una ventana autorizada, retira únicamente
`compose/monitoring-oidc.yml` de la composición efectiva y recrea solo Grafana
con `--no-deps`, conservando los demás overrides, perfiles, HTTPS y su volumen.
No retires `compose/keycloak.yml` ni alteres los clientes clínicos. Comprueba
antes que la cuenta local de contingencia funciona y conserva las referencias
de configuración e imagen previas. Deshabilitar el proveedor no sustituye la
revocación explícita de sesiones activas en Grafana y el IdP.

## Evidencia de pruebas y límites

```bash
bash scripts/validate-compose.sh
```

CI renderiza los modelos y comprueba roles configurados, URLs, redes,
restricciones y que el override solo modifique Grafana. La suite acotada no
levanta un proveedor OIDC sintético ni comprueba sesiones reales.

Antes de activar el override en un establecimiento, verificar en un entorno
isolado los tres roles, la denegación de usuarios sin rol, login, logout y la
cuenta local de contingencia. Validar también TLS/SameSite, MFA, logout SSO y
rotación de claves según la configuración del IdP. Registrar esa aceptación
por separado del resultado de CI.

Referencias primarias: [conector Grafana 12.3](https://github.com/grafana/grafana/blob/v12.3.0/pkg/login/social/connectors/generic_oauth.go),
[opciones 12.3](https://github.com/grafana/grafana/blob/v12.3.0/conf/defaults.ini),
[OAuth y roles](https://grafana.com/docs/grafana/latest/setup-grafana/configure-access/configure-authentication/generic-oauth/).
