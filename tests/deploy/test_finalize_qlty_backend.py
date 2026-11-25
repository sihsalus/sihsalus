"""Recovery is verifiable and append-only for the selected failed backend edge."""
from contextlib import ExitStack
from copy import deepcopy
from importlib import util
import os
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
from uuid import uuid4

from test_release_manifest import digest, fixture


DIRECTORY = Path(__file__).resolve().parents[2] / "scripts/deploy"
sys.path.insert(0, str(DIRECTORY))
try:
    spec = util.spec_from_file_location("finalize_qlty_backend", DIRECTORY / "finalize-qlty-backend.py")
    tool = util.module_from_spec(spec)
    spec.loader.exec_module(tool)
finally:
    sys.path.pop(0)


class FinalizeTests(unittest.TestCase):
    def setUp(self):
        self.context = ExitStack()
        self.addCleanup(self.context.close)
        self.root = Path(self.context.enter_context(TemporaryDirectory())).resolve()
        self.state = self.root / ".env.release-state"
        self.state.mkdir(mode=0o700)
        self.previous = fixture()
        self.previous["target"]["nodeId"] = tool.qlty.QLTY_NODE
        self.target = deepcopy(self.previous)
        self.sha = "e" * 40
        self.digest = digest("approved")
        image = f"ghcr.io/sihsalus/sihsalus-backend:sha-{self.sha}@{self.digest}"
        self.target["sources"]["backend"] = {"commit": self.sha, "image": image}
        self.target["services"]["backend"] = {"image": image, "imageId": digest("runtime")}
        self.previous_hash = tool.release.manifest_digest(self.previous)
        self.attempt = str(uuid4())
        self.prior = str(uuid4())
        self.token = "12345-2-backend-qlty"
        self.backup = "verified-20261124T010208Z-12345678"
        self.install()
        mac = self.root / "adapter-address"
        mac.write_text("00:0c:29:1c:f7:78\n")
        self.mock(tool, "MAC_PATH", new=mac)
        self.mock(tool.deploy, "checked_root", return_value=self.root)
        self.mock(tool.release, "verify_selected_compose")
        self.images = self.mock(tool.release, "verify_images")
        self.retained = self.mock(tool, "verify_recovery_images")
        self.instance = self.mock(tool, "backend_instance", return_value={"containerId": "f" * 64, "imageId": digest("runtime"),
                                                                        "startedAt": "2026-11-24T01:03:00Z"})
        self.mock(tool.deploy, "source_image", return_value=self.target["sources"]["backend"])
        self.runtime = self.mock(tool.release, "verify_runtime")
        self.health = self.mock(tool.deploy, "health")
        self.public = self.mock(tool.deploy, "verify_external")
        self.receipt = self.mock(tool, "verify_backup", return_value={"backup": self.backup, "sha256": "4" * 64})
        self.mock(tool.release, "apply_release", side_effect=AssertionError("Unexpected deployment"))

    def mock(self, obj, key, **kwargs):
        return self.context.enter_context(patch.object(obj, key, **kwargs))

    def journal(self, name, previous, target, status):
        journal = self.state / name
        journal.mkdir(mode=0o700, exist_ok=True)
        result = {"operation": "deploy", "status": status, "previous": tool.release.manifest_digest(previous),
                  "target": tool.release.manifest_digest(target)}
        for key, value in (("previous", previous), ("target", target), ("result", result)):
            (journal / f"{key}.json").write_bytes(tool.release.canonical_bytes(value))
        return journal / "result.json"

    def install(self):
        self.target_hash = tool.release.manifest_digest(self.target)
        for checksum, manifest in ((self.previous_hash, self.previous), (self.target_hash, self.target)):
            (self.state / f"{checksum}.json").write_bytes(tool.release.canonical_bytes(manifest))
            (self.state / f"{checksum}.compose.json").write_bytes(tool.release.canonical_bytes(tool.release.compose_override(manifest)))
        for name, before, after, status, timestamp in [(self.prior, self.previous, self.previous, "verified", 10),
                                                        (self.attempt, self.previous, self.target, "failed-or-interrupted", 20)]:
            result = self.journal(name, before, after, status)
            os.utime(result, (timestamp, timestamp))
        node = self.target["target"]["nodeId"]
        (self.root / ".env").write_text(f"DEPLOYMENT_ENV=qlty\nSIHSALUS_NODE_ID={node}\n"
                                        f"SIHSALUS_RELEASE_MANIFEST={self.state}/{self.target_hash}.json\n")
        (self.state / self.attempt / "before.env").write_text(f"SIHSALUS_RELEASE_MANIFEST={self.state}/{self.previous_hash}.json\n")

    def finalize(self, apply=True, **overrides):
        arguments = dict(attempt=self.attempt, previous=self.previous_hash, target=self.target_hash, sha=self.sha,
                         digest=self.digest, run_token=self.token, backup=self.backup)
        arguments.update(overrides)
        return tool.finalize(self.root, **arguments, apply=apply)

    def journals(self):
        return set(self.state.glob("*/result.json"))

    def test_verified_recovery_visible_to_existing_history_preserves_failed_journal(self):
        failed = self.state / self.attempt
        before = {path: path.read_bytes() for path in failed.iterdir()}
        env = (self.root / ".env").read_bytes()
        original = self.journals()
        with self.assertRaises(tool.release.ManifestError):
            tool.qlty.check_history(self.root, self.target)
        self.finalize(apply=False)
        self.assertEqual(self.journals(), original)
        self.finalize()
        entry, = self.journals() - original
        result = tool.release.read_json(entry)
        self.assertEqual((result["operation"], result["status"], result["previous"], result["target"]),
                         ("verify-recovery", "verified", self.previous_hash, self.target_hash))
        self.assertEqual(result["attempt"], self.attempt)
        self.assertEqual(result["backup"], self.receipt.return_value)
        for key in ("previous", "target"):
            self.assertEqual((entry.parent / f"{key}.json").read_bytes(), before[failed / f"{key}.json"])
        tool.qlty.check_history(self.root, self.target)
        self.finalize()
        self.assertEqual(self.journals(), original | {entry})
        self.assertEqual({path: path.read_bytes() for path in failed.iterdir()}, before)
        self.assertEqual((self.root / ".env").read_bytes(), env)
        self.retained.assert_any_call(self.root, self.previous)
        self.images.assert_any_call(self.target, self.root)
        self.runtime.assert_any_call(self.target, self.root)
        self.public.assert_any_call(self.target, self.root, tool.qlty.QLTY_URL)

    def test_later_failure_or_incomplete_journal_cannot_be_skipped(self):
        self.finalize()
        new = str(uuid4())
        (self.state / new).mkdir(mode=0o700)
        newest = max(path.stat().st_mtime_ns for path in self.journals()) + 1_000_000_000
        os.utime(self.state / new, ns=(newest, newest))
        for outcome in (None, "failed-or-interrupted"):
            with self.subTest(outcome=outcome):
                if outcome:
                    result = self.journal(new, self.target, self.previous, outcome)
                    os.utime(result, ns=(newest, newest))
                count = self.journals()
                with self.assertRaises(tool.release.ManifestError):
                    self.finalize()
                self.assertEqual(self.journals(), count)
                with self.assertRaises(tool.release.ManifestError):
                    tool.qlty.check_history(self.root, self.target)

    def test_wrong_machine_or_replaced_container_cannot_be_verified(self):
        original = self.journals()
        with patch.object(tool, "MAC_PATH", self.root / "wrong-address"):
            tool.MAC_PATH.write_text("00:00:00:00:00:00\n")
            with self.assertRaises(tool.release.ManifestError):
                self.finalize()
        initial = self.instance.return_value
        self.instance.side_effect = [initial, {**initial, "containerId": "e" * 64}]
        with self.assertRaises(tool.release.ManifestError):
            self.finalize()
        self.assertEqual(self.journals(), original)

    def test_refuses_wrong_pins_unverified_predecessor_and_unrelated_change(self):
        original = self.journals()
        for argument in ({"attempt": self.prior}, {"previous": "8" * 64}, {"target": "9" * 64},
                         {"sha": "9" * 40}, {"digest": digest("other")}):
            with self.subTest(argument=argument), self.assertRaises(tool.release.ManifestError):
                self.finalize(**argument)
        for service in ("gateway", "db"):
            with self.subTest(service=service):
                self.target["services"][service] = {"image": digest("other"), "imageId": digest("other")}
                self.install()
                with self.assertRaises(tool.release.ManifestError):
                    self.finalize()
                self.target["services"][service] = deepcopy(self.previous["services"][service])
        self.install()
        result = self.journal(self.prior, self.previous, self.previous, "failed-or-interrupted")
        os.utime(result, (10, 10))
        with self.assertRaises(tool.release.ManifestError):
            self.finalize()
        self.assertEqual(self.journals(), original)

    def test_failing_receipt_images_runtime_health_or_public_gate_does_not_record_success(self):
        original = self.journals()
        for gate in (self.receipt, self.retained, self.images, self.runtime, self.health, self.public):
            with self.subTest(gate=gate):
                gate.side_effect = tool.release.ManifestError("Refused")
                with self.assertRaisesRegex(tool.release.ManifestError, "Refused"):
                    self.finalize()
                gate.side_effect = None
                self.assertEqual(self.journals(), original)


class RecoveryEvidenceTests(unittest.TestCase):
    def test_backup_requires_the_failed_runs_receipt_database_and_ciphertext(self):
        with TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            token = "12345-2-backend-qlty"
            stamp = "20261124T010208Z"
            backup = f"verified-{stamp}-12345678"
            run = root / ".redeploy-runs" / token
            run.mkdir(parents=True)
            status = run / "status"
            status.write_text("1\n")
            lines = ["OpenMRS database backup verified by isolated restore: " + backup,
                     "Container sihsalus-backend Recreated", "Container sihsalus-backend Started",
                     "Container sihsalus-backend Waiting", "application not healthy after 30m0s",
                     "[deploy-qlty-backend] Failed: Redeploy failed; use the retained previous manifest for recovery"]
            log = run / "redeploy.log"
            log.write_text("\n".join(lines) + "\n")
            source = root / ".local/share/sihsalus/backups/qlty-backend-update" / backup
            source.mkdir(parents=True)
            dump = source / "dump_2026-11-24_01-02-08.sql.gz.enc"
            dump.write_bytes(b"synthetic encrypted backup")
            checksum = tool.file_hash(dump)
            (source / "SHA256SUMS").write_text(f"{checksum}  {dump.name}\n")
            previous = fixture()
            image = previous["services"]["db"]["imageId"]
            receipt = source / "verification.txt"
            receipt.write_text(f"timestamp={stamp}\nscope=openmrs-database\nsource_image={image}\n"
                               "key=~/.sihsalus-backup-keys/qlty-backend-update.key\n"
                               "checks=sha256,decryption,isolated-restore,table-list,mariadb-check\n")
            prior = root / "prior"
            failed = root / "failed"
            prior.mkdir()
            failed.mkdir()
            for instant, path in enumerate([prior / "result.json", receipt, failed / "target.json", failed / "result.json", status], 1):
                path.touch()
                os.utime(path, (instant, instant))
            with patch.object(Path, "home", return_value=root):
                def verify():
                    return tool.verify_backup(root, token, backup, previous, prior, failed)

                evidence = verify()
                self.assertEqual(evidence, {"id": backup, "receiptSha256": tool.file_hash(receipt), "encryptedSha256": checksum})
                for path, replacement in [(status, "0"), (log, "\n".join(lines[:-1])), (log, log.read_text() + lines[0]),
                                          (receipt, receipt.read_text().replace(image, digest("other"))),
                                          (dump, "modified ciphertext")]:
                    with self.subTest(file=path.name):
                        original = path.read_bytes()
                        timestamp = path.stat().st_mtime_ns
                        path.write_text(replacement)
                        os.utime(path, ns=(timestamp, timestamp))
                        with self.assertRaises(tool.release.ManifestError):
                            verify()
                        path.write_bytes(original)
                        os.utime(path, ns=(timestamp, timestamp))
                os.utime(receipt, (10, 10))
                with self.assertRaises(tool.release.ManifestError):
                    verify()

    def test_running_backend_must_have_started_within_the_reviewed_failed_attempt(self):
        with TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            failed = root / str(uuid4())
            failed.mkdir()
            for path, instant in ((failed / "target.json", 10), (failed / "result.json", 20)):
                path.touch()
                os.utime(path, (instant, instant))
            for second, restarts, accepted in [("10.000000001", 0, True), ("09.999999999", 0, False),
                                               ("20.000000001", 0, False), ("11", 1, False)]:
                line = f"{'a' * 64} {digest('runtime')} 1970-01-01T00:00:{second}Z {restarts}"
                with self.subTest(second=second, restarts=restarts), patch.object(tool.release, "run", return_value=line):
                    if accepted:
                        self.assertEqual(tool.backend_instance(root, failed)["containerId"], "a" * 64)
                    else:
                        with self.assertRaises(tool.release.ManifestError):
                            tool.backend_instance(root, failed)
