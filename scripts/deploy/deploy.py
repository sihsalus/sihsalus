#!/usr/bin/env python3
"""Update SIHSalus components and recover the previous frontend version."""

import argparse
from contextlib import nullcontext
from copy import deepcopy
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys


DIRECTORY = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("releases", DIRECTORY / "release-manifest.py")
releases = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(releases)


def env_value(root, key):
    return releases.run(["bash", "-c", 'source "$1"; read_env_value "$2" "$3"',
                         "env-reader", str(DIRECTORY / "env.sh"), key, str(root / ".env")], root=root).strip()


def source_image(service, reference, root):
    image = releases.inspect_image(reference, root)
    repository = f"ghcr.io/sihsalus/sihsalus-{service}"
    revision = image["revision"]
    releases.require(releases.matches(revision, releases.SHA), "Image has no valid source revision")
    references = [item for item in image["digests"] or [] if item.startswith(repository + "@")]
    releases.require(len(references) == 1, "Cannot identify the immutable source image")
    return {"commit": revision, "image": f"{repository}:sha-{revision}@{references[0].split('@')[1]}"}


def current_release(root):
    selected = env_value(root, "SIHSALUS_RELEASE_MANIFEST")
    if selected:
        path = Path(selected)
        releases.require(path.parent == root / ".env.release-state" and not path.is_symlink(),
                         "Installed version must be stored privately on this host")
        current = releases.validate_manifest(releases.read_json(path))
        releases.require(path.name == releases.manifest_digest(current) + ".json", "Installed version checksum differs")
        releases.verify_selected_compose(current, root, root / ".env", path, compatible_checkout=True)
        return current

    # Adopt an existing Compose installation directly; operators never author metadata.
    model = json.loads(releases.run(["docker", "compose", "config", "--format", "json"], root=root))
    backend_id = releases.run(["docker", "inspect", "sihsalus-backend", "--format", "{{.Image}}"], root=root).strip()
    backend = source_image("backend", backend_id, root)
    frontend = source_image("frontend", model["services"]["frontend"]["build"]["args"]["FRONTEND_SOURCE_IMAGE"], root)
    properties = releases.image_file(backend_id, "/openmrs/distribution/openmrs-distro.properties", root)
    version = re.findall(r"^content\.sihsalus-content\s*=\s*(\S+)\s*$", properties, re.MULTILINE)
    releases.require(len(version) == 1, "Cannot identify installed content version")
    files = env_value(root, "COMPOSE_FILE") or "docker-compose.yml"
    files = [str((root / name).resolve().relative_to(root)) for name in files.split(":")]
    metadata = {
        "schemaVersion": 1, "releaseId": "installed-" + datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S"),
        "createdAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "target": {"environment": env_value(root, "DEPLOYMENT_ENV"), "nodeId": env_value(root, "SIHSALUS_NODE_ID")},
        "compose": {"project": model["name"], "files": files,
                    "profiles": [x for x in env_value(root, "COMPOSE_PROFILES").split(",") if x],
                    "platform": model["services"]["backend"].get("platform", "linux/amd64")},
        "sources": {"distroCommit": releases.run(["git", "rev-parse", "HEAD"], root=root).strip(),
                    "contentVersion": version[0], "backend": backend, "frontend": frontend},
    }
    return releases.capture(metadata, root, root / ".env")


def resolve(service, version, expected_digest, root, platform):
    releases.require(version == "latest" or releases.matches(version, releases.SHA),
                     "Choose latest or a complete published commit SHA")
    releases.require(not expected_digest or releases.matches(expected_digest, releases.DIGEST), "Invalid image digest")
    repository = f"ghcr.io/sihsalus/sihsalus-{service}"
    tag = "latest" if version == "latest" else "sha-" + version
    reference = f"{repository}:{tag}"
    # Resolve the published alias once, then pull and build only by immutable digest.
    digest = releases.run(["docker", "buildx", "imagetools", "inspect", reference,
                           "--format", "{{.Manifest.Digest}}"], root=root, timeout=120).strip()
    releases.require(releases.matches(digest, releases.DIGEST), "Published image has no valid digest")
    releases.require(not expected_digest or digest == expected_digest, "Published version differs from selected digest")
    pinned = reference + "@" + digest
    try:
        releases.inspect_image(pinned, root)
    except releases.ManifestError:
        releases.require(shutil.disk_usage(root).free >= 2 * 1024 ** 3, "At least 2 GiB free is required to download an update")
        releases.run(["docker", "pull", "--platform", platform, pinned], root=root, timeout=600)
    result = source_image(service, pinned, root)
    releases.require(version == "latest" or result["commit"] == version, "Image revision differs from selected version")
    releases.require(result["image"].endswith("@" + digest), "Pulled image differs from resolved release")
    return result


def candidate_release(current, root):
    candidate = deepcopy(current)
    candidate["createdAt"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    candidate["releaseId"] = "update-" + datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S%f")
    candidate["sources"]["distroCommit"] = releases.run(["git", "rev-parse", "HEAD"], root=root).strip()
    return candidate


def build_frontend(candidate, root):
    source = candidate["sources"]["frontend"]
    runtime = "sihsalus-frontend-runtime:prepared-" + candidate["releaseId"]
    environment = releases.compose_environment(candidate)
    environment.update(FRONTEND_SOURCE_IMAGE=source["image"], FRONTEND_RUNTIME_IMAGE="sihsalus-frontend-runtime",
                       FRONTEND_RUNTIME_TAG="prepared-" + candidate["releaseId"])
    print("Preparando frontend para este servidor…", flush=True)
    releases.run(releases.compose_command(candidate, root / ".env") + ["build", "frontend"],
                 root=root, environment=environment, timeout=1200)
    image = releases.inspect_image(runtime, root)
    candidate["services"]["frontend"] = {"image": image["id"], "imageId": image["id"]}


def show(current):
    print(f"Ambiente: {current['target']['environment']}")
    for component in ("frontend", "backend"):
        print(f"{component}: {current['sources'][component]['commit'][:12]}")
    print(f"content: {current['sources']['contentVersion']}")


def history(root):
    return sorted((root / ".env.release-state").glob("*/result.json"), key=lambda path: path.stat().st_mtime, reverse=True)


def previous_release(current, root):
    attempts = [(path, releases.read_json(path)) for path in history(root)]
    for path, result in attempts:
        if result["target"] == releases.manifest_digest(current):
            if result["operation"] == "rollback" and any(
                other["target"] == result["previous"] and other["status"] != "verified"
                for _, other in attempts
            ):
                raise releases.ManifestError("The failed update was already recovered; select a published version explicitly")
            return releases.validate_manifest(releases.read_json(path.parent / "previous.json"))
    raise releases.ManifestError("No previous version is retained for this installation")


def health(current, root, components):
    for name in components:
        value = releases.run(["docker", "inspect", f"sihsalus-{name}", "--format",
                              "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}"], root=root).strip()
        releases.require(value == "healthy", f"Current {name} is not healthy; inspect it before updating")


def verify_external(candidate, root, public_url):
    if public_url:
        result = subprocess.run(["bash", str(DIRECTORY / "verify-external-frontend.sh"), public_url,
                                 candidate["sources"]["frontend"]["commit"], candidate["target"]["nodeId"],
                                 candidate["target"]["environment"]], cwd=root, check=False, timeout=600)
        releases.require(result.returncode == 0, "External verification failed")


def apply(candidate, current, root, state, components, public_url):
    try:
        releases.apply_release(candidate, current, root, services=components, state=state,
                               verify=lambda: verify_external(candidate, root, public_url))
    except BaseException:
        attempted = env_value(root, "SIHSALUS_RELEASE_MANIFEST") == str(state / (releases.manifest_digest(candidate) + ".json"))
        if components == ["frontend"] and attempted:
            print("La actualización falló; recuperando el frontend anterior…", file=sys.stderr, flush=True)
            recovery = candidate_release(current, root)
            releases.apply_release(recovery, candidate, root, rollback=True, services=components, state=state,
                                   verify=lambda: verify_external(recovery, root, public_url))
            print("Frontend anterior recuperado.", file=sys.stderr)
        elif attempted:
            print("Actualización detenida. Revisar migraciones y respaldo antes de revertir el backend.", file=sys.stderr)
        raise


def checked_root(root):
    root = Path(root).resolve()
    releases.require((root / ".env").is_file(), "Run from the installed SIHSalus checkout")
    # Retain the same drift/override guard for both command-line interfaces.
    releases.run(["bash", str(DIRECTORY / "check-clean-checkout.sh"), "deploy"], root=root,
                 environment={**os.environ, "SIHSALUS_MANIFEST_APPLY": "true"})
    return root


def execute_update(root, component, version="latest", expected_digest=None, public_url=None,
                   prepare_only=False, validate_candidate=None, confirm=None,
                   before_apply=None, event=None):
    """Prepare and optionally apply one component under a single release lock.

    Each operation callback receives (current, candidate, component). Validators
    and before_apply raise on failure (False also rejects the operation); confirm
    returns a bool. before_apply may return a context manager that stays open
    during application and verification, including failures. Callbacks may
    inspect, but must not change, the manifests.
    event receives (stage, message), containing no environment values or secrets.
    The result contains status, current, candidate and component; status is one of
    unchanged, prepared, cancelled or updated. Security/backup checks are supplied
    by the caller, rather than implied by successful identity validation.
    """
    releases.require(component in ("frontend", "backend"), "Choose frontend or backend")

    def notify(stage, message):
        if event is not None:
            event(stage, message)

    notify("checking", "Comprobando la instalación y su estado actual…")
    root = checked_root(root)
    with releases.release_lock(root) as state:
        current = current_release(root)
        public_url = public_url or env_value(root, "SIHSALUS_PUBLIC_URL")
        releases.require(not public_url or re.fullmatch(r"https?://[A-Za-z0-9.:-]+", public_url), "Invalid public URL")
        releases.verify_runtime(current, root)
        health(current, root, [component])
        releases.verify_images(current, root)
        notify("resolving", "Resolviendo y descargando la versión publicada…")
        selected = resolve(component, version, expected_digest, root, current["compose"]["platform"])
        unchanged = selected == current["sources"][component]
        if unchanged:
            candidate = deepcopy(current)
        else:
            releases.require(shutil.disk_usage(root).free >= 2 * 1024 ** 3, "At least 2 GiB free is required to prepare an update")
            notify("preparing", "Preparando la imagen para esta instalación…")
            candidate = candidate_release(current, root)
            candidate["sources"][component] = deepcopy(selected)
            if component == "frontend":
                build_frontend(candidate, root)
            else:
                image = releases.inspect_image(selected["image"], root)
                candidate["services"]["backend"] = {"image": selected["image"], "imageId": image["id"]}
                properties = releases.image_file(image["id"], "/openmrs/distribution/openmrs-distro.properties", root)
                versions = re.findall(r"^content\.sihsalus-content\s*=\s*(\S+)\s*$", properties, re.MULTILINE)
                releases.require(len(versions) == 1, "Candidate has no released content version")
                candidate["sources"]["contentVersion"] = versions[0]
            releases.validate_manifest(candidate)
            releases.verify_compose(candidate, root, root / ".env")
            releases.verify_images(candidate, root)

        current_digest = releases.manifest_digest(current)
        candidate_digest = releases.manifest_digest(candidate)

        def verify_selection():
            releases.require(releases.manifest_digest(current) == current_digest and
                             releases.manifest_digest(candidate) == candidate_digest,
                             "Update callback changed the selected release")

        def invoke(callback):
            verify_selection()
            result = callback(current, candidate, component)
            verify_selection()
            return result

        def result(status):
            verify_selection()
            return {"status": status, "current": current, "candidate": candidate, "component": component}

        notify("validating", "Comprobando el candidato seleccionado…")
        if validate_candidate is not None:
            releases.require(invoke(validate_candidate) is not False, "Candidate validation rejected the update")
        if unchanged:
            notify("complete", "La versión instalada coincide con la seleccionada.")
            return result("unchanged")
        if prepare_only:
            notify("complete", "Preparación correcta; los servicios siguen sin cambios.")
            return result("prepared")
        if confirm is not None:
            notify("confirming", "Esperando la confirmación del cambio preparado…")
            approved = invoke(confirm)
            releases.require(type(approved) is bool, "Update confirmation must return a bool")
            if not approved:
                notify("complete", "Actualización cancelada; los servicios siguen sin cambios.")
                return result("cancelled")
        preparation = None
        if before_apply is not None:
            notify("backing-up", "Ejecutando la preparación previa a la aplicación…")
            preparation = invoke(before_apply)
            releases.require(preparation is not False, "Pre-application preparation rejected the update")
        context = preparation if hasattr(preparation, "__enter__") and hasattr(preparation, "__exit__") else nullcontext()
        applied = False
        with context:
            notify("applying", "Aplicando y verificando la actualización…")
            verify_selection()
            apply(candidate, current, root, state, [component], public_url)
            applied = True
        # A cleanup context must never turn a suppressed application error into
        # a successful update reported to the operator.
        releases.require(applied, "Update application did not complete")
        notify("complete", "Actualización verificada.")
        return result("updated")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd(), help="Installed checkout (default: current directory)")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status", help="Show installed versions and verify runtime identity")
    commands.add_parser("history", help="Show previous updates")
    rollback = commands.add_parser("rollback", help="Recover the previous frontend without restarting other services")
    rollback.add_argument("--url", help="Public URL for external verification")
    update = commands.add_parser("update", help="Update only the selected component")
    choice = update.add_mutually_exclusive_group(required=True)
    choice.add_argument("--frontend", metavar="VERSION", help="latest or a published commit SHA")
    choice.add_argument("--backend", metavar="VERSION", help="latest or a published commit SHA; requires a verified database backup")
    update.add_argument("--digest", help="Optional expected digest for automation")
    update.add_argument("--url", help="Public URL for external verification")
    update.add_argument("--prepare", action="store_true", help="Prepare and validate without changing running services")
    args = parser.parse_args()
    if args.command == "update":
        component = "frontend" if args.frontend else "backend"

        def preview(_current, candidate, selected_component):
            show(candidate)
            print(f"Servicio que se actualizará: {selected_component}", flush=True)
            return True

        outcome = execute_update(args.root, component, args.frontend or args.backend,
                                 expected_digest=args.digest, public_url=args.url,
                                 prepare_only=args.prepare, confirm=preview)
        if outcome["status"] == "unchanged":
            show(outcome["current"])
            print("Ya está actualizado; no se reinició ningún servicio.")
        elif outcome["status"] == "prepared":
            preview(outcome["current"], outcome["candidate"], component)
            print("Preparación correcta; los servicios siguen sin cambios.")
        else:
            print("Actualización verificada.")
        return
    root = checked_root(args.root)
    with releases.release_lock(root) as state:
        current = current_release(root)
        if args.command == "history":
            for path in history(root)[:20]:
                result = releases.read_json(path)
                target = releases.read_json(path.parent / "target.json")
                print(target["createdAt"], result["operation"], result["status"],
                      "frontend=" + target["sources"]["frontend"]["commit"][:12],
                      "backend=" + target["sources"]["backend"]["commit"][:12])
            return
        if args.command == "status":
            show(current)
            releases.verify_runtime(current, root)
            print("Versiones instaladas verificadas.")
            return
        public_url = args.url or env_value(root, "SIHSALUS_PUBLIC_URL")
        releases.require(not public_url or re.fullmatch(r"https?://[A-Za-z0-9.:-]+", public_url), "Invalid public URL")
        if args.command == "rollback":
            previous = previous_release(current, root)
            releases.verify_checkout(previous, root, compatible=True)
            releases.require(previous["sources"]["backend"] == current["sources"]["backend"],
                             "Backend recovery requires reviewing database migrations; automatic rollback is frontend-only")
            candidate = candidate_release(previous, root)
            releases.apply_release(candidate, current, root, rollback=True, services=["frontend"], state=state,
                                   verify=lambda: verify_external(candidate, root, public_url))
            show(candidate)
            return


if __name__ == "__main__":
    def interrupted(_number, _frame):
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    try:
        main()
    except (releases.ManifestError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        message = str(error) if isinstance(error, releases.ManifestError) else "Operation failed or interrupted; run status and inspect the private deployment log"
        print(f"[deploy] {message}", file=sys.stderr)
        sys.exit(1)
