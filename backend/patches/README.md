Module ownership and distribution integration

REST and EMR API source changes, regression tests, compilation and release
publication now belong to their independent module repositories:

- [SIHSalus REST](https://github.com/sihsalus/openmrs-module-webservices.rest/tree/sihsalus-2.8)
- [SIHSalus EMR API](https://github.com/sihsalus/openmrs-module-emrapi/tree/sihsalus-2.8)

The distribution consumes their published OMODs by exact version and SHA-256 in
`backend/Dockerfile`, following the O3 Forms pattern. It does not apply their
patches, rewrite their source versions or compile them. The historical patch files
remain recoverable from Git; their code and tests are now ordinary module commits.

`tests/backend/owned-module-releases.py --self-test` verifies the release contract
and negative cases. The backend image gate checks that packaged OMOD bytes match
the published release pins, along with descriptor versions and compiled REST/EMR
API protections. The required-module gate uses the exact packaged Core comparator.
An incompatible dependency or altered release must fail before promotion.

The initial 3.5.1-sihsalus.1 releases are SIHSalus prereleases, not official OpenMRS
3.5.1 releases. See each module's `SIHSALUS-RELEASE.md` for upstream provenance,
test scope and release verification. REST retains the Core 2.8-compatible javax
base and upstream PR #748's UTF-8/plain-text/nosniff correction.

EMR API remains rollback containment, not a corrected clinical timestamp policy.
The first save/validation failure rolls back the whole closure batch. It does not
repair historical rows, change guessed end dates or scheduler settings, or
authorize reactivation. Keep auto closure paused pending actual OpenMRS + Queue
integration, an agreed timestamp policy and synthetic DEV/QLTY acceptance.

Remaining source OMODs

`backend/omod-sources.lock` retains immutable upstream source revisions and archive
checksums for eight other modules. `bash backend/bin/build-source-omods.sh package`
builds them in the distribution's Maven cache without applying external patches.
Core remains 2.8.9. The separate BedManagement source pin is unchanged.

Run `bash backend/bin/build-source-omods.sh test <module>` to execute a remaining
module's Maven suite. Seven use Java 21; Initializer's full reactor uses upstream's
Java 11 test baseline, followed by its Core 2.8 integration suite on Java 21 via
`test-core28 initializer`. Packaging uses Java 21. `OMOD_TEST_REPORTS` selects a
Surefire evidence directory and `OMOD_MAVEN_REPOSITORY` an isolated local cache.
Sibling test JARs are compiled during packaging as required by upstream reactors.

Deployment and promotion

Version automation must not replace an owned release independently of its
checksum and POM version. Source revisions and POM versions also move together.
Branch builds publish only immutable image SHA/digests; only successful main
builds promote the `latest` alias.

Publishing module releases or merging this dependency change does not authorize
clinical deployment. Validate the same image digest in DEV and then QLTY using
synthetic fixtures; verify module startup and the affected API/form/visit flows.
Back up the database before startup: an image rollback does not reverse schema
migrations. Production restart and scheduler activation require separate approval.
