"""Read-only UIA3 + MSAA census of SWD's main window, for the input sweep (swd_probe.ps1 -Probe Sweep).

Grown from the T3 probe dumper (%LOCALAPPDATA%\\swd-probe\\2026-09-30\\t3_uia3_dump.py). It adds what the
sweep needs to address a control across a relaunch: the native window handle (the join key to swd_msg.ps1's
Win32 map) and the designer name (AutomationId, stable across launches, unlike the handle), plus the
RangeValue, ExpandCollapse and LegacyIAccessible default-action reads that tell an input from a readout.

READ-ONLY. Only Current* property getters are called. No pattern METHOD (Invoke, Toggle, Select, SetValue,
Expand, DoDefaultAction) appears in this file; every actuation lives in swd_probe.ps1, behind its allowlist,
denylist and board guard.

Usage:  py -3.14 swd_uia3.py dump <out.json> [--pid N]      (SWD must be running, same integrity)
        py -3.14 swd_uia3.py --self-test
"""
import ctypes
import ctypes.wintypes as wt
import json
import os
import sys
import time

CT = {50000: "Button", 50002: "CheckBox", 50003: "ComboBox", 50004: "Edit", 50006: "Image", 50007: "ListItem",
      50008: "List", 50009: "Menu", 50010: "MenuBar", 50011: "MenuItem", 50013: "RadioButton", 50014: "ScrollBar",
      50015: "Slider", 50016: "Spinner", 50017: "StatusBar", 50018: "Tab", 50019: "TabItem", 50020: "Text",
      50021: "ToolBar", 50023: "Tree", 50024: "TreeItem", 50025: "Custom", 50026: "Group", 50027: "Thumb",
      50028: "DataGrid", 50029: "DataItem", 50031: "SplitButton", 50032: "Window", 50033: "Pane", 50034: "Header",
      50035: "HeaderItem", 50036: "Table", 50037: "TitleBar", 50038: "Separator"}
ROLE = {10: "client", 42: "text", 43: "pushbutton", 44: "checkbutton", 45: "radiobutton", 37: "pagetab",
        60: "pagetablist", 35: "outline", 36: "outlineitem", 28: "row", 29: "cell", 12: "menuitem", 46: "combobox",
        51: "slider", 52: "spinbutton", 20: "grouping", 33: "list", 34: "listitem", 41: "statictext", 9: "window",
        16: "pane", 24: "table", 25: "columnheader", 22: "toolbar", 57: "buttondropdown", 62: "splitbutton"}
MAIN_TITLE = "FYN Shaper Wave Dynamics"


def find_main(pid=None):
    """(pid, hwnd) of the single visible top-level window titled like the SWD main form.

    By title, not Process.MainWindowHandle, which returned a dialog's handle mid-run (LIVE-RUN-FINDINGS)."""
    u = ctypes.windll.user32
    found = []

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def cb(h, _):
        p = wt.DWORD()
        u.GetWindowThreadProcessId(h, ctypes.byref(p))
        if (pid is None or p.value == pid) and u.IsWindowVisible(h):
            buf = ctypes.create_unicode_buffer(512)
            u.GetWindowTextW(h, buf, 512)
            if buf.value.startswith(MAIN_TITLE):
                found.append((p.value, h))
        return True

    u.EnumWindows(cb, 0)
    if len(found) != 1:
        raise SystemExit(f"expected exactly one SWD main window, found {len(found)}")
    return found[0]


def classify(r):
    """What the sweep may do with an element: 'input:<kind>', 'button', 'tab', 'treeitem', 'gridrow' or ''.

    Pure, so the self-test pins it. Kinds follow the control, not the label: a NumericUpDown is addressed
    through its EDIT (SpinnerOf set by link_parts), a trackbar is a slider, a WinForms CheckBox/RadioButton is
    a toggle. The spinner shells and a combo's own EDIT are never inputs in their own right."""
    t, cls = r.get("Type"), r.get("Class", "")
    if not r.get("Enabled") or r.get("PartOf"):
        return ""
    if t == "Edit" and r.get("SpinnerOf"):
        return "input:numeric"
    if t == "Edit" and r.get("ReadOnly") is False:
        return "input:text"
    if t == "Spinner":
        return ""
    if t == "Slider" or "trackbar" in cls.lower():
        return "input:slider"
    if t == "ComboBox":
        return "input:combo"
    if t in ("CheckBox", "RadioButton"):
        return "input:toggle"
    if t == "Button":
        return "button"
    if t == "TabItem" or r.get("MsaaRole") == "pagetab":
        return "tab"
    if t == "TreeItem" or r.get("MsaaRole") == "outlineitem":
        return "treeitem"
    if r.get("MsaaRole") in ("row", "cell") and r.get("MsaaName"):
        return "gridrow"
    return ""


def link_parts(rows):
    """Tie composite WinForms controls together, in place (pure; rows in walk order, each with 'Path').

    A NumericUpDown is a named Spinner holding an unnamed inner Spinner (the arrows) and, as a SIBLING of
    that, the EDIT that takes text. The EDIT is the first Edit under the named spinner's path; it gets
    SpinnerOf (the designer name) and the spinner's range. A ComboBox's inner EDIT just echoes the combo,
    so it is marked PartOf and never swept twice."""
    named = lambda r: (r.get("AutomationId") or "") and not str(r.get("AutomationId")).isdigit()
    for i, r in enumerate(rows):
        if r.get("Type") == "Spinner" and named(r):
            for c in rows[i + 1:]:
                if not (str(c.get("Parents", "")) + "/").startswith(r["Path"] + "/"):
                    break
                if c.get("Type") == "Edit":
                    c["SpinnerOf"] = r["AutomationId"]
                    if "Range" in r:
                        c["SpinnerRange"] = r["Range"]
                    break
        if r.get("Type") == "ComboBox":
            for c in rows[i + 1:]:
                if not (str(c.get("Parents", "")) + "/").startswith(r["Path"] + "/"):
                    break
                if c.get("Type") == "Edit":
                    c["PartOf"] = r.get("AutomationId") or "ComboBox"


def write_json_atomic(path, doc):
    """Write doc as JSON beside path, then swap it in (pure apart from the file). swd_probe.ps1 reuses a
    census file for as long as its SWD process lives, so one cut short by a killed run would fail every
    later chunk until deleted by hand; a crash now leaves the previous file whole (SQA 2026-10-06, W5)."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False)
    os.replace(tmp, path)


def dump(out_path, pid=None):
    import comtypes.client
    comtypes.client.GetModule("UIAutomationCore.dll")
    from comtypes.gen import UIAutomationClient as U

    pid, hwnd = find_main(pid)
    uia = comtypes.client.CreateObject(U.CUIAutomation, interface=U.IUIAutomation)
    root = uia.ElementFromHandle(hwnd)
    walker = uia.RawViewWalker

    def pat(el, pid_, iface):
        try:
            p = el.GetCurrentPattern(pid_)
            return p.QueryInterface(iface) if p else None
        except Exception:
            return None

    rows, t0, stack = [], time.perf_counter(), [(root, 0, "", "")]
    truncated = False
    while stack:
        if time.perf_counter() - t0 > 120 or len(rows) > 8000:
            truncated = True
            break
        el, depth, ppath, ptabs = stack.pop()
        # TabPath: every tab page above the element, outermost first, '|'-joined; Tab: the innermost.
        r = {"Depth": depth, "Parents": ppath, "TabPath": ptabs, "Tab": ptabs.split("|")[-1] if ptabs else ""}
        try:
            r["Type"] = CT.get(el.CurrentControlType, el.CurrentControlType)
            r["Name"] = (el.CurrentName or "")[:200]
            r["AutomationId"] = el.CurrentAutomationId or ""
            r["Class"] = (el.CurrentClassName or "").split(".app.")[0]
            r["Hwnd"] = int(el.CurrentNativeWindowHandle or 0)
            r["Enabled"], r["Offscreen"] = bool(el.CurrentIsEnabled), bool(el.CurrentIsOffscreen)
            b = el.CurrentBoundingRectangle
            r["Rect"] = [b.left, b.top, b.right - b.left, b.bottom - b.top]
            v = pat(el, 10002, U.IUIAutomationValuePattern)
            if v:
                r["Value"], r["ReadOnly"] = (v.CurrentValue or "")[:200], bool(v.CurrentIsReadOnly)
            rv = pat(el, 10003, U.IUIAutomationRangeValuePattern)
            if rv:
                r["Range"] = {"Value": rv.CurrentValue, "Min": rv.CurrentMinimum, "Max": rv.CurrentMaximum,
                              "Small": rv.CurrentSmallChange, "Large": rv.CurrentLargeChange,
                              "ReadOnly": bool(rv.CurrentIsReadOnly)}
            t = pat(el, 10015, U.IUIAutomationTogglePattern)
            if t:
                r["Toggle"] = t.CurrentToggleState
            s = pat(el, 10010, U.IUIAutomationSelectionItemPattern)
            if s:
                r["Selected"] = bool(s.CurrentIsSelected)
            ec = pat(el, 10005, U.IUIAutomationExpandCollapsePattern)
            if ec:
                r["Expand"] = ec.CurrentExpandCollapseState
            la = pat(el, 10018, U.IUIAutomationLegacyIAccessiblePattern)
            if la:
                r["MsaaRole"] = ROLE.get(la.CurrentRole, la.CurrentRole)
                r["MsaaName"] = (la.CurrentName or "")[:200]
                r["MsaaValue"] = (la.CurrentValue or "")[:200]
                r["MsaaState"] = la.CurrentState
                r["MsaaDefaultAction"] = (la.CurrentDefaultAction or "")[:60]
        except Exception as e:  # a dead element mid-walk: recorded, never dropped
            r["Type"] = "ERROR"
            r["Name"] = str(e)[:200]
        rows.append(r)
        aid = r.get("AutomationId") or ""
        here = ppath + "/" + (aid if aid and not aid.isdigit() else (r.get("Type") or "?"))
        r["Path"] = here
        tabs = ptabs
        # A TabPage pane carries its tab's caption as Name (measured: AutomationId 'TabPage...');
        # its descendants inherit it.
        if r.get("Type") == "Pane" and r.get("Class", "").startswith("WindowsForms10.Window") and r.get("Name") \
                and aid.startswith("TabPage"):
            tabs = (ptabs + "|" if ptabs else "") + r["Name"]
        kids, ch = [], None
        try:
            ch = walker.GetFirstChildElement(el)
            while ch:
                kids.append(ch)
                ch = walker.GetNextSiblingElement(ch)
        except Exception:
            pass
        stack.extend((k, depth + 1, here, tabs) for k in reversed(kids))

    link_parts(rows)
    for r in rows:
        r["Kind"] = classify(r)
    doc = {"pid": pid, "hwnd": hwnd, "elements": len(rows), "seconds": round(time.perf_counter() - t0, 1),
           "truncated": truncated, "rows": rows}
    write_json_atomic(out_path, doc)
    kinds = {}
    for r in rows:
        if r["Kind"]:
            kinds[r["Kind"]] = kinds.get(r["Kind"], 0) + 1
    print(json.dumps({"elements": len(rows), "seconds": doc["seconds"], "truncated": truncated, "kinds": kinds}))


def self_test():
    assert classify({"Type": "Edit", "Enabled": True, "ReadOnly": False}) == "input:text"
    assert classify({"Type": "Edit", "Enabled": True, "ReadOnly": False, "SpinnerOf": "NumericUpDown_toe_deg"}) == "input:numeric"
    assert classify({"Type": "Edit", "Enabled": True, "ReadOnly": False, "PartOf": "ComboBox_tail_bevel"}) == ""
    assert classify({"Type": "Spinner", "Enabled": True}) == ""
    assert classify({"Type": "Edit", "Enabled": True, "ReadOnly": True}) == ""
    # The measured Fins-tab shape: named spinner > unnamed inner spinner > Up/Down, then the EDIT as the
    # inner spinner's SIBLING. A sibling spinner whose name extends this one's must not steal its EDIT.
    rows = [
        {"Type": "Spinner", "AutomationId": "NumericUpDown_toe_deg", "Parents": "/G", "Path": "/G/NumericUpDown_toe_deg",
         "Range": {"Min": -10, "Max": 10}},
        {"Type": "Spinner", "AutomationId": "1052608", "Parents": "/G/NumericUpDown_toe_deg", "Path": "/G/NumericUpDown_toe_deg/Spinner"},
        {"Type": "Button", "AutomationId": "", "Parents": "/G/NumericUpDown_toe_deg/Spinner", "Path": "/G/NumericUpDown_toe_deg/Spinner/Button"},
        {"Type": "Edit", "AutomationId": "8521994", "Parents": "/G/NumericUpDown_toe_deg", "Path": "/G/NumericUpDown_toe_deg/Edit"},
        {"Type": "Spinner", "AutomationId": "NumericUpDown_toe_deg2", "Parents": "/G", "Path": "/G/NumericUpDown_toe_deg2"},
        {"Type": "Edit", "AutomationId": "999", "Parents": "/G/NumericUpDown_toe_deg2", "Path": "/G/NumericUpDown_toe_deg2/Edit"},
        {"Type": "ComboBox", "AutomationId": "ComboBox_tail_bevel", "Parents": "/G", "Path": "/G/ComboBox_tail_bevel"},
        {"Type": "Edit", "AutomationId": "1001", "Parents": "/G/ComboBox_tail_bevel", "Path": "/G/ComboBox_tail_bevel/Edit"},
    ]
    link_parts(rows)
    assert rows[3]["SpinnerOf"] == "NumericUpDown_toe_deg" and rows[3]["SpinnerRange"]["Max"] == 10, rows[3]
    assert rows[5]["SpinnerOf"] == "NumericUpDown_toe_deg2", rows[5]
    assert rows[7]["PartOf"] == "ComboBox_tail_bevel", rows[7]
    assert classify({"Type": "Edit", "Enabled": False, "ReadOnly": False}) == ""
    assert classify({"Type": "Slider", "Enabled": True, "Class": "WindowsForms10.msctls_trackbar32"}) == "input:slider"
    assert classify({"Type": "ComboBox", "Enabled": True}) == "input:combo"
    assert classify({"Type": "RadioButton", "Enabled": True}) == "input:toggle"
    assert classify({"Type": "Button", "Enabled": True}) == "button"
    assert classify({"Type": "Custom", "Enabled": True, "MsaaRole": "row", "MsaaName": "Ra_micron"}) == "gridrow"
    assert classify({"Type": "Custom", "Enabled": True, "MsaaRole": "row", "MsaaName": ""}) == ""
    # A census write that fails part-way leaves the previous file whole and parseable (W5)
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "census-4243-view.json")
        write_json_atomic(p, {"rows": [{"Name": "café"}]})
        write_json_atomic(p, {"rows": [{"Name": "b"}]})
        with open(p, encoding="utf-8") as f:
            assert json.load(f) == {"rows": [{"Name": "b"}]}
        assert not os.path.exists(p + ".tmp")
        try:
            write_json_atomic(p, {"rows": [{"Name": "c"}, object()]})  # fails mid-dump
        except TypeError:
            pass
        with open(p, encoding="utf-8") as f:
            assert json.load(f) == {"rows": [{"Name": "b"}]}, "a failed write must leave the old census whole"
    print("swd_uia3 self-test: ok")


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["--self-test"]:
        self_test()
    elif a[:1] == ["dump"] and len(a) >= 2:
        dump(a[1], int(a[a.index("--pid") + 1]) if "--pid" in a else None)
    else:
        raise SystemExit(__doc__)
