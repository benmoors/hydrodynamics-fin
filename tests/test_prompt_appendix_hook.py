"""The session-end hook commits the appendix on its own, so its holds are the only review.

Each test runs the real worker against a throwaway git repo, with the extractor replaced
by a stub that appends one prompt, and checks what reached a commit.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

import tools.prompt_appendix_hook as hook
from tools.extract_prompts import BEGIN, END

HOME = Path("C:/Users/someone")
HEAD = "### 2026-09-29 17:00 AEST · Claude Code 2.1.284 · claude-opus-5-5 · `aaaa1111`"


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True,
                          check=True).stdout


@pytest.fixture
def repo(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    root = tmp_path / "repo"
    root.mkdir()
    _git(root, "init", "-q")
    _git(root, "config", "user.email", "t@example.com")
    _git(root, "config", "user.name", "t")
    (root / "AI-USE.md").write_text(f"# Record\n{BEGIN}\n{HEAD}\n\n> old\n\n{END}\n",
                                    encoding="utf-8")
    (root / "other.txt").write_text("x\n", encoding="utf-8")
    _git(root, "add", ".")
    _git(root, "commit", "-q", "-m", "init")
    state = tmp_path / "state"
    monkeypatch.setattr(hook, "REPO", root)
    monkeypatch.setattr(hook, "AI_USE", root / "AI-USE.md")
    monkeypatch.setattr(hook, "STATE", state)
    monkeypatch.setattr(hook, "LOG", state / "hook.log")
    monkeypatch.setattr(hook, "HOLD", state / "HOLD.txt")
    monkeypatch.setattr(hook, "LOCK", state / "worker.lock")
    monkeypatch.setattr(hook.time, "sleep", lambda _: None)
    return root


def _stub(monkeypatch: pytest.MonkeyPatch, repo: Path, new_prompt: str) -> None:
    def main(argv):
        path = repo / "AI-USE.md"
        text = path.read_text(encoding="utf-8")
        added = f"{HEAD.replace('17:00', '17:05')}\n\n> {new_prompt}\n\n"
        path.write_text(text.replace(END, added + END), encoding="utf-8")
        return 0
    monkeypatch.setattr(hook.ep, "main", main)


def test_commits_only_ai_use(repo: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _stub(monkeypatch, repo, "Fix the splits")
    (repo / "other.txt").write_text("unrelated edit\n", encoding="utf-8")
    _git(repo, "add", "other.txt")  # staged work elsewhere must not ride along
    assert hook.worker() == 0
    assert _git(repo, "show", "--name-only", "--format=", "HEAD").split() == ["AI-USE.md"]
    assert "> Fix the splits" in _git(repo, "show", "HEAD:AI-USE.md")
    assert not hook.HOLD.exists()


def test_holds_when_ai_use_has_uncommitted_edits(repo: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _stub(monkeypatch, repo, "Fix the splits")
    path = repo / "AI-USE.md"
    path.write_text(path.read_text(encoding="utf-8") + "\nhalf-written row\n", encoding="utf-8")
    assert hook.worker() == 1
    assert "half-written row" in path.read_text(encoding="utf-8")
    assert "Fix the splits" not in path.read_text(encoding="utf-8")
    assert _git(repo, "rev-list", "--count", "HEAD").strip() == "1"
    assert "uncommitted edits" in hook.HOLD.read_text(encoding="utf-8")


@pytest.mark.parametrize("prompt", [
    "Back up HKLM\\SOFTWARE\\WOW6432Node\\swdy first",
    "Open C:\\Users\\someone\\OneDrive - Tenant Uni\\Docs",
])
def test_holds_and_reverts_a_sensitive_new_prompt(
    repo: Path, monkeypatch: pytest.MonkeyPatch, prompt: str
) -> None:
    real = hook.unsafe
    monkeypatch.setattr(hook, "unsafe", lambda text, home=None: real(text, HOME))
    _stub(monkeypatch, repo, prompt)
    before = (repo / "AI-USE.md").read_text(encoding="utf-8")
    assert hook.worker() == 1
    assert (repo / "AI-USE.md").read_text(encoding="utf-8") == before
    assert _git(repo, "rev-list", "--count", "HEAD").strip() == "1"
    assert "--allow-sensitive" in hook.HOLD.read_text(encoding="utf-8")
    assert hook.worker(allow_sensitive=True) == 0
    assert _git(repo, "rev-list", "--count", "HEAD").strip() == "2"


def test_redacted_paths_are_not_flagged() -> None:
    assert not hook.unsafe("Read ~/HYDRODYNAMICS-FIN/src/splits.py and OneDrive/Documents", HOME)
