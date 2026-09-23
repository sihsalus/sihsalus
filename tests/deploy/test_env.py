import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[2] / "scripts/deploy/env.sh"


class DeploymentEnvironment(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env_file = self.root / ".env"
        self.original = ('# keep this comment\nUNRELATED_SECRET=$(touch should-not-exist)\n'
                         ' export BACKEND_TAG = "old" # previous image\nBACKEND_TAG=last\n')
        self.env_file.write_text(self.original)
        self.env_file.chmod(0o640)

    def call(self, *args, environment=None):
        return subprocess.run(["bash", "-c", 'source "$1"; shift; "$@"',
                               "env-test", str(HELPER), *args], cwd=self.root,
                              env=environment, capture_output=True, text=True, timeout=10)

    def test_read_literal_values_and_last_assignment_without_executing_shell(self):
        self.assertEqual(self.call("read_env_value", "BACKEND_TAG").stdout, "last\n")
        for value in ('"sha-abc" # comment', "'sha-abc'", "sha-abc # comment"):
            self.env_file.write_text(f" export BACKEND_TAG = {value}\n")
            self.assertEqual(self.call("read_env_value", "BACKEND_TAG").stdout, "sha-abc\n")
        self.assertFalse((self.root / "should-not-exist").exists())

    def test_replace_collapses_duplicates_preserves_other_lines_and_permissions(self):
        result = self.call("write_env_value", "BACKEND_TAG", "sha-new@sha256:abc")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.env_file.read_text(),
                         '# keep this comment\nUNRELATED_SECRET=$(touch should-not-exist)\n'
                         'BACKEND_TAG=sha-new@sha256:abc\n')
        self.assertEqual(stat.S_IMODE(self.env_file.stat().st_mode), 0o640)
        self.assertFalse((self.root / "should-not-exist").exists())
        self.assertEqual(list(self.root.glob(".env.deploy.*")), [])

    def test_new_key_is_appended(self):
        self.assertEqual(self.call("write_env_value", "SIHSALUS_NODE_ID", "node-id").returncode, 0)
        self.assertEqual(self.call("read_env_value", "SIHSALUS_NODE_ID").stdout, "node-id\n")

    def test_failed_replace_preserves_original_and_cleans_temporary(self):
        binary = self.root / "bin"
        binary.mkdir()
        mv = binary / "mv"
        mv.write_text("#!/bin/sh\nexit 1\n")
        mv.chmod(0o755)
        result = self.call("write_env_value", "BACKEND_TAG", "new",
                           environment=dict(os.environ, PATH=f"{binary}:{os.environ['PATH']}"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.env_file.read_text(), self.original)
        self.assertEqual(list(self.root.glob(".env.deploy.*")), [])


if __name__ == "__main__":
    unittest.main()
