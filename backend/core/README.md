# Core clinical integrity correction

The backend uses official OpenMRS Core 2.8.9, source
`openmrs/openmrs-core@4dda0f50a60991a5af9a4b36508e69bb3561c8a6`.
The Dockerfile verifies its archive checksum, applies the two bounded patches
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
`2.8.10-sihsalus.1`, matching `backend/pom.xml`. This is a SIHSalus build of
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

The exception is limited to these Core fixes and native tests; it introduces no
patch loader, runtime repair, schema change or new module. Review the patches
against every Core upgrade. Replace this source build and both patches with an
official artifact containing equivalent fixes after native tests, module
compatibility and synthetic DEV/QLTY acceptance pass. Do not grow this directory
into a general distribution patch system.

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
