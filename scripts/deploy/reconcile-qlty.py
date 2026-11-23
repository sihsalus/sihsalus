#!/usr/bin/env python3
"""Record an already running PostgreSQL 17 image and compatible checkout on QLTY."""

import argparse
from io import BytesIO
import importlib.util
import json
import os
import re
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
from zipfile import ZipFile

import deploy

release = deploy.releases
spec = importlib.util.spec_from_file_location("qlty", deploy.DIRECTORY / "deploy-qlty-backend.py")
qlty = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qlty)
PG = "fua-generator-db"
HELPER = "backend-oauth2-config"
DATA = "/var/lib/postgresql/data"


def compose_model(root, directory, manifest):
    command = release.compose_command(manifest, root / ".env") + ["config", "--no-path-resolution", "--format", "json"]
    data = json.loads(release.run(command, root=directory, environment=release.compose_environment(manifest)))
    return {key: value for key, value in data.items() if not key.startswith("x-")}


def verify_configuration(previous, candidate, root):
    source = previous["sources"]["distroCommit"]
    checkout = candidate["sources"]["distroCommit"]
    release.require(release.run(["git", "rev-parse", "HEAD"], root=root).strip() == checkout,
                    "Operational checkout changed during reconciliation")
    release.run(["git", "merge-base", "--is-ancestor", source, checkout], root=root)
    model = compose_model(root, root, previous)
    archive = release.run(["git", "archive", "--format=zip", source], root=root, binary=True)
    with TemporaryDirectory(prefix="sihsalus-reconcile-") as directory:
        with ZipFile(BytesIO(archive)) as snapshot:
            snapshot.extractall(directory)
        historical = compose_model(root, Path(directory), previous)
    release.require(model == historical, "Effective Compose configuration changed; coordinate the deployment")
    files = [mount["source"] for service in model["services"].values()
             for mount in service.get("volumes", []) if mount["type"] == "bind"]
    for category in ("configs", "secrets"):
        files.extend(item["file"] for item in model.get(category, {}).values() if "file" in item)
    tracked = set()
    for filename in files:
        path = Path(os.path.abspath(root / filename))
        if path.is_relative_to(root):
            release.require(path == path.resolve(), "Resolve linked runtime inputs before reconciliation")
            tracked.add(str(path.relative_to(root)))
    if tracked:
        try:
            release.run(["git", "--literal-pathspecs", "diff", "--quiet", source, checkout, "--", *sorted(tracked)], root=root)
        except release.ManifestError:
            raise release.ManifestError("Mounted repository files changed; coordinate the deployment") from None


def runtime_snapshot(root, manifest):
    ids = release.run(["docker", "ps", "-aq", "--no-trunc", "--filter",
                       "label=com.docker.compose.project=" + manifest["compose"]["project"]], root=root).splitlines()
    release.require(ids and all(release.matches(i, r"[a-f0-9]{64}") for i in ids), "Invalid runtime container inventory")
    template = ('{"name":{{json (index .Config.Labels "com.docker.compose.service")}},'
                '"oneoff":{{json (index .Config.Labels "com.docker.compose.oneoff")}},'
                '"id":{{json .Id}},"image":{{json .Image}},"configured":{{json .Config.Image}},'
                '"started":{{json .State.StartedAt}},"status":{{json .State.Status}},"exit":{{.State.ExitCode}},'
                '"health":{{with (index .State "Health")}}{{json .Status}}{{else}}null{{end}},'
                '"mounts":{{json .Mounts}}}')
    rows = release.run(["docker", "inspect", "--format", template, *ids], root=root).splitlines()
    items = [json.loads(row) for row in rows]
    # Docker does not guarantee mount order across consecutive inspections.
    for item in items:
        item["mounts"].sort(key=lambda mount: mount["Destination"])
    services = {item["name"]: item for item in items}
    release.require(len(services) == len(items) and all(str(i["oneoff"]).lower() != "true" for i in items),
                    "Unexpected or duplicate Compose container")
    helper = services.get(HELPER)
    release.require(helper and helper["status"] == "exited" and helper["exit"] == 0,
                    "The backend-oauth2-config container must exist and have exited successfully")
    release.require(set(services) == set(manifest["services"]), "Compose service inventory differs from the retained release")
    db = services[PG]
    release.require(db["status"] == "running" and db["health"] == "healthy", "FUA PostgreSQL is not healthy")
    data = [mount for mount in db["mounts"] if mount["Destination"] == DATA]
    volume = manifest["compose"]["project"] + "_db-fua-generator"
    release.require(len(data) == 1 and data[0]["Type"] == "volume" and data[0].get("Name") == volume and data[0]["RW"],
                    "FUA PostgreSQL data volume differs from the installed Compose volume")
    release.require(all(item["image"] == manifest["services"][name]["imageId"] for name, item in services.items() if name != PG),
                    "Only the FUA PostgreSQL image can be reconciled")
    return services


def pg_artifact(root, current, snapshot, digest):
    db = snapshot[PG]
    ref = "docker.io/library/postgres@" + digest
    official = ("postgres", "library/postgres", "docker.io/library/postgres")
    digests = {repo + "@" + digest for repo in official}
    configured = digests | {repo + ":17" for repo in official} | {repo + ":17@" + digest for repo in official}
    release.require(db["configured"] in configured, "Running FUA container does not identify the official PostgreSQL 17 image")
    # Docker retains the spelling used at creation. Identify the running bytes
    # by the immutable image ID and repo digest, even if that spelling was :17.
    inspected = release.inspect_image(ref, root)
    release.require(inspected["id"] == db["image"] and digests.intersection(inspected["digests"] or []),
                    "Running FUA image differs from the requested registry digest")
    major = '{{range .Config.Env}}{{if eq . "PG_MAJOR=17"}}PG_MAJOR=17{{end}}{{end}}'
    for image_id in {current["services"][PG]["imageId"], db["image"]}:
        release.require(release.run(["docker", "image", "inspect", image_id, "--format", major], root=root).strip() == "PG_MAJOR=17",
                        "Both FUA PostgreSQL images must have major version 17")
    return {"image": ref, "imageId": db["image"]}


def reconcile(root, expected, checkout, digest, apply=False):
    release.require(release.matches(expected, r"[0-9a-f]{64}") and release.matches(checkout, release.SHA)
                    and release.matches(digest, release.DIGEST), "Expected full release checksum, checkout SHA and PostgreSQL digest")
    root = deploy.checked_root(root)
    with release.release_lock(root) as state:
        path = Path(deploy.env_value(root, "SIHSALUS_RELEASE_MANIFEST"))
        release.require(path.parent == state and path.is_file() and not path.is_symlink(), "A retained selection on this host is required")
        current = release.validate_manifest(release.read_json(path))
        selected = release.manifest_digest(current)
        release.require(path.name == selected + ".json", "Selected manifest checksum differs")
        release.require(current["target"] == {"environment": "qlty", "nodeId": qlty.QLTY_NODE} and
                        deploy.env_value(root, "DEPLOYMENT_ENV") == "qlty" and
                        deploy.env_value(root, "SIHSALUS_NODE_ID") == qlty.QLTY_NODE, "Require the expected QLTY installation")
        release.require(release.run(["git", "rev-parse", "HEAD"], root=root).strip() == checkout,
                        "Operational checkout differs from the expected SHA")
        qlty.check_history(root, current)
        attempts = [p for p in deploy.history(root) if re.fullmatch(r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}", p.parent.name)]
        release.require(attempts, "A verified deployment journal is required")
        latest = release.read_json(attempts[0])
        release.require(latest["status"] == "verified" and latest["target"] == selected, "Selected release lacks verified history")
        replay = selected != expected
        if replay:
            release.require(latest["operation"] == "reconcile" and latest["previous"] == expected, "Expected release differs from current selection")
        release.verify_installed_selection(current, root, root / ".env", path)
        before = runtime_snapshot(root, current)
        artifact = pg_artifact(root, current, before, digest)
        unchanged = current["sources"]["distroCommit"] == checkout and current["services"][PG] == artifact
        release.require(not replay or unchanged, "Reconciliation replay differs from the completed operation")
        candidate = current if unchanged else deploy.candidate_release(current, root)
        if not unchanged:
            candidate["services"][PG] = artifact
        release.validate_manifest(candidate)
        release.verify_checkout(candidate, root)

        def verify_reconciliation(previous, target, installation):
            verify_configuration(previous, target, installation)
            observed = runtime_snapshot(installation, previous)
            release.require(observed == before, "Live containers or volumes changed during inspection")
            release.require(pg_artifact(installation, previous, observed, digest) == target["services"][PG],
                            "Candidate differs from the running PostgreSQL artifact")

        def verify_after():
            release.require(runtime_snapshot(root, candidate) == before, "Container identity, startup or mounts changed during reconciliation")

        if not unchanged and apply:
            release.apply_release(candidate, current, root, reconcile=True, state=state,
                                  verify_reconciliation=verify_reconciliation, verify=verify_after)
            return "reconciled"

        if unchanged:
            verify_reconciliation(current, candidate, root)
        else:
            release.verify_reconciliation_request(candidate, current, root, state, verify_reconciliation)
        release.verify_images(current, root)
        if not unchanged:
            release.verify_images(candidate, root)
        release.verify_compose(candidate, root, root / ".env")
        release.verify_runtime(candidate, root)
        verify_after()
        if unchanged:
            print("QLTY selection already matches the verified runtime.")
            return "unchanged"
        print("Dry run verified. Only the retained checkout and FUA PostgreSQL selection require reconciliation.")
        return "prepared"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-release", required=True)
    parser.add_argument("--checkout", required=True)
    parser.add_argument("--fua-postgres-digest", required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    try:
        reconcile(Path.cwd(), args.expected_release, args.checkout, args.fua_postgres_digest, args.apply)
    except (release.ManifestError, OSError, ValueError, KeyError, TypeError) as error:
        message = str(error) if isinstance(error, release.ManifestError) else "Cannot validate local deployment state"
        sys.exit(f"[reconcile-qlty] {message}")
