import hashlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import run_conformance as runner


class ConformanceRunnerTest(unittest.TestCase):
    def test_rejects_changed_cached_validator_without_network_or_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'validator.jar'
            path.write_bytes(b'changed')
            with patch.object(runner.urllib.request, 'urlopen') as download:
                with self.assertRaisesRegex(ValueError, 'Checksum mismatch'):
                    runner.verified_download('https://example.org/tool', path, '0' * 64)
                download.assert_not_called()

    def test_verified_cache_is_reused_without_network(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'validator.jar'
            path.write_bytes(b'verified')
            digest = hashlib.sha256(b'verified').hexdigest()
            with patch.object(runner.urllib.request, 'urlopen') as download:
                self.assertEqual(runner.verified_download('https://example.org/tool', path, digest), path)
                download.assert_not_called()

    def test_rejects_empty_and_non_fhir_validation_responses(self):
        for response in (None, [], {}, {'resourceType': 'OperationOutcome'},
                         {'resourceType': 'OperationOutcome', 'issue': []},
                         {'resourceType': 'OperationOutcome', 'issue': [None]},
                         {'resourceType': 'OperationOutcome', 'issue': [{'severity': 'success'}]},
                         {'resourceType': 'Bundle', 'entry': []}):
            with self.subTest(response=response), self.assertRaises(ValueError):
                runner.issues(response)

    def test_extracts_all_outcomes_without_losing_a_fatal_error(self):
        fatal = {'severity': 'fatal', 'code': 'invalid'}
        warning = {'severity': 'warning', 'code': 'informational'}
        outcome = {'resourceType': 'Bundle', 'entry': [
            {'resource': {'resourceType': 'OperationOutcome', 'issue': [warning]}},
            {'resource': {'resourceType': 'OperationOutcome', 'issue': [fatal]}},
        ]}
        self.assertEqual(runner.issues(outcome), [warning, fatal])

    def test_stale_success_does_not_mask_a_failed_validator(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            stale = output / 'positive-corepe-document.outcome.json'
            stale.write_text(json.dumps({'resourceType': 'OperationOutcome', 'issue': []}))
            with patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)):
                with self.assertRaisesRegex(ValueError, 'without an outcome'):
                    runner.run_case('java', Path('validator.jar'), Path('package.tgz'), output,
                                    'positive-corepe-document', True)
            self.assertFalse(stale.exists())

    def test_zero_exit_with_fhir_error_is_a_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)

            def fake_run(*args, **kwargs):
                (output / 'positive-corepe-document.outcome.json').write_text(json.dumps({
                    'resourceType': 'OperationOutcome',
                    'issue': [{'severity': 'error', 'code': 'invalid'}],
                }))
                return subprocess.CompletedProcess([], 0)

            with patch.object(runner.subprocess, 'run', side_effect=fake_run):
                result = runner.run_case('java', Path('validator.jar'), Path('package.tgz'), output,
                                         'positive-corepe-document', True)
            self.assertFalse(result['passed'])
            self.assertEqual(result['errors'], 1)

    def test_negative_requires_the_expected_error_and_rejects_unrelated_errors(self):
        expected = {
            'severity': 'error', 'code': 'invalid', 'expression': ['Bundle.entry[7]'],
            'extension': [{'url': 'http://hl7.org/fhir/StructureDefinition/operationoutcome-message-id',
                           'valueCode': 'Validation_VAL_Profile_NotSlice'}],
        }
        self.assertTrue(runner.expected_rejection('negative-extra-immunization', [expected]))
        for errors in ([], [{'severity': 'fatal', 'expression': ['Bundle']}],
                       [expected, {'severity': 'error', 'expression': ['Bundle.identifier']}],
                       [dict(expected, expression=['Bundle.entry[0]'])],
                       [dict(expected, severity='fatal')]):
            with self.subTest(errors=errors):
                self.assertFalse(runner.expected_rejection('negative-extra-immunization', errors))

    def test_unknown_process_exit_is_not_a_successful_negative(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)

            def fake_run(*args, **kwargs):
                (output / 'negative-extra-immunization.outcome.json').write_text(json.dumps({
                    'resourceType': 'OperationOutcome', 'issue': [{'severity': 'information', 'code': 'informational'}],
                }))
                return subprocess.CompletedProcess([], 137)

            with patch.object(runner.subprocess, 'run', side_effect=fake_run), \
                    patch.object(runner, 'expected_rejection', return_value=True):
                result = runner.run_case('java', Path('validator.jar'), Path('package.tgz'), output,
                                         'negative-extra-immunization', False)
            self.assertFalse(result['passed'])

    def test_changed_download_is_not_kept_as_trusted_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'package.tgz'
            response = io.BytesIO(b'unexpected draft')
            response.url = 'https://example.org/package.tgz'
            with patch.object(runner.urllib.request, 'urlopen', return_value=response):
                with self.assertRaisesRegex(ValueError, 'Checksum mismatch'):
                    runner.verified_download(response.url, destination, '0' * 64)
            self.assertFalse(destination.exists())
            self.assertFalse(destination.with_suffix('.tgz.part').exists())

    def test_http_redirect_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            response = io.BytesIO(b'not trusted')
            response.url = 'http://example.org/package.tgz'
            destination = Path(directory) / 'package.tgz'
            with patch.object(runner.urllib.request, 'urlopen', return_value=response):
                with self.assertRaisesRegex(ValueError, 'non-HTTPS'):
                    runner.verified_download('https://example.org/package.tgz', destination, '0' * 64)
            self.assertFalse(destination.exists())
            self.assertFalse(destination.with_suffix('.tgz.part').exists())

    def test_semantic_cross_patient_is_separately_rejected(self):
        positive = runner.run_identity_case('positive-corepe-document')
        cross_patient = runner.run_identity_case('semantic-cross-patient')
        self.assertTrue(positive['passed'])
        self.assertIsNone(positive['actual_error'])
        self.assertTrue(cross_patient['passed'])
        self.assertEqual(cross_patient['actual_error'], 'identity_patient_mismatch')

    def test_new_duplicate_missing_or_relocated_warning_blocks_the_baseline(self):
        warnings = [
            {'severity': 'warning', 'expression': list(locations),
             'extension': [{'url': 'http://hl7.org/fhir/StructureDefinition/operationoutcome-message-id',
                            'valueCode': code}]}
            for code, locations in runner.COMMON_WARNINGS
        ]
        self.assertTrue(runner.reviewed_warnings('positive-corepe-document', warnings))
        for changed in ([], warnings[:-1], warnings + [warnings[0]],
                        warnings + [{'severity': 'warning', 'expression': ['Bundle']}],
                        [dict(warnings[0], expression=['Bundle'])] + warnings[1:]):
            with self.subTest(changed=changed):
                self.assertFalse(runner.reviewed_warnings('positive-corepe-document', changed))

    def test_previous_later_case_evidence_is_removed_before_a_new_run(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            stale = output / 'negative-extra-immunization.outcome.json'
            stale.write_text('previous result')
            unrelated = output / 'keep.txt'
            unrelated.write_text('not generated by the suite')
            runner.prepare_output(output)
            self.assertFalse(stale.exists())
            self.assertEqual(unrelated.read_text(), 'not generated by the suite')

    def test_missing_java_replaces_previous_success_with_current_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            summary = output / 'summary.json'
            summary.write_text(json.dumps({'passed': True}))
            with patch.object(runner.sys, 'argv', ['run_conformance.py', '--cache', directory, '--output', directory]), \
                    patch.object(runner.shutil, 'which', return_value=None), \
                    patch.object(runner.urllib.request, 'urlopen') as download, \
                    patch.object(runner.sys, 'stderr', new_callable=io.StringIO):
                self.assertEqual(runner.main(), 1)
                download.assert_not_called()
            current = json.loads(summary.read_text())
            self.assertFalse(current['passed'])
            self.assertIn('Java 21', current['failure'])


if __name__ == '__main__':
    unittest.main()
