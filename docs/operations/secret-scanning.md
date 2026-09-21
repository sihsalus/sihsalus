# Detección de secretos en GitHub

Este procedimiento cubre `sihsalus/sihsalus`, `sihsalus/sihsalus-content` y
`sihsalus/sihsalus-frontend`. Seguimiento:
[issue #176](https://github.com/sihsalus/sihsalus/issues/176).

## Configuración verificada

El 21 de septiembre de 2026 los tres repositorios públicos tenían desactivadas
las cuatro funciones siguientes. Se habilitaron con una cuenta administradora
y GitHub devolvió `enabled` para todas:

| Función de la API | Protección |
| --- | --- |
| `secret_scanning` | Detecta secretos compatibles en el repositorio |
| `secret_scanning_push_protection` | Rechaza pushes con patrones protegidos |
| `secret_scanning_validity_checks` | Comprueba validez cuando el proveedor y el tipo de token lo permiten |
| `secret_scanning_non_provider_patterns` | Amplía la detección a patrones sin proveedor |

La activación funcionó con el plan y los permisos vigentes: no quedó demostrado
un bloqueo de licencia. No se cambió la configuración global de la organización
ni se contrató un plan o habilitaron excepciones. La disponibilidad y los
permisos pueden cambiar; comprobar el estado efectivo tras cualquier cambio de
política, visibilidad o plan y antes de una entrega.

Un administrador puede consultar únicamente los estados, sin recuperar secretos:

```bash
gh api repos/sihsalus/sihsalus --jq '{full_name,security_and_analysis}'
gh api repos/sihsalus/sihsalus-content --jq '{full_name,security_and_analysis}'
gh api repos/sihsalus/sihsalus-frontend --jq '{full_name,security_and_analysis}'
```

Una respuesta `403`, un campo ausente o un estado `disabled` no prueba por sí solo
un problema de licencia. El administrador debe comprobar permisos, configuración
de seguridad aplicada y disponibilidad en GitHub; registrar la causa confirmada
y el responsable de resolverla en el issue. No reducir protecciones para hacer
pasar una entrega.

## Alertas, responsables y tiempos de atención

Los siguientes son objetivos operativos propuestos para revisión de los
mantenedores; no suponen que exista una guardia institucional ya aprobada.

| Señal | Responsable | Objetivo de atención |
| --- | --- | --- |
| Credencial activa expuesta o indicios de uso indebido | Administrador del repositorio y responsable del servicio emisor | Prioridad inmediata; iniciar contención en una hora desde la detección |
| Alerta nueva con validez desconocida o sin comprobación compatible | Administrador del repositorio; asigna responsable del servicio | Clasificar y asignar en un día hábil; tratar como potencialmente activa hasta comprobarlo |
| Push rechazado antes de publicación | Autor del cambio, con revisión del mantenedor | Retirar la credencial de todos los commits afectados antes de reintentar |
| Patrón inactivo, dato de prueba o falso positivo confirmado | Mantenedor con acceso a alertas | Documentar evidencia y resolución en un día hábil |
| Una protección aparece desactivada o no disponible | Administrador de GitHub de la organización | Investigar y asignar en un día hábil; registrar la dependencia real de política, permisos o plan |

Cada alerta debe tener una persona asignada en la vista privada de seguridad.
El administrador del repositorio conserva la responsabilidad de seguimiento
hasta que el responsable del servicio acepte la atención. Una incidencia urgente
sin responsable disponible requiere escalar por el canal institucional de
incidentes existente; este documento no crea un nuevo canal ni una guardia.

Para una credencial real, revocar o rotar primero en el emisor, actualizar sus
consumidores autorizados y verificar que el valor anterior ya no funciona.
Eliminar texto del último commit no elimina una exposición del historial.
Registrar alcance, fechas, responsable y acciones en un espacio privado; nunca
copiar el valor a un issue público, PR, captura, log o comentario de resolución.
Cerrar la alerta con la resolución que corresponda a la evidencia. No descartar
como prueba una credencial real para desbloquear el push.

Una alerta `inactive` no demuestra ausencia de uso anterior. La ausencia de
alertas tampoco demuestra que no existan secretos: la cobertura y la protección
de push dependen de los patrones compatibles. Consultar los
[patrones admitidos por GitHub](https://docs.github.com/en/code-security/reference/secret-security/supported-secret-scanning-patterns).

## Prueba segura de protección de push

Usar exclusivamente el token **inactivo** que GitHub publica en
[GitHub Skills, paso 3](https://github.com/skills/introduction-to-secret-scanning/blob/main/.github/steps/3-enable-push-protection.md).
No generar ni obtener una credencial válida para esta prueba. No guardar el
patrón en el código de producto ni en un PR.

1. Confirmar los cuatro estados efectivos por API.
2. Preparar un commit desechable con el ejemplo inactivo en un repositorio local
   aislado y una referencia remota de prueba nueva y única. No usar `main` ni una
   rama de trabajo existente.
3. Intentar el push sin bypass. Exigir que GitHub lo rechace específicamente por
   protección de secretos; un error de red, permisos o reglas de rama no cuenta.
4. Confirmar con `git ls-remote` que la referencia no se creó. Si se acepta por
   error, registrar el fallo y retirar solamente esa referencia, verificando que
   todavía apunte al commit de prueba antes de eliminarla.
5. Conservar un resultado redactado: repositorio, fecha, rechazo específico,
   ausencia de la referencia y ausencia de bypass. No publicar el token ni las
   URLs para autorizar excepciones.

Resultado del 21 de septiembre de 2026: **los tres repositorios rechazaron el
push por protección de secretos**. Ninguna referencia de prueba se creó y no
se utilizó bypass. Esta prueba acredita el patrón de GitHub utilizado; no
acredita todos los proveedores ni la revocación de una credencial real.

GitHub documenta cómo
[resolver un push bloqueado](https://docs.github.com/en/code-security/how-tos/secure-your-secrets/work-with-leak-prevention/push-protection-on-the-command-line)
y cómo administrar los estados mediante la
[API de repositorios](https://docs.github.com/en/rest/repos/repos#update-a-repository).
