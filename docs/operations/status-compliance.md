# Semáforo local: privacidad y cumplimiento

Este documento define los controles mínimos para que el semáforo local de SIH Salus apoye disponibilidad operativa sin procesar datos clínicos ni datos personales.

## Alcance

El semáforo local es un control de disponibilidad y continuidad operativa. No reemplaza controles de seguridad clínica, auditoría del EMR, gestión de usuarios, cifrado, backup, retención documental ni respuesta a incidentes.

## Principios

- No debe consultar endpoints que devuelvan datos personales o datos de salud.
- No debe mostrar nombres, documentos, teléfonos, direcciones, diagnósticos, resultados, notas clínicas ni identificadores de pacientes.
- No debe almacenar cuerpos de respuesta con información sensible.
- No debe exponer logs técnicos al personal clínico o administrativo.
- Debe separar la vista operativa del soporte técnico.
- Debe usar lenguaje de continuidad asistencial, no códigos técnicos como única salida.

## Uso permitido de Gatus

Gatus puede usarse para verificar disponibilidad de servicios y endpoints técnicos sin PHI.

Checks permitidos:

- `GET /health`
- `GET /startup`
- `GET /ready`
- `GET /openmrs/health/started`
- `GET /openmrs/ws/rest/v1/session` solo para validar disponibilidad de sesión, sin usuario autenticado
- Endpoints propios de `status-agent` que devuelvan solo estado operativo

Checks no permitidos:

- Búsquedas de pacientes
- Listados de encuentros
- Observaciones clínicas
- Resultados de laboratorio
- Recursos FHIR con datos identificables
- Logs de aplicación con contenido clínico
- Endpoints administrativos que devuelvan secretos, tokens o configuración sensible

## Controles de acceso

Vista para personal clínico o administrativo:

- Solo lectura
- Sin datos clínicos
- Sin acceso a Docker
- Sin acciones destructivas
- Mensajes de acción recomendada claros

Vista para soporte técnico:

- Restringida a red administrativa, VPN o túnel SSH
- Protegida con credenciales
- Con registro de acciones si permite reinicios, cambios o restauraciones

## Estados permitidos

El semáforo debe resumir el estado en categorías operativas:

- `verde`: puede atender pacientes y guardar información
- `amarillo`: puede atender, pero requiere acción preventiva
- `rojo`: atención digital comprometida o riesgo alto de pérdida de datos

Cada estado amarillo o rojo debe incluir una acción recomendada.

Ejemplos:

- `Conectar USB de backup semanal`
- `Liberar espacio en disco`
- `Contactar soporte técnico`
- `No apagar el servidor durante restauración`
- `Usar contingencia en papel hasta recuperar base de datos`

## Evidencia auditable

El semáforo puede servir como evidencia de:

- monitoreo de disponibilidad
- detección temprana de fallas
- continuidad operativa
- separación entre estado técnico y datos clínicos
- minimización de datos expuestos

No debe presentarse como cumplimiento total de HIPAA, Ley 29733, Ley 30024 u otra normativa. Debe describirse como un control técnico parcial dentro de un programa mayor de seguridad, privacidad y continuidad.

## Requisitos para `status-agent`

El `status-agent` debe devolver JSON operativo sin PHI.

Campos permitidos:

- estado general
- disponibilidad de servicios
- porcentaje de disco usado
- fecha del último backup exitoso
- fecha de última exportación
- versión de SIH Salus
- versión de contenido clínico
- días restantes de certificado
- cantidad de paquetes de sincronización pendientes

Campos prohibidos:

- nombres de pacientes
- documentos de identidad
- teléfonos
- direcciones
- UUIDs de pacientes
- diagnósticos
- resultados clínicos
- tokens
- passwords
- secretos
- connection strings

## Frase de cumplimiento recomendada

El semáforo local de SIH Salus es un control de disponibilidad y continuidad operativa. Esta diseñado para no procesar ni mostrar datos clínicos o personales. No constituye cumplimiento normativo completo por sí mismo; complementa controles de autenticación, autorización, auditoría, cifrado, backup, retención y respuesta a incidentes.
