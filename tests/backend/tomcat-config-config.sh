#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$ROOT_DIR/backend/Dockerfile" <<'PY'
import pathlib
import sys


PARENT = "install -d -o 0 -g 0 -m 0755 /usr/local/tomcat/conf/Catalina"
HOST = "install -d -o 1001 -g 0 -m 0750 /usr/local/tomcat/conf/Catalina/localhost"


def instructions(source):
    pending = ""
    for line in source.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        pending += line.rstrip("\\").strip() + " "
        if line.endswith("\\"):
            continue
        operation, value = pending.strip().split(None, 1)
        yield operation.upper(), " ".join(value.split())
        pending = ""
    if pending:
        raise ValueError("unterminated Dockerfile instruction")


def validate(source):
    runtime = []
    base = None
    for operation, value in instructions(source):
        if operation == "FROM":
            runtime = []
            base = value
        else:
            runtime.append((operation, value))
    if base != "${OPENMRS_RUNTIME_IMAGE}":
        raise ValueError("expected the pinned OpenMRS runtime as the final stage")

    user = None
    matches = {PARENT: [], HOST: []}
    for operation, value in runtime:
        if operation == "USER":
            user = value
        elif operation == "RUN":
            for command in value.split("&&"):
                command = command.strip()
                if command in matches:
                    matches[command].append(user)
    if user not in ("1001", "1001:0"):
        raise ValueError("the runtime must still drop privileges to UID 1001")
    for command, users in matches.items():
        if users not in (["root"], ["0"], ["0:0"]):
            raise ValueError(f"expected exactly one root-owned preparation step: {command}")


source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
validate(source)

mutations = {
    "missing Host directory": source.replace(HOST, "true"),
    "missing parent preparation": source.replace(PARENT, "true"),
    "wrong Host owner": source.replace(HOST, HOST.replace("-o 1001", "-o 0")),
    "world-writable Host": source.replace(HOST, HOST.replace("0750", "0777")),
    "writable parent": source.replace(PARENT, PARENT.replace("0755", "0777")),
    "comment-only preparation": source.replace(HOST, "true") + "\n# RUN " + HOST + "\n",
    "unprivileged preparation": source.replace("RUN " + PARENT, "USER 1001\nRUN " + PARENT),
    "root runtime": source + "\nUSER root\n",
    "preparation in discarded stage": source + "\nFROM ${OPENMRS_RUNTIME_IMAGE}\nUSER 1001\n",
    "duplicate preparation": source + "\nUSER root\nRUN " + HOST + "\nUSER 1001\n",
}
for name, mutation in mutations.items():
    try:
        validate(mutation)
    except ValueError:
        continue
    raise SystemExit(f"[FAIL] accepted regression: {name}")

print(f"[OK] Tomcat rootless directory contract and {len(mutations)} regression checks")
PY
