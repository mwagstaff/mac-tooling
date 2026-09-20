# Asynchronous ~/dev Git prompt warning

This package adds a yellow informational line ABOVE an existing zsh prompt:

    ~/dev: 3 projects uncommitted (top-scores, train-track-uk, +1 more)
    <your normal Oh My Posh prompt and command line>

It disappears when the scanned projects are clean. Errors produce an
"incomplete" warning rather than a false all-clear.

## Installation

Save dev-git-prompt.zip to Downloads. In zsh:

```zsh
mkdir -p "$HOME/.config/zsh"
unzip -o "$HOME/Downloads/dev-git-prompt.zip" -d "$HOME/.config/zsh"
zsh -n "$HOME/.config/zsh/dev-git-prompt/dev-git-prompt.zsh"
```

If the syntax check succeeds (no output), append the following line at the END
of ~/.zshrc, after Oh My Posh initialization and other prompt hooks:

```zsh
source "$HOME/.config/zsh/dev-git-prompt/dev-git-prompt.zsh"
```

Back up ~/.zshrc before editing it. Then run `reload` (or `exec zsh`). Do not
replace your existing ~/.zshrc or your theme. Your Mac and GitHub repositories
have not been modified by preparing this package.

Requirements: zsh 5.8+ with its standard zsh/system module, Git, and Python 3.8+.
Python is resolved at initialization, so later virtual-environment changes do
not change the worker interpreter.

## Useful commands

`dev-dirty` prints the latest cached result and affected project names. It does
not start another scan. Very large lists are explicitly marked [truncated] to
keep messages through the prompt pipe bounded.

`dev-git-refresh` requests a fresh asynchronous scan immediately.

`dev-git-prompt-off` stops this feature for the current shell.

For an explicit, synchronous diagnostic scan with the full list:

```zsh
python3 "$HOME/.config/zsh/dev-git-prompt/dev-git-scan.py" --root "$HOME/dev" --once
```

Change the interval by placing this BEFORE the source line in ~/.zshrc:

```zsh
DEV_GIT_INTERVAL=30
```

The default is a 15-second pause between scans; scan time is additional. The
minimum is five seconds. You can also change DEV_GIT_ROOT. Use
`dev-git-refresh` after changing these variables in an already running shell.

## Scope and safeguards

Discovery starts at ~/dev and descends through ordinary grouping folders until
it finds a project repository. It then stops descending into that project.
This counts projects, not every nested Git working tree. Submodule changes are
included in the parent project's Git status. Standalone linked worktrees found
as project roots are supported, including detached HEADs.

Hidden folders (including .claude and .codex), directory symlinks, and common
dependency/build folders are not traversed. Generated .claude/worktrees inside
your projects are not scanned independently. However, a worktree accidentally
tracked as a gitlink by its parent may still make that parent dirty; this is
real Git state, not something the monitor should hide.

Staged changes, unstaged edits/deletions and untracked, non-ignored files all
count. Unpushed commits, stashes, ignored files and unsaved editor buffers do
not. This code never stages, commits, pushes, fetches or runs an AI request.

Git runs with --no-optional-locks, no interactive input, a per-repository
timeout and a total Git-scan time budget. The Git-related environment is
cleared in the worker's child commands to avoid inherited GIT_DIR or
GIT_INDEX_FILE pointing a scan at the wrong repository. Custom fsmonitor
hooks are disabled for this background check. No Git config files are changed.

The worker has lower CPU scheduling priority where supported. There is one
worker per shell, with sequential scans. Many open tabs multiply background
work; increase the interval if needed. This is asynchronous, not zero-cost:
background filesystem/CPU work and tiny in-memory prompt updates still exist.

## Prompt behavior

No Git scans or directory walks run in precmd or in prompt expansion. A
background Python process delivers bounded messages over a pipe; zsh consumes
them through zle -F and nonblocking sysread, and calls .reset-prompt only when
the warning changes. The input buffer and cursor are not assigned or replaced.
The existing right-hand prompt is untouched. Updates arrive while ZLE is
editing a command line, including when the terminal is idle. During a
foreground command they are queued, not printed over command output.

The helper is intended for your current standard Oh My Posh initialization.
It adds its prefix after the theme's precmd hook. A theme or plugin that later
replaces PROMPT asynchronously may overwrite the prefix; integration with
that additional renderer would need adjustment. This package does not change
Oh My Posh's own async/transient settings or call the Oh My Posh executable
from callbacks.

Re-sourcing closes the previous pipe and removes this helper's hooks before
registering them again. Close-on-exec prevents the reader surviving `reload`.
The worker exits quietly when the pipe closes. A Git subprocess already in
progress may finish or reach its timeout before the worker notices.

## Testing

The included scanner test suite passed 18 integration checks with temporary
real Git repositories in Linux. It covers clean/staged/unstaged/untracked and
ignored states, unborn repositories, detached HEADs, grouping folders, spaces,
broken worktree references, prompt-label sanitization, index preservation,
inherited GIT_DIR, worker output and exit when its reader closes.

The zsh/Oh My Posh/iTerm2 rendering integration has NOT been executed here:
this environment does not have zsh or your Mac session. Use the syntax check
above, then verify that a test edit produces a warning, committing it clears
the warning, and partially typed input stays intact during a refresh.

Run the scanner tests explicitly with:

```sh
python3 test-scanner.py
```

## Uninstall

Remove the added source line from ~/.zshrc and run `reload`. You may then
delete ~/.config/zsh/dev-git-prompt. No repository configuration needs undoing.

## References

- Zsh file-descriptor handlers and prompt redraw:
  https://zsh.sourceforge.io/Doc/Release/Zsh-Line-Editor.html
- Zsh sysopen, close-on-exec and nonblocking sysread:
  https://zsh.sourceforge.io/Doc/Release/Zsh-Modules.html#The-zsh_002fsystem-Module
- Git background status and optional locks:
  https://git-scm.com/docs/git-status#_background_refresh
