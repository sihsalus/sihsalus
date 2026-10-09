# Inventario, vulnerabilidades y promoción de imágenes

Los tres publicadores de este repositorio —backend, gateway y certbot— usan
`.github/actions/check-image` antes de firmar y promover una imagen. Backend
publica `linux/amd64`; gateway y certbot publican `linux/amd64` y `linux/arm64`.
Cada plataforma debe tener un inventario SPDX adjunto por BuildKit y un escaneo
Trivy del digest exacto de su manifiesto ejecutable.

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

`scripts/security/image-exceptions.json` registra las aceptaciones temporales. Una excepción requiere PR
revisado, responsable identificable y un issue de seguimiento. Su alcance
incluye repositorio de imagen, plataforma, CVE/advisory, nombre y versión exacta
del paquete, clase, ecosistema y severidad. Una versión, arquitectura, ecosistema
o severidad diferente vuelve a bloquearse. No se admiten comodines.

Cada entrada contiene:

| Campo                             | Requisito                                                           |
| --------------------------------- | ------------------------------------------------------------------- |
| `id`                              | Identificador único y estable de la excepción                       |
| `repository`                      | Repositorio exacto, por ejemplo `ghcr.io/sihsalus/sihsalus-backend` |
| `platform`                        | `linux/amd64` o `linux/arm64`                                       |
| `vulnerabilityId`                 | Identificador exacto informado por Trivy                            |
| `packageName`, `installedVersion` | Paquete y versión exactos                                           |
| `class`, `type`                   | Clase y ecosistema del informe, por ejemplo `lang-pkgs` / `jar`     |
| `severity`                        | `HIGH` o `CRITICAL`                                                 |
| `owner`                           | Usuario o equipo GitHub que asume el seguimiento                    |
| `issue`                           | Issue de SIHSalus que registra decisión, mitigación y resolución    |
| `rationale`                       | Justificación concreta; sin contraseñas ni configuración privada    |
| `createdOn`, `expiresOn`          | Fechas ISO; vencimiento máximo a 30 días de la creación             |

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

## Aceptación temporal del backend del 23/09/2026

El mantenedor autorizó habilitar la publicación del backend para continuar la
actualización de QLTY. Se registran 43 excepciones exactas del escaneo
[35887356865](https://github.com/sihsalus/sihsalus/actions/runs/35887356865):
2 CRITICAL y 41 HIGH, todas bibliotecas Java de `linux/amd64`. Responsable:
`@Duvet05`; seguimiento [#323](https://github.com/sihsalus/sihsalus/issues/323);
vencimiento inclusivo: **30/09/2026 UTC**.

La aceptación permite publicar una imagen que conserve esos hallazgos; no
los corrige ni demuestra que sean inexplotables. El catálogo se aplica a la
publicación del repositorio backend, no implementa una restricción por entorno.
La intervención autorizada continúa en QLTY; esta decisión no constituye una
aprobación de despliegue de ese backend en producción.

Se reutiliza el mecanismo de excepciones existente, sin cambiar el evaluador,
Trivy, SBOM, firma, comparación con OpenMRS ni rechazo de fallos operativos.
Una CVE, paquete, versión, severidad, ecosistema o plataforma fuera del alcance
registrado sigue bloqueando. Gateway, Certbot y frontend no reciben excepciones.

Retirar cada entrada al publicar y verificar la corrección en el componente
propietario. Si vence sin corrección, la publicación vuelve a bloquearse;
renovar exige una nueva decisión explícita. Retirar las entradas revoca futuras
promociones, pero no modifica imágenes ya publicadas ni revierte despliegues.

## Revisión y renovación propuesta del 02/10/2026

El mantenedor pidió actualizar los paquetes de la imagen y revisar el catálogo
vencido en [PR #345](https://github.com/sihsalus/sihsalus/pull/345). La revisión
propone renovar únicamente las 43 entradas anteriores, conservando IDs,
responsable, issue y todos sus campos de alcance. La nueva vigencia empieza el
**02/10/2026** y termina el **09/10/2026 UTC**, inclusive; no es una renovación
automática ni una ampliación a paquetes o hallazgos nuevos.

La comparación aislada de DEV usó el backend existente de main, los OMOD
oficiales Attachments 4.1.0 y Authentication 2.4.0, y el bloque de actualización
de paquetes del Dockerfile revisado. Trivy 0.74.0 descargó bases nuevas y terminó
el escaneo el **02/10/2026 a las 23:07 UTC**, incluyendo HIGH/CRITICAL sin
corrección disponible. La imagen local de comparación fue
`sha256:59468213bcf725bd18f67bacbecb1e78f689e19215ba053491e4849a4ac022d8`.
La evidencia depurada confirmó:

- Cero hallazgos HIGH/CRITICAL del sistema operativo; `curl` y `libcurl` quedaron
  en `8.3.0-1.amzn2.0.13`.
- Las 43 entradas anteriores todavía coinciden exactamente: dos CRITICAL y
  41 HIGH Java. No hubo entradas obsoletas que retirar.
- Cinco alcances HIGH Java adicionales quedan fuera del catálogo y siguen
  bloqueando la publicación. Esta revisión no los acepta ni los oculta.

La línea oficial de Core mantiene 2.8.9 como último tag 2.8 disponible en esta
revisión. Las correcciones Java requieren una release validada en el componente
propietario; se conserva [#323](https://github.com/sihsalus/sihsalus/issues/323)
como seguimiento. La renovación temporal no corrige esas dependencias ni
demuestra que sean inexplotables. Su incorporación requiere revisión del PR.

Esta comparación local no tiene índice de release, SBOM adjunto ni firma y no
sirve como evidencia de promoción. El CI del PR debe construir el Dockerfile
completo y pasar el control de vulnerabilidades corregibles y la comparación
con OpenMRS. La publicación sigue exigiendo su propio escaneo del digest
inmutable, SBOM, política completa y firma. No se autorizan merge, despliegue
ni ampliación de aceptación por este cambio.

## Aceptación adicional para DEV y QLTY del 03/10/2026 UTC

Después del merge de PR #345, el mantenedor aceptó expresamente los cinco
hallazgos HIGH adicionales de Jackson/Core, únicamente para continuar los
despliegues de DEV y QLTY. Se agregan cinco entradas exactas al catálogo;
las 43 entradas anteriores permanecen intactas. Responsable: `@Duvet05`;
seguimiento [#323](https://github.com/sihsalus/sihsalus/issues/323). La aceptación
empieza el **03/10/2026 UTC** y vence el **09/10/2026 UTC**, inclusive.

La evidencia del [Build Backend 37078656482](https://github.com/sihsalus/sihsalus/actions/runs/37078656482)
corresponde al Dockerfile completo del commit
`e0645a6e4cc7e1325d49c812d1b7c2f523e71dd3` y al índice inmutable
`sha256:dfa4649ba5cd586fdd6f45240d4430dc0848b3fa19699a19bad3d3016dec6b15`.
Trivy 0.74.0 terminó el escaneo el **03/10/2026 a las 00:06:59 UTC**;
el inventario SPDX contiene 432 paquetes. Encontró 48 alcances Java:
dos CRITICAL y 46 HIGH, sin hallazgos HIGH/CRITICAL del sistema operativo.
El control bloqueó cinco alcances que no tenían excepción; esas son exactamente
las entradas adicionales aceptadas. No se amplía ningún otro alcance.

El catálogo gobierna la publicación del repositorio de imagen y no restringe
técnicamente el entorno. Esta decisión **no autoriza despliegues en producción**.
Mantiene la plataforma `linux/amd64`, los paquetes y versiones exactos, la
comparación con OpenMRS y todos los controles de SBOM, escaneo vigente, firma y
promoción por digest. El candidato rechazado no se despliega como release.

Antes de intervenir DEV o QLTY se requiere una imagen que haya superado los
controles de publicación y el smoke de autenticación local y Keycloak del digest
correspondiente, además del [checklist de despliegue](deploy-checklist.md).
La aceptación es temporal: no corrige Core ni demuestra que los hallazgos sean
inexplotables. Retirar cada entrada cuando una release probada del componente
propietario resuelva su alcance; el día posterior al vencimiento se vuelve a
bloquear la publicación y cualquier renovación exige otra decisión explícita.

## Aceptación adicional para QLTY del 09/10/2026 UTC

El mantenedor aceptó expresamente dos hallazgos adicionales para continuar la
instalación de EmrApi `3.5.1-sihsalus.2` en **QLTY únicamente**. Se agregan dos
entradas exactas; las 48 anteriores conservan todos sus valores y su vencimiento
**09/10/2026 UTC**. Responsable: `@Duvet05`; seguimiento
[#323](https://github.com/sihsalus/sihsalus/issues/323).

La evidencia del [Build Backend 37992692656, intento 2](https://github.com/sihsalus/sihsalus/actions/runs/37992692656/attempts/2)
corresponde al commit `23cd14b02d75e2d5186061894785693b7015077a`.
Trivy 0.74.0 terminó el escaneo el **09/10/2026 a las 21:44:24 UTC**;
el SPDX 2.3 contiene 432 paquetes y sitúa ambos componentes en el WAR de Core.
Los dos alcances son `linux/amd64`, `lang-pkgs` / `jar`:

| Hallazgo | Paquete y versión | Severidad del escáner |
| --- | --- | --- |
| CVE-2026-47884 | `org.springframework:spring-webmvc` 5.3.30 | CRITICAL |
| CVE-2026-68494 | `com.fasterxml.jackson.core:jackson-core` 2.19.1 | HIGH |

Core 2.8.9 es el componente propietario. Para Spring, la corrección compatible
5.3.50 requiere [acceso Enterprise](https://spring.io/security/cve-2026-47884/);
la alternativa OSS 7.0.9 cambia de `javax` a `jakarta` y exige una migración del
stack actual de Core y Tomcat 9, según la
[matriz oficial de Spring](https://github.com/spring-projects/spring-framework/wiki/Spring-Framework-Versions).
Para Jackson, el escáner informa 2.18.8 y 2.21.4 como versiones corregidas;
actualizar a 2.21.4 requiere una release probada de Core y sus dependencias
Jackson coordinadas. No se sustituye un JAR anidado desde infraestructura.

Las dos entradas se crean el **09/10/2026** y vencen el **10/10/2026 UTC**,
inclusive, la fecha mínima válida del contrato existente. Esto **no renueva las
48 entradas anteriores**: el catálogo completo sólo permite publicación mientras
todas estén vigentes, y vuelve a fallar el 10/10 por las 48 vencidas.

El catálogo gobierna la publicación global de la imagen; no impone restricciones
por entorno. QLTY es el alcance operativo autorizado para esta aceptación;
no se amplía a DEV ni producción. La aceptación no corrige las dependencias,
no declara falsos positivos ni demuestra que sean inexplotables.
Retirar cada entrada cuando una release verificada de Core elimine su hallazgo
y pase compatibilidad, runtime y seguridad; cualquier renovación necesita otra
decisión explícita del mantenedor.

El intento 2 también falló al obtener un token de Docker Hub durante el escaneo
de la baseline OpenMRS (HTTP 504). Ese fallo operativo sigue bloqueando: esta
aceptación no lo ignora ni convierte el candidato en una release. Se conservan
la comparación con OpenMRS, SBOM, escaneo vigente del digest exacto, política,
firma y promoción nativas. Antes de instalar en QLTY se requieren además el
[smoke de autenticación](runtime-smoke.md), el
[checklist de despliegue](deploy-checklist.md) y la aceptación funcional del módulo.

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

La suite rápida comprueba la política con fixtures locales, sin registry ni
builds de prueba. Los workflows de publicación siguen exigiendo SBOM, escaneo
por digest, política de excepciones y firma antes de promover la imagen real.

El frontend publica desde `sihsalus-frontend`, con su propio workflow y controles.
Este documento cubre los tres publicadores de imágenes del distro; la promoción
del conjunto sigue requiriendo revisión, aceptación en QLTY y el
[checklist de despliegue](deploy-checklist.md).
