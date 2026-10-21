"""Translate SWD's French CSV column headings to English, in place.

SWD names its data fields in French, and extract_board.ps1 and phase2/swd_solver_table.py write
those names straight into their CSV headers. This rewrites the header line of each CSV through
column_names.csv (one row per SWD field, with the evidence for its translation; see
SWD/docs/column-names.md) and leaves every data row byte for byte as it was. Run it after either
tool. Names already in English are not in the map and pass through, so a second run changes
nothing (Benjamin 2026-10-21: French only, the extractor itself untouched).

    py -3.14 SWD/tools/translate_columns.py [CSV ...]
    py -3.14 SWD/tools/translate_columns.py --self-test
"""
import argparse
import csv
import glob
import io
import os
import re
import sys
import tempfile
import unicodedata
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
MAP = os.path.join(HERE, "column_names.csv")
DATA = os.path.normpath(os.path.join(HERE, "..", "data"))
DEFAULT = ["*/board.csv", "*/elements.csv", "*/sub_elements.csv", "live_solver/*/*/*.csv"]


def fold(name):
    """Match key for an SWD name: accents dropped, outer underscores stripped, lower case. The
    per-board CSVs carry ASCII-folded .NET names (deviation_rail_deg), the live solver SWD's grid
    names (Deviation_rail_deg, index_point_decrochage_); both fold to one key."""
    return unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode().strip("_").lower()


def read_map(path=MAP):
    with open(path, encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def load_map(path=MAP):
    """{folded SWD name: English name}. Refuses two rows on one key, or one English name twice."""
    out = {}
    for r in read_map(path):
        k = fold(r["swd_name"])
        if k in out:
            raise ValueError(f"{r['swd_name']}: folds onto a key already in the map")
        out[k] = r["english"]
    dup = sorted(n for n, c in Counter(out.values()).items() if c > 1)
    if dup:
        raise ValueError(f"English names used twice: {dup}")
    return out


def translate_file(path, names):
    """Rename one CSV's header in place and return [(old, new)]. Data rows are not touched; a file
    whose renamed header would repeat a name is refused and left as it was."""
    with open(path, "rb") as f:
        raw = f.read()
    if raw.startswith(b"\xef\xbb\xbf"):
        raise ValueError(f"{path}: has a BOM (the readers downstream expect none)")
    end = raw.find(b"\n")
    head, body = (raw, b"") if end < 0 else (raw[:end + 1], raw[end + 1:])
    text = head.decode("utf-8")
    line = text.rstrip("\r\n")
    cols = next(csv.reader([line]))
    new = [names.get(fold(c), c) for c in cols]
    renamed = [(a, b) for a, b in zip(cols, new) if a != b]
    if not renamed:
        return []
    dup = sorted(n for n, c in Counter(new).items() if c > 1)
    if dup:
        raise ValueError(f"{path}: renaming would repeat {dup}")
    buf = io.StringIO()
    quoting = csv.QUOTE_ALL if line.startswith('"') else csv.QUOTE_MINIMAL
    csv.writer(buf, quoting=quoting, lineterminator=text[len(line):]).writerow(new)
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(buf.getvalue().encode("utf-8") + body)
    os.replace(tmp, path)
    return renamed


def default_paths():
    return sorted(p for pat in DEFAULT for p in glob.glob(os.path.join(DATA, pat)))


def self_test():
    assert fold("_trainée_globale_horizontale_n") == "trainee_globale_horizontale_n"
    assert fold("Deviation_rail_deg") == fold("deviation_rail_deg")
    assert fold("index_point_decrochage_") == "index_point_decrochage"
    names = load_map()
    assert names[fold("section_frontale_flux_dévié_m2_planing")] == "frontal_section_m2"
    assert names[fold("vitesse_flux_relatif_ms")] == "board_speed_setting_ms", "metadata, not the scan speed"
    assert all(re.fullmatch(r"[a-z0-9_]+", v) for v in names.values()), "English names are snake_case"
    assert fold("Fx_friction_n") not in names, "English names are not in the map"
    with tempfile.TemporaryDirectory() as d:
        body = b'"1","2,5","x"\r\n"3","4","y"\r\n'
        q = os.path.join(d, "q.csv")
        with open(q, "wb") as f:
            f.write(b'"board","trainee_globale_horizontale_n","Fx_friction_n"\r\n' + body)
        assert translate_file(q, names) == [("trainee_globale_horizontale_n", "drag_total_n")]
        raw = open(q, "rb").read()
        assert raw == b'"board","drag_total_n","Fx_friction_n"\r\n' + body, raw
        assert translate_file(q, names) == [] and open(q, "rb").read() == raw, "a second run changes nothing"
        u = os.path.join(d, "u.csv")
        with open(u, "wb") as f:
            f.write(b"seq,Deviation_rail_deg,index_\n1,2,3\n")
        assert translate_file(u, names) == [("Deviation_rail_deg", "rail_deviation_deg")]
        assert open(u, "rb").read() == b"seq,rail_deviation_deg,index_\n1,2,3\n", "unquoted stays unquoted"
        c = os.path.join(d, "c.csv")
        clash = b"drag_total_n,trainee_globale_horizontale_n\n1,2\n"
        with open(c, "wb") as f:
            f.write(clash)
        try:
            translate_file(c, names)
            raise AssertionError("a repeated heading must be refused")
        except ValueError:
            pass
        assert open(c, "rb").read() == clash, "a refused file is left alone"
        b = os.path.join(d, "b.csv")
        with open(b, "wb") as f:
            f.write(b"\xef\xbb\xbfnom_\n1\n")
        try:
            translate_file(b, names)
            raise AssertionError("a BOM must be refused")
        except ValueError:
            pass
        m = os.path.join(d, "m.csv")
        with open(m, "w", encoding="utf-8") as f:
            f.write("swd_name,english\nDeviation_rail_deg,a\ndeviation_rail_deg_,b\n")
        try:
            load_map(m)
            raise AssertionError("two rows folding onto one key must be refused")
        except ValueError:
            pass
    print("self-test passed")


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("paths", nargs="*", help="CSV files (default: every per-board and live-solver CSV under SWD/data)")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        self_test()
        return 0
    names = load_map()
    total = 0
    for p in a.paths or default_paths():
        renamed = translate_file(p, names)
        total += len(renamed)
        print(f"{len(renamed):3} renamed  {os.path.relpath(p)}")
    print(f"{total} headings renamed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
