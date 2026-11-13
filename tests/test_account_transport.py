"""Synthetic PTY transport regressions; no SSH, accounts, or credential writes."""
import base64
import errno
import importlib.util
import pathlib
import sys
import types
import unittest
from contextlib import ExitStack
from unittest import mock


ACCOUNT_DIR = pathlib.Path(__file__).resolve().parents[1] / 'linux/local-accounts'


def load_transport(filename):
    policy_spec = importlib.util.spec_from_file_location('account_policy', ACCOUNT_DIR / 'account_policy.py')
    policy_module = importlib.util.module_from_spec(policy_spec)
    policy_spec.loader.exec_module(policy_module)
    spec = importlib.util.spec_from_file_location('account_transport_checks', ACCOUNT_DIR / filename)
    module = importlib.util.module_from_spec(spec)
    with ExitStack() as stack:
        stack.enter_context(mock.patch.dict(sys.modules, {'account_policy': policy_module}))
        # Windows lacks termios; every transport operation is mocked below.
        # This fixture does not establish actual Linux PTY compatibility.
        if sys.platform == 'win32':
            pty_stub = types.ModuleType('pty')
            pty_stub.openpty = mock.Mock(side_effect=AssertionError('Unmocked PTY access'))
            stack.enter_context(mock.patch.dict(sys.modules, {'pty': pty_stub}))
        spec.loader.exec_module(module)
    return module


class AccountTransportChecks:
    def setUp(self):
        self.module = load_transport(self.filename)
        self.policy = self.module.load_policy(ACCOUNT_DIR / 'policy.example.json')

    def records(self, values):
        return ''.join(self.module.MARKER + '\t' + key + '\t' +
                       base64.b64encode(value.encode()).decode() + '\n'
                       for key, value in values.items()).encode()

    def run_transport(self, chunks, times, returncode=0, readiness=None):
        module = self.module
        process = mock.Mock(returncode=returncode)
        process.poll.return_value = returncode
        process.wait.return_value = returncode
        with mock.patch.object(module.shutil, 'which', return_value='/synthetic/tool'), \
             mock.patch.object(module.pty, 'openpty', return_value=(100, 101)), \
             mock.patch.object(module.subprocess, 'Popen', return_value=process) as popen, \
             mock.patch.object(module.select, 'select', return_value=([100], [], []), side_effect=readiness), \
             mock.patch.object(module.os, 'read', side_effect=chunks) as read, \
             mock.patch.object(module.os, 'write', side_effect=AssertionError('Unexpected credential write')) as write, \
             mock.patch.object(module.os, 'close') as close, \
             mock.patch.object(module.time, 'monotonic', side_effect=times):
            if self.filename == 'local_admin_discovery.py':
                result = module.collect_host('host1.example.invalid', 'example_operator', '', self.policy)
            else:
                result = module.run_remote('host1.example.invalid', 'example_operator', '', '',
                                           self.apply_mode, False, self.policy)
        popen.assert_called_once()
        write.assert_not_called()
        self.assertEqual(close.call_args_list, [mock.call(101), mock.call(100)])
        self.assertEqual(read.call_count, len(chunks))
        return result, process

    def test_split_final_record_after_empty_snapshot_and_exit_is_drained(self):
        initial = {'hostname': 'host1.example.invalid'}
        terminal = {self.final_key: self.success_status if self.apply_mode is not None else 'COMPLETE'}
        tail = self.records(terminal)
        chunks = [self.records(initial), tail[:-6], tail[-6:], OSError(errno.EIO, 'Synthetic PTY EOF')]
        ready = ([100], [], [])
        # The child writes its tail and exits between the empty select snapshot
        # and poll. Exit does not prove that the terminal buffer is empty.
        result, process = self.run_transport(
            chunks, range(6), readiness=[ready, ([], [], []), ready, ready, ready])
        self.assertEqual(result[self.status_key], self.success_status)
        self.assertEqual(result['data'], {**initial, **terminal})
        self.assertIsNone(result['error'])
        process.wait.assert_called_once_with(timeout=5)
        process.kill.assert_not_called()

    def test_missing_terminal_record_stays_fail_closed(self):
        partial = {'hostname': 'host1.example.invalid'}
        result, process = self.run_transport([self.records(partial), b''], [0, 1, 2])
        self.assertEqual(result[self.status_key], self.unverified_status)
        self.assertEqual(result['data'], {} if self.apply_mode is None else partial)
        self.assertTrue(result['error'])
        process.wait.assert_called_once_with(timeout=5)
        process.kill.assert_not_called()

    def test_terminal_success_with_nonzero_exit_stays_fail_closed(self):
        terminal = {self.final_key: self.success_status if self.apply_mode is not None else 'COMPLETE'}
        result, process = self.run_transport([self.records(terminal), b''], [0, 1, 2], returncode=255)
        self.assertEqual(result[self.status_key], self.unverified_status)
        self.assertEqual(result['data'], {} if self.apply_mode is None else terminal)
        self.assertTrue(result['error'])
        process.wait.assert_called_once_with(timeout=5)
        process.kill.assert_not_called()

    def test_exited_child_without_terminal_eof_reaches_existing_deadline(self):
        budget = self.module.SSH_TIMEOUT if self.apply_mode is None else self.module.TIMEOUT_SECONDS
        partial = {'hostname': 'host1.example.invalid'}
        result, process = self.run_transport(
            [self.records(partial)], [0, 1, 2, budget],
            readiness=[([100], [], []), ([], [], [])])
        self.assertEqual(result[self.status_key], self.timeout_status)
        self.assertEqual(result['data'], {})
        self.assertIn(f'{budget} seconds', result['error'])
        process.kill.assert_called_once()


class DiscoveryTransportTests(AccountTransportChecks, unittest.TestCase):
    filename = 'local_admin_discovery.py'
    apply_mode = None
    status_key = 'transport_status'
    final_key = 'collection_complete'
    success_status = 'SUCCESS'
    unverified_status = 'ERROR'
    timeout_status = 'UNREACHABLE'


class RemediationDryRunTransportTests(AccountTransportChecks, unittest.TestCase):
    filename = 'local_admin_remediation.py'
    apply_mode = False
    status_key = 'status'
    final_key = 'result'
    success_status = 'DRY_RUN_READY'
    unverified_status = 'UNVERIFIED'
    timeout_status = 'TIMEOUT'


class RemediationApplyTransportTests(RemediationDryRunTransportTests):
    apply_mode = True
    success_status = 'REMEDIATED'


if __name__ == '__main__':
    unittest.main()
