"""Physical backup rejects missing credentials before touching data or old backups."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BackupFullPreflight(unittest.TestCase):
    def test_missing_credentials_do_not_call_docker_or_change_existing_backups(self):
        for missing in ("BACKUP_ENCRYPTION_PASSWORD", "MYSQL_ROOT_PASSWORD"):
            for value in (None, ""):
                for existing in (False, True):
                    with self.subTest(missing=missing, value=value, existing=existing):
                        with tempfile.TemporaryDirectory() as directory:
                            root = Path(directory)
                            backup = root / "backups"
                            if existing:
                                backup.mkdir()
                                (backup / "fullBackup_log.txt").write_text("previous log")
                                (backup / "backup_previous.tar.gz.enc").write_bytes(b"synthetic backup")
                            before = {p.name: p.read_bytes() for p in backup.glob("*")}
                            docker = root / "docker"
                            docker.write_text("#!/bin/sh\ntouch docker-was-called\nexit 73\n")
                            docker.chmod(0o755)
                            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                                       MYSQL_ROOT_PASSWORD="synthetic-database-key",
                                       BACKUP_ENCRYPTION_PASSWORD="synthetic-encryption-key")
                            for key in ("OMRS_DB_BACKUP_USER", "OMRS_DB_BACKUP_PASSWORD"):
                                env.pop(key, None)
                            if value is None:
                                env.pop(missing)
                            else:
                                env[missing] = value
                            result = subprocess.run(
                                ["bash", str(ROOT / "scripts/backup/backup_full.sh"),
                                 "--dir", str(backup)], cwd=root, env=env,
                                capture_output=True, text=True, timeout=10)
                            self.assertEqual(result.returncode, 2, result.stderr)
                            self.assertFalse((root / "docker-was-called").exists())
                            self.assertEqual(backup.exists(), existing)
                            self.assertEqual({p.name: p.read_bytes() for p in backup.glob("*")}, before)
                            self.assertNotIn("synthetic-database-key", result.stdout + result.stderr)
                            self.assertNotIn("synthetic-encryption-key", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
