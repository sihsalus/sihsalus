# Opciones de firma digital para Hospital Santa Clotilde

Revisión de fuentes oficiales: **16/10/2026**. Propuesta para decidir; no acredita
cumplimiento SIHCE ni incluye contratación, credenciales, cambios de configuración,
implementación o despliegue. La institución aún no ha confirmado proveedor,
certificados, titular contractual ni infraestructura de firma.

**Recomendación condicionada:** integrar Firma Perú oficial y su validador,
gestionados por la entidad responsable de Hospital Santa Clotilde (HSC), con
certificados individuales de los profesionales. Confirmar antes la categoría y
titularidad RENIPRESS, el perfil de certificado, la autenticación y la custodia
documental. PUCP puede integrar el software; no se presume que pueda solicitar
servicios reservados a entidades públicas como titular del hospital.

## Condiciones normativas verificadas

La norma es la **Directiva Administrativa 343-MINSA/OGTI-2023**, aprobada por
[RM 462-2023/MINSA](https://www.gob.pe/institucion/minsa/normas-legales/4234106-462-2023-minsa).
Se cotejó el [PDF oficial de 14 páginas](https://cdn.www.gob.pe/uploads/document/file/4570977/Directiva%20Administrativa%20N%C2%B0%20343-MINSA/OGTI-2023.pdf?v=1684344947),
incluidas sus imágenes; las páginas siguientes corresponden a ese PDF.

| Numeral y página | Condición que afecta la decisión |
| --- | --- |
| 5.3.6 y 5.3.8, p.7 | Admite persona natural autorizada y persona jurídica: en esta última el profesional es suscriptor y la institución titular. Deben incorporarse los datos profesionales exigidos. |
| 6.1.1–6.1.3, p.9 | Requiere autenticación y firma; contempla DNIe, token o smartcard. DIRIS/DIRESA/GERESA e IPRESS de segundo/tercer nivel gestionan certificados PJ y permiten además DNIe personal. |
| 6.1.4–6.1.5, p.9 | Verificar identidad, vínculo, rol, título y colegiatura; RENIEC es primera opción para entidades públicas. |
| 6.3.1(b), p.10 | El repositorio debe estar alojado físicamente en el establecimiento. Custodia exclusiva en nube requiere aclaración normativa previa. |
| 6.4.1, p.11 | Contingencia temporal por imposibilidad de firma: solicitud motivada, agente automatizado y habilitación administrativa con duración. |
| 6.5.1(a), p.12; 6.5.5–6.5.7, p.13 | Software acreditado; acceso con certificado de autenticación vigente/no revocado, autorización profesional y gestión del estado de la credencial. |

Estos requisitos impiden declarar cumplimiento solamente con una sesión de
usuario/contraseña y un botón de firma. La contingencia no autoriza sustituir
permanentemente la firma individual por un certificado compartido.

## Alternativas con componentes mantenidos por sus proveedores

| Opción | Qué se reutiliza | Mantenimiento y condiciones | Decisión propuesta |
| --- | --- | --- | --- |
| **Firma Perú, PCM** | Firmador web oficial y validador REST; formatos PAdES, XAdES y CAdES, niveles B/T/LTA. | Solicitud institucional de credenciales y registro de URLs/IP según componente; instalación cliente y soporte de puestos. La licencia es gratuita y limitada. | **Primera opción**, si HSC confirma elegibilidad, certificados, autenticación y custodia. Un solo firmador en el piloto. |
| **ReFirma PCX / Suite, RENIEC** | Invocación web mediante ReFirma Invoker; Suite 1.6 tiene seguimiento de acreditación publicado en 2026. | PCX documenta Windows, Java 8 y ClickOnce. T/LTA requiere convenio TSA. Confirmar soporte y licencia del paquete concreto; no inferir permiso de modificar por disponibilidad del código. | Preferible si la entidad ya lo opera y mantiene; no añadirlo en paralelo sin necesidad demostrada. |
| **PSVA de firma remota** | Creación remota por proveedor con alcance acreditado, consentimiento individual y API contractual. | Puede reducir lectores e instalaciones; añade dependencia de red, proveedor, SLA y contrato de datos. Verificar modalidad exacta, producto, versión y vigencia, además de EC/ER. | Alternativa **pendiente de encaje con MINSA/IOFE** para autenticación, dispositivo y custodia. No se ha elegido ni acreditado aquí un proveedor concreto. |

Fuentes de las alternativas: [acceso al firmador PCM](https://www.gob.pe/22273-solicitar-acceso-al-firmador-firma-peru-para-entidades-publicas),
[acceso al validador PCM](https://www.gob.pe/22274-solicitar-acceso-al-validador-de-firmas-digitales-firma-peru-para-entidades-publicas),
[PCX oficial](https://dsp.reniec.gob.pe/refirma_suite/pcx/web/main.jsf),
[acreditaciones RENIEC](https://pki.reniec.gob.pe/acreditaciones/),
[ROPS INDECOPI](https://www.gob.pe/institucion/indecopi/informes-publicaciones/5447866-registro-oficial-de-prestadores-de-servicios-de-certificacion-digital-rops)
y [requisitos de acreditación remota](https://www.gob.pe/institucion/indecopi/normas-legales/6107532-175-2024-dgi-indecopi).
La publicación ROPS localizada está fechada 09/07/2026; hay que verificar el
registro y las resoluciones vigentes del candidato al contratar, no reutilizar
esta fecha como garantía de vigencia futura.

La [licencia de Firma Perú](https://cdn.www.gob.pe/uploads/document/file/3061260/Condiciones%20de%20uso%20de%20la%20Plataforma%20Nacional%20de%20Firma%20Digital.pdf)
permite uso gratuito, pero restringe reproducción, modificación, adaptación,
cesión y venta. Integrar por interfaces oficiales y conservar el componente
separado del código propio; no incorporarlo al repositorio como obra de PUCP.
Sus condiciones describen estadísticas en Google Analytics e incorporación de
IP/MAC en PAdES: incluirlo en la revisión institucional de privacidad.

El [manual web de Firma Perú](https://resources.firmaperu.gob.pe/documentos/firmador-componente-web.pdf)
documenta un cliente local: no es un firmador íntegramente dentro del navegador.
En Windows recomienda Edge/ClickOnce; Linux y macOS tienen requisitos distintos
y soporte documentado para DNIe. Exige Internet para consultar revocación y TSL.
El piloto debe usar los equipos y conectividad reales del hospital; no se ha
verificado compatibilidad de sus puestos ni funcionamiento sin conexión.

No presentar una futura API remota RENIEC como servicio disponible para HSC:
la fuente localizada de 2026 corresponde a un [requerimiento de adquisición de
infraestructura SCFR](https://identidad.reniec.gob.pe/documents/d/guest/003a-integracion-requerimiento),
no a un contrato de integración listo para esta institución.

## Costos publicados y límites

| Concepto | Importe publicado | Alcance |
| --- | --- | --- |
| Licencia Firma Perú | Sin costo de licencia | No incluye integración, certificados, hardware, conectividad, archivo ni soporte local. |
| Certificado RENIEC de persona jurídica para suscriptor | **S/8,10** | Entidades de la administración pública, contrato y autorización de su representante; confirmar perfil individual para HSC. [Trámite oficial](https://www.gob.pe/31115-solicitar-certificacion-digital-solicitar-certificacion-digital-para-persona-juridica). |
| Renovación de certificados en DNIe | **S/6,60** | Renovación, no adquisición inicial de DNIe ni lector. [Trámite oficial](https://www.gob.pe/100089). |
| Sellado de tiempo RENIEC | **S/0,30** | Tarifa publicada; confirmar unidad, volumen y facturación por convenio. [Servicio oficial](https://www.gob.pe/31148-solicitar-certificacion-digital-solicitar-generacion-de-sellos-de-tiempo). |
| Servicio remoto privado | **Por cotizar** | No se verificó una tarifa oficial comparable para el alcance de HSC. |

Para PJ, RENIEC pide contrato, representante con certificado vigente,
autorización del suscriptor y documentación de identidad. La oficina TI solicita
los accesos PCM y declara sistemas/ambientes. El convenio TSA es un trámite
adicional. No se estimó costo total ni plazo contractual del proyecto.

## Flujo propuesto y adaptador mínimo del backend

Lo siguiente es una **propuesta de ingeniería**, pendiente de elección del
proveedor y aprobación institucional; no describe capacidades ya implementadas.
Frontend/content por sí solos no pueden acreditar identidad criptográfica,
preservación documental ni validación del resultado.

1. La entidad verifica identidad, vínculo y habilitación del profesional y
   tramita sus certificados de autenticación/firma. Seleccionar el mecanismo
   oficial de autenticación e integrarlo con la autorización existente; validar
   ese contrato por separado del firmador. No equiparar autenticación de la
   aplicación con prueba de posesión del certificado.
2. El servidor prepara una **revisión inmutable** del documento clínico y la
   vincula al paciente, atención, profesional y contenido a firmar. Mostrar esa
   revisión para aceptación; una edición concurrente debe invalidar la solicitud.
   La unidad documental y sus campos los decide el responsable clínico.
3. El adaptador solicita el token institucional desde servidor y entrega una
   solicitud de un solo uso, con vencimiento, vinculada a esa revisión. El
   profesional autoriza la operación en el cliente oficial con su propio PIN o
   mecanismo aprobado. Claves privadas y PIN no se reciben ni registran en
   SIHSalus. No introducir firmas clínicas HMAC ni criptografía propia.
4. Recibir el artefacto firmado de manera idempotente y validarlo en servidor:
   identidad autorizada del firmante, revisión esperada, integridad, cadena de
   confianza, estado de revocación, sello de tiempo si aplica y reporte completo.
   `signatureOk` o el filtro de certificado del navegador no bastan. La
   comparación de contenido debe respetar el formato: un PDF firmado cambia
   bytes; una firma separada requiere conservar y verificar su original exacto.
5. Registrar resultado y evidencias sin sobrescribir la revisión: documento
   original/firmado, referencia a certificado, reporte, fechas y trazas de acceso
   y operación. No copiar datos clínicos ni secretos a logs. Correcciones
   posteriores generan otra revisión y otra firma, conservando la anterior.
6. Renovaciones, pérdida, revocación y cese profesional tienen responsables
   institucionales. Inhabilitar acceso cuando corresponda no borra documentos
   históricos. Su validación histórica debe considerar el momento de firma y
   las evidencias preservadas; una revocación actual no se interpreta sin contexto.

Reutilizar los servicios existentes de autorización, documento y auditoría si
cubren ese contrato. Antes de estimar el adaptador, comprobar qué capacidades
ofrece el backend actual y cuál componente será responsable de cada ausencia.
Mantenerse en APIs soportadas; no parchear Core ni duplicar un framework de
documentos, permisos o claves. Si falta un repositorio inmutable o autenticación
por certificado, declarar esa brecha; no llamarla resuelta con un callback.

El [contrato REST del validador PCM](https://resources.firmaperu.gob.pe/documentos/validador-servicio-web.pdf)
distingue `VALID`, `INVALID`, `INDETERMINATE` y `NOSIGNATURE`, y requiere el
original para firmas separadas. Documenta despliegue en red interna. Una
respuesta indeterminada, incluidos fallos de consulta de revocación/TSL, deja
la validación pendiente; no se transforma en aprobación. No enviar historias
clínicas al validador público como sustituto del componente institucional.

## Aceptación y recuperación antes de habilitar uso clínico

La prueba debe usar documentos sintéticos y versiones concretas del adaptador,
firmador y validador. Registrar SHA/digest cuando exista y la versión acreditada
del proveedor. El certificado de prueba debe identificarse como tal; una
demostración con él no acredita producción.

- Probar autenticación por certificado y autorización profesional separadamente,
  después firma/validación con el perfil aprobado, incluyendo DNIe y PJ si ambos
  se ofrecen. Verificar identidad, rol, título y colegiatura mostrados.
- Rechazar documento alterado, firmante distinto, revisión obsoleta, solicitud
  expirada/reutilizada y resultado duplicado conflictivo. Conservar evidencia de
  las decisiones sin exponer el contenido clínico.
- Probar certificado expirado, revocado y cadena no confiable; distinguir
  fallo definitivo de indisponibilidad del proveedor o validación indeterminada.
- Verificar conservación y recuperación del documento, referencia a su atención
  y reporte de validación después de reinicio/restauración. Revisar sellado de
  tiempo y política de archivo de largo plazo con el custodio documental.
- Ensayar pérdida de conectividad: documento pendiente, aviso y recuperación
  trazable. Una contingencia con agente automatizado necesita procedimiento
  temporal aprobado; no se activa automáticamente para superar un error.
- Obtener aceptación del responsable clínico y de seguridad sobre documentos,
  autenticación, custodia y fallos. El CI no sustituye esa revisión.

Ante firmas atribuidas a otra persona, contenido divergente, pérdida de trazas,
validación insegura o imposibilidad de recuperar documentos, **no habilitar nuevas
firmas**. El plan de recuperación debe permitir volver al adaptador previamente
verificado, por versión inmutable y con aprobación de la operación concreta,
manteniendo el repositorio, las firmas ya emitidas y su evidencia. No restaurar
una base antigua que elimine actos posteriores; no marcar como firmado un
documento pendiente para reabrir el servicio. El procedimiento de continuidad
asistencial lo aprueba HSC antes del piloto.

## Decisiones y trámites pendientes

| Responsable propuesto, por confirmar | Decisión o evidencia necesaria |
| --- | --- |
| Dirección de HSC / entidad titular | RENIPRESS, categoría vigente, RUC/titular contractual, representación legal y responsable del SIHCE; autorización a PUCP como integrador. |
| Oficina TI institucional | Elegir una alternativa; solicitar accesos oficiales DEV/QLTY/PROD y acordar equipos, red, soporte, gestión de secretos y renovación. Sin incluir credenciales en documentos o repositorios. |
| Dirección clínica / RR. HH. | Nómina de perfiles habilitados, vínculo, colegiatura, unidad documental a firmar, correcciones, consentimiento y procedimiento de contingencia. |
| Asesoría jurídica / seguridad / MINSA | Encaje de firma remota y autenticación, custodia prevista frente a DA343 y normas posteriores; tratamiento de datos, responsabilidades y contrato/licencia. |
| Compras / entidad certificadora | Certificados de autenticación y firma adecuados, hardware si aplica, convenio TSA, tarifas efectivas y costos de renovación/operación. |
| Proveedor remoto, si se elige | Acreditación por modalidad/producto/versión, consentimiento individual, API, revocación, SLA, subencargados, ubicación de datos, exportación de evidencias y plan de salida. |
| Mantenedor y responsables de dominio | Aprobar alcance del adaptador y repositorio, PR/SHA, ensayos y posteriormente el ambiente/versión de una aplicación. Decisiones separadas. |

La firma del documento clínico y la firma de un IPS interoperable necesitan
contratos compatibles, pero no son evidencia intercambiable. El
[contrato IPS Perú](ips-peru-contract.md) mantiene sus propios límites de perfil,
identidad y autorización; un Bundle estructuralmente válido no prueba firma
IOFE, RENIPRESS ni acreditación del SIHCE.
