#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
from pathlib import Path
import re
import shlex
import sys
import xml.etree.ElementTree as ET

root = Path(sys.argv[1])
ns = {"m": "http://maven.apache.org/POM/4.0.0"}
release_url = (
    "https://github.com/sihsalus/openmrs-module-o3forms/releases/download/"
    "${O3FORMS_VERSION}/o3forms-${O3FORMS_VERSION}.omod"
)
install_goal = "org.apache.maven.plugins:maven-install-plugin:3.1.4:install-file"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate(dockerfile, pom_xml, distro, lock):
    # Read logical Docker instructions; comments cannot satisfy a build contract.
    instructions = [
        line.strip() for line in re.sub(r"\\\n\s*", " ", dockerfile).splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    stages = [i for i, line in enumerate(instructions) if line.startswith("FROM ")]
    require(len(stages) == 2, "review the O3 release contract when build stages change")
    build = instructions[stages[0] + 1:stages[1]]
    runtime = instructions[stages[1] + 1:]
    versions = [line.removeprefix("ARG O3FORMS_VERSION=") for line in build
                if line.startswith("ARG O3FORMS_VERSION=")]
    require(len(versions) == 1, "pin O3FORMS_VERSION exactly once in the build stage")
    version = versions[0]
    require(re.fullmatch(r"\d+\.\d+\.\d+-sihsalus\.\d+", version),
            "O3 Forms must use an immutable SIH Salus release version")

    downloads = [line for line in instructions if release_url in line]
    require(len(downloads) == 1 and downloads[0] in build,
            "consume exactly one O3 Forms release asset in the build stage")
    require(re.fullmatch(
        r"ADD --checksum=sha256:[0-9a-f]{64}\s+" + re.escape(release_url)
        + r"\s+/tmp/o3forms\.omod", downloads[0]),
        "the O3 Forms release URL must use a literal 64-hex SHA-256 checksum")

    installs = [line for line in build if install_goal in line]
    require(len(installs) == 1, "install the published O3 Forms binary exactly once")
    install = installs[0]
    require(install.startswith("RUN --mount=type=cache,target=/root/.m2/repository "),
            "install O3 Forms inside the distro Maven cache mount")
    require("||" not in install and ";" not in install,
            "O3 Forms installation and packaging must fail closed")
    commands = [command.strip() for command in install.split(" && ")]
    binary_installs = [command for command in commands if install_goal in command
                       and "-DartifactId=o3forms-omod" in shlex.split(command)]
    require(len(binary_installs) == 1, "keep one fail-fast binary install command")
    tokens = shlex.split(binary_installs[0])
    for token in (
        "mvn", install_goal, "-Dfile=/tmp/o3forms.omod",
        "-DgroupId=org.openmrs.module", "-DartifactId=o3forms-omod",
        "-Dversion=${O3FORMS_VERSION}", "-Dpackaging=jar", "-DgeneratePom=true",
    ):
        require(tokens.count(token) == 1, f"binary Maven install must specify {token}")
    distro_command = "mvn $MVN_ARGS_SETTINGS $MVN_ARGS"
    require(commands.count(distro_command) == 1,
            "install O3 Forms in the same fail-fast RUN as distro packaging")
    require(commands.index(binary_installs[0]) < commands.index(distro_command),
            "the release binary must enter Maven before distro packaging")

    require(not any("o3forms" in line.lower() for line in runtime),
            "runtime must consume the distribution, not install O3 Forms manually")
    require(not any("openmrs-module-o3forms/archive/" in line.lower()
                    or "o3forms-source" in line.lower() for line in instructions),
            "O3 Forms source compilation belongs in the module repository")
    active_lock = "\n".join(line for line in lock.splitlines()
                            if line.strip() and not line.lstrip().startswith("#"))
    require("o3forms" not in active_lock.lower(),
            "O3 Forms must not return to the source-build lock")

    pom = ET.fromstring(pom_xml)
    versions = pom.findall("m:properties/m:o3forms.version", ns)
    require(len(versions) == 1 and versions[0].text == version,
            "POM and Dockerfile must select the same O3 Forms release")
    deps = [dep for dep in pom.findall("m:dependencies/m:dependency", ns)
            if dep.findtext("m:artifactId", namespaces=ns) == "o3forms-omod"]
    require(len(deps) == 1, "the distro must declare exactly one O3 Forms dependency")
    for name, expected in (("groupId", "org.openmrs.module"),
                           ("version", "${o3forms.version}"), ("scope", "provided")):
        require(deps[0].findtext(f"m:{name}", namespaces=ns) == expected,
                f"O3 Forms dependency {name} must be {expected}")
    entries = [line.strip() for line in distro.splitlines()
               if re.match(r"\s*omod\.o3forms\s*=", line)]
    require(entries == ["omod.o3forms=${o3forms.version}"],
            "the distribution must select O3 Forms through its POM property")
    return version


try:
    dockerfile = (root / "backend/Dockerfile").read_text()
    pom = (root / "backend/pom.xml").read_text()
    distro = (root / "backend/distro.properties").read_text()
    lock = (root / "backend/omod-sources.lock").read_text()
    version = validate(dockerfile, pom, distro, lock)

    # Exercise fail-closed checks against the current reviewed configuration.
    mutations = [
        (dockerfile.replace("ARG O3FORMS_VERSION=", "ARG UNPINNED_O3_VERSION="), pom, distro, lock),
        (dockerfile.replace(release_url, release_url.replace("releases/download/", "archive/")), pom, distro, lock),
        (dockerfile.replace("-Dpackaging=jar", "-Dpackaging=omod"), pom, distro, lock),
        (dockerfile.replace("-Dversion=${O3FORMS_VERSION}", "-Dversion=2.3.0"), pom, distro, lock),
        (dockerfile.replace(install_goal, "install:install-file"), pom, distro, lock),
        (dockerfile + "\nRUN cp /tmp/o3forms.omod /openmrs/data/modules/\n", pom, distro, lock),
        (dockerfile, pom.replace(f"<o3forms.version>{version}</o3forms.version>",
                                 "<o3forms.version>2.3.0</o3forms.version>"), distro, lock),
        (dockerfile, pom, distro.replace("omod.o3forms=${o3forms.version}", "omod.o3forms=2.3.0"), lock),
        (dockerfile, pom, distro, lock + "\no3forms openmrs/openmrs-module-o3forms\n"),
    ]
    # Alter only the O3 release checksum, not other pinned source artifacts.
    malformed_checksum = re.sub(
        r"(ADD --checksum=sha256:)[0-9a-f]{64}(\s*\\?\s*\n?\s*"
        + re.escape(release_url) + r")", r"\g<1>missing-release-checksum\2", dockerfile,
    )
    require(malformed_checksum != dockerfile, "could not exercise the O3 checksum rejection")
    mutations.append((malformed_checksum, pom, distro, lock))
    for index, arguments in enumerate(mutations, 1):
        try:
            validate(*arguments)
        except ValueError:
            continue
        raise ValueError(f"negative configuration case {index} was accepted")

    for path in (root / "backend").rglob("*"):
        if not path.is_file() or "target" in path.parts:
            continue
        if path.suffix in (".patch", ".java") or path.parent == root / "backend/bin":
            require("o3forms" not in path.name.lower()
                    and "o3forms" not in path.read_text().lower(),
                    f"O3 Forms Java/patch/startup logic must not live in {path.relative_to(root)}")
except (ValueError, ET.ParseError, OSError) as error:
    raise SystemExit(f"[FAIL] {error}")

print(f"[OK] O3 Forms {version}: published binary, pinned checksum and no runtime install")
print(f"[OK] {len(mutations)} negative configuration cases rejected")
PY
