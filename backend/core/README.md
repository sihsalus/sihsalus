# Core clinical integrity and dependency maintenance

The backend uses official OpenMRS Core 2.8.10, source
`openmrs/openmrs-core@a7f6314dd430cbc393313dcfcdc6dd2edecea377`.
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
`2.8.10-sihsalus.4`, matching `backend/pom.xml`. This is a SIHSalus build of
**official 2.8.10 plus these patches**. The suffix distinguishes the patched
artifact from upstream and the previous SIHSalus candidates. Never install these
bytes as the official 2.8.10 artifact or change applied Liquibase identities.

## Bounded exception and removal

Tracking: [#365](https://github.com/sihsalus/sihsalus/issues/365) and
[#366](https://github.com/sihsalus/sihsalus/issues/366). Maintenance owner:
`@Duvet05` / SIHSalus backend.

The official 2.8.10 validators and condition service lack these checks, verified
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
| Spring Security Crypto | 6.5.11 | Standalone password-encoding library; retain Core's legacy encoder and validate native authentication tests. |
| Velocity Engine / Tools | 2.4.1 / 3.1 generic | Adapt logging and exception callbacks; preserve legacy template semantics. |

Core only uses generic Velocity tools. Selecting their dedicated artifact
removes the obsolete Struts integration transitively included by Tools 2.
Core's remaining Commons Lang imports use the already declared Lang 3 dependency;
they no longer depend on Lang 2 arriving implicitly through Velocity. Official
OMODs still use its legacy namespace, so the API now explicitly provides
`commons-lang:commons-lang:2.6`. The suffix `.4` distinguishes these bytes from
the incompatible `.3` candidate. Its CVE-2025-48924 is temporarily accepted
alongside nine exact Spring findings through 2026-10-22 UTC, with user approval
for DEV/QLTY. Removing it requires upstream module compatibility first.
Regression tests render actual startup templates and synthetic mail, checking
localization, legacy truthiness, hyphenated identifiers and exception handling.

The official [Core 2.8.10 release](https://github.com/openmrs/openmrs-core/releases/tag/2.8.10)
still selects Spring 5.3.30 and Jackson 2.19.1. Upgrading the source baseline
does not replace this dependency work.

### Upstream 2.8.10 compatibility

The [complete upstream comparison](https://github.com/openmrs/openmrs-core/compare/2.8.9...2.8.10)
contains 30 commits and 163 changed files. Besides the release notes' password
encoder and MariaDB test harness changes, it includes lazy association loading,
patient search ranking, observation pagination, UUID generation, caches,
authorization metadata, session handling and optional telemetry.

Core now routes passwords through Spring's `PasswordEncoder`, retaining the
upstream legacy encoder by default, and guards credential writes through
`UserService`. The existing clinical and dependency patches apply without
changing those upstream authentication or authorization protections. Native
password tests do not substitute for a fresh local/Keycloak login and forced
password-change check with the complete candidate image.

Upstream adds `spring-security-crypto:5.8.16`, which introduces
[CVE-2025-22228](https://spring.io/security/cve-2025-22228/). The dependency patch
selects the standalone Crypto 6.5.11 library; its published POM does not pull in
Spring Framework or the Spring Security web/authentication stack. This keeps the
current Framework 5.3/Tomcat 9 architecture while removing that additional
finding. Core's password configuration and stored credentials are unchanged.

No upstream Liquibase changelog definitions changed between 2.8.9 and 2.8.10;
the UUID-generating Java change class did change upstream. This is not evidence
of a successful upgrade against an installed MariaDB database. Content and
module migrations still need their own restore-based validation before deployment.

The dependency upgrade alone does not establish release eligibility.
Spring 5.3 remains affected by findings whose fixes require a different runtime
or licensed maintenance. In particular, CVE-2016-1000027 remains associated with
Spring Web versions before 6.0, and the OSS fix for CVE-2026-47884 is Spring 7.0.9.
Moving to Spring 6+ also requires Jakarta-compatible Core, OMODs and Tomcat;
changing a Maven version alone is insufficient. Track that migration separately.
The 2026-10-15 user-approved ten-entry exception catalog applies to this
candidate through 2026-10-22 UTC. It is shared by CI and image promotion;
new findings, OS findings, expired acceptance, failed tests, missing SBOM or
signatures still block. Production is outside the approved deployment scope.

### Native validation, 2026-10-15

The complete patched 2.8.10 reactor passed `mvn --batch-mode --no-transfer-progress
-Dstyle.color=never install` with Java 21 and Maven 3.10.0: **5,659 tests,
zero failures/errors and 54 upstream skips**, across 369 suites. Connection and
request timeouts bounded dependency downloads; no tests or security gates were
disabled. Tests cover the clinical protections, password encoders and credential
writes, authorization, H2 persistence/cache behavior, and Velocity compatibility.

The local WAR SHA-256 is
`98e98ab1aeafee6a5ab9b99ea80c3002b3b34647eab95223b5a267005f41d54d`.
Syft 1.54.1 inventories 202 components. Trivy 0.74.0 with the 2026-10-15 database
reports **9 HIGH/CRITICAL findings (2 CRITICAL, 7 HIGH), all in Spring Framework**.
The initial 2.8.10 build reported 10; Crypto 6.5.11 removes CVE-2025-22228.
This is a WAR-only diagnostic, not a scan or acceptance of the complete image.
The earlier 2.8.9-based WAR counts are superseded by this evidence.

The full local distribution contract suite passed, including 24 security-policy
tests and the empty exception catalog. All three patches reproduce the tested
source in Dockerfile order; no local Liquibase changelog was changed.

The complete container, OMOD integration, fresh local/Keycloak authentication,
MariaDB behavior and DEV/QLTY clinical acceptance require separate checks.
The prior native success does not validate the `.4` change or authorize
deployment before the complete candidate passes its checks. No migration was run on an existing environment.

## Core 3 outlook

As of 2026-10-15, upstream Core 3 is `3.0.0-SNAPSHOT`, not a stable release.
The inspected revision is
[`7cde7e0`](https://github.com/openmrs/openmrs-core/tree/7cde7e0cab6020d93dab0573139a392d6aa26dba).
It is a separate migration from this Core 2.8.10 update:

- Java 21 is required; the current SIHSalus runtime already uses Java 21.
- Jakarta Servlet 6.1/Tomcat 11 replaces the Java EE/Tomcat 9 stack. Modules
  importing `javax.servlet` or `javax.persistence` need compatible builds.
- The upstream BOM selects Spring Framework 7, Spring Security 7, Hibernate ORM
  7, Hibernate Search 8 and Validator 9, together with newer supporting libraries.
- Spring Security method authorization supports rules on arguments/results and
  result filtering. Legacy `@Authorized` remains enforced during transition;
  the upstream migration also adds guards to previously unguarded clinical APIs.
- JobRunr and ShedLock replace/extend background-task execution and coordination;
  persistence and scheduler behavior need migration-specific checks.

See the upstream [dependency BOM](https://github.com/openmrs/openmrs-core/blob/7cde7e0cab6020d93dab0573139a392d6aa26dba/bom/pom.xml)
and [authorization migration guide](https://github.com/openmrs/openmrs-core/blob/7cde7e0cab6020d93dab0573139a392d6aa26dba/doc/AUTHORIZATION_MIGRATION.md).
These are changes in the current development source, not a promise of the final
release contents or date. They do not automatically add CRED/Gestantes screens.

The local preparation identified 34 installed OMODs, 32 with legacy API
references. The Core 3 WAR experiment does not establish module, MariaDB or
clinical readiness; migrate and validate the complete stack before promotion.

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
