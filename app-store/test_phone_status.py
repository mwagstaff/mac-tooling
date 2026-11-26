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

    def test_list_skips_connection_check(self):
        with patch('sys.argv', ['i', '--list']), patch('run_ios.discover', return_value=[]), \
                patch('run_ios.find_available_device') as check:
            run_ios.main()
            check.assert_not_called()
