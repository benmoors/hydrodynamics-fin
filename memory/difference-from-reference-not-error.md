---
name: difference-from-reference-not-error
description: "A gap to a rounded book value is a \"difference from the reference\", never \"the error\"; and check a predicted test failure against a budget that contains the same term before claiming it."
metadata:
  node_type: memory
  type: feedback
  originSessionId: e90e01ba-3e44-4c52-8696-f95a2e8cc07a
  modified: 2026-10-26T08:15:10.856Z
---

A computed value minus a printed book value (e.g. White's σ = 0.46959999, Eq. 4-64) is a **difference
from the reference**, not "the actual error": the reference carries its own rounding (σ up to 5e-9).
Before claiming a mutant or setting "fails the budget", recompute the budget with that change, because a
budget that includes the changed term (e.g. the secant's own error estimate) grows with it.

**Why:** Benjamin rejected the `skin_and_shear.py` plan (2026-10-26) for both: 2.13e-9 called "the
actual error", and "a 1e-6 secant is 1.34e-8, over budget" when the budget rose to 2.04e-8 (AI-USE E141,
E142).

**How to apply:** in tables, docstrings and AI-USE rows, label gaps to book values as differences from
the named equation; run the mutant before predicting it fails.
