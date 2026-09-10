#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${1:?Supply the backend image}"
TEMP_DIR="$(mktemp -d)"
CONTAINER=""
cleanup() {
  [[ -z "$CONTAINER" ]] || docker rm "$CONTAINER" >/dev/null
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT
CONTAINER="$(docker create "$IMAGE")"
docker cp "$CONTAINER:/openmrs/distribution/openmrs_modules/." "$TEMP_DIR/"
python3 - "$ROOT" "$TEMP_DIR" <<'PY'
from pathlib import Path
import io
import sys
import xml.etree.ElementTree as ET
import zipfile

root, modules = map(Path, sys.argv[1:])
ns = {'m': 'http://maven.apache.org/POM/4.0.0'}
pom = ET.parse(root / 'backend/pom.xml').getroot()
properties = {e.tag.split('}')[1]: e.text for e in pom.find('m:properties', ns)}
expected = {}
for line in (root / 'backend/distro.properties').read_text().splitlines():
    if line.startswith('omod.') and '=' in line:
        key, value = line.split('=', 1)
        if key.endswith(('.groupId', '.type')):
            continue
        expected[key[5:]] = properties[value[2:-1]]
actual = {}
for path in modules.glob('*.omod'):
    with zipfile.ZipFile(path) as archive:
        config = ET.fromstring(archive.read('config.xml'))
        module, version = config.findtext('id'), config.findtext('version')
        assert module not in actual, f'Duplicate OMOD: {module}'
        actual[module] = version
        if module == 'webservices.rest':
            controller = archive.read('org/openmrs/module/webservices/rest/web/v1_0/controller/openmrs1_9/ClobDatatypeStorageController.class')
            for value in [b'text/plain;charset=UTF-8', b'X-Content-Type-Options', b'nosniff']:
                assert value in controller, f'REST protection missing: {value!r}'
        if module == 'emrapi':
            api_entries = [name for name in archive.namelist()
                           if name.startswith('lib/emrapi-api-') and name.endswith('.jar')]
            assert len(api_entries) == 1, 'Expected one packaged EMR API library'
            with zipfile.ZipFile(io.BytesIO(archive.read(api_entries[0]))) as api:
                service = api.read('org/openmrs/module/emrapi/adt/AdtServiceImpl.class')
                assert b'Failed to close inactive visit; rolling back closure batch: ' in service, \
                    'Compiled EMR API closure containment patch missing'
assert actual == expected, f'Packaged OMOD mismatch: expected={expected}, actual={actual}'
print(f'[OK] All {len(actual)} OMOD versions match; compiled REST and EMR API protection markers are present')
PY
