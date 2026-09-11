_Packages a distribution of configs, metadata and binaries to run OpenMRS_

-----

```bash
mvn clean package
```

Output:

`target/openmrs-distro-package/openmrs-distro-package-$version.zip`

Package contents:

|File or Directory|Description|
|-----------------|-----------|
|`openmrs_config` |The OpenMRS configuration, particularly including any files to be processed by the [Initializer module](https://github.com/mekomsolutions/openmrs-module-initializer). An example configuration can be found [here](https://github.com/mekomsolutions/openmrs-config-haiti).
|`openmrs_core`   |The main OpenMRS WAR file.|
|`openmrs_modules`|The modules (OMODs) to be run in this OpenMRS instance.|
|`spa`            |The compiled SPA for the 3.x frontend.|
|`spa_config`     |Any configuration files used by the SPA.|
|`openmrs-distro.properties`|The distro.properties used to generate this package.|

----

### Specifying dependencies
#### OpenMRS modules
`omod`s are specified as Maven `<dependency>` in the [pom.xml](pom.xml) file.

O3 Forms is an explicitly versioned binary dependency published by
[`sihsalus/openmrs-module-o3forms`](https://github.com/sihsalus/openmrs-module-o3forms/releases).
Its Java source, patch, tests and OMOD compilation belong in that repository.
The backend image build downloads the released OMOD using a literal SHA-256 pin
in `Dockerfile` and registers those exact bytes in its build-only Maven cache
before packaging the distribution. No O3 Forms source patch, compilation or
manual runtime-module installation takes place here.

To update it, approve and publish the module release first, then change
`o3forms.version`, `O3FORMS_VERSION` and the Dockerfile checksum together. Do not
use a short-lived CI artifact or a moving download URL. The configuration test
checks this dependency contract; the image test checks the packaged OMOD's
checksum, module identity and nested API version. Version automation must not
replace this pin independently.

#### Independently released REST and EMR API

REST and EMR API follow the same owned-release pattern in
[`sihsalus/openmrs-module-webservices.rest`](https://github.com/sihsalus/openmrs-module-webservices.rest)
and [`sihsalus/openmrs-module-emrapi`](https://github.com/sihsalus/openmrs-module-emrapi).
Their Java changes, regressions and CI release builds live only in those repos.
The backend consumes the published OMODs, with literal SHA-256 pins and explicit
versions. Do not reintroduce them into `omod-sources.lock` or apply build-time patches.

Update `REST_VERSION`/`EMRAPI_VERSION`, the corresponding Dockerfile checksum and
POM property together, only after a tested immutable module release is published.
`python3 tests/backend/owned-module-releases.py --self-test` checks the contract;
the image gate checks the packaged bytes against those same checksums.

EMR API 3.5.1-sihsalus.1 is a containment prerelease: a failed automatic visit
closure rolls back the entire batch. It does not correct timestamp policy,
repair clinical rows, or authorize scheduler reactivation. Actual OpenMRS + Queue
integration and synthetic DEV/QLTY acceptance remain necessary before deployment.
See [module ownership and safety requirements](patches/README.md).

#### Required module compatibility gate

Before promotion, CI checks every packaged OMOD's required module dependencies
by package identity and minimum version using `ModuleUtil.compareVersion` from
the exact Core WAR in the image. This is a test-only harness; it does not compile
module/application source, start OpenMRS, attach runtime data or contact a database.
Optional dependencies are not treated as required. Missing/duplicate module
identities, malformed descriptors and incompatible required versions fail closed.

```bash
bash tests/backend/module-dependencies-image.sh IMAGE
# Offline alternatives using distribution artifacts only:
bash tests/backend/module-dependencies-image.sh --files PATH_TO_WAR MODULES_DIRECTORY
bash tests/backend/module-dependencies-image.sh --self-test PATH_TO_WAR
```

The gate requires a JDK (CI uses 21); image mode additionally requires Docker.
It creates an unstarted, network-isolated container and removes that test container
and its anonymous volumes afterward. It never reads a deployed instance's data.
The self-test exercises synthetic OMOD descriptors against the actual Core
comparator, including Patient Documents requiring O3 Forms `>=2.3.0`.

Core rejects `2.3.0-sihsalus.1` for that minimum even if O3 Forms itself starts.
The pinned correction
[`2.3.1-sihsalus.1`](https://github.com/sihsalus/openmrs-module-o3forms/releases/tag/2.3.1-sihsalus.1)
is an immutable prerelease that satisfies `2.3.0`, but not a future minimum of
`2.3.1`. It preserves the null-locale form translation fix. Its published OMOD,
checksum and signed provenance were verified before updating both version pins
and the Dockerfile checksum. The image gate must still validate the actual
packaged distribution; do not overwrite the old release or bypass the gate.

Static dependency acceptance is not module-start or clinical acceptance. After
an explicitly authorized deployment, separately verify O3 Forms, REST and Patient
Documents are started and test synthetic form open/save/edit flows in DEV before
coordinating QLTY.

Deploy only the tested backend image by SHA and OCI digest using the
[backend-only procedure](../scripts/deploy/README.md#backend-únicamente), with
synthetic DEV acceptance before QLTY. Preserve the prior image for rollback.

#### OpenMRS Configuration (Initializer)
OpenMRS config can be set under [`backend/config/openmrs_config/`](config/openmrs_config/) when present.

#### Tomcat rootless configuration directory

The image prepares the empty default Host XML base at
`/usr/local/tomcat/conf/Catalina/localhost` before switching to UID 1001.
Only that directory is owned by `1001:0` with mode `0750`; `conf` and `Catalina`
remain root-owned with mode `0755`. Do not make the entire configuration tree
writable or disable Tomcat's directory creation/validation to hide startup errors.

```bash
bash tests/backend/tomcat-config-config.sh
bash tests/backend/tomcat-config-image.sh IMAGE
```

The first test is offline. The second requires Docker and an already-built local
image; it runs only a shell with no network, no application startup and no mounted
runtime data. It checks the default user, real paths, ownership, modes and access,
then removes its test container and anonymous volumes. CI runs both gates before
promotion. These checks do not replace startup and clinical acceptance testing.

#### Micro Frontends
SPA-related configuration is driven by the distro build and the frontend package in this repository.

#### Micro Frontends configuration
MF Config can be set under the frontend or distro configuration used by the build.

----
