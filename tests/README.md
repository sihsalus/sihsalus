# Pruebas del distro

La suite se limita a los contratos que mantiene este repositorio: configuración,
empaquetado, seguridad y scripts operativos. Los módulos OpenMRS y el frontend
mantienen sus pruebas funcionales en sus propios repositorios.

## Comprobación rápida

Desde la raíz, con Bash, Python 3, Node.js, Git y jq:

```bash
bash tests/run.sh
```

Usa archivos temporales y comandos simulados. Comprueba los hooks del backend,
los pins de módulos, despliegue y rollback, manifiestos, configuración del frontend,
apagado seguro y política de imágenes. Incluye dashboards, contratos de alertas
y el exportador UPS ViewPower. No requiere red ni un daemon Docker.

Para renderizar Compose y comprobar los contratos de autenticación:

```bash
bash scripts/validate-compose.sh
```

Requiere el plugin Docker Compose, sin arrancar servicios. CI ejecuta ambos
comandos en cada PR, además de validar el catálogo de releases contra los
commits fuente y su Compose real. Esta última comprobación también puede
ejecutarse con `python3 -B tests/deploy/release-manifest-compose.py --catalog`.

## Comprobaciones de imágenes

Cuando cambia el frontend o el gateway, el job `Web routing and cache` prueba
sus rutas y cabeceras con contenedores Nginx aislados. Requiere Docker y se puede
repetir con `bash tests/frontend/cache-policy.sh` y `python3 tests/gateway/routing.py`.

Cuando cambian el backend o sus pruebas, CI construye la imagen y verifica sus
módulos, dependencias, hooks de arranque y permisos. Los workflows de publicación
comprueban el backend, las rutas HTTP/HTTPS del gateway y los certificados de
Certbot antes de promover sus imágenes; conservan escaneo, SBOM y firma.

La matriz de pruebas de los diez módulos compilados desde fuente se ejecuta
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
