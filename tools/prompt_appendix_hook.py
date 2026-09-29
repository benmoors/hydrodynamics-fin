"""Keep AI-USE.md's prompt appendix current with no one having to run anything.

Wired as a Claude Code ``SessionEnd`` hook (user settings), so it fires whichever folder a
session was opened in. Claude Code may kill a hook's process tree when it exits, so the
hook itself only starts a detached worker and returns at once::

    python tools/prompt_appendix_hook.py            # hook: spawn the worker, exit 0
    python tools/prompt_appendix_hook.py --worker   # regenerate, check, commit
    python tools/prompt_appendix_hook.py --status   # SessionStart: print a held run, if any

The worker regenerates § 6 with ``extract_prompts.main`` and commits ``AI-USE.md`` alone. It
never pushes: publishing stays a deliberate act. It **holds** instead, leaving the file as it
found it and writing ``HOLD.txt`` beside the log, when:

* ``AI-USE.md`` already had uncommitted edits (someone is mid-change; never sweep them in);
* a newly added prompt matches a licence/registry pattern or still names the home directory
  or the OneDrive tenant (R9). After a human has read it, re-run with ``--allow-sensitive``;
* the extractor or the commit fails (for example, the shrink guard refuses).

A held run is reported by ``--status`` at the next session start, until a run succeeds.
Standard library only.
"""

from __future__ import annotations

import contextlib
import io
import os
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import extract_prompts as ep  # noqa: E402

REPO = ep.REPO_ROOT
AI_USE = ep.DEFAULT_AI_USE
STATE = Path(os.environ.get("LOCALAPPDATA") or Path.home()) / "hydrofin-prompts"
LOG, HOLD, LOCK = STATE / "hook.log", STATE / "HOLD.txt", STATE / "worker.lock"
MESSAGE = "Regenerate AI-USE.md prompt appendix (automatic, at session end)"


def _log(line: str) -> None:
    STATE.mkdir(parents=True, exist_ok=True)
    with LOG.open("a", encoding="utf-8") as fh:
        fh.write(f"{datetime.now():%Y-%m-%d %H:%M:%S} {line}\n")


def _hold(reason: str) -> int:
    _log(f"HELD: {reason}")
    HOLD.write_text(f"{datetime.now():%Y-%m-%d %H:%M} {reason}\n", encoding="utf-8")
    return 1


def _git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(REPO), *args], capture_output=True, text=True)


def _texts(text: str) -> set[str]:
    return {p.text for s in ep.parse_appendix(text) for p in s.prompts}


def unsafe(prompt: str, home: Path | None = None) -> bool:
    """A new prompt a human must read before it is published (R9)."""
    return bool(
        ep._SENSITIVE.search(prompt)
        # redact() leaves a bare "OneDrive"; any tenant spelling left means it missed one
        or re.search(r"OneDrive(?: - |---)", prompt, re.I)
        or ep._home_pattern(home or Path.home()).search(prompt)
    )


def worker(allow_sensitive: bool = False) -> int:
    STATE.mkdir(parents=True, exist_ok=True)
    try:  # one worker at a time; a lock older than 10 minutes is a crashed run
        if LOCK.exists() and time.time() - LOCK.stat().st_mtime > 600:
            LOCK.unlink()
        fd = os.open(LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        _log("skipped: another worker is running")
        return 0
    try:
        os.close(fd)
        time.sleep(5)  # let the ending session finish writing its transcript
        if _git("status", "--porcelain", "--", AI_USE.name).stdout.strip():
            return _hold("AI-USE.md has uncommitted edits; not touched. Commit them and it resumes.")
        original = AI_USE.read_bytes()  # restored byte-for-byte on any hold
        before = original.decode("utf-8")
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            rc = ep.main([])
        if rc != 0:
            AI_USE.write_bytes(original)
            return _hold(f"extract_prompts exited {rc}: {out.getvalue().strip()[-300:]}")
        after = AI_USE.read_text(encoding="utf-8")
        flagged = [t for t in _texts(after) - _texts(before) if unsafe(t)]
        if flagged and not allow_sensitive:
            AI_USE.write_bytes(original)
            first = flagged[0][:80].replace("\n", " ")
            return _hold(f"{len(flagged)} new prompt(s) need a human read before publishing "
                         f"(first: {first!r}). Read them, then run: python "
                         f"tools/prompt_appendix_hook.py --worker --allow-sensitive")
        if not _git("status", "--porcelain", "--", AI_USE.name).stdout.strip():
            _log("no change")
        else:
            commit = _git("commit", "-q", "-m", MESSAGE, "--", AI_USE.name)
            if commit.returncode != 0:
                return _hold(f"git commit failed: {(commit.stderr or commit.stdout).strip()[-300:]}")
            _log(f"committed {_git('rev-parse', '--short', 'HEAD').stdout.strip()}: "
                 f"{len(_texts(after)) - len(_texts(before))} new prompt(s)")
        HOLD.unlink(missing_ok=True)
        return 0
    except Exception as exc:  # a detached worker has nowhere else to report
        return _hold(f"worker crashed: {exc!r}")
    finally:
        LOCK.unlink(missing_ok=True)


def spawn() -> int:
    """Start the worker so it outlives Claude Code; return at once."""
    flags = 0x00000008 | 0x00000200 | 0x08000000  # DETACHED, NEW_PROCESS_GROUP, NO_WINDOW
    for extra in (0x01000000, 0):  # BREAKAWAY_FROM_JOB, if the job allows it
        try:
            subprocess.Popen(
                [sys.executable, __file__, "--worker"], cwd=str(REPO),
                creationflags=flags | extra if os.name == "nt" else 0,
                start_new_session=os.name != "nt",
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            return 0
        except OSError:
            continue
    _log("could not start the worker")
    return 0  # never fail the session's exit


def status() -> int:
    if HOLD.is_file():
        print(f"HYDRODYNAMICS-FIN prompt appendix is on hold -- {HOLD.read_text(encoding='utf-8').strip()} "
              f"(log: {LOG})")
    return 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if "--status" in args:
        sys.exit(status())
    if "--worker" in args:
        sys.exit(worker(allow_sensitive="--allow-sensitive" in args))
    sys.exit(spawn())
