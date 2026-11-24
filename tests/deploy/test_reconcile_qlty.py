"""Synthetic operator checks for adopting the observed PostgreSQL image in QLTY."""
from contextlib import ExitStack
from copy import deepcopy
from importlib import util
import json
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch


DIRECTORY = Path(__file__).resolve().parents[2] / "scripts/deploy"
sys.path.insert(0, str(DIRECTORY))
try:
    spec = util.spec_from_file_location("reconcile_qlty", DIRECTORY / "reconcile-qlty.py")
    tool = util.module_from_spec(spec)
    spec.loader.exec_module(tool)
finally:
    sys.path.pop(0)


class ReconcileTests(unittest.TestCase):
    def setUp(self):
        temporary = TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.sha = "a" * 40
        self.digest = "sha256:" + "d" * 64
        self.old_image = "sha256:" + "1" * 64
        self.new_image = "sha256:" + "2" * 64
        self.ref = "docker.io/library/postgres@" + self.digest
        self.manifest = {"target": {"environment": "qlty", "nodeId": tool.qlty.QLTY_NODE},
                         "compose": {"project": "test"}, "sources": {"distroCommit": "c" * 40},
                         "services": {tool.PG: {"image": self.old_image, "imageId": self.old_image},
                                      tool.HELPER: {"imageId": self.old_image}}}
        self.db = {"name": tool.PG, "oneoff": "False", "id": "1" * 64, "image": self.new_image,
                   "started": "2026-11-01", "status": "running", "exit": 0, "health": "healthy", "configured": self.ref,
                   "mounts": [{"Type": "volume", "Name": "test_db-fua-generator", "Destination": tool.DATA, "RW": True}]}
        self.helper = {**self.db, "name": tool.HELPER, "id": "2" * 64, "image": self.old_image,
                       "status": "exited", "exit": 0, "mounts": []}

    def inspect_containers(self, *items):
        with patch.object(tool.release, "run", side_effect=["\n".join(i["id"] for i in items),
                                                             "\n".join(json.dumps(i) for i in items)]):
            return tool.runtime_snapshot(self.root, self.manifest)

    def test_live_snapshot_checks_helper_volume_and_other_images(self):
        self.assertEqual(self.inspect_containers(self.db, self.helper)[tool.PG]["id"], self.db["id"])
        wrong_mount = {**self.db["mounts"][0], "Name": "other"}
        for items in ((self.db,), (self.db, {**self.helper, "exit": 1}), (self.db, {**self.helper, "image": self.new_image}),
                      ({**self.db, "health": "unhealthy"}, self.helper), ({**self.db, "mounts": []}, self.helper),
                      ({**self.db, "mounts": [wrong_mount]}, self.helper)):
            with self.subTest(items=items), self.assertRaises(tool.release.ManifestError):
                self.inspect_containers(*items)

    def test_mount_order_is_immaterial_but_a_replacement_is_detected(self):
        log = {"Type": "volume", "Name": "logs", "Destination": "/logs", "RW": True}
        first = self.inspect_containers({**self.db, "mounts": [*self.db["mounts"], log]}, self.helper)
        reordered = self.inspect_containers({**self.db, "mounts": [log, *self.db["mounts"]]}, self.helper)
        changed = self.inspect_containers({**self.db, "mounts": [{**log, "Name": "other"}, *self.db["mounts"]]}, self.helper)
        self.assertEqual(first, reordered)
        self.assertNotEqual(first, changed)

    def test_pg_uses_digest_and_running_id_when_created_from_a_tag(self):
        image = {"id": self.new_image, "digests": [self.ref]}
        for configured in (self.ref, "postgres:17"):
            with patch.object(tool.release, "inspect_image", return_value=image) as inspected:
                with patch.object(tool.release, "run", return_value="PG_MAJOR=17") as major:
                    observed = tool.pg_artifact(self.root, self.manifest, {tool.PG: {**self.db, "configured": configured}}, self.digest)
            self.assertEqual(observed, {"image": self.ref, "imageId": self.new_image})
            inspected.assert_called_once_with(self.ref, self.root)
            self.assertEqual(major.call_count, 2)

        for configured, actual, version in (("postgres:16", image, "PG_MAJOR=17"), ("other/postgres@" + self.digest, image, "PG_MAJOR=17"),
                                            ("postgres@sha256:" + "f" * 64, image, "PG_MAJOR=17"),
                                            (self.ref, {**image, "id": self.old_image}, "PG_MAJOR=17"),
                                            (self.ref, {**image, "digests": ["other@" + self.digest]}, "PG_MAJOR=17"),
                                            (self.ref, image, "")):
            with self.subTest(configured=configured, actual=actual, version=version):
                with patch.object(tool.release, "inspect_image", return_value=actual), patch.object(tool.release, "run", return_value=version):
                    with self.assertRaises(tool.release.ManifestError):
                        tool.pg_artifact(self.root, self.manifest, {tool.PG: {**self.db, "configured": configured}}, self.digest)

    def run_selection(self, selected, apply, previous=None, provided=None):
        state = self.root / ".env.release-state"
        state.mkdir(mode=0o700, exist_ok=True)
        checksum = tool.release.manifest_digest(selected)
        path = state / (checksum + ".json")
        path.write_text(json.dumps(selected))
        attempt = state / "ffc07198-c042-4028-bf20-1096f735db39"
        attempt.mkdir(exist_ok=True)
        (attempt / "result.json").write_text(json.dumps({"status": "verified", "operation": "reconcile" if previous else "deploy",
                                                         "previous": previous, "target": checksum}))
        values = {"SIHSALUS_RELEASE_MANIFEST": str(path), "DEPLOYMENT_ENV": "qlty", "SIHSALUS_NODE_ID": tool.qlty.QLTY_NODE}
        artifact = {"image": self.ref, "imageId": self.new_image}

        def candidate(current, _root):
            result = deepcopy(current)
            result["sources"]["distroCommit"] = self.sha
            return result

        def transaction(target, current, root, **opts):
            self.assertTrue(opts["reconcile"])
            self.assertEqual(opts["state"], state)
            self.assertEqual(target["services"][tool.PG], artifact)
            self.assertEqual(target["services"][tool.HELPER], current["services"][tool.HELPER])
            self.assertEqual(target["sources"]["distroCommit"], self.sha)
            opts["verify_reconciliation"](current, target, root)
            opts["verify"]()

        with ExitStack() as stack:
            def mock(obj, name, **opts):
                return stack.enter_context(patch.object(obj, name, **opts))

            mock(tool.deploy, "checked_root", return_value=self.root)
            mock(tool.deploy, "env_value", side_effect=lambda _root, key: values[key])
            mock(tool.release, "validate_manifest", side_effect=lambda item: item)
            mock(tool.qlty, "check_history")
            mock(tool.release, "run", return_value=self.sha)
            mock(tool.deploy, "candidate_release", side_effect=candidate)
            mock(tool, "verify_configuration")
            mock(tool, "runtime_snapshot", return_value={tool.PG: self.db, tool.HELPER: self.helper})
            mock(tool, "pg_artifact", return_value=artifact)
            for action in ("verify_installed_selection", "verify_images", "verify_checkout", "verify_compose", "verify_runtime"):
                mock(tool.release, action)
            mock(tool.release, "verify_reconciliation_request", side_effect=lambda new, old, root, _state, guard: guard(old, new, root))
            engine = mock(tool.release, "apply_release", side_effect=transaction)
            result = tool.reconcile(self.root, provided or checksum, self.sha, self.digest, apply)
        return result, engine.call_count

    def test_dry_run_and_exact_apply(self):
        self.assertEqual(self.run_selection(self.manifest, False), ("prepared", 0))
        self.assertEqual(self.run_selection(self.manifest, True), ("reconciled", 1))
        with self.assertRaises(tool.release.ManifestError):
            self.run_selection(self.manifest, True, provided="f" * 64)

    def test_verified_replay_is_idempotent_for_the_same_original_selection(self):
        old = tool.release.manifest_digest(self.manifest)
        selected = deepcopy(self.manifest)
        selected["sources"]["distroCommit"] = self.sha
        selected["services"][tool.PG] = {"image": self.ref, "imageId": self.new_image}
        self.assertEqual(self.run_selection(selected, True, previous=old, provided=old), ("unchanged", 0))
        with self.assertRaises(tool.release.ManifestError):
            self.run_selection(selected, True, previous=old, provided="e" * 64)

    def test_mounted_input_changes_block_adoption_when_models_match(self):
        def git(*args):
            return subprocess.run(["git", *args], cwd=self.root, text=True, capture_output=True, check=True).stdout.strip()

        git("init", "--quiet")
        config = self.root / "service.conf"
        config.write_text("old")
        git("add", "service.conf")
        identity = ("-c", "user.name=Test", "-c", "user.email=test@example.invalid")
        git(*identity, "commit", "-qm", "before")
        first = git("rev-parse", "HEAD")
        config.write_text("new")
        git(*identity, "commit", "-qam", "after")
        old = {"sources": {"distroCommit": first}}
        new = {"sources": {"distroCommit": git("rev-parse", "HEAD")}}
        for model in ({"services": {"s": {"volumes": [{"type": "bind", "source": "./service.conf"}]}}},
                      {"services": {}, "configs": {"test": {"file": "./service.conf"}}},
                      {"services": {}, "secrets": {"test": {"file": "./service.conf"}}}):
            with self.subTest(model=model), patch.object(tool, "compose_model", return_value=model):
                with self.assertRaisesRegex(tool.release.ManifestError, "Mounted"):
                    tool.verify_configuration(old, new, self.root)
        with patch.object(tool, "compose_model", return_value={"services": {"s": {"volumes": []}}}):
            tool.verify_configuration(old, new, self.root)
