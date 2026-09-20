#!/usr/bin/env python3
"""Integration tests for the worker, using isolated local Git repositories."""
import importlib.util
import os
import subprocess
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("scanner", Path(__file__).with_name("dev-git-scan.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
checks = 0

def check(condition, message):
    global checks
    assert condition, message
    checks += 1
    print("PASS:", message)

def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)

def new(root, name):
    p = root / name
    p.mkdir(parents=True)
    git(p, "init", "-q")
    git(p, "config", "user.name", "Test")
    git(p, "config", "user.email", "test@example.invalid")
    (p / "tracked").write_text("one\n")
    git(p, "add", "tracked")
    git(p, "commit", "-qm", "initial")
    return p

with tempfile.TemporaryDirectory() as t:
    root = Path(t) / "dev"
    root.mkdir()
    clean = new(root, "clean")
    dirty, errors, total = m.scan(root)
    check((dirty, errors, total) == ([], [], 1), "clean project has no warning")
    (clean / "new-file").write_text("new")
    check(m.scan(root)[0] == [clean], "untracked file is detected")
    git(clean, "add", "new-file")
    check(m.scan(root)[0] == [clean], "staged addition is detected")
    git(clean, "commit", "-qm", "new")
    (clean / "tracked").write_text("changed\n")
    check(m.scan(root)[0] == [clean], "unstaged modification is detected")
    git(clean, "restore", "tracked")
    (clean / "tracked").unlink()
    check(m.scan(root)[0] == [clean], "unstaged deletion is detected")
    git(clean, "restore", "tracked")
    (clean / ".gitignore").write_text("ignored\n.claude/\n")
    git(clean, "add", ".gitignore")
    git(clean, "commit", "-qm", "ignore")
    (clean / "ignored").write_text("ignore me")
    check(not m.scan(root)[0], "gitignored files do not produce warnings")
    git(clean, "checkout", "--detach")
    (clean / "tracked").write_text("detached edit")
    check(m.scan(root)[0] == [clean], "detached HEAD with changes is not skipped")
    git(clean, "restore", "tracked")
    broken_claude = clean / ".claude/worktrees/obsolete"
    broken_claude.mkdir(parents=True)
    (broken_claude / ".git").write_text("gitdir: /nonexistent/old-name/.git/worktrees/x\n")
    check(m.scan(root) == ([], [], 1), "generated Claude worktree is not scanned independently")
    grouped = new(root, "group/project with spaces")
    (grouped / "tracked").write_text("changed")
    check(m.scan(root)[0] == [grouped], "grouped projects and spaces are supported")
    unborn = root / "unborn"
    unborn.mkdir()
    git(unborn, "init", "-q")
    (unborn / "new").write_text("new")
    check(unborn in m.scan(root)[0], "repository with no commits is supported")
    broken = root / "broken"
    broken.mkdir()
    (broken / ".git").write_text("gitdir: /nonexistent/worktree\n")
    d, e, n = m.scan(root)
    check(len(e) == 1 and e[0][0] == broken, "broken repository is unknown, not clean")
    tracked_index = grouped / ".git/index"
    before = tracked_index.read_bytes(), tracked_index.stat().st_mtime_ns
    m.scan(root)
    after = tracked_index.read_bytes(), tracked_index.stat().st_mtime_ns
    check(before == after, "status scan does not rewrite the Git index")
    old = os.environ.get("GIT_DIR")
    os.environ["GIT_DIR"] = "/nonexistent"
    check(grouped in m.scan(root)[0], "inherited GIT_DIR cannot redirect scans")
    if old is None:
        os.environ.pop("GIT_DIR")
    else:
        os.environ["GIT_DIR"] = old
    check(m.safe_label('bad%F{red}$(touch x)\n\x1b') == 'bad_F_red___touch x___',
          "repository labels cannot inject prompt syntax")
    check(bool(m.scan(root / "missing")[1]), "missing root is unknown, not clean")
    check("incomplete" in m.render(root, d, e, n), "incomplete scans have a visible warning")
    worker = subprocess.Popen(["python3", str(Path(__file__).with_name("dev-git-scan.py")),
                               "--root", str(root)], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE)
    while True:
        frame = worker.stdout.readline()
        if b"\t" in frame:
            break
    check(b"projects uncommitted" in frame, "background worker emits a complete snapshot")
    worker.stdout.close()
    worker.wait(timeout=8)
    check(worker.returncode == 0 and worker.stderr.read() == b"",
          "worker exits quietly after its prompt closes")
print("{} scanner checks passed.".format(checks))
