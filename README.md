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
