"""Check whether Xcode can use a named physical device."""
import json
import subprocess

DEFAULT_DEVICE = "Mike's iPhone"


class DeviceUnavailable(ValueError):
    pass


def find_available_device(name, discovery_seconds=3):
    try:
        result = subprocess.run(
            ['xcrun', 'xcdevice', 'list', '--timeout', str(discovery_seconds)],
            capture_output=True, text=True, timeout=12, check=True)
        devices = json.loads(result.stdout)
        if not isinstance(devices, list):
            raise ValueError('Unexpected device list')
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        raise ValueError('Could not check the connection. Check that Xcode and its command-line tools are available, then retry.') from error

    def normalized(value):
        return value.replace('’', "'").casefold()

    matches = [d for d in devices if d.get('simulator') is False
               and d.get('platform') != 'com.apple.platform.macosx'
               and normalized(d.get('name', '')) == normalized(name)]
    for device in matches:
        if device.get('available') is True and device.get('identifier'):
            return device
    advice = 'Unlock the device, reconnect the cable and accept Trust if prompted.'
    for device in matches:
        suggestion = (device.get('error') or {}).get('recoverySuggestion')
        if suggestion:
            advice = ' '.join(suggestion.split())
            break
    raise DeviceUnavailable(f'Xcode cannot reach {name}. {advice}')


if __name__ == '__main__':
    try:
        device = find_available_device(DEFAULT_DEVICE, discovery_seconds=1)
        print(f"Xcode can reach {device['name']}.")
    except DeviceUnavailable as error:
        print(error)
        raise SystemExit(1)
    except ValueError as error:
        print(error)
        raise SystemExit(2)
