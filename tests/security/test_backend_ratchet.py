"""Exact, expiring risk acceptance must not admit unrelated findings."""
from copy import deepcopy
from datetime import timedelta
import unittest
from test_image_policy import policy, exception, TODAY, EMPTY_POLICY, FINDING

REPOSITORY = 'ghcr.io/sihsalus/sihsalus-backend'

def report(**changes):
    value = {'Metadata': {'ImageConfig': {'os': 'linux', 'architecture': 'amd64'}},
             'Results': [{'Class': 'lang-pkgs', 'Type': 'jar', 'Vulnerabilities': [{**FINDING, **changes}]}]}
    return value

def accepted(**changes):
    return {'schemaVersion': 1, 'exceptions': [exception(repository=REPOSITORY, **{'class': 'lang-pkgs', 'type': 'jar'}, **changes)]}

class BackendRatchet(unittest.TestCase):
    def check(self, candidate=None, baseline=None, exceptions=None, today=TODAY):
        return policy.backend_ratchet(report() if candidate is None else candidate,
                                      {'Results': []} if baseline is None else baseline,
                                      accepted() if exceptions is None else exceptions, today)

    def test_exact_exception_remains_visible(self):
        summary, blocked = self.check()
        self.assertFalse(blocked)
        self.assertIn('Findings added beyond upstream: 1', summary)
        self.assertIn('Temporarily accepted findings: 1', summary)
        self.assertIn(FINDING['VulnerabilityID'], summary)
        self.assertIn('expires 2026-09-27', summary)

    def test_new_id_package_version_or_severity_blocks(self):
        for changes in ({'VulnerabilityID': 'CVE-2026-99999'}, {'PkgName': 'another-library'},
                        {'InstalledVersion': '1.0.1'}, {'Severity': 'CRITICAL'}):
            with self.subTest(changes=changes):
                self.assertTrue(self.check(report(**changes))[1])

    def test_architecture_ecosystem_and_repository_do_not_share_exceptions(self):
        candidate = report()
        candidate['Metadata']['ImageConfig']['architecture'] = 'arm64'
        self.assertTrue(self.check(candidate)[1])
        candidate = report()
        candidate['Results'][0]['Type'] = 'gobinary'
        self.assertTrue(self.check(candidate)[1])
        value = accepted()
        value['exceptions'][0]['repository'] = 'ghcr.io/sihsalus/sihsalus-frontend'
        self.assertTrue(self.check(exceptions=value)[1])

    def test_expiration_and_incomplete_policy_fail_closed(self):
        with self.assertRaises(policy.PolicyError):
            self.check(today=TODAY + timedelta(days=7))
        value = accepted()
        del value['exceptions'][0]['owner']
        with self.assertRaises(policy.PolicyError):
            self.check(exceptions=value)

    def test_os_is_never_excepted_even_if_in_baseline(self):
        candidate = report()
        candidate['Results'][0].update(Class='os-pkgs', Type='alpine')
        value = accepted()
        value['exceptions'][0].update({'class': 'os-pkgs', 'type': 'alpine'})
        self.assertTrue(self.check(candidate, deepcopy(candidate), value)[1])
        self.assertTrue(self.check(candidate, exceptions=value)[1])

    def test_baseline_does_not_cover_changed_severity(self):
        self.assertTrue(self.check(report(Severity='CRITICAL'), report(), EMPTY_POLICY)[1])

    def test_missing_platform_or_scan_results_fail_closed(self):
        for candidate in ({'Results': []}, {'Metadata': report()['Metadata']},
                          {'Metadata': report()['Metadata'], 'Results': 'invalid'}):
            with self.subTest(candidate=candidate), self.assertRaises(policy.PolicyError):
                self.check(candidate)

    def test_mixed_known_and_new_still_blocks(self):
        candidate = report()
        candidate['Results'][0]['Vulnerabilities'].append({**FINDING, 'VulnerabilityID': 'CVE-2026-99999'})
        summary, blocked = self.check(candidate)
        self.assertTrue(blocked)
        self.assertIn('Temporarily accepted findings: 1', summary)
        self.assertIn('Unaccepted findings: 1', summary)
