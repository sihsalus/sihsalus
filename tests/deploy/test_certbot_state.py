"""Certbot's one-shot and renewal process contracts, without a Docker daemon."""
import json
from pathlib import Path
import unittest
from unittest.mock import patch

from test_release_manifest import release


class CertbotState(unittest.TestCase):
    def check(self, mode, status, exit_code=0, actual_mode=None, actual_image=None):
        image = "sha256:" + "a" * 64
        manifest = {"services": {"certbot": {"imageId": image}},
                    "compose": {"project": "sihsalus", "files": ["compose/ssl.yml"],
                                "profiles": ["ssl"], "platform": "linux/amd64"},
                    "target": {"nodeId": "synthetic-node"}}
        answers = [mode, "b" * 64, json.dumps({"image": actual_image or image,
                   "status": status, "exitCode": exit_code, "health": None}),
                   "SSL_MODE=" + (actual_mode or mode)]
        with patch.object(release, "run", side_effect=answers), patch.dict(release.os.environ, {"SSL_MODE": mode}):
            release.wait_certbot(manifest, Path("/synthetic"), timeout=0)

    def test_development_requires_successful_completion(self):
        self.check("dev", "exited")
        for status, code in (("exited", 1), ("running", 0), ("restarting", 0)):
            with self.assertRaises(release.ManifestError):
                self.check("dev", status, code)

    def test_production_requires_running_renewal_process(self):
        self.check("prod", "running")
        with self.assertRaises(release.ManifestError):
            self.check("prod", "exited")

    def test_identity_or_mode_drift_blocks(self):
        with self.assertRaises(release.ManifestError):
            self.check("dev", "exited", actual_mode="prod")
        with self.assertRaises(release.ManifestError):
            self.check("prod", "running", actual_image="sha256:" + "c" * 64)


if __name__ == "__main__":
    unittest.main()
