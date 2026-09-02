#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - \
  "$ROOT_DIR/backend/pom.xml" \
  "$ROOT_DIR/backend/distro.properties" \
  "$ROOT_DIR/backend/distro-no-demo.properties" \
  "$ROOT_DIR/gateway/default.conf.template" \
  "$ROOT_DIR/gateway/default-ssl.conf.template" <<'PY'
import pathlib
import re
import sys
import xml.etree.ElementTree as ET


def fail(message):
    raise SystemExit(f"[FAIL] {message}")


pom_path = pathlib.Path(sys.argv[1])
root = ET.parse(pom_path).getroot()
namespace = {"m": "http://maven.apache.org/POM/4.0.0"}

version = root.findtext("m:properties/m:sihsalusnotifications.version", namespaces=namespace)
if not version or not re.fullmatch(r"[0-9]+[.][0-9]+[.][0-9]+", version):
    fail("backend must pin sihsalusnotifications.version to a stable release")

dependencies = []
for dependency in root.findall("m:dependencies/m:dependency", namespace):
    dependencies.append({
        child.tag.rsplit("}", 1)[-1]: (child.text or "").strip()
        for child in dependency
    })

matches = [
    dependency for dependency in dependencies
    if dependency.get("groupId") == "io.github.proyecto-santaclotilde"
    and dependency.get("artifactId") == "sihsalusnotifications-omod"
]
if len(matches) != 1:
    fail("backend pom must contain exactly one SIHSALUS notifications OMOD dependency")
if matches[0].get("version") != "${sihsalusnotifications.version}":
    fail("notifications OMOD dependency must use the pinned version property")
if matches[0].get("scope") != "provided":
    fail("notifications OMOD dependency must use provided scope")

for raw_path in sys.argv[2:4]:
    path = pathlib.Path(raw_path)
    properties = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            properties[key] = value
    if properties.get("omod.sihsalusnotifications") != "${sihsalusnotifications.version}":
        fail(f"{path.name} must enable the notifications OMOD")
    if properties.get("omod.sihsalusnotifications.groupId") != "io.github.proyecto-santaclotilde":
        fail(f"{path.name} must resolve the notifications OMOD from the SIHSALUS group")


def location_body(configuration, marker):
    if configuration.count(marker) != 1:
        fail(f"gateway must contain exactly one {marker} location")
    start = configuration.index(marker)
    opening = configuration.index("{", start)
    depth = 0
    for index in range(opening, len(configuration)):
        character = configuration[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return configuration[opening + 1:index]
    fail(f"gateway location is not closed: {marker}")


websocket_marker = "location = /openmrs/ws/sihsalus/notifications {"
sse_marker = "location ~ ^/openmrs/ws/sihsalus/notifications/sse/?$ {"
for raw_path in sys.argv[4:]:
    path = pathlib.Path(raw_path)
    configuration = path.read_text(encoding="utf-8")
    websocket = location_body(configuration, websocket_marker)
    sse = location_body(configuration, sse_marker)

    for required in (
        "proxy_set_header HOST $http_host;",
        "proxy_set_header Upgrade $http_upgrade;",
        "proxy_set_header Connection $connection_upgrade;",
        "proxy_read_timeout 1810s;",
        "proxy_pass $backend;",
    ):
        if required not in websocket:
            fail(f"{path.name} WebSocket location is missing: {required}")

    for required in (
        "proxy_buffering off;",
        "proxy_cache off;",
        "proxy_read_timeout 130s;",
        "proxy_pass $backend;",
    ):
        if required not in sse:
            fail(f"{path.name} SSE location is missing: {required}")
    if "proxy_set_header Upgrade" in sse:
        fail(f"{path.name} SSE location must not request a WebSocket upgrade")

print("[OK] independent notifications OMOD and gateway transport contract")
PY
