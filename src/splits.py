"""Grouped train/test splitting for the board surrogate.

Why not ``train_test_split``
----------------------------
Rows in the training table are not independent samples. All 30 operating points of
one hull share its volume, aspect ratio and relative thickness *exactly*, so a
random row split puts near-identical feature vectors on both sides and the reported
R-squared measures memorisation rather than generalisation. Every split in this
module therefore partitions **groups**, never rows.

Two grouping levels, answering two different questions
------------------------------------------------------
``board``
    One group per hull. Answers *"does the surrogate transfer to an unseen board?"*

``family``
    One group per hull **and all geometry variants derived from it**. A sweep
    generates variants by scaling a parent in SWD's Shape Room, so a variant is a
    near-deterministic function of its parent. With a parent in train and its
    variant in test, the across-board claim is worthless. Answers *"does the
    surrogate transfer to an unseen shape?"*

Family membership is read from the board name, because the acquisition side is
frozen and cannot be asked to record it. A variant produced by the sweep is named
``<parent>__v<axis><signed percent>`` -- for example
``default_shortboard__vV+10``. Anything without that marker is its own family.

Note that ``default_shortboard_Copy_1`` and ``_Copy_3`` are *not* treated as one
family: they are separate library boards with genuinely different measured geometry
(35.2 L vs 24.9 L), not variants this project generated. Grouping by a shared name
prefix would be wrong, which is why the marker is an explicit ``__v`` rather than a
prefix heuristic.
"""

from __future__ import annotations

from collections.abc import Iterator

import numpy as np
import pandas as pd

__all__ = [
    "VARIANT_MARKER",
    "family_of",
    "group_labels",
    "holdout_split",
    "leave_one_group_out",
]

#: Separator marking a generated geometry variant from its parent board.
VARIANT_MARKER = "__v"


def family_of(board: str) -> str:
    """Parent board name for a possibly-variant board.

    Parameters
    ----------
    board : str
        Board name as it appears in the training table.

    Returns
    -------
    str
        The parent name if ``board`` carries :data:`VARIANT_MARKER`, else ``board``
        unchanged.

    Examples
    --------
    >>> family_of("default_shortboard__vV+10")
    'default_shortboard'
    >>> family_of("default_shortboard_Copy_3")
    'default_shortboard_Copy_3'
    """
    return board.split(VARIANT_MARKER, 1)[0]


def group_labels(table: pd.DataFrame, level: str = "family") -> pd.Series:
    """Group label per row, for a grouped splitter.

    Parameters
    ----------
    table : pandas.DataFrame
        Training table containing a ``board`` column.
    level : {'family', 'board'}, optional
        ``'family'`` collapses generated variants onto their parent -- the correct
        default for any across-board generalisation claim. ``'board'`` keeps each
        variant separate, which is only valid for a within-family study.

    Returns
    -------
    pandas.Series
        Group label aligned to ``table``'s index.

    Raises
    ------
    ValueError
        If ``level`` is not one of the two accepted values, or ``board`` is absent.
    """
    if "board" not in table.columns:
        raise ValueError("table has no 'board' column; cannot group")
    if level == "board":
        return table["board"].astype(str)
    if level == "family":
        return table["board"].astype(str).map(family_of)
    raise ValueError(f"level must be 'family' or 'board', got {level!r}")


def holdout_split(
    table: pd.DataFrame,
    test_fraction: float = 0.2,
    level: str = "family",
    seed: int = 0,
) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Partition whole groups into a train and an untouched test set.

    Groups are shuffled and assigned to test until the target row fraction is
    reached, so the test fraction is approximate -- groups are indivisible. At least
    one group always lands in test.

    Parameters
    ----------
    table : pandas.DataFrame
        Training table with a ``board`` column.
    test_fraction : float, optional
        Target share of rows to withhold. Defaults to 0.2, the rubric's minimum.
        Must lie in (0, 1).
    level : {'family', 'board'}, optional
        Grouping level, see :func:`group_labels`.
    seed : int, optional
        Seed for the group shuffle, so a split is reproducible.

    Returns
    -------
    tuple of pandas.DataFrame
        ``(train, test)``. No group appears in both.

    Raises
    ------
    ValueError
        If ``test_fraction`` is outside (0, 1), or the table has fewer than two
        groups -- with one group there is no honest split to make.
    """
    if not 0.0 < test_fraction < 1.0:
        raise ValueError(f"test_fraction must be in (0, 1), got {test_fraction}")

    labels = group_labels(table, level)
    groups = np.array(sorted(labels.unique()))
    if groups.size < 2:
        raise ValueError(
            f"need at least 2 {level} groups to split, found {groups.size}"
        )

    rng = np.random.default_rng(seed)
    rng.shuffle(groups)

    target_rows = test_fraction * len(table)
    test_groups: set[str] = set()
    rows = 0
    for name in groups:
        if rows >= target_rows and test_groups:
            break
        test_groups.add(name)
        rows += int((labels == name).sum())

    in_test = labels.isin(test_groups)
    return table[~in_test].copy(), table[in_test].copy()


def leave_one_group_out(
    table: pd.DataFrame, level: str = "family"
) -> Iterator[tuple[str, pd.DataFrame, pd.DataFrame]]:
    """Yield one fold per group, that group held out.

    With 13 boards this gives 13 folds. Report the **spread** of the resulting
    scores, not only their mean: a single unusual hull -- the paddleboard at 130.7 L
    against a 24-59 L cluster -- can carry a large share of the total error, and a
    mean alone conceals that.

    Parameters
    ----------
    table : pandas.DataFrame
        Training table with a ``board`` column.
    level : {'family', 'board'}, optional
        Grouping level, see :func:`group_labels`.

    Yields
    ------
    tuple
        ``(held_out_name, train, test)`` for each group in sorted order.

    Raises
    ------
    ValueError
        If the table has fewer than two groups.
    """
    labels = group_labels(table, level)
    groups = sorted(labels.unique())
    if len(groups) < 2:
        raise ValueError(f"need at least 2 {level} groups, found {len(groups)}")
    for name in groups:
        held = labels == name
        yield name, table[~held].copy(), table[held].copy()
