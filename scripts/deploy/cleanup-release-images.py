#!/usr/bin/env python3
"""Retire unused release images; preserve manifests, containers and volumes."""

import argparse
from datetime import datetime, timedelta, timezone
import importlib.util
import json
from pathlib import Path
import re
import sys


def load_release(root):
    spec = importlib.util.spec_from_file_location("release_manifest", root / "scripts/deploy/release-manifest.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def timestamp(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def normalize(reference):
    if "@" not in reference:
        return reference
    repository, digest = reference.split("@", 1)
    parts = repository.split("/")
    parts[-1] = parts[-1].split(":", 1)[0]
    if len(parts) == 1 or not ("." in parts[0] or ":" in parts[0] or parts[0] == "localhost"):
        parts.insert(0, "docker.io")
    if parts[0] == "index.docker.io":
        parts[0] = "docker.io"
    if parts[0] == "docker.io" and len(parts) == 2:
        parts.insert(1, "library")
    return "/".join(parts) + "@" + digest


def references(manifest):
    return {a[key] for a in manifest["services"].values() for key in ("image", "imageId")} | {
        manifest["sources"][name]["image"] for name in ("backend", "frontend")
    }


def retained_releases(manifests, current, days, count, now):
    ordered = sorted(manifests, key=lambda key: (manifests[key]["createdAt"], key), reverse=True)
    cutoff = now - timedelta(days=days)
    return {current} | set(ordered[:count]) | {
        key for key, value in manifests.items() if timestamp(value["createdAt"]) >= cutoff
    }


def image_inventory(release, root, identifiers=None):
    if identifiers is None:
        identifiers = sorted(set(release.run(["docker", "image", "ls", "--quiet", "--no-trunc"], root=root).splitlines()))
    images = {}
    template = ('{"id":{{json .Id}},"tags":{{json .RepoTags}},'
                '"digests":{{json .RepoDigests}},"created":{{json .Created}}}')
    for start in range(0, len(identifiers), 100):
        output = release.run(["docker", "image", "inspect", "--format", template] + identifiers[start:start + 100], root=root)
        for line in output.splitlines():
            item = json.loads(line)
            images[item["id"]] = item
    return images


def used_images(release, root):
    containers = release.run(["docker", "ps", "--all", "--quiet", "--no-trunc"], root=root).splitlines()
    if not containers:
        return set()
    return set(release.run(["docker", "inspect", "--format", "{{.Image}}", *containers], root=root).splitlines())


def plan_images(images, manifests, keep, prepared, used, cutoff):
    lookup = {normalize(ref): key for key, image in images.items()
              for ref in [key, *(image["tags"] or []), *(image["digests"] or [])]}

    def ids(manifest):
        return {lookup[normalize(ref)] for ref in references(manifest) if normalize(ref) in lookup}

    protected = set(used)
    for key in keep:
        protected.update(ids(manifests[key]))
    for manifest in prepared:
        protected.update(ids(manifest))
    candidates = set()
    for key, manifest in manifests.items():
        if key not in keep:
            candidates.update(ids(manifest))
    result = []
    for key in sorted(candidates - protected):
        image = images[key]
        refs = sorted(set((image["tags"] or []) + (image["digests"] or [])))
        # Unknown owners and explicitly staged candidates are never garbage.
        if not refs or any(not ref.startswith(("sihsalus-", "local/sihsalus-", "ghcr.io/sihsalus/"))
                           or "-prepared:" in ref or ":candidate-" in ref for ref in refs):
            continue
        if timestamp(image["created"]) >= cutoff:
            continue
        result.append({"id": key, "references": refs})
    return result


def clean(release, root, days, count, apply):
    env = root / ".env"
    release.require(env.is_file() and not env.is_symlink(), "A regular local environment file is required")
    values = re.findall(r"^SIHSALUS_RELEASE_MANIFEST=(\S+)$", env.read_text(), re.MULTILINE)
    release.require(len(values) == 1, "Exactly one retained release selection is required")
    selected = Path(values[0])
    now = datetime.now(timezone.utc)
    with release.release_lock(root) as state:
        release.require(selected.parent == state and not selected.is_symlink(), "Unsafe retained release selection")
        manifests = {}
        for path in state.glob("*.json"):
            if not re.fullmatch(r"[0-9a-f]{64}\.json", path.name):
                continue
            release.require(not path.is_symlink(), "Manifest must not be a symbolic link")
            manifest = release.validate_manifest(release.read_json(path))
            release.require(release.manifest_digest(manifest) == path.stem, "Retained manifest checksum differs")
            manifests[path.stem] = manifest
        release.require(selected.stem in manifests, "Selected manifest is missing")
        current = manifests[selected.stem]
        release.verify_selected_compose(current, root, env, selected)
        release.verify_runtime(current, root)
        release.require(all(m["target"] == current["target"] for m in manifests.values()), "Mixed node identities in release history")
        keep = retained_releases(manifests, selected.stem, days, count, now)
        # Preserve the actual predecessor even after a rollback to an older release.
        attempts = sorted(state.glob("*/result.json"), key=lambda path: path.stat().st_mtime, reverse=True)
        if attempts:
            latest = release.read_json(attempts[0])
            release.require(latest.get("status") == "verified", "Latest deployment requires recovery before cleanup")
            for key in (latest.get("target"), latest.get("previous")):
                release.require(key in manifests, "Recovery manifest is missing")
                keep.add(key)
        prepared = []
        staging = root.parent / ".sihsalus-release-prep"
        for path in staging.glob("*/candidate.json"):
            release.require(not path.is_symlink() and not path.parent.is_symlink(), "Unsafe staged manifest")
            prepared.append(release.validate_manifest(release.read_json(path)))
        images = image_inventory(release, root)
        known = {normalize(ref) for key, item in images.items()
                 for ref in [key, *(item["tags"] or []), *(item["digests"] or [])]}
        for key in keep:
            release.require(all(normalize(ref) in known for ref in references(manifests[key])),
                            "A protected release has missing images; resolve recovery before cleanup")
        candidates = plan_images(images, manifests, keep, prepared, used_images(release, root), now - timedelta(days=days))
        report = {"createdAt": now.isoformat(), "mode": "apply" if apply else "preview",
                  "keep_days": days, "keep_releases": count, "target": current["target"],
                  "preserved_manifests": sorted(keep), "candidate_images": candidates,
                  "removed_images": [], "volumes_deleted": False, "containers_deleted": False}
        if apply:
            # Journal lives outside immutable release manifests. A failed deletion
            # remains visible and is retried safely on the next run.
            journal = state / "image-cleanup-latest.json"
            release.replace_private(journal, release.canonical_bytes(report))
            for item in candidates:
                release.require(item["id"] not in used_images(release, root), "A candidate image became used; cleanup stopped")
                fresh = image_inventory(release, root, [item["id"]])
                release.require(item["id"] in fresh, "Candidate image changed; cleanup stopped")
                refs = sorted(set((fresh[item["id"]]["tags"] or []) + (fresh[item["id"]]["digests"] or [])))
                release.require(refs == item["references"], "Candidate references changed; cleanup stopped")
                # Removing the final tag also removes digest references. Passing
                # those digests again would turn a successful deletion into an error.
                remove = sorted(fresh[item["id"]]["tags"] or []) or refs
                release.run(["docker", "image", "rm", "--no-prune", *remove], root=root)
                report["removed_images"].append(item["id"])
                release.replace_private(journal, release.canonical_bytes(report))
            remaining = image_inventory(release, root)
            release.require(not set(report["removed_images"]) & set(remaining), "An image was untagged but remains; inspect cleanup journal")
            release.verify_runtime(current, root)
            report["status"] = "completed"
            release.replace_private(journal, release.canonical_bytes(report))
        return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--keep-days", type=int, default=3)
    parser.add_argument("--keep-releases", type=int, default=2)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    if args.keep_days < 1 or args.keep_releases < 2:
        parser.error("Keep at least one day and two releases")
    root = args.root.resolve()
    release = load_release(root)
    try:
        result = clean(release, root, args.keep_days, args.keep_releases, args.apply)
        print(json.dumps(result, sort_keys=True))
    except release.ManifestError as error:
        print(f"[image-cleanup] {error}", file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, TypeError):
        print("[image-cleanup] Invalid operational metadata; no raw values displayed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
