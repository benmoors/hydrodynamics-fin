"""The notebooks that sit beside their modules: their imports resolve from the repository root and from their folder.

Only each notebook's top-level imports and its sys.path set-up are run, in a fresh interpreter, so a stale module path
(the failure the 2026-10-28 move into src/ could cause) fails here instead of in front of a reader. The computation in
the notebooks is not run.
"""

from __future__ import annotations

import ast
import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
NOTEBOOKS = sorted(ROOT.glob("src/**/*.ipynb"))


def setup_code(nb_path: Path) -> str:
    """The notebook's top-level imports, ROOT assignment and sys.path inserts, in cell order."""
    kept = []
    for cell in json.loads(nb_path.read_text(encoding="utf-8"))["cells"]:
        if cell["cell_type"] != "code":
            continue
        for node in ast.parse("".join(cell["source"])).body:
            text = ast.unparse(node)
            if isinstance(node, (ast.Import, ast.ImportFrom)) or text.startswith(("ROOT =", "sys.path.insert(")):
                kept.append(text)
    return "\n".join(kept)


def test_the_four_notebooks_are_found() -> None:
    assert [p.name for p in NOTEBOOKS] == ["fd_vs_shooting_cc.ipynb", "rk4_blasius_checks_cc.ipynb",
                                           "shooting_for_blasius.ipynb", "vonkarman.ipynb"]


@pytest.mark.parametrize("where", ["repository root", "notebook folder"])
@pytest.mark.parametrize("nb_path", NOTEBOOKS, ids=lambda p: p.name)
def test_notebook_imports_resolve(nb_path: Path, where: str) -> None:
    cwd = ROOT if where == "repository root" else nb_path.parent
    result = subprocess.run([sys.executable, "-c", setup_code(nb_path)], cwd=cwd, capture_output=True, text=True,
                            timeout=300)
    assert result.returncode == 0, result.stderr[-2000:]
