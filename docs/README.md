# Guías de SIH Salus

El [README principal](../README.md) cubre arranque y validación local. Cada
procedimiento operativo se mantiene en la guía de su componente; este índice
permite encontrarlo sin duplicar comandos ni versiones.

## Instalar y configurar

| Tarea | Guía |
| --- | --- |
| Entender límites y fuentes de configuración | [Arquitectura](architecture/infrastructure.md) |
| Seleccionar servicios y conservar overrides | [Compose](../compose/README.md) |
| Preparar credenciales | [Seguridad](../scripts/security/README.md) |
| Instalar o renovar HTTPS | [Certificados](operations/https.md) |
| Configurar OpenMRS local, Keycloak e Imaging | [Autenticación](../oauth/README.md), [Imaging](../imaging/README.md) |
| Aplicar el cambio obligatorio de contraseña | [Contrato de contraseña](operations/forced-password-change.md) |
| Elegir el perfil operativo del establecimiento | [Perfiles de instalación](operations/profiles.md) |

## Actualizar y recuperar

| Tarea | Guía |
| --- | --- |
| Preparar y aceptar un despliegue | [Checklist](operations/deploy-checklist.md) |
| Actualizar un servicio o un ambiente completo | [Scripts de despliegue](../scripts/deploy/README.md) |
| Aplicar o revertir una release coordinada | [Manifiestos](operations/release-manifests.md) |
| Verificar firmas, imágenes y vulnerabilidades | [Política de imágenes](operations/image-security.md) |
| Respaldar y restaurar MariaDB | [Backups](../scripts/backup/README.md) |
| Preparar semillas cifradas | [Semillas](../scripts/seed/README.md) |
| Configurar usuarios y réplica MariaDB | [Base de datos](../scripts/database/README.md) |
| Comprobar recuperación y autenticación | [Simulacros](operations/physical-backup-drill.md), [smoke del runtime](operations/runtime-smoke.md) |

## Operar y mantener

| Tarea | Guía |
| --- | --- |
| Consultar métricas, alertas, logs y UPS | [Monitoreo](../monitoring/README.md) |
| Habilitar acceso a Grafana | [Acceso LAN](operations/grafana-lan.md), [OIDC](operations/grafana-oidc.md) |
| Interpretar estado y frescura de respaldos | [Semáforo](operations/status-compliance.md), [métricas de restore](operations/seed-restore-metrics.md) |
| Configurar apagado seguro | [Runbook UPS](operations/safe-poweroff.md) |
| Atender alertas de secretos | [Detección de secretos](operations/secret-scanning.md) |
| Construir y probar componentes | [Backend](../backend/README.md), [frontend](../frontend/README.md), [gateway](../gateway/README.md), [pruebas](../tests/README.md) |

El [contrato de enrutamiento clínico 1.23.0](operations/canonical-care-routing-1.23.0.md)
conserva el contexto de esa versión; no reemplaza las instrucciones vigentes de despliegue.
