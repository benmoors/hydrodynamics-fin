"""The prompt extractor must keep what was typed and drop what was injected.

A wrong filter here is not a crash; it is a disclosure document that quietly omits
prompts (understating AI use) or includes hook noise as if the author had typed it.
The fixture below plants one of each record type Claude Code writes and asserts the
exact set that survives.
"""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

import pytest

from tools.extract_prompts import (
    BEGIN,
    Prompt,
    Session,
    END,
    load_agy_sessions,
    load_devin_sessions,
    load_sessions,
    main,
    parse_appendix,
    redact,
    render,
    splice,
)

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


@pytest.mark.parametrize(
    "spelling",
    [
        "C:\\Users\\someone\\OneDrive - Tenant\\Docs\\repo\\x",
        "C:/Users/someone/OneDrive - Tenant/Docs/repo/x",
        "/c/Users/someone/OneDrive - Tenant/Docs/repo/x",
        "C--Users-someone-OneDrive---Tenant-Docs-repo",
    ],
)
def test_redacts_the_tenant_above_a_repo_under_home(spelling: str) -> None:
    out = redact(spelling, home=HOME, root=Path("C:/Users/someone/OneDrive - Tenant/Docs/repo"))
    assert "Tenant" not in out and "someone" not in out
    assert "repo" in out


@pytest.mark.parametrize(
    "spelling",
    [
        "C:\\Users\\someone\\OneDrive - Tenant Uni\\Documents\\Library\\Boards",
        "C:\\\\Users\\\\someone\\\\OneDrive - Tenant Uni\\\\Documents\\\\Library",  # JSON-escaped
        "C:/Users/someone/OneDrive - Tenant Uni/Other/x",
    ],
)
def test_redacts_the_tenant_outside_the_repo(spelling: str) -> None:
    out = redact(spelling, home=HOME, root=Path("C:/Users/someone/OneDrive - Tenant Uni/Docs/repo"))
    assert "Tenant" not in out and "someone" not in out
    assert "OneDrive" in out


def test_splice_replaces_only_between_markers(tmp_path: Path, transcripts: Path) -> None:
    ai_use = tmp_path / "AI-USE.md"
    ai_use.write_text(f"# Record\n\nhand-written\n\n{BEGIN}\nold\n{END}\n\ntail\n", encoding="utf-8")
    splice(ai_use, render(load_sessions(transcripts, home=HOME)))
    text = ai_use.read_text(encoding="utf-8")
    assert text.startswith("# Record\n\nhand-written\n")
    assert text.endswith(f"{END}\n\ntail\n")
    assert "old" not in text
    assert "### 2026-08-30 11:00 AEST" in text
    assert "> Fix the failing test" in text


def test_splice_refuses_a_file_without_markers(tmp_path: Path) -> None:
    ai_use = tmp_path / "AI-USE.md"
    ai_use.write_text("no markers here\n", encoding="utf-8")
    with pytest.raises(SystemExit):
        splice(ai_use, "body")


# --- sessions opened above the repo, agy and Devin -------------------------------------

REPO = Path("C:/Users/someone/UNI/HYDRODYNAMICS-FIN")
HFIN_PATH = "C:\\Users\\someone\\UNI\\HYDRODYNAMICS-FIN\\src\\splits.py"
CAREER_PATH = "C:\\Users\\someone\\UNI\\Career\\scripts\\fetch.py"


def test_heading_names_cli_version_and_model(transcripts: Path) -> None:
    text = render(load_sessions(transcripts, home=HOME))
    assert "### 2026-08-30 12:35 AEST · Claude Code 2.1.250 · claude-opus-5 · `abcdef12`" in text
    assert "| `abcdef12` | Claude Code | 2.1.250 | claude-opus-5 | repo |" in text


def test_claude_session_above_the_repo_keeps_only_repo_turns(tmp_path: Path) -> None:
    def tool(path: str) -> dict:
        return {"model": "claude-opus-5",
                "content": [{"type": "tool_use", "name": "Read", "input": {"file_path": path}}]}

    rows = [
        # injected context names the repo: must not count as work on it
        _record(type="user", timestamp="2026-09-20T01:00:00Z",
                message={"content": "<system-reminder>HYDRODYNAMICS-FIN is a repo</system-reminder>"}),
        _record(type="user", timestamp="2026-09-20T01:01:00Z", message={"content": "Fix fetch"}),
        _record(type="assistant", timestamp="2026-09-20T01:02:00Z", message=tool(CAREER_PATH)),
        _record(type="user", timestamp="2026-09-20T02:00:00Z", message={"content": "Fix splits"}),
        _record(type="assistant", timestamp="2026-09-20T02:01:00Z", message=tool(HFIN_PATH)),
        # dropped: a subagent's hand-back is delivered as a user record, never typed
        _record(type="user", timestamp="2026-09-20T02:30:00Z",
                message={"content": '<agent-message from="a1">HYDRODYNAMICS-FIN done</agent-message>'}),
        _record(type="user", timestamp="2026-09-20T03:00:00Z",
                message={"content": "Now the hydrodynamics fin README"}),
    ]
    (tmp_path / "11111111.jsonl").write_text("\n".join(rows), encoding="utf-8")
    sessions = load_sessions(tmp_path, home=HOME, scope="via UNI")
    assert [p.text for p in sessions[0].prompts] == ["Fix splits", "Now the hydrodynamics fin README"]
    assert sessions[0].prompts[0].model == "claude-opus-5"


def _agy_root(tmp_path: Path, workspace: str) -> Path:
    conv = "9b3bc2ea-0000-0000-0000-000000000000"
    logs = tmp_path / "brain" / conv / ".system_generated" / "logs"
    logs.mkdir(parents=True)

    def user(ts: str, text: str, extra: str = "") -> str:
        return _record(type="USER_INPUT", source="USER_EXPLICIT", created_at=ts,
                       content=f"<USER_REQUEST>\n{text}\n</USER_REQUEST>{extra}"
                               "<ADDITIONAL_METADATA>time</ADDITIONAL_METADATA>")

    def plan(ts: str, path: str) -> str:
        return _record(type="PLANNER_RESPONSE", source="MODEL", created_at=ts,
                       tool_calls=[{"name": "view_file", "args": {"AbsolutePath": path}}])

    switch = ("<USER_SETTINGS_CHANGE>The user changed setting `Model Selection` from None to "
              "Gemini 3.8 Flash (High). No need to comment.</USER_SETTINGS_CHANGE>")
    rows = [
        user("2026-09-24T01:00:00Z", "/model"),                   # dropped: bare command
        user("2026-09-24T01:01:00Z", "Audit fetch"),              # Career only
        plan("2026-09-24T01:02:00Z", CAREER_PATH),
        user("2026-09-24T02:00:00Z", "/plan Audit splits", switch),
        plan("2026-09-24T02:01:00Z", HFIN_PATH),
        _record(type="SYSTEM_MESSAGE", source="SYSTEM", created_at="2026-09-24T02:02:00Z",
                content="HYDRODYNAMICS-FIN"),
    ]
    (logs / "transcript.jsonl").write_text("\n".join(rows), encoding="utf-8")
    (tmp_path / "history.jsonl").write_text(
        _record(display="x", workspace=workspace, conversationId=conv), encoding="utf-8")
    (tmp_path / "conversations").mkdir()
    con = sqlite3.connect(tmp_path / "conversations" / f"{conv}.db")
    con.execute("CREATE TABLE gen_metadata (idx integer, data blob)")
    con.execute("INSERT INTO gen_metadata VALUES (0, ?)",
                (b"\x0a\x10gemini-3.8-flash\x12\x20we asked gemini-x about it here",))
    con.commit()
    con.close()
    return tmp_path


def test_agy_session_above_the_repo(tmp_path: Path) -> None:
    root = _agy_root(tmp_path, "C:\\Users\\someone\\UNI")
    [session] = load_agy_sessions(root, repo=REPO, home=HOME)
    assert session.scope == "via UNI"
    assert [p.text for p in session.prompts] == ["/plan Audit splits"]
    assert session.prompts[0].cli == "agy"
    assert session.prompts[0].model == "Gemini 3.8 Flash (High)"


def test_agy_session_inside_the_repo_keeps_every_prompt(tmp_path: Path) -> None:
    root = _agy_root(tmp_path, str(REPO))
    [session] = load_agy_sessions(root, repo=REPO, home=HOME)
    assert session.scope == "repo"
    assert [p.text for p in session.prompts] == ["Audit fetch", "/plan Audit splits"]
    # before any model switch, the model comes from the generation metadata, whole ids only
    assert session.prompts[0].model == "gemini-3.8-flash"


def test_devin_keeps_repo_turns_with_cli_version_and_model(tmp_path: Path) -> None:
    def agent(ts: str, path: str) -> dict:
        return {"source": "agent", "timestamp": ts, "model_name": "swe-1-7",
                "tool_calls": [{"function_name": "read_file", "arguments": {"path": path}}]}

    data = {
        "session_id": "star-water",
        "agent": {"name": "devin", "version": "3000.11.3", "model_name": "SWE-1.7 Max"},
        "steps": [
            {"source": "system", "timestamp": "2026-09-24T00:00:00Z", "message": "HYDRODYNAMICS-FIN"},
            {"source": "user", "timestamp": "2026-09-24T00:01:00.123456789+00:00", "message": "/context"},
            {"source": "user", "timestamp": "2026-09-24T00:02:00+00:00", "message": "Audit Career"},
            agent("2026-09-24T00:03:00+00:00", CAREER_PATH),
            {"source": "user", "timestamp": "2026-09-24T00:04:00+00:00", "message": "Audit splits"},
            agent("2026-09-24T00:05:00+00:00", HFIN_PATH),
        ],
    }
    (tmp_path / "star-water.json").write_text(json.dumps(data), encoding="utf-8")
    [session] = load_devin_sessions(tmp_path, home=HOME)
    [prompt] = session.prompts
    assert (prompt.text, prompt.cli, prompt.version, prompt.model) == (
        "Audit splits", "Devin", "3000.11.3", "swe-1-7")
    assert "### 2026-09-24 10:04 AEST · Devin 3000.11.3 · swe-1-7 · `star-water`" in render([session])


# --- the committed appendix is a source: carry forward, never shrink --------------------


def _stores(tmp_path: Path, transcripts: Path) -> list[str]:
    empty = tmp_path / "empty"
    empty.mkdir(exist_ok=True)
    return ["--transcripts", str(transcripts), "--claude-projects", str(empty),
            "--agy-dir", str(empty), "--devin-dir", str(empty)]


def _pruned_session() -> str:
    return (
        "| `deadbeef` | Claude Code | 2.1.246 | claude-opus-5 | repo "
        "| 2026-08-26 12:38 | 2026-08-26 12:39 | 2 |\n\n"
        "### 2026-08-26 12:38 · Claude Code 2.1.246 · claude-opus-5 · `deadbeef` · `main`\n\n"
        "> First line\n>\n> second paragraph\n\n"
        "### 2026-08-26 12:39 · Claude Code 2.1.246 · ? · `deadbeef` · `main`\n\n"
        "> Only line\n"
    )


def test_parse_appendix_inverts_render(transcripts: Path) -> None:
    rendered = render(load_sessions(transcripts, home=HOME))
    assert render(parse_appendix(rendered)) == rendered
    [session] = parse_appendix(_pruned_session())
    assert [p.text for p in session.prompts] == ["First line\n\nsecond paragraph", "Only line"]
    assert session.prompts[1].model == ""


def test_pruned_session_is_carried_forward(tmp_path: Path, transcripts: Path) -> None:
    ai_use = tmp_path / "AI-USE.md"
    ai_use.write_text(f"head\n{BEGIN}\n{_pruned_session()}\n{END}\n", encoding="utf-8")
    assert main([*_stores(tmp_path, transcripts), "--ai-use", str(ai_use)]) == 0
    text = ai_use.read_text(encoding="utf-8")
    assert "> First line\n>\n> second paragraph" in text  # carried verbatim
    assert "> Fix the failing test" in text  # live prompts still added
    assert "5 prompts across 2 sessions" in text


def test_refuses_to_shrink_the_committed_appendix(tmp_path: Path, transcripts: Path) -> None:
    ai_use = tmp_path / "AI-USE.md"
    committed = render(load_sessions(transcripts, home=HOME)).replace(
        "### 2026-08-30 11:00 AEST", "### 2026-08-29 11:00 AEST")  # a prompt the live store lacks
    extra = "### 2026-08-30 04:00 · Claude Code 2.1.250 · ? · `abcdef12` · `main`\n\n> Gone\n"
    original = f"{BEGIN}\n{committed}\n{extra}\n{END}\n"
    ai_use.write_text(original, encoding="utf-8")
    args = [*_stores(tmp_path, transcripts), "--ai-use", str(ai_use)]
    assert main(args) == 2
    assert ai_use.read_text(encoding="utf-8") == original
    assert main([*args, "--allow-shrink"]) == 0
    assert "Gone" not in ai_use.read_text(encoding="utf-8")


def test_excluded_session_is_named_not_rendered(tmp_path: Path, transcripts: Path) -> None:
    ai_use = tmp_path / "AI-USE.md"
    ai_use.write_text(f"{BEGIN}\n{_pruned_session().replace('deadbeef', '64368e17')}\n{END}\n",
                      encoding="utf-8")
    assert main([*_stores(tmp_path, transcripts), "--ai-use", str(ai_use)]) == 0
    text = ai_use.read_text(encoding="utf-8")
    assert "`64368e17` (" in text  # named, with its reason, in the header
    assert "· `64368e17` ·" not in text and "First line" not in text


def test_times_render_in_melbourne_and_old_utc_headings_convert() -> None:
    # A heading from before the switch has no zone label and is UTC: 12:38 UTC = 22:38 AEST.
    [old] = parse_appendix(_pruned_session())
    assert "### 2026-08-26 22:38 AEST · Claude Code 2.1.246" in render([old])
    # The hour repeated when daylight saving ends round-trips on its label.
    utc = [datetime(2027, 4, 3, 15, 30, tzinfo=timezone.utc),  # 02:30 AEDT
           datetime(2027, 4, 3, 16, 30, tzinfo=timezone.utc)]  # 02:30 AEST
    session = Session(id="dst", cli="Claude Code", prompts=[
        Prompt(when=w, session="dst", branch="", text=f"p{i}") for i, w in enumerate(utc)])
    rendered = render([session])
    assert "02:30 AEDT" in rendered and "02:30 AEST" in rendered
    assert [p.when for p in parse_appendix(rendered)[0].prompts] == utc
