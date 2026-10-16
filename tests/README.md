# Pruebas del distro

La suite se limita a los contratos que mantiene este repositorio: configuración,
empaquetado, seguridad y scripts operativos. Los módulos OpenMRS y el frontend
mantienen sus pruebas funcionales en sus propios repositorios.

## Comprobación rápida

Desde la raíz, con Bash, Python 3, Node.js, Git, jq, gzip y OpenSSL:

```bash
bash tests/run.sh
```

Usa archivos temporales y comandos simulados. Comprueba los hooks del backend,
los pins de módulos, despliegue y rollback, manifiestos, configuración del frontend,
apagado seguro, límites de fallo del restore SQL y política de imágenes. Incluye
dashboards, contratos de alertas y el exportador UPS ViewPower. No requiere red
ni un daemon Docker.

Para renderizar Compose y comprobar los contratos de autenticación:

```bash
bash scripts/validate-compose.sh
```

Requiere los plugins Docker Compose y Buildx, sin arrancar servicios. También
compara contexto, Dockerfile y argumentos del frontend entre Compose y Bake
(automático, explícito y HCL aislado), incluida `.env.template` y la precedencia
de overrides sobre los valores de respaldo del HCL.
CI ejecuta ambos comandos en cada PR y los contratos sintéticos de selección
persistente. `Deployment checks` comprueba además la identidad y lectura de
imágenes reales. Las pruebas de `test_deploy.py` verifican actualización parcial,
recuperación ante fallo interno o HTTP, exclusión mutua y conservación de bases
de datos, secretos y configuración. La compatibilidad de registros históricos
se sigue probando para recuperar instalaciones anteriores.

## Comprobaciones de imágenes

Cuando cambia el frontend o el gateway, el job `Web routing and cache` prueba
sus rutas y cabeceras con contenedores Nginx aislados. Requiere Docker y se puede
repetir con `bash tests/frontend/cache-policy.sh` y `python3 tests/gateway/routing.py`.

Cuando cambian el backend o sus pruebas, CI construye la imagen y verifica sus
módulos, dependencias, hooks de arranque y permisos. Los workflows de publicación
comprueban el backend, las rutas HTTP/HTTPS del gateway y los certificados de
Certbot antes de promover sus imágenes; conservan escaneo, SBOM y firma.

La matriz de pruebas de los módulos de `backend/omod-sources.lock` se ejecuta
manualmente con la opción `source_omods` del workflow CI. El build normal sigue
compilando sus revisiones fijadas y comprobando la imagen resultante.

## Monitoreo

La parte rápida también puede ejecutarse por separado:

```bash
bash tests/monitoring/config-validation.sh --static
```

Dos jobs con contenedores se activan por cambios relacionados y forman parte de
`PR Gate`; una ejecución manual de CI activa ambos:

| Job | Cobertura |
| --- | --- |
| `Monitoring configuration and Docker API proxy` | Configuración Alloy, Prometheus y Gatus; alertas con uno o ambos túneles VPN caídos; Docker API permite lectura y rechaza escritura con HTTP 403 |
| `Grafana OIDC authorization` | Grafana real con proveedor sintético: roles, precedencia, usuarios sin permisos, códigos expirados, PKCE y cierre de sesión |

`bash tests/monitoring/config-validation.sh` ejecuta también los validadores
en contenedores y necesita Docker activo. `socket-proxy.sh` y el runtime OIDC
requieren un runner efímero de GitHub. Los contratos OIDC pueden comprobarse
localmente con Compose instalado, sin levantar servicios:

```bash
python3 -B -m unittest discover -s tests/monitoring/oidc -p 'test_*.py' -v
```

Los validadores de Alloy, Prometheus y Gatus toman las imágenes del modelo
Compose, sin repetir sus versiones en el script. Cambios en `compose/status.yml`
también activan el job de monitoreo.

Los límites de la prueba sintética y la aceptación del IdP real están descritos
en [Grafana OIDC](../docs/operations/grafana-oidc.md).

## Autenticación y restauración fuera del CI habitual

Dos workflows independientes admiten ejecución manual y periódica, sin activarse
en cada PR ni formar parte de `PR Gate`:

| Workflow | Frecuencia | Cobertura |
| --- | --- | --- |
| `runtime-smoke.yml` | Diario, 08:23 UTC (03:23 Perú) | Instalación nueva, SPA, login/logout local y Keycloak, cambio de contraseña y sesión REST |
| `physical-backup-drill.yml` | Lunes, 09:41 UTC (04:41 Perú) | Dump cifrado, semillas, restauración física y recuperación del snapshot ante fallo |

Usan datos sintéticos y recursos temporales en runners de GitHub. El smoke
admite un `backend_digest` manual para probar un candidato publicado; por
defecto resuelve `latest` una sola vez y usa ese digest en ambos modos.

Preparación del smoke sin iniciar contenedores, con el plugin Compose instalado:

```bash
python3 -B -m unittest discover -s tests/runtime -p 'test_*.py' -v
```

Ejecución y límites: [autenticación](../docs/operations/runtime-smoke.md) y
[restauración](../docs/operations/physical-backup-drill.md). Registrar la evidencia
en el [checklist de despliegue](../docs/operations/deploy-checklist.md).
La autorización específica de Imaging sigue requiriendo aceptación separada;
no se recuperan su proveedor sintético ni el registry de prueba.

## Conformidad RENHICE con datos sintéticos

Esta suite prepara evidencia de desarrollo para el [contrato IPS Perú](../docs/accreditation/ips-peru-contract.md).
No ejecuta un exportador de OpenMRS, no consulta pacientes ni prueba acreditación,
firma, transporte, autorización institucional o aceptación clínica.

Los controles locales de identidad y manejo de fallos no requieren red:

```bash
python3 -B -m unittest discover -s tests/interop -p 'test_*.py' -v
```

La validación completa requiere Python 3.11+, Java 21 y acceso a GitHub, al
paquete MINSA, al registro de paquetes FHIR y a `https://tx.fhir.org/r4`:

```bash
python3 -B tests/interop/run_conformance.py --cache "$TMPDIR/sihsalus-renhice-validation"
```

En Linux, usar una ruta temporal o de caché propia si `TMPDIR` no está definido.
El script descarga el validador oficial HL7 **7.0.2** y CorePE **0.1** con SHA-256
fijados. Un cambio de bytes del borrador oficial bloquea la ejecución hasta
revisión humana del nuevo artefacto; no actualiza el pin automáticamente.
Las dependencias FHIR transitivas las resuelve el validador en su caché habitual
`~/.fhir/packages`; sus versiones y carga quedan en los logs. No se afirma
reproducibilidad binaria completa de esas dependencias ni del servicio de
terminología. Usar un runner efímero de CI para obtener una ejecución nueva.

Se conserva `target/interop-conformance/summary.json`, logs y OperationOutcome.
La suite comprueba documento válido, referencia ausente, recurso incompatible
y mezcla de pacientes. El último caso separa aceptación del perfil de rechazo
por identidad documental. Los errores negativos deben ser los esperados; un
fallo de red o del proceso no cuenta como prueba aprobada. Las advertencias
conocidas del borrador quedan visibles y se contrastan por ID, ubicación y
cantidad. Una advertencia nueva, ausente o cambiada bloquea la referencia de
prueba hasta revisar la causa; no se desactiva terminología ni se rebaja la
severidad de los diagnósticos.

El documento positivo produce tres advertencias: dos por los tipos de identidad
peruanos frente al binding extensible de R4 y una porque el paquete MINSA
referencia `CIE10VS` sin incluirlo. La prueba de mezcla de pacientes añade otra
del mismo tipo de identidad para el paciente contenido. Son limitaciones
explícitas del borrador: **no demuestran validación terminológica completa ni
autorizan uso clínico**. Los errores/advertencias de las referencias rotas se
comprueban exclusivamente en su caso negativo.

El workflow `renhice-conformance.yml` ejecuta la suite en PR que cambian sus
pruebas y permite ejecución manual. Conserva evidencia sintética durante 14
días. No usa Docker, secretos, credenciales de entornos ni modifica servicios.
El script no admite archivos clínicos arbitrarios: solo fixtures del repositorio.
