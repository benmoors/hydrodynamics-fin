"""Leakage tests for the grouped splitters.

A leak here does not raise, crash or look wrong -- it silently inflates every score
in the report. So these tests do not merely check that a correct split is correct;
``test_family_level_catches_a_planted_leak`` **constructs the leak** a naive splitter
would allow and asserts the family splitter refuses it.
"""

from __future__ import annotations

import warnings

import numpy as np
import pandas as pd
import pytest

from src.data import build_training_table
from src.splits import (
    VARIANT_MARKER,
    family_of,
    group_labels,
    holdout_split,
    leave_one_group_out,
)


@pytest.fixture(scope="module")
def table() -> pd.DataFrame:
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        return build_training_table()


def _synthetic(boards: list[str], rows_each: int = 4) -> pd.DataFrame:
    """Minimal table: just the 'board' column, which is all the splitters read."""
    return pd.DataFrame({"board": np.repeat(boards, rows_each)})


class TestFamilyOf:
    def test_variant_maps_to_parent(self):
        assert family_of(f"default_shortboard{VARIANT_MARKER}V+10") == "default_shortboard"

    def test_plain_board_is_its_own_family(self):
        assert family_of("Mini_Simmons") == "Mini_Simmons"

    def test_library_copies_are_not_treated_as_variants(self):
        """Copy_1 and Copy_3 are separate library hulls, 35.2 L vs 24.9 L.

        A prefix heuristic would fuse them and destroy two genuine data points. The
        marker must be explicit.
        """
        assert family_of("default_shortboard_Copy_1") == "default_shortboard_Copy_1"
        assert family_of("default_shortboard_Copy_3") == "default_shortboard_Copy_3"
        assert family_of("default_shortboard_Copy_1") != family_of("default_shortboard")


class TestNoLeakage:
    def test_holdout_shares_no_board(self, table):
        train, test = holdout_split(table)
        assert set(train.board) & set(test.board) == set()

    def test_holdout_shares_no_family(self, table):
        train, test = holdout_split(table)
        assert set(train.board.map(family_of)) & set(test.board.map(family_of)) == set()

    def test_every_row_is_used_exactly_once(self, table):
        train, test = holdout_split(table)
        assert len(train) + len(test) == len(table)

    def test_family_level_catches_a_planted_leak(self):
        """THE test. Plant a parent and its variant; they must never separate.

        At ``level='board'`` they are distinct groups and a splitter is free to put
        one in train and the other in test -- the exact leak that makes a geometry
        sweep prove nothing. At ``level='family'`` that must be impossible for every
        seed, not merely unlikely.
        """
        parent = "default_shortboard"
        boards = [parent, f"{parent}{VARIANT_MARKER}V+10", f"{parent}{VARIANT_MARKER}V-10",
                  "Mini_Simmons", "default_paddle", "Poahaku"]
        planted = _synthetic(boards)

        for seed in range(50):
            train, test = holdout_split(planted, level="family", seed=seed)
            parent_side = {"train" if parent in set(train.board) else "test"}
            for variant in (f"{parent}{VARIANT_MARKER}V+10", f"{parent}{VARIANT_MARKER}V-10"):
                variant_side = "train" if variant in set(train.board) else "test"
                assert {variant_side} == parent_side, (
                    f"seed {seed}: {variant} separated from its parent {parent}"
                )

    def test_board_level_would_have_allowed_the_leak(self):
        """Demonstrates the failure mode is real, not hypothetical.

        Across many seeds, board-level grouping does split a parent from its variant.
        If this ever stops being true the family level has stopped being necessary --
        which would itself be worth knowing.
        """
        parent = "default_shortboard"
        variant = f"{parent}{VARIANT_MARKER}V+10"
        boards = [parent, variant, "Mini_Simmons", "default_paddle"]
        planted = _synthetic(boards)

        separated = False
        for seed in range(50):
            train, test = holdout_split(planted, level="board", seed=seed)
            if (parent in set(train.board)) != (variant in set(train.board)):
                separated = True
                break
        assert separated, "board-level grouping never separated a parent from its variant"


class TestHoldoutSizing:
    def test_withholds_at_least_the_requested_fraction(self, table):
        """Groups are indivisible, so the split rounds up, never down.

        The rubric asks for a minimum of 20 %; undershooting would breach it.
        """
        _, test = holdout_split(table, test_fraction=0.2)
        assert len(test) / len(table) >= 0.2

    def test_is_reproducible(self, table):
        a = holdout_split(table, seed=7)[1].index.tolist()
        b = holdout_split(table, seed=7)[1].index.tolist()
        assert a == b

    def test_different_seeds_give_different_splits(self, table):
        a = set(holdout_split(table, seed=1)[1].board)
        b = set(holdout_split(table, seed=99)[1].board)
        assert a != b

    @pytest.mark.parametrize("bad", [0.0, 1.0, -0.1, 1.5])
    def test_invalid_fraction_refuses(self, table, bad):
        with pytest.raises(ValueError, match="test_fraction"):
            holdout_split(table, test_fraction=bad)

    def test_single_group_refuses(self):
        with pytest.raises(ValueError, match="at least 2"):
            holdout_split(_synthetic(["only_one"]))


class TestLeaveOneGroupOut:
    def test_one_fold_per_group(self, table):
        folds = list(leave_one_group_out(table))
        assert len(folds) == table.board.map(family_of).nunique() == 13

    def test_each_fold_is_disjoint_and_complete(self, table):
        for name, train, test in leave_one_group_out(table):
            assert set(train.board) & set(test.board) == set()
            assert len(train) + len(test) == len(table)
            assert set(test.board.map(family_of)) == {name}

    def test_single_group_refuses(self):
        with pytest.raises(ValueError, match="at least 2"):
            list(leave_one_group_out(_synthetic(["only_one"])))


class TestGroupLabels:
    def test_rejects_unknown_level(self, table):
        with pytest.raises(ValueError, match="must be 'family' or 'board'"):
            group_labels(table, level="row")

    def test_rejects_table_without_board_column(self):
        with pytest.raises(ValueError, match="no 'board' column"):
            group_labels(pd.DataFrame({"x": [1, 2]}))
