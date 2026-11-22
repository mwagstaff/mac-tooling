# Archive and upload iOS apps

The shell configuration provides `a`, backed by `archive_ios.zsh` and a Python 3
helper. Requires Xcode, its command-line tools, Python 3, and an Apple Developer
account configured for signing. No Fastlane or extra Python packages are required.
Reload your shell with `exec zsh` after installation.

```zsh
a --list
a top-scores --dry-run
a top-scores --archive-only
a top-scores                    # Archives AND uploads to App Store Connect
a train-track --archive-only
a                              # Detect from current directory; archives AND uploads
a --upload-archive '/path/to/App.xcarchive'  # Upload without rebuilding
```

Discovery searches `~/dev` (override with `--root`), ignoring hidden directories,
worktrees, dependencies and build output. Names match repository/project names,
then abbreviations, substrings or globs. Exact names take priority. Ambiguous
matches prompt in a terminal and fail in scripts. `--scheme 'Name'` overrides
scheme selection. Shared schemes with a primary iOS application are selected;
the resolved build settings must identify exactly one phone application. A
workspace explicitly referencing the project takes priority over the project.
Complex workspace groups or schemes requiring custom preparation may need a
project-specific setup before this helper can archive them.

The scheme's archive configuration is used (normally Release), targeting generic
iOS devices. Embedded watch apps/extensions follow the project's dependencies.
Current working files, including uncommitted changes, are built. No source version
numbers are edited. Archives are kept under `~/Library/Developer/Xcode/Archives`,
with an adjacent `.archive.log` and, for uploads, `.distribution` directory holding
export options and `upload.log`. Cancellation or errors preserve those artifacts.
The helper checks embedded app/extension versions against the main app before
uploading. A failed upload prints a retry command.

`--archive-only` never invokes export or upload. `--dry-run` prints build/upload
commands without executing them; Xcode still resolves build settings and may
resolve package dependencies. Ordinary invocations upload immediately, without
a confirmation prompt. Upload uses `app-store-connect`, uploads symbols and lets
Xcode manage upload build numbers. Builds are eligible for external TestFlight
and the App Store, rather than being restricted to internal testers.

By default, Xcode uses its configured developer account. For API-key authentication,
set all three variables below; keep the private key outside repositories:

```zsh
export ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_YOURKEY.p8"
export ASC_KEY_ID="YOURKEY"
export ASC_ISSUER_ID="YOUR_ISSUER_ID"
```

Signing access, certificates/profiles, an App Store Connect app record and account
agreements must be ready. The helper permits Xcode provisioning updates. Upload
success means Apple accepted the transfer, not that processing or review finished.
TestFlight groups, export compliance and App Review remain in App Store Connect.
The helper does not submit a review or release an app publicly.

## Build and run on a device

`i` (backed by `run_ios.zsh`) builds an app with the same project matching as `a`,
installs it on a paired physical device and launches it. The scheme's Run
configuration (normally Debug) and Xcode's default DerivedData are used, so builds
are incremental. The device defaults to "Mike's iPhone" and must be unlocked to launch.

```zsh
i                                  # Pick from a list of all apps
i train-uk
i top*                             # Prompts if several projects match
i --device 'Ippy (Nova’s iPad)' tube
i --list
```

Run automated checks with:

```zsh
python3 -m unittest discover -s app-store -p 'test_*.py'
```
