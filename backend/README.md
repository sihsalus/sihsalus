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
[assembly descriptor](src/main/assembly/assembly.xml).

Initializer metadata comes from the selected content packages. SPA configuration
belongs to the [frontend build](../frontend/README.md). Runtime setup, including
OCL token reconciliation, lives in the [root README](../README.md); password
policy is documented in the [forced-password-change contract](../docs/operations/forced-password-change.md).

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

Run from the repository root with Maven and the appropriate JDK:

```bash
bash backend/bin/build-source-omods.sh package
bash backend/bin/build-source-omods.sh test MODULE
bash backend/bin/build-source-omods.sh test-core28 initializer
```

Packaging uses Java 21 and compiles sibling test JARs required by upstream
reactors. Tests use Java 21 except Initializer: first install its full reactor
with `test initializer` on Java 11, then run `test-core28 initializer` on Java 21
using the same Maven repository. `OMOD_MAVEN_REPOSITORY` selects an isolated cache;
`OMOD_TEST_REPORTS` selects the Surefire evidence directory.

## Clinical audit candidate for DEV

The standalone [clinical audit module](https://github.com/sihsalus/openmrs-module-sihsalus-audit)
owns event ingestion and privileged review. While its release is pending,
`omod-sources.lock` pins its source commit and archive checksum. The existing
build compiles the module into the distribution; no audit Java source is
vendored here and no external runtime script is required.

The source-module CI matrix runs its tests. The packaged-image gate also checks
the controller, response sanitizer, persistence resources and distinct record
and review privileges. These checks do not establish clinical event coverage.

DEV acceptance must cover MariaDB migration and restart, authenticated ingestion,
separate review access, invalid payloads, idempotent replay and frontend offline
delivery using dedicated test users. The candidate grants neither audit privilege
to existing roles and enables no retention deletion or visit-closing job. Wider
rollout still requires event coverage, role assignments and retention decisions.

The [DEV endpoint acceptance runner](../tests/backend/clinical-audit-smoke.md)
uses three dedicated accounts and records synthetic events without changing
patients. Database trigger checks and browser offline replay remain separate.

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
