---
name: archive-not-delete
description: "When Benjamin asks to remove his own work files from the repo, move them to his UNIVERSITY project folder (hash-checked) rather than deleting them, especially untracked files git cannot restore."
metadata:
  node_type: memory
  type: feedback
  originSessionId: a3cd550c-2e9c-41be-8d73-22a19b485853
  modified: 2026-10-27T09:31:45.456Z
---

Removing his work from the repo means moving it out, not deleting it. Unit material goes to
`~\UNIVERSITY\Mechanical Engineering\Year 2\MMA3001\Project\`. Check the destination first, compare the SHA-256
after the move, and only then confirm the repo copy is gone. Deleting a merged git branch with `git branch -d` is
fine, because its commits survive.

**Why:** 2026-10-27. He first answered "Yes, delete the folder" for the untracked `PINNs/PINN.ipynb`, then
changed it while rejecting the plan: "Don't delete PINNs/. Move it to …\MMA3001\Project\PINNs\ instead." An
untracked file has no git copy, so a deletion is permanent. He keeps deferred work, here the inverse PINN, for
later.

**How to apply:** for "remove", "delete" or "get rid of" on his own files, offer the move by default and say where
the files will go. Delete only on an explicit "delete permanently".
