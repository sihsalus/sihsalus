# Inventario, vulnerabilidades y promoción de imágenes

Los tres publicadores de este repositorio —backend, gateway y certbot— usan
`.github/actions/check-image` antes de firmar y promover una imagen. Backend
publica `linux/amd64`; gateway y certbot publican `linux/amd64` y `linux/arm64`.
Cada plataforma debe tener un inventario SPDX adjunto por BuildKit y un escaneo
Trivy del digest exacto de su manifiesto ejecutable.

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

Un fallo en inventario, escaneo, política o firma impide publicar los aliases de
release. El candidato puede permanecer en GHCR para investigación y no debe
desplegarse como release. Una firma identifica al publicador; antes de desplegar
se deben verificar también la decisión de la política y la aceptación del
ambiente correspondiente.

## Política HIGH/CRITICAL y excepciones

El comportamiento por defecto es bloquear cada hallazgo HIGH o CRITICAL,
incluidos los que todavía no tienen corrección. No se agrega una excepción
automática por estar presente en una imagen base. Los controles existentes del
backend siguen siendo adicionales: una excepción no desactiva el rechazo de
vulnerabilidades corregibles del sistema operativo ni el de hallazgos nuevos
frente a la base OpenMRS.

`security/image-exceptions.json` empieza vacío. Una excepción requiere PR
revisado, responsable identificable y un issue de seguimiento. Su alcance
incluye repositorio de imagen, plataforma, CVE/advisory, nombre y versión exacta
del paquete, clase, ecosistema y severidad. Una versión, arquitectura, ecosistema
o severidad diferente vuelve a bloquearse. No se admiten comodines.

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

Este cambio puede detener una publicación que antes pasaba por heredar un
hallazgo de OpenMRS. Resolverlo con una actualización probada o con una excepción
explícitamente revisada; no sustituir el umbral por `exit-code: 0`, modificar el
informe ni deshabilitar el control. Los valores del catálogo son decisiones de
seguridad que los mantenedores deben revisar antes de incorporarlos.

## Evidencia sin credenciales

El escáner se limita explícitamente a vulnerabilidades. Incluso así, su JSON
completo puede incluir `ImageConfig` y variables de entorno. Por eso los informes
crudos y la extracción SPDX se guardan en un directorio temporal privado, se
eliminan al terminar y no se suben como artefactos de Actions.

La evidencia publicada contiene únicamente imagen/commit, versión del escáner,
fecha UTC, checksum del catálogo, plataformas/digests, formato y checksum del
SPDX, número de paquetes y hallazgos normalizados. Las excepciones utilizadas
se identifican por ID, responsable, vencimiento e issue. No incluye variables,
descripciones libres, fragmentos de archivos, rutas objetivo ni resultados de
escaneo de secretos. Los errores operativos muestran la fase fallida sin volcar
configuración ni salida cruda de las herramientas.

Los artefactos `backend-image-security-<SHA>`, `gateway-image-security-<SHA>` y
`certbot-image-security-<SHA>` se conservan durante **90 días**, tanto si la
política acepta como si bloquea un informe válido. Si la inspección o el escaneo
no concluyen, el job falla sin fabricar evidencia de éxito. El SPDX completo y
la provenance permanecen adjuntos al índice en GHCR; conservar los digests de
las releases necesarias para auditoría y rollback.

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
nueva evidencia depurada, desde un checkout revisado y con Trivy 0.74.0:

```bash
bash scripts/security/scan-image.sh "$IMAGE" '<SHA-fuente-completo>' nueva-evidencia
```

El directorio debe ser nuevo. La comprobación puede fallar posteriormente por
un nuevo advisory o una excepción vencida, aunque una release antigua hubiera
pasado su CI.

## Pruebas y alcance

```bash
python3 -B -m unittest discover -s tests/security -p 'test_image_*.py' -v
bash tests/backend/vulnerability-ratchet-config.sh
```

El job obligatorio `Image attestations and policy` utiliza un registry temporal
en `127.0.0.1`, dos plataformas y paquetes sintéticos. Comprueba el recorrido real
BuildKit/SPDX/Trivy y la promoción por el mismo digest, e incluye un valor falso
de credencial para comprobar que no aparece en la evidencia. Elimina únicamente
su builder, registry y volumen de prueba. No arranca servicios clínicos, no
publica imágenes de producto y no modifica DEV, QLTY ni producción.

El frontend publica desde `sihsalus-frontend`, con su propio workflow y controles.
Este documento cubre los tres publicadores de imágenes del distro; la promoción
del conjunto sigue requiriendo revisión, aceptación en QLTY y el
[checklist de despliegue](deploy-checklist.md).
