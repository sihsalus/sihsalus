# Autenticación periódica del runtime OpenMRS

El workflow independiente `OpenMRS runtime smoke` levanta una instalación nueva
con datos sintéticos y comprueba login/logout en Chromium. Se ejecuta cada día
a las 08:23 UTC (03:23 Perú) y manualmente desde Actions. No se activa en PR
ni forma parte de `PR Gate`.

## Qué comprueba

La matriz ejecuta dos casos separados: autenticación local y Keycloak. Ambos
usan el mismo digest del backend publicado, resuelto una sola vez por ejecución.
Frontend, gateway y Keycloak se construyen con la configuración del checkout;
el contexto de Keycloak está en `oauth/`.

1. Completar el arranque fresco con `fail_on_error` de Initializer.
2. Obtener HTTP 200 en `/startup` y `/ready` y comprobar que no hay pacientes.
3. Renderizar la SPA y verificar que la sesión REST anónima no está autenticada.
4. Iniciar sesión desde la UI, completar el cambio obligatorio de contraseña
   cuando corresponda y seleccionar la sede.
5. Llegar al inicio y comprobar la identidad autenticada en REST.
6. Cerrar sesión, verificar su invalidación y exigir login al volver al inicio.
7. Confirmar que la tabla de pacientes sigue vacía y retirar los recursos.

## Ejecución manual

Desde Actions, seleccionar `OpenMRS runtime smoke` y la rama a comprobar, o:

```bash
gh workflow run runtime-smoke.yml --repo sihsalus/sihsalus --ref main
```

Para comprobar un backend candidato ya publicado, añadir
`-f backend_digest=sha256:DIGEST_COMPLETO`. Sin ese parámetro se resuelve `latest`.
El digest es compartido por ambas variantes y se registra en la evidencia.
El checkout y el backend pueden corresponder a commits distintos; registrar el
resultado del digest candidato antes de promoverlo.

## Aislamiento y evidencia

La prueba completa exige un runner Linux efímero de GitHub y Docker local.
Valida el Compose efectivo antes del arranque, usa nombres y volúmenes propios,
expone solo `127.0.0.1:80` y genera credenciales nuevas por ejecución.
Tiene plazos por operación y un máximo de dos horas por variante.

Conserva siete días de identidades de imágenes, salud, resultado y logs depurados.
No publica contraseñas, cookies, tokens, configuración Docker completa ni estado
del navegador. La limpieza elimina sus contenedores, volúmenes y archivos privados.

Para validar aislamiento, rutas y redacción de logs sin iniciar contenedores:

```bash
python3 -B -m unittest discover -s tests/runtime -p 'test_*.py' -v
```

Requiere Python 3 y el plugin Compose. El smoke no acredita autorización de
Imaging/Grafana, cobertura de auditoría clínica ni restauración de una instalación
existente. Registrar la evidencia en el [checklist de despliegue](deploy-checklist.md).
