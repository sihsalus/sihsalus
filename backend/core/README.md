# Core clinical integrity and dependency maintenance

The backend uses official OpenMRS Core 2.8.9, source
`openmrs/openmrs-core@4dda0f50a60991a5af9a4b36508e69bb3561c8a6`.
The Dockerfile verifies its archive checksum, applies the bounded patches
here, runs the native Maven reactor including its regression tests, and installs
the resulting WAR in the same build-only cache as the SDK distribution.

`clinical-integrity.patch` changes the owning Core components:

- `PatientProgramValidator` rejects enrollment before the patient's birth date,
  comparing calendar days and allowing enrollment on the day of birth.
- `ConditionService` rejects another non-voided active coded condition for the
  same patient, concept and supplemental detail. Active includes recurrence and
  relapse. Different supplemental context remains distinct because historical
  clients use it for personal/family antecedents. Free-text conditions are unchanged.
- The patient's database row serializes condition save/void/unvoid operations;
  a locking read retrieves active conditions. Updates preserve Core's existing
  void-and-replace history. Resolution or voiding permits a subsequent episode.
- Duplicate rejection uses native `ValidationException` with field `condition`
  and code `Condition.activeDuplicate`, exposed by the existing REST validation
  response. Historical duplicates are not deleted or rewritten.

`distribution-version.patch` changes only the reactor POM versions to
`2.8.10-sihsalus.2`, matching `backend/pom.xml`. This is a SIHSalus build of
**2.8.9 plus these patches**, not an official 2.8.10 release. The next patch
number avoids comparing below modules' 2.8.9 minimum. Never install these bytes
as the official 2.8.9 artifact or change applied Liquibase identities.

## Bounded exception and removal

Tracking: [#365](https://github.com/sihsalus/sihsalus/issues/365) and
[#366](https://github.com/sihsalus/sihsalus/issues/366). Maintenance owner:
`@Duvet05` / SIHSalus backend.

The official 2.8.9 validators and condition service lack these checks, verified
against their native source and regression tests. Frontend-only validation
cannot protect other API callers or concurrent requests. Implementing condition
versioning/locking in REST, EMR API or content would duplicate Core persistence
logic. The archived SIHSalus Core fork is not a build dependency.

The exception is limited to these Core fixes, the dependency maintenance below,
and native tests; it introduces no
patch loader, runtime repair, schema change or new module. Review the patches
against every Core upgrade. Replace this source build and its patches with an
official artifact containing equivalent fixes after native tests, module
compatibility and synthetic DEV/QLTY acceptance pass. Do not grow this directory
into a general distribution patch system.

## Dependency security maintenance

Tracking: [#323](https://github.com/sihsalus/sihsalus/issues/323). The
`dependency-security.patch` changes dependency selection in the owning Core
reactor before compilation. No packaged JAR is substituted, stripped or renamed.
The native reactor tests remain mandatory during the image build.

| Component | Candidate version | Compatibility approach |
| --- | --- | --- |
| Netty | 4.1.139.Final | Import the 4.1 BOM to align all protocol modules. |
| Jackson | 2.21.7 | Import its BOM, including the distinct annotations version. |
| Protobuf | 3.25.9 | Stay on the 3.x maintenance line. |
| c3p0 / mchange-commons-java | 0.14.2 / 0.6.1 | Compile and test against Hibernate's existing pool adapter. |
| ProtoStream / ProtoStream types | 4.6.5.Final | Align both artifacts and exercise native Infinispan cache tests. |
| PostgreSQL JDBC | 42.7.14 | Stay on the 42.7 maintenance line. |
| MySQL Connector/J | 8.4.0 | Use the maintained `com.mysql:mysql-connector-j` coordinates. |
| Spring Framework | 5.3.39 | Keep the current `javax` runtime; this does not resolve every Spring finding. |
| Velocity Engine / Tools | 2.4.1 / 3.1 generic | Adapt logging and exception callbacks; preserve legacy template semantics. |

Core only uses generic Velocity tools. Selecting their dedicated artifact
removes the obsolete Struts integration transitively included by Tools 2.
Core's remaining Commons Lang imports use the already declared Lang 3 dependency;
they no longer depend on Lang 2 arriving implicitly through Velocity.
Regression tests render actual startup templates and synthetic mail, checking
localization, legacy truthiness, hyphenated identifiers and exception handling.

The official [Core 2.8.10 release](https://github.com/openmrs/openmrs-core/releases/tag/2.8.10)
exists, but its POM still selects Spring 5.3.30 and Jackson 2.19.1. It is not a
replacement for this dependency work. Its unrelated functional changes are not
included in this candidate.

This change does not authorize an exception or establish release eligibility.
Spring 5.3 remains affected by findings whose fixes require a different runtime
or licensed maintenance. In particular, CVE-2016-1000027 remains associated with
Spring Web versions before 6.0, and the OSS fix for CVE-2026-47884 is Spring 7.0.9.
Moving to Spring 6+ also requires Jakarta-compatible Core, OMODs and Tomcat;
changing a Maven version alone is insufficient. Track that migration separately.
The empty exception policy, HIGH/CRITICAL gate, SBOM and signing requirements
remain unchanged. Do not deploy a rejected candidate.

### Native validation, 2026-10-15

The complete patched reactor passed `mvn --batch-mode --no-transfer-progress
-Dstyle.color=never install` with Java 21 and Maven 3.10.0: 5,241 tests,
zero failures/errors and 54 upstream skips. This includes the existing clinical
integrity tests, H2 persistence/cache tests, actual startup template rendering
and synthetic mail compatibility tests. The local WAR SHA-256 is
`141a0a663d00129cb2c73a0d55510cbde25895019873752602fb1b5e7f38e09e`.

A local diagnostic used Syft 1.54.1 to inventory both WARs and Trivy 0.74.0
with the same 2026-10-15 vulnerability database. It reports 47 HIGH/CRITICAL
findings for the previous patched WAR and 9 for this candidate (2 CRITICAL,
7 HIGH), all in Spring; 38 CVE/package pairs disappear and none are added.
The candidate inventory contains 200 components. This is a WAR-only diagnostic,
not the required scan of the complete container. Syft identifies the old MySQL
connector under different Maven coordinates from the image scanner, so these
counts must not be presented as a direct reduction of the earlier 48 image
findings. The release scan must independently verify every affected package.

The complete container, OMOD integration, fresh local/Keycloak authentication,
MariaDB behavior and DEV/QLTY clinical acceptance require separate checks.
Native success does not remove the Spring publication block or establish that
this candidate can be deployed. No migration was run on an existing environment.

## Verification and acceptance

The image build runs `mvn --batch-mode --no-transfer-progress install` on the
extracted, patched source. To reproduce without Docker, download the exact
archive/checksum from `backend/Dockerfile`, extract it into a disposable directory,
apply the patches in Dockerfile order using `git apply`, and run that same Maven
command with Java 21. Tests use synthetic H2 fixtures.

The packaged-WAR gate verifies the native validation and locking methods are
present before checking required module versions. Existing image security gates
still apply. Native tests and bytecode checks do not establish MariaDB concurrency
or clinical acceptance. Before promotion, use the same candidate image for
synthetic REST create/edit/resolve/void/unvoid, simultaneous duplicate creation,
same-day enrollment and before-birth rejection. Coordinate the companion
frontend changes for translated feedback; no production data is needed.

Rollback selects the prior immutable backend image. No migration or historical
repair is introduced; rollback removes enforcement for subsequent writes and
does not revert clinical records created during candidate validation.
