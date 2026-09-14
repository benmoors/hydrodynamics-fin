"""The prompt extractor must keep what was typed and drop what was injected.

A wrong filter here is not a crash; it is a disclosure document that quietly omits
prompts (understating AI use) or includes hook noise as if the author had typed it.
The fixture below plants one of each record type Claude Code writes and asserts the
exact set that survives.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from tools.extract_prompts import BEGIN, END, load_sessions, redact, render, splice

HOME = Path("C:/Users/someone")


def _record(**kw) -> str:
    return json.dumps(kw)


@pytest.fixture
def transcripts(tmp_path: Path) -> Path:
    rows = [
        # kept: plain string content
        _record(type="user", timestamp="2026-08-30T01:00:00Z", gitBranch="main",
                version="2.1.250", message={"content": "Fix the failing test"}),
        # kept: text block, with a home path that must be redacted
        _record(type="user", timestamp="2026-08-30T02:00:00Z", gitBranch="main",
                message={"content": [{"type": "text",
                                      "text": "Read C:\\Users\\someone\\notes.md"}]}),
        # dropped: a tool result, no typed text
        _record(type="user", timestamp="2026-08-30T02:30:00Z",
                message={"content": [{"type": "tool_result", "content": "ok"}]}),
        # kept: a prompt typed while Claude was mid-turn (stored as an attachment)
        _record(type="attachment", timestamp="2026-08-30T02:35:00Z", gitBranch="main",
                attachment={"type": "queued_command", "prompt": "Replace graphify with this",
                            "commandMode": "prompt", "origin": {"kind": "human"}}),
        # dropped: a background task notification with the same record shape
        _record(type="attachment", timestamp="2026-08-30T02:36:00Z",
                attachment={"type": "queued_command", "commandMode": "task-notification",
                            "prompt": "<task-notification>\n<task-id>x</task-id>"}),
        # dropped: meta record
        _record(type="user", isMeta=True, timestamp="2026-08-30T02:40:00Z",
                message={"content": "internal"}),
        # dropped: harness injection
        _record(type="user", timestamp="2026-08-30T02:50:00Z",
                message={"content": "<system-reminder>hook output</system-reminder>"}),
        # dropped: slash command
        _record(type="user", timestamp="2026-08-30T02:55:00Z",
                message={"content": "/compact"}),
        # assistant turn: contributes the model name only
        _record(type="assistant", timestamp="2026-08-30T03:00:00Z",
                message={"model": "claude-opus-5", "content": []}),
    ]
    (tmp_path / "abcdef12-session.jsonl").write_text("\n".join(rows), encoding="utf-8")
    (tmp_path / "subagents").mkdir()  # never read; only top-level files are sessions
    return tmp_path


def test_keeps_typed_prompts_and_drops_everything_else(transcripts: Path) -> None:
    sessions = load_sessions(transcripts, home=HOME)
    assert len(sessions) == 1
    texts = [p.text for p in sessions[0].prompts]
    assert texts == ["Fix the failing test", "Read ~\\notes.md", "Replace graphify with this"]
    assert sessions[0].models == {"claude-opus-5"}
    assert sessions[0].versions == {"2.1.250"}


@pytest.mark.parametrize(
    "spelling",
    ["C:\\Users\\someone\\x", "C:/Users/someone/x", "/c/Users/someone/x", "C--Users-someone"],
)
def test_redacts_every_spelling_of_home(spelling: str) -> None:
    assert "someone" not in redact(spelling, home=HOME)


def test_splice_replaces_only_between_markers(tmp_path: Path, transcripts: Path) -> None:
    ai_use = tmp_path / "AI-USE.md"
    ai_use.write_text(f"# Record\n\nhand-written\n\n{BEGIN}\nold\n{END}\n\ntail\n", encoding="utf-8")
    splice(ai_use, render(load_sessions(transcripts, home=HOME)))
    text = ai_use.read_text(encoding="utf-8")
    assert text.startswith("# Record\n\nhand-written\n")
    assert text.endswith(f"{END}\n\ntail\n")
    assert "old" not in text
    assert "### 2026-08-30 01:00" in text
    assert "> Fix the failing test" in text


def test_splice_refuses_a_file_without_markers(tmp_path: Path) -> None:
    ai_use = tmp_path / "AI-USE.md"
    ai_use.write_text("no markers here\n", encoding="utf-8")
    with pytest.raises(SystemExit):
        splice(ai_use, "body")
