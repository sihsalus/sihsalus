"""Logical backup resolves the database through the checkout's Compose project from any directory."""
import gzip
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BackupDump(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        docker = self.bin / "docker"
        docker.write_text('''#!/usr/bin/env python3
import os, sys
from pathlib import Path
state = Path(os.environ['BACKUP_STATE'])
args = sys.argv[1:]
with (state / 'commands').open('a') as f:
    f.write(' '.join(args) + '\\n')
if args == ['compose', 'ps', '--all', '--quiet', os.environ['BACKUP_EXPECTED_SERVICE']]:
    # Compose selects the project from the checkout that owns the script.
    if Path.cwd() != Path(os.environ['BACKUP_CHECKOUT']):
        raise SystemExit('Compose command outside the checkout')
    if os.environ.get('BACKUP_MISSING_DB') != 'true':
        print('synthetic-database')
elif args[:2] == ['exec', '-e'] and args[4:5] == ['mariadb-dump']:
    (state / 'dumped-container').write_text(args[3])
    sys.stdout.write('CREATE TABLE synthetic_probe (id INT);\\n')
else:
    raise SystemExit('Unexpected Docker command')
''')
        docker.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        MYSQL_ROOT_PASSWORD="synthetic-only", BACKUP_STATE=str(self.root),
                        BACKUP_CHECKOUT=str(ROOT), BACKUP_EXPECTED_SERVICE="db")
        for key in ("BACKUP_ENCRYPTION_PASSWORD", "BACKUP_MISSING_DB", "CONTAINER_NAME", "DB_SERVICE"):
            self.env.pop(key, None)

    def backup(self, *args, **environment):
        # The working directory is never the checkout, as for a cron entry.
        return subprocess.run(["bash", str(ROOT / "scripts/backup/backup_dump.sh"),
                               "--dir", str(self.root / "dumps"), *args], cwd=self.root,
                              env=dict(self.env, **environment), capture_output=True, text=True, timeout=10)

    def commands(self):
        path = self.root / "commands"
        return path.read_text().splitlines() if path.exists() else []

    def test_database_is_resolved_through_the_checkout_from_another_directory(self):
        result = self.backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commands()[0], "compose ps --all --quiet db")
        self.assertEqual((self.root / "dumped-container").read_text(), "synthetic-database")
        dumps = list((self.root / "dumps").glob("dump_*.sql.gz"))
        self.assertEqual(len(dumps), 1)
        self.assertEqual(gzip.decompress(dumps[0].read_bytes()), b"CREATE TABLE synthetic_probe (id INT);\n")

    def test_other_service_and_explicit_container_are_honoured(self):
        result = self.backup("--service", "db-replic", BACKUP_EXPECTED_SERVICE="db-replic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commands()[0], "compose ps --all --quiet db-replic")
        result = self.backup("--container", "explicit-database")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "dumped-container").read_text(), "explicit-database")
        self.assertFalse(any(command.startswith("compose") for command in self.commands()[2:]))

    def test_missing_database_container_aborts_before_writing_a_dump(self):
        result = self.backup(BACKUP_MISSING_DB="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no container for service 'db'", result.stderr)
        self.assertEqual(self.commands(), ["compose ps --all --quiet db"])
        self.assertFalse((self.root / "dumps").exists())


if __name__ == "__main__":
    unittest.main()
