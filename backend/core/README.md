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
the incompatible `.3` candidate. Removing Lang 2.6 requires upstream module
compatibility first.
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
changing those upstream authentication or authorization protections. Check
fresh local/Keycloak login and forced password change with the complete
candidate image.

Upstream adds `spring-security-crypto:5.8.16`, which introduces
[CVE-2025-22228](https://spring.io/security/cve-2025-22228/). The dependency patch
selects the standalone Crypto 6.5.11 library; its published POM does not pull in
Spring Framework or the Spring Security web/authentication stack. This keeps the
current Framework 5.3/Tomcat 9 architecture while removing that additional
finding. Core's password configuration and stored credentials are unchanged.

No upstream Liquibase changelog definitions changed between 2.8.9 and 2.8.10;
the UUID-generating Java change class did change upstream. Content and module
migrations still need restore-based validation before deployment.

Spring 5.3 remains affected by findings whose fixes require a different runtime
or licensed maintenance: CVE-2016-1000027 applies to Spring Web before 6.0, and
the OSS fix for CVE-2026-47884 is Spring 7.0.9, which also needs
Jakarta-compatible Core, OMODs and Tomcat. Track that migration separately.
The accepted Spring and Commons Lang findings, their owner, validity window and
limits are recorded in [the image security policy](../../docs/operations/image-security.md)
and `scripts/security/image-exceptions.json`; CI and image promotion share
that catalog.

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
