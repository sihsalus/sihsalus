#!/usr/bin/env python3
"""Validate, capture and consume immutable, node-specific SIHSalus releases."""

import argparse
from contextlib import contextmanager
from datetime import datetime
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tarfile
import tempfile
from uuid import UUID, uuid4


CORE_SERVICES = {"backend", "backend-oauth2-config", "db", "docs", "frontend", "gateway"}
SHA = r"[0-9a-f]{40}"
DIGEST = r"sha256:[0-9a-f]{64}"
NAME = r"[a-z0-9][a-z0-9_-]{0,63}"
REGISTRY_IMAGE = (
    r"[a-z0-9]+(?:[._-][a-z0-9]+)*(?::[0-9]+)?"
    r"(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)+"
    r"(?::[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?@" + DIGEST
)
BACKEND_REPOSITORY = "ghcr.io/sihsalus/sihsalus-backend"
FRONTEND_REPOSITORY = "ghcr.io/sihsalus/sihsalus-frontend"


class ManifestError(Exception):
    """An intentionally bounded error that does not contain input values."""


def require(condition, message):
    if not condition:
        raise ManifestError(message)


def keys(value, expected, context):
    require(isinstance(value, dict) and set(value) == set(expected), f"Invalid {context} fields")


def matches(value, expression):
    return isinstance(value, str) and re.fullmatch(expression, value) is not None


def unique_strings(value, pattern, context, allow_empty=False):
    require(isinstance(value, list), f"Invalid {context} list")
    require(allow_empty or len(value) > 0, f"Empty {context} list")
    require(all(matches(item, pattern) for item in value), f"Invalid {context} entry")
    require(len(set(value)) == len(value), f"Duplicate {context} entry")


def registry_image(value):
    if not matches(value, REGISTRY_IMAGE):
        return False
    name = value.split("@", 1)[0].rsplit("/", 1)[1]
    return ":" not in name or name.rsplit(":", 1)[1].lower() not in {"latest", "main", "next"}


def validate_manifest(manifest):
    keys(manifest, {"schemaVersion", "releaseId", "createdAt", "target", "compose", "sources", "services"}, "manifest")
    require(type(manifest["schemaVersion"]) is int and manifest["schemaVersion"] == 1, "Unsupported schema version")
    require(matches(manifest["releaseId"], r"[a-z0-9][a-z0-9-]{0,63}"), "Invalid release identifier")
    require(matches(manifest["createdAt"], r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"), "Invalid creation time")
    try:
        datetime.strptime(manifest["createdAt"], "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        raise ManifestError("Invalid creation time") from None

    target = manifest["target"]
    keys(target, {"environment", "nodeId"}, "target")
    require(target["environment"] in ("development", "qlty", "staging", "production"), "Invalid target environment")
    try:
        node = UUID(target["nodeId"])
        require(str(node) == target["nodeId"] and node.int != 0, "Invalid node identity")
    except (ValueError, TypeError, AttributeError):
        raise ManifestError("Invalid node identity") from None

    compose = manifest["compose"]
    keys(compose, {"project", "files", "profiles", "platform"}, "Compose selection")
    require(matches(compose["project"], NAME), "Invalid Compose project")
    unique_strings(compose["files"], r"docker-compose\.yml|compose/[a-z0-9][a-z0-9-]*\.yml", "Compose files")
    require(compose["files"][0] == "docker-compose.yml", "The canonical Compose entry point must be first")
    require("compose/seed.yml" not in compose["files"], "Seed is not a release service")
    unique_strings(compose["profiles"], NAME, "profiles", allow_empty=True)
    require("seed" not in compose["profiles"], "Seed is not a release profile")
    require(compose["platform"] in ("linux/amd64", "linux/arm64"), "Unsupported runtime platform")

    sources = manifest["sources"]
    keys(sources, {"distroCommit", "contentVersion", "backend", "frontend"}, "sources")
    require(matches(sources["distroCommit"], SHA), "Invalid distribution commit")
    require(matches(sources["contentVersion"], r"[0-9]+\.[0-9]+\.[0-9]+"), "Invalid released content version")
    for service, repository in (("backend", BACKEND_REPOSITORY), ("frontend", FRONTEND_REPOSITORY)):
        source = sources[service]
        keys(source, {"commit", "image"}, "source image")
        require(matches(source["commit"], SHA), "Invalid source commit")
        require(registry_image(source["image"]), "Source images must use immutable registry digests")
        require(
            source["image"].startswith(f"{repository}:sha-{source['commit']}@"),
            "Source image tag and source commit must agree",
        )

    services = manifest["services"]
    require(isinstance(services, dict) and CORE_SERVICES <= set(services), "Missing core service image")
    require(len(services) <= 100, "Too many service images")
    for service, artifact in services.items():
        require(matches(service, NAME) and service != "seed", "Invalid release service")
        keys(artifact, {"image", "imageId"}, "service image")
        require(matches(artifact["imageId"], DIGEST), "Invalid runtime image ID")
        require(
            registry_image(artifact["image"]) or artifact["image"] == artifact["imageId"],
            "Every service must use a registry digest or its exact local image ID",
        )
    require(services["backend"]["image"] == sources["backend"]["image"], "Backend source and runtime references differ")
    return manifest


def read_json(path):
    def no_duplicate_keys(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "Duplicate JSON key")
            result[key] = value
        return result

    try:
        require(path.stat().st_size <= 128 * 1024, "Manifest file is too large")
        return json.loads(path.read_text(), object_pairs_hook=no_duplicate_keys)
    except (OSError, UnicodeError, json.JSONDecodeError):
        raise ManifestError("Cannot read manifest JSON") from None


def canonical_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=True) + "\n").encode()


def write_new(path, value):
    """Never replace an existing manifest, even with a different release ID."""
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(canonical_bytes(value))
        output.flush()
        os.fsync(output.fileno())


def compose_override(manifest):
    validate_manifest(manifest)
    return {
        "services": {
            service: {"image": artifact["image"], "pull_policy": "never"}
            for service, artifact in sorted(manifest["services"].items())
        }
    }


def validate_effective_compose(manifest, model, active_services):
    require(set(active_services) == set(manifest["services"]), "Manifest does not cover exactly the enabled services")
    require(model.get("name") == manifest["compose"]["project"], "Compose project differs from manifest")
    for service, artifact in manifest["services"].items():
        configured = model.get("services", {}).get(service, {})
        require(configured.get("image") == artifact["image"], "Effective service image differs from manifest")
        require(configured.get("pull_policy") == "never", "Effective pull policy must not resolve mutable tags")
        require(set(configured.get("depends_on", {})) <= set(active_services), "Dependency is absent from the manifest")


def run(command, *, root, environment=None, binary=False):
    """Capture operational output: Compose configuration can contain secrets."""
    try:
        result = subprocess.run(command, cwd=root, env=environment, capture_output=True,
                                text=not binary, check=False, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        raise ManifestError("Required operational command is unavailable") from None
    require(result.returncode == 0, "Operational command failed; no raw configuration or error output is displayed")
    return result.stdout


def compose_command(manifest, env_file, override=None):
    command = ["docker", "compose", "--env-file", str(env_file), "--project-name", manifest["compose"]["project"]]
    for path in manifest["compose"]["files"]:
        command.extend(("--file", path))
    if override is not None:
        command.extend(("--file", str(override)))
    for profile in manifest["compose"]["profiles"]:
        command.extend(("--profile", profile))
    return command


def compose_environment(manifest):
    environment = dict(os.environ)
    # An environment file or inherited shell cannot silently enable another profile.
    environment["COMPOSE_PROFILES"] = ",".join(manifest["compose"]["profiles"])
    environment["COMPOSE_FILE"] = ":".join(manifest["compose"]["files"])
    environment["COMPOSE_PROJECT_NAME"] = manifest["compose"]["project"]
    environment["COMPOSE_PATH_SEPARATOR"] = ":"
    environment["DOCKER_DEFAULT_PLATFORM"] = manifest["compose"]["platform"]
    environment["SIHSALUS_NODE_ID"] = manifest["target"]["nodeId"]
    return environment


def verify_checkout(manifest, root):
    current = run(["git", "rev-parse", "HEAD"], root=root).strip()
    require(current == manifest["sources"]["distroCommit"], "Checkout does not match the manifest distribution commit")
    require(not run(["git", "status", "--porcelain=v1", "--untracked-files=no"], root=root).strip(), "Checkout contains tracked changes")
    for name in manifest["compose"]["files"]:
        path = root / name
        require(path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(root.resolve()), "Unsafe Compose file")
        run(["git", "ls-files", "--error-unmatch", "--", name], root=root)


def verify_compose(manifest, root, env_file):
    require(env_file.is_file(), "Environment file is missing")
    environment = compose_environment(manifest)
    with tempfile.TemporaryDirectory(prefix="sihsalus-release-") as directory:
        override = Path(directory) / "images.json"
        write_new(override, compose_override(manifest))
        command = compose_command(manifest, env_file, override)
        active = run(command + ["config", "--services"], root=root, environment=environment).splitlines()
        try:
            model = json.loads(run(command + ["config", "--format", "json"], root=root, environment=environment))
        except json.JSONDecodeError:
            raise ManifestError("Invalid rendered Compose model") from None
        validate_effective_compose(manifest, model, active)


def verify_selected_compose(manifest, root, env_file, manifest_path):
    """Audit the selection actually used by ordinary Docker Compose commands."""
    verify_checkout(manifest, root)
    verify_environment(manifest, env_file)
    command = ["docker", "compose", "--env-file", str(env_file)]
    rendered_environment = run(command + ["config", "--environment"], root=root)
    selected = dict(line.split("=", 1) for line in rendered_environment.splitlines() if "=" in line)
    override = manifest_path.parent / f"{manifest_digest(manifest)}.compose.json"
    expected_files = [str(root / name) for name in manifest["compose"]["files"]] + [str(override)]
    require(selected.get("COMPOSE_FILE") == ":".join(expected_files), "Effective Compose files differ from the retained release")
    require(selected.get("COMPOSE_PROFILES", "") == ",".join(manifest["compose"]["profiles"]), "Effective profiles differ from the release")
    require(selected.get("SIHSALUS_RELEASE_MANIFEST") == str(manifest_path), "Effective release selection differs")
    require(selected.get("SIHSALUS_NODE_ID") == manifest["target"]["nodeId"], "Effective node identity differs")
    require(selected.get("DOCKER_DEFAULT_PLATFORM") == manifest["compose"]["platform"], "Effective platform differs")
    require(not override.is_symlink() and read_json(override) == compose_override(manifest), "Retained image override differs")
    active = run(command + ["config", "--services"], root=root).splitlines()
    model = json.loads(run(command + ["config", "--format", "json"], root=root))
    validate_effective_compose(manifest, model, active)


def inspect_image(reference, root):
    # Never retrieve Config.Env: an image can contain baked-in credentials.
    template = ('{"id":{{json .Id}},"os":{{json .Os}},"arch":{{json .Architecture}},'
                '"digests":{{json .RepoDigests}},"revision":'
                '{{json (index .Config.Labels "org.opencontainers.image.revision")}},'
                '"node":{{json (index .Config.Labels "org.sihsalus.node-id")}}}')
    return json.loads(run(["docker", "image", "inspect", reference, "--format", template], root=root))


def container_file(container, path, root):
    archive = run(["docker", "cp", f"{container}:{path}", "-"], root=root, binary=True)
    try:
        with tarfile.open(fileobj=io.BytesIO(archive)) as stream:
            members = stream.getmembers()
            require(len(members) == 1 and members[0].isfile() and members[0].size <= 128 * 1024,
                    "Invalid packaged metadata file")
            return stream.extractfile(members[0]).read().decode("utf-8")
    except (tarfile.TarError, UnicodeError):
        raise ManifestError("Cannot read packaged metadata") from None


def image_file(image, path, root):
    # This container is never started or connected to a network or host volume.
    container = run(["docker", "create", "--network", "none", "--entrypoint", "/bin/false", image], root=root).strip()
    require(matches(container, r"[0-9a-f]{64}"), "Invalid inspection container")
    try:
        return container_file(container, path, root)
    finally:
        run(["docker", "rm", "--volumes", container], root=root)


def verify_images(manifest, root):
    for artifact in manifest["services"].values():
        inspected = inspect_image(artifact["image"], root)
        require(inspected["id"] == artifact["imageId"], "Preloaded image ID differs from manifest")
        require(f"{inspected['os']}/{inspected['arch']}" == manifest["compose"]["platform"],
                "Preloaded image platform differs from manifest")
    for name in ("backend", "frontend"):
        source = manifest["sources"][name]
        inspected = inspect_image(source["image"], root)
        require(inspected["revision"] == source["commit"], "Source image revision differs from manifest")
    frontend = manifest["services"]["frontend"]["imageId"]
    require(inspect_image(frontend, root)["node"] == manifest["target"]["nodeId"],
            "Frontend wrapper belongs to a different node")
    info = json.loads(image_file(frontend, "/usr/share/nginx/html/build-info.json", root))
    require(info.get("gitSha") == manifest["sources"]["frontend"]["commit"],
            "Packaged frontend revision differs from manifest")
    properties = image_file(manifest["services"]["backend"]["imageId"],
                            "/openmrs/distribution/openmrs-distro.properties", root)
    versions = re.findall(r"^content\.sihsalus-content\s*=\s*([^\s]+)\s*$", properties, re.MULTILINE)
    require(versions == [manifest["sources"]["contentVersion"]],
            "Packaged content version differs from manifest")


def runtime_inventory(manifest, root, allow_missing=False):
    identifiers = run(["docker", "ps", "--all", "--quiet", "--no-trunc", "--filter",
                       f"label=com.docker.compose.project={manifest['compose']['project']}"], root=root).splitlines()
    inventory = {}
    template = ('{"service":{{json (index .Config.Labels "com.docker.compose.service")}},'
                '"oneoff":{{json (index .Config.Labels "com.docker.compose.oneoff")}},'
                '"imageId":{{json .Image}},"node":{{json (index .Config.Labels "org.sihsalus.node-id")}}}')
    for identifier in identifiers:
        require(matches(identifier, r"[0-9a-f]{64}"), "Invalid runtime container ID")
        item = json.loads(run(["docker", "inspect", identifier, "--format", template], root=root))
        require(str(item["oneoff"]).lower() != "true", "A one-off Compose operation is still present")
        service = item["service"]
        require(matches(service, NAME) and service not in inventory, "Unexpected or scaled runtime service")
        inventory[service] = item
    complete = set(inventory) == set(manifest["services"])
    recoverable = allow_missing and set(inventory) <= set(manifest["services"])
    require(complete or recoverable,
            "Runtime services differ; handle installation, profile migration or orphan recovery separately")
    if "frontend" in inventory:
        require(inventory["frontend"]["node"] == manifest["target"]["nodeId"], "Runtime node identity differs")
    else:
        # A failed recreation may already have removed the previous frontend.
        # Recovery then requires the private selection written on this host.
        values = dict(line.split("=", 1) for line in (root / ".env").read_text().splitlines() if "=" in line)
        require(values.get("SIHSALUS_NODE_ID") == manifest["target"]["nodeId"], "Retained node identity differs")
        selected = Path(values.get("SIHSALUS_RELEASE_MANIFEST", ""))
        require(selected.parent == root / ".env.release-state" and not selected.is_symlink(), "Recovery requires a retained local release")
        retained = validate_manifest(read_json(selected))
        verify_transition(manifest, retained)
        require(selected.name == manifest_digest(retained) + ".json", "Retained release checksum differs")
    return inventory


def verify_runtime(manifest, root):
    inventory = runtime_inventory(manifest, root)
    require(all(item["imageId"] == manifest["services"][name]["imageId"] for name, item in inventory.items()),
            "Runtime image IDs differ from manifest")


def immutable_reference(inspected):
    for reference in sorted(inspected["digests"] or []):
        repository = reference.split("@", 1)[0]
        if "/" not in repository:
            reference = "docker.io/library/" + reference
        elif not any(character in repository.split("/", 1)[0] for character in ".:"):
            reference = "docker.io/" + reference
        if registry_image(reference):
            return reference
    return inspected["id"]


def capture(metadata, root, env_file):
    keys(metadata, {"schemaVersion", "releaseId", "createdAt", "target", "compose", "sources"}, "capture metadata")
    # Validate metadata before invoking any operational command, with temporary
    # schema-valid placeholders that never reach the output artifact.
    manifest = dict(metadata, services={name: {"image": "sha256:" + "0" * 64,
                                              "imageId": "sha256:" + "0" * 64} for name in CORE_SERVICES})
    require(isinstance(metadata["sources"], dict) and isinstance(metadata["sources"].get("backend"), dict),
            "Invalid source metadata")
    manifest["services"]["backend"]["image"] = metadata["sources"]["backend"].get("image")
    validate_manifest(manifest)
    verify_checkout(manifest, root)
    verify_environment(manifest, env_file)
    command = compose_command(manifest, env_file)
    active = run(command + ["config", "--services"], root=root, environment=compose_environment(manifest)).splitlines()
    require(CORE_SERVICES <= set(active) and "seed" not in active, "Invalid active services")
    manifest["services"] = dict.fromkeys(active)
    for service, item in runtime_inventory(manifest, root).items():
        inspected = inspect_image(item["imageId"], root)
        reference = metadata["sources"]["backend"]["image"] if service == "backend" else immutable_reference(inspected)
        manifest["services"][service] = {"image": reference, "imageId": inspected["id"]}
    validate_manifest(manifest)
    verify_compose(manifest, root, env_file)
    verify_images(manifest, root)
    verify_runtime(manifest, root)
    return manifest


def manifest_digest(manifest):
    return hashlib.sha256(canonical_bytes(manifest)).hexdigest()


def persist_immutable(path, value):
    if path.exists():
        require(path.is_file() and not path.is_symlink() and path.read_bytes() == canonical_bytes(value),
                "Retained artifact cannot be replaced")
    else:
        write_new(path, value)


def replace_private(path, data):
    descriptor, temporary = tempfile.mkstemp(prefix=".env.release-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def select_manifest(env_text, values):
    lines = env_text.splitlines()
    for key, value in values.items():
        require(matches(value, r"[A-Za-z0-9_./,:@=+-]*"), "Unsafe environment selection; use paths without spaces or shell syntax")
        # dotenv allows export and whitespace; eliminate every existing spelling.
        expression = rf"^\s*(?:export\s+)?{re.escape(key)}\s*="
        lines = [line for line in lines if not re.match(expression, line)]
        # Keep managed values unquoted for the existing operational env readers.
        lines.append(f"{key}={value}")
    return "\n".join(lines) + "\n"


def verify_transition(manifest, previous):
    require(manifest["target"] == previous["target"], "Previous release belongs to another target")
    require(manifest["compose"] == previous["compose"] and set(manifest["services"]) == set(previous["services"]),
            "Profile, platform or project migration requires a separate reviewed procedure")


def verify_environment(manifest, env_file):
    values = re.findall(r"^\s*(?:export\s+)?DEPLOYMENT_ENV\s*=\s*([^\r\n]*)", env_file.read_text(), re.MULTILINE)
    require(len(values) == 1, "Exactly one DEPLOYMENT_ENV must identify the local environment")
    value = values[0].strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    require(value == manifest["target"]["environment"], "Local environment differs from the manifest target")


@contextmanager
def release_lock(root):
    directory = root / ".env.release-state"
    require(not directory.is_symlink(), "Release state must not be a symbolic link")
    directory.mkdir(mode=0o700, exist_ok=True)
    require(directory.stat().st_mode & 0o077 == 0, "Release state must be private")
    lock = directory / "lock"
    require(not lock.is_symlink(), "Release lock must not be a symbolic link")
    with open(lock, "a", encoding="utf-8") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ManifestError("Another manifest operation is active") from None
        yield directory


def apply_release(manifest, previous, root, rollback=False):
    """Deploy and rollback share the same pinned execution and verification path."""
    validate_manifest(manifest)
    validate_manifest(previous)
    verify_transition(manifest, previous)
    verify_checkout(manifest, root)
    env_file = root / ".env"
    require(env_file.is_file() and not env_file.is_symlink(), "A regular local .env is required")
    # Never consume deployment secrets from Git.
    require(not run(["git", "ls-files", "--", ".env"], root=root).strip(), "Environment file must not be tracked")
    verify_environment(manifest, env_file)
    run(["git", "check-ignore", "--quiet", ".env.release-state/"], root=root)
    with release_lock(root) as state:
        verify_compose(manifest, root, env_file)
        runtime_inventory(manifest, root, allow_missing=rollback)
        if not rollback:
            verify_runtime(previous, root)
        if not rollback:
            verify_images(previous, root)
        verify_images(manifest, root)
        # Keep references outside the frontend runtime repository. Its historical
        # tag cleanup must never make a retained release disappear.
        for release in (previous, manifest):
            digest = manifest_digest(release)
            persist_immutable(state / f"{digest}.json", release)
            persist_immutable(state / f"{digest}.compose.json", compose_override(release))
            artifacts = {name: artifact["imageId"] for name, artifact in release["services"].items()}
            artifacts["source-frontend"] = release["sources"]["frontend"]["image"]
            for name, reference in artifacts.items():
                try:
                    run(["docker", "image", "tag", reference, f"sihsalus-release-retained:{digest[:48]}-{name}"], root=root)
                except ManifestError:
                    # Missing images from a broken candidate must not prevent
                    # recovery to a complete, verified earlier release.
                    if not rollback or release is manifest:
                        raise
                    print("[release-manifest] An attempted-release image is unavailable; the rollback target remains fully verified", file=sys.stderr)

        attempt = state / str(uuid4())
        attempt.mkdir(mode=0o700)
        before = env_file.read_bytes()
        with open(attempt / "before.env", "xb") as output:
            os.chmod(output.name, 0o600)
            output.write(before)
        write_new(attempt / "previous.json", previous)
        write_new(attempt / "target.json", manifest)
        status = {"operation": "rollback" if rollback else "deploy", "target": manifest_digest(manifest),
                  "previous": manifest_digest(previous), "status": "applying"}
        write_new(attempt / "result.json", status)
        override = state / f"{manifest_digest(manifest)}.compose.json"
        files = [str(root / name) for name in manifest["compose"]["files"]] + [str(override)]
        require(all(":" not in path for path in files), "Compose paths cannot contain a separator")
        environment = compose_environment(manifest)
        selection = {"COMPOSE_FILE": ":".join(files), "COMPOSE_PROFILES": ",".join(manifest["compose"]["profiles"]),
                     "COMPOSE_PROJECT_NAME": manifest["compose"]["project"], "COMPOSE_PATH_SEPARATOR": ":",
                     "DOCKER_DEFAULT_PLATFORM": manifest["compose"]["platform"],
                     "SIHSALUS_NODE_ID": manifest["target"]["nodeId"],
                     "SIHSALUS_RELEASE_MANIFEST": str(state / f"{manifest_digest(manifest)}.json"),
                     "BACKEND_TAG": manifest["sources"]["backend"]["image"].split(":sha-", 1)[1]}
        selection["BACKEND_TAG"] = "sha-" + selection["BACKEND_TAG"]
        try:
            # Persist the attempted selection before recreation. On any failure
            # leave it and the journal in place: silently restoring only .env
            # would misrepresent a partially changed runtime.
            replace_private(env_file, select_manifest(before.decode("utf-8"), selection).encode())
            environment.update(selection)
            environment.update(REDEPLOY_OFFLINE="true", SIHSALUS_MANIFEST_APPLY="true",
                               COMPOSE_ENV_FILES=str(env_file), COMPOSE_DISABLE_ENV_FILE="false")
            source = manifest["sources"]["backend"]
            command = ["bash", str(Path(__file__).with_name("redeploy-environment.sh")), source["commit"],
                       source["image"].split("@", 1)[1]]
            # Reuse existing authenticated FUA preflight and all health checks.
            # Stream its bounded progress instead of collecting secret-bearing config.
            result = subprocess.run(command, cwd=root, env=environment, check=False)
            require(result.returncode == 0, "Redeploy failed; use the retained previous manifest for recovery")
            verify_runtime(manifest, root)
            verify_selected_compose(manifest, root, env_file, state / f"{manifest_digest(manifest)}.json")
            status["status"] = "verified"
        except BaseException:
            status["status"] = "failed-or-interrupted"
            raise
        finally:
            replace_private(attempt / "result.json", canonical_bytes(status))
        print(f"Verified {status['operation']}: {manifest['releaseId']}; journal {attempt.name}")


def validate_catalog(root, base, output=None):
    """Published manifests are append-only; Git retains them beyond artifact expiry."""
    directory = root / "releases"
    require(not directory.is_symlink() and (not directory.exists() or directory.is_dir()),
            "Release catalog must be a directory")
    if base:
        require(matches(base, SHA), "Invalid catalog baseline commit")
        names = run(["git", "ls-tree", "-r", "--name-only", base, "--", "releases"], root=root).splitlines()
        for name in names:
            if name.endswith(".json"):
                path = root / name
                require(path.is_file() and not path.is_symlink(), "Published manifests cannot be deleted")
                original = run(["git", "show", f"{base}:{name}"], root=root, binary=True)
                require(path.read_bytes() == original, "Published manifests cannot be changed or renamed")
    results = []
    for path in sorted(directory.rglob("*.json")):
        require(not path.is_symlink() and path.resolve().is_relative_to(directory.resolve()), "Unsafe catalog path")
        manifest = validate_manifest(read_json(path))
        target = manifest["target"]
        expected = directory / target["environment"] / target["nodeId"] / (manifest["releaseId"] + ".json")
        require(path == expected, "Manifest path must match its environment, node and release identifier")
        results.append({"path": str(path.relative_to(root)), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    if output:
        write_new(output, {"manifests": results})
    print(f"Validated append-only release catalog: {len(results)} manifests")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    validate = subcommands.add_parser("validate", help="Validate a manifest without accessing Docker")
    validate.add_argument("manifest", type=Path)
    render = subcommands.add_parser("render", help="Write a new image-only Compose override")
    render.add_argument("manifest", type=Path)
    render.add_argument("--output", required=True, type=Path)
    check = subcommands.add_parser("check-compose", help="Verify the effective service selection without a daemon")
    check.add_argument("manifest", type=Path)
    check.add_argument("--root", type=Path, default=Path.cwd())
    check.add_argument("--env-file", type=Path, required=True)
    selected = subcommands.add_parser("check-selected", help="Audit the persistent selection used by ordinary Compose commands")
    selected.add_argument("manifest", type=Path)
    selected.add_argument("--root", type=Path, default=Path.cwd())
    selected.add_argument("--env-file", type=Path, required=True)
    capture_command = subcommands.add_parser("capture", help="Capture prepared runtime images; never pull, build or start services")
    capture_command.add_argument("metadata", type=Path)
    capture_command.add_argument("--root", type=Path, default=Path.cwd())
    capture_command.add_argument("--env-file", type=Path, required=True)
    capture_command.add_argument("--output", type=Path, required=True)
    for name in ("deploy", "rollback"):
        apply = subcommands.add_parser(name, help="Apply all pinned services using the existing offline redeploy checks")
        apply.add_argument("manifest", type=Path)
        apply.add_argument("--previous", type=Path, required=True, help="Retained previous/current release for recovery")
        apply.add_argument("--root", type=Path, default=Path.cwd())
    catalog = subcommands.add_parser("catalog", help="Check immutable release history and emit a checksum index")
    catalog.add_argument("--root", type=Path, default=Path.cwd())
    catalog.add_argument("--base", help="Previous main or pull-request base commit")
    catalog.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.command == "catalog":
        validate_catalog(args.root.resolve(), args.base, args.output)
        return
    if args.command == "capture":
        manifest = capture(read_json(args.metadata), args.root.resolve(), args.env_file.resolve())
        write_new(args.output, manifest)
    else:
        manifest = validate_manifest(read_json(args.manifest))
    if args.command == "render":
        write_new(args.output, compose_override(manifest))
    if args.command == "check-compose":
        verify_checkout(manifest, args.root.resolve())
        verify_compose(manifest, args.root.resolve(), args.env_file.resolve())
    if args.command == "check-selected":
        verify_selected_compose(manifest, args.root.resolve(), args.env_file.resolve(), args.manifest.resolve())
    if args.command in ("deploy", "rollback"):
        previous = validate_manifest(read_json(args.previous))
        apply_release(manifest, previous, args.root.resolve(), rollback=args.command == "rollback")
    digest = manifest_digest(manifest)
    print(f"Validated release {manifest['releaseId']}: {len(manifest['services'])} services; sha256:{digest}")


if __name__ == "__main__":
    def interrupted(_number, _frame):
        raise ManifestError("Operation interrupted; inspect the retained journal before recovery")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    try:
        main()
    except (ManifestError, OSError, ValueError, KeyError, TypeError, KeyboardInterrupt) as error:
        if isinstance(error, ManifestError):
            message = str(error)
        elif isinstance(error, FileExistsError):
            message = "Output already exists; previous releases cannot be overwritten"
        else:
            message = "Invalid operational metadata or unavailable local resource; no raw values are displayed"
        print(f"[release-manifest] {message}", file=sys.stderr)
        sys.exit(1)
