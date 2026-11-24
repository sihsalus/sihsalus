"""Reconciliation must only record an already-running QLTY database."""
from copy import deepcopy
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

from test_release_manifest import Engine, digest, fixture, release


class Reconciliation(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / "docker-compose.yml").write_text("services: {}\n")
        (self.root / ".gitignore").write_text(".env\n.env.release-state/\n")
        for args in (["init", "-q"], ["add", "."],
                     ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture"]):
            subprocess.run(["git", *args], cwd=self.root, capture_output=True, check=True)

        self.previous = fixture()
        self.previous["target"]["nodeId"] = "0cefb0c8-c860-48c5-856f-408594775cbb"
        self.previous["services"]["fua-generator-db"] = self.pg("before")
        self.candidate = deepcopy(self.previous)
        self.candidate["releaseId"] = "reconciled"
        self.candidate["sources"]["distroCommit"] = release.run(["git", "rev-parse", "HEAD"], root=self.root).strip()
        self.candidate["services"]["fua-generator-db"] = self.pg("observed")
        state = self.root / ".env.release-state"
        state.mkdir(mode=0o700)
        checksum = release.manifest_digest(self.previous)
        self.selected = state / (checksum + ".json")
        self.override = state / (checksum + ".compose.json")
        release.write_new(self.selected, self.previous)
        release.write_new(self.override, release.compose_override(self.previous))
        self.env = self.root / ".env"
        self.env.write_text(release.select_manifest("DEPLOYMENT_ENV=qlty\n", {
            "SIHSALUS_RELEASE_MANIFEST": str(self.selected), "SIHSALUS_NODE_ID": self.previous["target"]["nodeId"],
            "COMPOSE_FILE": str(self.root / "docker-compose.yml") + ":" + str(self.override), "COMPOSE_PROFILES": "",
            "DOCKER_DEFAULT_PLATFORM": "linux/amd64"}))
        self.before = self.env.read_bytes()
        self.engine = Engine(self.previous, self.candidate)
        self.engine.runtime = deepcopy(self.candidate)

        def guarded(command, **kwargs):
            if command[0] == "git" or command[:2] == ["bash", "-c"]:
                return self.engine.real_subprocess(command, **kwargs)
            raise AssertionError("Unexpected lifecycle command: " + str(command[:3]))

        self.addCleanup(patch.stopall)
        patch.object(release, "run", self.engine.run).start()
        patch.object(release.subprocess, "run", guarded).start()

    @staticmethod
    def pg(name):
        return {"image": "docker.io/library/postgres@" + digest("ref-" + name), "imageId": digest("id-" + name)}

    def apply(self, **kwargs):
        options = dict(reconcile=True, verify_reconciliation=lambda *args: True, verify=lambda: None)
        options.update(kwargs)
        release.apply_release(self.candidate, self.previous, self.root, **options)

    def results(self):
        return [release.read_json(p) for p in self.selected.parent.glob("*/result.json")]

    def test_verified_reconciliation_records_selection_without_lifecycle(self):
        def check(old, new, root):
            self.assertEqual((old, new, root), (self.previous, self.candidate, self.root))
            self.assertEqual(self.env.read_bytes(), self.before)
            with self.assertRaisesRegex(release.ManifestError, "active"):
                with release.release_lock(root):
                    self.fail("Reconciliation must hold the release lock")

        self.apply(verify_reconciliation=check)
        self.assertEqual(self.results(), [{"operation": "reconcile", "target": release.manifest_digest(self.candidate),
                                           "previous": release.manifest_digest(self.previous), "status": "verified"}])
        self.assertEqual(release.read_json(self.selected), self.previous)
        self.assertEqual(release.read_json(self.override), release.compose_override(self.previous))
        new_path = self.selected.parent / (release.manifest_digest(self.candidate) + ".json")
        release.verify_selected_compose(self.candidate, self.root, self.env, new_path)
        self.assertEqual(self.engine.runtime, self.candidate)
        self.assertFalse(self.engine.temporary)

    def test_refuses_modes_and_callbacks(self):
        for options in ({"verify_reconciliation": None}, {"verify": None}, {"rollback": True}, {"services": ["backend"]},
                        {"verify_reconciliation": lambda *args: False}):
            with self.subTest(options=options), self.assertRaises(release.ManifestError):
                self.apply(**options)
        self.assertEqual(self.results(), [])
        self.assertEqual(self.env.read_bytes(), self.before)

    def test_refuses_unrelated_source_service_and_foreign_target(self):
        for section, field, value in (("sources", "contentVersion", "1.25.99"), ("services", "docs", self.pg("other")),
                                      ("target", "environment", "development"),
                                      ("target", "nodeId", "11111111-1111-4111-8111-111111111111")):
            with self.subTest(field=field), patch.dict(self.candidate[section], {field: value}):
                with self.assertRaises(release.ManifestError):
                    self.apply()
        self.assertEqual(self.results(), [])

    def test_refuses_changed_previous_manifest_override_or_marker(self):
        for path, bad in ((self.selected, b"{}"), (self.override, b"{}"),
                          (self.env, self.before.replace(str(self.selected).encode(), b"/other"))):
            original = path.read_bytes()
            try:
                path.write_bytes(bad)
                with self.subTest(path=path), self.assertRaises(release.ManifestError):
                    self.apply()
            finally:
                path.write_bytes(original)
        self.assertEqual(self.results(), [])

    def test_blocks_unverified_previous_image_or_observed_runtime(self):
        self.engine.runtime = deepcopy(self.previous)
        with self.assertRaisesRegex(release.ManifestError, "Runtime image"):
            self.apply()
        self.engine.runtime = deepcopy(self.candidate)
        del self.engine.images[self.previous["services"]["fua-generator-db"]["image"]]
        with self.assertRaisesRegex(release.ManifestError, "Image unavailable"):
            self.apply()
        self.assertEqual(self.results(), [])
        self.assertEqual(self.env.read_bytes(), self.before)

    def test_postselection_failure_marks_attempt(self):
        with self.assertRaisesRegex(release.ManifestError, "continuity"):
            self.apply(verify=Mock(return_value=False))
        self.assertEqual(self.results()[0]["operation"], "reconcile")
        self.assertEqual(self.results()[0]["status"], "failed-or-interrupted")
        self.assertEqual(next(self.selected.parent.glob("*/before.env")).read_bytes(), self.before)
