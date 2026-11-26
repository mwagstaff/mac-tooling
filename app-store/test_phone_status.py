import json
from pathlib import Path
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

    def test_ipad_rows_use_each_devices_own_connection_and_lock_state(self):
        skyla, nova = phone_status.TARGET_DEVICES.values()
        devices = [dict(self.phone, name=skyla, identifier='skyla'),
                   dict(self.phone, name=nova, identifier='nova')]
        with patch('phone_status.list_devices', return_value=devices), \
                patch('phone_status.lock_status', side_effect={'skyla': True, 'nova': False}.get) as lock:
            self.assertEqual(phone_status.ipad_statuses(), [
                f'{skyla} — Connected · Locked', f'{nova} — Connected · Unlocked'])
            devices[0]['available'] = False
            lock.reset_mock()
            lock.side_effect = [None]
            self.assertEqual(phone_status.ipad_statuses(), [
                f'{skyla} — Unavailable', f'{nova} — Connected · Lock state unknown'])
            lock.assert_called_once_with('nova')

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

    def test_target_selection_and_unlock_between_install_and_launch(self):
        root = Path.home() / 'dev'
        stone = root / 'games/StoneAgeSettlers.xcodeproj'
        princess = root / 'games/otter-and-mosey-princess-ball/PrincessBall.xcodeproj'
        alternate = root / 'games/otter-and-mosey-princess-ball-codex-attempt/PrincessBall.xcodeproj'
        settings = dict(PRODUCT_TYPE='com.apple.product-type.application', PLATFORM_NAME='iphoneos',
                        TARGET_BUILD_DIR='/tmp', WRAPPER_NAME='Game.app', PRODUCT_BUNDLE_IDENTIFIER='test.game')
        for args, name, project in [
            (['stone', 'skyla'], 'Ippygelda (Skyla’s iPad)', stone),
            (['princess', 'nova'], 'Ippy (Nova’s iPad)', princess),
            (['stone'], phone_status.DEFAULT_DEVICE, stone),
            (['--device', 'Other iPad', 'stone'], 'Other iPad', stone),
        ]:
            with self.subTest(args=args):
                events = []
                device = dict(name=name, identifier='selected-udid')
                states = iter([False, True, False])

                def lock(identifier):
                    self.assertEqual(identifier, device['identifier'])
                    events.append('lock check')
                    return next(states)

                def execute(command):
                    if command[0] == 'xcodebuild':
                        self.assertIn('DEVELOPMENT_TEAM=$(inherited:default=SJ8X4DLAN9)', command)
                        self.assertIn(str(project), command)
                        self.assertIn('id=selected-udid', command)
                        events.append('build')
                    else:
                        self.assertEqual(command[command.index('--device') + 1], device['identifier'])
                        events.append(command[3])

                with patch('sys.argv', ['i', *args]), patch('run_ios.discover', return_value=[alternate, stone, princess]), \
                        patch('run_ios.find_available_device', return_value=device) as lookup, \
                        patch('run_ios.workspace_for', return_value=project) as workspace, \
                        patch('run_ios.scheme_candidates', return_value=['Game']), \
                        patch('run_ios.capture', return_value=json.dumps([dict(buildSettings=settings)])), \
                        patch('run_ios.lock_status', side_effect=lock), patch('sys.stdin.isatty', return_value=True), \
                        patch('run_ios.time.sleep'), patch('run_ios.run', side_effect=execute), patch('builtins.print'):
                    run_ios.main()
                lookup.assert_called_once_with(name)
                workspace.assert_called_once_with(project)
                self.assertEqual(events, ['lock check', 'build', 'install', 'lock check', 'lock check', 'process'])

    def test_both_builds_once_and_uses_same_app_on_each_ipad(self):
        project = Path.home() / 'dev/games/StoneAgeSettlers.xcodeproj'
        devices = [dict(name=name, identifier=alias) for alias, name in phone_status.TARGET_DEVICES.items()]
        settings = dict(PRODUCT_TYPE='com.apple.product-type.application', PLATFORM_NAME='iphoneos',
                        TARGET_BUILD_DIR='/tmp', WRAPPER_NAME='Game.app', PRODUCT_BUNDLE_IDENTIFIER='test.game')
        for first_install_fails in [False, True]:
            commands = []

            def execute(command):
                commands.append(command)
                if first_install_fails and 'install' in command and 'skyla' in command:
                    raise subprocess.CalledProcessError(1, command)

            with self.subTest(first_install_fails=first_install_fails), patch('sys.argv', ['i', 'stone', 'both']), \
                    patch('run_ios.find_available_device', side_effect=devices) as lookup, \
                    patch('run_ios.discover', return_value=[project]), patch('run_ios.workspace_for', return_value=project), \
                    patch('run_ios.scheme_candidates', return_value=['Game']), patch('run_ios.wait_for_unlock') as unlock, \
                    patch('run_ios.capture', return_value=json.dumps([dict(buildSettings=settings)])), \
                    patch('run_ios.run', side_effect=execute), patch('builtins.print'):
                if first_install_fails:
                    with self.assertRaisesRegex(ValueError, 'Ippygelda'):
                        run_ios.main()
                else:
                    run_ios.main()
            self.assertEqual([c.args[0] for c in lookup.call_args_list], [d['name'] for d in devices])
            self.assertEqual([c.args for c in unlock.call_args_list], [(d,) for d in devices] +
                             [(d, 'launch the app') for d in (devices[1:] if first_install_fails else devices)])
            builds = [c for c in commands if c[0] == 'xcodebuild']
            self.assertEqual(len(builds), 1)
            self.assertIn('generic/platform=iOS', builds[0])
            self.assertEqual([c[-2:] for c in commands if 'install' in c],
                             [['skyla', '/tmp/Game.app'], ['nova', '/tmp/Game.app']])
            self.assertEqual([c[c.index('--device') + 1] for c in commands if 'launch' in c],
                             ['nova'] if first_install_fails else ['skyla', 'nova'])

    def test_both_stops_before_build_when_second_ipad_is_offline(self):
        with patch('sys.argv', ['i', 'stone', 'both']), patch('run_ios.find_available_device',
                side_effect=[self.phone, phone_status.DeviceUnavailable('Nova is unavailable')]), \
                patch('run_ios.run') as run, self.assertRaisesRegex(ValueError, 'Nova is unavailable'):
            try:
                run_ios.main()
            finally:
                run.assert_not_called()

    def test_list_skips_connection_check(self):
        with patch('sys.argv', ['i', '--list']), patch('run_ios.discover', return_value=[]), \
                patch('run_ios.find_available_device') as check:
            run_ios.main()
            check.assert_not_called()
