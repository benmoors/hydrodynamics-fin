---
paths:
  - "AI-USE.md"
  - "README.md"
  - "tools/extract_prompts.py"
  - "tests/test_extract_prompts.py"
---

# AI documentation requirements (moved verbatim from CLAUDE.md §§ 3.1–3.2)

Loads only when `AI-USE.md`, `README.md` or the prompt-extraction tool is read. The repo rules R1–R12 stay in CLAUDE.md § 3.3, always loaded.

### 3.1 What the brief requires

**The reflection must explain all eight of these** (p. 6, verbatim list):

1. which AI tools were used;
2. what they were used for;
3. the approximate level of AI contribution;
4. why AI was used for those tasks;
5. how AI-generated material was checked;
6. which important decisions remained the student's responsibility;
7. any errors, limitations or unhelpful suggestions produced by AI;
8. how AI use affected the student's understanding or workflow.

**Where it must appear — three places, not one:** the written report as item 7 of its required
contents (p. 8); the 5-minute presentation, as "the student's use and evaluation of AI" (p. 9); and the
project itself — "Acknowledgement and details of AI usage" is a bullet of "Each project must include"
(p. 2), which puts it in the repository.

**Two sentences that bind everything else** (p. 6): *"Students remain responsible for all submitted
code, results, claims, references and engineering decisions. Disclosure does not replace
verification."* And, bold in the original: *"You will not be able to use AI to answer questions during
the presentation and interview."*

**The rubric row** (p. 15). Excellent: *"Fully disclosed, critically evaluated, and clearly subordinate
to the student's own work. The student was clearly driving the AI process to arrive at the solution.
Evidence: complete disclosure; justification; verification of AI content; identification of errors;
clear evidence of understanding; thoughtful reflection on AI's impact."* Good drops "complete",
"identification of errors" and "critically evaluated"; Satisfactory adds "uncertainty about
ownership"; Poor includes "unrecognised errors". **Error identification is the Excellent/Good
discriminator.**

**What the brief does NOT require** — so nothing below claims it does: prompt logs or transcripts,
tool versions or dates, vendor names, per-file attribution, a template, a word count, a declaration
form, a named Monash policy, or a file called `AI-USE.md`. Those are this project's choices, made
because they are cheap and make "complete disclosure" checkable.

### 3.2 What the notebook adds

- Every acknowledgement carries **three elements**: *what* AI was used (tool, version, access date,
  how many drafts, known biases), *how* it was used (which parts, how outputs were modified or
  incorporated), and a *statement of human oversight and responsibility*.
- "AI tools are evolving, so … include **version numbers and access dates**" (1.4.2).
- Acknowledge "the tools, **and type of prompts** that were provided" (1.4.2). The notebooks model
  this by quoting prompts verbatim at the point of use — `> ### 🗣️ AI Prompts`, then
  `> ### 🧠 AI Output`, then what the author changed — and closing every document with
  `## 🤖 AI Acknowledgment` (that spelling, that emoji). Match it in human-read documents.
- **Data security** (1.4.3): public AI tools may retain and train on inputs; check who owns inputs
  and outputs; prefer university-provided enterprise tools; treat AI output as possibly manipulated,
  not merely wrong.
- **Accountability**: an engineer acting on wrong AI advice is negligent under duty of care. "Always
  look to professional standards, published papers and textbooks — permanent documents that can be
  cited."

