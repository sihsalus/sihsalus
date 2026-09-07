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
module's Maven tests. CI runs all ten source suites on Java 21 and checks the
packaged versions and the compiled REST response protections. `OMOD_TEST_REPORTS`
can select a destination for Surefire XML evidence; `OMOD_MAVEN_REPOSITORY` can
select an isolated dependency cache for local runs.

Packaging compiles sibling test JARs required by upstream reactors, with execution
left to the source test jobs. Initializer and Patient Documents run their legacy
CGLIB/PowerMock tests with `java.lang` opened to the test JVM on Java 21; the
application JVM is not changed by this test setting.

The REST patch ports the content-response correction from
[upstream PR #748](https://github.com/openmrs/openmrs-module-webservices.rest/pull/748)
to the released 3.5.0 javax Servlet/JUnit 4 branch. It serves CLOB content as UTF-8
plain text with `X-Content-Type-Options: nosniff`, reads uploads as UTF-8, and tests
both direct CLOB and delegated form-resource responses. The upstream master
branch uses Jakarta and must not replace this Core 2.8-compatible base.

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
