import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('nonproduction', ROOT/'scripts/monitoring/render-nonproduction.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class NonproductionConfigTests(unittest.TestCase):
    def config(self, environment):
        return module.configuration(environment, 'sihsalus@gmail.com', 'sih.salus.ia-grupo@pucp.edu.pe')
    def test_local_metrics_and_external_targets_are_environment_scoped(self):
        for environment in ['dev', 'qlty']:
            config = self.config(environment)['prometheus.json']
            self.assertEqual(config['global']['external_labels']['environment'], environment)
            jobs = config['scrape_configs']
            self.assertIn('node-exporter', [j['job_name'] for j in jobs])
            probes = [j for j in jobs if 'params' in j]
            self.assertEqual(len(probes), 2)
            for probe in probes:
                self.assertEqual(probe['static_configs'][0]['labels']['environment'], environment)
                self.assertNotIn('ignore_ssl', probe['params']['module'][0])
    def test_observer_checks_both_environments_without_requiring_their_exporters(self):
        jobs = self.config('observer')['prometheus.json']['scrape_configs']
        self.assertNotIn('node-exporter', [j['job_name'] for j in jobs])
        self.assertNotIn('cadvisor', [j['job_name'] for j in jobs])
        self.assertEqual(len([j for j in jobs if 'params' in j]), 4)
    def test_smtp_uses_private_file_tls_and_bounded_grouping(self):
        config = self.config('qlty')['alertmanager.json']
        self.assertTrue(config['global']['smtp_require_tls'])
        self.assertNotIn('smtp_auth_password', config['global'])
        self.assertEqual(config['global']['smtp_auth_password_file'], '/run/secrets/smtp-password')
        self.assertEqual(config['route']['repeat_interval'], '4h')
        self.assertTrue(config['receivers'][0]['email_configs'][0]['send_resolved'])
    def test_inhibition_only_suppresses_same_filesystem_warning(self):
        rule = self.config('dev')['alertmanager.json']['inhibit_rules'][0]
        self.assertEqual(rule['equal'], ['environment', 'instance', 'mountpoint'])
        self.assertEqual(rule['target_matchers'], ['alertname="HostFilesystemSpaceLow"'])
    def test_rejects_invalid_target_and_recipient_header_injection(self):
        with self.assertRaises(ValueError): self.config('production')
        with self.assertRaises(ValueError):
            module.configuration('dev', 'sihsalus@gmail.com', 'list@example.com\nBcc: other@example.com')

if __name__ == '__main__': unittest.main()
