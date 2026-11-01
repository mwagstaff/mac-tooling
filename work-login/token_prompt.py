"""Terminal token input with clipboard and camera watchers scoped to this prompt."""

import asyncio
import contextlib
import re
from pathlib import Path

from AppKit import NSPasteboard, NSPasteboardTypeString
from prompt_toolkit import PromptSession
from prompt_toolkit.history import DummyHistory
from prompt_toolkit.output.defaults import create_output

PROMPT = ("RSA SecurID token (type + Enter, copy a fresh 6-digit token, "
          "or hold your phone up to the camera): ")
MANUAL_PROMPT = "RSA SecurID token (clipboard unavailable; type + Enter or use the camera): "
# Prints a 6-digit code read from the phone held up to the camera, then exits.
CAMERA_COMMAND = [str(Path(__file__).resolve().parent.parent / "camera-otp" / "camera-otp.sh")]


class ClipboardTokenWatcher:
    def __init__(self, pasteboard):
        self.pasteboard = pasteboard
        # Snapshot metadata only: never consume text copied before the prompt.
        self.change_count = pasteboard.changeCount()

    def poll(self):
        count = self.pasteboard.changeCount()
        if count == self.change_count:
            return None
        text = self.pasteboard.stringForType_(NSPasteboardTypeString)
        # Retry a changing or not-yet-populated pasteboard on the next poll.
        if self.pasteboard.changeCount() != count or text is None:
            return None
        self.change_count = count
        if re.fullmatch(r"[0-9]{6}", text):
            return text
        return None


async def watch_clipboard(session, watcher):
    while True:
        await asyncio.sleep(0.2)
        if session.app.is_done:
            return
        try:
            token = watcher.poll()
        except Exception:
            # Clipboard failures should leave manual entry usable, without
            # printing exceptions that might contain clipboard contents.
            session.message = MANUAL_PROMPT
            session.app.invalidate()
            return
        if token is not None:
            submit(session, token)
            return


async def watch_camera(session):
    try:
        process = await asyncio.create_subprocess_exec(
            *CAMERA_COMMAND, stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
    except OSError:
        return  # Camera unavailable; typing and clipboard still work.
    try:
        output, _ = await process.communicate()
    finally:
        # Prompt finished another way (or was cancelled): release the camera.
        if process.returncode is None:
            with contextlib.suppress(ProcessLookupError):
                process.terminate()
            await process.wait()
    token = output.decode(errors="replace").strip()
    if process.returncode == 0 and re.fullmatch(r"[0-9]{6}", token) and not session.app.is_done:
        submit(session, token)


def submit(session, token):
    session.default_buffer.text = token
    session.app.exit(result=token)


def prompt_token():
    # Explicit output avoids PromptSession's TERM=dumb fallback, which echoes
    # raw input and skips the watcher startup hook.
    session = PromptSession(history=DummyHistory(),
                            output=create_output(always_prefer_tty=True))

    def start_watching():
        # The application cancels these tasks before returning, including Ctrl-C.
        session.app.create_background_task(watch_camera(session))
        try:
            watcher = ClipboardTokenWatcher(NSPasteboard.generalPasteboard())
        except Exception:
            session.message = MANUAL_PROMPT
            return
        session.app.create_background_task(watch_clipboard(session, watcher))

    return session.prompt(PROMPT, pre_run=start_watching, set_exception_handler=False)
