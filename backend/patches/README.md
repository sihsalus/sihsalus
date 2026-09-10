Source OMOD integration

`backend/omod-sources.lock` records the repository, immutable source revision,
archive checksum and SIHSalus version of every module built from source. Released
FUA 1.0.89, Appointments 2.2.0 and LegacyUI 2.2.0 are resolved normally by Maven.
Core remains 2.8.9. The existing BedManagement source pin is retained.

`backend/bin/build-source-omods.sh package` installs the source modules in the
same Maven repository used to package the distro. Source modules are assigned
explicit SIHSalus versions; floating upstream SNAPSHOT OMODs are not installed.
The version rules prevent the release updater from silently replacing these
artifacts. Update the source lock and POM together when adopting a newer release.

Run `bash backend/bin/build-source-omods.sh test <module>` to run that source
module's Maven tests. CI runs nine source suites on Java 21. Initializer's full
reactor also exercises Core 2.1-era dependencies, so it runs on upstream's Java 11
test baseline; CI then repeats its Core 2.8 integration tests on Java 21 with
`test-core28 initializer`, using the installed reactor artifacts. Packaging uses
Java 21 for all modules. CI checks packaged versions and the compiled REST
response protections. `OMOD_TEST_REPORTS`
can select a destination for Surefire XML evidence; `OMOD_MAVEN_REPOSITORY` can
select an isolated dependency cache for local runs.

Packaging compiles sibling test JARs required by upstream reactors, with execution
left to the source test jobs. Patient Documents and Initializer's Core 2.8 tests
run legacy CGLIB mocks with `java.lang` opened to the test JVM on Java 21; the
application JVM is not changed by this test setting.

The REST patch ports the content-response correction from
[upstream PR #748](https://github.com/openmrs/openmrs-module-webservices.rest/pull/748)
to the released 3.5.0 javax Servlet/JUnit 4 branch. It serves CLOB content as UTF-8
plain text with `X-Content-Type-Options: nosniff`, reads uploads as UTF-8, and tests
both direct CLOB and delegated form-resource responses. The upstream master
branch uses Jakarta and must not replace this Core 2.8-compatible base.
The SIHSalus module descriptor uses its explicit Maven version without upstream's
extra SCM build-number suffix; the immutable source revision is recorded in the lock.

The EMR API patch `3.5.0-sihsalus.2` makes `closeInactiveVisits` transactional
and propagates save/validation failures instead of catching and continuing.
Save handlers can flush modified visits and related queue rows before rejecting
an incompatible end date. The outer transaction must therefore roll back the
whole closure batch, including previously processed visits, on the first failure.
Do not catch that exception inside a caller's transaction and continue committing.

The regression uses the real Spring annotation interceptor and a disposable H2
database with a save-service double that writes visit and queue rows before
throwing `ValidationException`. It covers queue end before start, end equal to
start, rollback of earlier writes, stopping before later visits, a valid batch,
and an empty batch. It does not replace an actual OpenMRS + Queue integration test.

This is a fail-closed containment patch, not a new clinical timestamp policy.
It deliberately preserves the existing guessed end date and queue validation.
Incompatible visits will still prevent automatic batch completion, but must not
leave partially committed timestamps. It does not repair historical rows, change
scheduler settings or authorize reactivation. Keep affected installations' auto
closure paused until the timestamp policy and transaction behavior pass synthetic
DEV/QLTY acceptance and clinical/operational review.

Validation in DEV and then QLTY must use the same immutable image digest. Confirm
all 33 modules are started, compare their versions to `backend/pom.xml`, and test
the updated APIs with synthetic fixtures: FUA payloads, recurring appointments
and availability, queue transitions and metrics, document/PDF generation, billing
filters, reporting permissions, FHIR tasks and authentication. Back up the database
before startup: Appointments adds availability tables and Queue adds indexes.
An image rollback does not itself reverse database migrations.

Branch builds publish only their immutable SHA/digest. The `latest` alias is
promoted only by a successful main build. The dependency updater proposes a PR
and explicitly dispatches CI because a push made with GITHUB_TOKEN does not
automatically trigger another workflow.
