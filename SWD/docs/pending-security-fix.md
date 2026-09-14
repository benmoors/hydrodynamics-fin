# SUPERSEDED — see [`provenance-gate.md`](provenance-gate.md)

The `BinaryFormatter` provenance gate described here was **applied on 2026-08-27**, with both
defects in the proposed patch fixed first.

This file described a *proposal*. It is superseded by **[`provenance-gate.md`](provenance-gate.md)**,
which records what was actually built, how it was verified, and — more usefully — what it does not do.

Kept as a pointer rather than deleted, because the round-3 verifier's finding about it is worth
remembering: **a patch written before an invariant exists will not satisfy that invariant, and
nothing re-checks it automatically.** The proposal was drafted in round 1 and reviewed as an artifact
in round 3, by which point the containment and privacy rules it violated had been added in rounds 2
and 3. Both defects were real:

- it added a write target outside the containment guard, and
- it reintroduced the exact privacy leak round 3 had removed.

Neither was caught by reading the patch on its own terms. Both were caught by checking it against
invariants that post-dated it.
