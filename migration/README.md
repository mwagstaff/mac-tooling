# New Mac Restore Guide

This folder contains the scripts for backing up key machine data to iCloud Drive and restoring it onto a new Mac.

## What Gets Restored

These scripts cover:

- shell and Git config
- SSH keys and SSH config
- Codex and Claude local config
- GitHub repos under `~/dev`
- Xcode signing identities and provisioning profiles

They do not fully restore:

- app installs
- macOS system settings
- Xcode Apple ID login state

## Recommended Order On The New Mac

1. Install Xcode, Command Line Tools, and Git.
2. Sign in to iCloud Drive and wait for the backup folder to sync locally.
3. Clone this repo or otherwise copy the `migration/` folder onto the new Mac.
4. Restore shell, Git, SSH, and local tooling config.
5. Restore Xcode signing assets if you do iOS/macOS development.
6. Clone your GitHub repos under `~/dev`.
7. Sign back into any tools that do not preserve session state.

## 1. Restore Core Dotfiles And Local Tooling

Pick the timestamped backup directory created by `backup_to_icloud.sh`.

Preview:

```bash
ls -1 ~/Library/Mobile\ Documents/com~apple~CloudDocs/MacBook-Trade-In-Backup
```

Restore:

```bash
bash migration/restore_from_icloud.sh "/Users/$USER/Library/Mobile Documents/com~apple~CloudDocs/MacBook-Trade-In-Backup/YYYY-MM-DD_HH-MM-SS"
```

If any of these already exist on the new machine and you want to replace them:

```bash
bash migration/restore_from_icloud.sh --force "/Users/$USER/Library/Mobile Documents/com~apple~CloudDocs/MacBook-Trade-In-Backup/YYYY-MM-DD_HH-MM-SS"
```

This restores:

- `~/.ssh`
- `~/.zshrc`
- `~/.gitconfig`
- `~/.codex`
- `~/.claude`

## 2. Restore Xcode Signing Assets

Pick the timestamped backup directory created by `backup_xcode_signing_assets.sh`.

Preview:

```bash
ls -1 ~/Library/Mobile\ Documents/com~apple~CloudDocs/MacBook-Trade-In-Backup/Xcode-Signing
```

Restore:

```bash
bash migration/restore_xcode_signing_assets.sh "/Users/$USER/Library/Mobile Documents/com~apple~CloudDocs/MacBook-Trade-In-Backup/Xcode-Signing/YYYY-MM-DD_HH-MM-SS"
```

This restores:

- code-signing identities from `signing-identities.p12` into your login keychain
- provisioning profiles into the standard Xcode/macOS locations

Notes:

- You will be prompted for the PKCS#12 passphrase unless you set `P12_IMPORT_PASSWORD`.
- You may still need to sign back into Xcode via `Xcode > Settings > Accounts`.

Non-interactive import example:

```bash
P12_IMPORT_PASSWORD='your-passphrase' bash migration/restore_xcode_signing_assets.sh "/path/to/backup"
```

## 3. Restore GitHub Repos Under `~/dev`

The repo manifest lives in `migration/repos.tsv`.

Dry run first:

```bash
bash migration/restore_github_repos.sh --dry-run
```

Clone missing repos:

```bash
bash migration/restore_github_repos.sh
```

Update existing repos instead of skipping them:

```bash
bash migration/restore_github_repos.sh --update
```

Use more parallelism if the new Mac and network can handle it:

```bash
bash migration/restore_github_repos.sh --jobs 6
```

Current manifest entries:

- `mac-tooling`
- `healthcheck`
- `my-boris-bikes`
- `server-tooling`
- `top-scores`
- `train-track-uk`

## Suggested Post-Restore Checks

Run these after the restore:

```bash
ls -la ~/.ssh
git config --list --show-origin | sed -n '1,40p'
ssh -T git@github.com
security find-identity -v -p codesigning
```

If SSH reports permission problems, fix the key permissions:

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/config ~/.ssh/* 2>/dev/null
chmod 644 ~/.ssh/*.pub 2>/dev/null
```

## Likely Manual Steps

Expect to do some manual cleanup after the scripted restore:

- sign in to GitHub CLI again if needed
- sign in to Xcode Accounts again
- reinstall apps that are not managed elsewhere
- re-enable any VPN, security, or SSO tooling
- review old provisioning profiles and remove expired ones if necessary

## Backup Scripts Reference

For completeness, the matching backup commands are:

```bash
bash migration/backup_to_icloud.sh
bash migration/backup_xcode_signing_assets.sh
```
