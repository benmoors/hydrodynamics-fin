---
name: test-constants-hard-coded
description: "Constants in a test (a coefficient, a reference value, a crossing speed) are hard-coded numbers with their derivation in a comment, never computed at test time from the module or the data under test."
metadata:
  node_type: memory
  type: feedback
  originSessionId: a3cd550c-2e9c-41be-8d73-22a19b485853
  modified: 2026-10-27T09:31:40.578Z
---

A test's constants and reference values are written into the test as numbers, with a comment saying where each
came from and on what date. Example: E19's c = 79.66155266587084 N·s²/m² = D(2 m/s, 20°, k = 1)/2², and SWD's
`drag_total_n` zero crossing at 7.292572140736888 m/s. They are not recomputed from the force data or the module
when the test runs.

**Why:** Benjamin, 2026-10-27, rejecting the forward-model plan: "In the E19 test, hard-code c as a number;
don't compute it from the force data." A constant derived from the same code or data as the thing under test can
pass against itself. It is the same reason `test_von_karman.py` hard-codes ALPHA and BETA.

**How to apply:** when a test needs a value that comes from the data, compute it once while planning, show it,
and paste the full-precision number with its provenance into the test. The model under test may still compute
its own output, such as V* by brentq. See also [[author-picks-grids-and-tolerances]].
