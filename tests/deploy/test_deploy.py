"""Version updates, bounded recreation and recovery without a Docker daemon."""

from contextlib import contextmanager
from copy import deepcopy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

from test_release_manifest import ROOT, Engine, fixture, release, digest

SPEC = importlib.util.spec_from_file_location("deploy", ROOT / "scripts/deploy/deploy.py")
deploy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(deploy)
deploy.releases = release


class ComponentUpdate(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        (self.root / "docker-compose.yml").write_text("services: {}\n")
        (self.root / ".gitignore").write_text(".env\n.env.release-state/\n")
        for command in (["git", "init", "-q"], ["git", "add", "."],
                        ["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture"]):
            subprocess.run(command, cwd=self.root, check=True, capture_output=True)
        self.current = fixture()
        self.current["sources"]["distroCommit"] = release.run(["git", "rev-parse", "HEAD"], root=self.root).strip()
        self.target = deepcopy(self.current)
        self.target["releaseId"] = "frontend-update"
        second = fixture("second")
        self.target["services"]["frontend"] = second["services"]["frontend"]
        self.target["sources"]["frontend"] = second["sources"]["frontend"]
        self.state = self.root / ".env.release-state"
        self.state.mkdir(mode=0o700)
        self.select(self.current)
        self.before = (self.root / ".env").read_bytes()
        self.engine = Engine(self.current, self.target)
        self.real_subprocess = subprocess.run
        self.fail_once = False
        self.addCleanup(patch.stopall)
        patch.object(release, "run", self.engine.run).start()
        patch.object(release.subprocess, "run", self.execute).start()

    def select(self, version):
        checksum = release.manifest_digest(version)
        path = self.state / f"{checksum}.json"
        release.persist_immutable(path, version)
        release.persist_immutable(self.state / f"{checksum}.compose.json", release.compose_override(version))
        files = [str(self.root / p) for p in version["compose"]["files"]] + [str(self.state / f"{checksum}.compose.json")]
        (self.root / ".env").write_text(release.select_manifest("SECRET=keep-private\n", {
            "DEPLOYMENT_ENV": "qlty", "COMPOSE_FILE": ":".join(files), "COMPOSE_PROFILES": "",
            "SIHSALUS_NODE_ID": version["target"]["nodeId"], "SIHSALUS_RELEASE_MANIFEST": str(path),
            "DOCKER_DEFAULT_PLATFORM": "linux/amd64"}))

    def execute(self, command, **kwargs):
        if command[:2] == ["docker", "compose"] and "up" in command:
            self.engine.calls.append(command)
            selected = json.loads(Path(kwargs["env"]["SIHSALUS_RELEASE_MANIFEST"]).read_text())
            components = command[command.index("--wait-timeout") + 2:]
            for name in components:
                self.engine.runtime["services"][name] = deepcopy(selected["services"][name])
            self.engine.runtime["sources"] = deepcopy(selected["sources"])
            failed = self.fail_once
            self.fail_once = False
            return subprocess.CompletedProcess(command, int(failed))
        return self.real_subprocess(command, **kwargs)

    def up_commands(self):
        return [c for c in self.engine.calls if c[:2] == ["docker", "compose"] and "up" in c]

    @contextmanager
    def frontend_candidate(self, source=None):
        def build(candidate, root):
            candidate["services"]["frontend"] = deepcopy(self.target["services"]["frontend"])

        with patch.object(deploy, "health"), \
             patch.object(deploy, "resolve", return_value=deepcopy(source or self.target["sources"]["frontend"])) as resolve, \
             patch.object(deploy, "build_frontend", side_effect=build):
            yield resolve

    def test_frontend_update_preserves_every_other_runtime_and_secret(self):
        release.apply_release(self.target, self.current, self.root, services=["frontend"])
        self.assertEqual(len(self.up_commands()), 1)
        command = self.up_commands()[0]
        self.assertIn("--no-deps", command)
        self.assertIn("--no-build", command)
        self.assertEqual(command[-1], "frontend")
        for name in self.current["services"]:
            if name != "frontend":
                self.assertEqual(self.engine.runtime["services"][name], self.current["services"][name])
        self.assertIn("SECRET=keep-private", (self.root / ".env").read_text())
        self.assertEqual(deploy.env_value(self.root, "FRONTEND_RUNTIME_IMAGE"), "sihsalus-release-retained")
        self.assertEqual(deploy.env_value(self.root, "FRONTEND_RUNTIME_TAG"), release.manifest_digest(self.target)[:48] + "-frontend")
        self.assertEqual(deploy.current_release(self.root), self.target)
        self.assertEqual(deploy.previous_release(self.target, self.root), self.current)

    def test_component_update_refuses_changes_to_database_before_docker(self):
        self.target["services"]["db"] = fixture("other")["services"]["db"]
        with self.assertRaisesRegex(release.ManifestError, "unrelated"):
            release.apply_release(self.target, self.current, self.root, services=["frontend"])
        self.assertFalse(self.engine.calls)
        self.assertEqual((self.root / ".env").read_bytes(), self.before)

    def test_empty_component_selection_cannot_recreate_all_services(self):
        with self.assertRaises(release.ManifestError):
            release.apply_release(self.current, self.current, self.root, services=[])
        self.assertFalse(self.engine.calls)

    def test_backend_update_recreates_only_backend(self):
        target = deepcopy(self.current)
        target["releaseId"] = "backend-update"
        target["services"]["backend"]["imageId"] = digest("new-backend")
        image = deepcopy(self.engine.images[target["services"]["backend"]["image"]])
        image["id"] = target["services"]["backend"]["imageId"]
        # Different immutable source is required; old source remains available for recovery.
        source = target["sources"]["backend"]
        source["image"] = source["image"].split("@")[0] + "@" + digest("new-backend-source")
        target["services"]["backend"]["image"] = source["image"]
        self.engine.images[source["image"]] = image
        self.engine.images[image["id"]] = image
        self.engine.metadata[image["id"]] = "content.sihsalus-content=" + target["sources"]["contentVersion"] + "\n"
        with patch.object(deploy, "health"), patch.object(deploy, "resolve", return_value=source) as resolve:
            outcome = deploy.execute_update(self.root, "backend")
        self.assertEqual(outcome["status"], "updated")
        self.assertEqual(outcome["candidate"]["sources"]["backend"], source)
        resolve.assert_called_once_with("backend", "latest", None, self.root, "linux/amd64")
        self.assertEqual(len(self.up_commands()), 1)
        self.assertEqual(self.up_commands()[0][-1], "backend")
        self.assertEqual(self.engine.runtime["services"]["db"], self.current["services"]["db"])

    def test_health_failure_automatically_recovers_only_frontend(self):
        self.fail_once = True
        with release.release_lock(self.root) as state:
            with self.assertRaises(release.ManifestError):
                deploy.apply(self.target, self.current, self.root, state, ["frontend"], None)
        self.assertEqual(len(self.up_commands()), 2)
        self.assertTrue(all(c[-1] == "frontend" and "--no-deps" in c for c in self.up_commands()))
        self.assertEqual(self.engine.runtime["services"], self.current["services"])
        self.assertEqual(deploy.current_release(self.root)["sources"], self.current["sources"])

    def test_external_failure_recovers_after_successful_internal_health(self):
        with patch.object(deploy, "verify_external", side_effect=[release.ManifestError("External verification failed"), None]):
            with release.release_lock(self.root) as state:
                with self.assertRaises(release.ManifestError):
                    deploy.apply(self.target, self.current, self.root, state, ["frontend"], "https://example.invalid")
        self.assertEqual(len(self.up_commands()), 2)
        self.assertEqual(self.engine.runtime["services"], self.current["services"])

        results = [release.read_json(path) for path in deploy.history(self.root)]
        self.assertEqual([item["status"] for item in results if item["operation"] == "deploy"], ["failed-or-interrupted"])
        with self.assertRaisesRegex(release.ManifestError, "already recovered"):
            deploy.previous_release(deploy.current_release(self.root), self.root)

    def test_preparation_failure_does_not_trigger_a_restart(self):
        del self.engine.images[self.target["services"]["frontend"]["image"]]
        with release.release_lock(self.root) as state:
            with self.assertRaises(release.ManifestError):
                deploy.apply(self.target, self.current, self.root, state, ["frontend"], None)
        self.assertFalse(self.up_commands())
        self.assertEqual((self.root / ".env").read_bytes(), self.before)

    def test_operations_checkout_can_advance_but_runtime_configuration_cannot(self):
        (self.root / "README.md").write_text("Updated operations guide\n")
        self.real_subprocess(["git", "add", "README.md"], cwd=self.root, check=True, capture_output=True)
        self.real_subprocess(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "docs"], cwd=self.root, check=True, capture_output=True)
        self.assertEqual(deploy.current_release(self.root), self.current)
        (self.root / "docker-compose.yml").write_text("services: {different: {}}\n")
        with self.assertRaises(release.ManifestError):
            deploy.current_release(self.root)
        self.assertFalse(self.up_commands())

    def test_invalid_versions_and_digest_mismatch_never_pull(self):
        for version, expected in [("candidate-unreviewed", None), ("latest", "bad-digest")]:
            with self.assertRaises(release.ManifestError):
                deploy.resolve("frontend", version, expected, self.root, "linux/amd64")
        with patch.object(release, "run", return_value=digest("published")) as run:
            with self.assertRaisesRegex(release.ManifestError, "selected digest"):
                deploy.resolve("frontend", "latest", digest("different"), self.root, "linux/amd64")
            self.assertEqual(run.call_count, 1)

    def test_concurrent_operation_is_rejected(self):
        with release.release_lock(self.root):
            with self.assertRaises(release.ManifestError):
                release.apply_release(self.target, self.current, self.root, services=["frontend"])
        self.assertFalse(self.up_commands())

    def test_prepare_command_builds_without_changing_selection_or_runtime(self):
        def build(candidate, root):
            candidate["services"]["frontend"] = self.target["services"]["frontend"]

        arguments = ["deploy.py", "--root", str(self.root), "update", "--frontend", "latest", "--prepare"]
        with patch.object(deploy.sys, "argv", arguments), patch.object(deploy, "health"), \
             patch.object(deploy, "resolve", return_value=self.target["sources"]["frontend"]), \
             patch.object(deploy, "build_frontend", side_effect=build):
            deploy.main()
        self.assertFalse(self.up_commands())
        self.assertEqual((self.root / ".env").read_bytes(), self.before)
        self.assertEqual(self.engine.runtime, self.current)

    def test_healthy_same_version_does_not_build_or_restart_even_with_low_disk(self):
        arguments = ["deploy.py", "--root", str(self.root), "update", "--frontend", "latest"]
        with patch.object(deploy.sys, "argv", arguments), patch.object(deploy, "health"), \
             patch.object(deploy, "resolve", return_value=self.current["sources"]["frontend"]), \
             patch.object(deploy, "build_frontend") as build, \
             patch.object(deploy.shutil, "disk_usage") as disk:
            disk.return_value.free = 0
            deploy.main()
            build.assert_not_called()
        self.assertFalse(self.up_commands())
        self.assertEqual((self.root / ".env").read_bytes(), self.before)

    def test_cancelled_api_update_validates_but_never_backs_up_or_applies(self):
        order = []
        validate = Mock(side_effect=lambda *args: order.append("validated"))
        confirm = Mock(side_effect=lambda *args: order.append("confirmed") or False)
        backup = Mock()
        with self.frontend_candidate():
            outcome = deploy.execute_update(self.root, "frontend", validate_candidate=validate,
                                            confirm=confirm, before_apply=backup)
        self.assertEqual(outcome["status"], "cancelled")
        self.assertEqual(order, ["validated", "confirmed"])
        self.assertEqual(validate.call_args.args, (outcome["current"], outcome["candidate"], "frontend"))
        self.assertEqual(confirm.call_args.args, validate.call_args.args)
        backup.assert_not_called()
        self.assertFalse(self.up_commands())
        self.assertEqual((self.root / ".env").read_bytes(), self.before)
        self.assertEqual(self.engine.runtime, self.current)

    def test_unchanged_version_still_requires_candidate_validation(self):
        confirm, backup = Mock(), Mock()
        validate = Mock(side_effect=release.ManifestError("Published image is no longer allowed"))
        with self.frontend_candidate(self.current["sources"]["frontend"]) as resolve:
            with self.assertRaisesRegex(release.ManifestError, "no longer allowed"):
                deploy.execute_update(self.root, "frontend", validate_candidate=validate,
                                      confirm=confirm, before_apply=backup)
        resolve.assert_called_once()
        validate.assert_called_once()
        confirm.assert_not_called()
        backup.assert_not_called()
        self.assertFalse(self.up_commands())
        self.assertEqual((self.root / ".env").read_bytes(), self.before)

    def test_prepare_api_validates_without_confirmation_backup_or_application(self):
        validate, confirm, backup = Mock(), Mock(), Mock()
        with self.frontend_candidate():
            outcome = deploy.execute_update(self.root, "frontend", prepare_only=True,
                                            validate_candidate=validate, confirm=confirm, before_apply=backup)
        self.assertEqual(outcome["status"], "prepared")
        validate.assert_called_once()
        confirm.assert_not_called()
        backup.assert_not_called()
        self.assertFalse(self.up_commands())
        self.assertEqual((self.root / ".env").read_bytes(), self.before)
        self.assertEqual(self.engine.runtime, self.current)

    def test_update_keeps_one_selection_and_lock_through_confirmation_and_backup(self):
        order = []
        original_lock = release.release_lock
        selected = None
        backup_open = False

        def check_selection(current, candidate, component):
            self.assertEqual(release.manifest_digest(candidate), selected)
            self.assertEqual(candidate["sources"]["frontend"], self.target["sources"]["frontend"])
            self.assertEqual((self.root / ".env").read_bytes(), self.before)
            self.assertFalse(self.up_commands())
            with self.assertRaisesRegex(release.ManifestError, "Another manifest operation"):
                with original_lock(self.root):
                    self.fail("The update lock was released during operator callbacks")
            # The mutable registry alias moves while an operator reviews the
            # preview; this must not change the already prepared target.
            resolve.return_value = deepcopy(self.current["sources"]["frontend"])

        def validate(current, candidate, component):
            nonlocal selected
            selected = release.manifest_digest(candidate)
            order.append("validated")

        def confirm(*args):
            check_selection(*args)
            order.append("confirmed")
            return True

        @contextmanager
        def receipt():
            nonlocal backup_open
            backup_open = True
            order.append("backup-open")
            try:
                yield
            finally:
                order.append("backup-closed")
                backup_open = False

        def backup(*args):
            check_selection(*args)
            return receipt()

        def event(stage, message):
            self.assertNotIn("keep-private", message)
            if stage == "applying":
                self.assertTrue(backup_open)
                order.append("applying")

        with self.frontend_candidate() as resolve, patch.object(release, "release_lock", wraps=original_lock) as lock:
            outcome = deploy.execute_update(self.root, "frontend", validate_candidate=validate,
                                            confirm=confirm, before_apply=backup, event=event)
        resolve.assert_called_once_with("frontend", "latest", None, self.root, "linux/amd64")
        lock.assert_called_once_with(self.root)
        self.assertEqual(outcome["status"], "updated")
        self.assertEqual(order, ["validated", "confirmed", "backup-open", "applying", "backup-closed"])
        self.assertEqual(release.manifest_digest(outcome["candidate"]), selected)
        self.assertEqual(deploy.current_release(self.root), outcome["candidate"])
        self.assertEqual(len(self.up_commands()), 1)
        self.assertEqual(self.engine.runtime["services"]["frontend"], self.target["services"]["frontend"])
        self.assertEqual(self.engine.runtime["services"]["backend"], self.current["services"]["backend"])

    def test_backup_failure_prevents_application(self):
        for backup in (Mock(side_effect=release.ManifestError("Backup verification failed")),
                       Mock(return_value=False)):
            with self.subTest(backup=backup), self.frontend_candidate():
                with self.assertRaises(release.ManifestError):
                    deploy.execute_update(self.root, "frontend", confirm=lambda *args: True, before_apply=backup)
            self.assertFalse(self.up_commands())
            self.assertEqual((self.root / ".env").read_bytes(), self.before)
            self.assertEqual(self.engine.runtime, self.current)

    def test_backup_context_is_closed_when_application_fails(self):
        states = []

        @contextmanager
        def receipt():
            states.append("opened")
            try:
                yield
            finally:
                states.append("closed")

        with self.frontend_candidate(), patch.object(deploy, "apply", side_effect=release.ManifestError("Apply failed")):
            with self.assertRaisesRegex(release.ManifestError, "Apply failed"):
                deploy.execute_update(self.root, "frontend", before_apply=lambda *args: receipt())
        self.assertEqual(states, ["opened", "closed"])
        self.assertEqual((self.root / ".env").read_bytes(), self.before)

    def test_backup_cleanup_cannot_report_a_suppressed_apply_error_as_success(self):
        class SuppressingReceipt:
            def __enter__(self):
                return self

            def __exit__(self, *error):
                return True

        with self.frontend_candidate(), patch.object(deploy, "apply", side_effect=release.ManifestError("Apply failed")):
            with self.assertRaisesRegex(release.ManifestError, "did not complete"):
                deploy.execute_update(self.root, "frontend", before_apply=lambda *args: SuppressingReceipt())
        self.assertEqual((self.root / ".env").read_bytes(), self.before)

    def test_callback_cannot_replace_the_prepared_release(self):
        def mutate(current, candidate, component):
            candidate["sources"]["frontend"] = deepcopy(current["sources"]["frontend"])
            return True

        for callback in ("validate_candidate", "confirm", "before_apply"):
            with self.subTest(callback=callback), self.frontend_candidate():
                with self.assertRaisesRegex(release.ManifestError, "changed the selected release"):
                    deploy.execute_update(self.root, "frontend", **{callback: mutate})
            self.assertFalse(self.up_commands())
            self.assertEqual((self.root / ".env").read_bytes(), self.before)

    def test_backend_failure_does_not_silently_downgrade_a_migrated_database(self):
        self.fail_once = True
        # Fail at the mutation boundary, preserving a failed journal for recovery.
        with patch.object(release, "apply_release", side_effect=release.ManifestError("backend failed")) as apply:
            with release.release_lock(self.root) as state:
                with self.assertRaises(release.ManifestError):
                    deploy.apply(self.target, self.current, self.root, state, ["backend"], None)
            self.assertEqual(apply.call_count, 1)


if __name__ == "__main__":
    unittest.main()
