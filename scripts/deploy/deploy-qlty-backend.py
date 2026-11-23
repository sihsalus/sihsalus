#!/usr/bin/env python3
"""Apply a published main backend on the QLTY host using the installed Compose selection."""

import argparse
from io import BytesIO
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
from tempfile import TemporaryDirectory
from zipfile import ZipFile

import deploy


release = deploy.releases
QLTY_NODE = "0cefb0c8-c860-48c5-856f-408594775cbb"
QLTY_URL = "https://gidis-hsc-qlty.inf.pucp.edu.pe"
REPOSITORY = "https://github.com/sihsalus/sihsalus.git"
MAIN_REF = "refs/sihsalus/qlty/backend-main"


def check_history(root, current):
    state = root / ".env.release-state"
    # The journal is created before the selection is changed. A process killed
    # while creating a journal may leave the directory without a result.
    attempts = [directory for directory in state.iterdir() if directory.is_dir()]
    attempts.sort(key=lambda directory: (directory / "result.json" if
                  (directory / "result.json").exists() else directory).stat().st_mtime_ns, reverse=True)
    for index, directory in enumerate(attempts):
        path = directory / "result.json"
        release.require(path.is_file(), "Incomplete release journal; inspect QLTY recovery history")
        result = release.read_json(path)
        if index == 0:
            release.require(result["status"] == "verified" and result["target"] == release.manifest_digest(current),
                            "Last QLTY deployment is unresolved; inspect the selected release and journal")
        before = release.read_json(directory / "previous.json")
        after = release.read_json(directory / "target.json")
        if before["sources"]["backend"] != after["sources"]["backend"]:
            # A later frontend-only operation cannot certify that a failed
            # backend migration was recovered.
            release.require(result["status"] == "verified", "Last backend change requires recovery review")
            break


def check_order(root, installed, selected):
    fetch = ["git", "fetch", "--no-tags", "--no-recurse-submodules", "--no-write-fetch-head"]
    if release.run(["git", "rev-parse", "--is-shallow-repository"], root=root).strip() == "true":
        fetch.append("--unshallow")
    release.run(fetch + [REPOSITORY, "refs/heads/main:" + MAIN_REF], root=root, timeout=300,
                environment={**os.environ, "GIT_TERMINAL_PROMPT": "0"})
    try:
        release.run(["git", "merge-base", "--is-ancestor", selected["commit"], MAIN_REF], root=root)
        release.run(["git", "merge-base", "--is-ancestor", installed["commit"], selected["commit"]], root=root)
    except release.ManifestError:
        raise release.ManifestError("QLTY requires a main publication descended from the installed backend") from None
    release.require(installed["commit"] != selected["commit"] or installed == selected,
                    "Two digests for the same backend commit require explicit selection")


def backend_model(directory, installed_root, manifest):
    # Compose includes only the selected service, its transitive dependencies
    # and their resources. Paths must stay relative to compare two checkouts.
    command = release.compose_command(manifest, installed_root / ".env")
    rendered = release.run(command + ["config", "--format", "json", "--no-path-resolution", "backend"],
                           root=directory, environment=release.compose_environment(manifest))
    return json.loads(rendered)


def ignore_log_rotation(service, default_driver):
    logging = service.get("logging", {})
    if logging.get("driver", default_driver) == "json-file":
        options = dict(logging.get("options", {}))
        options.pop("max-size", None)
        options.pop("max-file", None)
        remaining = {key: value for key, value in logging.items() if key not in ("driver", "options")}
        if default_driver != "json-file":
            remaining["driver"] = "json-file"
        if options:
            remaining["options"] = options
        if remaining:
            service["logging"] = remaining
        else:
            service.pop("logging", None)


def check_compatibility(root, manifest, sha):
    installed = backend_model(root, root, manifest)
    # Read tracked files into a private temporary directory without checking
    # out another revision in the installation or copying its .env.
    snapshot = release.run(["git", "archive", "--format=zip", sha], root=root, binary=True)
    with TemporaryDirectory(prefix="sihsalus-qlty-compose-") as directory:
        with ZipFile(BytesIO(snapshot)) as archive:
            archive.extractall(directory)
        proposed = backend_model(Path(directory), root, manifest)

    if installed != proposed:
        driver = release.run(["docker", "info", "--format", "{{.LoggingDriver}}"], root=root).strip()
        for model in (installed, proposed):
            for service in model["services"].values():
                ignore_log_rotation(service, driver)
    release.require(installed == proposed, "Candidate needs a coordinated change to the installed backend Compose configuration")

    files = [mount["source"] for service in installed["services"].values()
             for mount in service.get("volumes", []) if mount["type"] == "bind"]
    for resource in ("secrets", "configs"):
        files.extend(item["file"] for item in installed.get(resource, {}).values() if "file" in item)
    local = set()
    for filename in files:
        path = (root / filename).resolve()
        if path.is_relative_to(root):
            local.add(str(path.relative_to(root)))
    if local:
        try:
            release.run(["git", "--literal-pathspecs", "diff", "--quiet", "HEAD", sha, "--", *sorted(local)], root=root)
        except release.ManifestError:
            raise release.ManifestError("Candidate requires a coordinated change to backend runtime files") from None


def update(root, sha, digest):
    release.require(release.matches(sha, release.SHA) and release.matches(digest, release.DIGEST),
                    "A complete published SHA and sha256 digest are required")
    release.require(deploy.env_value(root, "DEPLOYMENT_ENV") == "qlty" and
                    deploy.env_value(root, "SIHSALUS_NODE_ID") == QLTY_NODE,
                    "This operation requires the QLTY installation and node identity")

    def validate(current, candidate, component):
        release.require(component == "backend" and current["target"] == {"environment": "qlty", "nodeId": QLTY_NODE},
                        "Release target differs from the QLTY backend")
        installed = current["sources"]["backend"]
        selected = candidate["sources"]["backend"]
        check_history(root, current)
        check_order(root, installed, selected)
        if installed == selected:
            # execute_update already checks local health and image identity for
            # a no-op; also prove public readiness before reporting success.
            deploy.verify_external(current, root, QLTY_URL)
        else:
            check_compatibility(root, current, sha)

    def backup(_current, _candidate, _component):
        subprocess.run(["bash", str(deploy.DIRECTORY / "qlty-pre-backend-backup.sh")], cwd=root, check=True)

    outcome = deploy.execute_update(root, "backend", sha, expected_digest=digest, public_url=QLTY_URL,
                                    validate_candidate=validate, before_apply=backup)
    release.require(outcome["status"] in ("updated", "unchanged"), "Backend update did not complete")
    print(f"[deploy-qlty-backend] frontend={outcome['candidate']['sources']['frontend']['commit']}")
    print(f"[deploy-qlty-backend] backend={sha} digest={digest} status={outcome['status']}")


if __name__ == "__main__":
    def interrupted(_number, _frame):
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sha")
    parser.add_argument("digest")
    args = parser.parse_args()
    try:
        update(Path.cwd(), args.sha, args.digest)
    except (release.ManifestError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        sys.exit(f"[deploy-qlty-backend] Failed: {error}")
