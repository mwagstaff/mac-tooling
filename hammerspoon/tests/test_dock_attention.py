import json
from pathlib import Path
import runpy
import sqlite3
import tempfile
import unittest

helper = Path(__file__).resolve().parents[1] / "config" / "dock-attention.py"
module = runpy.run_path(str(helper))
codex_waiting = module["codex_waiting"]


class DockAttentionTests(unittest.TestCase):
    def test_question_outlives_turn_until_all_answers_arrive(self):
        question = {"type": "agentMessage", "id": "call_1", "questions": [{}, {}]}
        original = {"status": "inProgress", "items": [question]}
        later = {"status": "inProgress", "items": []}
        state = {"turnHistory": {"history": {"entitiesByKey": {"first": original}}},
                 "turns": [later]}
        self.assertTrue(codex_waiting(state))
        original["status"] = "completed"
        self.assertTrue(codex_waiting(state))
        for index in range(2):
            key = json.dumps(["request_user_input_async", "call_1", index])
            reply = json.dumps([{"questionItemId": key, "answer": "Yes"}])
            text = f"<send_user_message_question_reply>{reply}</send_user_message_question_reply>"
            later["items"].append({"type": "userMessage", "content": [{"type": "text", "text": text}]})
            self.assertEqual(codex_waiting(state), index == 0)

    def test_cancelled_turn_and_ordinary_question(self):
        turns = [
            {"status": "interrupted", "items": [{"type": "agentMessage", "id": "q", "questions": [{}]}]},
            {"status": "completed", "items": [{"type": "agentMessage", "text": "Anything else?"}]},
        ]
        self.assertFalse(codex_waiting({"turns": turns}))

    def test_unread_completed_local_results(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            observer = module["UnreadResults"](directory)
            db = sqlite3.connect(directory / "state_5.sqlite")
            self.addCleanup(db.close)
            db.execute("ATTACH DATABASE ? AS history", (str(directory / "thread_history_1.sqlite"),))
            db.execute("CREATE TABLE threads (id TEXT, archived INTEGER)")
            db.execute("CREATE TABLE history.thread_turns (thread_id TEXT, turn_id TEXT, status TEXT)")
            db.execute("CREATE TABLE thread_read_receipts (thread_id TEXT, first_unread_turn TEXT, last_published_turn TEXT)")
            db.executemany("INSERT INTO threads VALUES (?,?)", [("old", 0), ("a", 0), ("b", 0), ("c", 0), ("d", 1)])
            db.executemany("INSERT INTO history.thread_turns VALUES (?, 'turn', ?)",
                           [(name, "completed") for name in ("old", "a", "b", "d")] + [("c", "interrupted")])
            db.executemany("INSERT INTO thread_read_receipts VALUES (?, 'turn', 'turn')",
                           [(name,) for name in "abcd"])
            db.commit()
            # Reproduce the obsolete desktop cache keeping the Dock dot on after a read.
            legacy = {"version": 1, "unreadByIdentity": {"account": {"local:mac": ["old", "a", "b"]}}}
            (directory / ".codex-global-state.json").write_text(json.dumps({"electron-thread-read-state-v1": legacy}))
            self.assertTrue(observer.any_completed())
            for name, expected in [("a", True), ("b", False)]:
                db.execute("UPDATE thread_read_receipts SET first_unread_turn=NULL WHERE thread_id=?", (name,))
                db.commit()
                self.assertEqual(observer.any_completed(), expected)
            db.execute("UPDATE thread_read_receipts SET first_unread_turn='turn' WHERE thread_id='a'")
            db.commit()
            self.assertTrue(observer.any_completed())
