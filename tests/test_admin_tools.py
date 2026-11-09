"""Offline checks only: no SSH, account changes, network or installers."""
import ast
import base64
import contextlib
import io
import importlib.util
import pathlib
import re
import shlex
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load(relative):
    path = ROOT / relative
    tree = ast.parse(path.read_text())
    compile(tree, str(path), 'exec')
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # Reviewed modules have guarded main entry points.
    return module


class AdminToolsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.clam = load('linux/clamav/clamav_rhel9_discovery.py')
        cls.discovery = load('linux/local-accounts/local_admin_discovery.py')
        cls.remediation = load('linux/local-accounts/local_admin_remediation.py')

    def test_embedded_bash_syntax(self):
        for module in (self.clam, self.discovery, self.remediation):
            script = getattr(module, 'REMOTE_SCRIPT', getattr(module, 'REMOTE_TEMPLATE', ''))
            result = subprocess.run(['bash', '-n'], input=script, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_emitter_roundtrip(self):
        # Execute only the pure formatting helper, not collection commands.
        for module in (self.clam, self.discovery, self.remediation):
            script = getattr(module, 'REMOTE_SCRIPT', getattr(module, 'REMOTE_TEMPLATE', ''))
            start = script.index('emit() {')
            end = script.index('\n}', start) + 2
            helper = script[start:end] + '\nemit "example_key" "synthetic value"\n'
            output = subprocess.check_output(['bash'], input=helper, text=True)
            decode = getattr(module, 'decode_records', getattr(module, 'decode_remote_output', None))
            self.assertEqual(decode(output), {'example_key': 'synthetic value'})

    def test_inventory_validation(self):
        for module in (self.clam, self.discovery, self.remediation):
            module.validate_target('host1.example.invalid', 'example_operator')
            for host, user in [('bad host', 'operator'), ('-option', 'operator'),
                               ('host1.example.invalid', '-option'), ('host;command', 'operator')]:
                with self.assertRaises(ValueError):
                    module.validate_target(host, user)
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'inventory.csv'
            path.write_text('# synthetic input\nhost1.example.invalid,example_operator\n')
            self.assertEqual(len(self.discovery.read_inventory(path)), 1)
            self.assertEqual(len(self.remediation.read_inventory(path)), 1)
            path.write_text('host1.example.invalid\n')
            for module in (self.discovery, self.remediation):
                with self.assertRaises(ValueError):
                    module.read_inventory(path)

    def test_assessment_conflict(self):
        result = self.discovery.assess_host('host1.example.invalid', 'example_operator', {
            'transport_status': 'SUCCESS', 'data': {
                'os_release': 'ID=rhel\nVERSION_ID=9',
                'uid_20000_owner': 'other_example:x:20000:20000:Example:/home/example:/bin/bash',
            },
        })
        self.assertEqual(result['overall_status'], 'UID_GID_CONFLICT')

    def test_clamav_missing(self):
        result = self.clam.assess('host1.example.invalid', {
            'transport_status': 'SUCCESS', 'data': {'os_release': 'ID=rhel\nVERSION_ID=9'},
        })
        self.assertEqual(result['overall_status'], 'NOT_INSTALLED')

    def check_config_queries(self, files, expected):
        # Execute only the three config queries. Leave stdin open: the old grep
        # calls would block here when there are no config filenames.
        commands = ['config_files=(' + ' '.join(shlex.quote(str(p)) for p in files) + ')']
        for name in ('socket_settings', 'clam_user', 'log_paths'):
            assignment = re.search(r'(?ms)^' + name + r'="\$\(\n.*?^\)"', self.clam.REMOTE_SCRIPT)
            self.assertIsNotNone(assignment)
            commands.append(assignment.group())
            commands.append('printf "%s\\n" "$' + name + '"')
        proc = subprocess.Popen(['bash', '-c', '\n'.join(commands)], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            proc.wait(timeout=3)
            output, error = proc.communicate(timeout=1)
            self.assertEqual(proc.returncode, 0, error)
            self.assertEqual(output.splitlines(), expected)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.communicate()

    def test_clamav_no_configs_does_not_read_stdin(self):
        self.check_config_queries([], ['', '', ''])

    def test_clamav_config_filename_with_spaces(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'example config.conf'
            path.write_text('LocalSocket /example/socket\nUser example_service\nLogFile /example/log\n')
            self.check_config_queries([path], ['/example/socket', 'example_service', '/example/log'])

    def records(self, values):
        return ''.join(self.remediation.MARKER + '\t' + key + '\t' +
                       base64.b64encode(value.encode()).decode() + '\n'
                       for key, value in values.items())

    def test_remediation_requires_terminal_result_and_zero_exit(self):
        for apply_mode, success in ((True, 'REMEDIATED'), (False, 'DRY_RUN_READY')):
            with self.subTest(apply=apply_mode):
                interpret = self.remediation.interpret_remote_response
                self.assertEqual(interpret(self.records({'result': success}), 0, apply_mode)['status'], success)
                for values, exit_code in (({'hostname': 'host1.example.invalid'}, 0),
                                          ({'result': 'UNKNOWN'}, 0), ({'result': 'unexpected'}, 0),
                                          ({'result': success}, 255), ({'result': success}, None),
                                          ({'result': 'DRY_RUN_READY' if apply_mode else 'REMEDIATED'}, 0),
                                          ({}, 0)):
                    self.assertEqual(interpret(self.records(values), exit_code, apply_mode)['status'], 'UNVERIFIED')
                for failure in ('FAILED', 'UID_GID_CONFLICT', 'UNSUPPORTED_OS'):
                    self.assertEqual(interpret(self.records({'result': failure}), 1, apply_mode)['status'], failure)

    def test_remediation_uses_ssh_exit_code(self):
        module = self.remediation
        process = mock.Mock(returncode=255)
        with mock.patch.object(module.shutil, 'which', return_value='/example/ssh'), \
             mock.patch.object(module.pty, 'openpty', return_value=(100, 101)), \
             mock.patch.object(module.subprocess, 'Popen', return_value=process), \
             mock.patch.object(module.select, 'select', return_value=([100], [], [])), \
             mock.patch.object(module.os, 'read', side_effect=[self.records({'result': 'REMEDIATED'}).encode(), b'']), \
             mock.patch.object(module.os, 'close'):
            result = module.run_remote('host1.example.invalid', 'example_operator', '', '', True, False)
        self.assertEqual(result['status'], 'UNVERIFIED')
        process.wait.assert_called_once()

    def test_remediation_main_fails_closed_without_apply_retries(self):
        module = self.remediation
        for status, expected_exit in (('UNKNOWN', 1), ('UNVERIFIED', 1), ('TIMEOUT', 1),
                                      ('ERROR', 1), ('DRY_RUN_READY', 1), ('REMEDIATED', 0)):
            with self.subTest(status=status), \
                 mock.patch.object(module.sys, 'argv', ['script', '--inventory', 'private.csv', '--apply']), \
                 mock.patch.object(module.os, 'geteuid', return_value=0), \
                 mock.patch.object(module, 'read_inventory', return_value=[('host1.example.invalid', 'example_operator')]), \
                 mock.patch('builtins.input', return_value='APPLY'), \
                 mock.patch.object(module.getpass, 'getpass', return_value='synthetic-test-value'), \
                 mock.patch.object(module, 'run_remote', return_value={'status': status, 'error': None, 'data': {}}) as remote, \
                 mock.patch.object(module, 'write_report'), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(module.main(), expected_exit)
                remote.assert_called_once()

    def test_remote_command_preserves_script(self):
        # Verify shell quoting round-trips literal script content without execution.
        import shlex
        for module in (self.clam, self.discovery, self.remediation):
            script = getattr(module, 'REMOTE_SCRIPT', getattr(module, 'REMOTE_TEMPLATE', ''))
            command = 'sudo -S -p EXAMPLE_PROMPT: bash -c ' + shlex.quote(script)
            self.assertEqual(shlex.split(command)[-1], script)

    def test_private_report(self):
        for module in (self.clam, self.discovery, self.remediation):
            with tempfile.TemporaryDirectory() as directory:
                module.REPORT_DIR = pathlib.Path(directory) / 'reports'
                module.REPORT_FILE = module.REPORT_DIR / 'latest.json'
                module.write_report({'synthetic': True})
                self.assertEqual(module.REPORT_FILE.stat().st_mode & 0o777, 0o600)
                self.assertEqual(module.REPORT_DIR.stat().st_mode & 0o777, 0o700)


if __name__ == '__main__':
    unittest.main()
