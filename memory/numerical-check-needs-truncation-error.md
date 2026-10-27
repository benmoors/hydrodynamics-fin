---
name: numerical-check-needs-truncation-error
description: A check that is exact by construction (e.g. RK4 on a constant right-hand side) is not a numerical comparison; propose one with a real truncation error and an observed order.
metadata:
  type: feedback
---

A "comparison" between a closed form and a numerical method only counts if the method has a real truncation
error. Marching z = phi(delta) with dz/dx = 1 integrates a constant, so RK4 is exact and the march is the
closed form by another route. Benjamin rejected it (2026-10-27) and asked for the singular ODE itself,
d(delta)/dx = nu*beta/(U*alpha*delta), marched from x0 > 0 with a step-halving tolerance and p_obs.

**Why:** a check that cannot fail tells the marker nothing about the method (rubric criterion 4).

**How to apply:** when planning a numerical cross-check, say whether it can differ from the reference at all.
If it is exact by construction, do not call it a comparison; propose one that is not. Grid and tolerance
values remain the author's ([[author-picks-grids-and-tolerances]]).
