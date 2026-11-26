"""Observe local agent sessions. Stdout contains only the two Dock indicator states."""
from contextlib import closing
import json
import os
from pathlib import Path
import select
import socket
import sqlite3
import struct
import subprocess
import threading
import time
import uuid

HOME = Path.home()
CLAUDE_SESSIONS = HOME / ".claude/sessions"
IPC = HOME / ".codex/ipc/ipc.sock"
PROMPTS = {
    "item/tool/requestUserInput", "item/tool/requestOptionPicker",
    "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
    "item/permissions/requestApproval", "mcpServer/elicitation/request",
    "execCommandApproval", "applyPatchApproval",
}


def claude_waiting(directory=CLAUDE_SESSIONS):
    for path in directory.glob("*.json"):
        try:
            session = json.loads(path.read_bytes())
            if session.get("status") != "waiting" or session.get("waitingFor") == "dialog open":
                continue
            pid = session["pid"]
            if str(pid) != path.stem or session.get("pidDomain", "darwin") != "darwin":
                continue
            os.kill(pid, 0)
            # A stale file must not follow a recycled process ID after restart.
            if session.get("procStart"):
                started = subprocess.check_output(
                    ["/bin/ps", "-o", "lstart=", "-p", str(pid)], text=True, timeout=2,
                    env={**os.environ, "LC_ALL": "C"})
                if started.split() != session["procStart"].split():
                    continue
            return True
        except (KeyError, ValueError, OSError, subprocess.SubprocessError):
            continue
    return False


def unanswered(turns):
    pending, answered = set(), set()
    for turn in turns:
        for item in turn.get("items", []):
            kind = item.get("type")
            if kind == "agentMessage" and turn.get("status") in ("inProgress", "completed"):
                for index, _ in enumerate(item.get("questions") or []):
                    pending.add(("request_user_input_async", item.get("id"), index))
            if kind == "userMessage":
                content = item.get("content", [])
            elif kind == "steeringUserMessage" and (item.get("status") == "accepted" or item.get("steerAcknowledged")):
                content = item.get("input", [])
            else:
                continue
            for part in content:
                text = part.get("text", "").strip()
                marker = "<send_user_message_question_reply>"
                end = "</send_user_message_question_reply>"
                if part.get("type") != "text" or not text.endswith(end) or marker not in text:
                    continue
                try:
                    rows = json.loads(text.rsplit(marker, 1)[1][:-len(end)])
                    for row in rows if isinstance(rows, list) else [rows]:
                        answered.add(tuple(json.loads(row["questionItemId"])))
                except (ValueError, TypeError, KeyError):
                    pass
    return bool(pending - answered)


def codex_waiting(state):
    status = state.get("threadRuntimeStatus") or {}
    if status.get("type") == "active" and {"waitingOnApproval", "waitingOnUserInput"}.intersection(status.get("activeFlags", [])):
        return True
    if any(r.get("method") in PROMPTS for r in state.get("requests", [])):
        return True
    history = (state.get("turnHistory") or {}).get("history") or {}
    # An async question can outlive its turn. Its reply may arrive in a later one.
    return unanswered([*history.get("entitiesByKey", {}).values(), *state.get("turns", [])])


class UnreadResults:
    def __init__(self, directory):
        self.directory = directory

    def any_completed(self):
        try:
            state = (self.directory / "state_5.sqlite").as_uri() + "?mode=ro"
            history = (self.directory / "thread_history_1.sqlite").as_uri() + "?mode=ro"
            with closing(sqlite3.connect(state, uri=True, timeout=0.2)) as db:
                db.execute("ATTACH DATABASE ? AS history", (history,))
                return bool(db.execute("""
                    SELECT EXISTS (
                        SELECT 1 FROM thread_read_receipts AS receipt
                        JOIN threads AS t ON t.id = receipt.thread_id
                        JOIN history.thread_turns AS result
                          ON result.thread_id = receipt.thread_id
                         AND result.turn_id = receipt.last_published_turn
                        WHERE receipt.first_unread_turn IS NOT NULL
                          AND t.archived = 0 AND result.status = 'completed'
                    )
                """).fetchone()[0])
        except sqlite3.Error:
            return False


def attention_change(patch, waiting):
    path = patch.get("path", [])
    if not path or path[0] in ("requests", "threadRuntimeStatus"):
        return True
    if path[0] not in ("turns", "turnHistory"):
        return False
    if "questions" in path or (waiting and (("status" in path or "steerAcknowledged" in path) or patch.get("op") == "remove")):
        return True
    value = patch.get("value")
    if isinstance(value, dict):
        if value.get("questions") or value.get("type") in ("userMessage", "steeringUserMessage"):
            return True
        if "items" in value or "entitiesByKey" in value or "history" in value:
            return True
    return isinstance(value, list) and (path[-1] in ("items", "turns") or "questions" in path)


def send(sock, **fields):
    payload = json.dumps(fields).encode()
    sock.sendall(struct.pack("<I", len(payload)) + payload)


def desktop_sessions():
    result = subprocess.run(["/opt/homebrew/bin/codexbar", "sessions", "--json"],
                            capture_output=True, timeout=5, check=True)
    return {row["id"] for row in json.loads(result.stdout)
            if row.get("provider") == "codex" and row.get("source") == "desktopApp"}


def observe_codex(sock, indicator):
    # The desktop owns these threads; a separate app-server reports them as notLoaded.
    send(sock, type="request", method="initialize", version=0, sourceClientId="initializing-client",
         requestId=str(uuid.uuid4()), params={"clientType": "dock-attention"})
    client = None
    followed, refresh = set(), set()
    states, revisions, owners = {}, {}, {}
    buffer = bytearray()
    scan_at = sync_at = 0
    while True:
        now = time.monotonic()
        if client and now >= scan_at:
            scan_at = now + 30
            try:
                refresh.update(desktop_sessions() - followed)
            except (OSError, ValueError, subprocess.SubprocessError):
                pass
        if client and refresh and now >= sync_at:
            sync_at = now + 0.3
            for tid in refresh:
                # A follow also requests a current snapshot if already subscribed.
                send(sock, type="broadcast", method="thread-stream-following-changed",
                     version=1, sourceClientId=client,
                     params={"hostId": "local", "conversationId": tid, "following": True})
            refresh.clear()
        if not select.select([sock], [], [], 0.3)[0]:
            continue
        data = sock.recv(256 * 1024)
        if not data:
            return
        buffer.extend(data)
        while len(buffer) >= 4:
            size, = struct.unpack_from("<I", buffer)
            if not 0 < size <= 256 * 1024 * 1024:
                raise ValueError("Invalid desktop event")
            if len(buffer) < 4 + size:
                break
            event = json.loads(buffer[4:4+size])
            del buffer[:4+size]
            method, params = event.get("method"), event.get("params") or {}
            if event["type"] == "client-discovery-request":
                send(sock, type="client-discovery-response", requestId=event["requestId"],
                     response={"canHandle": False})
            elif method == "initialize" and event["type"] == "response":
                client = event["result"]["clientId"]
            elif method == "client-status-changed" and params.get("status") == "disconnected":
                for tid in [t for t, owner in owners.items() if owner == params.get("clientId")]:
                    states.pop(tid, None)
                    owners.pop(tid)
                    revisions.pop(tid, None)
                    refresh.discard(tid)
                    followed.discard(tid)
                scan_at = 0
            elif params.get("hostId") == "local" and (tid := params.get("conversationId")):
                if method == "thread-archived":
                    owners.pop(tid, None)
                    revisions.pop(tid, None)
                    refresh.discard(tid)
                    states.pop(tid, None)
                    followed.discard(tid)
                elif method == "thread-stream-following-status-requested":
                    refresh.add(tid)
                elif method == "thread-stream-state-changed":
                    change = params["change"]
                    if change["type"] == "snapshot":
                        followed.add(tid)
                        owners[tid] = event.get("sourceClientId")
                        states[tid] = codex_waiting(change["conversationState"])
                    elif change.get("baseRevision") != revisions.get(tid) or any(
                            attention_change(p, states.get(tid)) for p in change.get("patches", [])):
                        refresh.add(tid)
                    revisions[tid] = change.get("revision")
                    del change
            del params, event
            if any(states.values()):
                indicator.set()
            else:
                indicator.clear()


def codex_worker(indicator):
    while True:
        try:
            with socket.socket(socket.AF_UNIX) as sock:
                sock.settimeout(5)
                sock.connect(str(IPC))
                observe_codex(sock, indicator)
        except (OSError, ValueError, KeyError, TypeError):
            pass
        indicator.clear()
        time.sleep(3)


if __name__ == "__main__":
    unread = UnreadResults(HOME / ".codex")
    codex = threading.Event()
    threading.Thread(target=codex_worker, args=(codex,), daemon=True).start()
    previous = None
    while True:
        state = {"claude": claude_waiting(), "codex": codex.is_set(), "codexUnread": unread.any_completed()}
        if state != previous:
            print(json.dumps(state), flush=True)
            previous = state
        time.sleep(1)
