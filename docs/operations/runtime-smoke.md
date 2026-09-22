# Smoke periódico del runtime OpenMRS

El workflow `OpenMRS runtime smoke` arranca una instalación nueva completa en
GitHub Actions y verifica la SPA, una sesión REST y el login/logout en navegador.
Se ejecuta diariamente a las 08:23 UTC, manualmente y en PR que modifican el
propio smoke o la configuración de gateway, frontend y Keycloak.

El issue de seguimiento es [#175](https://github.com/sihsalus/sihsalus/issues/175).
Este control prepara la aceptación del conjunto, pero no sustituye las pruebas
clínicas ni el [checklist de despliegue](deploy-checklist.md).

## Combinación que se prueba

- Backend publicado: se resuelve `ghcr.io/sihsalus/sihsalus-backend:latest` una
  sola vez por ejecución; ambas variantes consumen ese mismo digest inmutable.
  La ejecución manual admite `backend_digest` para probar un candidato ya
  publicado del mismo repositorio de imágenes. Solo acepta un digest SHA-256
  completo y comprueba que la resolución devuelva exactamente ese digest.
- Frontend: fuente fijada en `.env.template`, ensamblada con el Dockerfile actual
  y la configuración normal de cada modo de autenticación.
- Gateway y Keycloak: Dockerfiles del checkout. Bases, configuración OAuth2 y
  portal de ayuda: imágenes y contratos declarados en el Compose del producto.

La matriz tiene dos casos independientes: autenticación local y Keycloak.
Cada caso crea una base vacía y volúmenes propios que reciben únicamente la
inicialización del producto. El checkout del test y
la revisión del backend publicado pueden ser diferentes: `sources.json`,
`containers.json`, `images.json` y el SHA del frontend en `browser.log` identifican
los bytes realmente probados. Un cambio de backend todavía no publicado requiere
su propia validación de candidato; este workflow no lo incorpora por inferencia.

Para validar una imagen candidata, registrar primero su commit de construcción,
resultado de CI y digest. Ejecutar manualmente este workflow con ese digest en
`backend_digest` y conservar el enlace al resultado. El control diario y las
ejecuciones sin ese parámetro siguen comprobando `latest`. Esta selección no
promueve imágenes ni cambia un entorno desplegado.

## Reutilización y aislamiento

Se reutilizan `docker-compose.yml`, `compose/keycloak.yml` y sus Dockerfiles.
Los overrides de `tests/runtime/` se limitan a nombres únicos, publicación del
gateway en `127.0.0.1:80`, retiro de puertos administrativos, credenciales
sintéticas, memoria acotada y rechazo de fallos de Initializer.
No se desactiva un loader ni se modifica content para hacer pasar el test.

El script admite exclusivamente un runner Linux efímero de GitHub, con su
conexión Docker local. Antes de arrancar comprueba el modelo real que produce
Compose: servicios esperados, recursos sin referencias externas, nombres del
proyecto y montajes de archivos del repositorio de solo lectura. Se rechaza una
configuración que pueda reutilizar otro stack. La limpieza usa ese mismo
proyecto y verifica que no queden sus contenedores ni volúmenes.

Se usan las opciones soportadas de
[Compose para combinar overrides](https://docs.docker.com/reference/compose-file/merge/)
y [esperar salud con un plazo](https://docs.docker.com/reference/cli/docker/compose/up/).
Se requiere Compose 2.24.4 o posterior. La orquestación usa Compose, curl y
`timeout` de GNU; no inicia un daemon ni aplica migraciones de reparación.

## Qué debe pasar

1. Resolver el digest compartido, descargar las dependencias y construir los
   wrappers del checkout sin publicar imágenes de producto.
2. Completar el arranque fresco en un máximo de 45 minutos. Initializer usa
   `fail_on_error`; que Nginx responda no basta para dar por listo OpenMRS.
3. Obtener HTTP 200 en `/startup` y `/ready` y comprobar que la tabla de pacientes
   está vacía, sin consultar registros clínicos.
4. Renderizar la SPA real en Chromium y comprobar que la sesión anónima no está
   autenticada. Registrar la procedencia del frontend empaquetado.
5. Autenticar al administrador de la instalación sintética desde la interfaz.
   Se respeta el cambio obligatorio de contraseña: Legacy UI 2.2.0 en el modo
   local cuando corresponde, y el flujo real de contraseña temporal de Keycloak.
6. Seleccionar una sede si la aplicación la solicita, llegar al inicio y
   comprobar la sesión del navegador contra REST. Playwright reutiliza las
   [cookies del contexto del navegador](https://playwright.dev/docs/api/class-browsercontext#browser-context-request).
7. Cerrar la sesión, confirmar su invalidación en el servidor y verificar que
   volver al inicio exige autenticarse. La tabla de pacientes debe seguir vacía.

Los pulls, builds y esperas tienen límites externos; el job completo tiene un
máximo de dos horas, incluida la preparación. Un timeout es un fallo, no una
aceptación parcial. Los dos modos se reportan por separado y ninguno oculta el
fallo del otro.

## Evidencia y diagnóstico

Cada variante conserva durante siete días `result.json`, estados de servicios,
identidades de imágenes, resultados de salud y logs depurados. Las contraseñas
son aleatorias por ejecución y pasan a Compose y Playwright por variables de
entorno. El fixture escrito contiene solo identidad y modo; la configuración
resuelta de Compose se valida desde stdin, sin guardarla. Antes de subir logs se
eliminan esos valores y
sus formas codificadas, cabeceras de autenticación/cookies, tokens JWT y parámetros
de callback. Se conservan hasta 2 MiB por log para diagnosticar fallos de arranque.

No se suben `.env`, configuración Docker resuelta, informes completos de
`inspect`, estado autenticado del navegador, traces, videos ni capturas. El
directorio privado temporal se elimina al terminar. Solo se publican los campos
de identidad y estado elegidos expresamente, incluso si el test falla.

Un fallo de descarga, bootstrap o login debe corregirse en el componente
responsable. No cambiar a la imagen upstream del antiguo
`docker-compose-no-volumes.yml`, aceptar un redirect como login, omitir módulos,
desactivar políticas de contraseña ni retirar la variante fallida.

Para verificar las protecciones y el render sin iniciar Docker:

```bash
python3 -B -m unittest discover -s tests/runtime -p 'test_*.py' -v
```

La prueba completa se ejecuta desde Actions. Su mantenimiento corresponde a los
mantenedores del distro; la lógica clínica, los formularios y la autorización
permanecen en sus módulos propietarios.
