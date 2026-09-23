# Inventario, vulnerabilidades y promoción de imágenes

Los tres publicadores de este repositorio —backend, gateway y certbot— usan
`.github/actions/check-image` antes de firmar y promover una imagen. Backend
publica `linux/amd64`; gateway y certbot publican `linux/amd64` y `linux/arm64`.
Cada plataforma debe tener un inventario SPDX adjunto por BuildKit y un escaneo
Trivy del digest exacto de su manifiesto ejecutable.

El modo vigente es **`report-only`**, configurado en `vulnerabilityMode` de
`scripts/security/image-exceptions.json`. Los hallazgos de vulnerabilidades se
publican como advertencias y no bloquean PR ni releases. Esto aplica al backend,
gateway y certbot, e incluye la comparación del backend con su base OpenMRS.
Compilación, pruebas funcionales, escaneo completo, SBOM, firma e identidad del
digest siguen siendo obligatorios. Para reactivar el bloqueo, cambiar ese campo
a `enforce` y generar evidencia nueva; no hay que modificar los workflows.

Gateway y el wrapper del frontend fijan la misma base Nginx 1.30.5 por digest;
Certbot fija la versión 5.8.0 y actualiza los paquetes Alpine al construir.
La construcción comprueba sus dependencias con `pip check` y desinstala `pip`:
el instalador y sus bibliotecas vendorizadas no son necesarios para emitir o
renovar certificados. Los plugins adicionales requieren reconstruir la imagen
e instalarlos antes de retirar `pip`; no se instalan durante la ejecución.
Las pruebas de rutas y caché toman la base del Dockerfile correspondiente para
evitar validar una versión distinta. Antes de firmar, el publicador de Gateway
ejercita sus rutas HTTP/HTTPS; el de Certbot verifica el plugin webroot, opciones CLI
y la generación de un certificado sintético sin red. El cambio de base requiere
reconstrucción y despliegue coordinado; no modifica certificados existentes.

## Secuencia de publicación

1. Validar el catálogo de excepciones vigente.
2. Construir una sola vez con `sbom: true` y `provenance: mode=max`. Subir el
   resultado bajo `candidate-<SHA>-<run>-<attempt>` para poder inspeccionar y
   escanear exactamente los bytes del registry. Ese tag es un candidato de CI.
3. Inspeccionar el índice por digest, comprobar las attestations de cada hijo y
   obtener los documentos SPDX. Los descriptores `unknown/unknown` deben ser
   attestations BuildKit vinculadas a un hijo ejecutable del índice.
4. Escanear **todos** los hijos por digest con Trivy 0.74.0 y `--image-src remote`.
   Se verifican el sujeto del informe, su arquitectura y la revisión OCI
   `org.opencontainers.image.revision` contra el commit del workflow. Se incluyen
   HIGH y CRITICAL con y sin versión corregida.
5. Aplicar la política, conservar evidencia depurada y, si pasa, firmar el índice
   por digest con Cosign. Backend conserva además sus comprobaciones de OMOD,
   contratos y comparación de vulnerabilidades con la base OpenMRS.
6. Publicar `sha-<SHA>` y, únicamente desde `main`, `latest`, reutilizando ese
   índice. Después de actualizar cada alias se exige que resuelva al digest
   escaneado. No se reconstruye la imagen para promoverla.

Un fallo en inventario, ejecución del escaneo, validación de evidencia o firma
impide publicar los aliases de release. En modo `enforce`, también los impiden
los hallazgos sin excepción. El candidato puede permanecer en GHCR para investigación y no debe
desplegarse como release. Una firma identifica al publicador; antes de desplegar
se deben verificar también la decisión de la política y la aceptación del
ambiente correspondiente.

## Política HIGH/CRITICAL y excepciones

En `report-only`, cada hallazgo HIGH o CRITICAL conserva su identidad, versión y
severidad, incluso si no tiene corrección. La decisión es `warn` cuando quedan
hallazgos sin excepción, y `pass` cuando no los hay. Un escaneo fallido no se
convierte en una advertencia ni en un informe limpio. El ratchet del backend
también conserva sus conteos y advierte sobre paquetes del sistema corregibles
y hallazgos nuevos frente a OpenMRS.

En `enforce` se bloquea cada hallazgo sin excepción y se aplican los rechazos del
ratchet. Una política histórica sin `vulnerabilityMode` conserva este modo
estricto; valores desconocidos son errores. El catálogo `exceptions` sigue vacío.
Una excepción requiere PR
revisado, responsable identificable y un issue de seguimiento. Su alcance
incluye repositorio de imagen, plataforma, CVE/advisory, nombre y versión exacta
del paquete, clase, ecosistema y severidad. Una versión, arquitectura, ecosistema
o severidad diferente deja de estar cubierta. No se admiten comodines.

Cada entrada contiene:

| Campo | Requisito |
| --- | --- |
| `id` | Identificador único y estable de la excepción |
| `repository` | Repositorio exacto, por ejemplo `ghcr.io/sihsalus/sihsalus-backend` |
| `platform` | `linux/amd64` o `linux/arm64` |
| `vulnerabilityId` | Identificador exacto informado por Trivy |
| `packageName`, `installedVersion` | Paquete y versión exactos |
| `class`, `type` | Clase y ecosistema del informe, por ejemplo `lang-pkgs` / `jar` |
| `severity` | `HIGH` o `CRITICAL` |
| `owner` | Usuario o equipo GitHub que asume el seguimiento |
| `issue` | Issue de SIHSalus que registra decisión, mitigación y resolución |
| `rationale` | Justificación concreta; sin contraseñas ni configuración privada |
| `createdOn`, `expiresOn` | Fechas ISO; vencimiento máximo a 30 días de la creación |

Las fechas se evalúan en UTC, incluyendo el día de vencimiento. El día siguiente
la excepción falla, aunque la imagen o el paquete no hayan cambiado. Una entrada
vencida debe retirarse o renovarse mediante otra revisión con evidencia vigente;
no se renueva automáticamente. El control de promoción vuelve a validar el
catálogo, su checksum y una evidencia de escaneo de menos de 24 horas.

El modo informativo permite publicar con vulnerabilidades conocidas; no las
marca como corregidas ni cierra las alertas. La remediación del backend sigue en
[#323](https://github.com/sihsalus/sihsalus/issues/323). El modo y las excepciones
forman parte del checksum de la política, de modo que un cambio invalida la
evidencia anterior y exige un escaneo nuevo antes de promover.

## Evidencia sin credenciales

El escáner se limita explícitamente a vulnerabilidades. Incluso así, su JSON
completo puede incluir `ImageConfig` y variables de entorno. Por eso los informes
crudos y la extracción SPDX se guardan en un directorio temporal privado, se
eliminan al terminar y no se suben como artefactos de Actions.

La evidencia publicada contiene únicamente imagen/commit, versión del escáner,
fecha UTC, checksum del catálogo, plataformas/digests, formato y checksum del
SPDX, número de paquetes y hallazgos normalizados. El campo histórico `blockedFindings`
cuenta hallazgos sin excepción; con decisión `warn` es informativo. Las excepciones utilizadas
se identifican por ID, responsable, vencimiento e issue. No incluye variables,
descripciones libres, fragmentos de archivos, rutas objetivo ni resultados de
escaneo de secretos. Los errores operativos muestran la fase fallida sin volcar
configuración ni salida cruda de las herramientas.

Los artefactos `backend-image-security-<SHA>`, `gateway-image-security-<SHA>` y
`certbot-image-security-<SHA>` se conservan durante **90 días**, tanto si la
política acepta, advierte o bloquea un informe válido. Si la inspección o el escaneo
no concluyen, el job falla sin fabricar evidencia de éxito. El SPDX completo y
la provenance permanecen adjuntos al índice en GHCR; conservar los digests de
las releases necesarias para auditoría y rollback.

Cada comando tiene además un límite externo: 30 segundos para consultar la
versión, 120 para cada inspección del registry y 900 por escaneo de plataforma,
incluida la descarga de las bases de vulnerabilidades y Java. Tras cinco segundos
de gracia se detiene únicamente el grupo de procesos creado para ese comando.
Esto también cubre descargas que no obedecen el timeout interno de Trivy; el
control falla con código 124, sin fabricar evidencia ni promover la imagen.

## Verificar firma e inventario

Usar el digest registrado en la release, y el workflow publicador correspondiente.
Ejemplo para gateway publicado desde `main`:

```bash
IMAGE='ghcr.io/sihsalus/sihsalus-gateway@sha256:<digest-revisado>'
cosign verify "$IMAGE" \
  --certificate-identity 'https://github.com/sihsalus/sihsalus/.github/workflows/build-gateway.yml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com'

docker buildx imagetools inspect "$IMAGE" --raw > image-index.json
python3 scripts/security/image-policy.py platforms "$IMAGE" image-index.json
docker buildx imagetools inspect "$IMAGE" --format '{{json .SBOM}}' > image-sbom.json
```

Para backend y certbot cambiar tanto repositorio como nombre del workflow a
`build-backend.yml` o `build-certbot.yml`. La identidad exacta de `main` es parte
de la verificación de releases; un build manual de otra rama conserva otra
identidad.

La firma autentica el índice por digest. Ese índice contiene las referencias a
los manifiestos de cada plataforma y sus attestations; los documentos SPDX se
obtienen de esa misma referencia inmutable. BuildKit usa SPDX dentro de
attestations in-toto, descritas en la [documentación oficial de Docker](https://docs.docker.com/build/metadata/attestations/sbom/).
La verificación de identidad y emisor sigue la [documentación de Cosign](https://docs.sigstore.dev/cosign/verifying/verify/).

Para repetir la política con la base de vulnerabilidades vigente y obtener una
nueva evidencia depurada conforme al modo vigente, desde un checkout revisado y con Trivy 0.74.0:

```bash
bash scripts/security/scan-image.sh "$IMAGE" '<SHA-fuente-completo>' nueva-evidencia
```

El directorio debe ser nuevo. La comprobación puede fallar posteriormente por
una excepción vencida o, en modo `enforce`, un nuevo advisory, aunque una release
antigua hubiera pasado su CI.

## Pruebas y alcance

```bash
python3 -B -m unittest discover -s tests/security -p 'test_image_*.py' -v
bash tests/backend/vulnerability-ratchet-config.sh
```

La suite rápida comprueba la política con fixtures locales, sin registry ni
builds de prueba. Los workflows de publicación siguen exigiendo SBOM, escaneo
por digest, política de excepciones y firma antes de promover la imagen real.

El frontend publica desde `sihsalus-frontend`, con su propio workflow y controles.
Este documento cubre los tres publicadores de imágenes del distro; la promoción
del conjunto sigue requiriendo revisión, aceptación en QLTY y el
[checklist de despliegue](deploy-checklist.md).
