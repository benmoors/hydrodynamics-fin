"""Shared fixtures."""

import pytest

from src.forward_model import forward_model as fm


@pytest.fixture(scope="session")
def authors_run():
    """simulate() at its defaults, the only motion input, run once per session (the author's choice, AI-USE.md 4)."""
    return fm.simulate()
