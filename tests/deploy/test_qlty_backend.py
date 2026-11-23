import importlib.util
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
    spec = importlib.util.spec_from_file_location("qlty_backend", DIRECTORY / "deploy-qlty-backend.py")
    qlty = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(qlty)
finally:
    sys.path.pop(0)


def git(root, *args):
    return subprocess.run(["git", *args], cwd=root, check=True, capture_output=True, text=True).stdout.strip()


def source(sha, digit="1"):
    return {"commit": sha, "image": f"ghcr.io/sihsalus/sihsalus-backend:sha-{sha}@sha256:{digit * 64}"}


class QltyBackendTests(unittest.TestCase):
    def setUp(self):
        temporary = TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.target = {"nodeId": qlty.QLTY_NODE, "environment": "qlty"}
        self.sha = "a" * 40
        self.digest = "sha256:" + "1" * 64
        self.current = {"target": self.target, "sources": {"backend": source(self.sha),
                                                          "frontend": {"commit": "b" * 40}}}

    def test_wrong_host_or_mutable_reference_rejected_before_engine(self):
        with patch.object(qlty.deploy, "execute_update") as engine:
            for sha, digest, env, node in [(self.sha, self.digest, "production", qlty.QLTY_NODE),
                                          (self.sha, self.digest, "qlty", "wrong"),
                                          ("latest", self.digest, "qlty", qlty.QLTY_NODE),
                                          (self.sha, "bad", "qlty", qlty.QLTY_NODE)]:
                with self.subTest(sha=sha, digest=digest, env=env, node=node):
                    with patch.object(qlty.deploy, "env_value", side_effect=[env, node]):
                        with self.assertRaises(qlty.release.ManifestError):
                            qlty.update(self.root, sha, digest)
            engine.assert_not_called()

    def test_engine_hooks_verify_noop_and_require_backup_for_change(self):
        with patch.object(qlty.deploy, "env_value", side_effect=["qlty", qlty.QLTY_NODE]), \
             patch.object(qlty.deploy, "execute_update", return_value={"status": "unchanged", "candidate": self.current}) as engine:
            qlty.update(self.root, self.sha, self.digest)
        self.assertEqual(engine.call_args.args, (self.root, "backend", self.sha))
        hooks = engine.call_args.kwargs
        self.assertEqual(hooks["expected_digest"], self.digest)
        self.assertEqual(hooks["public_url"], qlty.QLTY_URL)
        with patch.object(qlty, "check_order"), patch.object(qlty, "check_history"), \
             patch.object(qlty.deploy, "verify_external") as verify, patch.object(qlty, "check_compatibility") as compatibility:
            hooks["validate_candidate"](self.current, self.current, "backend")
            verify.assert_called_once_with(self.current, self.root, qlty.QLTY_URL)
            compatibility.assert_not_called()
            newer = {**self.current, "sources": {"backend": source("c" * 40)}}
            hooks["validate_candidate"](self.current, newer, "backend")
            compatibility.assert_called_once()
            with self.assertRaises(qlty.release.ManifestError):
                hooks["validate_candidate"]({**self.current, "target": {"environment": "production"}}, newer, "backend")
        with patch.object(subprocess, "run", side_effect=subprocess.CalledProcessError(1, "backup")) as backup:
            with self.assertRaises(subprocess.CalledProcessError):
                hooks["before_apply"](self.current, newer, "backend")
        backup.assert_called_once_with(["bash", str(DIRECTORY / "qlty-pre-backend-backup.sh")], cwd=self.root, check=True)

    def test_incomplete_journal_blocks_noop_and_frontend_success_cannot_mask_failed_backend(self):
        state = self.root / ".env.release-state"
        state.mkdir()
        qlty.check_history(self.root, self.current)
        failed = state / "first"
        failed.mkdir()
        with self.assertRaisesRegex(qlty.release.ManifestError, "Incomplete"):
            qlty.check_history(self.root, self.current)
        changed_backend = {**self.current, "sources": {"backend": source("c" * 40)}}
        for name, data in [("previous", changed_backend), ("target", self.current)]:
            (failed / f"{name}.json").write_text(json.dumps(data))
        checksum = qlty.release.manifest_digest(self.current)
        for status in ("applying", "failed-or-interrupted"):
            (failed / "result.json").write_text(json.dumps({"status": status, "target": checksum}))
            with self.assertRaisesRegex(qlty.release.ManifestError, "unresolved"):
                qlty.check_history(self.root, self.current)
        frontend = state / "second"
        frontend.mkdir()
        for name in ("previous", "target"):
            (frontend / f"{name}.json").write_text(json.dumps(self.current))
        (frontend / "result.json").write_text(json.dumps({"status": "verified", "target": checksum}))
        with self.assertRaisesRegex(qlty.release.ManifestError, "backend change"):
            qlty.check_history(self.root, self.current)
        # A verified coordinated backend recovery supersedes the failed attempt.
        (frontend / "previous.json").write_text(json.dumps(changed_backend))
        qlty.check_history(self.root, self.current)

    def init(self):
        git(self.root, "init", "--quiet", "-b", "main")
        git(self.root, "config", "user.email", "fixture@example.invalid")
        git(self.root, "config", "user.name", "QLTY Fixture")

    def commit(self, message):
        git(self.root, "add", ".")
        git(self.root, "commit", "--quiet", "--allow-empty", "-m", message)
        return git(self.root, "rev-parse", "HEAD")

    def test_ancestry_uses_main_and_leaves_checked_out_sha_intact(self):
        self.init()
        first = self.commit("installed")
        second = self.commit("next")
        git(self.root, "switch", "--quiet", "-c", "unpublished")
        branch = self.commit("branch")
        git(self.root, "checkout", "--quiet", "--detach", first)
        with patch.object(qlty, "REPOSITORY", str(self.root)):
            qlty.check_order(self.root, source(first), source(second))
            qlty.check_order(self.root, source(second), source(second))
            for previous, requested in [(source(second), source(first)), (source(first), source(branch)),
                                        (source(second), source(second, "2"))]:
                with self.subTest(requested=requested), self.assertRaises(qlty.release.ManifestError):
                    qlty.check_order(self.root, previous, requested)
        self.assertEqual(git(self.root, "rev-parse", "HEAD"), first)

    def test_real_compose_allows_unrelated_service_and_log_rotation_but_checks_dependencies_and_mounts(self):
        try:
            subprocess.run(["docker", "compose", "version"], check=True, capture_output=True)
        except (OSError, subprocess.CalledProcessError):
            self.skipTest("Docker Compose plugin unavailable")
        self.init()
        (self.root / ".gitignore").write_text(".env\n")
        (self.root / ".env").write_text("DB_VALUE=synthetic\n")
        compose = self.root / "docker-compose.yml"
        bind = self.root / "db-init.sh"
        bind.write_text("# initial fixture\n")
        base = """services:
  backend:
    image: busybox
    depends_on: [db]
  db:
    image: mariadb
    environment:
      CONTRACT: ${DB_VALUE}
    volumes:
      - ./db-init.sh:/fixture:ro
  frontend:
    image: busybox:stable
"""
        compose.write_text(base)
        baseline = self.commit("installed")
        rotated = base.replace("depends_on: [db]", "depends_on: [db]\n    logging:\n      driver: json-file\n      options: {max-size: 10m, max-file: '3'}")
        compose.write_text(rotated.replace("busybox:stable", "busybox:latest"))
        compatible = self.commit("unrelated frontend and backend logging")
        bind.write_text("# changed dependency\n")
        incompatible_bind = self.commit("different mounted database configuration")
        bind.write_text("# initial fixture\n")
        compose.write_text(base.replace("${DB_VALUE}", "incompatible"))
        incompatible_db = self.commit("different database settings")
        compose.write_text(base.replace("depends_on: [db]", "depends_on: [db]\n    logging: {driver: local}"))
        incompatible_driver = self.commit("different logging driver")
        git(self.root, "checkout", "--detach", baseline)
        model = {
            "target": self.target, "compose": {"files": ["docker-compose.yml"], "project": "qlty-test",
                                             "profiles": [], "platform": "linux/amd64"}
        }
        run = qlty.release.run

        def local(command, **kwargs):
            if command[:2] == ["docker", "info"]:
                return "json-file"
            return run(command, **kwargs)

        with patch.object(qlty.release, "run", side_effect=local):
            qlty.check_compatibility(self.root, model, compatible)
            for sha in [incompatible_bind, incompatible_db, incompatible_driver]:
                with self.subTest(sha=sha), self.assertRaisesRegex(qlty.release.ManifestError, "coordinated change"):
                    qlty.check_compatibility(self.root, model, sha)
        self.assertEqual(git(self.root, "rev-parse", "HEAD"), baseline)


if __name__ == "__main__":
    unittest.main()
