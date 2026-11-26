import json
import subprocess
import unittest
from unittest.mock import patch

import phone_status
import run_ios


class PhoneStatusTests(unittest.TestCase):
    def setUp(self):
        self.phone = dict(name='Mike’s iPhone', simulator=False, available=True, identifier='udid')

    def lookup(self, devices):
        result = subprocess.CompletedProcess([], 0, stdout=json.dumps(devices))
        with patch('phone_status.subprocess.run', return_value=result):
            return phone_status.find_available_device(phone_status.DEFAULT_DEVICE)

    def test_available_physical_device_wins(self):
        for transport in ('usb', 'network'):
            device = dict(self.phone, interface=transport)
            self.assertEqual(self.lookup([dict(self.phone, available=False), device]), device)

    def test_remembered_phone_stops_before_any_build_or_prompt(self):
        device = dict(self.phone, available=False, error={'recoverySuggestion': 'Reconnect the cable.'})
        result = subprocess.CompletedProcess([], 0, stdout=json.dumps([device]))
        with patch('sys.argv', ['i']), patch('phone_status.subprocess.run', return_value=result) as run:
            with self.assertRaisesRegex(phone_status.DeviceUnavailable, 'Reconnect the cable'):
                run_ios.main()
            self.assertEqual([call.args[0][:2] for call in run.call_args_list], [['xcrun', 'xcdevice']])

    def test_simulator_and_other_phone_do_not_match(self):
        with self.assertRaises(phone_status.DeviceUnavailable):
            self.lookup([dict(self.phone, simulator=True), dict(self.phone, name='Other')])

    def test_timeout_is_a_check_failure(self):
        with patch('phone_status.subprocess.run', side_effect=subprocess.TimeoutExpired('xcdevice', 12)):
            with self.assertRaisesRegex(ValueError, 'Could not check') as caught:
                phone_status.find_available_device(phone_status.DEFAULT_DEVICE)
            self.assertNotIsInstance(caught.exception, phone_status.DeviceUnavailable)

    def test_current_lock_state_is_independent_of_first_unlock(self):
        for flag in (True, False, None, "false"):
            result = {'unlockedSinceBoot': True, 'passcodeRequired': flag}
            output = subprocess.CompletedProcess([], 0, stdout=json.dumps({'result': result}))
            with patch('phone_status.subprocess.run', return_value=output):
                self.assertIs(phone_status.lock_status('udid'), flag if isinstance(flag, bool) else None)

    def test_lock_query_timeout_leaves_state_unknown(self):
        with patch('phone_status.subprocess.run', side_effect=subprocess.TimeoutExpired('devicectl', 6)):
            self.assertIsNone(phone_status.lock_status('udid'))

    def test_interactive_build_waits_for_confirmed_unlock(self):
        with patch('run_ios.lock_status', side_effect=[True, True, False]) as check, \
                patch('sys.stdin.isatty', return_value=True), patch('run_ios.time.sleep') as sleep, \
                patch('sys.stderr'), patch('builtins.print') as prompt:
            run_ios.wait_for_unlock(self.phone)
        self.assertEqual(sleep.call_count, 2)
        self.assertEqual([call.args for call in check.call_args_list], [('udid',)] * 3)
        prompt.assert_called_once()

    def test_unlocked_device_continues_immediately(self):
        with patch('run_ios.lock_status', return_value=False), patch('run_ios.time.sleep') as sleep:
            run_ios.wait_for_unlock(self.phone)
            sleep.assert_not_called()

    def test_locked_noninteractive_or_unreadable_state_stops(self):
        for state, message in [(True, 'Unlock it'), (None, 'could not confirm')]:
            with patch('run_ios.lock_status', return_value=state), patch('sys.stdin.isatty', return_value=False):
                with self.assertRaisesRegex(ValueError, message):
                    run_ios.wait_for_unlock(self.phone)

    def test_list_skips_connection_check(self):
        with patch('sys.argv', ['i', '--list']), patch('run_ios.discover', return_value=[]), \
                patch('run_ios.find_available_device') as check:
            run_ios.main()
            check.assert_not_called()
