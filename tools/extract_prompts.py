"""Recover the prompts this repository's author gave to Claude Code, agy and Devin.

MMA3001's brief asks for "complete disclosure" of AI use (Project Brief p. 15). The
Week 1.4 notebook models that by quoting prompts verbatim. Each CLI keeps its sessions
outside the repo, so the prompts can be recovered rather than remembered -- but those
transcripts are pruned over time, which is why the result is committed into ``AI-USE.md``:

* Claude Code -- JSON Lines under ``~/.claude/projects/<encoded-path>/``
* agy (Antigravity CLI) -- ``~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/
  transcript.jsonl``; the model is read from ``conversations/<id>.db`` and the workspace
  from ``history.jsonl``
* Devin CLI -- ATIF JSON under ``%APPDATA%/Devin/cli/transcripts/``

Every prompt is printed with the CLI, its version and the model that answered it.

A session started inside the repo contributes every prompt. A session started elsewhere
(``UNIVERSITY/``, the home folder, or a Devin session, which records no working directory)
contributes only the turns that worked on this repo: the prompt, or a tool call the agent
made before the next prompt, names ``HYDRODYNAMICS-FIN``. Injected context is never
searched -- ``UNIVERSITY/CLAUDE.md`` mentions the repo in every session opened there.

The appendix is written between two HTML-comment markers in ``AI-USE.md`` so the
hand-written sections above it survive regeneration::

    python tools/extract_prompts.py            # rewrite the appendix in place
    python tools/extract_prompts.py --dry-run  # counts and date range only

The committed appendix is itself a source. A session it holds that is no longer on disk
(Claude Code deletes transcripts after ``cleanupPeriodDays``, 30 by default) is carried
forward verbatim, and a run that would leave fewer prompts than are committed refuses to
write unless ``--allow-shrink`` is passed. Before this, a re-run deleted every pruned prompt
(AI-USE.md E81). Sessions in ``_EXCLUDED`` reached the filter only through a passing tool
call; they are named, with the reason, in the appendix header.

What is kept (Claude Code): records of ``type == "user"`` that carry text the person typed, and
``queued_command`` attachments holding a prompt typed while Claude was mid-turn. What is
dropped: tool results, ``isMeta`` records, hook and system injections, slash commands,
interruptions and compaction summaries -- none of those are prompts. The user's home
directory is redacted to ``~``; anything that looks like a licence or registry reference
is flagged on stderr for a human to check, never silently removed.

Standard library only.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CLAUDE_PROJECTS = Path.home() / ".claude" / "projects"


def _claude_folder(path: Path) -> str:
    """Claude Code names a project folder after its path, every non-alphanumeric -> "-"."""
    return re.sub(r"[^A-Za-z0-9]", "-", str(path))


# Derived rather than typed, so the default survives the repo moving.
DEFAULT_TRANSCRIPTS = CLAUDE_PROJECTS / _claude_folder(REPO_ROOT)
DEFAULT_AGY = Path.home() / ".gemini" / "antigravity-cli"
DEFAULT_DEVIN = (
    Path(os.environ.get("APPDATA") or Path.home() / "AppData" / "Roaming")
    / "Devin" / "cli" / "transcripts"
)
DEFAULT_AI_USE = REPO_ROOT / "AI-USE.md"

# How a turn is recognised as work on this repo, in a session started outside it.
_REPO_MARK = re.compile(r"hydrodynamics[-_ ]fin", re.I)
# A bare slash command (``/model``, ``/context``). agy's ``/plan <text>`` is a real prompt.
_BARE_COMMAND = re.compile(r"^/[\w:-]+\s*$")
_AGY_REQUEST = re.compile(r"<USER_REQUEST>(.*?)</USER_REQUEST>", re.S)
_AGY_MODEL_SWITCH = re.compile(r"`Model Selection` from .+? to (.+?)\.\s+No need", re.S)
_AGY_MODEL_ID = re.compile(rb"(?:gemini|claude|gpt)-[a-z0-9][\w.-]*")

BEGIN = "<!-- prompts:begin -->"
END = "<!-- prompts:end -->"

# Sessions opened above the repo that the filter admits only because a tool call named the
# repo folder in passing. Their prompts are about other work, and the appendix is public.
_EXCLUDED = {
    "64368e17": "Career commits and SQA; only listed the repo's git status",
    "3ec3aba3": "global CLAUDE.md wiki rule; only read the repo's wiki schema",
    "9bdca7c3": "resume-profile rule; edited only the gitignored wiki/ schema",
    "b95c1da1": "resume profile; read AI-USE.md, edited only the gitignored wiki/ schema",
    "34012d20": "ENG1090 wiki ingest; read the repo's wiki/ read-only",
}
_CLIS = ("Claude Code", "agy", "Devin")

# Injected by Claude Code, hooks or the harness -- text the user never typed.
_NOISE = re.compile(
    r"<(system-reminder|command-name|command-message|local-command-stdout"
    r"|local-command-caveat|task-notification|agent-message)\b",
    re.I,
)
# Typed, but not a prompt: slash commands, ctrl-c interruptions, /compact summaries.
_DROP = re.compile(
    r"^(/\w|\[Request interrupted|This session is being continued|Caveat: The messages below)",
    re.I,
)
# Flagged, not removed: a human decides whether these belong in a public file.
_SENSITIVE = re.compile(r"HKLM|swdy|\.reg\b|licen[cs]e\s+key", re.I)
# "OneDrive - <tenant>" as a folder name, in path or Claude-project-folder spelling.
_ONEDRIVE_TENANT = re.compile(r"OneDrive(?: - |---)[^\\/\r\n]+?(?=[\\/]|-Documents|$)", re.I | re.M)


def _home_pattern(home: Path) -> re.Pattern[str]:
    """Match every spelling of the home directory Windows and MSYS produce.

    ``C:\\Users\\moors``, ``C:/Users/moors``, ``/c/Users/moors`` and the
    ``C--Users-moors`` form Claude Code uses for its project folder.
    """
    parts = [re.escape(p) for p in home.parts[1:]]  # drop the drive
    sep = r"[\\/]+"
    body = sep.join(parts)
    drive = r"(?:[A-Za-z]:|/[A-Za-z])"
    # The project-folder form turns spaces and punctuation into "-" too, not just separators.
    dashed = "-".join(re.sub(r"[^A-Za-z0-9]", "-", p) for p in home.parts[1:])
    return re.compile(rf"{drive}{sep}{body}|[A-Za-z]--{dashed}", re.I)


def redact(text: str, home: Path | None = None, root: Path | None = None) -> str:
    """Replace the user's home directory, in any spelling, with ``~``.

    When the repo sits deeper under home (e.g. ``~/OneDrive - <tenant>/...``), its parent
    folder is collapsed first, so paths render as ``~/HYDRODYNAMICS-FIN/...`` and the
    OneDrive tenant never reaches the committed appendix (R9).
    """
    home = home or Path.home()
    parent = (root or REPO_ROOT).parent
    if home in parent.parents:
        text = _home_pattern(parent).sub("~", text)
    text = _home_pattern(home).sub("~", text)
    # A path to any other OneDrive folder (e.g. the SWD library) still names the tenant.
    return _ONEDRIVE_TENANT.sub("OneDrive", text)


def _queued_prompt(record: dict) -> dict | None:
    """The attachment of a prompt typed while Claude was mid-turn, else ``None``.

    Claude Code stores those as ``type == "attachment"`` records whose attachment is a
    ``queued_command`` with ``commandMode == "prompt"`` -- never as a ``type == "user"``
    record -- so reading user records alone silently drops every mid-turn prompt.
    Background task notifications share the shape with ``commandMode ==
    "task-notification"`` and are not prompts.
    """
    attachment = record.get("attachment")
    if (
        record.get("type") == "attachment"
        and isinstance(attachment, dict)
        and attachment.get("type") == "queued_command"
        and attachment.get("commandMode") == "prompt"
    ):
        return attachment
    return None


def text_of(record: dict) -> str:
    """The typed text in a user or queued-prompt record, or ``""`` if there is none."""
    queued = _queued_prompt(record)
    if queued is not None:
        prompt = queued.get("prompt")
        return prompt.strip() if isinstance(prompt, str) else ""
    content = record.get("message", {}).get("content")
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        return "".join(
            block.get("text", "")
            for block in content
            if isinstance(block, dict) and block.get("type") == "text"
        ).strip()
    return ""


def is_prompt(record: dict) -> bool:
    """True for a record that carries something the user actually typed."""
    if record.get("isMeta"):
        return False
    if record.get("type") != "user" and _queued_prompt(record) is None:
        return False
    text = text_of(record)
    return bool(text) and not _NOISE.search(text) and not _DROP.match(text)


@dataclass
class Prompt:
    when: datetime
    session: str
    branch: str
    text: str
    cli: str = "Claude Code"
    version: str = ""
    model: str = ""


@dataclass
class Session:
    id: str
    prompts: list[Prompt] = field(default_factory=list)
    models: set[str] = field(default_factory=set)
    versions: set[str] = field(default_factory=set)
    cli: str = "Claude Code"
    scope: str = "repo"  # "repo", or "via <folder>" when started outside it


@dataclass
class _Turn:
    """A prompt plus whether the work it started touched this repo."""

    prompt: Prompt
    touched: bool


def _parse_ts(value: str) -> datetime:
    # Devin writes nanoseconds; fromisoformat takes at most six fractional digits.
    return datetime.fromisoformat(re.sub(r"(\.\d{6})\d+", r"\1", value.replace("Z", "+00:00")))


def _inside(path: Path, repo: Path) -> bool:
    path_s, repo_s = os.path.normcase(str(path)), os.path.normcase(str(repo))
    return path_s == repo_s or path_s.startswith(repo_s.rstrip("\\/") + os.sep)


def _jsonl(path: Path):
    with path.open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def _touches_repo(value: object) -> bool:
    return bool(_REPO_MARK.search(json.dumps(value, ensure_ascii=False)))


def _finish(session: Session, turns: list[_Turn], home: Path | None) -> Session:
    """Keep every turn in a repo session, only the repo turns in any other; redact and flag."""
    for turn in turns:
        if session.scope != "repo" and not turn.touched:
            continue
        prompt = turn.prompt
        prompt.text = redact(prompt.text, home)
        if _SENSITIVE.search(prompt.text):
            print(
                f"WARNING: {prompt.cli} prompt at {prompt.when:%Y-%m-%d %H:%M} in {session.id} "
                f"matches a sensitive pattern -- review before committing",
                file=sys.stderr,
            )
        session.prompts.append(prompt)
        session.versions.update({prompt.version} - {""})
        session.models.update({prompt.model} - {""})
    return session


def load_sessions(
    transcripts: Path, home: Path | None = None, scope: str = "repo"
) -> list[Session]:
    """Read every top-level Claude Code session file; subagent transcripts hold no prompts."""
    sessions: list[Session] = []
    for path in sorted(transcripts.glob("*.jsonl")):
        session = Session(id=path.stem[:8], scope=scope)
        turns: list[_Turn] = []
        version = ""
        for record in _jsonl(path):
            version = record.get("version") or version
            if record.get("type") == "assistant" and turns:
                message = record.get("message", {})
                # "<synthetic>" marks a message Claude Code wrote itself, not a model reply.
                if message.get("model") not in (None, "", "<synthetic>") and not turns[-1].prompt.model:
                    turns[-1].prompt.model = message["model"]
                for block in message.get("content") or []:
                    if isinstance(block, dict) and block.get("type") == "tool_use":
                        turns[-1].touched |= _touches_repo(block.get("input"))
            if is_prompt(record):
                text = text_of(record)
                prompt = Prompt(
                    when=_parse_ts(record["timestamp"]),
                    session=session.id,
                    branch=record.get("gitBranch") or "",
                    text=text,
                    version=version,
                )
                turns.append(_Turn(prompt, bool(_REPO_MARK.search(text))))
        if _finish(session, turns, home).prompts:
            sessions.append(session)
    return sessions


def load_claude_ancestors(
    repo: Path = REPO_ROOT, projects: Path = CLAUDE_PROJECTS, home: Path | None = None
) -> list[Session]:
    """Claude Code sessions opened in a folder above the repo (``UNIVERSITY/``, home)."""
    home = home or Path.home()
    sessions: list[Session] = []
    for parent in repo.parents:
        folder = projects / _claude_folder(parent)
        if folder.is_dir():
            sessions += load_sessions(folder, home, scope=f"via {parent.name or parent}")
        if parent == home:
            break
    return sessions


def _agy_models(db: Path) -> list[str]:
    """Model ids agy recorded per generation, read from a copy -- never the live database."""
    if not db.is_file():
        return []
    ids: Counter[str] = Counter()
    with tempfile.TemporaryDirectory() as tmp:
        copy = Path(tmp) / db.name
        shutil.copyfile(db, copy)
        con = sqlite3.connect(copy)
        try:
            for (blob,) in con.execute("SELECT data FROM gen_metadata"):
                # A protobuf string field is a run of printable bytes; the model id is a
                # whole run, which keeps model-looking words inside prompt text out.
                for run in re.findall(rb"[\x20-\x7e]{4,80}", bytes(blob or b"")):
                    if _AGY_MODEL_ID.fullmatch(run):
                        ids[run.decode()] += 1
        except sqlite3.DatabaseError:
            pass
        finally:
            con.close()
    return sorted(ids)


def load_agy_sessions(
    root: Path = DEFAULT_AGY, repo: Path = REPO_ROOT, home: Path | None = None
) -> list[Session]:
    """agy conversations: ``USER_INPUT`` steps, text inside ``<USER_REQUEST>`` only."""
    workspaces: dict[str, str] = {}
    if (root / "history.jsonl").is_file():
        for record in _jsonl(root / "history.jsonl"):
            if record.get("conversationId") and record.get("workspace"):
                workspaces[record["conversationId"]] = record["workspace"]
    sessions: list[Session] = []
    for path in sorted(root.glob("brain/*/.system_generated/logs/transcript.jsonl")):
        conv = path.parents[2].name
        workspace = workspaces.get(conv)
        if workspace and _inside(Path(workspace), repo):
            scope = "repo"
        else:
            scope = f"via {Path(workspace).name}" if workspace else "via ?"
        session = Session(id=conv[:8], cli="agy", scope=scope)
        model = ", ".join(_agy_models(root / "conversations" / f"{conv}.db"))
        turns: list[_Turn] = []
        for record in _jsonl(path):
            kind = record.get("type")
            if kind == "USER_INPUT" and record.get("source") == "USER_EXPLICIT":
                content = record.get("content") or ""
                switch = _AGY_MODEL_SWITCH.search(content)
                model = switch.group(1).strip() if switch else model
                request = _AGY_REQUEST.search(content)
                text = request.group(1).strip() if request else ""
                if not text or _BARE_COMMAND.match(text) or _NOISE.search(text):
                    continue
                prompt = Prompt(
                    when=_parse_ts(record["created_at"]),
                    session=session.id, branch="", text=text, cli="agy", model=model,
                )
                turns.append(_Turn(prompt, bool(_REPO_MARK.search(text))))
            elif kind == "PLANNER_RESPONSE" and turns:
                turns[-1].touched |= _touches_repo(record.get("tool_calls") or [])
        if _finish(session, turns, home).prompts:
            sessions.append(session)
    return sessions


def load_devin_sessions(root: Path = DEFAULT_DEVIN, home: Path | None = None) -> list[Session]:
    """Devin CLI ATIF transcripts. No working directory is recorded, so every turn is
    filtered on the prompt and the agent's tool-call arguments."""
    sessions: list[Session] = []
    for path in sorted(root.glob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8", errors="replace"))
        except json.JSONDecodeError:
            continue
        agent = data.get("agent") or {}
        session = Session(id=data.get("session_id") or path.stem, cli="Devin", scope="via ?")
        turns: list[_Turn] = []
        for step in data.get("steps") or []:
            if step.get("source") == "user":
                text = step.get("message")
                text = text.strip() if isinstance(text, str) else ""
                if not text or _BARE_COMMAND.match(text) or _NOISE.search(text):
                    continue
                prompt = Prompt(
                    when=_parse_ts(step["timestamp"]),
                    session=session.id, branch="", text=text, cli="Devin",
                    version=agent.get("version") or "",
                )
                turns.append(_Turn(prompt, bool(_REPO_MARK.search(text))))
            elif step.get("source") == "agent" and turns:
                if step.get("model_name") and not turns[-1].prompt.model:
                    turns[-1].prompt.model = step["model_name"]
                turns[-1].touched |= _touches_repo(step.get("tool_calls") or [])
        for turn in turns:  # answered by nothing yet: fall back to the session's selection
            turn.prompt.model = turn.prompt.model or agent.get("model_name") or ""
        if _finish(session, turns, home).prompts:
            sessions.append(session)
    return sessions


def render(sessions: list[Session]) -> str:
    """Markdown appendix: a per-session table, then every prompt in time order."""
    prompts = sorted((p for s in sessions for p in s.prompts), key=lambda p: p.when)
    if not prompts:
        return "_No prompts found._\n"
    fmt = "%Y-%m-%d %H:%M"
    per_cli = Counter(p.cli for p in prompts)
    out = [
        f"{len(prompts)} prompts across {len(sessions)} sessions "
        f"({', '.join(f'{cli} {n}' for cli, n in sorted(per_cli.items()))}), "
        f"{prompts[0].when:%Y-%m-%d} to {prompts[-1].when:%Y-%m-%d}. "
        "Timestamps are UTC, as recorded by each CLI. A session opened outside the repo "
        "contributes only the turns whose prompt or tool calls touched HYDRODYNAMICS-FIN. "
        "A session whose transcript the CLI has since deleted is carried forward from the "
        "previous appendix. Excluded as not about this repo: "
        + "; ".join(f"`{sid}` ({why})" for sid, why in _EXCLUDED.items())
        + ". Generated by `tools/extract_prompts.py`; do not edit by hand.",
        "",
        "| Session | CLI | Version | Model | Scope | First | Last | Prompts |",
        "|---|---|---|---|---|---|---|---:|",
    ]
    for s in sorted(sessions, key=lambda s: min(p.when for p in s.prompts)):
        first, last = min(s.prompts, key=lambda p: p.when), max(s.prompts, key=lambda p: p.when)
        out.append(
            f"| `{s.id}` | {s.cli} | {', '.join(sorted(s.versions)) or '?'} "
            f"| {', '.join(sorted(s.models)) or '?'} | {s.scope} "
            f"| {first.when:{fmt}} | {last.when:{fmt}} | {len(s.prompts)} |"
        )
    out.append("")
    for p in prompts:
        branch = f" · `{p.branch}`" if p.branch else ""
        cli = f"{p.cli} {p.version}" if p.version else p.cli
        out.append(f"### {p.when:{fmt}} · {cli} · {p.model or '?'} · `{p.session}`{branch}")
        out.append("")
        out.extend(f"> {line}" if line else ">" for line in p.text.splitlines())
        out.append("")
    return "\n".join(out)


_ROW = re.compile(r"^\| `([^`]+)` \| ([^|]+) \| ([^|]+) \| ([^|]+) \| ([^|]+) \|")
_HEADING = re.compile(
    r"^### (\d{4}-\d\d-\d\d \d\d:\d\d) · (.+?) · (.+?) · `([^`]+)`(?: · `([^`]*)`)?$"
)


def parse_appendix(text: str) -> list[Session]:
    """Read a rendered appendix back into sessions -- the inverse of :func:`render`.

    Only the text between the markers is read. Times come back at minute resolution in
    UTC, which is all the appendix records.
    """
    start, stop = text.find(BEGIN), text.find(END)
    block = text[start + len(BEGIN): stop] if 0 <= start < stop else text
    sessions: dict[str, Session] = {}
    current: Prompt | None = None
    body: list[str] = []

    def close() -> None:
        if current is not None:
            current.text = "\n".join(body)
            sessions[current.session].prompts.append(current)

    for line in block.splitlines():
        row = _ROW.match(line)
        if row:
            sid, cli, versions, models, scope = (g.strip() for g in row.groups())
            sessions[sid] = Session(
                id=sid, cli=cli, scope=scope,
                versions=set() if versions == "?" else set(versions.split(", ")),
                models=set() if models == "?" else set(models.split(", ")),
            )
            continue
        heading = _HEADING.match(line)
        if heading:
            close()
            when, cli_version, model, sid, branch = heading.groups()
            cli = next(c for c in _CLIS if cli_version == c or cli_version.startswith(c + " "))
            current = Prompt(
                when=datetime.strptime(when, "%Y-%m-%d %H:%M").replace(tzinfo=timezone.utc),
                session=sid, branch=branch or "", text="", cli=cli,
                version=cli_version[len(cli):].strip(), model="" if model == "?" else model,
            )
            body = []
        elif current is not None and line.startswith(">"):
            body.append(line[2:] if line.startswith("> ") else "")
    close()
    return [s for s in sessions.values() if s.prompts]


def splice(ai_use: Path, body: str) -> None:
    """Replace whatever sits between the markers in ``AI-USE.md``; keep the rest."""
    original = ai_use.read_text(encoding="utf-8")
    start, stop = original.find(BEGIN), original.find(END)
    if start < 0 or stop < 0 or stop < start:
        raise SystemExit(
            f"{ai_use} must contain the markers {BEGIN} and {END}, in that order; "
            "the hand-written sections above them are never touched."
        )
    updated = original[: start + len(BEGIN)] + "\n" + body + "\n" + original[stop:]
    ai_use.write_text(updated, encoding="utf-8", newline="\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--transcripts", type=Path, default=DEFAULT_TRANSCRIPTS,
                        help="this repo's Claude Code project folder")
    parser.add_argument("--claude-projects", type=Path, default=CLAUDE_PROJECTS,
                        help="where folders for sessions opened above the repo are found")
    parser.add_argument("--agy-dir", type=Path, default=DEFAULT_AGY)
    parser.add_argument("--devin-dir", type=Path, default=DEFAULT_DEVIN)
    parser.add_argument("--ai-use", type=Path, default=DEFAULT_AI_USE)
    parser.add_argument("--dry-run", action="store_true", help="report counts only")
    parser.add_argument("--allow-shrink", action="store_true",
                        help="write even if fewer prompts result than are committed")
    args = parser.parse_args(argv)

    sessions: list[Session] = []
    stores = [
        ("Claude Code", args.transcripts, lambda: load_sessions(args.transcripts)),
        ("Claude Code (opened above the repo)", args.claude_projects,
         lambda: load_claude_ancestors(projects=args.claude_projects)),
        ("agy", args.agy_dir, lambda: load_agy_sessions(args.agy_dir)),
        ("Devin", args.devin_dir, lambda: load_devin_sessions(args.devin_dir)),
    ]
    for name, where, load in stores:
        if not where.is_dir():
            print(f"skipped {name}: no directory at {where}", file=sys.stderr)
            continue
        found = load()
        print(f"{name}: {sum(len(s.prompts) for s in found)} prompts, {len(found)} sessions")
        sessions += found

    committed = [
        s for s in (parse_appendix(args.ai_use.read_text(encoding="utf-8"))
                    if args.ai_use.is_file() else [])
        if s.id not in _EXCLUDED
    ]
    live = {s.id for s in sessions}
    carried = [s for s in committed if s.id not in live]
    if carried:
        print(f"carried forward {sum(len(s.prompts) for s in carried)} prompts from "
              f"{len(carried)} sessions no longer on disk: {', '.join(s.id for s in carried)}")
    sessions = [s for s in sessions if s.id not in _EXCLUDED] + carried
    prompts = [p for s in sessions for p in s.prompts]
    before = sum(len(s.prompts) for s in committed)
    if len(prompts) < before and not args.allow_shrink:
        print(f"refusing to write: {len(prompts)} prompts would replace {before} committed. "
              "Pass --allow-shrink only for a deliberate filter change.", file=sys.stderr)
        return 2
    if not prompts:
        print("no prompts found", file=sys.stderr)
        return 1
    span = sorted(p.when for p in prompts)
    print(f"{len(prompts)} prompts, {len(sessions)} sessions, {span[0]:%Y-%m-%d} -> {span[-1]:%Y-%m-%d}")
    if args.dry_run:
        return 0
    splice(args.ai_use, render(sessions))
    print(f"wrote appendix into {args.ai_use}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
