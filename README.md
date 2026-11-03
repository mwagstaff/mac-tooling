# mac-tooling

Personal Mac setup: shell config, prompt, and assorted scripts for managing a Mac and its dev environment.

## Install shell & prompt config

Sets up zsh (aliases, functions, Bitwarden-backed env vars), the oh-my-posh prompt (host-colour-coded, so you can tell machines apart at a glance), the `dev-git-prompt` background git-status banner, and `tabset` (sets the terminal tab title/badge — see [`.zshrc`](shell/.zshrc)'s `setTitle` function).

Run this on a fresh Mac:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/mwagstaff/mac-tooling/main/shell/install.sh)"
```

This will:

1. Check for Xcode Command Line Tools (required; the script exits with instructions if missing).
2. Install [Homebrew](https://brew.sh) if it isn't already present.
3. `brew install oh-my-posh` (from `homebrew/core`; if a prior install came from the upstream `jandedobbeleer/oh-my-posh` tap, it's swapped over automatically), then `brew install` the rest: `zoxide`, `jq`, `bitwarden-cli`, `node`.
4. Clone this repo to `~/dev/mac-tooling` (or pull latest if it's already there).
5. Clone [`iterm2-tab-set`](https://github.com/mwagstaff/iterm2-tab-set) to `~/dev/iterm2-tab-set` (or pull latest) and `npm link` it, which provides the `tabset` command.
6. Run [`shell/setup.sh`](shell/setup.sh), which symlinks `~/.zshenv`, `~/.zshrc` and `~/.config/zsh/dev-git-prompt` to their copies in this repo, then reloads the shell.

Already have the repo cloned? Just run the last step directly:

```bash
zsh ~/dev/mac-tooling/shell/setup.sh
```

Re-running either command is safe — existing correct symlinks are left alone, and anything unexpected in the way is backed up (`<file>.backup.<timestamp>`) rather than overwritten.

### After installing

- Open a new terminal tab (or `exec zsh`) to pick up the config.
- Run `bw login` to enable the Bitwarden-backed environment variables (see `shell/.zshrc`); without it, that feature just stays quietly disabled.

## What's in here

- **`shell/`** — zsh config (`.zshrc`, `.zshenv`), the oh-my-posh theme, and the `dev-git-prompt` background git-status scanner. See above for setup.
- **`git/`** — AI-assisted git helpers: `commit.zsh` (commit + push across all repos under `~/dev`), `status.zsh` (status across all repos), `git-ai-commit.sh`.
- **`hammerspoon/`** — Hammerspoon config (`config/init.lua`) and its own `setup.sh` to symlink it into `~/.hammerspoon`.
- **`apps/`** — `install_apps.sh`, a Homebrew-based app installer for a fresh Mac.
- **`dns/`** — `toggle-dns.sh` for switching between DHCP and manual DNS.
- **`migration/`** — full machine backup/restore to iCloud Drive (shell & git config, SSH keys, Codex/Claude config, GitHub repos, Xcode signing assets). See [`migration/README.md`](migration/README.md).
- **`app-store/`** — reusable screenshot converters for App Store Connect.
- **`work-login/`** — RSA SecurID work-login and Citrix launcher; see [setup and security notes](work-login/README.md).
- **`speak-digits/`** — offline voice-to-digits: `speak-digits.sh` listens for a spoken 6-digit number (e.g. a 2FA code) and prints it. Run `setup.sh` once to create the venv and download the ~70MB Vosk model; after that it needs no Internet.
- **`camera-otp/`** — `camera-otp.sh` opens the built-in FaceTime camera, reads a 6-digit code (e.g. RSA SecurID) from a phone held up to it, copies it to the clipboard and prints it. Fully offline (on-device Vision OCR); compiles itself on first run. Your terminal app needs Camera permission.
- **`camera-screenshot/`** — `camera-screenshot.sh` opens the built-in FaceTime camera, finds a phone screen held up to it (outlined in green), and once it's held still, crops and straightens it and copies it to the clipboard as a PNG. A quick, low-fidelity alternative to AirDropping a screenshot. Fully offline; compiles itself on first run. Your terminal app needs Camera permission.

## Commit and push with `gc`

`gc` scans GitHub-backed projects under `~/dev`, commits working-tree changes,
then fast-forwards the current branch, local `main`, and remote `main` to their
most advanced compatible commit. It leaves the project on `main` and pushes
explicitly to `main`, including commits that already existed before the run.
Projects without a `main` branch get one from their current history.
Projects that are already up to date are omitted from the output.

Diverged histories stop with an error so you can merge them manually and rerun
`gc`. It never force-pushes or deletes branches. Detached checkouts and operations
already in progress are skipped; a `main` checked out in another worktree cannot
be switched to. Other inactive branches are not automatically merged.

Use `gc --dry-run` to preview the actions without changing files or fetching,
or `gc --test-messages` to preview commit messages. Set `COMMIT_ROOT` to limit
execution to another directory or a single repository.

Commit messages use Codex's saved ChatGPT login with `gpt-5.6-luna`. Set
`AI_COMMIT_MODEL` to override the model for `gc`. If Codex is unavailable or
message generation fails, `gc` reports the reason and uses a basic message
based on changed file names, then continues committing and pushing.

## App Store screenshots

The scripts require ImageMagick (`brew install imagemagick`). Give either one
an input image; by default it writes a JPEG beside the original. An optional
second argument chooses the output path.

```bash
~/dev/mac-tooling/app-store/prepare-watch-screenshot.sh "/path/to/Watch capture.png"
~/dev/mac-tooling/app-store/prepare-iphone-screenshot.sh "/path/to/iPhone capture.png"
```

The Watch script produces 416 × 496 for the Apple Watch Series 11 gallery. The
iPhone script produces 1320 × 2868 for the 6.9-inch iPhone gallery. Both fit
the complete capture without cropping or stretching, fill any spare space with
black, remove transparency and metadata, and verify the output dimensions.
Check the size requested by App Store Connect before using either script for
a different device gallery.
