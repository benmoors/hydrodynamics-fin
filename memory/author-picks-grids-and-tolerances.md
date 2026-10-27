---
name: author-picks-grids-and-tolerances
description: x0, x_end, step sizes and tolerances in a numerical check are Benjamin's to choose; run an exploration table, show it, and wait, never tuning values to hit the expected order.
metadata:
  type: feedback
---

In a numerical check (march start x0, end x_end, h / h/2 / h/4, p_obs tolerance), Claude Code does not pick
the values. It runs a few combinations, shows the table (x0, h, h/x0, error at each h, p_obs) and waits for
Benjamin's choice. It never adjusts x0 or h to make p_obs reach the theoretical order. If p_obs falls short
because h is not small against x0, it reports that as measured.

**Why:** Benjamin, 2026-10-27, on `march_delta`: "these are my choices. Don't pick them." Tuning a grid to
reach the expected order would make the verification evidence circular (R12, rubric criterion 4).

**How to apply:** for any verification test with grid or tolerance parameters, stop before writing the test
and show the exploration table. See also [[numerical-check-needs-truncation-error]] and
[[difference-from-reference-not-error]].
