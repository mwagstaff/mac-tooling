#!/usr/bin/env python3
"""Discover iOS schemes, archive locally, and optionally upload with Xcode."""
import argparse
from datetime import datetime
import fnmatch
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import subprocess
import sys
import xml.etree.ElementTree as ET

EXCLUDED = {"node_modules", "Pods", "Carthage", "build", "dist", "DerivedData",
            "vendor", "worktrees", ".worktrees"}


def capture(args):
    return subprocess.check_output(args, text=True)


def discover(root):
    projects = []
    for directory, dirs, _ in os.walk(root):
        dirs[:] = sorted(d for d in dirs if not d.startswith('.') and d not in EXCLUDED)
        for name in dirs[:]:
            if name.endswith(('.xcodeproj', '.xcworkspace', '.xcarchive')):
                dirs.remove(name)
                if name.endswith('.xcodeproj'):
                    path = Path(directory) / name
                    projects.append(path)
    return projects


def names(project, root):
    return [project.relative_to(root).parts[0], project.stem, str(project.parent)]


def matches(query, fields):
    fields = [f.lower() for f in fields]
    tokens = query.lower().split()
    def match(token, field):
        if any(c in token for c in '*?['):
            return fnmatch.fnmatchcase(field, token)
        parts = token.split('-')
        if len(parts) > 1 and all(parts):
            words = iter(re.split(r'[-_./\s]+', field))
            if all(any(word.startswith(part) for word in words) for part in parts):
                return True
        return token == field or (len(token) >= 3 and token in field)
    return all(any(match(t, f) for f in fields) for t in tokens)


def choose(items, label):
    if not items:
        raise ValueError(f'No {label} found.')
    if len(items) == 1:
        return items[0]
    listing = '\n'.join(f'  {i}. {item}' for i, item in enumerate(items, 1))
    if not sys.stdin.isatty():
        raise ValueError(f'Ambiguous {label}:\n{listing}\nUse a more specific name or --scheme.')
    print(f'Select {label}:\n{listing}')
    while True:
        answer = input('Number: ')
        if answer.isdigit() and 1 <= int(answer) <= len(items):
            return items[int(answer) - 1]


def resolve(projects, root, query):
    if not query:
        cwd = Path.cwd().resolve()
        candidates = [p for p in projects if cwd == p.parent or cwd in p.parents or p.parent in cwd.parents]
        if not candidates and cwd.is_relative_to(root):
            repo = root / cwd.relative_to(root).parts[0]
            candidates = [p for p in projects if p.is_relative_to(repo)]
    else:
        candidates = [p for p in projects if query.lower() in [n.lower() for n in names(p, root)[:2]]]
        if not candidates:
            candidates = [p for p in projects if matches(query, names(p, root))]
    return choose(candidates, 'Xcode project')


def workspace_for(project):
    project = project.resolve()
    candidates = []
    # Only select workspaces that explicitly reference this project.
    for parent in [project.parent, *project.parent.parents]:
        for workspace in parent.glob('*.xcworkspace'):
            data = workspace / 'contents.xcworkspacedata'
            if data.exists():
                tree = ET.parse(data)
                if any((workspace.parent / ref.get('location', '').removeprefix('group:')).resolve() == project
                       for ref in tree.iter('FileRef')):
                    candidates.append(workspace)
        if (parent / '.git').exists():
            break
    return choose(candidates, 'workspace') if candidates else project


def scheme_candidates(project, container):
    raw = capture(['plutil', '-convert', 'json', '-o', '-', str(project / 'project.pbxproj')])
    objects = json.loads(raw)['objects']
    candidates = {}
    for owner in {project, container}:
        for file in (owner / 'xcshareddata/xcschemes').glob('*.xcscheme'):
            tree = ET.parse(file)
            archive = tree.find('ArchiveAction')
            if archive is None:
                continue
            # The first build entry is the scheme's primary product; extension
            # and watch schemes can also list the host phone app afterwards.
            for entry in tree.findall('./BuildAction/BuildActionEntries/BuildActionEntry')[:1]:
                ref = entry.find('BuildableReference')
                if entry.get('buildForArchiving') != 'YES' or ref is None:
                    continue
                target = objects.get(ref.get('BlueprintIdentifier'), {})
                if target.get('productType') != 'com.apple.product-type.application':
                    continue
                configs = objects.get(target.get('buildConfigurationList'), {}).get('buildConfigurations', [])
                settings = [objects[c].get('buildSettings', {}) for c in configs]
                platforms = ' '.join(str(s.get('SDKROOT', '')) + ' ' + str(s.get('SUPPORTED_PLATFORMS', '')) for s in settings)
                if 'watch' in platforms and 'iphone' not in platforms:
                    continue
                candidates[file.stem] = archive.get('buildConfiguration', 'Release')
    return candidates


def auth_flags():
    values = [os.environ.get(k) for k in ('ASC_KEY_PATH', 'ASC_KEY_ID', 'ASC_ISSUER_ID')]
    if any(values) and not all(values):
        raise ValueError('Set all of ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID, or none.')
    if not all(values):
        return []
    if not Path(values[0]).expanduser().is_file():
        raise ValueError('ASC_KEY_PATH does not exist.')
    return ['-authenticationKeyPath', str(Path(values[0]).expanduser()),
            '-authenticationKeyID', values[1], '-authenticationKeyIssuerID', values[2]]


def run_logged(command, log):
    print(f'Running: {shlex.join(command)}\nLog: {log}', flush=True)
    with log.open('w') as output:
        result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        print('\n'.join(log.read_text(errors='replace').splitlines()[-60:]), file=sys.stderr)
        raise ValueError(f'Xcode failed ({result.returncode}). Full log: {log}')


def validate_archive(archive):
    apps = list((archive / 'Products/Applications').glob('*.app'))
    if len(apps) != 1:
        raise ValueError('Archive must contain exactly one top-level application.')
    def info(bundle):
        with (bundle / 'Info.plist').open('rb') as stream:
            return plistlib.load(stream)
    main = info(apps[0])
    for bundle in apps[0].rglob('*'):
        if bundle.suffix not in ('.app', '.appex') or not bundle.is_dir():
            continue
        embedded = info(bundle)
        for key in ('CFBundleShortVersionString', 'CFBundleVersion'):
            if embedded.get(key) != main.get(key):
                raise ValueError(f'{bundle.name}: {key} differs from the main app. Archive retained at {archive}')
    print(f"Archived {main['CFBundleIdentifier']} {main.get('CFBundleShortVersionString')} ({main.get('CFBundleVersion')})")
    return main


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', nargs='?', help='Repository/project name, partial name, or glob')
    parser.add_argument('--root', type=Path, default=Path.home() / 'dev')
    parser.add_argument('--list', action='store_true')
    parser.add_argument('--scheme')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--archive-only', action='store_true')
    parser.add_argument('--upload-archive', type=Path, help='Retry upload of an existing archive without rebuilding')
    args = parser.parse_args()
    if args.upload_archive and (args.archive_only or args.app or args.scheme):
        parser.error('--upload-archive cannot be combined with an app, --scheme or --archive-only')
    auth = auth_flags()
    if args.upload_archive:
        archive = args.upload_archive.expanduser().resolve()
        validate_archive(archive)
    else:
        root = args.root.expanduser().resolve()
        projects = discover(root)
        if args.list:
            for project in projects:
                print(f'{names(project, root)[0]}: {project}')
            return
        project = resolve(projects, root, args.app)
        container = workspace_for(project)
        schemes = scheme_candidates(project, container)
        scheme = args.scheme or choose(sorted(schemes), 'shared iOS application scheme')
        configuration = schemes.get(scheme, 'Release')
        selector = ['-workspace' if container.suffix == '.xcworkspace' else '-project', str(container), '-scheme', scheme]
        settings_command = ['xcodebuild', *selector, '-configuration', configuration,
                            '-destination', 'generic/platform=iOS', '-showBuildSettings', '-json']
        print(f'Project: {container}\nScheme: {scheme}\nConfiguration: {configuration}', flush=True)
        settings = json.loads(capture(settings_command))
        apps = [x['buildSettings'] for x in settings if x['buildSettings'].get('PRODUCT_TYPE') == 'com.apple.product-type.application'
                and x['buildSettings'].get('PLATFORM_NAME') == 'iphoneos']
        if len(apps) != 1:
            raise ValueError('Selected scheme must archive exactly one main iOS app.')
        app = apps[0]
        print(f"Bundle: {app.get('PRODUCT_BUNDLE_IDENTIFIER')}\nTeam: {app.get('DEVELOPMENT_TEAM')}\nVersion: {app.get('MARKETING_VERSION')} ({app.get('CURRENT_PROJECT_VERSION')})")
        subprocess.run(['git', '-C', str(project.parent), 'status', '--short', '--branch'], check=False)
        stamp = datetime.now().strftime('%Y-%m-%d_%H-%M-%S-%f')
        archive = Path.home() / 'Library/Developer/Xcode/Archives' / stamp[:10] / f'{scheme}_{stamp}.xcarchive'
        command = ['xcodebuild', *selector, '-configuration', configuration, '-destination', 'generic/platform=iOS',
                   '-archivePath', str(archive), '-allowProvisioningUpdates', *auth, 'archive']
        if args.dry_run:
            print(shlex.join(command))
        else:
            archive.parent.mkdir(parents=True, exist_ok=True)
            run_logged(command, archive.with_suffix('.archive.log'))
            validate_archive(archive)
    print(f'Archive: {archive}')
    if args.archive_only:
        print('Archive only: no export or upload performed.')
        return
    export = archive.with_suffix('.distribution')
    options = {'method': 'app-store-connect', 'destination': 'upload',
               'manageAppVersionAndBuildNumber': True, 'uploadSymbols': True,
               'testFlightInternalTestingOnly': False}
    command = ['xcodebuild', '-exportArchive', '-archivePath', str(archive), '-exportPath', str(export),
               '-exportOptionsPlist', str(export / 'ExportOptions.plist'), '-allowProvisioningUpdates', *auth]
    if args.dry_run:
        print(f'Export options: {json.dumps(options)}\n{shlex.join(command)}')
        return
    export.mkdir(parents=True, exist_ok=True)
    with (export / 'ExportOptions.plist').open('wb') as stream:
        plistlib.dump(options, stream)
    try:
        run_logged(command, export / 'upload.log')
    except ValueError:
        print(f'Retry without rebuilding: a --upload-archive {shlex.quote(str(archive))}', file=sys.stderr)
        raise
    print('Uploaded to App Store Connect; awaiting Apple processing. No App Review submission performed.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, subprocess.CalledProcessError, OSError, ET.ParseError) as error:
        print(f'Error: {error}', file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print('Cancelled.', file=sys.stderr)
        sys.exit(130)
