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
module's Maven tests. CI runs ten source suites on Java 21. Initializer's full
reactor also exercises Core 2.1-era dependencies, so it runs on upstream's Java 11
test baseline; CI then repeats its Core 2.8 integration tests on Java 21 with
`test-core28 initializer`, using the installed reactor artifacts. Packaging uses
Java 21 for all modules. CI checks packaged versions and the compiled REST
response protections. `OMOD_TEST_REPORTS`
can select a destination for Surefire XML evidence; `OMOD_MAVEN_REPOSITORY` can
select an isolated dependency cache for local runs.

Packaging compiles sibling test JARs required by upstream reactors, with execution
left to the source test jobs. Patient Documents, O3 Forms and Initializer's Core 2.8 tests
run legacy CGLIB mocks with `java.lang` opened to the test JVM on Java 21; the
application JVM is not changed by this test setting.

O3 Forms' upstream tests additionally use Core 2.3's legacy XStream harness.
Only `test o3forms` opens `java.util`, `java.lang.reflect`, `java.text` and
`java.awt.font` to that test JVM on Java 21. The package mode, dependencies and
deployed JVM options are unchanged; these flags do not relax application access.

The REST patch ports the content-response correction from
[upstream PR #748](https://github.com/openmrs/openmrs-module-webservices.rest/pull/748)
to the released 3.5.0 javax Servlet/JUnit 4 branch. It serves CLOB content as UTF-8
plain text with `X-Content-Type-Options: nosniff`, reads uploads as UTF-8, and tests
both direct CLOB and delegated form-resource responses. The upstream master
branch uses Jakarta and must not replace this Core 2.8-compatible base.
The SIHSalus module descriptor uses its explicit Maven version without upstream's
extra SCM build-number suffix; the immutable source revision is recorded in the lock.

The O3 Forms patch is based on the released 2.3.0 source, not upstream's moving
main branch. A null entry in the ordered locale preferences previously caused
translation loading to throw instead of returning the compiled form. The patch
skips null entries and retains the original preference order, translation
fallbacks and main-form overrides of referenced-form translations. It does not
modify the shared locale list, set a new default language, suppress unrelated
errors, change clinical schemas or bypass permissions. The origin of a runtime
null locale must be investigated separately; this guard does not establish a
configuration error. No database migration is added by this O3 Forms change.

Run `bash backend/bin/build-source-omods.sh test o3forms` to reproduce the
module's complete test suite, including null-locale regressions. Before rollout,
validate compiled form loading and translations with synthetic forms in DEV/QLTY.
The frontend consumer must explicitly accept `2.3.0-sihsalus.1` as well as the
upstream `>=2.3.0` range: a SemVer prerelease does not satisfy that minimum.
Do not weaken the shared version comparator or deploy a mismatched consumer.
Rollback requires the previously verified immutable backend image; it restores
the old null-locale form-loading failure too. Other changes
between deployed distribution versions can have separate migration requirements.

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
