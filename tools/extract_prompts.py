"""Recover the prompts this repository's author gave to Claude Code.

MMA3001's brief asks for "complete disclosure" of AI use (Project Brief p. 15). The
Week 1.4 notebook models that by quoting prompts verbatim. Claude Code keeps every
session as JSON Lines under ``~/.claude/projects/<encoded-repo-path>/``, so the prompts
can be recovered rather than remembered -- but those transcripts sit outside the repo
and are pruned over time, which is why the result is committed into ``AI-USE.md``.

The appendix is written between two HTML-comment markers in ``AI-USE.md`` so the
hand-written sections above it survive regeneration::

    python tools/extract_prompts.py            # rewrite the appendix in place
    python tools/extract_prompts.py --dry-run  # counts and date range only

What is kept: records of ``type == "user"`` that carry text the person typed, and
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
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_TRANSCRIPTS = (
    Path.home() / ".claude" / "projects" / "C--Users-moors-HYDRODYNAMICS-FIN"
)
DEFAULT_AI_USE = REPO_ROOT / "AI-USE.md"

BEGIN = "<!-- prompts:begin -->"
END = "<!-- prompts:end -->"

# Injected by Claude Code, hooks or the harness -- text the user never typed.
_NOISE = re.compile(
    r"<(system-reminder|command-name|command-message|local-command-stdout"
    r"|local-command-caveat|task-notification)\b",
    re.I,
)
# Typed, but not a prompt: slash commands, ctrl-c interruptions, /compact summaries.
_DROP = re.compile(
    r"^(/\w|\[Request interrupted|This session is being continued|Caveat: The messages below)",
    re.I,
)
# Flagged, not removed: a human decides whether these belong in a public file.
_SENSITIVE = re.compile(r"HKLM|swdy|\.reg\b|licen[cs]e\s+key", re.I)


def _home_pattern(home: Path) -> re.Pattern[str]:
    """Match every spelling of the home directory Windows and MSYS produce.

    ``C:\\Users\\moors``, ``C:/Users/moors``, ``/c/Users/moors`` and the
    ``C--Users-moors`` form Claude Code uses for its project folder.
    """
    parts = [re.escape(p) for p in home.parts[1:]]  # drop the drive
    sep = r"[\\/]+"
    body = sep.join(parts)
    drive = r"(?:[A-Za-z]:|/[A-Za-z])"
    return re.compile(rf"{drive}{sep}{body}|[A-Za-z]--{'-'.join(parts)}", re.I)


def redact(text: str, home: Path | None = None) -> str:
    """Replace the user's home directory, in any spelling, with ``~``."""
    return _home_pattern(home or Path.home()).sub("~", text)


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


@dataclass
class Session:
    id: str
    prompts: list[Prompt] = field(default_factory=list)
    models: set[str] = field(default_factory=set)
    versions: set[str] = field(default_factory=set)


def _parse_ts(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def load_sessions(transcripts: Path, home: Path | None = None) -> list[Session]:
    """Read every top-level session file; subagent transcripts hold no user prompts."""
    sessions: list[Session] = []
    for path in sorted(transcripts.glob("*.jsonl")):
        session = Session(id=path.stem[:8])
        with path.open(encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if record.get("version"):
                    session.versions.add(record["version"])
                if record.get("type") == "assistant":
                    model = record.get("message", {}).get("model")
                    if model:
                        session.models.add(model)
                if is_prompt(record):
                    text = redact(text_of(record), home)
                    if _SENSITIVE.search(text):
                        print(
                            f"WARNING: prompt at {record.get('timestamp')} in {session.id} "
                            f"matches a sensitive pattern -- review before committing",
                            file=sys.stderr,
                        )
                    session.prompts.append(
                        Prompt(
                            when=_parse_ts(record["timestamp"]),
                            session=session.id,
                            branch=record.get("gitBranch") or "",
                            text=text,
                        )
                    )
        if session.prompts:
            sessions.append(session)
    return sessions


def render(sessions: list[Session]) -> str:
    """Markdown appendix: a per-session table, then every prompt in time order."""
    prompts = sorted((p for s in sessions for p in s.prompts), key=lambda p: p.when)
    if not prompts:
        return "_No prompts found._\n"
    fmt = "%Y-%m-%d %H:%M"
    out = [
        f"{len(prompts)} prompts across {len(sessions)} sessions, "
        f"{prompts[0].when:%Y-%m-%d} to {prompts[-1].when:%Y-%m-%d}. "
        "Timestamps are as recorded by Claude Code (UTC). "
        "Generated by `tools/extract_prompts.py`; do not edit by hand.",
        "",
        "| Session | First | Last | Prompts | Claude Code | Model |",
        "|---|---|---|---:|---|---|",
    ]
    for s in sessions:
        first, last = min(s.prompts, key=lambda p: p.when), max(s.prompts, key=lambda p: p.when)
        out.append(
            f"| `{s.id}` | {first.when:{fmt}} | {last.when:{fmt}} | {len(s.prompts)} "
            f"| {', '.join(sorted(s.versions)) or '?'} | {', '.join(sorted(s.models)) or '?'} |"
        )
    out.append("")
    for p in prompts:
        branch = f" · `{p.branch}`" if p.branch else ""
        out.append(f"### {p.when:{fmt}} · `{p.session}`{branch}")
        out.append("")
        out.extend(f"> {line}" if line else ">" for line in p.text.splitlines())
        out.append("")
    return "\n".join(out)


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
    parser.add_argument("--transcripts", type=Path, default=DEFAULT_TRANSCRIPTS)
    parser.add_argument("--ai-use", type=Path, default=DEFAULT_AI_USE)
    parser.add_argument("--dry-run", action="store_true", help="report counts only")
    args = parser.parse_args(argv)

    if not args.transcripts.is_dir():
        print(f"no transcript directory at {args.transcripts}", file=sys.stderr)
        return 1
    sessions = load_sessions(args.transcripts)
    prompts = [p for s in sessions for p in s.prompts]
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
