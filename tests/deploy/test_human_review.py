"""Exercise deployment refusal against synthetic GitHub environment responses."""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/deploy/check-human-review.sh'


class HumanReviewTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        gh = self.bin / 'gh'
        gh.write_text('''#!/usr/bin/env bash
set -euo pipefail
test "$1" = api
printf '%s\\n' "$2" >> "$REVIEW_API_CALLS"
test "${REVIEW_API_UNAVAILABLE:-false}" = false
environment="${2##*/}"
cat "$REVIEW_FIXTURES/$environment.json"
''')
        gh.chmod(0o755)
        self.policy = {
            'can_admins_bypass': False,
            'protection_rules': [{
                'type': 'required_reviewers',
                'reviewers': [{'type': 'User', 'reviewer': {'type': 'User'}}],
            }],
        }
        self.environment = {
            **os.environ,
            'PATH': f'{self.bin}{os.pathsep}{os.environ["PATH"]}',
            'GITHUB_REPOSITORY': 'test/example',
            'REVIEW_FIXTURES': str(self.root),
            'REVIEW_API_CALLS': str(self.root / 'calls'),
        }

    def run_policy(self, policy, names=('development',), **environment):
        for name in ('development', 'quality'):
            (self.root / f'{name}.json').write_text(json.dumps(policy))
        return subprocess.run(
            ['bash', str(SCRIPT), *names], env={**self.environment, **environment},
            capture_output=True, text=True, timeout=10,
        )

    def test_accepts_native_user_or_team_review_without_admin_bypass(self):
        for reviewer in (
            {'type': 'User', 'reviewer': {'type': 'User'}},
            {'type': 'Team', 'reviewer': {'name': 'clinical-maintainers'}},
        ):
            with self.subTest(reviewer=reviewer):
                policy = copy.deepcopy(self.policy)
                policy['protection_rules'][0]['reviewers'] = [reviewer]
                self.assertEqual(self.run_policy(policy).returncode, 0)

    def test_refuses_missing_review_or_bypass_capability(self):
        policies = []
        for bypass in (True, None):
            policy = copy.deepcopy(self.policy)
            policy['can_admins_bypass'] = bypass
            policies.append(policy)
        policies.append({'protection_rules': self.policy['protection_rules']})
        policies.append({'can_admins_bypass': False, 'protection_rules': []})
        policies.append({'can_admins_bypass': False, 'protection_rules': [{'type': 'wait_timer'}]})
        for reviewers in ([], None, [{'type': 'User', 'reviewer': {'type': 'Bot'}}],
                          self.policy['protection_rules'][0]['reviewers'] +
                          [{'type': 'User', 'reviewer': {'type': 'Bot'}}]):
            policy = copy.deepcopy(self.policy)
            policy['protection_rules'][0]['reviewers'] = reviewers
            policies.append(policy)
        for policy in policies:
            with self.subTest(policy=policy):
                self.assertNotEqual(self.run_policy(policy).returncode, 0)

    def test_api_failure_does_not_allow_deployment(self):
        self.assertNotEqual(self.run_policy(self.policy, REVIEW_API_UNAVAILABLE='true').returncode, 0)

    def test_every_target_environment_must_be_protected(self):
        (self.root / 'development.json').write_text(json.dumps(self.policy))
        (self.root / 'quality.json').write_text('{}')
        result = subprocess.run(
            ['bash', str(SCRIPT), 'development', 'quality'], env=self.environment,
            capture_output=True, text=True, timeout=10,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / 'calls').read_text().splitlines(), [
            'repos/test/example/environments/development',
            'repos/test/example/environments/quality',
        ])

    def test_invalid_target_is_rejected_before_api_access(self):
        self.assertEqual(self.run_policy(self.policy, names=('../unexpected',)).returncode, 2)
        self.assertFalse((self.root / 'calls').exists())
        self.assertEqual(self.run_policy(self.policy, names=()).returncode, 2)


if __name__ == '__main__':
    unittest.main()
