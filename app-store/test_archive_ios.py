import contextlib
import io
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

import archive_ios as archive


class ArchiveTests(unittest.TestCase):
    def test_discovery_excludes_dependencies_and_worktrees(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            expected = root / 'games/nested/My App.xcodeproj'
            for path in [expected, root / 'node_modules/Bad.xcodeproj', root / '.worktrees/Bad.xcodeproj',
                         root / 'worktrees/Bad.xcodeproj']:
                path.mkdir(parents=True)
            self.assertEqual(archive.discover(root), [expected])

    def test_exact_name_wins_and_ambiguity_fails_without_terminal(self):
        root = Path('/dev')
        projects = [root / 'top-scores/ios/Top Scores.xcodeproj', root / 'top-scores-soccer/App.xcodeproj']
        self.assertEqual(archive.resolve(projects, root, 'TOP-SCORES'), projects[0])
        with patch('sys.stdin.isatty', return_value=False), self.assertRaisesRegex(ValueError, 'Ambiguous'):
            archive.resolve(projects, root, 'top')
        self.assertTrue(archive.matches('t-sc', ['top-scores']))
        self.assertTrue(archive.matches('train*', ['train-track-uk']))

    def test_workspace_must_reference_project(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / '.git').mkdir()
            project = root / 'My App.xcodeproj'
            project.mkdir()
            for name, reference in [('App', 'My App'), ('Other', 'Unrelated')]:
                workspace = root / f'{name}.xcworkspace'
                workspace.mkdir()
                (workspace / 'contents.xcworkspacedata').write_text(
                    f'<Workspace><FileRef location="group:{reference}.xcodeproj"/></Workspace>')
            self.assertEqual(archive.workspace_for(project), (root / 'App.xcworkspace').resolve())

    def test_host_app_in_extension_scheme_is_not_selected(self):
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp) / 'App.xcodeproj'
            schemes = project / 'xcshareddata/xcschemes'
            schemes.mkdir(parents=True)
            objects = {'phone': {'productType': 'com.apple.product-type.application', 'buildConfigurationList': 'pc'},
                       'watch': {'productType': 'com.apple.product-type.application', 'buildConfigurationList': 'wc'},
                       'widget': {'productType': 'com.apple.product-type.app-extension'},
                       'pc': {'buildConfigurations': ['p']}, 'wc': {'buildConfigurations': ['w']},
                       'p': {'buildSettings': {'SDKROOT': 'iphoneos'}}, 'w': {'buildSettings': {'SDKROOT': 'watchos'}}}
            for name, targets in [('Phone', ['phone']), ('Watch', ['watch', 'phone']), ('Widget', ['widget', 'phone'])]:
                entries = ''.join(f'<BuildActionEntry buildForArchiving="YES"><BuildableReference BlueprintIdentifier="{t}"/></BuildActionEntry>' for t in targets)
                (schemes / f'{name}.xcscheme').write_text(f'<Scheme><BuildAction><BuildActionEntries>{entries}</BuildActionEntries></BuildAction><ArchiveAction buildConfiguration="Release"/></Scheme>')
            with patch.object(archive, 'capture', return_value=json.dumps({'objects': objects})):
                self.assertEqual(archive.scheme_candidates(project, project), {'Phone': 'Release'})

    def test_archive_only_never_exports_and_upload_retry_does_not_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            project = root / 'top-scores/App.xcodeproj'
            project.mkdir(parents=True)
            settings = [{'buildSettings': {'PRODUCT_TYPE': 'com.apple.product-type.application', 'PLATFORM_NAME': 'iphoneos'}}]
            commands = []
            def run(command, log):
                commands.append(command)
                if 'archive' in command:
                    output = Path(command[command.index('-archivePath') + 1]) / 'Products/Applications/App.app'
                    output.mkdir(parents=True)
                    with (output / 'Info.plist').open('wb') as stream:
                        plistlib.dump({'CFBundleIdentifier': 'example.app', 'CFBundleVersion': '1',
                                       'CFBundleShortVersionString': '1.0'}, stream)
            with patch.object(Path, 'home', return_value=root), patch.object(archive, 'auth_flags', return_value=[]), \
                 patch.object(archive, 'scheme_candidates', return_value={'App': 'Release'}), \
                 patch.object(archive, 'capture', return_value=json.dumps(settings)), \
                 patch.object(archive.subprocess, 'run'), patch.object(archive, 'run_logged', side_effect=run), \
                 contextlib.redirect_stdout(io.StringIO()):
                with patch('sys.argv', ['a', 'top-scores', '--root', str(root), '--archive-only']):
                    archive.main()
                self.assertEqual(len(commands), 1)
                self.assertIn('archive', commands[0])
                saved = commands[0][commands[0].index('-archivePath') + 1]
                with patch('sys.argv', ['a', '--upload-archive', saved]):
                    archive.main()
                self.assertEqual(len(commands), 2)
                self.assertIn('-exportArchive', commands[1])
                options = Path(commands[1][commands[1].index('-exportOptionsPlist') + 1])
                with options.open('rb') as stream:
                    self.assertEqual(plistlib.load(stream)['destination'], 'upload')
                with patch.object(archive, 'run_logged', side_effect=ValueError('upload failed')), \
                     patch('sys.argv', ['a', '--upload-archive', saved]), \
                     contextlib.redirect_stderr(io.StringIO()) as errors, self.assertRaises(ValueError):
                    archive.main()
                self.assertIn('Retry without rebuilding', errors.getvalue())
                self.assertTrue(Path(saved).exists())
                with patch.object(archive, 'run_logged') as runner, \
                     patch('sys.argv', ['a', '--upload-archive', saved, '--dry-run']):
                    archive.main()
                    runner.assert_not_called()

    def test_mismatched_extension_version_blocks_upload(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app = root / 'Products/Applications/App.app'
            extension = app / 'PlugIns/Widget.appex'
            extension.mkdir(parents=True)
            for bundle, version in [(app, '2'), (extension, '1')]:
                with (bundle / 'Info.plist').open('wb') as stream:
                    plistlib.dump({'CFBundleIdentifier': 'example.app', 'CFBundleVersion': version}, stream)
            with self.assertRaisesRegex(ValueError, 'differs'):
                archive.validate_archive(root)


if __name__ == '__main__':
    unittest.main()
