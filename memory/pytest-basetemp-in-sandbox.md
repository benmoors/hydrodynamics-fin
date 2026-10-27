---
name: pytest-basetemp-in-sandbox
description: "Full pytest shows 17 tmp_path ERRORs under Claude Code's sandbox; pass --basetemp in the scratchpad, they are not failures"
metadata:
  node_type: memory
  type: project
  originSessionId: d85b9dcc-1bf4-4b9f-9d25-95f787deeef4
  modified: 2026-10-24T06:17:24.552Z
---

Under Claude Code's sandbox, `%TEMP%\pytest-of-moors` is refused (WinError 5), so every test that
uses `tmp_path` (`test_extract_prompts.py`, `test_prompt_appendix_hook.py`, 17 tests on 2026-10-24)
shows as ERROR while the rest pass. Run the suite with
`.venv\Scripts\python.exe -m pytest -q -p no:cacheprovider --basetemp "<scratchpad>/pytest-tmp"`
and all pass (121 on 2026-10-24).

**Why:** the errors are fixture setup failures from the sandbox, not code failures. Reporting them
as failures, or "fixing" the tests, would be wrong.

**How to apply:** when the full suite shows `PermissionError` on `pytest-of-moors`, re-run with
`--basetemp` before reporting a result, and say which way it was run.
