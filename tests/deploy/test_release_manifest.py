"""Synthetic release tests: no clinical data, network, or Docker daemon."""

from copy import deepcopy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release_manifest", ROOT / "scripts/deploy/release-manifest.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


def digest(value):
    return "sha256:" + hashlib.sha256(value.encode()).hexdigest()


def fixture(name="first"):
    sources = {
        "distroCommit": "a" * 40,
        "contentVersion": "1.25.20" if name == "first" else "1.25.21",
        "backend": {"commit": "b" * 40},
        "frontend": {"commit": "c" * 40 if name == "first" else "d" * 40},
    }
    for service in ("backend", "frontend"):
        sources[service]["image"] = f"ghcr.io/sihsalus/sihsalus-{service}:sha-{sources[service]['commit']}@{digest(name + service)}"
    services = {}
    for service in release.CORE_SERVICES:
        image_id = digest(name + service + "runtime")
        image = image_id if service in ("frontend", "gateway") else f"docker.io/library/alpine@{digest(name + service)}"
        services[service] = {"image": image, "imageId": image_id}
    services["backend"]["image"] = sources["backend"]["image"]
    return {
        "schemaVersion": 1, "releaseId": name, "createdAt": "2026-09-21T00:00:00Z",
        "target": {"environment": "qlty", "nodeId": "11111111-1111-4111-8111-111111111111"},
        "compose": {"project": "release-test", "files": ["docker-compose.yml"], "profiles": [], "platform": "linux/amd64"},
        "sources": sources, "services": services,
    }


class Engine:
    """Docker command boundary, with real Git/file operations kept intact."""

    def __init__(self, previous, target):
        self.real_run = release.run
        self.real_subprocess = subprocess.run
        self.calls = []
        self.images = {}
        self.metadata = {}
        self.temporary = {}
        self.runtime = deepcopy(previous)
        self.target = target
        self.fail = False
        self.drift = False
        for manifest in (previous, target):
            for service, artifact in manifest["services"].items():
                image = {"id": artifact["imageId"], "os": "linux", "arch": "amd64", "digests": [], "revision": "", "node": ""}
                if "@" in artifact["image"]:
                    repository = artifact["image"].split("@", 1)[0].split(":sha-", 1)[0]
                    image["digests"] = [repository + "@" + artifact["image"].split("@", 1)[1]]
                if service == "backend":
                    image["revision"] = manifest["sources"][service]["commit"]
                    self.metadata[image["id"]] = "content.sihsalus-content=" + manifest["sources"]["contentVersion"] + "\n"
                if service == "frontend":
                    image["node"] = manifest["target"]["nodeId"]
                    self.metadata[image["id"]] = json.dumps({"gitSha": manifest["sources"]["frontend"]["commit"]})
                self.images[artifact["image"]] = image
                self.images[artifact["imageId"]] = image
            source = manifest["sources"]["frontend"]
            self.images[source["image"]] = {"id": digest(source["image"]), "revision": source["commit"]}

    def run(self, command, **kwargs):
        if command[0] != "docker":
            return self.real_run(command, **kwargs)
        self.calls.append(command)
        if command[1:3] == ["image", "inspect"]:
            if command[3] not in self.images:
                raise release.ManifestError("Image unavailable")
            return json.dumps(self.images[command[3]])
        if command[1:3] == ["image", "tag"]:
            if command[3] not in self.images:
                raise release.ManifestError("Image unavailable")
            self.images[command[4]] = self.images[command[3]]
            return ""
        if command[1] == "create":
            identifier = digest(str(len(self.calls)))[7:]
            self.temporary[identifier] = command[-1]
            return identifier
        if command[1] == "cp":
            identifier = command[2].split(":", 1)[0]
            data = self.metadata[self.temporary[identifier]].encode()
            output = io.BytesIO()
            with tarfile.open(fileobj=output, mode="w") as archive:
                member = tarfile.TarInfo("metadata")
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
            return output.getvalue()
        if command[1] == "rm":
            del self.temporary[command[-1]]
            return ""
        if command[1] == "ps":
            return "\n".join(digest(service)[7:] for service in self.runtime["services"])
        if command[1] == "inspect":
            service = next(service for service in self.runtime["services"] if digest(service)[7:] == command[2])
            return json.dumps({"service": service, "oneoff": "False",
                               "imageId": self.runtime["services"][service]["imageId"],
                               "node": self.runtime["target"]["nodeId"] if service == "frontend" else ""})
        if command[1] == "compose":
            env_file = Path(command[command.index("--env-file") + 1])
            selected = dict(line.split("=", 1) for line in env_file.read_text().splitlines() if "=" in line)
            if command[-1] == "--environment":
                return "\n".join(f"{key}={value}" for key, value in selected.items())
            if command[-1] == "--services":
                return "\n".join(self.target["services"])
            files = [command[index + 1] for index, value in enumerate(command) if value == "--file"]
            if not files:
                files = selected["COMPOSE_FILE"].split(":")
            override = json.loads(Path(files[-1]).read_text())
            return json.dumps({"name": self.target["compose"]["project"], **override})
        raise AssertionError(f"Unexpected Docker operation: {command[:3]}")

    def execute(self, command, **kwargs):
        if command[0] != "bash":
            return self.real_subprocess(command, **kwargs)
        self.calls.append(command)
        environment = kwargs["env"]
        assert environment["REDEPLOY_OFFLINE"] == "true"
        assert environment["SIHSALUS_MANIFEST_APPLY"] == "true"
        assert Path(environment["COMPOSE_ENV_FILES"]) == kwargs["cwd"] / ".env"
        selected = json.loads(Path(environment["SIHSALUS_RELEASE_MANIFEST"]).read_text())
        assert command[-2:] == [selected["sources"]["backend"]["commit"], selected["sources"]["backend"]["image"].split("@", 1)[1]]
        if not self.fail:
            self.runtime = deepcopy(selected)
        if self.drift:
            self.runtime["services"]["docs"]["imageId"] = digest("unexpected")
        return subprocess.CompletedProcess(command, 1 if self.fail else 0)


class ManifestContract(unittest.TestCase):
    def test_core_optional_and_local_images(self):
        manifest = fixture()
        manifest["services"]["fua-generator"] = {"image": "ghcr.io/sihsalus/fua-generator@" + digest("fua"), "imageId": digest("fua-id")}
        self.assertEqual(release.validate_manifest(manifest), manifest)
        self.assertTrue(all(item["pull_policy"] == "never" for item in release.compose_override(manifest)["services"].values()))

    def test_mutable_or_mismatched_metadata_is_rejected(self):
        mutations = [
            lambda m: m.update(schemaVersion=True),
            lambda m: m.update(secret="SYNTHETIC_SECRET_DO_NOT_LOG"),
            lambda m: m["services"].pop("docs"),
            lambda m: m["services"]["db"].update(image="mariadb:10.11.7"),
            lambda m: m["services"]["docs"].update(image="ghcr.io/sihsalus/docs:latest@" + digest("docs")),
            lambda m: m["services"]["gateway"].update(image=digest("different")),
            lambda m: m["sources"]["frontend"].update(commit="e" * 40),
            lambda m: m["sources"].update(contentVersion="1.0.0-SNAPSHOT"),
            lambda m: m["compose"]["files"].append("../outside.yml"),
            lambda m: m["compose"]["files"].append("compose/seed.yml"),
            lambda m: m["compose"]["profiles"].append("seed"),
            lambda m: m["compose"]["profiles"].extend(["fua", "fua"]),
            lambda m: m["target"].update(nodeId="00000000-0000-0000-0000-000000000000"),
            lambda m: m.update(createdAt="2026-02-30T00:00:00Z"),
        ]
        for change in mutations:
            with self.subTest(change=change):
                manifest = fixture()
                change(manifest)
                with self.assertRaises(release.ManifestError) as caught:
                    release.validate_manifest(manifest)
                self.assertNotIn("SYNTHETIC_SECRET", str(caught.exception))

    def test_every_enabled_service_and_dependency_must_be_pinned(self):
        manifest = fixture()
        model = {"name": manifest["compose"]["project"], **release.compose_override(manifest)}
        active = list(manifest["services"])
        release.validate_effective_compose(manifest, model, active)
        for mutation in ("extra-service", "image-drift", "pull", "dependency"):
            with self.subTest(mutation=mutation):
                changed = deepcopy(model)
                enabled = list(active)
                if mutation == "extra-service":
                    enabled.append("fua-generator")
                elif mutation == "image-drift":
                    changed["services"]["docs"]["image"] = "docs:latest"
                elif mutation == "pull":
                    changed["services"]["docs"]["pull_policy"] = "always"
                else:
                    changed["services"]["docs"]["depends_on"] = {"unknown": {}}
                with self.assertRaises(release.ManifestError):
                    release.validate_effective_compose(manifest, changed, enabled)

    def test_dotenv_selection_removes_all_duplicate_spellings_without_exposing_secrets(self):
        before = "PASSWORD=synthetic-kept\nexport COMPOSE_FILE = old\nCOMPOSE_FILE=other\n# retained\n"
        after = release.select_manifest(before, {"COMPOSE_FILE": "docker-compose.yml:images.json"})
        self.assertEqual(after.count("COMPOSE_FILE"), 1)
        self.assertIn("PASSWORD=synthetic-kept\n", after)
        self.assertIn("# retained\n", after)

    def test_duplicate_json_and_overwrite_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text('{"schemaVersion":1,"schemaVersion":2}')
            with self.assertRaises(release.ManifestError):
                release.read_json(path)
            with self.assertRaises(FileExistsError):
                release.write_new(path, fixture())

    def test_docker_hub_references_are_qualified(self):
        self.assertEqual(release.immutable_reference({"digests": ["alpine@" + digest("a")]}), "docker.io/library/alpine@" + digest("a"))
        self.assertEqual(release.immutable_reference({"digests": ["vendor/image@" + digest("a")]}), "docker.io/vendor/image@" + digest("a"))


class RuntimeConsumption(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "docker-compose.yml").write_text("services: {}\n")
        (self.root / ".gitignore").write_text(".env\n.env.release-state/\n")
        for command in (["git", "init", "-q"], ["git", "add", "."],
                        ["git", "-c", "user.name=Release Test", "-c", "user.email=release@example.invalid", "commit", "-qm", "fixture"]):
            subprocess.run(command, cwd=self.root, check=True, capture_output=True)
        self.previous, self.target = fixture(), fixture("second")
        head = release.run(["git", "rev-parse", "HEAD"], root=self.root).strip()
        for manifest in (self.previous, self.target):
            manifest["sources"]["distroCommit"] = head
        self.before = b"PASSWORD=synthetic-secret\nDEPLOYMENT_ENV=qlty\n"
        (self.root / ".env").write_bytes(self.before)
        self.engine = Engine(self.previous, self.target)
        self.addCleanup(patch.stopall)
        patch.object(release, "run", self.engine.run).start()
        patch.object(release.subprocess, "run", self.engine.execute).start()

    def results(self):
        return [json.loads(path.read_text()) for path in (self.root / ".env.release-state").glob("*/result.json")]

    def test_deploy_and_rollback_consume_the_same_manifest_format(self):
        release.apply_release(self.target, self.previous, self.root)
        self.assertEqual(self.engine.runtime, self.target)
        self.assertEqual(self.results()[0]["status"], "verified")
        selected = (self.root / ".env").read_text()
        self.assertIn("SIHSALUS_RELEASE_MANIFEST=", selected)
        self.assertIn("PASSWORD=synthetic-secret", selected)
        self.assertIn(release.manifest_digest(self.target) + ".compose.json", selected)
        self.assertEqual((self.root / ".env").stat().st_mode & 0o777, 0o600)
        self.assertFalse(self.engine.temporary)
        # The retained previous source/runtime images remain addressable.
        self.assertTrue(any(key.startswith("sihsalus-release-retained:") for key in self.engine.images))
        release.apply_release(self.previous, self.target, self.root, rollback=True)
        self.assertEqual(self.engine.runtime, self.previous)
        self.assertEqual(len(self.results()), 2)
        self.assertTrue(all(result["status"] == "verified" for result in self.results()))

    def test_failed_deploy_retains_attempted_selection_and_recovery_evidence(self):
        self.engine.fail = True
        with self.assertRaises(release.ManifestError):
            release.apply_release(self.target, self.previous, self.root)
        self.assertEqual(self.results()[0]["status"], "failed-or-interrupted")
        self.assertIn(release.manifest_digest(self.target), (self.root / ".env").read_text())
        before = next((self.root / ".env.release-state").glob("*/before.env"))
        self.assertEqual(before.read_bytes(), self.before)
        self.assertEqual(before.stat().st_mode & 0o777, 0o600)
        self.engine.fail = False
        release.apply_release(self.previous, self.target, self.root, rollback=True)
        self.assertEqual(self.engine.runtime, self.previous)

    def test_post_redeploy_image_drift_is_not_reported_as_verified(self):
        self.engine.drift = True
        with self.assertRaisesRegex(release.ManifestError, "Runtime image IDs"):
            release.apply_release(self.target, self.previous, self.root)
        self.assertEqual(self.results()[0]["status"], "failed-or-interrupted")

    def test_rollback_recovers_missing_frontend_without_requiring_broken_candidate_image(self):
        self.engine.fail = True
        with self.assertRaises(release.ManifestError):
            release.apply_release(self.target, self.previous, self.root)
        self.engine.fail = False
        del self.engine.runtime["services"]["frontend"]
        del self.engine.images[self.target["services"]["frontend"]["imageId"]]
        release.apply_release(self.previous, self.target, self.root, rollback=True)
        self.assertEqual(self.engine.runtime, self.previous)

    def test_missing_frontend_without_retained_node_cannot_trigger_recovery(self):
        del self.engine.runtime["services"]["frontend"]
        with self.assertRaisesRegex(release.ManifestError, "Retained node"):
            release.apply_release(self.target, self.previous, self.root, rollback=True)
        self.assertEqual((self.root / ".env").read_bytes(), self.before)

    def test_interruption_keeps_failed_attempt_and_private_previous_configuration(self):
        original = self.engine.execute

        def interrupted(command, **kwargs):
            if command[0] == "bash":
                raise KeyboardInterrupt()
            return original(command, **kwargs)

        with patch.object(release.subprocess, "run", interrupted):
            with self.assertRaises(KeyboardInterrupt):
                release.apply_release(self.target, self.previous, self.root)
        self.assertEqual(self.results()[0]["status"], "failed-or-interrupted")
        self.assertEqual(next((self.root / ".env.release-state").glob("*/before.env")).read_bytes(), self.before)

    def test_audit_rejects_a_marker_with_a_different_effective_compose_selection(self):
        release.apply_release(self.target, self.previous, self.root)
        env_file = self.root / ".env"
        original = env_file.read_text()
        manifest_path = self.root / ".env.release-state" / (release.manifest_digest(self.target) + ".json")
        release.verify_selected_compose(self.target, self.root, env_file, manifest_path)
        env_file.write_text(release.select_manifest(original, {"COMPOSE_FILE": "docker-compose.yml"}))
        with self.assertRaisesRegex(release.ManifestError, "Effective Compose files"):
            release.verify_selected_compose(self.target, self.root, env_file, manifest_path)

    def test_wrong_content_is_rejected_before_environment_or_runtime_changes(self):
        self.engine.metadata[self.target["services"]["backend"]["imageId"]] = "content.sihsalus-content=0.0.1\n"
        with self.assertRaisesRegex(release.ManifestError, "content version"):
            release.apply_release(self.target, self.previous, self.root)
        self.assertEqual((self.root / ".env").read_bytes(), self.before)
        self.assertFalse(any(command[0] == "bash" for command in self.engine.calls))
        self.assertFalse(self.engine.temporary)

    def test_environment_identity_must_match_before_docker(self):
        (self.root / ".env").write_text("DEPLOYMENT_ENV=production\n")
        with self.assertRaisesRegex(release.ManifestError, "Local environment"):
            release.apply_release(self.target, self.previous, self.root)
        self.assertFalse(self.engine.calls)

    def test_wrong_frontend_revision_is_rejected_before_recreation(self):
        self.engine.metadata[self.target["services"]["frontend"]["imageId"]] = json.dumps({"gitSha": "e" * 40})
        with self.assertRaisesRegex(release.ManifestError, "frontend revision"):
            release.apply_release(self.target, self.previous, self.root)
        self.assertEqual((self.root / ".env").read_bytes(), self.before)
        self.assertFalse(self.engine.temporary)

    def test_missing_rollback_image_is_rejected_before_recreation(self):
        del self.engine.images[self.previous["services"]["docs"]["image"]]
        with self.assertRaises(release.ManifestError):
            release.apply_release(self.target, self.previous, self.root)
        self.assertEqual((self.root / ".env").read_bytes(), self.before)

    def test_wrong_node_platform_source_and_image_ids_fail_before_changes(self):
        cases = (("frontend", "node", "22222222-2222-4222-8222-222222222222"),
                 ("db", "arch", "arm64"), ("backend", "revision", "f" * 40),
                 ("docs", "id", digest("unexpected")))
        for service, field, value in cases:
            with self.subTest(service=service, field=field):
                image = self.engine.images[self.target["services"][service]["image"]]
                original = image[field]
                image[field] = value
                with self.assertRaises(release.ManifestError):
                    release.apply_release(self.target, self.previous, self.root)
                image[field] = original
                self.assertEqual((self.root / ".env").read_bytes(), self.before)

    def test_runtime_drift_or_cross_node_rollback_does_not_recreate(self):
        self.engine.runtime["services"]["unexpected"] = deepcopy(self.previous["services"]["docs"])
        with self.assertRaises(release.ManifestError):
            release.apply_release(self.target, self.previous, self.root, rollback=True)
        self.assertEqual((self.root / ".env").read_bytes(), self.before)

    def test_profile_transition_requires_separate_migration(self):
        self.target["compose"]["profiles"] = ["fua"]
        with self.assertRaisesRegex(release.ManifestError, "migration"):
            release.apply_release(self.target, self.previous, self.root)
        self.assertFalse(self.engine.calls)

    def test_dirty_checkout_and_wrong_commit_fail_before_docker(self):
        (self.root / "docker-compose.yml").write_text("services: {unexpected: {}}\n")
        with self.assertRaisesRegex(release.ManifestError, "tracked changes"):
            release.apply_release(self.target, self.previous, self.root)
        self.assertFalse(self.engine.calls)
        self.target["sources"]["distroCommit"] = "f" * 40
        with self.assertRaisesRegex(release.ManifestError, "distribution commit"):
            release.apply_release(self.target, self.previous, self.root)

    def test_capture_pins_current_runtime_without_pulling_or_starting_it(self):
        self.engine.runtime = deepcopy(self.target)
        metadata = {key: value for key, value in self.target.items() if key != "services"}
        captured = release.capture(metadata, self.root, self.root / ".env")
        self.assertEqual(captured["sources"], self.target["sources"])
        self.assertEqual(set(captured["services"]), set(self.target["services"]))
        self.assertEqual(captured["services"]["frontend"]["image"], self.target["services"]["frontend"]["imageId"])
        self.assertFalse(any(command[1] in ("pull", "start", "build", "up", "exec") for command in self.engine.calls))
        self.assertFalse(self.engine.temporary)
        self.assertEqual((self.root / ".env").read_bytes(), self.before)

    def test_lock_prevents_concurrent_recreation(self):
        with release.release_lock(self.root):
            with self.assertRaisesRegex(release.ManifestError, "Another manifest"):
                release.apply_release(self.target, self.previous, self.root)
        self.assertFalse(self.engine.calls)

    def test_legacy_deployment_guard_rejects_manifest_managed_host(self):
        (self.root / ".env").write_text("export SIHSALUS_RELEASE_MANIFEST = '/local/release.json'\n")
        result = self.engine.real_subprocess(["bash", str(ROOT / "scripts/deploy/check-clean-checkout.sh"), "test"],
                                             cwd=self.root, capture_output=True, text=True,
                                             env={**os.environ, "SIHSALUS_MANIFEST_APPLY": "false"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("managed by a release manifest", result.stderr)


class CatalogHistory(unittest.TestCase):
    def test_unused_catalog_can_be_absent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            release.validate_catalog(root, None, root / "index.json")
            self.assertEqual(json.loads((root / "index.json").read_text()), {"manifests": []})
            self.assertFalse((root / "releases").exists())

    def test_catalog_rejects_a_file_or_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            catalog = root / "releases"
            catalog.write_text("invalid")
            with self.assertRaises(release.ManifestError):
                release.validate_catalog(root, None)
            catalog.unlink()
            catalog.symlink_to(root / "missing")
            with self.assertRaises(release.ManifestError):
                release.validate_catalog(root, None)

    def test_history_is_append_only_and_index_contains_exact_file_checksums(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = fixture()
            parent = root / "releases" / "qlty" / manifest["target"]["nodeId"]
            parent.mkdir(parents=True)
            path = parent / "first.json"
            release.write_new(path, manifest)
            for command in (["git", "init", "-q"], ["git", "add", "."],
                            ["git", "-c", "user.name=Release Test", "-c", "user.email=release@example.invalid", "commit", "-qm", "published"]):
                subprocess.run(command, cwd=root, check=True, capture_output=True)
            base = release.run(["git", "rev-parse", "HEAD"], root=root).strip()
            release.write_new(parent / "second.json", fixture("second"))
            release.validate_catalog(root, base, root / "index.json")
            index = json.loads((root / "index.json").read_text())
            self.assertEqual(len(index["manifests"]), 2)
            self.assertEqual(index["manifests"][0]["sha256"], hashlib.sha256(path.read_bytes()).hexdigest())
            path.write_text(path.read_text() + "\n")
            with self.assertRaisesRegex(release.ManifestError, "changed or renamed"):
                release.validate_catalog(root, base)
            path.unlink()
            with self.assertRaisesRegex(release.ManifestError, "deleted"):
                release.validate_catalog(root, base)
            (parent / "second.json").unlink()
            parent.rmdir()
            parent.parent.rmdir()
            parent.parent.parent.rmdir()
            with self.assertRaisesRegex(release.ManifestError, "deleted"):
                release.validate_catalog(root, base)


if __name__ == "__main__":
    unittest.main()
