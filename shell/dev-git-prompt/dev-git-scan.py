#!/usr/bin/env python3
"""Read-only Git status worker for dev-git-prompt.zsh (Python 3.8+).

Discovery stops at project repository roots; submodule dirtiness is included
in the parent project's status. Hidden/build/dependency folders and symlinks
are not traversed. No network access, staging, commits, or pushes.
"""
import argparse
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

SKIP = {
    "node_modules", "vendor", "venv", "__pycache__", "DerivedData",
    "Pods", "Carthage", "build", "dist", "coverage", "target",
}


def safe_label(value):
    # Never put terminal escapes, prompt escapes, or shell substitutions in PS1.
    return re.sub(r"[^A-Za-z0-9 ./_+@-]", "_", str(value))[:160]


def discover(root):
    """Find project roots, including projects inside non-repository groups."""
    repos, errors = [], []
    pending = [root]
    while pending:
        directory = pending.pop()
        if (directory / ".git").exists():
            repos.append(directory)
            continue
        try:
            with os.scandir(directory) as entries:
                children = [Path(e.path) for e in entries
                            if not e.name.startswith(".") and e.name not in SKIP
                            and e.is_dir(follow_symlinks=False)]
            pending.extend(sorted(children, reverse=True))
        except OSError:
            errors.append((directory, "unreadable directory"))
    return sorted(repos), errors


def scan(root, timeout=5.0, budget=30.0, heartbeat=None):
    """Return dirty project labels, errors, and number of discovered projects."""
    deadline = time.monotonic() + budget
    repos, errors = discover(root)
    dirty = []
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0")
    for repo in repos:
        if heartbeat:
            heartbeat()  # Detect a closed terminal before starting another Git.
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            errors.append((repo, "scan time budget exceeded"))
            continue
        try:
            result = subprocess.run(
                ["git", "--no-optional-locks", "-C", str(repo),
                 "-c", "core.fsmonitor=false", "status", "--porcelain=v1",
                 "--untracked-files=normal", "--ignore-submodules=none",
                 "--no-renames"],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, env=env,
                timeout=min(timeout, remaining), check=False,
            )
        except subprocess.TimeoutExpired:
            errors.append((repo, "Git status timed out"))
        except OSError:
            errors.append((repo, "Git status unavailable"))
        else:
            if result.returncode:
                errors.append((repo, "invalid or inaccessible repository"))
            elif result.stdout:
                dirty.append(repo)
    return dirty, errors, len(repos)


def label(path, root):
    try:
        text = path.relative_to(root).as_posix()
    except ValueError:
        text = str(path)
    return safe_label(text if text != "." else root.name)


def render(root, dirty, errors, total):
    root_label = "~/dev" if root == Path.home() / "dev" else safe_label(root.name)
    pieces = []
    if dirty:
        count = len(dirty)
        names = [label(p, root)[:28] for p in dirty[:2]]
        if count > 2:
            names.append("+{} more".format(count - 2))
        pieces.append("{} project{} uncommitted ({})".format(
            count, "s" if count != 1 else "", ", ".join(names)))
    if errors:
        pieces.append("{} check{} incomplete".format(
            len(errors), "s" if len(errors) != 1 else ""))
    summary = root_label + ": " + "; ".join(pieces) if pieces else ""
    details = ["Uncommitted: " + label(p, root) for p in dirty]
    details.extend("Unchecked: {} ({})".format(label(p, root), reason)
                   for p, reason in errors)
    if not details:
        details = ["{} project repos checked; no uncommitted changes.".format(total)]
    # One bounded, single-line protocol record. No eval/JSON parser in the prompt.
    return summary + "\t" + " | ".join(details)[:32000] + "\n"


def emit(data):
    payload = data.encode("ascii", "replace")
    # Keep each record <= PIPE_BUF so a nonblocking write is all-or-nothing.
    limit = min(4096, os.fpathconf(sys.stdout.fileno(), "PC_PIPE_BUF"))
    if len(payload) > limit:
        payload = payload[:limit - 16] + b" [truncated]\n"
    # The foreground shell is the sole reader. Never block behind a busy shell.
    try:
        os.write(sys.stdout.fileno(), payload)
    except BlockingIOError:
        pass  # Send a fresh snapshot on the next tick.
    except BrokenPipeError:
        raise SystemExit(0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.home() / "dev")
    parser.add_argument("--interval", type=float, default=15)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    root = args.root.expanduser().absolute()
    if args.once:
        dirty, errors, total = scan(root)
        summary, details = render(root, dirty, errors, total).rstrip("\n").split("\t", 1)
        print(summary or "No uncommitted changes.")
        print(details.replace(" | ", "\n"))
        return 1 if errors else 0
    # Exit promptly when explicitly stopped, including while inside subprocess.run.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    os.set_blocking(sys.stdout.fileno(), False)
    try:
        os.nice(10)
    except OSError:
        pass
    interval = max(5.0, min(args.interval, 3600.0))
    while True:
        dirty, errors, total = scan(root, heartbeat=lambda: emit("\n"))
        frame = render(root, dirty, errors, total)
        # Repeat the current snapshot once per second. This detects closed pipes
        # and lets a prompt immediately catch up after a long foreground command.
        until = time.monotonic() + interval
        while True:
            emit(frame)
            remaining = until - time.monotonic()
            if remaining <= 0:
                break
            time.sleep(min(1.0, remaining))


if __name__ == "__main__":
    raise SystemExit(main())
