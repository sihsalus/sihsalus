# Preparación de acreditación SIHCE — Hospital Santa Clotilde

Evaluación de ingeniería al **16 de octubre de 2026**, pendiente de revisión
institucional. Alcance confirmado: requisitos globales, gestión administrativa,
consulta externa, CRED, gestantes e inmunizaciones. No equivale a acreditar todo
el hospital, hospitalización, emergencia ni todos los servicios obstétricos.
La institución debe confirmar qué perfiles funcionales corresponden a sus
UPSS, categoría y servicios declarados.

**Todavía no hay evidencia suficiente para afirmar cumplimiento de la
acreditación.** Se encontraron funcionalidades y pruebas reutilizables, pero
faltan evidencias documentales, aceptación clínica y contratos externos.
No se modificó la hoja de evaluación ni se marcaron requisitos como aprobados.
Esta preparación no cambia el backend, dependencias, roles, datos o ambientes;
no autoriza merge, publicación ni despliegue.

## Base de la evaluación

La [RM 164-2025/MINSA](https://www.gob.pe/institucion/minsa/normas-legales/6551375-164-2025-minsa)
aprueba la DA 373-MINSA/OGTI-2025. La evaluación requiere cumplir los requisitos
obligatorios aplicables, documentales y funcionales; una lista de funcionalidades
o un porcentaje de pruebas unitarias no sustituye la resolución de
acreditación. El perfil global precede a los específicos. El cambio de versión
del SIHCE también debe tratarse según el procedimiento de actualización.

La [RM 188-2026/MINSA](https://busquedas.elperuano.pe/dispositivo/EX/2494135-1)
amplía el plazo de inicio del proceso; no elimina sus requisitos.
La guía técnica [IPS Perú](ips-peru-contract.md) es un contrato de
interoperabilidad en desarrollo, no toda la acreditación SIHCE.

La [hoja institucional revisada](https://docs.google.com/spreadsheets/d/1jksWmIHu4MAjWHay1I9U6_mDBBTij1NX7xTHR6NIVJs/edit?gid=1387621291#gid=1387621291)
contiene 25 pestañas. En Anexo 10 se encontraron 44 formatos y ninguna
calificación de cumplimiento registrada en el bloque revisado `A5:AF48`.
Las marcas X expresan aplicabilidad, no resultados de prueba. Hay respuestas
generales parciales en Anexo 1, pero no un expediente de aceptación completo.
Los anexos de requisitos revisados incluyen global (9), infraestructura (11),
RENHICE (12), recursos humanos (13), turnos (14), admisión (15), consulta externa
(16), inmunizaciones (17) y obstetricia (20). No se trasladó automáticamente
todo el perfil obstétrico al alcance de gestantes.

Los inventarios internos tampoco permiten calcular un porcentaje confiable:
el catálogo de 429 requisitos no contiene evaluaciones; enumera 35 formatos
frente a los 44 de la hoja. Una evaluación previa de admisión tiene totales
inconsistentes. Antes de presentar el expediente hay que reconciliar cada
identificador con la directiva vigente y confirmar la aplicabilidad con OGTI.

## Evidencia y acciones prioritarias

`P0` bloquea una afirmación de cumplimiento o una integración segura.
`P1` debe verificarse antes de solicitar evaluación. `P2` mejora mantenimiento
y reproducibilidad. «Pendiente de evidencia» no significa que la institución
carezca del documento: significa que no fue aportado ni verificado aquí.

| Prioridad / requisito | Evidencia revisada y límite | Acción y criterio de aceptación | Responsable propuesto |
| --- | --- | --- | --- |
| P0 — alcance y expediente | Alcance clínico confirmado por el solicitante; identificación legal, RENIPRESS, categoría, representantes y formatos firmados pendientes | Confirmar titular de HSC, código y categoría vigentes; mapear servicios a perfiles; completar expediente de la DA 373 con responsable y evidencia por fila | Dirección HSC / responsable de acreditación |
| P0 — firma y autenticación, global 004/008 | Consulta externa documenta firma manual; PDF y login actuales no demuestran firma digital IOFE ni autenticación con certificado | Seleccionar la [opción de firma](digital-signature-options.md), verificar producto/versión acreditados, certificados individuales, autenticación, revocación y custodia | HSC, TI, asesoría legal y profesionales |
| P0 — RENHICE, global 001/003/009/014 y Anexo 12 | Importador demográfico Dyaku existe; no prueba envío/consulta autorizada del resumen. CorePE 0.1 tiene contradicciones y excluye recursos de vacunas/resultados | Obtener contrato operativo, sandbox y criterios oficiales. Resolver [brechas del perfil](ips-peru-contract.md), autorización temporal y prohibición de persistencia antes de integrar | OGTI/MINSA + HSC + integración |
| P0 — identidad, admisión y global 004 | Importador podía inferir DNI por posición y crear después de búsquedas fallidas; el flujo de verificación DNI de registro tiene una función sin integración efectiva | Revisar corrección frontend Dyaku; validar coincidencia exacta tipo/valor, búsquedas completas, duplicados, identidad RENIEC/Migraciones y representantes en QLTY sintético | Equipo frontend + admisión HSC |
| P0 — acceso, global 005/006/007/010 | Existen controles y pruebas de autenticación; no se verificó aquí la matriz real de puestos, turno asistencial, paciente/representante ni compromisos | Matriz aprobada por rol y servicio; probar acceso permitido y denegado, expiración, desvinculación y acceso excepcional con evidencia. Ninguna concesión de permisos automática | HSC + seguridad + responsable clínico |
| P0 — datos clínicos y terminología, global 012/015 | CRED/Gestantes presentes; content PR 269 todavía falla preservación del orden en transición OCL | Mantener bloqueo de content. Resolver orden canónico sin perder observaciones ni identidades; aceptación clínica y regresión de conceptos/decimales/roles antes de promover | Terminología + responsables CRED/Gestantes |
| P0 — integridad, auditoría y retención, global 011/013 | Biblioteca de auditoría y versiones existen; instrumentación integral, inmutabilidad, lectura/exportación y retención no demostradas | Evidenciar acceso, consulta, cambios, anulación, firma y exportación, autor/tiempo/motivo; retener versiones previas sin datos sensibles en logs generales | Seguridad + TI + dirección clínica |
| P0 — intercambio seguro | Excepciones de imagen existentes son temporales y específicas de DEV/QLTY; no son aceptación productiva | Revisar escaneo vigente del digest candidato y vencimientos; resolver riesgos antes de promoción. No extender excepciones ni desactivar controles para la acreditación | Seguridad + mantenedor |
| P1 — consulta externa, Anexo 16 | Aplicación y resumen de atención disponibles; no se validaron los 63 criterios individualmente | Ejecutar circuito completo de admisión, antecedentes, atención, diagnóstico, tratamiento, referencias, cierre y corrección con responsable clínico | Jefatura de consulta externa |
| P1 — CRED y gestantes | Hay formularios, antecedentes y flujos específicos; presencia de formulario no prueba regla clínica, completitud HCMP ni trazabilidad | Matriz por requisito/formato y caso clínico sintético, con valores límite, fechas, autor y versiones; resolver semántica clínica antes de calcular indicadores | Enfermería CRED y obstetricia |
| P1 — inmunizaciones, Anexo 17 | Módulo disponible; issues 376/377 siguen abiertos y aceptación QLTY pendiente | Probar vacuna/dosis/lote/vencimiento/profesional/fecha/contraindicaciones/reacción y consulta por roles. Conservar el dato «desconocido» distinto de negación | Inmunizaciones + QA |
| P1 — catálogos e integraciones administrativas | La hoja solicita RENIEC, CPMS, medicamentos, colegios, IAFAS, UPSS y episodios; existencia de catálogos locales no demuestra vigencia ni convenios | Inventario con fuente, versión, fecha, cobertura y sincronización; documentar convenio/servicio y manejo seguro de indisponibilidad | Admisión + farmacia + TI |
| P1 — respaldo/recuperación, global 016 | [Simulacro CI del 12/10](https://github.com/sihsalus/sihsalus/actions/runs/38296606481) exitoso, con datos sintéticos y alcance limitado | Evidencia del ambiente real: frescura, cifrado, custodia, restauración de todos los componentes, tiempos RPO/RTO aprobados y recuperación de documentos firmados | Operaciones HSC |
| P1 — infraestructura, soporte y documentación, global 002/017 | Monitoreo, guías y pruebas existen; no se auditó inventario físico, continuidad, licencias, capacitaciones ni expediente legal | Completar Anexos 2/11: activos, conectividad, UPS, continuidad, soporte, manuales, capacitación, bancos de datos y compromisos exigidos | TI + dirección + legal |
| P2 — evidencia repetible | Nueva suite sintética usa HL7 oficial y reglas de identidad separadas | Conservar SHA, artefactos de CI y resultados por versión. Los cambios del paquete MINSA requieren revisión explícita de hash y pruebas | Mantenedor + QA |

Evidencia de código tomada del frontend `0420291580c1a5d8ee3c39712afa8b62174eceea`
y distro `bdfa1bb78095e59fc24eb655bb39aa352fdf5681`, más los PR de preparación.
Referencias de código: `esm-atencion-ambulatoria-app/README.md` (firma manual),
`esm-patient-registration-app/src/patient-registration/identity/identity-verification.resource.ts`
(verificación DNI del flujo de registro), `esm-salud-materna-app/README.md`
(alcance HCMP), `esm-audit-logger/README.md` (cobertura pendiente) y
`esm-patient-immunizations-app/README.md` (aceptación pendiente).
La evidencia documental de código no sustituye comprobar la versión desplegada.

## Entregables técnicos de esta preparación

1. **Frontend Dyaku:** propuesta para identificación explícita, búsqueda local
   reciente y completa, rechazo de ambigüedad, conservación de identificadores
   existentes y exclusión de importaciones concurrentes del mismo DNI en una
   instancia de la aplicación. No proporciona bloqueo entre equipos ni una
   garantía de unicidad transaccional del servidor.
2. **Contrato IPS:** perfiles y narrativa contrastados, diferencias con HL7 IPS,
   errores del ejemplo oficial, autorización y preguntas concretas a MINSA en
   [el análisis técnico](ips-peru-contract.md).
3. **Pruebas de desarrollo:** [suite de conformidad](../../tests/README.md#conformidad-renhice-con-datos-sintéticos)
   con validador HL7 y paquete MINSA verificados por SHA-256. Documento válido,
   referencia rota, vacuna incompatible y mezcla de pacientes. Sin pacientes
   reales, consultas clínicas, certificados ni modificación de ambientes.
4. **Decisión de firma:** tres opciones, condiciones y criterios de aceptación
   en [firma digital](digital-signature-options.md). No se contrató proveedor ni
   se instalaron componentes/certificados.

El PR de frontend CRED [1229](https://github.com/sihsalus/sihsalus-frontend/pull/1229)
y el PR de content [269](https://github.com/sihsalus/sihsalus-content/pull/269)
siguen separados. La transición OCL de este último conserva cantidades y
UUID, pero la prueba de actualización encontró **2922 pesos de respuestas
convertidos a NULL y dos pesos de conjuntos modificados**. El caso de talla
decimal pasó; eso no autoriza ignorar el resto de la regresión. No se afirma
que esos cambios estén desplegados ni que los issues clínicos estén cerrados.
La prueba histórica de actualización completó sus fases previas, pero agotó
el tiempo al comprobar el último reinicio tras rechazo controlado. Ese reintento
también sigue pendiente de evidencia; no se amplió el límite ni se omitió el control.

## Secuencia de aceptación

1. **Expediente:** designar responsable y revisar aplicabilidad con OGTI. Cada
   fila de evaluación debe registrar ID oficial, versión/digest, entorno,
   evidencia, resultado, fecha y revisor. Usar «no aplica» únicamente con
   sustento institucional; no rellenar X como «cumple».
2. **Pruebas locales/CI:** revisar diffs, controles de seguridad, regresión y
   fixtures sintéticos. Separar error de infraestructura, validación estructural
   y resultado semántico. Conservar advertencias de terminología.
3. **QLTY autorizado:** reservar cuentas existentes por rol y pacientes
   inequívocamente sintéticos. No conceder permisos ni escribir datos hasta
   aprobar el plan y el candidato concreto. Registrar situación inicial y
   final, sin PHI en capturas, logs ni repositorios.
4. **Circuitos funcionales:** admisión → programa → consulta CRED/gestantes/CE
   → indicaciones/inmunización → cierre y consulta posterior. Probar además
   usuario sin permiso, fecha previa al nacimiento, alta incoherente,
   hospitalización contradictoria, talla decimal, actualización de reacciones,
   doble envío, desconexión y datos incompletos. La persona clínica valida el
   significado y completitud, no solamente la respuesta HTTP.
5. **Integración externa:** solo con contrato y sandbox oficiales, validar
   resumen, ausencia de datos, identidad y catálogos; autorización temporal,
   revocación y no persistencia; autenticación y firma/certificado válidos,
   caducados, revocados y documento alterado. Verificar auditoría y custodia.
6. **Recuperación:** demostrar respaldo y restauración integral en entorno
   aislado, incluida evidencia de firma y versiones. Una reversión de software
   no debe borrar documentos firmados ni revertir datos clínicos a ciegas.
7. **Presentación:** responsable institucional revisa todos los obligatorios
   aplicables, manuales y formatos firmados. Solicitar evaluación formal; no
   anunciar acreditación antes de su resolución.

## Decisiones que todavía requieren intervención humana

- Confirmar titular legal, RENIPRESS/categoría y responsable del expediente de
  Hospital Santa Clotilde; obtener documentos y convenios institucionales.
- Elegir proveedor y modalidad de firma/autenticación tras verificar elegibilidad,
  acreditación vigente, certificados por profesional, soporte y custodia.
- Resolver con MINSA las contradicciones de CorePE y obtener contrato vigente,
  sandbox, endpoints, autorización y pruebas de aceptación. Este documento no
  autoriza enviar comunicaciones ni datos a MINSA.
- Aprobar con responsables clínicos contenido longitudinal del resumen,
  representación de desconocido/negado y aplicabilidad del perfil obstétrico.
- Resolver la pérdida del orden de catálogo en content antes de integrar la
  transición OCL. No omitir la comprobación ni mantener un OMOD propio sin
  una decisión explícita.
- Si los contratos confirmados lo requieren, revisar una propuesta mínima de
  backend para emitir la versión documental autorizada, verificar firma y
  certificado, hacer cumplir acceso/no persistencia y registrar auditoría.
  Intentar imponerlo solo desde JavaScript no ofrece garantía del servidor.
  Se reutilizarán servicios oficiales existentes cuando sean compatibles;
  no se propone modificar Core, OMOD o controles sin un diff específico.
- Aprobar por separado cualquier merge, cambio de rol, prueba con escritura,
  publicación o despliegue con SHA/versión y entorno identificados.
