#!/usr/bin/env python3
"""Build an iOS app and run it on a connected physical device."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

from archive_ios import capture, choose, discover, names, resolve, scheme_candidates, workspace_for

DEFAULT_DEVICE = "Mike's iPhone"


def normalize(name):
    return name.replace('’', "'").lower()


def find_device(name):
    with tempfile.TemporaryDirectory() as tmp:
        output = Path(tmp) / 'devices.json'
        subprocess.run(['xcrun', 'devicectl', 'list', 'devices', '--json-output', str(output)],
                       check=True, stdout=subprocess.DEVNULL)
        devices = json.loads(output.read_text())['result']['devices']
    for device in devices:
        if (normalize(device['deviceProperties']['name']) == normalize(name)
                and device['hardwareProperties'].get('reality') == 'physical'):
            return device
    raise ValueError(f'No paired physical device named {name!r}. Check `xcrun devicectl list devices`.')


def launch_configuration(project, container, scheme):
    for owner in (container, project):
        file = owner / 'xcshareddata/xcschemes' / f'{scheme}.xcscheme'
        if file.exists():
            action = ET.parse(file).find('LaunchAction')
            if action is not None:
                return action.get('buildConfiguration', 'Debug')
    return 'Debug'


def run(command):
    print(f'$ {" ".join(command)}', flush=True)
    subprocess.run(command, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', nargs='?', help='Repository/project name, partial name, or glob')
    parser.add_argument('--device', default=DEFAULT_DEVICE, help=f'Device name (default: {DEFAULT_DEVICE})')
    parser.add_argument('--list', action='store_true')
    args = parser.parse_args()
    root = (Path.home() / 'dev').resolve()
    projects = discover(root)
    if args.list:
        for project in projects:
            print(f'{names(project, root)[0]}: {project}')
        return
    if args.app:
        project = resolve(projects, root, args.app)
    else:
        labels = {f'{names(p, root)[0]} ({p.stem})': p for p in projects}
        project = labels[choose(list(labels), 'app')]
    container = workspace_for(project)
    scheme = choose(sorted(scheme_candidates(project, container)), 'shared iOS application scheme')
    configuration = launch_configuration(project, container, scheme)
    device = find_device(args.device)
    udid = device['hardwareProperties']['udid']
    selector = ['-workspace' if container.suffix == '.xcworkspace' else '-project', str(container),
                '-scheme', scheme, '-configuration', configuration, '-destination', f'id={udid}']
    print(f'Project: {container}\nScheme: {scheme}\nConfiguration: {configuration}\n'
          f"Device: {device['deviceProperties']['name']} ({udid})", flush=True)
    settings = json.loads(capture(['xcodebuild', *selector, '-showBuildSettings', '-json']))
    apps = [x['buildSettings'] for x in settings
            if x['buildSettings'].get('PRODUCT_TYPE') == 'com.apple.product-type.application'
            and x['buildSettings'].get('PLATFORM_NAME') == 'iphoneos']
    if len(apps) != 1:
        raise ValueError('Selected scheme must build exactly one main iOS app.')
    app = Path(apps[0]['TARGET_BUILD_DIR']) / apps[0]['WRAPPER_NAME']
    bundle_id = apps[0]['PRODUCT_BUNDLE_IDENTIFIER']
    run(['xcodebuild', *selector, '-allowProvisioningUpdates', '-quiet', 'build'])
    run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', device['identifier'], str(app)])
    run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', device['identifier'],
         '--terminate-existing', bundle_id])
    print(f'Launched {bundle_id} on {device["deviceProperties"]["name"]}.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, subprocess.CalledProcessError, OSError, ET.ParseError) as error:
        print(f'Error: {error}', file=sys.stderr)
        sys.exit(1)
    except (KeyboardInterrupt, EOFError):
        print('Cancelled.', file=sys.stderr)
        sys.exit(130)
