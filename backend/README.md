# OpenMRS backend distribution

This directory packages the Core WAR, OMODs and Initializer content into the
backend image. Build from the repository root:

```bash
docker buildx bake backend
```

[Dockerfile](Dockerfile) prepares module artifacts in a build-only Maven cache
before building the `backend` profile. [pom.xml](pom.xml) owns versions;
[distro.properties](distro.properties) selects modules and content packages.
The SDK writes `backend/target/sdk-distro`, packaged by the
[assembly descriptor](assembly.xml).

Initializer metadata comes from the selected content packages. SPA configuration
belongs to the [frontend build](../frontend/README.md). Runtime setup, including
OCL token reconciliation, is described below; password
policy is documented in the [forced-password-change contract](../docs/operations/forced-password-change.md).

## Configuración del token OCL

El backend reconcilia `OMRS_OCL_TOKEN` después de copiar la configuración y antes de que
Initializer la procese. Un valor no vacío se aplica en cada arranque, por lo que un recreate o una
rotación convergen al token configurado sin crear otra propiedad. Si la variable está vacía, el
backend elimina cualquier placeholder del paquete de content, no escribe un valor vacío y conserva
el token que OpenMRS ya tuviera almacenado. En una base limpia, dejarla vacía mantiene deshabilitada
la importación remota hasta configurar un token válido.

Vaciar la variable no revoca una credencial ya persistida. Para rotarla, reemplaza el valor en el
archivo de entorno y recrea el backend; para retirarla sin reemplazo, revoca primero el token en OCL
y elimina la propiedad desde la administración de OpenMRS durante una ventana controlada.

## Tomcat security maintenance

The pinned OpenMRS runtime contains Tomcat 9.0.120. The Dockerfile installs the
complete official Tomcat 9.0.121 `bin` and `lib` directories from Apache's archive,
verified by a literal SHA-256 pin. This fixes CVE-2026-65182, CVE-2026-65905 and
CVE-2026-68525 while retaining OpenMRS's configuration, startup scripts and UID
1001. The checksum was checked against Apache's published SHA-512 file.

CI verifies the running Java version of Tomcat, the writable `setenv.sh` needed
by OpenMRS, configuration ownership and startup of an empty HTTP server without
an external network or database. This patch does not fix dependencies inside
the Core WAR; those remain tracked in
[issue #323](https://github.com/sihsalus/sihsalus/issues/323), and the full image
security policy still controls release promotion.

## Module ownership

The following repositories own their Java changes, patches, regression tests,
OMOD compilation and releases:

| Module | Owning repository | Dockerfile version / POM property |
| --- | --- | --- |
| O3 Forms | [openmrs-module-o3forms](https://github.com/sihsalus/openmrs-module-o3forms) | `O3FORMS_VERSION` / `o3forms.version` |
| REST | [openmrs-module-webservices.rest](https://github.com/sihsalus/openmrs-module-webservices.rest/tree/sihsalus-2.8) | `REST_VERSION` / `webservices.rest.version` |
| EMR API | [openmrs-module-emrapi](https://github.com/sihsalus/openmrs-module-emrapi/tree/sihsalus-2.8) | `EMRAPI_VERSION` / `emrapi.version` |

The image consumes their published OMODs with literal SHA-256 pins. Do not compile
or patch them here, add them to `omod-sources.lock`, or install them manually into
a running instance. Historical distribution patches remain recoverable from Git.

Publish and verify a tested immutable module release first, then update its
Dockerfile version, checksum and POM property together. Version automation must
preserve these pins; temporary CI artifacts, moving URLs and overwritten releases
are not substitutes. Each module's `SIHSALUS-RELEASE.md` records provenance and
release verification. SIH Salus prereleases are not official OpenMRS releases.

Preserve O3 Forms' null-locale translation handling and REST's Core 2.8-compatible
`javax` base with UTF-8/plain-text/`nosniff` responses. EMR API rolls back the entire
automatic visit-closure batch on its first save or validation failure; it does not
repair clinical rows or correct timestamp policy. Keep automatic closure paused
pending actual OpenMRS + Queue integration, an agreed timestamp policy and
synthetic DEV/QLTY acceptance. An image update does not authorize reactivation.

## Source-built modules

[omod-sources.lock](omod-sources.lock) pins the remaining upstream source revisions,
archive checksums and distribution versions. The [build script](bin/build-source-omods.sh)
builds them without external patches; source pins and POM versions must move
together. BedManagement has a separate source/checksum pin in the Dockerfile.

Initializer `2.13.0-sihsalus.2` pins the tested retirement-reason fix in
[the module repository](https://github.com/sihsalus/openmrs-module-initializer/pull/1).
Creating an AMPATH form with `retired: true` previously failed native OpenMRS
validation because its retirement reason was missing. The loader now applies
the same default reason used for an existing form; content stays declarative
and historical schemas remain intact. The fix is proposed
[upstream](https://github.com/mekomsolutions/openmrs-module-initializer/pull/334).
Tracking: [#336](https://github.com/sihsalus/sihsalus/issues/336), owner `@Duvet05`.
Replace the temporary fork pin with an upstream revision containing the fix
after validating fresh creation and version replacement. No SQL repair or
runtime module installation is required.

Run from the repository root with Maven and the appropriate JDK:

```bash
bash backend/bin/build-source-omods.sh package
bash backend/bin/build-source-omods.sh test MODULE
bash backend/bin/build-source-omods.sh test-core28 initializer
```

Packaging uses Java 21 and compiles sibling test JARs required by upstream
reactors. OAuth2Login tests use Java 8, matching its upstream JUnit/PowerMock
stack. Its pinned SIHSalus candidate registers routes through the native module
servlet/filter lifecycle; acceptance also requires fresh Core 2.8 startup and
actual Keycloak login, callback, session and logout.

The source-module matrix is opt-in through the CI workflow `source_omods` input.
Other tests use Java 21 except Initializer: first install its full reactor
with `test initializer` on Java 11, then run `test-core28 initializer` on Java 21
using the same Maven repository. `OMOD_MAVEN_REPOSITORY` selects an isolated cache;
`OMOD_TEST_REPORTS` selects the Surefire evidence directory.

## Clinical audit candidate for DEV

The standalone [clinical audit module](https://github.com/sihsalus/openmrs-module-sihsalus-audit)
owns event ingestion and privileged review. While its release is pending,
`omod-sources.lock` pins its source commit and archive checksum. The existing
build compiles the module into the distribution; no audit Java source is
vendored here and no external runtime script is required.

The optional source-module CI matrix runs its tests. The packaged-image gate also checks
the controller, response sanitizer, persistence resources and distinct record
and review privileges. These checks do not establish clinical event coverage.

DEV acceptance must cover MariaDB migration and restart, authenticated ingestion,
separate review access, invalid payloads, idempotent replay and frontend offline
delivery using dedicated test users. The module declares separate recording and
review privileges. OpenMRS can also attach newly declared privileges to existing
`Privilege Level: High` and `Privilege Level: Full` roles. Review their
effective inheritance before assigning either role; a read-only auditor must not
inherit recording or clinical editing rights. The candidate enables no retention
deletion or visit-closing job. Wider rollout still requires event coverage, role
assignments and retention decisions.

Endpoint acceptance belongs to the module repository and the isolated DEV/QLTY
release check. Verify client milliseconds through persistence, identical and
concurrent replay, and a one-millisecond conflict with full batch rollback.
Database trigger checks and browser offline replay remain separate.

### Reverify an already published candidate

`Build Backend` can finish publishing an image and then fail while exporting
its build cache. A manual `verify-existing` run on a non-main branch verifies
that exact image without rebuilding it:

```bash
gh workflow run build-backend.yml --repo sihsalus/sihsalus --ref REVIEW_BRANCH \
  -f mode=verify-existing \
  -f source_sha=FULL_SOURCE_COMMIT \
  -f image_digest=sha256:FULL_IMAGE_DIGEST
```

Use the source commit and manifest digest from the original publication. The
source must be an ancestor of the workflow revision. The workflow checks out
that source for the package contracts and pinned dependencies, verifies the
image's digest, architecture and revision label, and runs the same image tests,
security scans, vulnerability ratchet and signature as a new build. It records
both the workflow and image source revisions. The security action, scanner tools
and exception policy are restored from the workflow revision after checking out
the historical source, so reverification cannot restore an older publication policy.
This mode does not promote a
release alias, change package visibility or deploy a service.

Normal builds continue to fail on build, publication or verification errors.
Only [cache export failures](https://docs.docker.com/build/cache/backends/gha/)
are non-fatal, so an unavailable cache cannot prevent the image gates from
running after a successful publication.

### MariaDB installations with binary logging

MariaDB requires an operator with `SUPER` to create triggers when `log_bin=ON`
and `log_bin_trust_function_creators=OFF` ([MariaDB documentation](https://mariadb.com/docs/server/ha-and-performance/standard-replication/replication-and-binary-log-system-variables#log_bin_trust_function_creators)).
The application database user should keep its existing database-scoped grants.
On these installations the first module migration creates the audit table and
indexes, then stops at trigger creation. Overall OpenMRS readiness can still be
healthy while the audit module has failed; check the module and endpoint too.

After taking a database backup and confirming the target installation, an
operator can apply the versioned [trigger migration](migrations/clinical-audit-append-only.sql)
to the OpenMRS database. From the distro checkout, for the standard Compose
database name `openmrs`:

```bash
docker compose exec -T db sh -c \
  'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec mariadb --user=root openmrs' \
  < backend/migrations/clinical-audit-append-only.sql
```

Run this within the deployment lock/window, then restart only the backend. The
module resumes its recoverable migration and validates the complete schema and
both trigger bodies. The SQL preserves existing triggers on repeat execution and
does not change grants, replication settings or evidence rows. If an existing
trigger is incompatible, startup validation must fail instead of replacing it.
Verify the module starts, both audit privileges exist, and synthetic UPDATE and
DELETE attempts are rejected. Image rollback leaves the audit schema and evidence
in place. This operator step must be included in first-install acceptance before
any wider rollout.

After a failed lifecycle start, OpenMRS can persist `sihsalusaudit.started=false`.
Replacing the OMOD then leaves it stopped. Once the corrected image and trigger
migration are verified, start the module through OpenMRS administration. An
operator recovering that specific failed-install state can instead apply
[the narrow startup recovery SQL](migrations/clinical-audit-resume-after-failed-start.sql)
with the same database command above, then restart the backend. Preserve an
intentional module stop. This recovery changes only the module's autostart flag;
it grants no audit privileges and enables no scheduled task or retention policy.

## Distribution checks

The audit source pin includes the scoped JDBC timestamp correction from
[audit module PR #3](https://github.com/sihsalus/openmrs-module-sihsalus-audit/pull/3).
The deployed MariaDB 10.11.7 / Connector/J 8.0.30 combination discards fractional
seconds when Hibernate binds a `Timestamp`. The module binds UTC text into the
existing `datetime(3)` column, preserving old evidence and avoiding a global
driver change. The image check requires that mapping and its compiled type.
Before promotion, the new immutable image must pass native endpoint readback,
identical and concurrent replay, a 1 ms conflict, and browser offline acceptance.
Prior acceptance on the old image failed precision readback and remains failed.

Run these static checks from the repository root, without a backend or database:

```bash
bash tests/backend/o3forms-release-config.sh
python3 tests/backend/owned-module-releases.py --self-test
bash tests/backend/tomcat-config-config.sh
```

For an already-built local image, CI checks release bytes, descriptor/API versions,
compiled protections, required module dependencies and Tomcat permissions:

```bash
bash tests/backend/o3forms-release-image.sh IMAGE
bash tests/backend/source-omods-image.sh IMAGE
bash tests/backend/module-dependencies-image.sh IMAGE
bash tests/backend/tomcat-config-image.sh IMAGE
```

The required-module gate uses `ModuleUtil.compareVersion` from the exact Core WAR.
Missing/duplicate identities, malformed descriptors and incompatible required
versions fail; optional dependencies are not required. Core rejects
`2.3.0-sihsalus.1` for Patient Documents' O3 Forms minimum `2.3.0`; the pinned
`2.3.1-sihsalus.1` meets that minimum, but not a future minimum of `2.3.1`.

This gate requires a JDK (CI uses 21), compiles only a test harness and extracts
files from an unstarted, network-isolated container, removing it and its anonymous
volumes afterward. It never accesses deployed data. Offline alternatives:

```bash
bash tests/backend/module-dependencies-image.sh --files PATH_TO_WAR MODULES_DIRECTORY
bash tests/backend/module-dependencies-image.sh --self-test PATH_TO_WAR
```

Tomcat's empty `/usr/local/tomcat/conf/Catalina/localhost` must be owned by `1001:0`,
mode `0750`; `conf` and `Catalina` stay root-owned, mode `0755`. Do not make the
configuration tree writable or disable directory validation. Its image check runs
only a shell as UID 1001, without network or mounted runtime data, and removes its
test container and anonymous volumes.

## Deployment and acceptance

Use the OCI index reference `sha-<commit>@sha256:<index-digest>`; Docker selects
the executable manifest for the host platform. GHCR entries marked
`unknown/unknown` contain provenance/SBOM attestations, and `sha256-<digest>`
tags may identify signature artifacts rather than runnable images. Inspect the
chosen release without deploying it:

```bash
IMAGE='ghcr.io/sihsalus/sihsalus-backend:sha-<commit>@sha256:<index-digest>'
docker buildx imagetools inspect "$IMAGE"
docker buildx imagetools inspect "$IMAGE" --format '{{ json .Provenance.SLSA }}'
docker buildx imagetools inspect "$IMAGE" --format '{{ json .SBOM.SPDX }}'
```

Build arguments appear in provenance. Pass build credentials through BuildKit
secret mounts, never `ARG` or `--build-arg`.

Branch builds publish immutable SHA/digests; successful main builds promote
`latest`. Static/image checks and release publication do not authorize clinical
deployment or prove module startup and clinical behavior.

Use the [backend-only procedure](../scripts/deploy/README.md#backend-únicamente)
with the tested SHA and OCI digest, retaining the previous image for rollback.
Back up the database before startup: an image rollback does not reverse schema
migrations. Verify O3 Forms, REST and Patient Documents start and exercise the
affected API, synthetic form open/save/edit and visit flows in DEV before QLTY
on the same digest. Production restart and scheduler activation require separate
approval.
