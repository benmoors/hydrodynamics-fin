"""Input -> output matrix from an SWD input sweep (swd_probe.ps1 -Probe Sweep).

Reads <sweep>/state.json (the manifest), trials.jsonl (Map pass) and curves.jsonl (Curve pass) and writes,
into <out>:
  effects.csv    one row per (input, output) pair that moved, with how consistently it moved
  inputs.csv     one row per input: what it is, whether SWD took the value, how many outputs it moves
  curves.csv     Pass-2 response: input level -> output value, numbers parsed where the text holds one
  matrix.md      the same, readable: per input, the outputs it moves, grouped by owner

An output counts as AFFECTED by an input only when it changed in BOTH repeats of at least one tested value
(Rep 1 and Rep 2 run back to back). A change seen in one repeat only is listed as NOISY, never as an effect:
that is the guard against reading SWD's own idle churn as a response. 'Rect' changes are layout, kept apart.

Usage:  py -3.14 swd_sweep_matrix.py <sweep dir> <out dir>
        py -3.14 swd_sweep_matrix.py --self-test
"""
import csv
import json
import os
import re
import sys
from collections import OrderedDict, defaultdict
from datetime import datetime

NUM = re.compile(r"[-+]?(?:\d+[.,]?\d*|[.,]\d+)(?:[eE][-+]?\d+)?")


def load_jsonl(path):
    if not os.path.exists(path):
        return []
    out = []
    with open(path, encoding="utf-8-sig") as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def as_list(x):
    if x is None:
        return []
    return x if isinstance(x, list) else [x]


def key(c):
    # An image change is keyed by the control it falls in, not its box: box edges move by a tile
    # between repeats, which would split one effect into two 'noisy' halves.
    if c.get("Ch") == "image":
        return f'image|{c.get("Owner")}||pixels'
    return f'{c.get("Ch")}|{c.get("Owner")}|{c.get("Item")}|{c.get("Field")}'


def numbers(text):
    """Every number in a text, comma decimals read as points (SWD writes both)."""
    return [float(m.replace(",", ".")) for m in NUM.findall(text or "") if m not in (".", ",")]


def analyse(manifest, trials):
    """(effects, inputs) rows. Pure; the self-test pins it."""
    by_input = defaultdict(lambda: defaultdict(dict))  # input -> value -> rep -> record
    errors = defaultdict(list)
    for t in trials:
        if t.get("Error"):
            errors[t.get("Input")].append(t["Error"])
            continue
        by_input[t["Input"]][str(t.get("Value"))][int(t.get("Rep", 1))] = t
    effects, inputs = [], []
    for spec in manifest:
        iid = spec["Id"]
        vals = by_input.get(iid, {})
        seen = OrderedDict()  # output key -> info
        took, tried, exact = 0, 0, 0
        for v, reps in vals.items():
            ks = {}
            for rep, rec in reps.items():
                tried += 1
                took += 1 if rec.get("TookValue") else 0
                exact += 1 if rec.get("RestoreExact") else 0
                ks[rep] = {key(c): c for c in as_list(rec.get("Changes")) if c}
            common = set.intersection(*(set(k) for k in ks.values())) if len(ks) >= 2 else set()
            union = set().union(*(set(k) for k in ks.values())) if ks else set()
            # Sorted: a set of strings iterates in hash order, which changes run to run, and so did
            # the row order of effects.csv and matrix.md (S18).
            for k in sorted(union):
                c = next(d[k] for d in ks.values() if k in d)
                info = seen.setdefault(k, {"c": c, "consistent": [], "noisy": [], "examples": []})
                (info["consistent"] if k in common else info["noisy"]).append(v)
                if len(info["examples"]) < 3:
                    info["examples"].append(f'{v}: {c.get("From", "")} -> {c.get("To", "")}')
        n_aff = 0
        for k, info in seen.items():
            c = info["c"]
            cls = "self" if c.get("InScope") else ("layout" if c.get("Field") == "Rect" else
                                                  ("effect" if info["consistent"] else "noisy"))
            n_aff += 1 if cls == "effect" else 0
            effects.append({"input": iid, "label": spec.get("Label", ""), "class": cls, "channel": c.get("Ch"),
                            "owner": c.get("Owner"), "item": c.get("Item"), "field": c.get("Field"),
                            "consistent_values": ";".join(info["consistent"]), "noisy_values": ";".join(info["noisy"]),
                            "examples": " | ".join(info["examples"])})
        inputs.append({"input": iid, "label": spec.get("Label", ""), "mode": spec.get("Mode"), "kind": spec.get("Kind"),
                       "tab": spec.get("TabPath"), "apply": spec.get("Apply") or "", "base": spec.get("Base"),
                       "values": ";".join(str(v) for v in as_list(spec.get("Values"))), "trials": tried,
                       "took_value": took, "restored_exactly": exact, "outputs_moved": n_aff,
                       "errors": " | ".join(errors.get(iid, []))[:500]})
    return effects, inputs


def curve_rows(curves):
    rows = []
    for r in curves:
        for c in as_list(r.get("Changes")):
            if not c or c.get("InScope"):
                continue
            nf, nt = numbers(c.get("From")), numbers(c.get("To"))
            rows.append({"input": r.get("Input"), "base": r.get("Base"), "level": r.get("Value"), "readback": r.get("ReadBack"),
                         "output": key(c), "from": c.get("From"), "to": c.get("To"),
                         "from_num": nf[0] if len(nf) == 1 else "", "to_num": nt[0] if len(nt) == 1 else ""})
    return rows


# --- Property grids, keyed by ROW NAME from the snapshot files -----------------------------------------
# The sweep's own diff keys MSAA nodes by position. A property grid re-lays its rows whenever the object
# it shows changes, so a positional diff pairs different rows and reports nonsense 'from' values (seen:
# Offset_x_embase_mm '0.5578' -> '0', which was a yaw inertia). Grids are therefore re-read here by name.
GRID_MARKERS = {
    "analysis": ("Fx_friction_n", "portance_globale_verticale_n", "Moment_yaw_hydrodynamic_nm", "surface_contact_m2"),
    "board": ("Vitesse_geographique_ms_3d", "Rayon_centrifuge_m", "Ra_micron", "volume_litre"),
}


def gridvals(nodes):
    """{grid kind: {row name: value}} from one snapshot's MSAA nodes (pure). Cells are role 29 and visible;
    a grid is identified by its marker rows; a repeated row name gets '#2', '#3'."""
    by_hwnd = OrderedDict()
    for n in nodes or []:
        if str(n.get("Role")) == "29" and not n.get("Hidden") and n.get("Name"):
            by_hwnd.setdefault(n.get("Hwnd"), []).append(n)
    out = {}
    for cells in by_hwnd.values():
        names = {c["Name"] for c in cells}
        kind = next((k for k, m in GRID_MARKERS.items() if names & set(m)), "other")
        rows, seen = OrderedDict(), defaultdict(int)
        for c in cells:
            seen[c["Name"]] += 1
            rows[c["Name"] if seen[c["Name"]] == 1 else f'{c["Name"]}#{seen[c["Name"]]}'] = c.get("Value")
        k, i = kind, 2
        while k in out:
            k, i = f"{kind}{i}", i + 1
        out[k] = rows
    return out


def griddiff(before, after):
    """Rows whose value differs, by grid and name (pure). A row present on one side only is not a change
    of value; it is reported as appeared/vanished so a re-laid grid cannot pose as a response."""
    rows = []
    for g in sorted(set(before) | set(after)):
        b, a = before.get(g, {}), after.get(g, {})
        for name in a:
            if name in b and str(b[name]) != str(a[name]):
                rows.append((g, name, b[name], a[name]))
        if set(a) != set(b) and b and a:
            rows.append((g, "#rows", f"{len(b)} rows", f"{len(a)} rows, {len(set(a) ^ set(b))} names differ"))
    return rows


def load_snap(path):
    with open(path, encoding="utf-8-sig") as f:
        return json.load(f)


def grid_of(path):
    """Grid rows of one snapshot file, or None when its MSAA walk was truncated (a cut walk is not a reading).
    Only the reduced grids outlive the call, so two parsed ~2 MB snapshots are never held at once (E1)."""
    snap = load_snap(path)
    if snap.get("MsaaTruncated"):
        return None
    return gridvals(snap.get("Msaa"))


def trial_window(t, slack=2.0):
    """[start, end] in epoch seconds of one Map trial: its Started stamp to Started + ElapsedMs, widened by
    `slack` (pure). None when the record lacks either. Every snapshot a trial writes falls inside it."""
    try:
        start = datetime.fromisoformat(str(t["Started"])).timestamp()
        return start - slack, start + float(t["ElapsedMs"]) / 1000.0 + slack
    except (KeyError, TypeError, ValueError):
        return None


def grid_effects(trials, probe_root, skipped=None):
    """Name-keyed grid changes per Map trial, from its OWN -b and -a snapshots; consistent = seen in both reps.

    A snapshot is a trial's own when it was written inside the trial's time window (W6). Files are named
    <seq>-<target>-<value>-r<rep>, so the S-mode and D-mode trials of one designer name, value and rep share a
    name apart from the sequence, and taking the newest scored the S trial from the D trial's snapshots (16
    of the 2026-10-01 trials). `skipped`, a dict, counts the trials left out: 'truncated' (an MSAA walk was
    cut short) and 'unmatched' (no before/after pair of its own)."""
    files = defaultdict(list)
    for root, _, fns in os.walk(probe_root):
        if os.path.basename(root) != "trials":
            continue
        for fn in fns:
            m = re.match(r"(\d{4})-(.+)-r(\d)-([bar])\.json$", fn)
            if m:
                p = os.path.join(root, fn)
                files[(m.group(2), m.group(3))].append((os.path.getmtime(p), m.group(4), p, m.group(1)))
    skipped = {} if skipped is None else skipped
    skipped.setdefault("truncated", 0)
    skipped.setdefault("unmatched", 0)
    seen = defaultdict(lambda: defaultdict(set))  # (input, value) -> key -> reps
    examples = {}
    for t in trials:
        if t.get("Error"):
            continue
        tag = re.sub(r"[^\w.-]", "_", f'{t.get("Target")}-{t.get("Value")}')
        cands = files.get((tag, str(t.get("Rep", 1))), [])
        win = trial_window(t)
        if win:
            cands = [x for x in cands if win[0] <= x[0] <= win[1]]
        elif len({x[3] for x in cands}) > 1:
            cands = []  # no window, and more than one trial wrote this name: never guess which one is ours
        b = sorted((x for x in cands if x[1] == "b"), key=lambda x: x[0])
        a = sorted((x for x in cands if x[1] == "a"), key=lambda x: x[0])
        if not b or not a:
            skipped["unmatched"] += 1
            continue
        gb = grid_of(b[-1][2])
        ga = grid_of(a[-1][2]) if gb is not None else None
        if gb is None or ga is None:
            skipped["truncated"] += 1
            continue
        for g, name, fr, to in griddiff(gb, ga):
            k = (t["Input"], str(t.get("Value")))
            seen[k][(g, name)].add(int(t.get("Rep", 1)))
            examples.setdefault((t["Input"], g, name), f'{t.get("Value")}: {fr} -> {to}')
    rows = []
    agg = defaultdict(lambda: {"consistent": [], "noisy": []})
    for (inp, val), keys in seen.items():
        for (g, name), reps in keys.items():
            agg[(inp, g, name)]["consistent" if len(reps) >= 2 else "noisy"].append(val)
    for (inp, g, name), v in sorted(agg.items()):
        rows.append({"input": inp, "grid": g, "row": name, "class": "effect" if v["consistent"] else "noisy",
                     "consistent_values": ";".join(v["consistent"]), "noisy_values": ";".join(v["noisy"]),
                     "example": examples.get((inp, g, name), "")})
    return rows


def level_tables(records, probe_root, kind, skipped=None):
    """Wide rows: one per ladder or situation level, the analysis and board grids by row name. A level whose
    snapshot's MSAA walk was truncated is left out and counted in skipped['truncated'] (a dict, when given)."""
    skipped = {} if skipped is None else skipped
    skipped.setdefault("truncated", 0)
    idx = {}
    for root, _, fns in os.walk(probe_root):
        if os.path.basename(root) != kind:
            continue
        for fn in fns:
            if fn.endswith(".json"):
                p = os.path.join(root, fn)
                if fn not in idx or os.path.getmtime(p) > os.path.getmtime(idx[fn]):
                    idx[fn] = p
    rows = []
    for r in records:
        target = r["Input"].split("/", 1)[1]
        stem = re.sub(r"[^\w.-]", "_", f"{target}-{r['Value']}") if kind == "situation" else \
            re.sub(r"[^\w.-]", "_", target) + "-" + re.sub(r"[^\w.-]", "_", str(r["Value"]))
        fn = stem + ("-a.json" if kind == "situation" else ".json")
        if fn not in idx:
            continue
        g = grid_of(idx[fn])
        if g is None:
            skipped["truncated"] += 1
            continue
        row = OrderedDict([("input", r["Input"]), ("level", r["Value"]), ("readback", r.get("ReadBack"))])
        for gk in ("analysis", "board"):
            for name, val in g.get(gk, {}).items():
                row[f"{gk}:{name}"] = val
        rows.append(row)
    return rows


def write_wide(path, rows):
    cols = []
    for r in rows:
        for k in r:
            if k not in cols:
                cols.append(k)
    write_csv(path, rows, cols)


def write_csv(path, rows, cols):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, cols, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)


def markdown(effects, inputs, curves):
    lines = ["| Input | Mode / tab | Kind | Took value | Outputs moved | Moved (owner: items) |", "|---|---|---|---|---|---|"]
    eff = defaultdict(lambda: defaultdict(list))
    for e in effects:
        if e["class"] == "effect":
            # Relabelled rows (Name changes, keyed by position) are counted, not listed; pixels are 'image'.
            item = "image" if e["channel"] == "image" else ("#relabelled" if str(e["item"]).startswith("#") else (e["item"] or e["field"]))
            eff[e["input"]][e["owner"]].append(item)
    for i in inputs:
        moved = "; ".join(f'{o}: {", ".join(sorted(set(v))[:8])}{" ..." if len(set(v)) > 8 else ""}'
                          for o, v in eff[i["input"]].items()) or "nothing (beyond itself)"
        took = f'{i["took_value"]}/{i["trials"]}'
        lines.append(f'| `{i["input"]}` {i["label"]} | {i["mode"]} / {i["tab"]} | {i["kind"]} | {took} | '
                     f'{i["outputs_moved"]} | {moved.replace("|", "/")} |')
    noisy = sum(1 for e in effects if e["class"] == "noisy")
    lines += ["", f"Noisy (seen in one repeat only, not counted): {noisy}. Curve rows: {len(curves)}."]
    return "\n".join(lines) + "\n"


def main(sweep, out):
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(sweep, "state.json"), encoding="utf-8-sig") as f:
        manifest = as_list(json.load(f).get("Manifest"))
    effects, inputs = analyse(manifest, load_jsonl(os.path.join(sweep, "trials.jsonl")))
    curves = curve_rows(load_jsonl(os.path.join(sweep, "curves.jsonl")))
    write_csv(os.path.join(out, "effects.csv"), effects, ["input", "label", "class", "channel", "owner", "item", "field",
                                                          "consistent_values", "noisy_values", "examples"])
    write_csv(os.path.join(out, "inputs.csv"), inputs, ["input", "label", "mode", "kind", "tab", "apply", "base", "values",
                                                        "trials", "took_value", "restored_exactly", "outputs_moved", "errors"])
    write_csv(os.path.join(out, "curves.csv"), curves, ["input", "base", "level", "readback", "output", "from", "to",
                                                        "from_num", "to_num"])
    root = os.path.dirname(os.path.abspath(sweep))
    skipped = {}
    gfx = grid_effects(load_jsonl(os.path.join(sweep, "trials.jsonl")), root, skipped)
    write_csv(os.path.join(out, "grid_effects.csv"), gfx, ["input", "grid", "row", "class", "consistent_values", "noisy_values", "example"])
    write_wide(os.path.join(out, "situation_grid.csv"), level_tables(load_jsonl(os.path.join(sweep, "situation.jsonl")), root, "situation", skipped))
    write_wide(os.path.join(out, "curves_grid.csv"), level_tables(load_jsonl(os.path.join(sweep, "curves.jsonl")), root, "curves", skipped))
    with open(os.path.join(out, "matrix.md"), "w", encoding="utf-8") as f:
        f.write(markdown(effects, inputs, curves))
        g = defaultdict(lambda: defaultdict(list))
        for r in gfx:
            if r["class"] == "effect" and r["row"] != "#rows":
                g[r["input"]][r["grid"]].append(r["row"])
        f.write("\n## Property-grid rows moved, by row name (both repeats)\n\n| Input | Grid: rows |\n|---|---|\n")
        for inp, gs in g.items():
            f.write(f'| `{inp}` | ' + "; ".join(f'{k} ({len(v)}): ' + ", ".join(sorted(v)) for k, v in gs.items()) + " |\n")
        # Counted, never silent (S17): a lost repeat turns a consistent row into a noisy one.
        f.write(f"\nLeft out of the property-grid tables: {skipped['truncated']} snapshots with a truncated MSAA walk, "
                f"{skipped['unmatched']} Map trials with no before/after snapshot pair of their own.\n")
    print(json.dumps({"inputs": len(inputs), "effects": sum(e["class"] == "effect" for e in effects), "grid_effects": sum(r["class"] == "effect" for r in gfx),
                      "noisy": sum(e["class"] == "noisy" for e in effects), "curve_rows": len(curves),
                      "skipped_truncated": skipped["truncated"], "skipped_unmatched": skipped["unmatched"]}))


def self_test():
    man = [{"Id": "D/TextBox_speed_ms", "Label": "flow ms", "Mode": "D", "Kind": "numeric", "Values": ["11", "9"]},
           {"Id": "S/x", "Label": "x", "Mode": "S", "Kind": "numeric", "Values": ["1"]}]
    ch = lambda item, to, scope=False, field="Value": {"Ch": "msaa", "Owner": "G", "Item": item, "Field": field,
                                                        "From": "10", "To": to, "InScope": scope}
    trials = [
        {"Input": "D/TextBox_speed_ms", "Value": "11", "Rep": 1, "TookValue": True, "RestoreExact": True,
         "Changes": [ch("Vitesse", "11"), ch("cpu", "3"), ch("box", "11", True)]},
        {"Input": "D/TextBox_speed_ms", "Value": "11", "Rep": 2, "TookValue": True, "RestoreExact": True,
         "Changes": [ch("Vitesse", "11"), ch("box", "11", True), ch("G", "1,2,3,4", field="Rect")]},
        {"Input": "D/TextBox_speed_ms", "Value": "9", "Rep": 1, "Changes": ch("Vitesse", "9")},  # one change, not a list
        {"Input": "S/x", "Value": "1", "Rep": 1, "Error": "boom"},
    ]
    eff, inp = analyse(man, trials)
    cls = {(e["input"], e["item"]): e["class"] for e in eff}
    assert cls[("D/TextBox_speed_ms", "Vitesse")] == "effect", cls
    assert cls[("D/TextBox_speed_ms", "cpu")] == "noisy", cls
    assert cls[("D/TextBox_speed_ms", "box")] == "self", cls
    assert cls[("D/TextBox_speed_ms", "G")] == "layout", cls
    speed = next(i for i in inp if i["input"] == "D/TextBox_speed_ms")
    assert speed["outputs_moved"] == 1 and speed["trials"] == 3 and speed["took_value"] == 2, speed
    assert next(i for i in inp if i["input"] == "S/x")["errors"] == "boom"
    assert numbers("Relative speed:10 m/s, Attack:4.3°") == [10.0, 4.3]
    assert numbers("40,69 Liters") == [40.69]
    rows = curve_rows([{"Input": "D/TextBox_speed_ms", "Base": "10", "Value": "15", "Changes": [ch("Vitesse", "15")]}])
    assert rows[0]["to_num"] == 15.0 and rows[0]["from_num"] == 10.0, rows
    assert "Vitesse" in markdown(eff, inp, rows)
    img = lambda box: {"Ch": "image", "Owner": "Chart1", "Item": box, "Field": "pixels"}
    eff2, _ = analyse(man[:1], [{"Input": "D/TextBox_speed_ms", "Value": "11", "Rep": 1, "Changes": [img("0,0,32,32")]},
                                 {"Input": "D/TextBox_speed_ms", "Value": "11", "Rep": 2, "Changes": [img("0,32,32,32")]}])
    assert [e["class"] for e in eff2] == ["effect"], eff2  # one effect, though the boxes moved
    cell = lambda h, n, v: {"Role": "29", "Hwnd": h, "Name": n, "Value": v, "Hidden": False}
    b = gridvals([cell(1, "Fx_friction_n", "260"), cell(1, "Fx_planing", "29"), cell(2, "Ra_micron", "0"), cell(2, "Ra_micron", "5")])
    assert set(b) == {"analysis", "board"} and b["board"] == {"Ra_micron": "0", "Ra_micron#2": "5"}, b
    # re-laid rows: same names in a new order are not changes; a value change is
    a = gridvals([cell(9, "Fx_planing", "29"), cell(9, "Fx_friction_n", "445"), cell(8, "Ra_micron", "0"), cell(8, "Ra_micron", "5")])
    assert griddiff(b, a) == [("analysis", "Fx_friction_n", "260", "445")], griddiff(b, a)
    # S18: output rows come out in key order, whatever the hash seed (9 keys: 1 in 362,880 by chance)
    many = [ch(f"k{i}", "1") for i in (7, 3, 9, 1, 8, 2, 6, 4, 5)]
    eff3, _ = analyse(man[:1], [{"Input": "D/TextBox_speed_ms", "Value": "11", "Rep": r, "Changes": many} for r in (1, 2)])
    assert [e["item"] for e in eff3] == [f"k{i}" for i in range(1, 10)], [e["item"] for e in eff3]
    # W6: the S and D trials of one designer name, value and rep share a file name apart from the sequence;
    # each is scored from the snapshots written inside its OWN time window, never from the newer trial's
    import tempfile
    snap = lambda v, trunc=False: {"MsaaTruncated": trunc, "Msaa": [cell(1, "Fx_friction_n", v)]}
    iso = lambda ts: datetime.fromtimestamp(ts).astimezone().isoformat()
    with tempfile.TemporaryDirectory() as d:
        tr = os.path.join(d, "205936-Sweep-Map", "trials")
        os.makedirs(tr)

        def put(name, obj, when, sub=tr):
            p = os.path.join(sub, name)
            with open(p, "w", encoding="utf-8") as f:
                json.dump(obj, f)
            os.utime(p, (when, when))
        s0, d0 = 1_000_000.0, 1_005_000.0
        for rep in (1, 2):
            put(f"00{rep}0-len-2024-r{rep}-b.json", snap("100"), s0 + rep * 10)
            put(f"00{rep}0-len-2024-r{rep}-a.json", snap("110"), s0 + rep * 10 + 1)
            put(f"01{rep}0-len-2024-r{rep}-b.json", snap("200"), d0 + rep * 10)
            put(f"01{rep}0-len-2024-r{rep}-a.json", snap("260"), d0 + rep * 10 + 1)
        trials = [{"Input": f"{mode}/len", "Target": "len", "Value": "2024", "Rep": rep, "Started": iso(t0 + rep * 10 - 0.5), "ElapsedMs": 3000}
                  for mode, t0 in (("S", s0), ("D", d0)) for rep in (1, 2)]
        sk = {}
        rows = grid_effects(trials, d, sk)
        assert {r["input"]: r["example"] for r in rows} == {"S/len": "2024: 100 -> 110", "D/len": "2024: 200 -> 260"}, rows
        assert all(r["class"] == "effect" for r in rows) and sk == {"truncated": 0, "unmatched": 0}, (rows, sk)
        # a trial with no snapshot inside its window, or with no window when two trials share the name, is
        # counted as unmatched, never scored from someone else's snapshots
        sk = {}
        grid_effects([dict(trials[0], Started=iso(2_000_000.0)), {k: v for k, v in trials[0].items() if k != "Started"}], d, sk)
        assert sk == {"truncated": 0, "unmatched": 2}, sk
        # S17/S21: a truncated walk is left out and COUNTED; the lost repeat makes the S row noisy, not an effect
        put("0010-len-2024-r1-b.json", snap("100", trunc=True), s0 + 10)
        sk = {}
        rows = grid_effects(trials, d, sk)
        assert sk == {"truncated": 1, "unmatched": 0}, sk
        assert [r["class"] for r in rows if r["input"] == "S/len"] == ["noisy"], rows
        cv = os.path.join(d, "211243-Sweep-Curve", "curves")
        os.makedirs(cv)
        put("len-2100.json", snap("300", trunc=True), s0, cv)
        put("len-1900.json", snap("250"), s0, cv)
        sk = {}
        lv = level_tables([{"Input": "S/len", "Value": "2100"}, {"Input": "S/len", "Value": "1900"}], d, "curves", sk)
        assert [r["level"] for r in lv] == ["1900"] and lv[0]["analysis:Fx_friction_n"] == "250" and sk == {"truncated": 1}, (lv, sk)
    print("swd_sweep_matrix self-test: ok")


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["--self-test"]:
        self_test()
    elif len(a) == 2:
        main(a[0], a[1])
    else:
        raise SystemExit(__doc__)
