"""Synthetic policy, command-fragment and mocked-transport tests; no live accounts/SSH."""
import contextlib
import copy
import io
import json
import os
import pathlib
import re
import shlex
import subprocess
import tempfile
import unittest
from unittest import mock

from test_admin_tools import ROOT, load


def shell_function(script, name):
    match = re.search(r'(?ms)^' + re.escape(name) + r'\(\) \{.*?^\}', script)
    if not match:
        raise AssertionError('Missing reviewed shell helper: ' + name)
    return match.group()


class AccountPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.policy_module = load('linux/local-accounts/account_policy.py')
        cls.discovery = load('linux/local-accounts/local_admin_discovery.py')
        cls.remediation = load('linux/local-accounts/local_admin_remediation.py')
        first = cls.policy_module.load_policy(ROOT / 'linux/local-accounts/policy.example.json')
        second = dict(first, account='example_alternate', group='example_private', uid=22010,
                      gid=22011, home='/srv/example_home', home_mode='0750', shell='/bin/sh',
                      comment="Operator's $(printf NOT_EXECUTED) account", privileged_group='example_privileged',
                      password_max_days=90, password_min_days=2, password_warn_days=12,
                      password_inactive_days=30, faillock_deny=5, faillock_unlock_time_seconds=1800)
        cls.policies = [first, cls.policy_module.validate_policy(second)]

    def test_policy_rejects_missing_unknown_duplicate_and_nonfinite_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            filename = pathlib.Path(directory) / 'private.json'
            for text in ('{}', '[]', '{"schema_version":1,"schema_version":1}',
                         json.dumps(dict(self.policies[0], password='not-allowed')),
                         json.dumps(self.policies[0]).replace('20000', 'NaN', 1), ' ' * 16385):
                filename.write_text(text)
                with self.subTest(text=text[:40]), self.assertRaises(ValueError):
                    self.policy_module.load_policy(filename)

    def test_policy_rejects_coercions_unsafe_paths_identities_and_policy_ranges(self):
        invalid = [('uid', True), ('uid', '20000'), ('uid', 999), ('gid', 65534),
                   ('schema_version', True), ('account', 'root'), ('account', '-option'),
                   ('group', 'wheel'), ('account', 'bad;name'), ('home', '/'),
                   ('home', '/home/../etc'), ('home', '/home/example/'), ('home', '/etc/example'),
                   ('home_mode', 700), ('home_mode', '0777'), ('shell', '/tmp/command'),
                   ('comment', 'Bad:comment'), ('comment', 'bad\ncomment'), ('comment', '\x1b[2J'),
                   ('password_max_days', 0), ('password_min_days', 61), ('password_warn_days', 61),
                   ('password_inactive_days', -1), ('faillock_deny', 0),
                   ('faillock_unlock_time_seconds', 0), ('faillock_deny', 3.0)]
        for field, value in invalid:
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                self.policy_module.validate_policy(dict(self.policies[0], **{field: value}))

    def test_two_policies_roundtrip_all_rendered_bash_values_without_evaluation(self):
        for policy in self.policies:
            for module in (self.discovery, self.remediation):
                with self.subTest(account=policy['account'], module=module.__name__):
                    script = module.build_remote_script(policy)
                    syntax = subprocess.run(['bash', '-n'], input=script, text=True, capture_output=True)
                    self.assertEqual(syntax.returncode, 0, syntax.stderr)
                    # Only assignments are evaluated; the remote operational body is excluded.
                    assignments = script[:script.index('emit() {')]
                    names = self.policy_module.SHELL_FIELDS
                    command = assignments + '\nprintf "%s\\0" ' + ' '.join('"$' + name + '"' for name in names)
                    values = subprocess.check_output(['bash', '-c', command]).decode().split('\0')[:-1]
                    self.assertEqual(values, [str(policy[field]) for field in names.values()])

    def test_two_policies_drive_mutation_arguments_in_isolated_command_stubs(self):
        for policy in self.policies:
            with self.subTest(account=policy['account']), tempfile.TemporaryDirectory() as directory:
                script = self.remediation.build_remote_script(policy, True, True)
                # Execute only this bounded mutation fragment with every command that
                # could change an account, filesystem or policy replaced by an inert stub.
                fragment = script[script.index('# Create the private primary group'):script.index('# Post-remediation validation.')]
                prefix = self.policy_module.shell_assignments(policy) + '\nMANAGE_FAILLOCK=true\nNEW_PASSWORD=synthetic\n'
                stubs = r'''
record() { printf '%s\0' "$@" >> "$TEST_LOG"; printf '\n' >> "$TEST_LOG"; }
emit() { :; }
fail() { printf '%s\n' "$1" >&2; exit 1; }
getent() { return 2; }
home_path_is_safe() { return 0; }
groupadd() { record groupadd "$@"; }
useradd() { record useradd "$@"; }
usermod() { record usermod "$@"; }
mkdir() { record mkdir "$@"; }
chown() { record chown "$@"; }
chmod() { record chmod "$@"; }
chpasswd() { local secret; IFS= read -r secret; record chpasswd; }
chage() { record chage "$@"; }
passwd() { record passwd "$@"; }
ensure_faillock_setting() { record faillock "$@"; }
find() { fail 'Unexpected ownership migration in absent-account fixture'; }
'''
                log = pathlib.Path(directory) / 'commands'
                subprocess.run(['bash', '-c', prefix + stubs + fragment], check=True,
                               env=dict(os.environ, TEST_LOG=str(log)), capture_output=True)
                calls = [line.split('\0')[:-1] for line in log.read_text().splitlines()]
                self.assertIn(['groupadd', '-g', str(policy['gid']), policy['group']], calls)
                self.assertIn(['useradd', '-u', str(policy['uid']), '-g', str(policy['gid']), '-c', policy['comment'],
                               '-d', policy['home'], '-m', '-s', policy['shell'], policy['account']], calls)
                self.assertIn(['usermod', '-aG', policy['privileged_group'], policy['account']], calls)
                self.assertIn(['chown', policy['account'] + ':' + policy['group'], policy['home']], calls)
                self.assertIn(['chmod', policy['home_mode'], policy['home']], calls)
                self.assertIn(['chage', '-M', str(policy['password_max_days']), '-m', str(policy['password_min_days']),
                               '-W', str(policy['password_warn_days']), '-I', str(policy['password_inactive_days']), policy['account']], calls)
                self.assertIn(['faillock', 'deny', str(policy['faillock_deny'])], calls)
                self.assertIn(['faillock', 'unlock_time', str(policy['faillock_unlock_time_seconds'])], calls)
                self.assertIn(['passwd', '-u', policy['account']], calls)

    def matching_collection(self, policy):
        record = f"{policy['account']}:x:{policy['uid']}:{policy['gid']}:{policy['comment']}:{policy['home']}:{policy['shell']}"
        return {'transport_status': 'SUCCESS', 'error': None, 'data': {
            'os_release': 'ID=rhel\nVERSION_ID=9', 'account_passwd': record,
            'target_uid_owner': record, 'target_gid_owner': f"{policy['group']}:x:{policy['gid']}:",
            'account_home_stat': policy['home'] + '|mode=' + policy['home_mode'].lstrip('0'),
            'privileged_group': f"{policy['privileged_group']}:x:30000:{policy['account']}",
            'ownership_scan_status': 'COMPLETE', 'account_owned_file_count': '0', 'collection_complete': 'COMPLETE',
        }}

    def test_two_policies_match_discovery_and_detect_attribute_drift(self):
        for policy in self.policies:
            collection = self.matching_collection(policy)
            result = self.discovery.assess_host('host1.example.invalid', 'example_operator', collection, policy)
            self.assertEqual(result['overall_status'], 'BASELINE_MATCHES_DISCOVERY')
            detail = result['findings'][-1]['detail']
            for value in (policy['password_max_days'], policy['password_min_days'], policy['password_warn_days'],
                          policy['password_inactive_days'], policy['faillock_deny'], policy['faillock_unlock_time_seconds']):
                self.assertIn(str(value), detail)
            for index, value in ((2, '33000'), (3, '33001'), (4, 'Other'), (5, '/home/other'), (6, '/bin/false')):
                changed = copy.deepcopy(collection)
                fields = changed['data']['account_passwd'].split(':'); fields[index] = value
                changed['data']['account_passwd'] = ':'.join(fields)
                result = self.discovery.assess_host('host1.example.invalid', 'example_operator', changed, policy)
                self.assertEqual(result['overall_status'], 'READY_FOR_REMEDIATION')

    def test_two_policies_match_confirmation_report_and_remote_selection(self):
        for policy in self.policies:
            for module in (self.discovery, self.remediation):
                is_remediation = module is self.remediation
                argv = ['script', '--inventory', 'private.csv', '--policy', 'private.json'] + (['--apply'] if is_remediation else [])
                inventory = [('host1.example.invalid', 'example_operator')] if is_remediation else [{'host': 'host1.example.invalid', 'username': 'example_operator'}]
                response = {'status': 'REMEDIATED', 'error': None, 'data': {}} if is_remediation else self.matching_collection(policy)
                output, reports = io.StringIO(), []
                with mock.patch.object(module.sys, 'argv', argv), mock.patch.object(module.os, 'geteuid', return_value=0), \
                     mock.patch.object(module, 'load_policy', return_value=policy), mock.patch.object(module, 'read_inventory', return_value=inventory), \
                     mock.patch.object(module.getpass, 'getpass', return_value='synthetic-secret'), mock.patch('builtins.input', return_value='APPLY'), \
                     mock.patch.object(module, 'write_report', side_effect=lambda report: reports.append(copy.deepcopy(report))), \
                     mock.patch.object(module, 'run_remote' if is_remediation else 'collect_host', return_value=response) as remote, \
                     contextlib.redirect_stdout(output):
                    self.assertEqual(module.main(), 0)
                self.assertEqual(reports[-1]['policy'], policy)
                self.assertEqual(reports[-1]['policy_sha256'], self.policy_module.policy_digest(policy))
                self.assertIn(self.policy_module.policy_summary(policy), output.getvalue())
                if is_remediation:
                    self.assertEqual(remote.call_args.kwargs['policy'], policy)
                    self.assertIn('modify ' + policy['account'], output.getvalue())
                else:
                    self.assertEqual(remote.call_args.args[-1], policy)
                self.assertNotIn('synthetic-secret', json.dumps(reports))

    def test_invalid_policy_stops_before_prompts_or_remote_work(self):
        for module in (self.discovery, self.remediation):
            with mock.patch.object(module.sys, 'argv', ['script', '--inventory', 'private.csv', '--policy', 'bad.json']), \
                 mock.patch.object(module.os, 'geteuid', return_value=0), mock.patch.object(module, 'load_policy', side_effect=ValueError('invalid policy')), \
                 mock.patch.object(module.getpass, 'getpass') as prompt, mock.patch.object(module, 'read_inventory') as inventory, \
                 contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(module.main(), 2); prompt.assert_not_called(); inventory.assert_not_called()

    def test_identity_and_home_safety_helpers_keep_their_fail_closed_behavior(self):
        template = self.remediation.REMOTE_TEMPLATE
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            passwd = root / 'passwd'
            helper = shell_function(template, 'local_identity_is_safe') + '\nlocal_identity_is_safe "$1" "$2" "$3"'
            for content, number, success in [('example:x:22000:22000:Example:/home/example:/bin/bash\n', '22000', True),
                                              ('example:x:0:0:Example:/home/example:/bin/bash\n', '0', False),
                                              ('example:x:22000:22000:Example:/home/example:/bin/bash\nother:x:22000:22000:Other:/home/other:/bin/bash\n', '22000', False)]:
                passwd.write_text(content)
                result = subprocess.run(['bash', '-c', helper, 'fixture', str(passwd), 'example', number])
                self.assertEqual(result.returncode == 0, success)
            (root / 'safe').mkdir(); (root / 'file').write_text('inert'); (root / 'link').symlink_to(root / 'safe', target_is_directory=True)
            helper = shell_function(template, 'home_path_is_safe') + '\nhome_path_is_safe "$1"'
            for target, success in ((root / 'safe' / 'new', True), (root / 'link' / 'new', False), (root / 'file' / 'new', False), (pathlib.Path('/'), False)):
                result = subprocess.run(['bash', '-c', helper, 'fixture', str(target)])
                self.assertEqual(result.returncode == 0, success)


    def test_zero_success_permission_and_timeout_never_trust_partial_counts(self):
        template = self.discovery.REMOTE_SCRIPT
        helper = shell_function(template, 'emit') + '\n' + shell_function(template, 'collect_ownership_count')
        for dots, status, expected in [('', 0, 'COMPLETE'), ('.....', 0, 'COMPLETE'), ('...', 1, 'FAILED'), ('..', 124, 'TIMEOUT')]:
            with self.subTest(status=status, dots=dots):
                # timeout/find are inert shell functions; no filesystem traversal occurs.
                stubs = '\ntimeout() { printf %s ' + shlex.quote(dots) + '; return ' + str(status) + '; }\n'
                command = helper + stubs + 'collect_ownership_count 22000; status=$?\nif [ "$status" -eq 0 ]; then emit collection_complete COMPLETE; else emit collection_complete INCOMPLETE; fi\nexit "$status"\n'
                result = subprocess.run(['bash', '-c', command], text=True, capture_output=True)
                data = self.discovery.decode_records(result.stdout)
                self.assertEqual(data['ownership_scan_status'], expected)
                self.assertEqual(data['account_owned_file_count'], str(len(dots)) if status == 0 else 'UNAVAILABLE')
                self.assertEqual(data['collection_complete'], 'COMPLETE' if status == 0 else 'INCOMPLETE')
                self.assertEqual(result.returncode, 0 if status == 0 else 1)

    def test_assessment_rejects_incomplete_scans_even_with_successful_transport(self):
        for status in ('FAILED', 'TIMEOUT', ''):
            collection = self.matching_collection(self.policies[0])
            collection['data'].update(ownership_scan_status=status, account_owned_file_count='123')
            result = self.discovery.assess_host('host1.example.invalid', 'example_operator', collection, self.policies[0])
            self.assertEqual(result['overall_status'], 'INCOMPLETE')
            self.assertEqual(result['evidence']['account_owned_file_count'], 'UNAVAILABLE')

    def test_incomplete_remote_collection_retains_status_but_discards_partial_count(self):
        module = self.discovery
        helper = shell_function(module.REMOTE_SCRIPT, 'emit')
        output = subprocess.check_output(['bash', '-c', helper + '\nemit ownership_scan_status TIMEOUT\nemit account_owned_file_count 123\nemit collection_complete INCOMPLETE\n'])
        process = mock.Mock(returncode=1)
        with mock.patch.object(module.shutil, 'which', return_value='/example/ssh'), \
             mock.patch.object(module.pty, 'openpty', return_value=(100, 101)), \
             mock.patch.object(module.subprocess, 'Popen', return_value=process), \
             mock.patch.object(module.select, 'select', return_value=([100], [], [])), \
             mock.patch.object(module.os, 'read', side_effect=[output, b'']), mock.patch.object(module.os, 'close'):
            collection = module.collect_host('host1.example.invalid', 'example_operator', '', self.policies[0])
        self.assertEqual(collection['transport_status'], 'INCOMPLETE')
        self.assertEqual(collection['data']['ownership_scan_status'], 'TIMEOUT')
        self.assertEqual(collection['data']['account_owned_file_count'], 'UNAVAILABLE')
        result = module.assess_host('host1.example.invalid', 'example_operator', collection, self.policies[0])
        self.assertEqual(result['overall_status'], 'INCOMPLETE')


if __name__ == '__main__':
    unittest.main()
