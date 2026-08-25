# Cambio obligatorio de contraseña con autenticación local

## Alcance

Este flujo se usa únicamente cuando OpenMRS autentica usuarios y contraseñas de
forma local (`OAUTH2_ENABLED=false`). La variable versionada
`SIHSALUS_FORCED_PASSWORD_CHANGE_ENABLED` vale `true` por defecto. Al arrancar,
el backend reconcilia estas propiedades exactas:

```properties
authentication.supportForcedPasswordChange=true
authentication.passwordChangeUrl=/admin/users/changePassword.form
```

En una instalación nueva se escriben primero con el prefijo `property.` en
`openmrs-server.properties`, que es el formato que consume el instalador de
OpenMRS. En una instalación existente se escriben directamente en
`openmrs-runtime.properties`. El hook se ejecuta después de que la imagen copia
la distribución, hace una sustitución atómica y produce los mismos bytes en
cada reinicio con la misma modalidad.

El perfil opcional de Keycloak fija `OAUTH2_ENABLED=true`. En esa modalidad el
backend converge a:

```properties
authentication.supportForcedPasswordChange=false
```

y elimina `authentication.passwordChangeUrl`. Esto evita conservar una
redirección local obsoleta al cambiar una instalación existente a OAuth2.
OAuth2 tiene precedencia: el filtro local queda desactivado aunque
`SIHSALUS_FORCED_PASSWORD_CHANGE_ENABLED=true`.

La distribución valida durante el build que estén presentes los módulos
requeridos:

- Authentication OMOD, que aplica el filtro de cambio obligatorio.
- Legacy UI OMOD, que sirve `/admin/users/changePassword.form` y retira la
  propiedad de usuario `forcePassword` después de un cambio correcto.

## Despliegue

Construye y publica la imagen mediante el workflow normal de backend. En el
servidor usa siempre un tag y digest inmutables y conserva el mismo conjunto de
archivos Compose y profiles del entorno. Este flujo tiene tres piezas
coordinadas: backend (filtro), frontend (guard global) y gateway (retorno de
Legacy a O3 y bloqueo de la recuperación insegura por pregunta secreta).
Despliega el frontend coordinado con el procedimiento inmutable documentado en
el README y reconstruye el gateway desde la misma revisión del distro.

```bash
export BACKEND_TAG='sha-<commit>@sha256:<digest-del-indice>'

# HTTP/local
docker compose pull backend
docker compose up -d --no-deps --force-recreate backend

# HTTPS; agrega también los overrides opcionales que ya use el servidor
docker compose -f docker-compose.yml -f compose/ssl.yml --profile ssl pull backend
docker compose -f docker-compose.yml -f compose/ssl.yml --profile ssl \
  up -d --no-deps --force-recreate backend

# Después de desplegar la imagen fuente frontend coordinada:
docker compose build gateway
docker compose up -d --no-deps --force-recreate gateway
```

En un entorno con SSL u otros overrides, usa la misma combinación efectiva de
`COMPOSE_FILE`/`COMPOSE_PROFILES` también al reconstruir y recrear `gateway`.
Sin ese cambio, la contraseña se modifica correctamente, pero Legacy termina
en su portada antigua en vez de regresar a `/openmrs/spa/home`.

No elimines el volumen `openmrs-data`: contiene la configuración de runtime y
otros datos operativos. Espera a que OpenMRS termine de arrancar:

```bash
docker compose ps backend
docker compose logs --tail 100 backend
curl -k -fsS https://localhost/openmrs/health/started >/dev/null
```

Authentication OMOD carga estas propiedades cuando inicializa su filtro. Un
cambio del flag en `.env` requiere recrear el backend para recibir el nuevo
entorno y reinicializar el filtro. Ejecutar el hook sobre un proceso que ya
arrancó no cambia el comportamiento del filtro en memoria.

Para un entorno local/basic, verifica solo las líneas administradas. No uses
`cat` sobre el archivo completo porque también contiene la credencial de base
de datos.

```bash
docker compose exec backend bash -ceu '
runtime=/openmrs/data/openmrs-runtime.properties
server=/openmrs/openmrs-server.properties
if [[ -f "$runtime" ]]; then
  file="$runtime"
  prefix=""
else
  file="$server"
  prefix="property."
fi
grep -qxF "${prefix}authentication.supportForcedPasswordChange=true" "$file"
grep -qxF "${prefix}authentication.passwordChangeUrl=/admin/users/changePassword.form" "$file"
'
```

Si el entorno usa el override de Keycloak, la comprobación esperada es que el
filtro local esté desactivado y que la URL local no exista:

```bash
docker compose -f docker-compose.yml -f compose/keycloak.yml --profile keycloak \
  exec backend bash -ceu '
file=/openmrs/data/openmrs-runtime.properties
grep -qxF "authentication.supportForcedPasswordChange=false" "$file"
! grep -qE "^[[:space:]]*authentication[.]passwordChangeUrl[[:space:]]*[:=]" "$file"
'
```

## Prueba operativa

Usa exclusivamente una cuenta sintética en DEV o QLTY:

1. Desde Legacy Administration, crea o restablece la contraseña de la cuenta y
   marca el cambio obligatorio de contraseña.
2. Inicia sesión desde una ventana privada con la contraseña temporal.
3. Comprueba que no se puede continuar al flujo clínico y que el usuario llega
   a la pantalla de cambio de contraseña.
4. Intenta una contraseña actual incorrecta y verifica que el cambio siga
   pendiente.
5. Cambia a una contraseña válida y comprueba que el indicador se retire.
6. Comprueba que el retorno de Legacy llegue a `/openmrs/spa/home`, no a la
   portada administrativa antigua.
7. Cierra la sesión y confirma que solo la contraseña nueva permite ingresar.
8. Repite el acceso desde una URL clínica directa para comprobar que no evita
   el filtro.
9. Comprueba que `GET` y `POST` a `/openmrs/forgotPassword.form` responden 404,
   incluidas `/openmrs/forgotPassword.form;jsessionid=test` y
   `/openmrs;jsessionid=test/forgotPassword.form`.

La pantalla y el bloqueo global de navegación pertenecen al cambio coordinado
del frontend. No despliegues únicamente esa parte si el backend aún no contiene
estas propiedades.

## Límites de seguridad

- Este flujo protege el primer ingreso y el uso de una contraseña temporal.
- Un restablecimiento no revoca por sí mismo otras sesiones OpenMRS ya abiertas;
  no debe presentarse como respuesta completa a una cuenta comprometida.
- No se deben registrar, fotografiar ni incluir contraseñas temporales en logs,
  tickets o capturas.
- Deja vacías la pregunta y respuesta secreta de Legacy. El gateway bloquea
  `/openmrs/forgotPassword.form` para todos los métodos, por lo que una pregunta
  antigua tampoco puede usarse para restablecer una contraseña. La recuperación
  se realiza únicamente mediante un administrador.
- Usa HTTPS también en la red interna y una cuenta individual por trabajador.
- La operación requiere conectividad con el backend; no se admite el cambio de
  contraseña en modo offline.

## Rollback

El valor se persiste en `openmrs-runtime.properties`; bajar solamente a una
imagen backend anterior no lo elimina. Además, este flag controla únicamente
el filtro del backend: el frontend coordinado seguirá enviando al formulario
Legacy a una sesión local que aún tenga `forcePassword=true`. Por eso el
rollback completo debe restaurar **ambos** artefactos coordinados, no solo uno.

Durante una ventana controlada, fija primero el flag en el archivo de entorno
que usa el servidor:

```bash
SIHSALUS_FORCED_PASSWORD_CHANGE_ENABLED=false
```

Recrea primero el backend candidato con la misma composición efectiva. El hook
hace una actualización atómica, fija
`authentication.supportForcedPasswordChange=false`, elimina la URL y el nuevo
proceso inicializa el filtro ya desactivado:

```bash
docker compose up -d --no-deps --force-recreate backend
docker compose ps backend
```

Verifica readiness y las dos condiciones del rollback sin imprimir el archivo
completo:

```bash
docker compose exec backend bash -ceu '
file=/openmrs/data/openmrs-runtime.properties
grep -qxF "authentication.supportForcedPasswordChange=false" "$file"
! grep -qE "^[[:space:]]*authentication[.]passwordChangeUrl[[:space:]]*[:=]" "$file"
'
```

Después, si el rollback incluye la imagen, restaura el tag y digest anterior y
recrea nuevamente solo el backend:

```bash
export BACKEND_TAG='sha-<commit-anterior>@sha256:<digest-anterior>'
docker compose pull backend
docker compose up -d --no-deps --force-recreate backend
```

Restaura también la referencia inmutable de frontend anterior al guard global,
siguiendo el procedimiento normal de despliegue/rollback de frontend. Si se
mantiene el frontend nuevo, los usuarios marcados seguirán viendo el cambio
obligatorio aunque el filtro backend ya esté desactivado. No borres ni cambies
masivamente las propiedades `forcePassword` de los usuarios como mecanismo de
rollback.

En HTTPS o con profiles opcionales, añade exactamente los mismos `-f` y
`--profile` usados al desplegar. Confirma readiness otra vez. Conserva el flag
en `false` mientras opere la versión revertida para que un despliegue accidental
de la candidata no reactive el flujo.

Para reactivar el flujo, cambia el flag a `true`, recrea el backend y verifica
las dos propiedades activas:

```bash
SIHSALUS_FORCED_PASSWORD_CHANGE_ENABLED=true
docker compose up -d --no-deps --force-recreate backend
```
