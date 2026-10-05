# SQA log — HYDRODYNAMICS-FIN

- `SWD/tools/swd_extract.ps1`
- `SWD/tools/tests/swd_extract.Tests.ps1`
- `SWD/tools/probe_fins.ps1`
- `SWD/tools/census_board.ps1`
- `SWD/tools/extract_board.ps1`
- `SWD/tools/phase2/swd_probe.ps1`
- `SWD/tools/phase2/tests/swd_probe.Tests.ps1`
- `SWD/tools/phase2/swd_diff.py`
- `SWD/tools/phase2/swd_geometry.ps1`
- `SWD/tools/phase2/tests/swd_geometry.Tests.ps1`
- `SWD/tools/phase2/swd_uia3.py` (new 2026-10-01: read-only UIA3 census for the input sweep)
- `SWD/tools/phase2/swd_sweep_matrix.py` (new 2026-10-01: input → output matrix from the sweep)
- `swd_probe.ps1` and its tests again: the `-Probe Sweep` section, NEW-1 fix and allowlist additions of 2026-10-01 have had no SQA pass
- `SWD/tools/phase2/swd_solver_table.py` (new 2026-10-05: live-solver reads → `solver_points.csv`)
- `swd_probe.ps1` and its tests again: the live-solver passes (`-Pass SolverPilot | SolverLoop | SolverRestore`), the `-tree` MSAA verbs, `ListSelect`, the cursor-guard and `-SweepDir` fixes of 2026-10-05, run live before this pass at Benjamin's instruction
