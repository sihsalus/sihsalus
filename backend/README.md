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

#### OpenMRS Configuration (Initializer)
OpenMRS config can be set under [`backend/config/openmrs_config/`](config/openmrs_config/) when present.

#### Micro Frontends
SPA-related configuration is driven by the distro build and the frontend package in this repository.

#### Micro Frontends configuration
MF Config can be set under the frontend or distro configuration used by the build.

----
