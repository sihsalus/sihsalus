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

Deploy only the tested backend image by SHA and OCI digest using the
[backend-only procedure](../scripts/deploy/README.md#backend-únicamente), with
synthetic DEV acceptance before QLTY. Preserve the prior image for rollback.

#### OpenMRS Configuration (Initializer)
OpenMRS config can be set under [`backend/config/openmrs_config/`](config/openmrs_config/) when present.

#### Micro Frontends
SPA-related configuration is driven by the distro build and the frontend package in this repository.

#### Micro Frontends configuration
MF Config can be set under the frontend or distro configuration used by the build.

----
