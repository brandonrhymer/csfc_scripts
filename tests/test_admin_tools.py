"""Offline checks only: no SSH, account changes, network or installers."""
import ast
import importlib.util
import pathlib
import subprocess
import tempfile
import unittest

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
