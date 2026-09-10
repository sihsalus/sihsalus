#!/usr/bin/env python3
"""Verify REST/EMR API release consumption without starting OpenMRS or a database."""
import argparse
from hashlib import sha256
from io import BytesIO
from pathlib import Path
import re
import shlex
from tempfile import TemporaryDirectory
import xml.etree.ElementTree as ET
from zipfile import BadZipFile, ZipFile

ROOT = Path(__file__).resolve().parents[2]
NS = {"m": "http://maven.apache.org/POM/4.0.0"}
MODULES = {
    "webservices.rest": ("REST_VERSION", "openmrs-module-webservices.rest"),
    "emrapi": ("EMRAPI_VERSION", "openmrs-module-emrapi"),
}
INSTALL = "org.apache.maven.plugins:maven-install-plugin:3.1.4:install-file"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate(dockerfile, pom_xml, distro, lock, builder):
    instructions = [line.strip() for line in re.sub(r"\\\n\s*", " ", dockerfile).splitlines()
                    if line.strip() and not line.lstrip().startswith("#")]
    stages = [i for i, line in enumerate(instructions) if line.startswith("FROM ")]
    require(len(stages) == 2, "Review release consumption when the Docker stages change")
    build = instructions[stages[0] + 1:stages[1]]
    runtime = instructions[stages[1] + 1:]
    pom = ET.fromstring(pom_xml)
    locked_modules = [line.split()[0] for line in lock.splitlines()
                      if line.strip() and not line.lstrip().startswith("#")]
    require("git apply" not in builder, "Source builder must not apply external patches")
    expected = {}
    for module, (variable, repository) in MODULES.items():
        versions = [line.split("=", 1)[1] for line in build if line.startswith(f"ARG {variable}=")]
        require(len(versions) == 1, f"Pin {variable} exactly once")
        version = versions[0]
        require(re.fullmatch(r"\d+\.\d+\.\d+-sihsalus\.\d+", version), f"Unversioned {module}")
        url = (f"https://github.com/sihsalus/{repository}/releases/download/"
               f"${{{variable}}}/{module}-${{{variable}}}.omod")
        downloads = [line for line in instructions if f"github.com/sihsalus/{repository}/" in line]
        require(len(downloads) == 1 and downloads[0] in build, f"One build-stage release required: {module}")
        match = re.fullmatch(r"ADD --checksum=sha256:([0-9a-f]{64})\s+" + re.escape(url)
                             + r"\s+" + re.escape(f"/tmp/{module}.omod"), downloads[0])
        require(match is not None, f"Literal release URL and SHA-256 required: {module}")
        require(module not in locked_modules, f"{module} must not be compiled from the source lock")
        require(not any(module in line or repository in line for line in runtime),
                f"Do not install {module} separately at runtime")
        properties = pom.findall(f"m:properties/m:{module}.version", NS)
        require(len(properties) == 1 and properties[0].text == version, f"POM/version mismatch: {module}")
        dependencies = [dep for dep in pom.findall("m:dependencies/m:dependency", NS)
                        if dep.findtext("m:artifactId", namespaces=NS) == f"{module}-omod"]
        require(len(dependencies) == 1, f"Exactly one {module} dependency required")
        for key, value in (("groupId", "org.openmrs.module"), ("version", f"${{{module}.version}}"),
                           ("scope", "provided")):
            require(dependencies[0].findtext(f"m:{key}", namespaces=NS) == value,
                    f"Unexpected {module} Maven {key}")
        entries = [line.strip() for line in distro.splitlines()
                   if re.match(r"\s*omod\." + re.escape(module) + r"\s*=", line)]
        require(entries == [f"omod.{module}=${{{module}.version}}"], f"Distro/version mismatch: {module}")
        runs = [line for line in build if line.startswith("RUN ") and f"-DartifactId={module}-omod" in line]
        require(len(runs) == 1, f"Exactly one binary install required: {module}")
        run = runs[0]
        require(run.startswith("RUN --mount=type=cache,target=/root/.m2/repository ")
                and "||" not in run and ";" not in run, f"Fail-fast shared Maven cache required: {module}")
        commands = [command.strip() for command in run.split(" && ")]
        installs = [command for command in commands if f"-DartifactId={module}-omod" in shlex.split(command)]
        require(len(installs) == 1, f"Exactly one Maven install required: {module}")
        tokens = shlex.split(installs[0])
        for token in ("mvn", INSTALL, f"-Dfile=/tmp/{module}.omod", "-DgroupId=org.openmrs.module",
                      f"-DartifactId={module}-omod", f"-Dversion=${{{variable}}}",
                      "-Dpackaging=jar", "-DgeneratePom=true"):
            require(tokens.count(token) == 1, f"Binary install must specify {token}")
        distro_command = "mvn $MVN_ARGS_SETTINGS $MVN_ARGS"
        require(commands.count(distro_command) == 1
                and commands.index(installs[0]) < commands.index(distro_command),
                f"Install {module} before packaging in the same RUN")
        expected[module] = (version, match.group(1))
    return expected


def verify_binaries(directory, expected):
    for module, (version, digest) in expected.items():
        matches = list(directory.glob(f"{module}-*.omod"))
        require(len(matches) == 1, f"Expected exactly one {module} OMOD")
        artifact = matches[0]
        require(artifact.name == f"{module}-{version}.omod", f"Wrong {module} filename/version")
        payload = artifact.read_bytes()
        require(sha256(payload).hexdigest() == digest, f"{module} bytes differ from the published release pin")
        with ZipFile(BytesIO(payload)) as archive:
            names = archive.namelist()
            require(len(names) == len(set(names)), f"Duplicate {module} OMOD entries")
            config = ET.fromstring(archive.read("config.xml"))
            require(config.findtext("id") == module and config.findtext("version") == version,
                    f"Wrong {module} descriptor identity/version")
            if module == "emrapi":
                apis = [name for name in names if re.fullmatch(r"lib/emrapi-api-[^/]+\.jar", name)
                        and not name.startswith("lib/emrapi-api-reporting-")]
                require(apis == [f"lib/emrapi-api-{version}.jar"], "Wrong nested EMR API version")


def self_test(arguments, expected):
    docker, pom, distro, lock, builder = arguments
    failures = []
    for module, (variable, repository) in MODULES.items():
        version = expected[module][0]
        failures.extend([
            (docker.replace(f"ARG {variable}=", f"ARG UNPINNED_{variable}="), pom, distro, lock, builder),
            (docker.replace(f"{repository}/releases/download/", f"{repository}/archive/"), pom, distro, lock, builder),
            (docker.replace(f"-Dfile=/tmp/{module}.omod", "-Dfile=/tmp/other.omod"), pom, distro, lock, builder),
            (docker.replace(f"-Dversion=${{{variable}}}", "-Dversion=0.0.0"), pom, distro, lock, builder),
            (docker, pom.replace(f"<{module}.version>{version}</{module}.version>",
                                 f"<{module}.version>0.0.0</{module}.version>"), distro, lock, builder),
            (docker, pom, distro, lock + f"\n{module} upstream/source\n", builder),
            (docker + f"\nRUN cp /tmp/{module}.omod /openmrs/data/modules/\n", pom, distro, lock, builder),
            (docker.replace(expected[module][1], "missing-checksum"), pom, distro, lock, builder),
        ])
    failures.append((docker, pom, distro, lock, builder + "\ngit apply fix.patch\n"))
    for case in failures:
        try:
            validate(*case)
        except ValueError:
            continue
        raise ValueError("Invalid release consumption configuration accepted")
    with TemporaryDirectory(prefix="sihsalus-release-verifier-") as temporary:
        directory = Path(temporary)
        for module in MODULES:
            version = "3.5.1-sihsalus.1"
            artifact = directory / f"{module}-{version}.omod"

            def fixture(identity=module, descriptor_version=version, api_version=version):
                with ZipFile(artifact, "w") as archive:
                    archive.writestr("config.xml", f"<module><id>{identity}</id>"
                                     f"<version>{descriptor_version}</version></module>")
                    if module == "emrapi":
                        archive.writestr(f"lib/emrapi-api-{api_version}.jar", b"synthetic fixture")
                        archive.writestr(f"lib/emrapi-api-reporting-{version}.jar", b"synthetic reporting API")
                return {module: (version, sha256(artifact.read_bytes()).hexdigest())}

            verify_binaries(directory, fixture())
            invalid = [dict(identity="other"), dict(descriptor_version="0.0.0")]
            if module == "emrapi":
                invalid.append(dict(api_version="0.0.0"))
            for overrides in invalid:
                try:
                    verify_binaries(directory, fixture(**overrides))
                except ValueError:
                    continue
                raise ValueError("Invalid binary descriptor accepted")
            fixture()
            try:
                verify_binaries(directory, {module: (version, "0" * 64)})
            except ValueError:
                pass
            else:
                raise ValueError("Invalid binary digest accepted")
    print(f"[OK] {len(failures)} negative configuration cases and release binary fixtures")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--self-test", action="store_true")
    mode.add_argument("--modules", type=Path)
    args = parser.parse_args()
    arguments = tuple((ROOT / name).read_text() for name in (
        "backend/Dockerfile", "backend/pom.xml", "backend/distro.properties",
        "backend/omod-sources.lock", "backend/bin/build-source-omods.sh"))
    expected = validate(*arguments)
    require(not list((ROOT / "backend/patches").glob("*.patch")), "External OMOD patches must live in owning repos")
    if args.self_test:
        self_test(arguments, expected)
    else:
        verify_binaries(args.modules, expected)
    print("[OK] REST and EMR API consume exact checksum-pinned module releases")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, BadZipFile, ET.ParseError) as error:
        raise SystemExit(f"[FAIL] {error}")
