# Semaforo local: privacidad y cumplimiento

Este documento define los controles mínimos para que el semáforo local de SIH Salus apoye disponibilidad operativa sin procesar datos clínicos ni datos personales.

## Alcance

El semaforo local es un control de disponibilidad y continuidad operativa. No reemplaza controles de seguridad clinica, auditoria del EMR, gestion de usuarios, cifrado, backup, retencion documental ni respuesta a incidentes.

## Principios

- No debe consultar endpoints que devuelvan datos personales o datos de salud.
- No debe mostrar nombres, documentos, telefonos, direcciones, diagnosticos, resultados, notas clinicas ni identificadores de pacientes.
- No debe almacenar cuerpos de respuesta con informacion sensible.
- No debe exponer logs tecnicos al personal clinico o administrativo.
- Debe separar la vista operativa del soporte tecnico.
- Debe usar lenguaje de continuidad asistencial, no codigos tecnicos como unica salida.

## Uso permitido de Gatus

Gatus puede usarse para verificar disponibilidad de servicios y endpoints tecnicos sin PHI.

Checks permitidos:

- `GET /health`
- `GET /startup`
- `GET /ready`
- `GET /openmrs/health/started`
- `GET /openmrs/ws/rest/v1/session` solo para validar disponibilidad de sesion, sin usuario autenticado
- Endpoints propios de `status-agent` que devuelvan solo estado operativo

Checks no permitidos:

- Busquedas de pacientes
- Listados de encuentros
- Observaciones clinicas
- Resultados de laboratorio
- Recursos FHIR con datos identificables
- Logs de aplicacion con contenido clinico
- Endpoints administrativos que devuelvan secretos, tokens o configuracion sensible

## Controles de acceso

Vista para personal clinico o administrativo:

- Solo lectura
- Sin datos clinicos
- Sin acceso a Docker
- Sin acciones destructivas
- Mensajes de accion recomendada claros

Vista para soporte tecnico:

- Restringida a red administrativa, VPN o tunel SSH
- Protegida con credenciales
- Con registro de acciones si permite reinicios, cambios o restauraciones

## Estados permitidos

El semaforo debe resumir el estado en categorias operativas:

- `verde`: puede atender pacientes y guardar informacion
- `amarillo`: puede atender, pero requiere accion preventiva
- `rojo`: atencion digital comprometida o riesgo alto de perdida de datos

Cada estado amarillo o rojo debe incluir una accion recomendada.

Ejemplos:

- `Conectar USB de backup semanal`
- `Liberar espacio en disco`
- `Contactar soporte tecnico`
- `No apagar el servidor durante restauracion`
- `Usar contingencia en papel hasta recuperar base de datos`

## Evidencia auditable

El semaforo puede servir como evidencia de:

- monitoreo de disponibilidad
- deteccion temprana de fallas
- continuidad operativa
- separacion entre estado tecnico y datos clinicos
- minimizacion de datos expuestos

No debe presentarse como cumplimiento total de HIPAA, Ley 29733, Ley 30024 u otra normativa. Debe describirse como un control tecnico parcial dentro de un programa mayor de seguridad, privacidad y continuidad.

## Requisitos para `status-agent`

El `status-agent` debe devolver JSON operativo sin PHI.

Campos permitidos:

- estado general
- disponibilidad de servicios
- porcentaje de disco usado
- fecha del ultimo backup exitoso
- fecha de ultima exportacion
- version de SIH Salus
- version de contenido clinico
- dias restantes de certificado
- cantidad de paquetes de sincronizacion pendientes

Campos prohibidos:

- nombres de pacientes
- documentos de identidad
- telefonos
- direcciones
- UUIDs de pacientes
- diagnosticos
- resultados clinicos
- tokens
- passwords
- secretos
- connection strings

## Frase de cumplimiento recomendada

El semaforo local de SIH Salus es un control de disponibilidad y continuidad operativa. Esta disenado para no procesar ni mostrar datos clinicos o personales. No constituye cumplimiento normativo completo por si mismo; complementa controles de autenticacion, autorizacion, auditoria, cifrado, backup, retencion y respuesta a incidentes.
