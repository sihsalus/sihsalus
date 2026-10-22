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

Core is built from the official 2.8.10 source with the bounded
[clinical integrity correction](core/README.md) for program enrollment and
duplicate active conditions and the dependency maintenance described in the
same guide. The distribution version is `2.8.10-sihsalus.4`, identifying the
official 2.8.10 baseline plus SIHSalus patches. Native Core tests run during the
image build before the WAR enters the SDK distribution.

Initializer metadata comes from the selected content packages. SPA configuration
belongs to the [frontend build](../frontend/README.md). Runtime setup, including
OCL token reconciliation, is described below; password
policy is documented in the [forced-password-change contract](../docs/operations/forced-password-change.md).

## Content 1.25.41

The distribution consumes published `sihsalus-content` 1.25.41, from
[content PR #277](https://github.com/sihsalus/sihsalus-content/pull/277).
It updates the native ethnicity exports with 58 MINSA equivalences and five
synonyms while preserving the 62 clinical concept UUIDs and answer order.
The other 32 exports and remote subscription pins stay unchanged. See the
[ethnicity contract](https://github.com/sihsalus/sihsalus-content/blob/0b9dd4fd6aeb07f8329cc79c925d71186ff137fc/docs/contracts/etnias-minsa.md)
for identities, provenance and pending clinical decisions.

For DEV/QLTY, take and verify a database backup before restarting with this
version. After Initializer completes, verify native code resolution
(`source=MINSA-ETNIAS`, `code=2` resolves Aimara), existing answer order and
module readiness. Reverting the backend image does not remove the newly
persisted mappings; reimporting the older export can lose answer weights.
Recovery requires evaluating the persisted state and a compatible backup.
Publication and technical health do not establish clinical acceptance.

## Runtime OS security maintenance

The runtime base stays immutable. Its build-time `yum update` includes both
`curl` and `libcurl`, so new Amazon Linux security patches are applied before
returning to UID 1001. The same list carries the rpm package family
(`python2-rpm`, `rpm`, `rpm-build-libs`, `rpm-libs`) for ALAS2-2026-3984 /
CVE-2026-78367. CI supplies the source SHA as `SECURITY_REFRESH` to invalidate
the package-update layer on each revision.

Amazon backports fixes without changing curl's `8.3.0` version string; inspect
`rpm -q curl libcurl` and the image scan rather than that string alone. Accepted
Java findings are listed in [the image security policy](../docs/operations/image-security.md).

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
CVE-2026-68525 while retaining OpenMRS's configuration, startup scripts and UID 1001. The checksum was checked against Apache's published SHA-512 file.

CI verifies the running Java version of Tomcat, the writable `setenv.sh` needed
by OpenMRS, configuration ownership and startup of an empty HTTP server without
an external network or database. This patch does not fix dependencies inside
the Core WAR; those remain tracked in
[issue #323](https://github.com/sihsalus/sihsalus/issues/323), and the full image
security policy still controls release promotion.

## Module ownership

The following repositories own their Java changes, patches, regression tests,
OMOD compilation and releases:

| Module   | Owning repository                                                                                                | Dockerfile version / POM property           |
| -------- | ---------------------------------------------------------------------------------------------------------------- | ------------------------------------------- |
| O3 Forms | [openmrs-module-o3forms](https://github.com/sihsalus/openmrs-module-o3forms)                                     | `O3FORMS_VERSION` / `o3forms.version`       |
| REST     | [openmrs-module-webservices.rest](https://github.com/sihsalus/openmrs-module-webservices.rest/tree/sihsalus-2.8) | `REST_VERSION` / `webservices.rest.version` |
| EMR API  | [openmrs-module-emrapi](https://github.com/sihsalus/openmrs-module-emrapi/tree/sihsalus-2.8)                     | `EMRAPI_VERSION` / `emrapi.version`         |

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

## Official upstream modules

[Attachments 4.1.0](https://github.com/openmrs/openmrs-module-attachments/releases/tag/4.1.0)
fixes saving visit notes with multiple image attachments.
[Authentication 2.4.0](https://github.com/openmrs/openmrs-module-authentication/releases/tag/2.4.0)
adds the session-rotation and incomplete-2FA fixes missing from the earlier
source pin. Both are official Maven artifacts. Preserve the
forced-password-change and OAuth2 configuration contracts.

- Reference Application demo/showcase packages do not replace SIH Salus clinical
  content. Report Builder and Metadata Export are separate optional products,
  not upgrades to installed modules; introducing them requires an actual
  consumer and acceptance scope.
- REST stays checksum-pinned to its published SIH Salus release. The 3.6.0
  candidate prepared in the owning fork keeps the CLOB UTF-8/plain-text/`nosniff`
  runtime protection and must be reviewed and released there before this pin
  changes.

### Official releases, 2026-10-15

Queue, OpenConceptLab, Patient Documents, Address Hierarchy and Reporting use
official Maven OMODs; none needs a distribution-specific version, source build
or source-test matrix entry.

| Module | Previous pin | Candidate |
| --- | --- | --- |
| [Queue](https://github.com/openmrs/openmrs-module-queue/releases/tag/3.1.0) | 3.1.0-sihsalus.1 | 3.1.0 |
| [OpenConceptLab](https://github.com/openmrs/openmrs-module-openconceptlab/releases/tag/4.0.0) | 3.2.0 | 4.0.0 |
| [Patient Documents](https://github.com/openmrs/openmrs-module-patientdocuments/releases/tag/1.2.0) | 1.2.0-sihsalus.1 | 1.2.0 |
| [Address Hierarchy](https://github.com/openmrs/openmrs-module-addresshierarchy/releases/tag/3.0.0) | 2.21.0 | 3.0.0 |
| [Reporting](https://github.com/openmrs/openmrs-module-reporting/releases/tag/2.2.0) | 2.2.0-sihsalus.1 | 2.2.0 |

Queue is adopted as published: queue entries are annulled when a patient is
voided, and both scheduled tasks are registered and started on module startup.
The visit task closes queue entries for visits that have already ended; it does
not end visits. The time-based task has no effect while
`queue.autoCloseQueueEntriesAtTime` is empty (the default). No closure time or
EMR API visit-closure setting is configured here. Before activation, inspect
the environment's persisted properties and task definitions, and cover ended
visits, patient voiding and any configured closure schedule in clinical
acceptance. Queue can persist scheduler records and change queue rows;
reverting the image does not reverse those writes.

OCL 4.0.0 performs asynchronous index work during imports and requires Core
2.8.0 or later; validate import completion, search results and Initializer
startup ordering. Patient Documents adds paper-size-aware PDF layout; verify
the CRED/Gestantes documents. Patient Documents 1.2.0 is validated only with
Reporting 2.2.0; its default Reporting 1.28 dependency does not initialize on
this baseline. Address Hierarchy import/update acceptance is pending; optional
ExtI18n stays outside this change.

Core `2.8.10-sihsalus.4` restores upstream Commons Lang 2.6 for the official
modules that still import `org.apache.commons.lang`. Its CVE-2025-48924 and
nine exact Spring 5.3.39 findings are accepted for DEV/QLTY through 2026-10-22
UTC in the shared [image exception catalog](../docs/operations/image-security.md);
other findings block.

### Gradual adoption of official OMODs, phase 1

[Billing 2.5.0](https://github.com/openmrs/openmrs-module-billing/releases/tag/2.5.0)
and [Reporting REST 2.0.0](https://github.com/openmrs/openmrs-module-reportingrest/releases/tag/2.0.0)
are official Maven artifacts; FHIR2 followed on 2026-10-19 (below). Billing
2.5.0 changes `getBillableServiceId` from `int` to `Integer` and removes
`setBillableServiceId` / `addServicePrice`; Java consumers of that API change
must be checked. Reporting REST 2.0.0 is an intentional downgrade from
`2.1.0-sihsalus.1`: it drops the unreleased immediate
`POST reportingrest/runReport/...` endpoints and keeps the queued report APIs;
external clients of `runReport` remain to be checked. Do not delete
module-version records or migration history to force the downgrade.

### Official releases, 2026-10-19

FHIR2 moved from the `4.3.0-sihsalus.1` source build to the official
[4.3.0](https://github.com/openmrs/openmrs-module-fhir2/releases/tag/4.3.0)
Maven release. The release contains the previously pinned revision
`069deb714818428540719182472ea13711628526` plus FM2-698 (externally
configured interceptors, [#628](https://github.com/openmrs/openmrs-module-fhir2/pull/628))
and release housekeeping; the distribution carried no FHIR2 patch. The
`integration-test` profile failures recorded on 2026-10-15 for the 4.3.0 source
were not re-diagnosed: medication-update persistence errors involving
`Drug.ingredients` / duplicate `DrugIngredient` identities, and `lastn` cases
that depend on Core's changed encounter-6 fixture. Because the release is the
already-shipped snapshot plus FM2-698, they are treated as pre-existing. Its
`omod-sources.lock` entry, source-test matrix job and version-review ignore
rule were removed. Queue moved from 3.1.0 to
[3.1.1](https://github.com/openmrs/openmrs-module-queue/releases/tag/3.1.1),
a signing-only release, and its version-review ignore rule was removed. The
daily dependency-update workflow can now propose later official releases of
both modules through pull requests.

The Core compatibility/security blockers described above still apply. Before
promotion, require the full image checks, actual startup on restored synthetic
data, authenticated FHIR reads/writes and denied access, billing create/pay/refund
and invoice checks, and queued report generation/download.

### Remaining exceptions and removal conditions

Keep each exception until its replacement passes the affected functional and
authorization tests. Technical maintenance owner: `@Duvet05`; clinical acceptance
requires a designated CRED/Gestantes reviewer. Track the phased transition in its
PR and existing owning-module PRs rather than introducing another version registry.

| Module | What would be lost by removing the current variant | Condition for an official replacement |
| --- | --- | --- |
| REST | CLOB UTF-8, plain-text and `nosniff` protection | A compatible Core 2.8 release containing the fix; its presence on upstream master alone is insufficient. |
| O3 Forms | Null-locale translation guard | Demonstrate safe form translation with the official release and actual locale configuration. |
| EMR API | Atomic failure of automatic visit closure and maternal lookup without admission metadata | Prove batch rollback and mother/child queries; keep automatic closure paused pending clinical acceptance. |
| Initializer | Retirement reason when creating an already-retired AMPATH form | Official release containing upstream PR #334; test fresh creation and replacement without modifying historical data. |
| OAuth2Login | Native route registration and authentication-scheme selection | Verify official login, callback, session and logout, or separately approve local OpenMRS authentication. |
| Bed Management | Clinical visit closure, scoped metadata access, extra bed states and tag mappings | Prove equivalent closure and authorization behavior (see below) and assess existing `CLEANING`, `MAINTENANCE` and `ISOLATION` states and tag mappings before replacing the module. |
| Stock Management | Operation-location input/fallback and the variant's DAO wiring | Compare official 3.0.0 with our 3.1.1 variant, then test receipts, transfers and billing; 3.1.1 is a private number, not an official release. |

FUA, Imaging, Notifications and Audit are local products, not redundant upstream
rebuilds. Their replacement needs an explicit functional decision; this phase
does not remove them.

Bed Management serves `POST /ws/rest/v1/clinicalvisitclosure`, called by visit
finalization, appointment closure and the deceased-patient workflow. The
endpoint calls `VisitService.endVisit`, returns an already-closed visit without
changing its stop date and temporarily supplies two metadata privileges; the
variant also changes service wiring in visit/encounter hooks. The native REST
visit update accepts `stopDatetime` but calls `saveVisit`, so a URL replacement
alone is not an equivalent in authorization or behavior. Any replacement keeps
these guards:

- Do not grant bed administration or broad metadata access to compensate for
  missing module behavior.
- Do not move backend authorization into the frontend.
- Do not delete or remap clinical/bed data as part of an artifact replacement.

Replacing the endpoint is accepted only after: allowed and denied requests with
actual CRED/Gestantes role metadata, including bed hooks; SIS summary
validation, closing before FUA generation and safe retry with an unchanged stop
date; queue draining, fresh visit readback, timestamp bounds and recovery after
a lost response in the deceased-patient workflow; appointments; and a human
clinical/permission review.

## Source-built modules

[omod-sources.lock](omod-sources.lock) pins the three remaining source-built
modules (Initializer, OAuth2Login and the clinical audit module) with their upstream
revisions, archive checksums and distribution versions. The
[build script](bin/build-source-omods.sh) builds them without external patches;
source pins and POM versions must move together. BedManagement has a separate
source/checksum pin in the Dockerfile.

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

The source-module matrix (`initializer`, `oauth2login`, `sihsalusaudit`) is
opt-in through the CI workflow `source_omods` input.
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
and review privileges.

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
[audit module PR #3](https://github.com/sihsalus/openmrs-module-sihsalus-audit/pull/3):
MariaDB 10.11.7 / Connector/J 8.0.30 discards fractional seconds when Hibernate
binds a `Timestamp`, so the module binds UTC text into the existing
`datetime(3)` column. The image check requires that mapping and its compiled type.

[tests/run.sh](../tests/run.sh) is the canonical list of static checks; run it
from the repository root without a backend or database. A single check runs the
same way, for example:

```bash
bash tests/backend/build-backend-config.sh
python3 -B tests/backend/owned-module-releases.py --self-test
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

Use the [backend and content procedure](../scripts/deploy/README.md#backend-y-content)
with the tested SHA and OCI digest, retaining the previous image for rollback.
Back up the database before startup: an image rollback does not reverse schema
migrations. Verify O3 Forms, REST and Patient Documents start and exercise the
affected API, synthetic form open/save/edit and visit flows in DEV before QLTY
on the same digest. Production restart and scheduler activation require separate
approval.
