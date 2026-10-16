# Contrato publicado de IPS Perú y límites de conformidad

Revisión de fuentes oficiales: **16/10/2026**. Alcance institucional previsto:
Hospital Santa Clotilde; requisitos globales, admisión, consulta externa, CRED,
gestantes e inmunizaciones. Esta revisión y sus fixtures no acreditan a la
IPRESS, no prueban interoperabilidad en producción y no autorizan acceso a
pacientes, transmisión de documentos, cambios al backend ni despliegues.

## Fuente verificable

La [guía de MINSA](https://dyaku.minsa.gob.pe/guides/index.html) publica
`hl7.fhir.pe.CorePE#0.1`, FHIR R4 **4.0.1**, generado el **19/06/2026**. Su
ImplementationGuide tiene estado `draft`; la página lo identifica como
`Local Development build`. El [paquete oficial](https://dyaku.minsa.gob.pe/guides/package.tgz)
declara `notForPublication: true` y licencia **CC0-1.0**. No es una release
estable que pueda darse por aprobada para integración institucional.

- SHA-256 del paquete descargado:
  `f2928f5fda2549721c62ba7bcabd32288a93e2bc87c1bef293bf87a35938ecc7`.
- Canónica: `https://www.gob.pe/minsa/RENHICE/fhir`.
- Dependencias declaradas: `hl7.fhir.r4.core#4.0.1`,
  `hl7.terminology.r4#7.2.0`, `hl7.fhir.uv.extensions.r4#5.3.0`.
- Los perfiles clínicos son `draft`; `ConsentimientoRENHICE` está marcado
  `active`, pero pertenece al mismo paquete `0.1` en desarrollo.
- [Versiones](https://dyaku.minsa.gob.pe/guides/versiones.html) conserva una
  entrada incompleta `2023-05-XX`; no sirve como historial preciso de releases.

La evidencia descargada es pública y queda identificada por hash. Un cambio
del contenido servido bajo la misma versión exige revisar el diff y sus
pruebas; no se debe consumir silenciosamente una nueva descarga como si fuera
el artefacto ya verificado.

## Documento y referencias

El contrato computable procede de los `snapshot` y `differential` oficiales,
incluidas las reglas heredadas de FHIR R4. `mustSupport` no convierte un campo
`0..1` en obligatorio ni demuestra que el productor capture el dato.

| Elemento | Contrato publicado |
| --- | --- |
| `Bundle.type` | `document` |
| `Bundle.identifier` | El invariante R4 `bdl-9` exige `system` y `value` en documentos, aunque la cardinalidad visible sea `0..1` |
| `Bundle.timestamp` | Obligatorio para documentos por `bdl-10` |
| Primera entrada | `Composition`, por `bdl-11` |
| `Bundle.entry` | `3..*`, particiones cerradas; los requisitos conjuntos implican al menos Composition, Patient, Practitioner y Organization |
| Entradas de identidad | Exactamente un `Patient/PacientePe`, un `Practitioner/PractitionerPe` y un `Organization/OrganizacionPe` |
| Entradas clínicas admitidas | Cero o más `Condition/ConditionPe`, `AllergyIntolerance/AlergiaPe`, `MedicationStatement/MedicationStatementPe` |
| `Composition` | `status`, `type`, `subject`, `date`, `author`, `title`, `custodian`: `1..1`; autor PractitionerPe, paciente PacientePe y custodio OrganizacionPe |
| `Composition.section` | `1..*`, particiones abiertas; cada sección tiene `code 1..1` |
| `Bundle.signature` | `0..1`; el perfil no define acreditación de firma, certificado IOFE ni procedimiento de verificación |

Fuentes: [BundlePe](https://dyaku.minsa.gob.pe/guides/StructureDefinition-BundlePe.json),
[CompositionPe](https://dyaku.minsa.gob.pe/guides/StructureDefinition-CompositionPe.json)
y [documentos FHIR R4](https://hl7.org/fhir/R4/documents.html).

El `short` de `Composition.status` dice `final`, pero el perfil no contiene un
`fixedCode` ni `patternCode` que lo imponga. Tampoco fija el tipo documental
LOINC `60591-5`: aparece en el ejemplo; el binding de `type` es `preferred`.
El fixture usa `final` y ese tipo documental sin atribuirles una firma.

Las referencias directas de Composition deben estar incluidas y resolverse
dentro del documento. Usar `fullUrl` absolutos o URN UUID consistentes, no
copiar las URL relativas incorrectas del ejemplo oficial. La coherencia del
grafo, la identidad del paciente y la procedencia requieren pruebas además de
la validación estructural. No se deben descargar recursos clínicos externos
para completar silenciosamente un documento incompleto.

## Secciones y datos ausentes

| Sección tipificada en CompositionPe | LOINC | Cardinalidad | Entradas si existe la sección |
| --- | --- | --- | --- |
| Diagnósticos | `11450-4` | `0..*` | `1..*` referencias ConditionPe |
| Medicación | `10160-0` | `0..*` | `1..*` referencias MedicationStatementPe |
| Alergias | `48765-2` | `0..*` | `1..*` referencias AlergiaPe |

[EstructuraIPS](https://dyaku.minsa.gob.pe/guides/EstructuraIPS.html) describe
también vacunas, procedimientos CPMS, resultados y antecedentes. Sin embargo,
el BundlePe cerrado no incorpora `Immunization`, `Observation`, `Procedure`,
`DiagnosticReport`, `Medication`, `Encounter` ni `DocumentReference`. Añadir
esos recursos al Bundle no queda autorizado por la narrativa ni por la
partición abierta de las secciones. Este límite afecta directamente al alcance
CRED, gestantes e inmunizaciones; requiere aclaración o actualización oficial.

La narrativa contempla la ausencia de información y la ausencia de
alergias conocidas, pero utiliza una misma expresión y no proporciona una
codificación peruana inequívoca para ambas. No se debe transformar un error
de consulta, un dato no cargado o un paciente no evaluado en una negación
clínica. Tampoco crear alergias, diagnósticos o medicamentos ficticios para
completar una sección de un paciente real.

En las tres secciones tipificadas, `entry 1..*` impide usar exclusivamente
`emptyReason`; R4 `cmp-2` impide combinar `emptyReason` con entradas. Por
tanto, omitir una sección puede pasar CorePE y aun así no satisfacer la
semántica clínica de un IPS. La representación de estados desconocidos,
negados y no evaluados necesita resolución del responsable clínico y MINSA.

## Identidad y terminología

| Perfil | Requisitos verificables relevantes | Límite |
| --- | --- | --- |
| PacientePe | `identifier 1..*`; cada identificador requiere `type`, extensión de país emisor, `type.coding.code` y `value`; `name 1..*` con `family 1..1` y `given 1..*`; `gender 1..1`; `birthDate 1..1` | No verifica identidad en RENIEC/Migraciones ni impone longitud de DNI |
| PractitionerPe | Identificador con tipo, país emisor y valor; `name 1..*`, `family 1..1`; colegiatura en `qualification`, cuando se suministre | `qualification` y `name.given` siguen opcionales; un PASS no acredita habilitación profesional ni certificado |
| OrganizacionPe | `identifier 1..*`, cada valor `1..1`; `active 1..1`; `name` y `type` son mustSupport pero opcionales | `identifier.type 0..1`; si existe, su código tiene binding required a IPRESSVS, cuyo catálogo publicado es incompleto |
| ConditionPe | Paciente referenciado; si hay `code.coding`, exige sistema `http://hl7.org/fhir/sid/icd-10`, código y display; `code.text` requerido dentro de code | CIE10VS tiene binding preferred y no está incluido entre los ValueSets del paquete |
| AlergiaPe | `category 1..1`; referencia al paciente; `code.text` requerido dentro de code | No publica una terminología peruana completa para sustancias, ausencia o negación |
| MedicationStatementPe | Estado, medicamento y paciente según R4; soporte a fecha, dosis y vía textual | No restringe el producto a un catálogo nacional ni equivale a orden, dispensación o administración |

Fuentes: [PacientePe](https://dyaku.minsa.gob.pe/guides/StructureDefinition-PacientePe.json),
[PractitionerPe](https://dyaku.minsa.gob.pe/guides/StructureDefinition-PractitionerPe.json),
[OrganizacionPe](https://dyaku.minsa.gob.pe/guides/StructureDefinition-OrganizacionPe.json),
[ConditionPe](https://dyaku.minsa.gob.pe/guides/StructureDefinition-ConditionPe.json),
[AlergiaPe](https://dyaku.minsa.gob.pe/guides/StructureDefinition-AlergiaPe.json)
y [MedicationStatementPe](https://dyaku.minsa.gob.pe/guides/StructureDefinition-MedicationStatementPe.json).

El CodeSystem [IdspersonaPeru](https://dyaku.minsa.gob.pe/guides/CodeSystem-IdspersonaPeru.json)
define `1=DNI`, `2=CE`, `3=Pasaporte`, `4=Documento de identidad extranjero`.
HC, CNV y afiliación SIS no son esos identificadores: no deben usarse como
DNI por posición en una lista. `pe-pais` usa `valueCodeableConcept`, con
PaisesVS/PaisesCS; Perú es `PER`. No truncar ni completar una identidad para
forzar una coincidencia y no crear pacientes si falló la búsqueda previa.

[IPRESSCS](https://dyaku.minsa.gob.pe/guides/CodeSystem-IPRESSCS.json) declara
`content: complete` pero contiene un único código, `00031361`, correspondiente
a una organización de ejemplo que **no es Hospital Santa Clotilde**. No debe
copiarse. El ejemplo oficial de Organization omite el `identifier.type`
opcional y coloca la identificación RENIPRESS en `identifier.system/value`.
Esa forma puede pasar la estructura sin validar el valor contra un catálogo
nacional; no prueba registro ni categorización de una IPRESS.

El catálogo de colegios también necesita revisión: el código de nutricionistas
es literalmente `1O` (letra O), no `10`. No corregir unilateralmente códigos
oficiales ni confundir este catálogo con verificación de habilitación.

## Diferencias frente al IPS internacional

Se contrastó con la versión publicada [HL7 IPS 2.0.1](https://hl7.org/fhir/uv/ips/).
CorePE deriva de los recursos base R4, no de los perfiles `uv.ips`, y no declara
dependencia del paquete IPS internacional. No son contratos intercambiables.

| Aspecto | CorePE 0.1 | HL7 IPS 2.0.1 |
| --- | --- | --- |
| Secciones esenciales | Tres particiones `0..*`, total `1..*` | Problemas, alergias y medicación `1..1`; total mínimo 3 |
| Ausencia de entradas | Las tres particiones exigen `entry 1..*` | Admite `entry` o `emptyReason`, preservando la distinción clínica |
| Tipo de Composition | Binding preferred sin código fijado | Patrón LOINC `60591-5` |
| Bundle | Particiones cerradas, siete tipos de recurso | Particiones abiertas, recursos para vacunas, resultados, procedimientos, gestación y otros |
| Autor/custodio | Un Practitioner y una Organization obligatorios | Modelo más amplio; no impone esos mismos conteos |

Fuentes computables: [Composition IPS](https://hl7.org/fhir/uv/ips/StructureDefinition-Composition-uv-ips.json)
y [Bundle IPS](https://hl7.org/fhir/uv/ips/StructureDefinition-Bundle-uv-ips.json).
La [guía de datos ausentes](https://hl7.org/fhir/uv/ips/Empty-Sections-and-Missing-Data.html)
orienta la semántica IPS, pero no modifica el paquete peruano publicado.

## Autorización, transporte y firma: contratos separados

EstructuraIPS no especifica una API de envío ni un método de firma. La página
separada [InformedConsent](https://dyaku.minsa.gob.pe/guides/InformedConsent.html)
sí describe un flujo de acceso a documentos centralizados:

1. El paciente selecciona DocumentReference y crea un Consent.
2. Se genera un enlace SHLink con JWT RS256 y `consent_id`.
3. El consumidor verifica autorización activa y ventana temporal; obtiene el
   IPS mediante el endpoint ilustrado `/shlink/{session}/generate-ips`.
4. El SIHCE funciona como visor temporal con `Cache-Control: no-store` y
   `X-RENHICE-No-Persist: true`. La narrativa prohíbe almacenar, cachear o
   replicar el Bundle recibido.
5. Revocación, expiración, uso único y auditoría forman parte del flujo descrito.

El perfil [ConsentimientoRENHICE](https://dyaku.minsa.gob.pe/guides/StructureDefinition-ConsentimientoRENHICE.json)
exige `active` o `rejected`, paciente, scope `patient-privacy`, provisión
`permit`, inicio/fin y al menos un DocumentReference. El máximo computable es
30 minutos. `organization` está prohibido. No se debe confundir un estado
`active` persistido con una autorización aún vigente.

Hay discrepancias por resolver: la página dice versión `1.0.0`, el JSON dice
`0.1`; la página presenta category como opcional, pero R4 la exige; los ejemplos
omiten policy/policyRule y fallan `ppc-1`; la restricción narrativa de action
`access` no se materializa como patrón en el JSON. La narrativa incluye además
marcadores editoriales sin resolver. Falta confirmar con MINSA el contrato
operativo vigente, endpoints institucionales, autenticación, revocación y
pruebas de aceptación. No se ejecutó ninguno de esos endpoints.

[Lineamientos](https://dyaku.minsa.gob.pe/guides/Lineamientos.html) describe
autenticación de profesionales mediante certificado y funciones de firma.
Un JSON estructuralmente válido, `Composition.status=final`, un JWT de acceso,
un hash PDF o un usuario autenticado no demuestran firma clínica IOFE. Esta
suite no instala certificados, no simula firmas y no modifica controles.

La app Dyaku existente lee Patient y puede copiarlo a OpenMRS. Ese importador
no equivale al visor temporal de IPS autorizado. Su reutilización para RENHICE
requiere resolver propósito, autorización, procedencia y prohibición de
persistencia; no ampliar automáticamente la importación.

## Validación y fixtures propios

La referencia es el [validador HL7](https://hl7.org/fhir/R4/validation.html)
con FHIR R4 y el paquete oficial fijado; no un esquema JSON casero que replique
sus reglas. JSON Schema/Schematron por sí solos no cubren toda la terminología,
las particiones ni las reglas clínicas. Los `OperationOutcome` y el resultado
del proceso deben conservarse como evidencia de cada ejecución.

El paquete incluye perfiles JSON/XML, Schematron, ejemplos y un informe de QA.
Su propio `package/other/validation-summary.json` contiene **29 errores y 40
advertencias**: Bundle ejemplo 18 errores, Composition 4, Organization 1 y los
dos Consent 3 cada uno. Entre las causas figuran fullUrl relativas,
referencias no resueltas, displays LOINC y falta de policy/policyRule. Los
ejemplos publicados no son un oracle de éxito. Véase [QA oficial](https://dyaku.minsa.gob.pe/guides/qa.html).

Los fixtures de [tests/interop/fixtures](../../tests/interop/fixtures) son nuevos
y totalmente sintéticos. Sus nombres, documentos civiles y organización no
representan personas ni IPRESS reales. No contienen firma ni datos extraídos
de servidores:

| Fixture | Propósito |
| --- | --- |
| `positive-corepe-document.json` | Documento de siete recursos con las tres secciones, referencias internas y perfiles publicados |
| `negative-unresolved-reference.json` | Referencia de Composition a un paciente ausente; debe rechazarse |
| `negative-extra-immunization.json` | Immunization completo y referenciado, no admitido por las particiones cerradas de BundlePe |
| `semantic-cross-patient.json` | Condition referencia otro Patient contenido; expone que conformidad de perfiles no garantiza que toda la información pertenezca al paciente del documento |

El último caso exige una comprobación semántica explícita del sujeto.
`tests/interop/document_identity.py` aplica una regla adicional de seguridad
SIHSALUS: Condition, AllergyIntolerance y MedicationStatement deben resolver
al mismo recurso Patient que Composition.subject. No es una regla que se
atribuya al perfil peruano. Acepta referencias `fullUrl` absolutas o URN exactas
y `#id` en su contenedor inmediato. Rechaza referencias relativas, incluso
`ResourceType/id`, con `identity_relative_reference_unsupported`: este corte no
implementa resolución de bases FHIR y no debe confundir recursos del mismo ID
publicados en servidores distintos. También rechaza ambigüedades, referencias
ausentes y externas, tipos incorrectos y referencias históricas.
No busca por identificadores, no consulta redes y no modifica el documento.
No pretende implementar resolución FHIR general ni reemplaza el validador.

No se debe reportar un rechazo nativo que el validador no haya producido ni
rebajar el contrato FHIR para acomodarlo. Un positivo estructural con
identificación sintética tampoco valida un DNI, colegiatura, código RENIPRESS
o dato clínico.

El resultado ejecutado y sus diagnósticos se registran por la suite; este
documento no sustituye esa evidencia ni presume que las pruebas hayan pasado.
La integración real requiere datos institucionales verificados, aceptación
clínica del resumen, resolución de brechas oficiales y aprobación humana.
