#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ "$#" -eq 1 ]] || { echo "Usage: $0 IMAGE | --self-test" >&2; exit 2; }
IMAGE="$1"
MODE=image
if [[ "$IMAGE" == --self-test ]]; then
  MODE=self-test
elif [[ -z "$IMAGE" || "$IMAGE" == -* ]]; then
  echo "[FAIL] Supply an explicit backend image reference" >&2
  exit 2
fi

TEMP_DIR="$(mktemp -d)"
CONTAINER_ID=""
cleanup() {
  local status=$?
  if [[ -n "$CONTAINER_ID" ]] && ! docker rm --volumes "$CONTAINER_ID" >/dev/null; then
    echo "[FAIL] Could not remove test container $CONTAINER_ID; cleanup state retained in $TEMP_DIR" >&2
    [[ "$status" -ne 0 ]] || status=1
    return "$status"
  fi
  rm -rf -- "$TEMP_DIR"
  return "$status"
}
trap cleanup EXIT

if [[ "$MODE" == image ]]; then
  # Do not start OpenMRS, attach a deployment volume, or connect to any database.
  CONTAINER_ID="$(docker create --network none --entrypoint /bin/true "$IMAGE")"
  [[ "$CONTAINER_ID" =~ ^[0-9a-f]{64}$ ]] || {
    echo "[FAIL] Docker did not return a valid test container ID" >&2
    CONTAINER_ID=""
    exit 1
  }
  printf '%s\n' "$CONTAINER_ID" > "$TEMP_DIR/container-id"
  mkdir "$TEMP_DIR/modules"
  docker cp "$CONTAINER_ID:/openmrs/distribution/openmrs_modules/." "$TEMP_DIR/modules/"
fi

python3 - "$MODE" "$ROOT_DIR" "$TEMP_DIR" <<'PY'
from hashlib import sha256
from io import BytesIO
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET
from zipfile import BadZipFile, ZipFile

mode, root, temporary = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(modules, version, digest):
    matches = list(modules.glob("o3forms-*.omod"))
    require(len(matches) == 1, "the image must contain exactly one o3forms-*.omod")
    artifact = matches[0]
    require(artifact.name == f"o3forms-{version}.omod", "O3 Forms OMOD filename/version mismatch")
    require(sha256(artifact.read_bytes()).hexdigest() == digest,
            "packaged O3 Forms bytes differ from the checksum-pinned published release")
    with ZipFile(artifact) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), "duplicate entries in the O3 Forms OMOD")
        descriptor = ET.fromstring(archive.read("config.xml"))
        require(descriptor.findtext("id") == "o3forms", "O3 Forms descriptor ID mismatch")
        require(descriptor.findtext("version") == version, "O3 Forms descriptor version mismatch")
        require("org/openmrs/module/o3forms/api/impl/O3FormsServiceImpl.class" in names,
                "the O3 Forms service implementation is missing")
        apis = [name for name in names if re.fullmatch(r"lib/o3forms-api-[^/]+\.jar", name)]
        require(apis == [f"lib/o3forms-api-{version}.jar"],
                "the OMOD must contain exactly one API JAR matching the release version")
        with ZipFile(BytesIO(archive.read(apis[0]))) as api:
            properties = dict(
                line.split("=", 1) for line in api.read(
                    "META-INF/maven/org.openmrs.module/o3forms-api/pom.properties"
                ).decode().splitlines() if line and not line.startswith("#") and "=" in line
            )
            require(properties.get("groupId") == "org.openmrs.module"
                    and properties.get("artifactId") == "o3forms-api"
                    and properties.get("version") == version,
                    "nested O3 Forms API Maven coordinates/version mismatch")


def self_test():
    version = "2.3.0-sihsalus.1"
    modules = temporary / "self-test"
    modules.mkdir()
    artifact = modules / f"o3forms-{version}.omod"

    def fixture(module_id="o3forms", descriptor_version=version, api_version=version,
                coordinates_version=version, service=True, api_extra=False):
        api_bytes = BytesIO()
        with ZipFile(api_bytes, "w") as api:
            api.writestr("META-INF/maven/org.openmrs.module/o3forms-api/pom.properties",
                         "groupId=org.openmrs.module\nartifactId=o3forms-api\n"
                         f"version={coordinates_version}\n")
        with ZipFile(artifact, "w") as archive:
            archive.writestr("config.xml", f"<module><id>{module_id}</id>"
                             f"<version>{descriptor_version}</version></module>")
            if service:
                archive.writestr("org/openmrs/module/o3forms/api/impl/O3FormsServiceImpl.class",
                                 b"synthetic test entry; not executable Java")
            archive.writestr(f"lib/o3forms-api-{api_version}.jar", api_bytes.getvalue())
            if api_extra:
                archive.writestr("lib/o3forms-api-2.3.0.jar", api_bytes.getvalue())
        return sha256(artifact.read_bytes()).hexdigest()

    digest = fixture()
    verify(modules, version, digest)
    failures = [
        {"module_id": "other"}, {"descriptor_version": "2.3.0"},
        {"api_version": "2.3.0"}, {"coordinates_version": "2.3.0"},
        {"service": False}, {"api_extra": True},
    ]
    for arguments in failures:
        digest = fixture(**arguments)
        try:
            verify(modules, version, digest)
        except ValueError:
            continue
        raise ValueError(f"invalid image fixture was accepted: {arguments}")
    digest = fixture()
    for case in ("checksum", "duplicate", "missing"):
        if case == "duplicate":
            duplicate = modules / "o3forms-2.3.0.omod"
            duplicate.write_bytes(artifact.read_bytes())
        elif case == "missing":
            duplicate.unlink()
            artifact.unlink()
        try:
            verify(modules, version, "0" * 64 if case == "checksum" else digest)
        except ValueError:
            continue
        raise ValueError(f"invalid {case} image fixture was accepted")
    print("[OK] O3 Forms image verifier: 1 positive and 9 negative synthetic cases")


try:
    if mode == "self-test":
        self_test()
    else:
        dockerfile = (root / "backend/Dockerfile").read_text()
        versions = re.findall(r"^ARG O3FORMS_VERSION=([^\s]+)$", dockerfile, re.MULTILINE)
        require(len(versions) == 1, "the Dockerfile must pin one O3 Forms version")
        logical = re.sub(r"\\\n\s*", " ", dockerfile)
        checksums = re.findall(
            r"^ADD --checksum=sha256:([0-9a-f]{64})\s+"
            r"https://github\.com/sihsalus/openmrs-module-o3forms/releases/download/"
            r"\$\{O3FORMS_VERSION\}/o3forms-\$\{O3FORMS_VERSION\}\.omod\s+"
            r"/tmp/o3forms\.omod$", logical, re.MULTILINE,
        )
        require(len(checksums) == 1, "the Dockerfile must pin one O3 Forms release checksum")
        verify(temporary / "modules", versions[0], checksums[0])
        print(f"[OK] Image contains the exact O3 Forms {versions[0]} release, descriptor and API")
except (ValueError, OSError, KeyError, BadZipFile, ET.ParseError) as error:
    raise SystemExit(f"[FAIL] {error}")
PY
