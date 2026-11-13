"""Synthetic timeout checks: no SSH, scanner, credentials, or target access."""
import base64
import errno
import importlib.util
import pathlib
import sys
import types
import unittest
from contextlib import ExitStack
from unittest import mock


SOURCE = pathlib.Path(__file__).resolve().parents[1] / 'linux/clamav/clamav_rhel9_discovery.py'


def load_collector():
    spec = importlib.util.spec_from_file_location('clamav_timeout_checks', SOURCE)
    module = importlib.util.module_from_spec(spec)
    # Windows lacks termios. Only this test supplies a PTY stub; every transport
    # operation below is mocked. This does not test Linux PTY compatibility.
    with ExitStack() as stack:
        if sys.platform == 'win32':
            pty_stub = types.ModuleType('pty')
            pty_stub.openpty = mock.Mock(side_effect=AssertionError('Unmocked PTY access'))
            stack.enter_context(mock.patch.dict(sys.modules, {'pty': pty_stub}))
        spec.loader.exec_module(module)
    return module


class ClamavTimeoutTests(unittest.TestCase):
    def setUp(self):
        self.collector = load_collector()

    def records(self, values):
        return ''.join(self.collector.MARKER + '\t' + key + '\t' +
                       base64.b64encode(value.encode()).decode() + '\n'
                       for key, value in values.items()).encode()

    def collect(self, chunks, times, returncode=0, readiness=None):
        module = self.collector
        process = mock.Mock(returncode=returncode)
        process.poll.return_value = returncode
        with mock.patch.object(module.shutil, 'which', return_value='/synthetic/tool'), \
             mock.patch.object(module.pty, 'openpty', return_value=(100, 101)), \
             mock.patch.object(module.subprocess, 'Popen', return_value=process) as popen, \
             mock.patch.object(module.select, 'select', return_value=([100], [], []), side_effect=readiness), \
             mock.patch.object(module.os, 'read', side_effect=chunks), \
             mock.patch.object(module.os, 'write', side_effect=AssertionError('Unexpected credential write')), \
             mock.patch.object(module.os, 'close'), \
             mock.patch.object(module.time, 'monotonic', side_effect=times):
            result = module.ssh_collect('host1.example.invalid', 'example_operator', '')
        return result, process, popen

    def test_complete_collection_after_connection_budget_is_accepted(self):
        # Two healthy scanners can finish at t=110, beyond the 60s SSH-connect
        # allowance. Advancing a fake clock reproduces the old controller bug.
        complete = self.records({'collection_complete': 'COMPLETE',
                                 'clamscan_test': 'rc=0', 'clamdscan_test': 'rc=0'})
        result, process, _ = self.collect([complete, b''], [0, 110, 111])
        self.assertEqual(result['transport_status'], 'SUCCESS')
        process.kill.assert_not_called()

    def test_complete_collection_just_inside_total_budget_is_accepted(self):
        budget = self.collector.COLLECTION_TIMEOUT_SECONDS
        complete = self.records({'collection_complete': 'COMPLETE'})
        result, process, _ = self.collect([complete, b''], [0, budget - 0.2, budget - 0.1])
        self.assertEqual(result['transport_status'], 'SUCCESS')
        process.kill.assert_not_called()

    def test_exited_child_output_is_drained_through_pty_eio(self):
        module = self.collector
        for complete, expected_status in ((True, 'SUCCESS'), (False, 'INCOMPLETE')):
            with self.subTest(complete=complete):
                values = {'hostname': 'host1.example.invalid'}
                chunks = [self.records(values)]
                if complete:
                    values['collection_complete'] = 'COMPLETE'
                    final_record = self.records({'collection_complete': 'COMPLETE'})
                    chunks.extend([final_record[:5], final_record[5:]])
                # Model buffered terminal output after exit, then Linux PTY EOF.
                # This fixture does not exercise an actual PTY or remote process.
                chunks.append(OSError(errno.EIO, 'Synthetic PTY EOF'))
                process = mock.Mock(returncode=0)
                process.poll.return_value = 0
                process.wait.return_value = 0
                with mock.patch.object(module.shutil, 'which', return_value='/synthetic/tool'), \
                     mock.patch.object(module.pty, 'openpty', return_value=(100, 101)), \
                     mock.patch.object(module.subprocess, 'Popen', return_value=process) as popen, \
                     mock.patch.object(module.select, 'select', return_value=([100], [], [])), \
                     mock.patch.object(module.os, 'read', side_effect=chunks) as read, \
                     mock.patch.object(module.os, 'write', side_effect=AssertionError('Unexpected credential write')), \
                     mock.patch.object(module.os, 'close') as close, \
                     mock.patch.object(module.time, 'monotonic', side_effect=range(len(chunks) + 1)), \
                     mock.patch.object(module.time, 'sleep') as sleep:
                    result = module.collect_with_retry('host1.example.invalid', 'example_operator', '')
                self.assertEqual(result['transport_status'], expected_status)
                self.assertEqual(result['data'], values)
                self.assertEqual(result['attempt'], 1)
                self.assertEqual(read.call_count, len(chunks))
                popen.assert_called_once()
                process.wait.assert_called_once_with(timeout=5)
                process.kill.assert_not_called()
                sleep.assert_not_called()
                self.assertEqual(close.call_args_list, [mock.call(101), mock.call(100)])

    def test_child_exit_after_empty_select_does_not_drop_buffered_records(self):
        for complete, expected_status in ((True, 'SUCCESS'), (False, 'INCOMPLETE')):
            with self.subTest(complete=complete):
                initial = {'hostname': 'host1.example.invalid'}
                tail = {'clamscan_test': 'rc=0'}
                if complete:
                    tail['collection_complete'] = 'COMPLETE'
                buffered = self.records(tail)
                chunks = [self.records(initial), buffered[:5], buffered[5:],
                          OSError(errno.EIO, 'Synthetic PTY EOF')]
                # The child writes its tail and exits after select's empty
                # snapshot, before a subsequent process.poll could observe exit.
                ready = ([100], [], [])
                readiness = [ready, ([], [], []), ready, ready, ready]
                result, process, _ = self.collect(chunks, range(6), readiness=readiness)
                self.assertEqual(result['transport_status'], expected_status)
                self.assertEqual(result['data'], {**initial, **tail})
                process.wait.assert_called_once_with(timeout=5)
                process.kill.assert_not_called()

    def test_exited_child_without_terminal_eof_reaches_total_deadline(self):
        partial = {'hostname': 'host1.example.invalid', 'clamscan_test': 'rc=0'}
        result, process, _ = self.collect(
            [self.records(partial)], [0, 1, 2, self.collector.COLLECTION_TIMEOUT_SECONDS],
            readiness=[([100], [], []), ([], [], [])],
        )
        self.assertEqual(result['transport_status'], 'COLLECTION_TIMEOUT')
        self.assertEqual(result['data'], partial)
        process.kill.assert_called_once()
        process.wait.assert_called_once_with(timeout=5)

    def test_total_deadline_preserves_partial_evidence_and_reaps_local_process(self):
        budget = self.collector.COLLECTION_TIMEOUT_SECONDS
        partial = self.records({'hostname': 'host1.example.invalid', 'clamscan_test': 'rc=0'})
        result, process, _ = self.collect([partial], [0, 1, budget])
        self.assertEqual(result['transport_status'], 'COLLECTION_TIMEOUT')
        self.assertEqual(result['data']['clamscan_test'], 'rc=0')
        process.kill.assert_called_once()
        process.wait.assert_called_once_with(timeout=5)
        report = self.collector.assess('host1.example.invalid', result)
        self.assertFalse(report['collection_complete'])
        self.assertEqual(report['evidence']['hostname'], 'host1.example.invalid')
        self.assertEqual(report['findings'][0]['control'], 'COLLECTION_COMPLETENESS')
        self.assertNotIn('scanner_results', report['evidence'])

    def test_connection_timeout_is_not_collection_timeout(self):
        result, process, popen = self.collect(
            [b'ssh: connect to host host1.example.invalid port 22: Connection timed out\n', b''],
            [0, 60, 61], returncode=255,
        )
        self.assertEqual(result['transport_status'], 'UNREACHABLE')
        self.assertEqual(result['data'], {})
        self.assertIn('ConnectTimeout=60', popen.call_args.args[0])
        process.kill.assert_not_called()

    def test_missing_completion_or_unsuccessful_exit_keeps_unassessed_evidence(self):
        for values, code in (({'hostname': 'host1.example.invalid'}, 0),
                             ({'hostname': 'host1.example.invalid', 'collection_complete': 'COMPLETE'}, 255)):
            with self.subTest(code=code, values=values):
                result, _, _ = self.collect([self.records(values), b''], [0, 1, 2], returncode=code)
                self.assertEqual(result['transport_status'], 'INCOMPLETE')
                self.assertEqual(result['data'], values)
                report = self.collector.assess('host1.example.invalid', result)
                self.assertFalse(report['collection_complete'])
                self.assertEqual(report['overall_status'], 'INCOMPLETE')

    def test_transport_exception_keeps_only_structured_evidence(self):
        partial = b'synthetic-unstructured-text\n' + self.records({'hostname': 'host1.example.invalid'})
        result, process, _ = self.collect([partial, RuntimeError('synthetic read failure')], [0, 1, 2])
        self.assertEqual(result['transport_status'], 'ERROR')
        report = self.collector.assess('host1.example.invalid', result)
        self.assertEqual(report['evidence'], {'hostname': 'host1.example.invalid'})
        self.assertFalse(report['collection_complete'])
        self.assertNotIn('synthetic-unstructured-text', str(report))
        process.kill.assert_called_once()
        process.wait.assert_called_once_with(timeout=5)

    def test_incomplete_collection_is_never_retried_or_overwritten(self):
        for status, data in (('COLLECTION_TIMEOUT', {}), ('INCOMPLETE', {'hostname': 'synthetic'}),
                             ('ERROR', {}), ('UNREACHABLE', {'hostname': 'synthetic'})):
            with self.subTest(status=status), \
                 mock.patch.object(self.collector, 'ssh_collect', return_value={
                     'transport_status': status, 'error': 'synthetic', 'data': data,
                 }) as collect, mock.patch.object(self.collector.time, 'sleep') as sleep:
                result = self.collector.collect_with_retry('host1.example.invalid', 'example_operator', '')
                self.assertEqual(result['data'], data)
                self.assertEqual(result['attempt'], 1)
                collect.assert_called_once()
                sleep.assert_not_called()

    def test_precollection_connection_failure_can_retry_once(self):
        failure = {'transport_status': 'UNREACHABLE', 'error': 'synthetic', 'data': {}}
        success = {'transport_status': 'SUCCESS', 'error': None, 'data': {'collection_complete': 'COMPLETE'}}
        with mock.patch.object(self.collector, 'ssh_collect', side_effect=[failure, success]) as collect, \
             mock.patch.object(self.collector.time, 'sleep'):
            result = self.collector.collect_with_retry('host1.example.invalid', 'example_operator', '')
        self.assertEqual(result['transport_status'], 'SUCCESS')
        self.assertEqual(result['attempt'], 2)
        self.assertEqual(collect.call_count, 2)

    def test_scanner_timeout_kill_and_other_failures_are_distinct(self):
        for record, expected in (('rc=0\nclean', 'SUCCESS'), ('rc=124\ntimed out', 'TIMEOUT'),
                                 ('rc=137', 'KILLED'), ('rc=1', 'FAILED'), ('rc=2', 'FAILED'),
                                 ('rc=00', 'FAILED'), ('', 'FAILED'), ('NOT_INSTALLED', 'NOT_INSTALLED')):
            with self.subTest(record=record):
                data = {'os_release': 'ID=rhel\nVERSION_ID=9', 'binary_clamscan': '/synthetic/clamscan',
                        'clamscan_test': record, 'clamdscan_test': 'rc=0',
                        'collection_complete': 'COMPLETE'}
                report = self.collector.assess('host1.example.invalid', {
                    'transport_status': 'SUCCESS', 'data': data,
                })
                self.assertTrue(report['collection_complete'])
                self.assertEqual(report['evidence']['scanner_results']['clamscan'], expected)
                self.assertEqual(report['evidence']['scanner_results']['clamdscan'], 'SUCCESS')
                self.assertEqual(report['evidence']['clamscan_test'], record)
                if expected == 'TIMEOUT':
                    self.assertTrue(any('60-second scan budget' in item['detail'] for item in report['findings']))


if __name__ == '__main__':
    unittest.main()
