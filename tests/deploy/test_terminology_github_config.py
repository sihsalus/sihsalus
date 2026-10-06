"""Receiver tests with real dotenv files and a simulated deployment."""
import contextlib
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('sync_config', SOURCE / 'scripts/terminology/sync-github-config.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
COMMIT = 'a' * 40


class ReceiverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / '.env.terminology-state'
        self.state.mkdir(mode=0o700)
        (self.root / 'scripts/deploy').mkdir(parents=True)
        shutil.copy2(SOURCE / 'scripts/deploy/env.sh', self.root / 'scripts/deploy/env.sh')
        self.settings = {key: 'synthetic-value' for key in module.CONFIG_KEYS}
        self.settings.update(TERMINOLOGY_MACHINE_ID='a'*32, TERMINOLOGY_BACKUP_KEEP='14',
                             TERMINOLOGY_EMAIL_PORT='587', TERMINOLOGY_ADMIN_EMAIL='',
                             TERMINOLOGY_EMAIL_BACKEND='django.core.mail.backends.smtp.EmailBackend')
        # Omit retention to exercise its default.
        self.original = '# preserve comment\nUNMANAGED_IMAGE=image@sha256:abc\n' + ''.join(
            key + "='" + value + "'\n" for key, value in self.settings.items()
            if key != 'TERMINOLOGY_BACKUP_KEEP')
        self.env = self.root / '.env.terminology'
        self.active = self.state / 'active.env'
        for path in (self.env, self.active):
            path.write_text(self.original)
            path.chmod(0o600)
        self.payload = dict(commit=COMMIT, mode='apply', settings=self.settings.copy())
        self.calls = []
        self.compose_failure = False
        self.deploy_failure = False
        self.dirty = False
        self.machine = 'a'*32
        real_read = Path.read_text

        def check_output(args, **kwargs):
            if args[:2] == ['git', 'rev-parse']:
                return COMMIT + '\n'
            if args[:2] == ['git', 'status']:
                return ' M tracked\n' if self.dirty else ''
            return subprocess.check_output(args, **kwargs)

        def read_text(path, *args, **kwargs):
            if str(path) == '/etc/machine-id':
                return self.machine
            return real_read(path, *args, **kwargs)

        def run(args, **kwargs):
            self.calls.append(args)
            if args[0] == 'docker':
                if self.compose_failure:
                    raise subprocess.CalledProcessError(1, args)
            elif args[:2] == ['bash', 'scripts/deploy/deploy-terminology.sh']:
                self.assertEqual(args[3], 'update')
                if not self.deploy_failure:
                    shutil.copy2(self.env, self.active)
                return subprocess.CompletedProcess(args, 1 if self.deploy_failure else 0)
            else:
                self.fail('Unexpected command')
            return subprocess.CompletedProcess(args, 0)

        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(patch.object(module, 'ROOT', self.root))
        commands = stack.enter_context(patch.object(module, 'subprocess'))
        commands.check_output.side_effect = check_output
        commands.run.side_effect = run
        commands.STDOUT = subprocess.STDOUT
        stack.enter_context(patch.object(Path, 'read_text', read_text))
        stack.enter_context(patch.dict(os.environ, SSH_ORIGINAL_COMMAND='terminology-config'))
        previous = os.umask(0o077)
        self.addCleanup(os.umask, previous)

    def receive(self):
        output = io.StringIO()
        stream = io.TextIOWrapper(io.BytesIO(json.dumps(self.payload).encode()))
        with patch.object(module.sys, 'stdin', stream), contextlib.redirect_stdout(output):
            module.receive()
        self.output = output.getvalue()
        return json.loads(self.output)

    def unchanged(self):
        self.assertEqual(self.env.read_text(), self.original)
        self.assertEqual(self.active.read_text(), self.original)
        self.assertFalse(self.calls)

    def test_noop_preserves_bytes_and_does_not_deploy(self):
        self.assertEqual(self.receive()['status'], 'unchanged')
        self.unchanged()

    def test_check_reports_names_without_changing_files(self):
        self.payload['mode'] = 'check'
        self.payload['settings']['TERMINOLOGY_EMAIL_HOST_PASSWORD'] = 'new-synthetic-password'
        result = self.receive()
        self.assertEqual(result['settings_matched'], 18)
        self.assertEqual(result['changed_keys'], ['TERMINOLOGY_EMAIL_HOST_PASSWORD'])
        self.assertNotIn('new-synthetic-password', self.output)
        self.unchanged()

    def test_apply_roundtrips_literals_preserves_unmanaged_and_journal(self):
        password = 'synthetic $HOME ${UNDEFINED} `uname` "double" \\slash #end'
        self.payload['settings']['TERMINOLOGY_EMAIL_HOST_PASSWORD'] = password
        result = self.receive()
        self.assertEqual(result['status'], 'applied')
        self.assertEqual(module.read_configuration(self.env), self.payload['settings'])
        self.assertIn('# preserve comment\nUNMANAGED_IMAGE=image@sha256:abc\n', self.env.read_text())
        journal = self.state / result['journal']
        self.assertEqual((journal / 'previous.env').read_text(), self.original)
        self.assertEqual(self.env.read_bytes(), self.active.read_bytes())
        self.assertEqual((journal / 'exit').read_text(), '0\n')
        for file in [self.env, journal/'previous.env', journal/'target.env', journal/'deploy.log']:
            self.assertEqual(file.stat().st_mode & 0o777, 0o600)
        self.assertEqual(journal.stat().st_mode & 0o777, 0o700)
        self.assertNotIn(password, self.output)
        self.assertEqual(len(self.calls), 2)

    def test_compose_failure_preserves_active_configuration(self):
        self.payload['settings']['TERMINOLOGY_BACKUP_KEEP'] = '15'
        self.compose_failure = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.receive()
        self.assertEqual(self.env.read_text(), self.original)
        self.assertEqual(self.active.read_text(), self.original)
        self.assertEqual(len(self.calls), 1)

    def test_failed_deploy_keeps_recovery_and_blocks_retry(self):
        self.payload['settings']['TERMINOLOGY_BACKUP_KEEP'] = '15'
        self.deploy_failure = True
        with self.assertRaisesRegex(module.ConfigurationError, 'private recovery journal'):
            self.receive()
        self.assertEqual(self.active.read_text(), self.original)
        journal = next(self.state.glob('github-config-*'))
        self.assertEqual((journal/'previous.env').read_text(), self.original)
        self.assertEqual((journal/'exit').read_text(), '1\n')
        with self.assertRaisesRegex(module.ConfigurationError, 'pending deployment'):
            self.receive()
        self.assertEqual(len(self.calls), 2)

    def test_rejects_persisted_credential_rotations(self):
        for key in set(module.CREDENTIAL_SETTING_NAMES) - {'TERMINOLOGY_EMAIL_HOST_PASSWORD'}:
            with self.subTest(key=key):
                self.payload['settings'] = dict(self.settings, **{key:'changed'})
                with self.assertRaisesRegex(module.ConfigurationError, 'coordinated'):
                    self.receive()
                self.unchanged()

    def test_rejects_bad_scalar_and_missing_values(self):
        for value in ['has\nnewline', 'has\rreturn', 'has\0null', "has'quote", '', None, 123]:
            with self.subTest(value=repr(value)):
                self.payload['settings']['TERMINOLOGY_EMAIL_HOST_PASSWORD'] = value
                with self.assertRaises(module.ConfigurationError):
                    self.receive()
                self.unchanged()

    def test_rejects_unknown_keys(self):
        self.payload['settings']['UNKNOWN'] = 'synthetic'
        with self.assertRaisesRegex(module.ConfigurationError, 'configuration keys'):
            self.receive()
        self.unchanged()

    def test_rejects_invalid_numeric_and_backend_settings(self):
        cases = [('BACKUP_KEEP','1'), ('BACKUP_KEEP','x'), ('EMAIL_PORT','0'),
                 ('EMAIL_PORT','65536'), ('EMAIL_PORT','smtp'), ('EMAIL_BACKEND','unapproved')]
        for suffix, value in cases:
            with self.subTest(setting=suffix, value=value):
                self.payload['settings'] = dict(self.settings, **{'TERMINOLOGY_'+suffix:value})
                with self.assertRaises(module.ConfigurationError):
                    self.receive()
                self.unchanged()

    def test_rejects_wrong_commit(self):
        self.payload['commit'] = 'b'*40
        with self.assertRaisesRegex(module.ConfigurationError, 'operations commit'):
            self.receive()
        self.unchanged()

    def test_rejects_dirty_checkout(self):
        self.dirty = True
        with self.assertRaisesRegex(module.ConfigurationError, 'clean'):
            self.receive()
        self.unchanged()

    def test_rejects_wrong_host(self):
        self.machine = 'b'*32
        with self.assertRaisesRegex(module.ConfigurationError, 'host identity'):
            self.receive()
        self.unchanged()

    def test_rejects_nonprivate_configuration(self):
        self.env.chmod(0o644)
        with self.assertRaisesRegex(module.ConfigurationError, 'mode 600'):
            self.receive()
        self.unchanged()

    def test_rejects_shell_command(self):
        with patch.dict(os.environ, SSH_ORIGINAL_COMMAND='id'):
            with self.assertRaisesRegex(module.ConfigurationError, 'Unsupported SSH command'):
                self.receive()
        self.unchanged()

    def test_rejects_concurrent_synchronization(self):
        with (self.state/'github-config.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                self.receive()
        self.unchanged()


if __name__ == '__main__':
    unittest.main(verbosity=2)
