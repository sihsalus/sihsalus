"""Verify automatic QLTY eligibility with synthetic GitHub responses and real jq."""
import json
import os
import re
import subprocess
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/deploy/check-qlty-publication.sh"
WORKFLOW = ROOT / ".github/workflows/build-backend.yml"
REPO = "sihsalus/sihsalus"
SHA = "a" * 40
OLDER = "b" * 40
API = f"repos/{REPO}"
RUNS = f"{API}/actions/workflows"
PULLS = f"{API}/commits/{SHA}/pulls"
CI = f"{RUNS}/ci.yml/runs?branch=main&event=push&head_sha={SHA}&per_page=1"
DRILLS = f"{RUNS}/physical-backup-drill.yml/runs?branch=main&status=completed&per_page=1"
PUBLICATIONS = f"{RUNS}/build-backend.yml/runs?branch=main&event=push&per_page=1"

FAKE_GH = """#!/usr/bin/env python3
import json
import sys
from pathlib import Path

args = sys.argv[1:]
with open('calls', 'a') as log:
    print(json.dumps(args), file=log)
fixtures = json.loads(Path('api.json').read_text())
if args[:1] == ['api'] and len(args) == 2:
    response = fixtures.get(args[1])
    if response is None:
        sys.exit('Simulated API failure: ' + args[1])
    print(json.dumps(response))
elif args[:3] == ['run', 'watch', '42'] and '--exit-status' in args:
    sys.exit(fixtures['watch_status'])
else:
    sys.exit('Unexpected gh invocation: ' + str(args))
"""


class PublicationTest(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory()
        self.addCleanup(workspace.cleanup)
        self.directory = Path(workspace.name)
        gh = self.directory / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.pr = {"merged_at": now, "merge_commit_sha": SHA, "html_url": f"https://github.com/{REPO}/pull/430",
                   "base": {"ref": "main", "repo": {"full_name": REPO}}}
        self.drill = {"conclusion": "success", "html_url": f"https://github.com/{REPO}/actions/runs/51",
                      "head_sha": OLDER, "updated_at": now}
        self.responses = {PULLS: [self.pr], CI: {"workflow_runs": [{"id": 42, "head_sha": SHA}]},
                          DRILLS: {"workflow_runs": [self.drill]}, PUBLICATIONS: {"workflow_runs": [{"head_sha": SHA}]},
                          "watch_status": 0}
        self.output = self.directory / "output"
        self.summary = self.directory / "summary"

    def run_check(self, **overrides):
        (self.directory / "api.json").write_text(json.dumps(self.responses))
        self.output.write_text("")
        self.summary.write_text("")
        env = dict(os.environ, PATH=f"{self.directory}{os.pathsep}{os.environ['PATH']}",
                   GITHUB_REPOSITORY=REPO, GITHUB_EVENT_NAME="push", GITHUB_REF="refs/heads/main",
                   GITHUB_SHA=SHA, GITHUB_OUTPUT=str(self.output), GITHUB_STEP_SUMMARY=str(self.summary))
        env.update(overrides)
        return subprocess.run(["bash", str(SCRIPT)], cwd=self.directory, env=env, text=True,
                              capture_output=True, timeout=10)

    def assert_blocked(self, **env):
        result = self.run_check(**env)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("deploy=true", self.output.read_text())

    def test_publish_latest_eligible_digest(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text().splitlines(), ["deploy=true"])
        for evidence in [self.pr["html_url"], "/actions/runs/42", self.drill["html_url"], OLDER, self.drill["updated_at"]]:
            self.assertIn(evidence, self.summary.read_text())

    def test_missing_or_unrelated_merged_pr(self):
        for prs in ([], [dict(self.pr, merged_at=None)], [dict(self.pr, merge_commit_sha=OLDER)],
                    [dict(self.pr, base={"ref": "release", "repo": {"full_name": REPO}})],
                    [dict(self.pr, base={"ref": "main", "repo": {"full_name": "unrelated/fork"}})]):
            with self.subTest(pulls=prs):
                self.responses[PULLS] = prs
                self.assert_blocked()

    def test_requires_successful_ci_on_same_commit(self):
        self.responses["watch_status"] = 1
        self.assert_blocked()
        self.responses["watch_status"] = 0
        self.responses[CI] = {"workflow_runs": [{"id": 42, "head_sha": OLDER}]}
        self.assert_blocked()

    def test_most_recent_completed_drill_must_succeed(self):
        for runs in ([], [dict(self.drill, conclusion="failure"), self.drill],
                     [dict(self.drill, head_sha="missing")], [dict(self.drill, updated_at=None)],
                     [dict(self.drill, html_url="https://example.org/unrelated")]):
            with self.subTest(runs=runs):
                self.responses[DRILLS] = {"workflow_runs": runs}
                self.assert_blocked()

    def test_error_reading_latest_publication(self):
        del self.responses[PUBLICATIONS]
        self.assert_blocked()

    def test_superseded_commit_skips_deployment(self):
        self.responses[PUBLICATIONS] = {"workflow_runs": [{"head_sha": "c" * 40}]}
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text().splitlines(), ["deploy=false"])

    def test_invalid_caller_refused_before_api_access(self):
        for env in ({"GITHUB_REPOSITORY": "fork/example"}, {"GITHUB_EVENT_NAME": "workflow_dispatch"},
                    {"GITHUB_REF": "refs/heads/dev"}, {"GITHUB_SHA": "abc123"}):
            with self.subTest(env=env):
                self.assert_blocked(**env)
                self.assertFalse((self.directory / "calls").exists())


class DeploymentWorkflowTest(unittest.TestCase):
    def test_deploy_requires_digest_bound_smoke_and_release_eligibility(self):
        # The workflow uses one-line job names at two-space indent.
        jobs = dict(re.findall(r"^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)",
                               WORKFLOW.read_text().split("\njobs:\n", 1)[1], re.M | re.S))
        smoke = jobs["qlty-authentication"]
        release = jobs["qlty-release"]
        deploy = jobs["deploy-qlty"]
        self.assertIn("digest: ${{ steps.image.outputs.digest }}", jobs["build-and-publish"])
        self.assertIn("needs: build-and-publish", smoke)
        self.assertIn("uses: ./.github/workflows/runtime-smoke.yml", smoke)
        self.assertIn("backend_digest: ${{ needs.build-and-publish.outputs.digest }}", smoke)
        self.assertIn("vars.AUTO_DEPLOY_BACKEND_QLTY == 'true'", smoke)
        self.assertIn("needs: qlty-authentication", release)
        self.assertIn("bash scripts/deploy/check-qlty-publication.sh", release)
        self.assertIn("deploy: ${{ steps.release.outputs.deploy }}", release)
        self.assertIn("needs: [build-and-publish, qlty-release]", deploy)
        self.assertIn("needs.qlty-release.outputs.deploy == 'true'", deploy)
        self.assertIn("vars.AUTO_DEPLOY_BACKEND_QLTY == 'true'", deploy)
        self.assertIn("name: quality", deploy)
        self.assertIn("cancel-in-progress: false", deploy)
        self.assertIn("BACKEND_DIGEST: ${{ needs.build-and-publish.outputs.digest }}", deploy)
        self.assertIn("run-redeploy-remote.sh --qlty-backend-only", deploy)
        self.assertIn('"$GITHUB_SHA" "$BACKEND_DIGEST"', deploy)
        for job in (smoke, release, deploy):
            self.assertNotIn("continue-on-error", job)
            self.assertNotIn("always()", job)


if __name__ == "__main__":
    unittest.main()
