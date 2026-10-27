---
name: no-unrequested-web-sources
description: "Never pull in Wikipedia (or other web pages) as a source for the wiki or a physics claim unless Benjamin asks; when the unit and repo don't cover something, say so and ask which source to use."
metadata:
  node_type: memory
  type: feedback
  originSessionId: 6461fe50-3e94-4e0d-8b2a-1730ed8989b1
  modified: 2026-10-23T02:21:35.569Z
---

Don't fetch Wikipedia or similar web pages and treat them as a source when nothing in the unit or repo covers a topic. Report the gap and ask which source Benjamin wants (usually a textbook).

**Why:** 2026-10-23, after a wiki update that used Wikipedia's *Blasius boundary layer* page to fill a gap the unit notebooks left: "Remove the source from wikipedia. That is useless, I did not tell you to use wikipedia". The page was deleted and recorded as `AI-USE.md` § 5 E130. Repo rule R8 already points to textbooks and permanent citable documents, and the wiki schema's "web research fills gaps" line does not override what Benjamin wants.

**How to apply:** in a wiki ingest or a physics answer, cite unit notebooks, the brief, the paper, repo docs or SWD data. If none covers the point, leave the claim out or mark it "not compiled, needs a source" and ask, rather than reaching for a web page.
