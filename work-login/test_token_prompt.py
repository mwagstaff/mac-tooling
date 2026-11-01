"""Prompt tests with a private pasteboard and stub camera; never touch the real ones."""

import asyncio
import io
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from AppKit import NSPasteboard, NSPasteboardTypeString
from prompt_toolkit import PromptSession
from prompt_toolkit.data_structures import Size
from prompt_toolkit.input import create_pipe_input
from prompt_toolkit.output.vt100 import Vt100_Output

import token_prompt


class ClipboardTests(unittest.TestCase):
    def setUp(self):
        self.pasteboard = NSPasteboard.pasteboardWithUniqueName()
        self.addCleanup(self.pasteboard.releaseGlobally)

    def copy(self, text):
        self.pasteboard.clearContents()
        self.assertTrue(self.pasteboard.setString_forType_(text, NSPasteboardTypeString))

    def test_existing_token_is_ignored_but_same_text_copied_again_is_accepted(self):
        self.copy("000123")
        watcher = token_prompt.ClipboardTokenWatcher(self.pasteboard)
        self.assertIsNone(watcher.poll())
        self.copy("000123")
        self.assertEqual(watcher.poll(), "000123")
        self.assertIsNone(watcher.poll())
        self.assertEqual(self.pasteboard.stringForType_(NSPasteboardTypeString), "000123")

    def test_only_exactly_six_ascii_digits_are_accepted(self):
        watcher = token_prompt.ClipboardTokenWatcher(self.pasteboard)
        for value in ("", "12345", "1234567", "12345678", "123 456", "123456\n",
                      " 123456", "１２３４５６", "token=123456", "abcdef"):
            with self.subTest(value=value):
                self.copy(value)
                self.assertIsNone(watcher.poll())
        self.copy("000000")
        self.assertEqual(watcher.poll(), "000000")

    def test_unchanged_clipboard_text_is_never_read(self):
        pasteboard = Mock()
        pasteboard.changeCount.return_value = 10
        watcher = token_prompt.ClipboardTokenWatcher(pasteboard)
        for _ in range(3):
            self.assertIsNone(watcher.poll())
        pasteboard.stringForType_.assert_not_called()

    def test_copy_that_changes_during_read_is_retried(self):
        pasteboard = Mock()
        pasteboard.changeCount.side_effect = [1, 2, 3, 3, 3]
        pasteboard.stringForType_.side_effect = ["111111", "000123"]
        watcher = token_prompt.ClipboardTokenWatcher(pasteboard)
        self.assertIsNone(watcher.poll())
        self.assertEqual(watcher.poll(), "000123")

    def test_copy_with_pending_text_is_retried(self):
        pasteboard = Mock()
        pasteboard.changeCount.side_effect = [1, 2, 2, 2, 2]
        pasteboard.stringForType_.side_effect = [None, "000123"]
        watcher = token_prompt.ClipboardTokenWatcher(pasteboard)
        self.assertIsNone(watcher.poll())
        self.assertEqual(watcher.poll(), "000123")


class PromptTests(unittest.TestCase):
    def setUp(self):
        self.pasteboard = NSPasteboard.pasteboardWithUniqueName()
        self.addCleanup(self.pasteboard.releaseGlobally)
        self.output = io.StringIO()
        self.watcher_stopped = False

    def run_prompt(self, drive, pasteboard=None, camera=("sleep", "10")):
        original_watch = token_prompt.watch_clipboard

        async def observed_watch(session, watcher):
            try:
                await original_watch(session, watcher)
            finally:
                self.watcher_stopped = True

        async def deadline(session):
            await asyncio.sleep(3)
            if not session.app.is_done:
                session.app.exit(exception=TimeoutError("Test prompt did not finish"))

        with create_pipe_input() as pipe:
            def create_session(**kwargs):
                self.session = PromptSession(input=pipe, **kwargs)
                self.session.app.pre_run_callables.append(lambda: (
                    self.session.app.create_background_task(drive(pipe)),
                    self.session.app.create_background_task(deadline(self.session))))
                return self.session

            native = Mock()
            native.generalPasteboard.return_value = (
                self.pasteboard if pasteboard is None else pasteboard)
            with patch.object(token_prompt, "NSPasteboard", native), \
                    patch.object(token_prompt, "create_output", return_value=Vt100_Output(
                        self.output, lambda: Size(rows=24, columns=120), enable_cpr=False)), \
                    patch.object(token_prompt, "PromptSession", side_effect=create_session), \
                    patch.object(token_prompt, "watch_clipboard", side_effect=observed_watch), \
                    patch.object(token_prompt, "CAMERA_COMMAND", list(camera)):
                return token_prompt.prompt_token()

    def assert_shown(self, token, *absent):
        output = self.output.getvalue()
        self.assertIn(token, output)
        self.assertNotIn("******", output)
        for text in absent:
            self.assertNotIn(text, output)
        self.assertEqual(self.session.history.get_strings(), [])

    def test_manual_entry_is_shown_and_backspace_works(self):
        async def drive(pipe):
            pipe.send_text("00012")
            await asyncio.sleep(0.05)
            pipe.send_text("\x7f34\r")

        self.assertEqual(self.run_prompt(drive), "000134")
        self.assert_shown("000134")
        self.assertTrue(self.watcher_stopped)

    def test_bracketed_paste_is_shown(self):
        async def drive(pipe):
            pipe.send_text("\x1b[200~000123\x1b[201~")
            await asyncio.sleep(0.05)
            pipe.send_text("\r")

        self.assertEqual(self.run_prompt(drive), "000123")
        self.assert_shown("000123")

    def test_dumb_terminal_never_uses_raw_fallback(self):
        async def drive(pipe):
            pipe.send_text("000123\r")

        with patch.dict(os.environ, {"TERM": "dumb"}), \
                patch.object(PromptSession, "_dumb_prompt", side_effect=AssertionError(
                    "Raw fallback must not be used")):
            self.assertEqual(self.run_prompt(drive), "000123")
        self.assert_shown("000123")
        self.assertTrue(self.watcher_stopped)

    def test_new_clipboard_token_replaces_partial_entry_without_enter(self):
        async def drive(pipe):
            pipe.send_text("98")
            await asyncio.sleep(0.05)
            self.pasteboard.clearContents()
            self.pasteboard.setString_forType_("000123", NSPasteboardTypeString)

        self.assertEqual(self.run_prompt(drive), "000123")
        self.assert_shown("000123")
        self.assertTrue(self.watcher_stopped)

    def test_ctrl_c_and_ctrl_d_cancel_and_stop_watching(self):
        for key, exception in (("\x03", KeyboardInterrupt), ("\x04", EOFError)):
            with self.subTest(key=key):
                self.watcher_stopped = False

                async def drive(pipe):
                    await asyncio.sleep(0.05)
                    pipe.send_text(key)

                with self.assertRaises(exception):
                    self.run_prompt(drive)
                self.assertTrue(self.watcher_stopped)

    def test_clipboard_initialization_failure_keeps_manual_entry_available(self):
        pasteboard = Mock()
        pasteboard.changeCount.side_effect = RuntimeError("private clipboard details")

        async def drive(pipe):
            pipe.send_text("000123\r")

        self.assertEqual(self.run_prompt(drive, pasteboard), "000123")
        self.assert_shown("000123", "private clipboard details")
        self.assertIn("clipboard unavailable", self.output.getvalue())

    def test_clipboard_read_failure_keeps_manual_entry_available(self):
        pasteboard = Mock()
        pasteboard.changeCount.side_effect = [1, 2]
        pasteboard.stringForType_.side_effect = RuntimeError("private clipboard details")

        async def drive(pipe):
            await asyncio.sleep(0.3)
            pipe.send_text("000123\r")

        self.assertEqual(self.run_prompt(drive, pasteboard), "000123")
        self.assert_shown("000123", "private clipboard details")
        self.assertIn("clipboard unavailable", self.output.getvalue())
        self.assertTrue(self.watcher_stopped)


    def test_camera_token_is_shown_and_submitted_without_enter(self):
        async def drive(pipe):
            pipe.send_text("98")

        camera = ("sh", "-c", "sleep 0.2; echo 000123")
        self.assertEqual(self.run_prompt(drive, camera=camera), "000123")
        self.assert_shown("000123")
        self.assertTrue(self.watcher_stopped)

    def test_camera_failure_or_bad_output_keeps_manual_entry_available(self):
        for camera in (("sh", "-c", "echo 000123; exit 1"), ("echo", "12345"),
                       ("/nonexistent/camera-otp",)):
            with self.subTest(camera=camera):
                async def drive(pipe):
                    await asyncio.sleep(0.3)
                    pipe.send_text("000456\r")

                self.assertEqual(self.run_prompt(drive, camera=camera), "000456")

    def test_camera_is_stopped_when_prompt_finishes_another_way(self):
        marker = Path(tempfile.mkdtemp()) / "camera-still-running"
        self.addCleanup(lambda: (marker.unlink(missing_ok=True), marker.parent.rmdir()))

        async def drive(pipe):
            pipe.send_text("000123\r")

        camera = ("sh", "-c", f"sleep 0.5; touch '{marker}'")
        self.assertEqual(self.run_prompt(drive, camera=camera), "000123")
        asyncio.run(asyncio.sleep(1))
        self.assertFalse(marker.exists())

if __name__ == "__main__":
    unittest.main()
