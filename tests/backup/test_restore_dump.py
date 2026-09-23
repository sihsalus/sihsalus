"""Restore failure boundaries using a synthetic dump and a Docker stub."""
import gzip
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RestoreDump(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "events"
        self.dump = self.root / "dump.sql.gz"
        self.sql = b"CREATE TABLE synthetic_probe (id INT);\n"
        self.dump.write_bytes(gzip.compress(self.sql))
        docker = self.bin / "docker"
        docker.write_text('''#!/usr/bin/env python3
import os, sys
from pathlib import Path
args = sys.argv[1:]
if args[:2] == ['compose', 'stop']:
    event = 'stop'
elif args[:2] == ['compose', 'ps']:
    event = 'inspect'
elif args[:2] == ['compose', 'start']:
    event = 'start'
elif any('DROP DATABASE' in arg for arg in args):
    event = 'drop'
elif args[0] == 'exec':
    event = 'import'
    Path('imported.sql').write_bytes(sys.stdin.buffer.read())
else:
    raise SystemExit('Unexpected Docker command')
with Path('events').open('a') as f:
    f.write(event + '\\n')
if os.environ.get('RESTORE_FAIL') == event:
    sys.exit(23)
if event == 'inspect' and os.environ.get('RESTORE_RUNNING') == 'true':
    print('synthetic-running-backend')
''')
        docker.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        MYSQL_ROOT_PASSWORD="synthetic-only", TMPDIR=str(self.root),
                        RESTORE_ASSUME_YES="true", RESTORE_MANAGE_BACKEND="true")
        self.env.pop("RESTORE_FAIL", None)
        self.env.pop("RESTORE_RUNNING", None)

    def restore(self, *args, **environment):
        return subprocess.run(["bash", str(ROOT / "scripts/backup/restore_dump.sh"),
                               "--file", str(self.dump), *args], cwd=self.root,
                              env=dict(self.env, **environment), capture_output=True,
                              text=True, timeout=10)

    def events(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_invalid_truncated_and_empty_dumps_do_not_touch_docker(self):
        for data in (b"not gzip", gzip.compress(self.sql)[:-5], gzip.compress(b"")):
            with self.subTest(data=data):
                self.dump.write_bytes(data)
                self.assertNotEqual(self.restore().returncode, 0)
                self.assertEqual(self.events(), [])
                self.assertEqual(list(self.root.glob("sihsalus-restore-dump.*")), [])

    def test_stop_and_inspection_failures_prevent_database_changes(self):
        for operation in ("stop", "inspect"):
            with self.subTest(operation=operation):
                self.log.unlink(missing_ok=True)
                self.assertNotEqual(self.restore(RESTORE_FAIL=operation).returncode, 0)
                self.assertNotIn("drop", self.events())
                self.assertNotIn("start", self.events())

    def test_running_backend_prevents_database_changes(self):
        self.assertNotEqual(self.restore(RESTORE_RUNNING="true").returncode, 0)
        self.assertEqual(self.events(), ["stop", "inspect"])

    def test_encrypted_dump_is_checked_before_stopping_backend(self):
        encrypted = self.root / "dump.sql.gz.enc"
        subprocess.run(["openssl", "enc", "-aes-256-cbc", "-salt", "-pbkdf2",
                        "-pass", "env:BACKUP_ENCRYPTION_PASSWORD", "-in", str(self.dump),
                        "-out", str(encrypted)], check=True, capture_output=True,
                       env=dict(self.env, BACKUP_ENCRYPTION_PASSWORD="synthetic-key"))
        self.dump = encrypted
        self.assertNotEqual(self.restore(BACKUP_ENCRYPTION_PASSWORD="wrong-key").returncode, 0)
        self.assertEqual(self.events(), [])
        self.assertEqual(self.restore(BACKUP_ENCRYPTION_PASSWORD="synthetic-key").returncode, 0)
        self.assertEqual((self.root / "imported.sql").read_bytes(), self.sql)

    def test_import_failure_leaves_backend_stopped(self):
        self.assertNotEqual(self.restore(RESTORE_FAIL="import").returncode, 0)
        self.assertEqual(self.events(), ["stop", "inspect", "drop", "import"])

    def test_success_imports_validated_bytes_and_starts_existing_container(self):
        result = self.restore()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(), ["stop", "inspect", "drop", "import", "start"])
        self.assertEqual((self.root / "imported.sql").read_bytes(), self.sql)
        self.assertEqual(list(self.root.glob("sihsalus-restore-dump.*")), [])

    def test_external_app_control_still_validates_but_does_not_stop_or_start(self):
        self.assertEqual(self.restore("--no-app-control").returncode, 0)
        self.assertEqual(self.events(), ["drop", "import"])


if __name__ == "__main__":
    unittest.main()
