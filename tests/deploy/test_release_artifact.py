"""External release artifacts retain the source-history and Compose checks."""

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from test_release_manifest import ROOT, fixture, release


SPEC = importlib.util.spec_from_file_location("release_compose", ROOT / "tests/deploy/release-manifest-compose.py")
compose = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(compose)


class ReleaseArtifact(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name) / "source"
        self.root.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release@example.invalid")
        (self.root / "docker-compose.yml").write_text("services: {}\n")
        self.git("add", ".")
        self.git("commit", "-qm", "reviewed source")
        self.manifest = fixture()
        self.manifest["sources"]["distroCommit"] = self.git("rev-parse", "HEAD")
        self.path = self.root.parent / "release-manifest.json"
        self.env = self.root.parent / "synthetic.env"
        self.env.write_text(compose.SYNTHETIC_ENV)

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True, stderr=subprocess.PIPE).strip()

    def verify(self):
        self.path.write_text(json.dumps(self.manifest))
        with patch.object(compose, "ROOT", self.root):
            compose.exercise_manifest(self.path, self.env)

    def test_external_artifact_uses_exact_historical_checkout(self):
        (self.root / "later.txt").write_text("later source\n")
        self.git("add", ".")
        self.git("commit", "-qm", "later source")
        observed = []

        def check(manifest, checkout, env):
            observed.append(self.git("-C", str(checkout), "rev-parse", "HEAD"))
            self.assertEqual(env, self.env)
            self.assertEqual(manifest, self.manifest)

        with patch.object(release, "verify_compose", side_effect=check):
            self.verify()
        self.assertEqual(observed, [self.manifest["sources"]["distroCommit"]])
        self.assertEqual(self.git("worktree", "list", "--porcelain").count("worktree "), 1)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_unmerged_source_rejected_before_compose(self):
        reviewed = self.git("rev-parse", "HEAD")
        self.git("checkout", "-qb", "unreviewed")
        (self.root / "unreviewed.txt").write_text("unreviewed source\n")
        self.git("add", ".")
        self.git("commit", "-qm", "unreviewed source")
        self.manifest["sources"]["distroCommit"] = self.git("rev-parse", "HEAD")
        self.git("checkout", "--detach", reviewed)
        with patch.object(release, "verify_compose") as check:
            with self.assertRaises(release.ManifestError):
                self.verify()
            check.assert_not_called()
        self.assertEqual(self.git("worktree", "list", "--porcelain").count("worktree "), 1)

    def test_invalid_compose_fails_and_removes_temporary_checkout(self):
        with patch.object(release, "verify_compose", side_effect=release.ManifestError("Missing service")):
            with self.assertRaisesRegex(release.ManifestError, "Missing service"):
                self.verify()
        self.assertEqual(self.git("worktree", "list", "--porcelain").count("worktree "), 1)


if __name__ == "__main__":
    unittest.main()
