"""Real child-process timeout/cancellation regressions, without network or Docker."""

import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "scripts/security/image-tool.py"


class BoundedImageToolTests(unittest.TestCase):
    def command(self, program, *args, timeout="0.8"):
        return [sys.executable, "-B", str(TOOL), "--timeout", timeout,
                "--kill-after", "0.1", "--", sys.executable, "-c", program, *args]

    def test_preserves_success_and_failure_status(self):
        for expected in (0, 7):
            result = subprocess.run(self.command(f"raise SystemExit({expected})"), capture_output=True, timeout=4)
            self.assertEqual(result.returncode, expected)
            self.assertEqual(result.stdout + result.stderr, b"")

    def test_forces_cleanup_when_tool_ignores_termination(self):
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory) / "owned.pid"
            program = ("import os,signal,sys,time; from pathlib import Path; "
                       "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                       "Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(60)")
            start = time.monotonic()
            result = subprocess.run(self.command(program, str(pid_file)), capture_output=True, timeout=4)
            self.assertEqual(result.returncode, 124)
            self.assertLess(time.monotonic() - start, 3)
            self.assertEqual(result.stdout + result.stderr, b"")
            with self.assertRaises(ProcessLookupError):
                os.kill(int(pid_file.read_text()), 0)

    def test_caller_cancellation_cleans_owned_tool(self):
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory) / "owned.pid"
            program = ("import os,signal,sys,time; from pathlib import Path; "
                       "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                       "Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(60)")
            process = subprocess.Popen(self.command(program, str(pid_file), timeout="30"),
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 3
                while not pid_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(pid_file.exists(), "owned tool did not start")
                process.send_signal(signal.SIGTERM)
                output, error = process.communicate(timeout=3)
                self.assertEqual(process.returncode, 128 + signal.SIGTERM)
                self.assertEqual(output + error, b"")
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(pid_file.read_text()), 0)
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=3)

    def test_timeout_reaches_owned_descendants(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "descendant-stopped"
            child = ("import signal,sys,time; from pathlib import Path; "
                     "signal.signal(signal.SIGTERM, lambda *_: "
                     "(Path(sys.argv[1]).write_text('stopped'), sys.exit(0))); time.sleep(60)")
            parent = ("import signal,subprocess,sys; "
                      "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                      "p=subprocess.Popen([sys.executable, '-c', sys.argv[1], sys.argv[2]]); "
                      "p.wait(); import time; time.sleep(60)")
            result = subprocess.run(self.command(parent, child, str(marker)), capture_output=True, timeout=4)
            self.assertEqual(result.returncode, 124)
            self.assertEqual(marker.read_text(), "stopped")
            self.assertEqual(result.stdout + result.stderr, b"")

    def test_rejects_unbounded_budget_before_starting_tool(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "must-not-start"
            for budget in ("nan", "inf", "0", "-1", "3601"):
                result = subprocess.run(self.command("from pathlib import Path; import sys; Path(sys.argv[1]).touch()",
                                                     str(marker), timeout=budget), capture_output=True, timeout=4)
                self.assertEqual(result.returncode, 2)
                self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
