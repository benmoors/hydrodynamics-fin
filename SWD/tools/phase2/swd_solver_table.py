"""Live-solver reads (swd_probe.ps1 -Pass SolverLoop) as one CSV row per read.

Input: the solver state directory (default %LOCALAPPDATA%\\swd-probe\\<date>\\solver), holding
solver.jsonl (one record per read) and controls.jsonl (one per (speed, slope) block). Output:
solver_points.csv, one row per board x speed x slope x drift x Pos Y x Pos X read, carrying the
key analysis-grid rows by name (all rows with --all), plus a summary on stdout.

The flags are QA, not filters: every read is written, unless --converged keeps only the reads whose
lift is within CONVERGED_TOL (1 %) of the plateau (both sets are kept, Benjamin 2026-10-08). lift_dev is the lift's deviation from the
board's weight plateau (the solver holds lift at the weight where it converges, so a large value
marks a position it did not; at 5 m/s about half the positions fall short, 2026-10-05, which is
why the reference is the plateau and not the median); element_match is False when the analysis tree showed another position;
same_as_previous is True when every row equals the read before it (a possible stale grid).
element_match compares the analysis tree's label with the position by MAGNITUDE of drift and Y:
SWD labels some positions with negative Y, and (in +3 deg slope blocks) drift 2 as 'Drift -2'
(2026-10-05/06); element_label keeps the raw label so the sign is not lost.

    py -3.14 swd_solver_table.py [--dir DIR] [--out CSV] [--all] [--converged]
    py -3.14 swd_solver_table.py --self-test
"""
import argparse
import csv
import io
import json
import os
import re
import statistics
import sys
from collections import Counter
import tempfile
from datetime import date

# CSV column -> analysis-grid row name (as SWD names it; accents included).
KEY_ROWS = [
    ("lift_n", "portance_globale_verticale_n"),
    ("fz_planing_n", "Fz_planing_n"),
    ("friction_n", "Fx_friction_n"),
    ("fx_planing_n", "Fx_planing"),
    ("fx_rail_n", "Fx_rail_n"),
    ("drag_total_n", "trainée_globale_horizontale_n"),
    ("yaw_moment_nm", "Moment_yaw_hydrodynamic_nm"),
    ("planing_angle_deg", "angle_planing_effectif_deg"),
    ("delta_plan_deg", "delta_plan_horizontal_deg"),
    ("wetted_area_m2", "surface_contact_m2"),
    ("wetted_length_mm", "longueur_mouillée_element_mm"),
    ("volume_l", "volume_litres"),
    ("mass_flux_kg_s", "masse_flux_dévié_kg_sec_planing"),
    ("hydrostatic_fx_n", "Fx_deplacement_hydrostatique_n"),
]
KEYS = ["board", "speed_ms", "slope_deg", "drift_deg", "pos_y", "pos_x"]
QA = ["element_match", "element_label", "same_as_previous", "lift_dev", "select_ms", "settle_ms", "read_ms", "seq"]
CONVERGED_TOL = 0.01  # |lift / plateau - 1| at or below this: the solver held lift at the weight


def converged(row):
    """True when a CSV row's lift is within CONVERGED_TOL of the board's weight plateau."""
    return row["lift_dev"] != "" and abs(row["lift_dev"]) <= CONVERGED_TOL


def number(text):
    """float of a grid value, or None (SWD writes invariant decimals: '807.3515')."""
    try:
        return float(str(text).strip())
    except (TypeError, ValueError):
        return None


def label_matches(label, drift, y, x):
    """The analysis tree's 'Drift D<deg> / Pos Y=Y X=X' label against a position, by magnitude of
    drift and Y. None when the label does not parse."""
    m = re.search(r"^Drift\s+(-?[0-9.]+)\D*?Pos Y=(-?[0-9.]+)\s+X=(-?[0-9.]+)\s*$", str(label or ""))
    if not m or None in (drift, y, x):
        return None
    d, yy, xx = (float(v) for v in m.groups())
    return abs(abs(d) - abs(float(drift))) < 1e-6 and abs(abs(yy) - abs(float(y))) < 1e-6 and abs(xx - float(x)) < 1e-6


def read_jsonl(path):
    out = []
    if not os.path.exists(path):
        return out
    with open(path, encoding="utf-8-sig") as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def plateau(values):
    """The weight plateau of a board's lifts: the most common 1 N bin of the POSITIVE lifts,
    refined to the median of the values within 1% of it. None for no positive values, or when the
    most common bin is 0 (a zero lift is a non-converged read, not a valid weight)."""
    values = [v for v in values if v > 0]
    if not values:
        return None
    centre = Counter(round(v) for v in values).most_common(1)[0][0]
    if centre == 0:
        return None
    near = [v for v in values if abs(v / centre - 1) <= 0.01]
    return statistics.median(near) if near else centre


def dedupe(records):
    """One record per Seq, the last one written: a chunk stopped between appending a read and
    saving its cursor reads that position again on resume."""
    last = {}
    for r in records:
        last[r.get("Seq")] = r
    return [last[k] for k in sorted(last, key=lambda x: (x is None, x))]


def rows_of(records, all_rows=False):
    """CSV rows (dicts) for solver records, with lift_dev against each board's weight plateau."""
    lifts = {}
    for r in records:
        v = number(r.get("Lift"))
        if v is not None:
            lifts.setdefault(r.get("Board"), []).append(v)
    median = {b: plateau(v) for b, v in lifts.items() if v}
    extra = []
    if all_rows:
        seen = set(name for _, name in KEY_ROWS)
        for r in records:
            for name in (r.get("Rows") or {}):
                if name not in seen:
                    seen.add(name)
                    extra.append(name)
    out = []
    for r in records:
        grid = r.get("Rows") or {}
        row = {"board": r.get("Board"), "speed_ms": r.get("Speed"), "slope_deg": r.get("Slope"),
               "drift_deg": r.get("Drift"), "pos_y": r.get("Y"), "pos_x": r.get("X")}
        for col, name in KEY_ROWS:
            row[col] = grid.get(name, "")
        for name in extra:
            row[name] = grid.get(name, "")
        lift = number(r.get("Lift"))
        m = median.get(r.get("Board"))
        row["lift_dev"] = "" if lift is None or not m else round(lift / m - 1, 6)
        lm = label_matches(r.get("Element"), r.get("Drift"), r.get("Y"), r.get("X"))
        row["element_match"] = r.get("ElementMatch") if lm is None else lm
        row["element_label"] = " ".join(str(r.get("Element") or "").split())
        row["same_as_previous"] = r.get("SameAsPrevious")
        row["select_ms"], row["settle_ms"], row["read_ms"] = r.get("SelectMs"), r.get("SettleMs"), r.get("ReadMs")
        row["seq"] = r.get("Seq")
        out.append(row)
    return out, extra


def write_csv(rows, extra, path):
    cols = KEYS + [c for c, _ in KEY_ROWS] + list(extra) + QA
    with open(path, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow(r)


def summary(rows, controls):
    lines = [f"reads: {len(rows)}"]
    if not rows:
        return lines
    pos = {(r["drift_deg"], r["pos_y"], r["pos_x"]) for r in rows}
    blocks = {(r["speed_ms"], r["slope_deg"]) for r in rows}
    lines.append(f"positions: {len(pos)}  blocks (speed, slope): {len(blocks)}  drifts: {sorted({r['drift_deg'] for r in rows})}")
    lines.append(f"element mismatches: {sum(1 for r in rows if r['element_match'] is False)}")
    lines.append(f"same as previous read: {sum(1 for r in rows if r['same_as_previous'] is True)}")
    devs = [abs(r["lift_dev"]) for r in rows if r["lift_dev"] != ""]
    if devs:
        lines.append(f"lift off the weight plateau by >1% (not converged): {sum(1 for d in devs if d > CONVERGED_TOL)} (max {max(devs):.4f})")
    for key in ("select_ms", "settle_ms", "read_ms"):
        v = [r[key] for r in rows if isinstance(r[key], (int, float))]
        if v:
            lines.append(f"{key}: median {statistics.median(v):.0f}, max {max(v)}")
    if controls:
        bad = [c.get("Block") for c in controls if not c.get("Match")]
        lines.append(f"block controls: {len(controls) - len(bad)} matched, {len(bad)} differed {bad}")
    return lines


def self_test():
    rec = lambda seq, lift, x, rows=None: {
        "Seq": seq, "Board": "b_Copy_1", "Speed": "10", "Slope": "0", "Drift": 0, "Y": 0, "X": x,
        "ElementMatch": True, "SameAsPrevious": False, "Lift": lift, "SelectMs": 90, "SettleMs": 1100, "ReadMs": 300,
        "Rows": rows if rows is not None else {"portance_globale_verticale_n": lift, "trainée_globale_horizontale_n": "201.171249", "Extra_row": "1"}}
    recs = [rec(0, "807.2", 0.1), rec(1, "807.4", 0.467), rec(2, "500", 0.45, {"portance_globale_verticale_n": "500"}), rec(3, "807.3", 0.5)]
    rows, extra = rows_of(recs)
    assert extra == [], extra
    assert rows[0]["drag_total_n"] == "201.171249", rows[0]
    assert rows[2]["drag_total_n"] == "", "a missing row is blank, not dropped"
    assert abs(rows[3]["lift_dev"]) < 1e-9, "807.3 is the plateau of 807.2, 807.4, 807.3 (500 did not converge)"
    assert abs(rows[2]["lift_dev"] - (500 / 807.3 - 1)) < 1e-6
    assert [r["seq"] for r in rows if converged(r)] == [0, 1, 3], "500 N is not converged"
    assert not converged({"lift_dev": ""}) and converged({"lift_dev": -0.01}) and not converged({"lift_dev": 0.0101})
    assert plateau([27.0, 807.3, 807.3, 19.6, 21.1, 807.4]) == 807.3, "a majority of failures does not move it"
    rows_all, extra_all = rows_of(recs, all_rows=True)
    assert extra_all == ["Extra_row"], extra_all
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "t.csv")
        write_csv(rows_all, extra_all, p)
        raw = open(p, "rb").read()
        assert not raw.startswith(b"\xef\xbb\xbf"), "no BOM"
        back = list(csv.DictReader(io.StringIO(raw.decode("utf-8"))))
        assert len(back) == 4 and back[1]["pos_x"] == "0.467" and back[0]["Extra_row"] == "1"
        j = os.path.join(d, "s.jsonl")
        with open(j, "w", encoding="utf-8") as f:
            f.write(json.dumps(recs[0], ensure_ascii=True) + "\n\n" + json.dumps(recs[1], ensure_ascii=False) + "\n")
        assert len(read_jsonl(j)) == 2, "blank lines skipped, both escapes read"
    s = summary(rows, [{"Block": "v=10|s=0", "Match": True}, {"Block": "v=5|s=0", "Match": False}])
    assert any("block controls: 1 matched, 1 differed" in x for x in s), s
    assert any("lift off the weight plateau by >1% (not converged): 1" in x for x in s), s
    assert number("abc") is None and number(" 12.5 ") == 12.5
    assert label_matches("Drift -2\u00b0\r\nPos Y=-0.027 X=0.15", 2, 0.027, 0.15) is True
    assert label_matches("Drift 2\u00b0\r\nPos Y=0 X=0.15", 2, 0.027, 0.15) is False
    assert label_matches("Details element0", 2, 0, 0.15) is None
    # S21: the label rule is anchored at both ends (the same rule as swd_probe.ps1 ConvertFrom-SwdSolverElement)
    assert label_matches("Drift 2\u00b0\r\nPos Y=0 X=0.15 extra", 2, 0, 0.15) is None, "trailing text is not a label"
    assert label_matches("Drift 2\u00b0\r\nPos Y=0 X=0.4 7", 2, 0, 0.4) is None, "'X=0.4 7' is not position X=0.4"
    assert label_matches("see Drift 2\u00b0 Pos Y=0 X=0.15", 2, 0, 0.15) is None, "leading text is not a label"
    assert label_matches("Drift 2\u00b0\r\nPos Y=0 X=0.15 \r\n", 2, 0, 0.15) is True, "trailing blanks are allowed"
    # S21: the plateau is a weight: positive lifts only, and never a bin that rounds to 0 N
    assert plateau([0.1, 0.2, 0.3]) is None, "lifts that all round to 0 N have no plateau"
    assert plateau([0.0, 0.0, 0.0, 807.3]) == 807.3, "zero lifts are non-converged reads, not the plateau"
    assert plateau([-807.3, -807.3, 500.0]) == 500.0, "negative lifts are not weights"
    d = dedupe([{"Seq": 1, "v": "a"}, {"Seq": 0, "v": "b"}, {"Seq": 1, "v": "c"}])
    assert [x["v"] for x in d] == ["b", "c"], d
    print("self-test passed")


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dir", default=os.path.join(os.environ.get("LOCALAPPDATA", ""), "swd-probe", date.today().isoformat(), "solver"))
    ap.add_argument("--out", default=None, help="CSV path (default <dir>/solver_points.csv)")
    ap.add_argument("--all", action="store_true", help="every analysis-grid row, not only the key ones")
    ap.add_argument("--converged", action="store_true", help="only reads whose lift is within 1 %% of the weight plateau")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        self_test()
        return 0
    records = dedupe(read_jsonl(os.path.join(a.dir, "solver.jsonl")))
    controls = read_jsonl(os.path.join(a.dir, "controls.jsonl"))
    rows, extra = rows_of(records, a.all)
    out = a.out or os.path.join(a.dir, "solver_points.csv")
    kept = [r for r in rows if converged(r)] if a.converged else rows
    write_csv(kept, extra, out)
    for line in summary(rows, controls):
        print(line)
    print(f"wrote {len(kept)} of {len(rows)} rows" + (" (converged only)" if a.converged else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
