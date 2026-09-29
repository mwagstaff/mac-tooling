"""Exercise gc against disposable repositories; no GitHub or Codex calls."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("commit.zsh")
GIT = shutil.which("git")


class CommitMainTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.remote = self.root / "remote.git"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0",
                        GIT_AUTHOR_NAME="Test", GIT_AUTHOR_EMAIL="test@example.com",
                        GIT_COMMITTER_NAME="Test", GIT_COMMITTER_EMAIL="test@example.com")
        # Only remote classification is stubbed; fetch, commit, merge and push use real Git.
        wrapper = self.bin / "git"
        wrapper.write_text('#!/bin/sh\nif [ "$1" = remote ] && [ "$2" = get-url ]; then\n'
                           '  echo https://github.com/test/disposable.git\nelse\n'
                           f'  exec {shlex.quote(GIT)} "$@"\nfi\n')
        wrapper.chmod(0o755)
        codex = self.bin / "codex"
        codex.write_text("#!/bin/sh\nexit 1\n")
        codex.chmod(0o755)
        self.command(GIT, "init", "--bare", str(self.remote))
        self.command(GIT, "init", "-b", "main", str(self.repo))
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "core.hooksPath", os.devnull)
        self.git("remote", "add", "origin", str(self.remote))
        self.commit("base")
        self.git("push", "-u", "origin", "main")
        self.initial = self.git("rev-parse", "HEAD")

    def command(self, *args):
        return subprocess.check_output(args, env=self.env, text=True, stderr=subprocess.STDOUT).strip()

    def git(self, *args):
        return self.command(GIT, "-C", str(self.repo), *args)

    def commit(self, name):
        (self.repo / name).write_text(name + "\n")
        self.git("add", "-A")
        self.git("commit", "-m", name)

    def run_gc(self, *args, success=True):
        env = dict(self.env, COMMIT_ROOT=str(self.repo), GIT_TOOL_JOBS="1",
                   PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        result = subprocess.run(["zsh", str(SCRIPT), *args], env=env,
                                text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0 if success else 1, result.stdout + result.stderr)
        return result.stdout

    def assert_pushed_main(self):
        self.assertEqual(self.git("branch", "--show-current"), "main")
        remote_head = self.command(GIT, "--git-dir", str(self.remote), "rev-parse", "main")
        self.assertEqual(self.git("rev-parse", "HEAD"), remote_head)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_clean_unpushed_commit(self):
        self.commit("unpushed")
        output = self.run_gc()
        self.assertIn("==> ", output)
        self.assertIn("0 committed, 1 pushed", output)
        self.assert_pushed_main()
        self.assertNotEqual(self.git("rev-parse", "HEAD"), self.initial)

    def test_up_to_date_repository_is_silent(self):
        output = self.run_gc()
        self.assertNotIn("==> ", output)
        self.assertNotIn("Already up to date", output)
        self.assertIn("0 committed, 0 pushed, 0 skipped, 0 failed", output)

    def test_dirty_feature_pushes_only_main(self):
        self.git("switch", "-c", "feature")
        self.git("push", "-u", "origin", "feature")
        (self.repo / "new-file").write_text("pending\n")
        self.run_gc()
        self.assert_pushed_main()
        self.assertEqual(self.command(GIT, "--git-dir", str(self.remote), "rev-parse", "feature"), self.initial)
        self.assertTrue((self.repo / "new-file").exists())

    def test_clean_feature_is_consolidated(self):
        self.git("switch", "-c", "feature")
        self.commit("feature-work")
        self.run_gc()
        self.assert_pushed_main()

    def test_behind_main_fetches_before_pushing(self):
        self.git("switch", "-c", "advance")
        self.commit("remote-work")
        self.git("push", "origin", "HEAD:main")
        self.git("switch", "main")
        output = self.run_gc()
        self.assertIn("==> ", output)
        self.assertIn("0 committed, 0 pushed", output)
        self.assert_pushed_main()
        self.assertTrue((self.repo / "remote-work").exists())

    def test_divergence_preserves_both_histories(self):
        self.git("switch", "-c", "feature")
        self.commit("feature-work")
        feature = self.git("rev-parse", "HEAD")
        self.git("switch", "main")
        self.commit("main-work")
        main = self.git("rev-parse", "HEAD")
        self.git("switch", "feature")
        self.assertIn("diverged", self.run_gc(success=False))
        self.assertEqual(self.git("rev-parse", "HEAD"), feature)
        self.assertEqual(self.git("rev-parse", "main"), main)
        self.assertEqual(self.command(GIT, "--git-dir", str(self.remote), "rev-parse", "main"), self.initial)

    def test_master_without_main_creates_main(self):
        self.git("branch", "-m", "master")
        self.command(GIT, "--git-dir", str(self.remote), "update-ref", "-d", "refs/heads/main")
        self.run_gc()
        self.assert_pushed_main()

    def test_dry_run_does_not_stage_commit_or_switch(self):
        self.git("switch", "-c", "feature")
        (self.repo / "pending").write_text("pending\n")
        before = self.git("status", "--porcelain")
        self.run_gc("--dry-run")
        self.assertEqual(self.git("status", "--porcelain"), before)
        self.assertEqual(self.git("branch", "--show-current"), "feature")
        self.assertEqual(self.git("rev-parse", "HEAD"), self.initial)

    def test_main_in_another_worktree_is_preserved(self):
        self.git("switch", "-c", "feature")
        self.commit("feature-work")
        self.git("worktree", "add", str(self.root / "other"), "main")
        self.run_gc(success=False)
        self.assertEqual(self.git("branch", "--show-current"), "feature")
        self.assertEqual(self.git("rev-parse", "main"), self.initial)

    def test_detached_head_is_skipped(self):
        self.git("switch", "--detach")
        self.assertIn("HEAD is detached", self.run_gc())
        self.assertEqual(self.git("branch", "--show-current"), "")


if __name__ == "__main__":
    unittest.main()
