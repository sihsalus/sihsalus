#!/usr/bin/env python3
"""Synthetic credentials, Compose isolation checks and bounded log redaction."""

import argparse
import base64
import json
import os
from pathlib import Path
import re
import secrets
import sys
from urllib.parse import quote
from uuid import uuid4


CORE = {"gateway", "frontend", "docs", "backend", "backend-oauth2-config", "db"}


def prepare(directory, mode, digest):
    if mode not in ("local", "keycloak") or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ValueError("invalid synthetic runtime configuration")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.umask(0o077)
    password = lambda: secrets.token_hex(24) + "Aa1!"
    initial, replacement = password(), password()
    project = "runtime-smoke-" + uuid4().hex[:16]
    environment = {
        "COMPOSE_PROJECT_NAME": project,
        "MYSQL_ROOT_PASSWORD": password(), "MYSQL_OPENMRS_PASSWORD": password(),
        "OMRS_DB_REPL_PASSWORD": password(), "OMRS_DB_BACKUP_PASSWORD": password(),
        "OPENMRS_DB_USER": "openmrs", "OMRS_OCL_TOKEN": "",
        "SMOKE_INITIAL_PASSWORD": initial, "SMOKE_REPLACEMENT_PASSWORD": replacement,
        "KEYCLOAK_ADMIN_PASSWORD": initial,
        "KC_DB_PASSWORD": password(), "OAUTH2_CLIENT_SECRET": password(),
        "IMAGING_OIDC_CLIENT_SECRET": password(),
        "KEYCLOAK_PUBLIC_URL": "http://127.0.0.1/keycloak", "KC_HOSTNAME": "http://127.0.0.1/keycloak",
        "OPENMRS_REDIRECT_URI": "http://127.0.0.1/openmrs/*",
        "IMAGING_OAUTH_REDIRECT_URI": "http://127.0.0.1/imaging/oauth2/callback",
        "KEYCLOAK_MODE": "development", "SIHSALUS_NODE_ID": str(uuid4()),
        "BACKEND_DIGEST": digest, "BACKEND_TAG": "latest@" + digest,
        "FRONTEND_RUNTIME_IMAGE": project + "-frontend",
        "FRONTEND_RUNTIME_TAG": "test", "SIHSALUS_FORCED_PASSWORD_CHANGE_ENABLED": "true",
    }
    metadata = {"project": project, "mode": mode, "baseURL": "http://127.0.0.1", "backendDigest": digest}
    with (directory / "fixture.json").open("x") as output:
        output.write(json.dumps(metadata) + "\n")
    return {**metadata, "initialPassword": initial, "replacementPassword": replacement, "environment": environment}


def validate_model(model, fixture, repository):
    project = fixture["project"]
    expected = CORE | ({"keycloak", "keycloak-db"} if fixture["mode"] == "keycloak" else set())
    if model.get("name") != project or set(model.get("services", {})) != expected:
        raise ValueError("unexpected Compose project or active services")
    for resources in (model.get("volumes", {}), model.get("networks", {})):
        for resource in resources.values():
            if resource.get("external") or not resource.get("name", "").startswith(project + "_"):
                raise ValueError("runtime test cannot reuse an external or unscoped resource")
    for name, service in model["services"].items():
        if not service.get("container_name", "").startswith(project + "-"):
            raise ValueError("runtime test container is not isolated")
        for port in service.get("ports", []):
            if name != "gateway" or port.get("host_ip") != "127.0.0.1" or str(port.get("published")) != "80":
                raise ValueError("runtime test may expose only the loopback gateway")
        for mount in service.get("volumes", []):
            if mount["type"] == "bind":
                source = Path(mount["source"]).resolve()
                if not source.is_relative_to(repository.resolve()) or not mount.get("read_only"):
                    raise ValueError("runtime binds must be read-only repository files")
    if model["services"]["backend"]["image"] != "ghcr.io/sihsalus/sihsalus-backend:latest@" + fixture["backendDigest"]:
        raise ValueError("backend must use the resolved immutable digest")


def sanitize(text, fixture):
    values = [fixture["initialPassword"], fixture["replacementPassword"]]
    values += [value for key, value in fixture["environment"].items()
               if value and re.search(r"PASSWORD|SECRET|TOKEN", key)]
    for value in sorted(set(values), key=len, reverse=True):
        for encoded in (value, quote(value, safe=""), base64.b64encode(("admin:" + value).encode()).decode()):
            text = text.replace(encoded, "[REDACTED]")
    text = re.sub(r"(?i)(\b(?:Bearer|Basic)\s+)[A-Za-z0-9._~+/=-]+", r"\1[REDACTED]", text)
    text = re.sub(r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+", "[REDACTED-JWT]", text)
    # Keycloak also uses session_code, execution, tab_id and client_data. Keep
    # the URL path for diagnosis, but retain no query or fragment values.
    text = re.sub(r"((?:https?://[^\s?#\"<>]+|/[^\s?#\"<>]*)[?#])[^\s\"<>]*", r"\1[REDACTED-QUERY]", text)
    text = re.sub(r"(?i)((?:[?&;]|\b)(?:code|state|session_state|sessionId|jsessionid|access_token|refresh_token|id_token)=)[^\s&;\"<>]+", r"\1[REDACTED]", text)
    text = re.sub(r"(?im)^.*(?:set-cookie|cookie|authorization)\s*[:=].*$", "[REDACTED HEADER]", text)
    text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text)
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("run", "validate", "sanitize"))
    parser.add_argument("directory", type=Path)
    parser.add_argument("arguments", nargs="*")
    args = parser.parse_args()
    if args.operation == "run":
        fixture = prepare(args.directory, *args.arguments)
        os.execvpe("bash", ["bash", str(Path(__file__).with_name("run.sh")), fixture["mode"]],
                   {**os.environ, **fixture["environment"], "SMOKE_STATE": str(args.directory.resolve())})
    fixture = json.loads((args.directory / "fixture.json").read_text())
    if args.operation == "validate":
        validate_model(json.load(sys.stdin), fixture, Path(args.arguments[0]))
        print("PASS: isolated core Compose with immutable backend and loopback gateway")
        return
    destination = Path(args.arguments[0])
    destination.mkdir(parents=True, exist_ok=True)
    fixture.update(initialPassword=os.environ["SMOKE_INITIAL_PASSWORD"],
                   replacementPassword=os.environ["SMOKE_REPLACEMENT_PASSWORD"], environment=os.environ)
    for log in args.directory.glob("*.log"):
        # Bound retained evidence; raw files and browser artifacts stay private.
        with log.open("rb") as source:
            source.seek(max(0, log.stat().st_size - 2 * 1024 * 1024))
            output = sanitize(source.read().decode(errors="replace"), fixture)
        (destination / log.name).write_text(output)


if __name__ == "__main__":
    main()
