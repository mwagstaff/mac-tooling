"""Masked terminal input with a clipboard watcher scoped to this prompt."""

import asyncio
import re

from AppKit import NSPasteboard, NSPasteboardTypeString
from prompt_toolkit import PromptSession
from prompt_toolkit.history import DummyHistory
from prompt_toolkit.output.defaults import create_output

PROMPT = "RSA SecurID token (type + Enter, or copy a fresh 6-digit token): "
MANUAL_PROMPT = "RSA SecurID token (clipboard unavailable; type + Enter): "


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
            session.default_buffer.text = token  # Rendered as ******.
            session.app.exit(result=token)
            return


def prompt_token():
    # Explicit output avoids PromptSession's TERM=dumb fallback, which echoes
    # raw input and skips the watcher startup hook even with is_password=True.
    session = PromptSession(is_password=True, history=DummyHistory(),
                            output=create_output(always_prefer_tty=True))

    def start_watching():
        try:
            watcher = ClipboardTokenWatcher(NSPasteboard.generalPasteboard())
        except Exception:
            session.message = MANUAL_PROMPT
            return
        # The application cancels this task before returning, including Ctrl-C.
        session.app.create_background_task(watch_clipboard(session, watcher))

    return session.prompt(PROMPT, pre_run=start_watching, set_exception_handler=False)
