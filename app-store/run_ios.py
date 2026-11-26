#!/usr/bin/env python3
"""Build an iOS app and run it on a connected physical device."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

from archive_ios import capture, choose, discover, names, resolve, scheme_candidates, workspace_for
from phone_status import DEFAULT_DEVICE, find_available_device, lock_status


def wait_for_unlock(device):
    name = device['name']
    identifier = device['identifier']
    locked = lock_status(identifier)
    if locked:
        if not sys.stdin.isatty():
            raise ValueError(f'{name} is locked. Unlock it and run i again.')
        print(f'Please unlock {name} to start the build. Waiting… (Ctrl-C to cancel)',
              file=sys.stderr, flush=True)
        while locked:
            time.sleep(3)
            locked = lock_status(identifier)
    if locked is None:
        raise ValueError(f'Xcode could not confirm whether {name} is unlocked. '
                         'Check the connection, unlock the device and run i again.')


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
    if args.list:
        for project in discover(root):
            print(f'{names(project, root)[0]}: {project}')
        return
    device = find_available_device(args.device)
    projects = discover(root)
    if args.app:
        project = resolve(projects, root, args.app)
    else:
        labels = {f'{names(p, root)[0]} ({p.stem})': p for p in projects}
        project = labels[choose(list(labels), 'app')]
    container = workspace_for(project)
    scheme = choose(sorted(scheme_candidates(project, container)), 'shared iOS application scheme')
    configuration = launch_configuration(project, container, scheme)
    udid = device['identifier']
    selector = ['-workspace' if container.suffix == '.xcworkspace' else '-project', str(container),
                '-scheme', scheme, '-configuration', configuration, '-destination', f'id={udid}']
    print(f'Project: {container}\nScheme: {scheme}\nConfiguration: {configuration}\n'
          f"Device: {device['name']} ({udid})", flush=True)
    wait_for_unlock(device)
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
    print(f'Launched {bundle_id} on {device["name"]}.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, subprocess.CalledProcessError, OSError, ET.ParseError) as error:
        print(f'Error: {error}', file=sys.stderr)
        sys.exit(1)
    except (KeyboardInterrupt, EOFError):
        print('Cancelled.', file=sys.stderr)
        sys.exit(130)
