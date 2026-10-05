<#
.SYNOPSIS
    Stage 2/3 automation probes for SWD: snapshot, act, settle, snapshot, diff, classify.
.DESCRIPTION
    The probe harness behind SWD/docs/plans/SWD-AUTOMATION-PROBES.md (T9, T11-T14, T17).
    It measures whether the techniques an evening "fiddling" rig would rest on actually
    hold on SWD. It is NOT the rig: every probe is short, supervised and self-reverting.

    WHAT IT ADDS to the existing, SQA'd layers it dot-sources:
      swd_msg.ps1       Win32 map, WM_SETTEXT write + read-back, BM_CLICK, PrintWindow
      swd_geometry.ps1  Set-SwdGeometry: write a box, press Apply, report every delta
    and, new here:
      MSAA reader       IAccessible walk (oleacc). Stage 1 measured that MSAA reaches what
                        Win32 cannot: the analysis grid (yaw moment included), checkbox
                        state, tab items. The managed UIA client does not.
      frame hash        PrintWindow into memory, measured noise rectangles zeroed, MD5.
      settle detector   WM_NULL round trip + SWD CPU below a threshold + K identical frames.
      snapshot/diff     Win32 + MSAA + image, classified in-scope / out-of-scope, with a
                        volatility set learned from a null action (the negative control).
      kill switch       a STOP file in the log root, or the cursor parked in the top-left
                        corner, stops the run at the next step boundary.

    SAFETY INVARIANTS (do not depend on any review):
      - Only buttons on an explicit ALLOWLIST can be clicked, and the text is re-read and
        checked against a DENYLIST (scan, delete, remove, unlock, save, export, import,
        share, rename, create, duplicate, reset, upload, CNC, overwrite, licence; English
        and French) immediately before every click.
      - Only tabs on an allowlist can be selected.
      - The loaded board's name must contain '_Copy'. Originals are refused.
      - Logs go only where swd_msg.ps1's path guard allows (never the install or library).
      - The SWD library is hashed before and after every run (SWD's own temp\ excluded);
        any other change is reported as LIBRARY CHANGED.
      - Every geometry probe restores the value it started from.

    REVIEW STATUS: written 2026-09-30 and RUN LIVE BEFORE ITS SQA PASS at Benjamin's
    explicit instruction (AI-USE.md section 4, 2026-09-30), overriding CLAUDE.md section 4
    for this file only. One SQA pass ran 2026-10-01 (Critical=0). The input sweep
    (-Probe Sweep, added 2026-10-01 for an overnight run under the same override) has had
    no SQA pass yet; it is owed. The live-solver passes (-Pass SolverPilot | SolverLoop |
    SolverRestore, 2026-10-05) were added and run the same night at Benjamin's instruction,
    with their SQA pass to follow the run.

    Windows PowerShell 5.1, elevated (SWD runs at High integrity; AI-USE.md E16/E17).
.PARAMETER Probe
    Snapshot | T9 | T11 | T12 | T13 | T14 | T17 | Sweep. Omit to dot-source the functions only.
.PARAMETER DeltaMm
    Length change used by T12-T14. Always restored afterwards.
.PARAMETER Repeats
    T13 click count.
.PARAMETER LogDir
    Overrides %LOCALAPPDATA%\swd-probe\<yyyy-MM-dd>. Validated by the path guard.
.PARAMETER SkipLibraryHash
    Skip the before/after library hash (about 2 s each). Not recommended.
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File swd_probe.ps1 -Probe T14
#>
[CmdletBinding()]
param(
    [ValidateSet('', 'Snapshot', 'T9', 'T11', 'T12', 'T13', 'T14', 'T17', 'Sweep')]
    [string]$Probe = '',
    [ValidateRange(0.1, 50)][double]$DeltaMm = 1.0,
    [ValidateRange(1, 50)][int]$Repeats = 5,
    [string]$LogDir,
    [switch]$SkipLibraryHash,
    # Sweep only: which pass this chunk runs, its time budget, and where state lives
    # (default <LogDir>\sweep). Run chunk after chunk; each resumes from state.json.
    [ValidateSet('Census', 'Map', 'Situation', 'Curve', 'SolverPilot', 'SolverLoop', 'SolverRestore')][string]$Pass = 'Map',
    [ValidateRange(1, 9)][double]$MaxMinutes = 8,
    [string]$SweepDir,
    # Solver passes only (2026-10-05; default state dir <LogDir>\solver): the loop's levels
    # ('5,10,20' is accepted as one argument), its drift range, and the board volume guard
    # (0 = record the volume, do not check it).
    [string[]]$Speeds = @('5', '10', '20'),
    [string[]]$Slopes = @('-3', '0', '3'),
    [ValidateRange(0, 90)][double]$MaxDrift = 20,
    [ValidateRange(0, 1000)][double]$ExpectVolumeL = 0
)

Set-StrictMode -Version Latest
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Windows PowerShell 5.1 required (BinaryFormatter-era tooling).' }
# $PSScriptRoot is empty inside param() defaults under [CmdletBinding()] on 5.1
# (measured trap, swd_diagnose.ps1), so it is resolved here.
$script:ProbeRoot = $PSScriptRoot
if (-not $script:ProbeRoot) { $script:ProbeRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not (Get-Command Get-SwdControl -ErrorAction SilentlyContinue)) { . (Join-Path $script:ProbeRoot 'swd_msg.ps1') }
if (-not (Get-Command Set-SwdGeometry -ErrorAction SilentlyContinue)) { . (Join-Path $script:ProbeRoot 'swd_geometry.ps1') }

# ---------------------------------------------------------------------------------------
# Measured constants (2026-09-30, Stage 1, laptop panel at 175%, SWD maximised)
# ---------------------------------------------------------------------------------------

# Buttons a probe may click. Exact, after trimming and removing '&' accelerators.
$script:ProbeAllowedButtons = @('Apply Length', 'Apply Width', 'Apply Volume', 'Apply situation')
# Captions allowed by anchored pattern, checked only after the denylist. Writing the volume
# box renames 'Apply Volume' to 'Set N liters volume to board' and nothing renames it back
# (T9, 2026-09-30); swd_geometry.ps1 already resolves that caption. Bare 'Apply' stays refused.
$script:ProbeAllowedButtonPatterns = @('^Set [0-9]+(?:[.,][0-9]+)? liters volume to board$')
# Tabs a probe may select (by TCM_SETCURFOCUS; the MSAA walk only finds them).
# 2026-10-01 sweep: Test Position, Elements;analysis and Dashboard exist only with Board Dynamics
# ON (measured); Spoon is a Shape sub-tab. Names as ConvertTo-SwdProbeLabel normalises them (';' -> ' ').
$script:ProbeAllowedTabs = @('Shape', 'Fins', 'SizeConfig', 'Outline', 'Rockers', 'Guides Sections',
                             'Test Position', 'Spoon', 'Elements analysis', 'Dashboard')
# Defence in depth: refused even if someone widens the allowlist. Matched against the
# NORMALISED label (ConvertTo-SwdProbeLabel), culture-invariantly. 'scan' is bare, so
# 'Rescan', 'Hydro-Scan' and 'Lancer le scan' are refused as well as 'Hydrodynamics Scanner'.
# overwrite / ecraser / licence (S3, SQA 2026-10-06): a lone OK on an overwrite or licence notice was
# acknowledged as an information box, because nothing it said was on this list.
$script:ProbeDenyPattern = '(?i)scan|delete|supprim|effac|remove|unlock|d[e\u00e9]verrouill|save|enregistr|sauvegard|export|import|share|partag|rename|renomm|create|cr[e\u00e9]er|sous-dossier|duplicat|dupliqu|reset|r[e\u00e9]initialis|upload|cnc|surfcommunity|overwrit|[e\u00e9]cras|licen[cs]'
# Invisible characters removed from a caption before either list is consulted: \p{Cf}, the
# C0/C1 controls other than tab/CR/LF (those become spaces below), and Unicode's
# default-ignorable code points, so one copied unnoticed from an SWD caption cannot split a
# denied word. Listed explicitly because .NET Framework's regex \p{Cf} misses U+00AD (its
# Latin-1 table still classes the soft hyphen as a dash) and cannot match an astral
# character at all (measured).
$script:ProbeInvisiblePattern = '\p{Cf}|[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F\u00ad\u034f\u061c\u115f\u1160\u17b4\u17b5\u180b-\u180f\u200b-\u200f\u202a-\u202e\u2060-\u206f\u3164\ufe00-\ufe0f\ufeff\uffa0\ufff0-\ufff8]|\uD804[\uDCBD\uDCCD]|\uD80D[\uDC30-\uDC3F]|\uD82F[\uDCA0-\uDCA3]|\uD834[\uDD73-\uDD7A]|[\uDB40-\uDB43][\uDC00-\uDFFF]'
# Window-relative rectangles (x, y, w, h) in the 1845x1111 PrintWindow frame that change
# on their own: status-bar CPU and RAM readouts, the UnLock/section-slider block (T5), and
# the title bar, whose colour follows focus (T4c). Zeroed before frame hashing.
$script:ProbeNoiseRects = @(
    @(1504, 864, 224, 224), @(192, 1056, 64, 55), @(352, 1056, 64, 55), @(0, 0, 1845, 32), @(1280, 128, 32, 32)
)
# MSAA names that change with no action (status bar). Extended at run time by the
# volatility a null action reveals (T14 negative control).
$script:ProbeMsaaNoiseLike = @('Cpu:*', 'Available RAM*', 'Os:*')
# MSAA default actions the sweep may take, by exact node name (Invoke-SwdProbeAcc). A ToolStrip
# item's default action is the WinForms PerformClick(), not a synthesised click; the cursor is
# still checked either side, because a TAB's default action turned out to be a real click (T11).
$script:ProbeAccDefaultAllowed = @('Board Dynamics')
$script:ProbeStopFileName = 'STOP'
$script:ProbeLibraryExclude = @('temp\*')

# ---------------------------------------------------------------------------------------
# Native helpers
# ---------------------------------------------------------------------------------------
if (-not ('SwdProbeNative' -as [type])) {
    Add-Type -ReferencedAssemblies 'Accessibility', 'System.Drawing' -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Accessibility;

public static class SwdProbeNative {
  [DllImport("oleacc.dll")]
  private static extern int AccessibleObjectFromWindow(IntPtr hwnd, uint id, ref Guid iid,
      [MarshalAs(UnmanagedType.Interface)] out IAccessible acc);
  [DllImport("oleacc.dll")]
  private static extern int AccessibleChildren([MarshalAs(UnmanagedType.Interface)] IAccessible parent,
      int start, int count, [In, Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 2)] object[] kids,
      out int obtained);
  [DllImport("oleacc.dll")]
  private static extern int WindowFromAccessibleObject([MarshalAs(UnmanagedType.Interface)] IAccessible acc, out IntPtr hwnd);
  [DllImport("user32.dll")] private static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr h, out R r);
  [DllImport("user32.dll")] private static extern bool GetCursorPos(out P p);
  [DllImport("user32.dll", SetLastError = true)]
  private static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint f, uint ms, out IntPtr res);
  [StructLayout(LayoutKind.Sequential)] private struct R { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] private struct P { public int X, Y; }

  private static readonly Guid IID_IAccessible = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");
  private const uint OBJID_CLIENT = 0xFFFFFFFC;

  // Path: index path from the root (for reading a dump; nothing navigates by it).
  // Key: "h<hwnd>:<index path within that window>". Diffs key on this, because creating one
  // tab's controls shifted every sibling's index path and made 1,103 false changes on the
  // first live T11 (2026-09-30). Hidden: the node or an ancestor has STATE_SYSTEM_INVISIBLE.
  public class MsaaNode {
    public string Path; public string Key; public long Hwnd; public int Depth; public string Role; public string Name;
    public string Value; public int State; public bool Simple; public bool Hidden;
  }

  // Set by the last Walk(): true when maxNodes, the deadline or the depth cap cut it short.
  // A truncated walk is reported as such; it is never a complete-looking snapshot.
  public static bool LastWalkTruncated;

  private static IAccessible Root(IntPtr hwnd) {
    IAccessible acc; Guid iid = IID_IAccessible;
    if (AccessibleObjectFromWindow(hwnd, OBJID_CLIENT, ref iid, out acc) != 0) return null;
    return acc;
  }

  public static List<MsaaNode> Walk(IntPtr hwnd, int maxNodes, int deadlineMs) {
    if (hwnd == IntPtr.Zero) throw new ArgumentException("Walk() refuses a NULL window.");
    LastWalkTruncated = false;
    var list = new List<MsaaNode>();
    IAccessible root = Root(hwnd);
    if (root == null) return list;
    Recurse(root, "0", 0, hwnd.ToInt64(), "0", false, list, maxNodes, deadlineMs, Stopwatch.StartNew());
    return list;
  }

  private static string S(Func<object> f, int max) {
    try { object o = f(); if (o == null) return null; string s = o.ToString(); return s.Length > max ? s.Substring(0, max) : s; }
    catch { return null; }
  }

  private static MsaaNode Describe(IAccessible acc, object child, string path, int depth, bool simple) {
    var n = new MsaaNode { Path = path, Depth = depth, Simple = simple };
    n.Name = S(() => acc.get_accName(child), 300);
    n.Value = S(() => acc.get_accValue(child), 300);
    n.Role = S(() => acc.get_accRole(child), 40);
    int st = 0; try { object o = acc.get_accState(child); if (o is int) st = (int)o; } catch { }
    n.State = st;
    // A child window's WINDOW object repeats its client's name (the window text), so a
    // renamed button was counted twice (measured live, T9 2026-09-30). The window node
    // keeps only its state, which carries visibility; name and value live on the client.
    if (n.Role == "9") { n.Name = null; n.Value = null; }
    return n;
  }

  // null when the object reports more than 10,000 children: too many to walk, and the walk
  // must then say it was cut short rather than treat the node as a leaf (S4).
  private static object[] Kids(IAccessible acc) {
    int count = 0;
    try { count = acc.accChildCount; } catch { return new object[0]; }
    if (count > 10000) return null;
    if (count <= 0) return new object[0];
    var kids = new object[count]; int got = 0;
    try { if (AccessibleChildren(acc, 0, count, kids, out got) < 0) got = 0; } catch { got = 0; }
    var outp = new object[got]; Array.Copy(kids, outp, got); return outp;
  }

  // A child window's WINDOW object (role 9) lists its parts in the standard proxy's fixed
  // order: 0 system menu, 1 title bar, 2 menu bar, 3 CLIENT, 4 vertical scroll, 5
  // horizontal scroll, 6 grip. The title bar ECHOES the window text, so every edit box
  // appeared twice and every change was double-counted (measured 2026-09-30 on a WinForms
  // TextBox). Indices 0, 1, 2 and 6 are dropped with their subtrees. BY POSITION, NOT BY
  // ROLE: a WinForms MenuStrip's CLIENT also has the menu-bar role, and a role filter would
  // have deleted SWD's Files/Tools menus. Only applied when the object has exactly the
  // standard seven parts; a custom window object is walked whole. The window node itself
  // is kept, because its state carries visibility.
  private static long HwndOf(IAccessible acc) {
    IntPtr h; try { if (WindowFromAccessibleObject(acc, out h) == 0) return h.ToInt64(); } catch { }
    return 0;
  }

  private static void Recurse(IAccessible acc, string path, int depth, long anchor, string rel, bool hiddenAbove,
                              List<MsaaNode> list, int max, int deadline, Stopwatch sw) {
    if (list.Count >= max || sw.ElapsedMilliseconds > deadline || depth > 60) { LastWalkTruncated = true; return; }
    MsaaNode self = Describe(acc, 0, path, depth, false);
    long h = HwndOf(acc);
    if (h != 0 && h != anchor) { anchor = h; rel = "0"; }
    self.Hwnd = anchor; self.Key = "h" + anchor + ":" + rel;
    self.Hidden = hiddenAbove || (self.State & 0x8000) != 0;
    list.Add(self);
    object[] kids = Kids(acc);
    if (kids == null) { LastWalkTruncated = true; kids = new object[0]; }
    bool standardWindow = self.Role == "9" && kids.Length == 7;
    for (int i = 0; i < kids.Length; i++) {
      if (list.Count >= max || sw.ElapsedMilliseconds > deadline) { LastWalkTruncated = true; return; }
      if (standardWindow && (i == 0 || i == 1 || i == 2 || i == 6)) continue;
      string p = path + "/" + i, r = rel + "/" + i;
      IAccessible ka = kids[i] as IAccessible;
      if (ka != null) Recurse(ka, p, depth + 1, anchor, r, self.Hidden, list, max, deadline, sw);
      else if (kids[i] is int) {
        MsaaNode n = Describe(acc, kids[i], p, depth + 1, true);
        n.Hwnd = anchor; n.Key = "h" + anchor + ":" + r; n.Hidden = self.Hidden || (n.State & 0x8000) != 0;
        list.Add(n);
      }
    }
  }

  // The child at POSITION of a window's client object, described like a walk node, or null.
  // Select-SwdProbeTab reads the page tab back after the switch: TCM_GETCURSEL proves an
  // index was selected, not that the index still names the requested tab (S12).
  public static MsaaNode ChildAt(IntPtr hwnd, int position) {
    if (hwnd == IntPtr.Zero) throw new ArgumentException("ChildAt() refuses a NULL window.");
    IAccessible acc = Root(hwnd);
    if (acc == null) return null;
    object[] kids = Kids(acc);
    if (kids == null || position < 0 || position >= kids.Length) return null;
    if (kids[position] is int) return Describe(acc, kids[position], "0/" + position, 1, true);
    IAccessible ka = kids[position] as IAccessible;
    return ka == null ? null : Describe(ka, 0, "0/" + position, 1, false);
  }

  // Tab switch by MESSAGE. TCM_SETCURFOCUS on a tab control without TCS_BUTTONS changes the
  // selection AND sends TCN_SELCHANGING/TCN_SELCHANGE, so WinForms raises SelectedIndexChanged
  // and the app's own handlers run. No cursor movement, works with the window covered.
  // Replaces the MSAA default action, which on a tab SIMULATES A REAL MOUSE CLICK at the tab's
  // screen position: it moved the user's cursor in the first live T11 and clicks whatever
  // window is on top there (measured 2026-09-30). That primitive was deleted, not kept.
  // Returns the tab index selected afterwards (TCM_GETCURSEL), or -1 on timeout.
  public static int SelectTab(IntPtr tabControl, int index) {
    IntPtr res;
    if (SendMessageTimeout(tabControl, 0x1330, new IntPtr(index), IntPtr.Zero, 0x0002, 3000, out res) == IntPtr.Zero) return -1;
    if (SendMessageTimeout(tabControl, 0x130B, IntPtr.Zero, IntPtr.Zero, 0x0002, 3000, out res) == IntPtr.Zero) return -1;
    return res.ToInt32();
  }

  // PrintWindow(PW_RENDERFULLCONTENT) into memory; ignore = flat [x, y, w, h, ...].
  // Returns "WxH:MD5" or null when the capture failed. Never a hash of a failed capture.
  public static string FrameHash(IntPtr hwnd, int[] ignore) {
    R r; if (!GetWindowRect(hwnd, out r)) return null;
    int w = r.Right - r.Left, h = r.Bottom - r.Top;
    if (w <= 0 || h <= 0) return null;
    using (var bmp = new Bitmap(w, h, PixelFormat.Format24bppRgb)) {
      using (var g = Graphics.FromImage(bmp)) {
        IntPtr dc = g.GetHdc(); bool ok;
        try { ok = PrintWindow(hwnd, dc, 2); } finally { g.ReleaseHdc(dc); }
        if (!ok) return null;
      }
      BitmapData d = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
      try {
        byte[] buf = new byte[d.Stride * h];
        Marshal.Copy(d.Scan0, buf, 0, buf.Length);
        if (ignore != null) {
          for (int k = 0; k + 3 < ignore.Length; k += 4) {
            int x0 = Math.Max(0, ignore[k]), y0 = Math.Max(0, ignore[k + 1]);
            int x1 = Math.Min(w, ignore[k] + ignore[k + 2]), y1 = Math.Min(h, ignore[k + 1] + ignore[k + 3]);
            if (x1 <= x0 || y1 <= y0) continue;
            for (int y = y0; y < y1; y++) Array.Clear(buf, y * d.Stride + x0 * 3, (x1 - x0) * 3);
          }
        }
        using (var md5 = MD5.Create()) return w + "x" + h + ":" + BitConverter.ToString(md5.ComputeHash(buf)).Replace("-", "");
      } finally { bmp.UnlockBits(d); }
    }
  }

  // WM_NULL round trip. -1 = timed out or hung (SMTO_ABORTIFHUNG).
  public static int NullRoundTripMs(IntPtr hwnd, uint timeoutMs) {
    var sw = Stopwatch.StartNew(); IntPtr res;
    IntPtr ok = SendMessageTimeout(hwnd, 0, IntPtr.Zero, IntPtr.Zero, 0x0002, timeoutMs, out res);
    return ok == IntPtr.Zero ? -1 : (int)sw.ElapsedMilliseconds;
  }

  public static int[] CursorPos() { P p; return GetCursorPos(out p) ? new[] { p.X, p.Y } : null; }

  // ---- Sweep actuators (2026-10-01). Messages and MSAA only: no cursor, no coordinates. ----
  [DllImport("user32.dll")] private static extern int GetDlgCtrlID(IntPtr h);
  [DllImport("user32.dll")] private static extern IntPtr GetParent(IntPtr h);
  [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] private static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("kernel32.dll")] private static extern uint SetThreadExecutionState(uint flags);

  // SendMessageTimeout(SMTO_ABORTIFHUNG); long.MinValue = not delivered (hung or timed out).
  public static long Send(IntPtr h, uint m, long w, long l, uint ms) {
    IntPtr res;
    if (SendMessageTimeout(h, m, new IntPtr(w), new IntPtr(l), 0x0002, ms, out res) == IntPtr.Zero) return long.MinValue;
    return res.ToInt64();
  }

  // Combo: CB_SETCURSEL changes the selection silently, so the CBN_SELCHANGE that a user's pick
  // would send follows as WM_COMMAND to the parent; WinForms reflects it to the ComboBox, which
  // raises SelectedIndexChanged. Returns CB_GETCURSEL afterwards (-2 / -3: a message was not delivered).
  public static int ComboSelect(IntPtr combo, int index, uint ms) {
    if (Send(combo, 0x014E, index, 0, ms) == long.MinValue) return -2;
    long wp = (1L << 16) | (uint)(GetDlgCtrlID(combo) & 0xFFFF);
    if (Send(GetParent(combo), 0x0111, wp, combo.ToInt64(), ms) == long.MinValue) return -3;
    return ComboIndex(combo, ms);
  }
  public static int ComboIndex(IntPtr combo, uint ms) { long r = Send(combo, 0x0147, 0, 0, ms); return r == long.MinValue ? -2 : (int)r; }
  public static int ComboCount(IntPtr combo, uint ms) { long r = Send(combo, 0x0146, 0, 0, ms); return r == long.MinValue ? -2 : (int)r; }

  // List box, the same way (2026-10-05, the hydroscan drift list): LB_SETCURSEL is silent, so the
  // LBN_SELCHANGE (1) a user's pick sends follows as WM_COMMAND to the parent, which WinForms
  // reflects to the ListBox (SelectedIndexChanged). Returns LB_GETCURSEL afterwards (-2 / -3: a
  // message was not delivered).
  public static int ListSelect(IntPtr list, int index, uint ms) {
    if (Send(list, 0x0186, index, 0, ms) == long.MinValue) return -2;
    long wp = (1L << 16) | (uint)(GetDlgCtrlID(list) & 0xFFFF);
    if (Send(GetParent(list), 0x0111, wp, list.ToInt64(), ms) == long.MinValue) return -3;
    return ListIndex(list, ms);
  }
  public static int ListIndex(IntPtr list, uint ms) { long r = Send(list, 0x0188, 0, 0, ms); return r == long.MinValue ? -2 : (int)r; }
  public static int ListCount(IntPtr list, uint ms) { long r = Send(list, 0x018B, 0, 0, ms); return r == long.MinValue ? -2 : (int)r; }

  // Trackbar: TBM_SETPOS, then the scroll notification a finished drag sends to the parent
  // (WM_HSCROLL, or WM_VSCROLL for TBS_VERT): SB_THUMBPOSITION, then SB_ENDSCROLL. WinForms
  // reflects it to the TrackBar, which re-reads TBM_GETPOS and raises Scroll and ValueChanged.
  // Returns TBM_GETPOS afterwards, or int.MinValue when a message was not delivered.
  public static int TrackSet(IntPtr tb, int pos, uint ms) {
    if (Send(tb, 0x0405, 1, pos, ms) == long.MinValue) return int.MinValue;
    uint msg = (GetWindowLong(tb, -16) & 0x2) != 0 ? 0x0115u : 0x0114u;
    IntPtr parent = GetParent(tb);
    if (Send(parent, msg, ((long)(pos & 0xFFFF) << 16) | 4, tb.ToInt64(), ms) == long.MinValue) return int.MinValue;
    if (Send(parent, msg, 8, tb.ToInt64(), ms) == long.MinValue) return int.MinValue;
    return TrackPos(tb, ms);
  }
  public static int TrackPos(IntPtr tb, uint ms) { long r = Send(tb, 0x0400, 0, 0, ms); return r == long.MinValue ? int.MinValue : (int)r; }
  // [min, max, line size]
  public static int[] TrackRange(IntPtr tb, uint ms) { return new[] { (int)Send(tb, 0x0401, 0, 0, ms), (int)Send(tb, 0x0402, 0, 0, ms), (int)Send(tb, 0x0418, 0, 0, ms) }; }

  // ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED for this thread: no sleep, no display
  // off, no screensaver while a sweep chunk runs. Cleared when the process exits.
  public static uint KeepAwake() { return SetThreadExecutionState(0x80000003); }

  public class ActResult {
    public string Status; public int Matches; public string Name; public string Value; public string Role;
    public int State; public string DefaultAction;
    // Screen rectangle [x, y, w, h] from accLocation, or null when the node has none.
    public int[] Rect;
  }

  // Find the node named NAME exactly (ordinal) under HWND, optionally of ROLE (MSAA role number as
  // a string), and READ it or act on it: "default" = accDoDefaultAction, "select" = accSelect
  // (TAKEFOCUS|TAKESELECTION), "setvalue" = put_accValue. Window objects (role 9) never match: they
  // echo their client's name. Ambiguity is the caller's to resolve: Matches is always reported, and
  // only the NTH hit is touched. Invisible nodes are refused, and so are unavailable ones for actions.
  // Policy (what may be acted on at all) lives in the PowerShell wrapper, Invoke-SwdProbeAcc.
  // The "-tree" actions (read-tree, default-tree, select-tree) are the same three, for a TREE ITEM
  // (role 36) only, and they skip the invisible check: the tree-view proxy marks every item
  // scrolled out of view STATE_SYSTEM_INVISIBLE (measured 2026-10-05: 15 of 88 items visible), and
  // selecting one by TVM_SELECTITEM scrolls it into view. Anything other than a tree item is refused.
  public static ActResult Act(IntPtr hwnd, string name, string role, int nth, string action, string value, int maxNodes, int deadlineMs) {
    if (hwnd == IntPtr.Zero) throw new ArgumentException("Act() refuses a NULL window.");
    var res = new ActResult();
    // Only read, default and select have a tree form; setting a tree item's value is never asked
    // for (Invoke-SwdProbeAcc refuses it), so it is refused here too, before any Find (S6).
    if (action == "setvalue-tree") { res.Status = "bad-action"; return res; }
    bool tree = action != null && action.EndsWith("-tree");
    if (tree) action = action.Substring(0, action.Length - 5);
    IAccessible root = Root(hwnd);
    if (root == null) { res.Status = "no-root"; return res; }
    var hits = new List<KeyValuePair<IAccessible, object>>();
    Find(root, name, role, hits, 0, maxNodes, deadlineMs, Stopwatch.StartNew(), new int[] { 0 });
    res.Matches = hits.Count;
    if (hits.Count <= nth) { res.Status = "not-found"; return res; }
    IAccessible acc = hits[nth].Key; object child = hits[nth].Value;
    Fill(res, acc, child);
    if (tree && res.Role != "36") { res.Status = "not-a-tree-item"; return res; }
    if (!tree && (res.State & 0x8000) != 0) { res.Status = "invisible"; return res; }
    if (action == "read") { res.Status = "ok"; return res; }
    if ((res.State & 0x1) != 0) { res.Status = "unavailable"; return res; }
    try {
      if (action == "default") acc.accDoDefaultAction(child);
      else if (action == "select") acc.accSelect(3, child);
      else if (action == "setvalue") acc.set_accValue(child, value);
      else { res.Status = "bad-action"; return res; }
    } catch (Exception e) { res.Status = "error: " + e.Message; return res; }
    Fill(res, acc, child);
    res.Status = "ok";
    return res;
  }

  private static void Fill(ActResult r, IAccessible acc, object child) {
    r.Name = S(() => acc.get_accName(child), 300); r.Value = S(() => acc.get_accValue(child), 300);
    r.Role = S(() => acc.get_accRole(child), 40); r.DefaultAction = S(() => acc.get_accDefaultAction(child), 60);
    try { int l, t, w, h; acc.accLocation(out l, out t, out w, out h, child); r.Rect = new[] { l, t, w, h }; } catch { r.Rect = null; }
    int st = 0; try { object o = acc.get_accState(child); if (o is int) st = (int)o; } catch { }
    r.State = st;
  }

  private static bool Match(IAccessible acc, object child, string name, string role) {
    string n = S(() => acc.get_accName(child), 300);
    if (n == null || !string.Equals(n, name, StringComparison.Ordinal)) return false;
    string r = S(() => acc.get_accRole(child), 40);
    if (r == "9") return false;
    // IsNullOrEmpty, not == null: PowerShell passes $null to a .NET string parameter as "".
    return string.IsNullOrEmpty(role) || r == role;
  }

  private static void Find(IAccessible acc, string name, string role, List<KeyValuePair<IAccessible, object>> hits,
                           int depth, int max, int deadline, Stopwatch sw, int[] seen) {
    if (seen[0]++ >= max || sw.ElapsedMilliseconds > deadline || depth > 60) return;
    if (Match(acc, 0, name, role)) hits.Add(new KeyValuePair<IAccessible, object>(acc, 0));
    object[] kids = Kids(acc);
    if (kids == null) return;
    bool standardWindow = S(() => acc.get_accRole(0), 40) == "9" && kids.Length == 7;
    for (int i = 0; i < kids.Length; i++) {
      if (standardWindow && (i == 0 || i == 1 || i == 2 || i == 6)) continue;
      IAccessible ka = kids[i] as IAccessible;
      if (ka != null) Find(ka, name, role, hits, depth + 1, max, deadline, sw, seen);
      else if (kids[i] is int) { seen[0]++; if (Match(acc, kids[i], name, role)) hits.Add(new KeyValuePair<IAccessible, object>(acc, kids[i])); }
    }
  }
}
'@
}

# ---------------------------------------------------------------------------------------
# Pure helpers (tested without SWD)
# ---------------------------------------------------------------------------------------

function ConvertTo-SwdProbeLabel {
    <#  Normalise a control or tab caption for allowlist matching: '&' accelerators,
        MSAA's ';' line breaks and runs of whitespace collapse; case is kept.
        Invisible characters ($script:ProbeInvisiblePattern) are removed and the text is
        composed to NFC FIRST, so the denylist regex, which compares code points, sees the
        word a person sees: 'Del<U+00AD>ete' and an 'e' + U+0301 spelling both walked a
        denied word past it (measured). Invisibles go before NFC so a stripped joiner cannot
        leave a mark uncomposed. Normalize() throws on a lone surrogate and on the
        noncharacters U+FDD0-U+FDEF, U+FFFE and U+FFFF (measured): the check then refuses,
        which is the safe direction.  #>
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    $t = ($Text -replace $script:ProbeInvisiblePattern, '').Normalize([Text.NormalizationForm]::FormC)
    return (($t -replace '&', '' -replace '[;\r\n\t]+', ' ') -replace '\s+', ' ').Trim()
}

function Test-SwdProbeListed {
    <#  Ordinal membership. The lists are documented as EXACT, but -ccontains is linguistic:
        it ignored 2,534 BMP code points (NUL, U+00AD, U+034F and letters its sort tables
        lack), so 'Del' + U+0525 + 'ete' matched a listed 'Delete' while the denylist regex
        did not see the word (measured 2026-10-01).  #>
    param([string[]]$List, [string]$Label)
    return (@($List | Where-Object { [string]::Equals($_, $Label, [StringComparison]::Ordinal) }).Count -gt 0)
}

function Format-PathForDisplay {
    <#  A path with the username and the OneDrive tenant collapsed, for the console and
        summary.json (R9). Ported from census_board.ps1: the OneDrive roots are tested FIRST,
        because they sit under USERPROFILE and '~' alone leaves the tenant folder name.  #>
    param([string] $Path)
    if (-not $Path) { return '' }
    $p = $Path.Replace('/', '\')
    foreach ($od in @($env:OneDriveCommercial, $env:OneDriveConsumer, $env:OneDrive)) {
        if ($od -and $p.StartsWith($od.Replace('/', '\'), [StringComparison]::OrdinalIgnoreCase)) {
            return '~\OneDrive' + $p.Substring($od.Length)
        }
    }
    $up = $env:USERPROFILE
    if ($up -and $p.StartsWith($up.Replace('/', '\'), [StringComparison]::OrdinalIgnoreCase)) { return '~' + $p.Substring($up.Length) }
    return $p
}

function Format-MessageForDisplay {
    <#  The same for free text: a .NET or Python error message embeds absolute paths.
        Ported from census_board.ps1. Longest roots first: OneDrive lives under USERPROFILE.
        Case-insensitive, as Format-PathForDisplay is (S9): Windows paths are, and a message
        that spelled the profile 'C:\USERS\...' kept the username.  #>
    param([string] $Message)
    $ic = [Text.RegularExpressions.RegexOptions]::IgnoreCase
    foreach ($root in @($env:OneDriveCommercial, $env:OneDriveConsumer, $env:OneDrive)) {
        if ($root) { $Message = [regex]::Replace($Message, [regex]::Escape($root), '~\OneDrive', $ic) }
    }
    if ($env:USERPROFILE) { $Message = [regex]::Replace($Message, [regex]::Escape($env:USERPROFILE), '~', $ic) }
    return $Message
}

function Get-SwdProbeDenyMatch {
    param([AllowNull()][string]$Text)
    if (-not $Text) { return $null }
    # CultureInvariant: under tr-TR, (?i) folds 'I' to a dotless i, so 'IMPORT' and
    # 'SUPPRIMER' did not match (measured).
    $m = [regex]::Match($Text, $script:ProbeDenyPattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if ($m.Success) { return $m.Value }
    return $null
}

function Test-SwdProbeAllowedButton {
    <#  $true only for an exact allowlisted caption that also clears the denylist.  #>
    param([AllowNull()][string]$Text)
    $label = ConvertTo-SwdProbeLabel $Text
    if (-not $label) { return $false }
    if (Get-SwdProbeDenyMatch $label) { return $false }
    if (Test-SwdProbeListed -List $script:ProbeAllowedButtons -Label $label) { return $true }
    foreach ($p in $script:ProbeAllowedButtonPatterns) {
        if ([regex]::IsMatch($label, $p, [Text.RegularExpressions.RegexOptions]::CultureInvariant)) { return $true }
    }
    return $false
}

function Assert-SwdProbeButton {
    <#  Re-reads the caption from the live handle and refuses anything not allowlisted.  #>
    param([Parameter(Mandatory)][int64]$Handle, [scriptblock]$TextReader = { param($h) Get-SwdText -Handle $h })
    $text = & $TextReader $Handle
    if (-not (Test-SwdProbeAllowedButton $text)) {
        throw "Refusing to click handle $Handle captioned '$(ConvertTo-SwdSafeText $text 60)': not on the probe allowlist."
    }
    return (ConvertTo-SwdProbeLabel $text)
}

function Test-SwdProbeAllowedTab {
    param([AllowNull()][string]$Name)
    $label = ConvertTo-SwdProbeLabel $Name
    if (-not $label -or (Get-SwdProbeDenyMatch $label)) { return $false }
    return (Test-SwdProbeListed -List $script:ProbeAllowedTabs -Label $label)
}

function Get-SwdProbeBoardName {
    <#  Board name from the main window caption, or $null.  #>
    param([AllowNull()][string]$Title)
    if ($Title -and $Title -match '<Board:\s*(.+?)\([\d.,]+\s*mm\)>') { return $Matches[1].Trim() }
    return $null
}

function Assert-SwdProbeBoard {
    param([AllowNull()][string]$Title)
    $name = Get-SwdProbeBoardName $Title
    if (-not $name) { throw "Cannot read the loaded board from the caption '$(ConvertTo-SwdSafeText $Title 80)'." }
    if ($name -notlike '*_Copy*') { throw "Board '$name' is not a copy. Probes run on '*_Copy*' boards only." }
    return $name
}

function Test-SwdProbeStop {
    <#  Kill switch. Returns the reason to stop, or $null.
        CursorReader is injectable for tests; the live one reads GetCursorPos.  #>
    param(
        [Parameter(Mandatory)][string]$StopFile,
        [scriptblock]$CursorReader = { [SwdProbeNative]::CursorPos() },
        [int]$CornerPx = 2
    )
    # Shown with the profile collapsed (S9): this text is rethrown and printed as it is.
    if (Test-Path -LiteralPath $StopFile) { return "stop file present: $(Format-PathForDisplay $StopFile)" }
    $c = & $CursorReader
    # The PRIMARY screen's top-left: (0,0) to (CornerPx,CornerPx). A bare 'x <= 2' also
    # matched the whole top edge of a monitor to the LEFT of the primary (negative x),
    # measured 2026-09-30 with the cursor at (-1920,127).
    if ($c -and $c.Count -ge 2 -and $c[0] -ge 0 -and $c[0] -le $CornerPx -and $c[1] -ge 0 -and $c[1] -le $CornerPx) {
        return 'cursor parked in the top-left corner'
    }
    return $null
}

function Assert-SwdProbeContinue {
    param([Parameter(Mandatory)][string]$StopFile, [scriptblock]$CursorReader = { [SwdProbeNative]::CursorPos() })
    $why = Test-SwdProbeStop -StopFile $StopFile -CursorReader $CursorReader
    if ($why) { throw "SWD-PROBE-STOPPED: $why" }
}

function ConvertFrom-SwdMapRect {
    <#  'l,t,r,b' (screen, as swd_msg.ps1 records it) -> window-relative [x, y, w, h].  #>
    param([Parameter(Mandatory)][string]$Rect, [int]$OriginX = 0, [int]$OriginY = 0)
    $v = @($Rect -split ',' | ForEach-Object { [int]($_.Trim()) })
    if ($v.Count -ne 4) { throw "Rect '$Rect' does not have four fields." }
    return , @(($v[0] - $OriginX), ($v[1] - $OriginY), ($v[2] - $v[0]), ($v[3] - $v[1]))
}

function Compare-SwdMsaa {
    <#  Diff two MSAA walks keyed by Path|Role. Ignore = @{ '<path>|<field>' = $true }.
        Name/Value/State are compared; a row whose Name matches a noise pattern is skipped.  #>
    param($Before, $After, [hashtable]$Ignore = @{}, [string[]]$NoiseLike = $script:ProbeMsaaNoiseLike)
    # Window-anchored Key when the walk provides one (live walks); index Path otherwise.
    $key = { param($n) $k = if ($n.PSObject.Properties['Key'] -and $n.Key) { $n.Key } else { $n.Path }; "$k|$($n.Role)" }
    $hid = { param($n) [bool]($n.PSObject.Properties['Hidden'] -and $n.Hidden) }
    $b = @{}; foreach ($n in @($Before)) { if ($null -ne $n) { $b[(& $key $n)] = $n } }
    $a = @{}; foreach ($n in @($After))  { if ($null -ne $n) { $a[(& $key $n)] = $n } }
    # Trimmed: SWD's status-bar names start with a space (' Cpu:13%'), measured live T9.
    function Test-Noise($n, [string[]]$patterns) { if (-not $n.Name) { return $false }; $t = $n.Name.Trim(); foreach ($p in $patterns) { if ($t -like $p) { return $true } }; return $false }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($k in $a.Keys) {
        $an = $a[$k]
        if (Test-Noise $an $NoiseLike) { continue }
        if (-not $b.ContainsKey($k)) {
            if (-not $Ignore.ContainsKey("$k|APPEARED")) {
                $out.Add([pscustomobject]@{ Key = $k; Kind = 'APPEARED'; Field = '-'; From = $null; To = $an.Name; Name = $an.Name; Hidden = (& $hid $an) })
            }
            continue
        }
        $bn = $b[$k]
        if (Test-Noise $bn $NoiseLike) { continue }
        foreach ($f in 'Name', 'Value', 'State') {
            $fb = $bn.$f; $fa = $an.$f
            if ((($null -eq $fb) -ne ($null -eq $fa)) -or ($null -ne $fb -and "$fb" -cne "$fa")) {
                if ($Ignore.ContainsKey("$k|$f")) { continue }
                $out.Add([pscustomobject]@{ Key = $k; Kind = 'CHANGED'; Field = $f; From = $fb; To = $fa; Name = $an.Name; Hidden = ((& $hid $an) -and (& $hid $bn)) })
            }
        }
    }
    foreach ($k in $b.Keys) {
        if (-not $a.ContainsKey($k) -and -not (Test-Noise $b[$k] $NoiseLike) -and -not $Ignore.ContainsKey("$k|VANISHED")) {
            $out.Add([pscustomobject]@{ Key = $k; Kind = 'VANISHED'; Field = '-'; From = $b[$k].Name; To = $null; Name = $b[$k].Name; Hidden = (& $hid $b[$k]) })
        }
    }
    return $out.ToArray()
}

function Get-SwdProbeVolatility {
    <#  Ignore set from a null-action diff: every key|field that moved with nothing done.  #>
    param($MsaaDiff, $Win32Diff)
    $ig = @{}
    foreach ($d in @($MsaaDiff)) { if ($null -ne $d) { $f = if ($d.Kind -eq 'CHANGED') { $d.Field } else { $d.Kind }; $ig["$($d.Key)|$f"] = $true } }
    foreach ($d in @($Win32Diff)) { if ($null -ne $d) { $ig["W$($d.Handle)|$($d.Kind)|$($d.Field)"] = $true } }
    return $ig
}

function Test-SwdBoxInNoise {
    <#  $true when a change box [x, y, w, h] lies wholly inside one measured noise rectangle.
        The image diff's tile mask comes from T5 alone; tiles seen changing with no action
        since (1280,128) are only in $script:ProbeNoiseRects.  #>
    param([Parameter(Mandatory)]$Box, $Rects = $script:ProbeNoiseRects)
    $b = @($Box); if ($b.Count -ne 4) { return $false }
    foreach ($r in @($Rects)) {
        if ($b[0] -ge $r[0] -and $b[1] -ge $r[1] -and ($b[0] + $b[2]) -le ($r[0] + $r[2]) -and ($b[1] + $b[3]) -le ($r[1] + $r[3])) { return $true }
    }
    return $false
}

function Get-SwdLibraryHash {
    <#  SHA-256 per file, keyed by path relative to Root. Exclude = wildcards on that path.  #>
    param([Parameter(Mandatory)][string]$Root, [string[]]$Exclude = $script:ProbeLibraryExclude)
    if (-not (Test-Path -LiteralPath $Root)) { throw "Library root not found: $(Format-PathForDisplay $Root)" }
    $full = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\')
    $map = @{}
    # -Force: without it hidden files, and every file in a hidden folder, were never hashed,
    # so tampering with one left Ok=$true (S11).
    foreach ($f in Get-ChildItem -LiteralPath $full -Recurse -File -Force) {
        $rel = $f.FullName.Substring($full.Length).TrimStart('\')
        $skip = $false; foreach ($x in $Exclude) { if ($rel -like $x) { $skip = $true; break } }
        if ($skip) { continue }
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $s = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
            try { $map[$rel] = [BitConverter]::ToString($sha.ComputeHash($s)).Replace('-', '') } finally { $s.Dispose() }
        } finally { $sha.Dispose() }
    }
    return $map
}

function Compare-SwdLibraryHash {
    param([Parameter(Mandatory)][hashtable]$Before, [Parameter(Mandatory)][hashtable]$After)
    $added = @($After.Keys | Where-Object { -not $Before.ContainsKey($_) } | Sort-Object)
    $removed = @($Before.Keys | Where-Object { -not $After.ContainsKey($_) } | Sort-Object)
    $changed = @($After.Keys | Where-Object { $Before.ContainsKey($_) -and $Before[$_] -ne $After[$_] } | Sort-Object)
    return [pscustomobject]@{
        Files = $After.Count; Added = $added; Removed = $removed; Changed = $changed
        Ok = ($added.Count + $removed.Count + $changed.Count -eq 0)
    }
}

function Measure-SwdSettle {
    <#  Settle decision over a sample series (pure; Wait-SwdProbeSettle feeds it live).
        Each sample: @{ T = ms since act; Responsive = bool; CpuPct = double; Frame = string }.
        Settled at the first sample where the app answers, CPU is below the threshold, and
        the last K frames are identical and non-null.  #>
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Samples, [double]$CpuThreshold = 2.5, [int]$FrameK = 3)
    # NOT @($Samples) for a generic list: on Windows PowerShell 5.1 '@(List[object])' throws
    # "Argument types do not match" (measured 2026-09-30, first live T9; the unit tests had
    # only ever passed arrays). ToArray() is safe. Assigned inside each branch, not as
    # '$s = if (...) {...}': that form unrolls a one-element array into a bare hashtable
    # and turns an empty one into $null (caught by the unit tests on the first fix).
    if ($Samples -is [System.Collections.Generic.List[object]]) { $s = $Samples.ToArray() } else { $s = @($Samples) }
    $first = @{ Responsive = $null; CpuQuiet = $null; FramesStable = $null }
    for ($i = 0; $i -lt $s.Count; $i++) {
        $x = $s[$i]
        $stable = $false
        if ($i -ge $FrameK - 1 -and $x.Frame) {
            $stable = $true
            for ($j = $i - $FrameK + 1; $j -lt $i; $j++) { if ($s[$j].Frame -ne $x.Frame) { $stable = $false; break } }
        }
        $cpuQuiet = ($null -ne $x.CpuPct -and $x.CpuPct -lt $CpuThreshold)
        if ($x.Responsive -and $null -eq $first.Responsive) { $first.Responsive = $x.T }
        if ($cpuQuiet -and $null -eq $first.CpuQuiet) { $first.CpuQuiet = $x.T }
        if ($stable -and $null -eq $first.FramesStable) { $first.FramesStable = $x.T }
        if ($x.Responsive -and $cpuQuiet -and $stable) {
            return [pscustomobject]@{ Settled = $true; SettleMs = $x.T; FirstResponsiveMs = $first.Responsive
                                      FirstCpuQuietMs = $first.CpuQuiet; FirstFramesStableMs = $first.FramesStable; Samples = $s.Count }
        }
    }
    $last = if ($s.Count) { $s[-1].T } else { 0 }
    return [pscustomobject]@{ Settled = $false; SettleMs = $last; FirstResponsiveMs = $first.Responsive
                              FirstCpuQuietMs = $first.CpuQuiet; FirstFramesStableMs = $first.FramesStable; Samples = $s.Count }
}

function Invoke-SwdProbeStopLoop {
    <#  T17 core: run Step for up to Iterations, checking the kill switch before each.
        Returns the number of steps completed and why it stopped.  #>
    param([Parameter(Mandatory)][string]$StopFile, [Parameter(Mandatory)][scriptblock]$Step,
          [int]$Iterations = 10, [scriptblock]$CursorReader = { $null })
    $done = 0
    try {
        for ($i = 0; $i -lt $Iterations; $i++) {
            Assert-SwdProbeContinue -StopFile $StopFile -CursorReader $CursorReader
            & $Step $i
            $done++
        }
        return [pscustomobject]@{ Completed = $done; Stopped = $false; Reason = $null }
    } catch {
        if ($_.Exception.Message -like 'SWD-PROBE-STOPPED:*') {
            return [pscustomobject]@{ Completed = $done; Stopped = $true; Reason = $_.Exception.Message }
        }
        throw
    }
}

function Write-SwdProbeJson {
    <#  Written beside the target and swapped in (W5, SQA 2026-10-06): a chunk killed mid-write left
        state.json EMPTY, which every reader took for "no state" and started over (the Sweep then
        overwrote its manifest with an empty one). A crash now leaves the old file whole.
        [NullString]::Value, not $null: PowerShell hands $null to a .NET string as '', which
        File.Replace refuses ("The path is not of a legal form", measured).  #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Object, [int]$Depth = 6)
    $json = $Object | ConvertTo-Json -Depth $Depth
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false))
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
}

function Read-SwdProbeState {
    <#  A resume-state file (state.json, loop_state.json, pilot.json) as an object, or $null when the
        file does not exist. A file that EXISTS but is empty, blank or anything but a JSON object
        ('null', 'false', truncated text) throws SWD-STATE-UNREADABLE (W5): reading it as "no
        state" restarted a loop at cursor 0 and let a Sweep chunk plan nothing and then overwrite
        the census-built state with an empty one.  #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $st = $null
    try { $st = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $st = $null }
    if ($st -isnot [Management.Automation.PSCustomObject]) {
        throw "SWD-STATE-UNREADABLE: $(Format-PathForDisplay $Path) exists but is empty or not a JSON object. Refusing to start over: restore it, or delete it to start a new run."
    }
    return $st
}

# ---------------------------------------------------------------------------------------
# Live layer (needs SWD running and an elevated host)
# ---------------------------------------------------------------------------------------

function Get-SwdProbeLogDir {
    param([string]$Override)
    $dir = if ($Override) { $Override } else { Join-Path $env:LOCALAPPDATA ('swd-probe\' + (Get-Date -Format 'yyyy-MM-dd')) }
    $resolved = Resolve-SwdWritableTarget -Path $dir
    if (-not $resolved) { throw "Refusing to log to '$dir' (path guard)." }
    if (-not (Test-Path -LiteralPath $resolved)) { [void][IO.Directory]::CreateDirectory($resolved) }
    return $resolved
}

function Get-SwdProbeMain {
    <#  Main window handle, verified by caption (MainWindowHandle is unstable: LIVE-RUN-FINDINGS).
        Polled for up to WaitMs: Board Dynamics raises a self-closing popup ('Dynamics on, Shaping
        function are unabled') that holds MainWindowHandle for a second or two (measured
        2026-10-01). Get-SwdControl and Save-SwdWindowImage both read MainWindowHandle, so a
        snapshot must not start while it is pointing elsewhere.  #>
    param([int]$WaitMs = 10000)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $p = $null; $h = 0; $title = $null; $why = $null
        # A zero MainWindowHandle (between windows) throws in Get-SwdProcess; it is polled
        # through like a foreign caption, and only the last failure is reported.
        try { $p = Get-SwdProcess; $h = [int64]$p.MainWindowHandle; $title = Get-SwdText -Handle $h } catch { $why = $_.Exception.Message }
        if ($title -and $title -like 'FYN Shaper Wave Dynamics*') { return [pscustomobject]@{ Process = $p; Handle = $h; Title = $title } }
        if ($sw.ElapsedMilliseconds -ge $WaitMs) {
            if ($why) { throw $why }
            throw "MainWindowHandle $h is captioned '$(ConvertTo-SwdSafeText $title 60)', not the SWD main window. Close dialogs and retry."
        }
        Start-Sleep -Milliseconds 500
    }
}

function Get-SwdMsaaSnapshot {
    param([Parameter(Mandatory)][int64]$Handle, [int]$MaxNodes = 6000, [int]$DeadlineMs = 20000)
    $nodes = [SwdProbeNative]::Walk([intptr]$Handle, $MaxNodes, $DeadlineMs)
    return [pscustomobject]@{ Nodes = @($nodes); Truncated = [SwdProbeNative]::LastWalkTruncated }
}

function Get-SwdProbeFrameHash {
    param([Parameter(Mandatory)][int64]$Handle, $Rects = $script:ProbeNoiseRects)
    $flat = New-Object System.Collections.Generic.List[int]
    foreach ($r in @($Rects)) { foreach ($v in $r) { $flat.Add([int]$v) } }
    return [SwdProbeNative]::FrameHash([intptr]$Handle, $flat.ToArray())
}

function Wait-SwdProbeSettle {
    <#  Poll until the app answers, its CPU falls below the threshold and K frames match.  #>
    param([Parameter(Mandatory)][int64]$Handle, [int]$TimeoutMs = 20000, [int]$IntervalMs = 250,
          [double]$CpuThreshold = 2.5, [int]$FrameK = 3, [string]$StopFile)
    $p = Get-SwdProcess
    $cores = [Environment]::ProcessorCount
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $samples = New-Object System.Collections.Generic.List[object]
    $p.Refresh(); $lastCpu = $p.TotalProcessorTime.TotalMilliseconds; $lastT = 0
    while ($true) {
        Start-Sleep -Milliseconds $IntervalMs
        if ($StopFile) { Assert-SwdProbeContinue -StopFile $StopFile }
        $rt = [SwdProbeNative]::NullRoundTripMs([intptr]$Handle, 200)
        $p.Refresh(); $cpu = $p.TotalProcessorTime.TotalMilliseconds; $t = $sw.ElapsedMilliseconds
        $pct = if ($t -gt $lastT) { 100.0 * ($cpu - $lastCpu) / (($t - $lastT) * $cores) } else { $null }
        $lastCpu = $cpu; $lastT = $t
        $samples.Add(@{ T = [int]$t; Responsive = ($rt -ge 0); RoundTripMs = $rt; CpuPct = $pct
                        Frame = (Get-SwdProbeFrameHash -Handle $Handle) })
        $m = Measure-SwdSettle -Samples $samples.ToArray() -CpuThreshold $CpuThreshold -FrameK $FrameK
        if ($m.Settled -or $t -ge $TimeoutMs) {
            $maxCpu = 0.0
            foreach ($x in $samples) { if ($null -ne $x.CpuPct -and $x.CpuPct -gt $maxCpu) { $maxCpu = $x.CpuPct } }
            $m | Add-Member -NotePropertyName TimedOut -NotePropertyValue (-not $m.Settled)
            $m | Add-Member -NotePropertyName MaxCpuPct -NotePropertyValue ([math]::Round($maxCpu, 2))
            return $m
        }
    }
}

function Get-SwdProbeSnapshot {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Label)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $main = Get-SwdProbeMain
    $controls = @(Get-SwdControl)
    $msaa = Get-SwdMsaaSnapshot -Handle $main.Handle
    $img = Save-SwdWindowImage -Name $Label -Dir $Dir
    $r = New-Object 'SwdWin+RECT'; [void][SwdWin]::GetWindowRect([intptr]$main.Handle, [ref]$r)
    $snap = [pscustomobject]@{
        Label = $Label; Time = (Get-Date).ToString('o'); Title = $main.Title
        Origin = @($r.Left, $r.Top); Controls = $controls; Msaa = $msaa.Nodes; MsaaTruncated = $msaa.Truncated
        # NEW-1 (SQA 2026-10-01): Save-SwdWindowImage returns $null when PrintWindow fails.
        # Recorded, so Compare-SwdProbeSnapshot reports the image detector as failed rather
        # than silently comparing Win32 and MSAA alone.
        Image = $img; ImageFailed = (-not $img); ElapsedMs = [int]$sw.ElapsedMilliseconds
    }
    Write-SwdProbeJson -Path (Join-Path $Dir "$Label.json") -Object ([pscustomobject]@{
        Label = $snap.Label; Time = $snap.Time; Title = $snap.Title; Origin = $snap.Origin; Image = $snap.Image
        ImageFailed = $snap.ImageFailed; MsaaTruncated = $snap.MsaaTruncated; Controls = $controls; Msaa = $snap.Msaa }) -Depth 4
    return $snap
}

function Find-SwdProbeNoiseMask {
    $root = Join-Path $env:LOCALAPPDATA 'swd-probe'
    $m = Get-ChildItem -LiteralPath $root -Recurse -Filter 'noise_mask.npy' -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($m) { return $m.FullName }
    return $null
}

function Invoke-SwdProbeImageDiff {
    <#  swd_diff.py 'pair'. Returns its result, or an object whose only property is Error.
        It does not throw for a failed diff: the caller reports that as 'detector failed',
        never as zero changes (W2).  #>
    param([Parameter(Mandatory)][string]$BeforeImage, [Parameter(Mandatory)][string]$AfterImage, [string]$Mask, $ExpectRects = @())
    $args2 = @((Join-Path $script:ProbeRoot 'swd_diff.py'), 'pair', $BeforeImage, $AfterImage)
    if ($Mask) { $args2 += @('--mask', $Mask) }
    # A loop, not a pipeline: piping an array of 4-element arrays can unroll them.
    $rects = @(); foreach ($r in @($ExpectRects)) { if ($null -ne $r -and @($r).Count -eq 4) { $rects += ,(@($r) -join ',') } }
    if ($rects.Count) { $args2 += '--expect'; $args2 += $rects }
    # Local 'Continue': -Probe runs under 'Stop', where Windows PowerShell 5.1 turns any
    # stderr line of a native command into a terminating error, so the error branch never
    # ran and a failed diff aborted the probe (measured, size-mismatched pair). stderr is
    # told apart from stdout by type, so a warning on it cannot corrupt the JSON.
    $ErrorActionPreference = 'Continue'
    $out = New-Object System.Collections.Generic.List[string]
    $err = New-Object System.Collections.Generic.List[string]
    # Reset first, so an exit code this call did not produce (an earlier command's, or none
    # at all under StrictMode) is never read as this diff's.
    $global:LASTEXITCODE = 0
    try {
        foreach ($line in (& py -3.14 @args2 2>&1)) {
            if ($line -is [Management.Automation.ErrorRecord]) { $err.Add("$line") } else { $out.Add("$line") }
        }
        $code = $LASTEXITCODE
    } catch { return [pscustomobject]@{ Error = "image diff did not run: $($_.Exception.Message)" } }
    $why = ($err -join ' ').Trim()
    if ($code -ne 0) { return [pscustomobject]@{ Error = $(if ($why) { $why } else { "swd_diff.py exited $code" }) } }
    $res = $null
    try { $res = ($out -join "`n") | ConvertFrom-Json } catch { $res = $null }
    # Success needs positive evidence: a result carrying out_of_scope.
    if ($null -eq $res -or -not $res.PSObject.Properties['out_of_scope']) {
        return [pscustomobject]@{ Error = "swd_diff.py returned no usable result. $why".Trim() }
    }
    return $res
}

function Compare-SwdProbeSnapshot {
    <#  Win32 + MSAA + image diff, each change tagged InScope against what the action
        declared. Everything not in scope and not volatile is the out-of-scope list.  #>
    param([Parameter(Mandatory)]$Before, [Parameter(Mandatory)]$After, [int64[]]$ExpectHandles = @(),
          [string[]]$ExpectValues = @(), [string[]]$ExpectNameLike = @(), $ExpectRects = @(),
          [hashtable]$Ignore = @{}, [string]$Mask)
    $exp = @{}; foreach ($h in $ExpectHandles) { $exp[[int64]$h] = $true }
    $win = @(Compare-SwdMap -Before $Before.Controls -After $After.Controls | Where-Object {
        -not $Ignore.ContainsKey("W$($_.Handle)|$($_.Kind)|$($_.Field)") })
    $parent = @{}; $visA = @{}; $visB = @{}
    foreach ($c in @($After.Controls)) { $parent[[int64]$c.Handle] = [int64]$c.Parent; $visA[[int64]$c.Handle] = [bool]$c.Visible }
    foreach ($c in @($Before.Controls)) { if (-not $parent.ContainsKey([int64]$c.Handle)) { $parent[[int64]$c.Handle] = [int64]$c.Parent }; $visB[[int64]$c.Handle] = [bool]$c.Visible }
    foreach ($d in $win) {
        $in = $exp.ContainsKey([int64]$d.Handle) -or ($parent.ContainsKey([int64]$d.Handle) -and $exp.ContainsKey($parent[[int64]$d.Handle]))
        # A control created (or destroyed) while hidden is structure, not a visible effect:
        # SWD builds a tab's controls on first show and keeps them (first live T11).
        $hidden = ($d.Kind -eq 'APPEARED' -and -not $visA[[int64]$d.Handle]) -or ($d.Kind -eq 'VANISHED' -and -not $visB[[int64]$d.Handle])
        $d | Add-Member -NotePropertyName InScope -NotePropertyValue $in -Force
        $d | Add-Member -NotePropertyName Hidden -NotePropertyValue ([bool]$hidden) -Force
    }
    $ms = @(Compare-SwdMsaa -Before $Before.Msaa -After $After.Msaa -Ignore $Ignore)
    foreach ($d in $ms) {
        $in = ($ExpectValues -contains "$($d.From)") -or ($ExpectValues -contains "$($d.To)")
        foreach ($p in $ExpectNameLike) { if ($d.Name -and $d.Name -like $p) { $in = $true } }
        $d | Add-Member -NotePropertyName InScope -NotePropertyValue $in -Force
        # Only structural appear/vanish under a hidden window is set aside; a value or state
        # CHANGE on a hidden control is still an effect (Apply Length updates hidden fields).
        $hs = ($d.Kind -ne 'CHANGED') -and $d.PSObject.Properties['Hidden'] -and [bool]$d.Hidden
        $d | Add-Member -NotePropertyName Hidden -NotePropertyValue ([bool]$hs) -Force
    }
    $img = $null; $imgErr = $null
    if ($Before.Image -and $After.Image) {
        $img = Invoke-SwdProbeImageDiff -BeforeImage $Before.Image -AfterImage $After.Image -Mask $Mask -ExpectRects $ExpectRects
        # A diff that failed is a detector that did not run, never a clean one (W2), so the
        # out-of-scope count below becomes $null, not 0. Python reports a path through
        # repr(), doubling its backslashes, which are collapsed before redaction (R9).
        if ($null -eq $img -or -not $img.PSObject.Properties['out_of_scope']) {
            $raw = if ($img -and $img.PSObject.Properties['Error']) { "$($img.Error)" } else { 'image diff returned nothing' }
            $imgErr = Format-MessageForDisplay ($raw.Replace('\\', '\'))
        }
    } elseif (($Before.PSObject.Properties['ImageFailed'] -and $Before.ImageFailed) -or
              ($After.PSObject.Properties['ImageFailed'] -and $After.ImageFailed)) {
        # NEW-1: a capture that failed is a detector that did not run, never zero image changes.
        $imgErr = 'window capture failed (PrintWindow returned no image)'
    }
    # Assigned per branch: '$x = if (...) { @(...) } else { @() }' yields $null for an empty
    # result (then .Count throws under StrictMode) and unrolls a single box into its four
    # numbers. Measured on the first live T9, 2026-09-30.
    $imgOut = @()
    if ($img -and $img.PSObject.Properties['out_of_scope']) {
        foreach ($b in @($img.out_of_scope)) { if (-not (Test-SwdBoxInNoise -Box $b)) { $imgOut += , $b } }
    }
    $outW = @($win | Where-Object { -not $_.InScope -and -not $_.Hidden })
    $outM = @($ms | Where-Object { -not $_.InScope -and -not $_.Hidden })
    return [pscustomobject]@{
        Win32 = $win; Msaa = $ms; Image = $img; ImageError = $imgErr
        OutOfScope = [pscustomobject]@{ Win32 = $outW; Msaa = $outM; ImageBoxes = $imgOut }
        # $null, never 0, when the image detector failed: the count is then unknown.
        OutOfScopeCount = $(if ($imgErr) { $null } else { $outW.Count + $outM.Count + $imgOut.Count })
        # Either MSAA walk cut short (node, time or depth cap, or a node with more than 10,000
        # children): the MSAA half of this diff is then incomplete (S4).
        MsaaTruncated = [bool](($Before.PSObject.Properties['MsaaTruncated'] -and $Before.MsaaTruncated) -or
                               ($After.PSObject.Properties['MsaaTruncated'] -and $After.MsaaTruncated))
        InScopeCount = @($win | Where-Object { $_.InScope }).Count + @($ms | Where-Object { $_.InScope }).Count
        HiddenStructural = @($win | Where-Object { $_.Hidden }).Count + @($ms | Where-Object { $_.Hidden }).Count
    }
}

function Format-SwdProbeDiff {
    <#  Short human-readable lines for the console and the summary.  #>
    param($Diff, [int]$Max = 25)
    $lines = @()
    if ($Diff.PSObject.Properties['ImageError'] -and $Diff.ImageError) { $lines += "  IMG  DETECTOR FAILED, change count unknown: $(ConvertTo-SwdSafeText $Diff.ImageError 160)" }
    if ($Diff.PSObject.Properties['MsaaTruncated'] -and $Diff.MsaaTruncated) { $lines += '  MSAA WALK TRUNCATED: changes past the cut are not in this diff' }
    foreach ($d in @($Diff.OutOfScope.Win32) | Select-Object -First $Max) { $lines += "  W32  $($d.Kind) $($d.Field) h=$($d.Handle): '$($d.From)' -> '$($d.To)'" }
    foreach ($d in @($Diff.OutOfScope.Msaa) | Select-Object -First $Max) { $lines += "  MSAA $($d.Kind) $($d.Field) [$(ConvertTo-SwdSafeText $d.Name 40)]: '$(ConvertTo-SwdSafeText "$($d.From)" 40)' -> '$(ConvertTo-SwdSafeText "$($d.To)" 40)'" }
    foreach ($b in @($Diff.OutOfScope.ImageBoxes) | Select-Object -First $Max) { $lines += "  IMG  box $($b -join ',')" }
    return $lines
}

function Select-SwdProbeTab {
    <#  Select an allowlisted tab by TCM_SETCURFOCUS (T11). The MSAA walk finds the page tab
        by exact name; its window-anchored Key gives the owning tab control and the index.
        Never a mouse click: see SwdProbeNative.SelectTab.  #>
    param([Parameter(Mandatory)][int64]$Handle, [Parameter(Mandatory)][string]$Name, [string]$StopFile)
    if (-not (Test-SwdProbeAllowedTab $Name)) { throw "Tab '$Name' is not on the probe allowlist." }
    $label = ConvertTo-SwdProbeLabel $Name
    $nodes = @((Get-SwdMsaaSnapshot -Handle $Handle).Nodes | Where-Object { $_.Role -eq '37' -and (Test-SwdProbeListed -List (ConvertTo-SwdProbeLabel $_.Name) -Label $label) })
    if ($nodes.Count -ne 1) { throw "Expected exactly one '$Name' page tab, found $($nodes.Count)." }
    $n = $nodes[0]
    if ($n.Key -notmatch '^h(\d+):.*/(\d+)$') { throw "Page tab '$Name' has no usable key '$($n.Key)'." }
    $tab = [int64]$Matches[1]; $index = [int]$Matches[2]
    $sb = New-Object System.Text.StringBuilder 256
    [void][SwdWin]::GetClassName([intptr]$tab, $sb, 256)
    if ($sb.ToString() -notlike '*SysTabControl32*') { throw "Page tab '$Name' is owned by '$($sb.ToString())', not a tab control. Refusing." }
    if ($StopFile) { Assert-SwdProbeContinue -StopFile $StopFile }
    # Re-read right before the switch (S7): the walk above takes seconds, and a tab set that shifted
    # since would otherwise be switched first and caught only by the check after it.
    $pre = [SwdProbeNative]::ChildAt([intptr]$tab, $index)
    if (-not $pre -or -not (Test-SwdProbeListed -List (ConvertTo-SwdProbeLabel $pre.Name) -Label $label)) {
        throw "Tab '$Name': index $index now reads '$(ConvertTo-SwdSafeText $(if ($pre) { $pre.Name } else { $null }) 40)'; the tab set changed. Refusing."
    }
    $got = [SwdProbeNative]::SelectTab([intptr]$tab, $index)
    if ($got -ne $index) { throw "Tab '$Name': asked for index $index, tab control reports $got." }
    # By NAME as well as by index (S12): the page tab now at that index must carry the name
    # and STATE_SYSTEM_SELECTED (0x2).
    $now = [SwdProbeNative]::ChildAt([intptr]$tab, $index)
    if (-not $now -or -not (Test-SwdProbeListed -List (ConvertTo-SwdProbeLabel $now.Name) -Label $label) -or -not ($now.State -band 0x2)) {
        throw "Tab '$Name': index $index is selected, but it is not the selected '$Name' tab (MSAA reads '$(ConvertTo-SwdSafeText $(if ($now) { $now.Name } else { $null }) 40)')."
    }
    return [pscustomobject]@{ Tab = $Name; TabControl = $tab; Index = $index; Selected = $got }
}

function Invoke-SwdProbeAcc {
    <#  Read or act on one MSAA node by exact name, under the sweep's policy:
          read      anything (nothing is touched)
          default   only names on $script:ProbeAccDefaultAllowed, clear of the denylist
          expand    a tree item (role 36) whose OWN default action reads 'Expand'. The
                    denylist is not applied here: expanding changes only what the tree
                    shows, and the analysis tree's root is literally named 'N HydroScans'.
          select    a tree item (role 36): what the property grid shows
          setvalue  only names the caller lists in -AllowedSetValue, clear of the denylist
        The node is read first, so ambiguity and its default action are checked before
        anything acts. The cursor is compared either side of every action: a move means
        the "programmatic" action simulated input, and the run must stop using it.  #>
    param([Parameter(Mandatory)][int64]$Handle, [Parameter(Mandatory)][string]$Name, [string]$Role,
          [ValidateSet('read', 'default', 'expand', 'select', 'setvalue')][string]$Action = 'read',
          [string]$Value, [int]$Nth = 0, [switch]$AllowAmbiguous, [string[]]$AllowedSetValue = @(),
          # Expand or select a tree item even when it is scrolled out of view (the native '-tree'
          # verbs, tree items only). Refused with any other action.
          [switch]$Offscreen,
          [scriptblock]$Native = { param($h, $n, $r, $i, $a, $v) [SwdProbeNative]::Act([intptr]$h, $n, $r, $i, $a, $v, 6000, 20000) },
          [scriptblock]$CursorReader = { [SwdProbeNative]::CursorPos() },
          # The kill switch, checked after the read and immediately before the act (W3).
          [string]$StopFile)
    if ($Offscreen -and @('expand', 'select') -notcontains $Action) { throw "-Offscreen applies to tree expand and select only, not '$Action'." }
    $sfx = if ($Offscreen) { '-tree' } else { '' }
    $label = ConvertTo-SwdProbeLabel $Name
    switch ($Action) {
        'default' {
            if ((Get-SwdProbeDenyMatch $label) -or -not (Test-SwdProbeListed -List $script:ProbeAccDefaultAllowed -Label $label)) {
                throw "Refusing the default action on '$(ConvertTo-SwdSafeText $Name 60)': not on the MSAA allowlist."
            }
        }
        'expand' { $Role = '36' }
        'select' { $Role = '36' }
        'setvalue' {
            if ((Get-SwdProbeDenyMatch $label) -or -not (Test-SwdProbeListed -List $AllowedSetValue -Label $label)) {
                throw "Refusing to set '$(ConvertTo-SwdSafeText $Name 60)': not on the caller's set-value list."
            }
        }
    }
    $r = & $Native $Handle $Name $(if ($Role) { $Role } else { $null }) $Nth "read$sfx" $null
    if ($r.Status -ne 'ok' -or $Action -eq 'read') { return $r }
    if ($r.Matches -gt 1 -and -not $AllowAmbiguous) {
        throw "'$(ConvertTo-SwdSafeText $Name 60)' matches $($r.Matches) MSAA nodes; refusing to guess."
    }
    # Not '$native': PowerShell variable names are case-insensitive, so that is the -Native parameter.
    $verb = $Action
    if ($Action -eq 'expand') {
        if ($r.DefaultAction -ne 'Expand') { $r.Status = "not-expandable ($($r.DefaultAction))"; return $r }
        $verb = 'default'
    }
    if ($StopFile) { Assert-SwdProbeContinue -StopFile $StopFile -CursorReader $CursorReader }
    $c0 = & $CursorReader
    $r2 = & $Native $Handle $Name $(if ($Role) { $Role } else { $null }) $Nth "$verb$sfx" $Value
    $c1 = & $CursorReader
    # An unread first position counts as a move (S5): the guard used to skip the check outright.
    if ($c1 -and (-not $c0 -or $c0[0] -ne $c1[0] -or $c0[1] -ne $c1[1])) {
        # A simulated click puts the cursor ON the node it acted on (T11: the tab's default action
        # clicked at the tab). A move that ends outside the node's rectangle, read either side of
        # the action, is someone at the mouse (measured 2026-10-05: a 2 px move halted the pilot
        # while Benjamin was at the desk); it is noted, not fatal. No rectangle: still fatal. A
        # zero-area rectangle is the 1 px point it marks, where a simulated click would land (S5:
        # it used to contain nothing, so any move read as someone at the mouse).
        $rects = @(@($r, $r2) | Where-Object { $_ -and $_.PSObject.Properties['Rect'] -and $_.Rect -and @($_.Rect).Count -eq 4 } | ForEach-Object { , @($_.Rect) })
        $onNode = @($rects | Where-Object { $c1[0] -ge $_[0] -and $c1[0] -lt $_[0] + [math]::Max($_[2], 1) -and $c1[1] -ge $_[1] -and $c1[1] -lt $_[1] + [math]::Max($_[3], 1) }).Count -gt 0
        $from = if ($c0) { $c0 -join ',' } else { 'unread' }
        if (-not $rects.Count -or $onNode) {
            throw "SWD-PROBE-CURSOR-MOVED: the MSAA '$Action' on '$(ConvertTo-SwdSafeText $Name 40)' moved the cursor ($from -> $($c1 -join ',')); it simulated input."
        }
        $note = "cursor moved during '$Action' on '$(ConvertTo-SwdSafeText $Name 40)' ($from -> $($c1 -join ',')), away from the node: someone at the mouse"
        Write-Warning $note
        $r2 | Add-Member -NotePropertyName CursorNote -NotePropertyValue $note -Force
    }
    return $r2
}

function Get-SwdProbeDelta {
    <#  One field from Set-SwdGeometry's Deltas, which is a dictionary (live T12); also
        accepts an object. $null when absent, never 0.  #>
    param($Deltas, [Parameter(Mandatory)][string]$Field)
    if ($null -eq $Deltas) { return $null }
    if ($Deltas -is [System.Collections.IDictionary]) { if ($Deltas.Contains($Field)) { return $Deltas[$Field] }; return $null }
    if ($Deltas.PSObject.Properties[$Field]) { return $Deltas.$Field }
    return $null
}

function Get-SwdProbeExpectHandle {
    <#  The group handle plus every control beneath it (pure).  #>
    param([Parameter(Mandatory)]$Controls, [Parameter(Mandatory)][int64]$Group)
    # No @() around the call: Get-SwdDescendant returns ',$out' (one array object), and
    # wrapping it again gave an array holding an array, so the handle cast failed on the
    # first live T12 (2026-09-30).
    $inside = Get-SwdDescendant -Controls $Controls -Handle $Group
    $out = New-Object System.Collections.Generic.List[int64]
    $out.Add($Group)
    foreach ($c in $inside) { $out.Add([int64]$c.Handle) }
    return , $out.ToArray()
}

function Get-SwdProbeLengthContext {
    <#  Resolved geometry panel, current box value, and the handles/rect an Apply Length
        is EXPECTED to touch (the Length group and everything under it).  #>
    param($Origin)
    $controls = @(Get-SwdControl)
    $res = Resolve-SwdGeometryControl -Controls $controls
    if (-not $res.Length -or -not $res.Length.Edit -or -not $res.Length.Apply) { throw "Length controls not resolved: $($res.Missing -join '; ')" }
    [void](Assert-SwdProbeButton -Handle $res.Length.Apply)
    $geo = Get-SwdGeometry -Controls $controls -Resolved $res
    $group = @($controls | Where-Object { [int64]$_.Handle -eq $res.Length.Group })[0]
    $rect = if ($Origin) { ConvertFrom-SwdMapRect -Rect $group.Rect -OriginX $Origin[0] -OriginY $Origin[1] } else { $null }
    return [pscustomobject]@{
        Resolved = $res; Geometry = $geo; LengthMm = $geo.Boxes.Length; LengthText = (Get-SwdText -Handle $res.Length.Edit)
        ExpectHandles = Get-SwdProbeExpectHandle -Controls $controls -Group ([int64]$res.Length.Group)
        ExpectRect = $rect
    }
}

function Set-SwdProbeLength {
    <#  Apply one length through swd_geometry.ps1, then wait for the whole app to settle.  #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][double]$ValueMm, [Parameter(Mandatory)][int64]$Main, [string]$StopFile)
    if ($StopFile) { Assert-SwdProbeContinue -StopFile $StopFile }
    if (-not $PSCmdlet.ShouldProcess("SWD board length", "Apply $ValueMm mm")) { return $null }
    # Re-resolved and re-checked before EVERY click: handles are session-scoped and the
    # caption is the only thing the allowlist trusts.
    $res = Resolve-SwdGeometryControl
    if (-not $res.Length -or -not $res.Length.Apply) { throw "Apply Length not resolved: $($res.Missing -join '; ')" }
    [void](Assert-SwdProbeButton -Handle $res.Length.Apply)
    # Recorded because 'does a click land with SWD in the background' (T10) cannot be
    # answered from runs where SWD happened to be in front.
    # Pass the FOREGROUND window, as every caller in swd_msg.ps1 does. Passing SWD's own
    # handle (first version, 2026-09-30) always answered True and made SWD look focused
    # while the terminal actually held the foreground.
    $p = Get-SwdProcess
    $fg = Test-SwdOwnsForeground -Handle ([int64][SwdWin]::GetForegroundWindow()) -ProcessId $p.Id
    $r = Set-SwdGeometry -Axis Length -Value $ValueMm -Confirm:$false
    $s = Wait-SwdProbeSettle -Handle $Main -StopFile $StopFile
    # Actuation is judged from the label, not from Set-SwdGeometry's Applied: its blocking
    # BM_CLICK times out (1460) on SWD's slow Apply handler and reports 'not transported'
    # for clicks that demonstrably landed (live T12/T13, 2026-09-30).
    $dl = Get-SwdProbeDelta -Deltas $r.Deltas -Field 'LengthMm'
    $moved = if ($null -eq $dl) { $null } else { [math]::Abs([double]$dl) -gt 0 }
    return [pscustomobject]@{ Requested = $ValueMm; Applied = $r.Applied; LengthMoved = $moved; SwdForeground = $fg
                              Reason = $r.Reason; ClickSent = $r.ClickSent
                              ClickLastError = $r.ClickLastError; GeometryMs = $r.ElapsedMs; Deltas = $r.Deltas; Settle = $s }
}

# ---------------------------------------------------------------------------------------
# Probes
# ---------------------------------------------------------------------------------------

function Invoke-SwdProbeSnapshotOnly {
    param([string]$RunDir)
    $s = Get-SwdProbeSnapshot -Dir $RunDir -Label 'snapshot'
    $grid = @($s.Msaa | Where-Object { $_.Name -like 'Moment_yaw*' -or $_.Name -like 'portance_globale*' })
    return [pscustomobject]@{ Win32Controls = @($s.Controls).Count; MsaaNodes = @($s.Msaa).Count; MsaaTruncated = $s.MsaaTruncated
                              Image = $s.Image; ElapsedMs = $s.ElapsedMs
                              GridSample = @($grid | ForEach-Object { "$($_.Name)=$($_.Value)" }) }
}

function Invoke-SwdProbeT9 {
    <#  Write + read back on the Volume TARGET box (entry field; nothing applies without
        Apply Volume), then restore. The diff shows whether the write alone touched
        anything else. It leaves the Apply Volume caption renamed until the board is
        reloaded; swd_geometry.ps1 resolves the renamed caption, so T12-T14 still run, but a
        later T9 on the same board starts from that residue, which BaselineDirty reports.  #>
    param([string]$RunDir, [string]$StopFile)
    $res = Resolve-SwdGeometryControl
    if (-not $res.Volume -or -not $res.Volume.Edit) { throw "Volume target box not resolved: $($res.Missing -join '; ')" }
    $h = [int64]$res.Volume.Edit
    $orig = Get-SwdText -Handle $h
    $n = ConvertTo-SwdNumber -Text $orig
    if (-not $n.Ok) { throw "Volume target box reads '$orig', not a number." }
    $s0 = Get-SwdProbeSnapshot -Dir $RunDir -Label 't9-0-before'
    # The caption BEFORE the write as well (S3): restoring the box does not restore it, so a
    # board whose Volume box was written earlier this session starts already renamed, and
    # LeavesResidue, measured against s0 only, cannot see residue that was there first.
    $capBefore = @($s0.Controls | Where-Object { $_.Class -like '*BUTTON*' -and $_.Parent -eq $res.Volume.Group } |
                   ForEach-Object { $_.Text } | Where-Object { $null -ne $_ })
    Assert-SwdProbeContinue -StopFile $StopFile
    $new = ([double]$n.Value + 1).ToString([Globalization.CultureInfo]::InvariantCulture)
    $w1 = $null; $w2 = $null; $st1 = $null; $s1 = $null
    try {
        $w1 = Set-SwdNumeric -Handle $h -Value $new -Confirm:$false
        $st1 = Wait-SwdProbeSettle -Handle ([int64](Get-SwdProbeMain).Handle) -StopFile $StopFile -TimeoutMs 8000
        $s1 = Get-SwdProbeSnapshot -Dir $RunDir -Label 't9-1-written'
    } finally {
        # Restored whatever happened above; a crash between write and restore left the
        # box at 11 on the first live run (2026-09-30).
        if ((Get-SwdText -Handle $h) -cne $orig) { $w2 = Set-SwdNumeric -Handle $h -Value $orig -Confirm:$false }
    }
    [void](Wait-SwdProbeSettle -Handle ([int64](Get-SwdProbeMain).Handle) -StopFile $StopFile -TimeoutMs 8000)
    $s2 = Get-SwdProbeSnapshot -Dir $RunDir -Label 't9-2-restored'
    $mask = Find-SwdProbeNoiseMask
    $d1 = Compare-SwdProbeSnapshot -Before $s0 -After $s1 -ExpectHandles @($h) -ExpectValues @($orig, $new) -Mask $mask
    $d2 = Compare-SwdProbeSnapshot -Before $s0 -After $s2 -Mask $mask
    return [pscustomobject]@{
        Target = 'Volume target box'; Original = $orig; Written = $new
        WriteOk = $w1.Ok; ReadBack = $w1.After; Culture = $w1.Culture; RestoreOk = $(if ($w2) { $w2.Ok } else { $null }); RestoredTo = $(Get-SwdText -Handle $h)
        SettleAfterWrite = $st1
        WriteDiff = [pscustomobject]@{ InScope = $d1.InScopeCount; OutOfScope = $d1.OutOfScopeCount; Lines = (Format-SwdProbeDiff $d1) }
        RestoreVsOriginal = [pscustomobject]@{ Changes = $d2.OutOfScopeCount; Lines = (Format-SwdProbeDiff $d2) }
        # Measured 2026-09-30: writing this box renames the Apply Volume button to
        # 'Set N liters volume to board', and restoring the box does NOT restore the caption.
        # Only a board reload does. LeavesResidue compares against s0 alone, so it is only
        # a clean-board result when BaselineDirty is $false.
        # $null when a detector failed: an unknown count is not 'no residue' (W2).
        LeavesResidue = $(if ($null -eq $d2.OutOfScopeCount) { $null } else { $d2.OutOfScopeCount -gt 0 })
        ApplyVolumeCaptionBefore = $capBefore
        ApplyVolumeCaption = @(Get-SwdControl | Where-Object { $_.Class -like '*BUTTON*' -and $_.Parent -eq $res.Volume.Group } | ForEach-Object { $_.Text })
        # $true: the renamed caption was already there before this write. $null: no caption
        # was read before it, so a dirty baseline cannot be ruled out.
        BaselineDirty = $(if ($capBefore.Count -eq 0) { $null } else { @($capBefore | Where-Object { $_ -cmatch $script:GeometryAxes['Volume'].ApplyLike }).Count -gt 0 })
    }
}

function Invoke-SwdProbeT11 {
    <#  Tab switch by TCM_SETCURFOCUS (Select-SwdProbeTab), then back. Checks the page really showed.  #>
    param([string]$RunDir, [string]$StopFile)
    $main = Get-SwdProbeMain
    $s0 = Get-SwdProbeSnapshot -Dir $RunDir -Label 't11-0-before'
    $a1 = $null; $a2 = $null; $st1 = $null; $finsShown = $null; $s1 = $null
    try {
        $a1 = Select-SwdProbeTab -Handle $main.Handle -Name 'Fins'
        $st1 = Wait-SwdProbeSettle -Handle $main.Handle -StopFile $StopFile -TimeoutMs 8000
        $finsShown = @(Get-SwdControl | Where-Object { $_.Text -eq 'Fins' -and $_.Visible }).Count -gt 0
        $s1 = Get-SwdProbeSnapshot -Dir $RunDir -Label 't11-1-fins'
    } finally {
        $a2 = Select-SwdProbeTab -Handle $main.Handle -Name 'Shape'
    }
    [void](Wait-SwdProbeSettle -Handle $main.Handle -StopFile $StopFile -TimeoutMs 8000)
    $s2 = Get-SwdProbeSnapshot -Dir $RunDir -Label 't11-2-back'
    $mask = Find-SwdProbeNoiseMask
    $d1 = Compare-SwdProbeSnapshot -Before $s0 -After $s1 -Mask $mask
    $d2 = Compare-SwdProbeSnapshot -Before $s0 -After $s2 -Mask $mask
    return [pscustomobject]@{
        SelectFins = $a1; FinsPageVisible = $finsShown; Settle = $st1; SelectShape = $a2
        SwitchChanges = [pscustomobject]@{ Visible = $d1.OutOfScopeCount; HiddenStructural = $d1.HiddenStructural; ImageBoxes = @($d1.OutOfScope.ImageBoxes).Count }
        BackVsOriginal = [pscustomobject]@{ Changes = $d2.OutOfScopeCount; HiddenStructural = $d2.HiddenStructural; Lines = (Format-SwdProbeDiff $d2) }
    }
}

function Invoke-SwdProbeT12 {
    <#  Reset fidelity by round trip: Length +Delta, then back to the original text.  #>
    param([string]$RunDir, [string]$StopFile, [double]$DeltaMm)
    $main = Get-SwdProbeMain
    $s0 = Get-SwdProbeSnapshot -Dir $RunDir -Label 't12-0-before'
    $ctx = Get-SwdProbeLengthContext -Origin $s0.Origin
    $orig = [double]$ctx.LengthMm
    $up = $null; $down = $null; $s1 = $null
    try {
        $up = Set-SwdProbeLength -ValueMm ($orig + $DeltaMm) -Main $main.Handle -StopFile $StopFile
        $s1 = Get-SwdProbeSnapshot -Dir $RunDir -Label 't12-1-changed'
    } finally {
        $down = Set-SwdProbeLength -ValueMm $orig -Main $main.Handle
    }
    $s2 = Get-SwdProbeSnapshot -Dir $RunDir -Label 't12-2-restored'
    $mask = Find-SwdProbeNoiseMask
    $d = Compare-SwdProbeSnapshot -Before $s0 -After $s2 -Mask $mask
    return [pscustomobject]@{
        OriginalMm = $orig; Up = $up; Down = $down
        Exact = $(if ($null -eq $d.OutOfScopeCount) { $null } else { $d.OutOfScopeCount -eq 0 }); Residual = $d.OutOfScopeCount; Lines = (Format-SwdProbeDiff $d 40)
        TitleBefore = $s0.Title; TitleChanged = $(if ($s1) { $s1.Title } else { $null }); TitleAfter = $s2.Title
    }
}

function Invoke-SwdProbeT13 {
    <#  Settle distribution over repeated Apply Length clicks (alternating +Delta / back).  #>
    param([string]$RunDir, [string]$StopFile, [double]$DeltaMm, [int]$Repeats)
    $main = Get-SwdProbeMain
    $ctx = Get-SwdProbeLengthContext
    $orig = [double]$ctx.LengthMm
    $rows = @()
    try {
        for ($i = 0; $i -lt $Repeats; $i++) {
            $target = if ($i % 2 -eq 0) { $orig + $DeltaMm } else { $orig }
            $r = Set-SwdProbeLength -ValueMm $target -Main $main.Handle -StopFile $StopFile
            $rows += [pscustomobject]@{ I = $i; Target = $target; Applied = $r.Applied; GeometryMs = $r.GeometryMs
                                        SettleMs = $r.Settle.SettleMs; TimedOut = $r.Settle.TimedOut
                                        FirstResponsiveMs = $r.Settle.FirstResponsiveMs; FirstCpuQuietMs = $r.Settle.FirstCpuQuietMs
                                        FirstFramesStableMs = $r.Settle.FirstFramesStableMs; MaxCpuPct = $r.Settle.MaxCpuPct }
        }
    } finally {
        $now = (Get-SwdProbeLengthContext).LengthMm
        if ([math]::Abs([double]$now - $orig) -gt 1e-6) { [void](Set-SwdProbeLength -ValueMm $orig -Main $main.Handle) }
    }
    $csv = $rows | ConvertTo-Csv -NoTypeInformation
    [IO.File]::WriteAllText((Join-Path $RunDir 't13-settle.csv'), ($csv -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding $false))
    $ms = @($rows | Where-Object { -not $_.TimedOut } | ForEach-Object { $_.SettleMs })
    $stat = $ms | Measure-Object -Minimum -Maximum -Average
    return [pscustomobject]@{ Clicks = $rows.Count; AppliedCount = @($rows | Where-Object Applied).Count
                              TimedOut = @($rows | Where-Object TimedOut).Count
                              SettleMinMs = $stat.Minimum; SettleMeanMs = [math]::Round([double]$stat.Average, 0); SettleMaxMs = $stat.Maximum
                              Rows = $rows }
}

function Invoke-SwdProbeT14 {
    <#  Detector controls. Negative: a null action (wait) must show nothing beyond noise,
        and what it does show becomes the volatility set. Positive: Apply Length, declared
        as touching only the Length group, must surface its known distant effects
        (Width/Volume/labels/title/3D view) as OUT-OF-SCOPE. Each twice; restored after.  #>
    param([string]$RunDir, [string]$StopFile, [double]$DeltaMm)
    $main = Get-SwdProbeMain
    $mask = Find-SwdProbeNoiseMask
    $neg = @(); $pos = @()
    $s0 = Get-SwdProbeSnapshot -Dir $RunDir -Label 't14-neg-0'
    $ctx = Get-SwdProbeLengthContext -Origin $s0.Origin
    $orig = [double]$ctx.LengthMm
    $ignore = @{}
    try {
        foreach ($k in 1, 2) {
            Assert-SwdProbeContinue -StopFile $StopFile
            Start-Sleep -Seconds 3
            $s1 = Get-SwdProbeSnapshot -Dir $RunDir -Label "t14-neg-$k"
            $d = Compare-SwdProbeSnapshot -Before $s0 -After $s1 -Mask $mask
            foreach ($kv in (Get-SwdProbeVolatility -MsaaDiff $d.Msaa -Win32Diff $d.Win32).GetEnumerator()) { $ignore[$kv.Key] = $true }
            $neg += [pscustomobject]@{ Run = $k; Win32 = @($d.Win32).Count; Msaa = @($d.Msaa).Count
                                       ImageBoxes = @($d.OutOfScope.ImageBoxes).Count; ImageError = $d.ImageError; Lines = (Format-SwdProbeDiff $d) }
            $s0 = $s1
        }
        foreach ($k in 1, 2) {
            $b = Get-SwdProbeSnapshot -Dir $RunDir -Label "t14-pos-$k-before"
            $newText = ($orig + $DeltaMm).ToString([Globalization.CultureInfo]::InvariantCulture)
            $act = Set-SwdProbeLength -ValueMm ($orig + $DeltaMm) -Main $main.Handle -StopFile $StopFile
            $a = Get-SwdProbeSnapshot -Dir $RunDir -Label "t14-pos-$k-after"
            $d = Compare-SwdProbeSnapshot -Before $b -After $a -ExpectHandles $ctx.ExpectHandles `
                    -ExpectValues @($ctx.LengthText, $newText) -ExpectRects @(, $ctx.ExpectRect) -Ignore $ignore -Mask $mask
            $pos += [pscustomobject]@{ Run = $k; Applied = $act.Applied; SettleMs = $act.Settle.SettleMs
                                       InScope = $d.InScopeCount; OutOfScope = $d.OutOfScopeCount
                                       OutWin32 = @($d.OutOfScope.Win32).Count; OutMsaa = @($d.OutOfScope.Msaa).Count
                                       OutImageBoxes = @($d.OutOfScope.ImageBoxes).Count; Lines = (Format-SwdProbeDiff $d 40) }
            [void](Set-SwdProbeLength -ValueMm $orig -Main $main.Handle -StopFile $StopFile)
        }
    } finally {
        $now = (Get-SwdProbeLengthContext).LengthMm
        if ([math]::Abs([double]$now - $orig) -gt 1e-6) { [void](Set-SwdProbeLength -ValueMm $orig -Main $main.Handle) }
    }
    # Both verdicts are $null when an image detector failed: a control that could not be
    # measured has neither passed nor failed (W2).
    $failed = @($neg | Where-Object { $_.ImageError }).Count + @($pos | Where-Object { $null -eq $_.OutOfScope }).Count
    return [pscustomobject]@{ Negative = $neg; Positive = $pos; VolatileKeys = $ignore.Count
                              NegativeClean = $(if ($failed) { $null } else { @($neg | Where-Object { $_.Win32 + $_.Msaa + $_.ImageBoxes -gt 0 }).Count -eq 0 })
                              PositiveDetected = $(if ($failed) { $null } else { @($pos | Where-Object { $_.OutOfScope -gt 0 }).Count -eq $pos.Count }) }
}

function Invoke-SwdProbeT17 {
    <#  Kill switch on a dummy loop: the stop file appears during step 3; the loop must
        stop before step 4. Touches no SWD control.  #>
    param([string]$RunDir)
    $stop = Join-Path $RunDir 'STOP-t17-test'
    if (Test-Path -LiteralPath $stop) { Remove-Item -LiteralPath $stop -Force }
    try {
        $r = Invoke-SwdProbeStopLoop -StopFile $stop -Iterations 10 -Step { param($i) if ($i -eq 2) { New-Item -ItemType File -Path $stop -Force | Out-Null } }
    } finally { if (Test-Path -LiteralPath $stop) { Remove-Item -LiteralPath $stop -Force } }
    return [pscustomobject]@{ Completed = $r.Completed; Stopped = $r.Stopped; Reason = $r.Reason; Pass = ($r.Stopped -and $r.Completed -eq 3) }
}

# ---------------------------------------------------------------------------------------
# Input sweep (2026-10-01): change every user-editable input, record which outputs move
# ---------------------------------------------------------------------------------------
# Owner override 2026-09-30 (AI-USE.md section 4) extended by Benjamin's 2026-10-01 prompt:
# written, run live overnight, light-touch fixes allowed, SQA pass after. Hydrodynamics
# Scanner stays denylisted; nothing here can reach it (the button allowlist is unchanged
# apart from the anchored volume-caption pattern).
#
# Two modes, because Board Dynamics changes what SWD shows (measured 2026-10-01):
#   S  Board Dynamics OFF: shaping tabs (SizeConfig, Shape > Guides Sections ...).
#   D  Board Dynamics ON: 'Dynamics on, Shaping function are unabled'. Test Position (flow ms,
#      Slope, Apply situation), the board's Dynamics rows in the Project property grid, Fins,
#      Dashboard, and the Elements;analysis grid of the selected hydro element.
# Each trial: snapshot, set, apply (if paired), settle, snapshot, restore, settle, snapshot.

$script:SweepExe = 'C:\Program Files\ShaperWaveDynamics\ShaperWaveDynamics\SurfHydrodynamics.exe'
# Never swept, by designer name: free-text boxes (a description, a fin's name and notes).
$script:SweepSkipIds = @('TextBox_description_project_object_select', 'TextBox_nom_aileron', 'TextBox_infos_fin')
# Grid rows never written: 'Nom' renames the board (the _Copy guard reads the name); 'infos' is free text.
$script:SweepGridSkip = @('Nom', 'infos')
# Inputs a write cannot undo, restored ONLY by a relaunch (W2, SQA 2026-10-06). The volume box is a
# TARGET: 'Apply Volume' resizes the board to whatever it holds, so typing the old target back (10)
# resized a 34 L board to 10 L (AI-USE.md E109). The Map loop relaunches after every such trial.
$script:SweepRestoreByRelaunch = @('NumericUpDownBoardVolumeInput')
# The only buttons the sweep presses on a dialog it did not expect; each declines or cancels.
# Preference order: cancel what was asked, then decline it, then close. 'Yes' is never pressed,
# with ONE exception below.
# The one dialog 'Yes' may answer (Benjamin, 2026-10-06, AI-USE.md section 4: "You can press yes for
# this, it is about switching Board Dyanmics on"): selecting a scan position with Board Dynamics OFF
# asks to switch it on. Matched EXACTLY - title, every text, and buttons exactly Yes + No - after
# ConvertTo-SwdProbeLabel, so no other dialog, rewording or extra button can borrow it.
$script:SweepDialogYesAllowed = @(
    @{ Title = 'Dynamics is off'; Text = 'Switch Dynamics On to show elements details ?' }
)
$script:SweepDialogSafeButtons = @('Cancel', 'Annuler', 'No', 'Non', 'Close', 'Fermer')
# Top-level SWD windows that are not dialogs: the splash and the Board Dynamics notice close themselves.
$script:SweepTransientLike = @('Loading ShaperWaveDynamics*', 'Dynamics on*', 'Dynamics off*')

function Format-SwdSweepNumber {
    <#  A sweep value as plain decimal text (pure): 6 significant digits as G6 gave, but never an
        exponent (S2: G6 typed '9.17912E-07' into a grid row on 2026-10-01), and NaN or an infinity
        throws, because nothing may type one into SWD.  #>
    param([double]$Value)
    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { throw "Refusing to format '$Value' as a sweep value." }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    return ([double]::Parse($Value.ToString('G6', $inv), $inv)).ToString('0.###############', $inv)
}

function Test-SwdSweepFinite { param([double]$Value) return -not ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) }

function Get-SwdSweepValue {
    <#  Test values for one input (pure). numeric: base +10% and -10%, or +1 and -1 from zero,
        clamped to a known range and never the base itself. bool: the other value. toggle:
        'toggle'. Index kinds (combo, slider, radio) pick from -Options, never the base.  #>
    param([Parameter(Mandatory)][string]$Kind, [AllowNull()][string]$Base, $Min = $null, $Max = $null,
          [object[]]$Options = @(), [int]$MaxOptions = 6)
    switch ($Kind) {
        'numeric' {
            $n = ConvertTo-SwdNumber -Text $Base
            # A box reading 'NaN' or 'Infinity' parses as a double; it is not a base to sweep around (S2).
            if (-not $n.Ok -or -not (Test-SwdSweepFinite $n.Value)) { return }
            $b = [double]$n.Value
            # Parenthesised: PowerShell's comma binds tighter than '*', so '$b * 1.1, $b * 0.9'
            # multiplies by an array (measured: op_Multiply on Object[]).
            $cand = if ($b -eq 0) { @(1.0, -1.0) } else { @(($b * 1.1), ($b * 0.9)) }
            $out = @()
            foreach ($c in $cand) {
                if ($null -ne $Min -and $c -lt [double]$Min) { $c = [double]$Min }
                if ($null -ne $Max -and $c -gt [double]$Max) { $c = [double]$Max }
                if (-not (Test-SwdSweepFinite $c)) { continue }
                $s = Format-SwdSweepNumber $c
                if ($c -ne $b -and $out -notcontains $s) { $out += $s }
            }
            return $out
        }
        'bool' { if ($Base -eq 'True') { return 'False' }; if ($Base -eq 'False') { return 'True' }; return }
        'check' { return 'toggle' }
        default { return @(@($Options | Where-Object { "$_" -ne "$Base" }) | Select-Object -First $MaxOptions) }
    }
}

function Get-SwdSweepCurveLevel {
    <#  Pass-2 ladder around a numeric base (pure): x0.5 .. x1.5, or -3 .. +3 from zero,
        clamped, deduplicated, ascending, base excluded (it is measured separately).  #>
    param([Parameter(Mandatory)][double]$Base, $Min = $null, $Max = $null, [double[]]$Factors = @(0.5, 0.75, 0.9, 1.1, 1.25, 1.5))
    $cand = if ($Base -eq 0) { @(-3, -2, -1, 1, 2, 3) | ForEach-Object { [double]$_ } } else { @($Factors) | ForEach-Object { $Base * $_ } }
    $vals = @()
    foreach ($c in $cand) {
        if ($null -ne $Min -and $c -lt [double]$Min) { $c = [double]$Min }
        if ($null -ne $Max -and $c -gt [double]$Max) { $c = [double]$Max }
        if ((Test-SwdSweepFinite $c) -and $c -ne $Base -and $vals -notcontains $c) { $vals += $c }
    }
    return @($vals | Sort-Object | ForEach-Object { Format-SwdSweepNumber $_ })
}

function Select-SwdSweepDialogAction {
    <#  The button to press on a dialog the sweep did not expect, or $null to stop (pure).
        Cancel / No / Close (and French) first: each declines what the dialog asks. A dialog
        whose ONLY button is OK is acknowledged when nothing it says is on the denylist (an
        information box). 'Yes' is pressed only on the exact dialogs in
        $script:SweepDialogYesAllowed (switching Board Dynamics on); anything else stops the run.  #>
    param([AllowNull()][string]$Title, [string[]]$Texts = @(), [string[]]$Buttons = @(), [string[]]$Order = $script:SweepDialogSafeButtons)
    $labels = @(@($Buttons) | ForEach-Object { ConvertTo-SwdProbeLabel $_ } | Where-Object { $_ })
    # Checked before the decline order, which would otherwise pick No first.
    $title = ConvertTo-SwdProbeLabel $Title
    $text = ConvertTo-SwdProbeLabel ((@($Texts) | Where-Object { $_ }) -join ' ')
    $yesNo = ($labels.Count -eq 2 -and @($labels | Where-Object { [string]::Equals($_, 'Yes', [StringComparison]::Ordinal) }).Count -eq 1 -and
              @($labels | Where-Object { [string]::Equals($_, 'No', [StringComparison]::Ordinal) }).Count -eq 1)
    foreach ($a in $script:SweepDialogYesAllowed) {
        if ($yesNo -and [string]::Equals($title, $a.Title, [StringComparison]::Ordinal) -and [string]::Equals($text, $a.Text, [StringComparison]::Ordinal)) { return 'Yes' }
    }
    # -Order may only reorder the safe set, never add to it.
    foreach ($want in @($Order | Where-Object { $script:SweepDialogSafeButtons -contains $_ })) {
        foreach ($l in $labels) { if ([string]::Equals($l, $want, [StringComparison]::OrdinalIgnoreCase)) { return $l } }
    }
    if ($labels.Count -eq 1 -and [string]::Equals($labels[0], 'OK', [StringComparison]::OrdinalIgnoreCase)) {
        $all = ConvertTo-SwdProbeLabel ((@($Title) + @($Texts)) -join ' ')
        if (-not (Get-SwdProbeDenyMatch $all)) { return 'OK' }
    }
    return $null
}

function ConvertTo-SwdSweepInput {
    <#  Sweep inputs from swd_uia3.py census rows of ONE mode (pure). One record per input:
        Id, Mode, TabPath, Kind (numeric | combo | slider | radio | check), Target (designer
        name), Label, Apply (designer name of an allowlisted button in an enclosing container,
        deepest wins, else $null), Options (radio: the group's designer names), Min, Max.
        Left out: disabled or part-of controls, unnamed ones (a numeric AutomationId mirrors
        the HWND and cannot be found again after a relaunch), skip-listed ids, free text.  #>
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Rows, [Parameter(Mandatory)][string]$Mode)
    $rows = @($Rows)
    $prop = { param($o, $n) if ($o.PSObject.Properties[$n]) { $o.$n } else { $null } }
    $buttons = @($rows | Where-Object { $_.Kind -eq 'button' -and $_.AutomationId -and $_.AutomationId -notmatch '^\d+$' -and (Test-SwdProbeAllowedButton $_.Name) })
    $out = New-Object System.Collections.Generic.List[object]
    $radios = [ordered]@{}
    foreach ($r in $rows) {
        if ("$($r.Kind)" -notlike 'input:*') { continue }
        $sp = & $prop $r 'SpinnerOf'
        $aid = if ($sp) { $sp } else { "$($r.AutomationId)" }
        if (-not $aid -or $aid -match '^\d+$' -or $script:SweepSkipIds -contains $aid) { continue }
        $kind = switch ($r.Kind) { 'input:numeric' { 'numeric' } 'input:text' { 'numeric' } 'input:combo' { 'combo' }
                                   'input:slider' { 'slider' } 'input:toggle' { if ($r.Type -eq 'RadioButton') { 'radio' } else { 'check' } } }
        if ($r.Kind -eq 'input:text' -and -not (ConvertTo-SwdNumber -Text "$(& $prop $r 'Value')").Ok) { continue }
        $apply = $null; $best = -1
        foreach ($b in $buttons) {
            $bp = "$($b.Parents)/"
            if ("$($r.Parents)/".StartsWith($bp, [StringComparison]::Ordinal) -and $bp.Length -gt $best) { $apply = $b.AutomationId; $best = $bp.Length }
        }
        $range = & $prop $r 'SpinnerRange'; if (-not $range) { $range = & $prop $r 'Range' }
        $min = if ($range) { & $prop $range 'Min' } else { $null }; $max = if ($range) { & $prop $range 'Max' } else { $null }
        if ($kind -eq 'radio') {
            $g = "$Mode|$($r.Parents)"
            if (-not $radios.Contains($g)) {
                $radios[$g] = [pscustomobject]@{ Id = "$Mode/radio:$($r.Parents.Split('/')[-1])"; Mode = $Mode; TabPath = $r.TabPath; Kind = 'radio'
                                                  Target = $aid; Label = "$($r.Name)"; Apply = $apply; Options = @(); Min = $null; Max = $null }
                $out.Add($radios[$g])
            }
            $radios[$g].Options += $aid
            $radios[$g].Label = (@($radios[$g].Label, "$($r.Name)") | Where-Object { $_ }) -join ' / '
            continue
        }
        $out.Add([pscustomobject]@{ Id = "$Mode/$aid"; Mode = $Mode; TabPath = $r.TabPath; Kind = $kind; Target = $aid
                                    Label = "$($r.Name)"; Apply = $apply; Options = @(); Min = $min; Max = $max })
    }
    # A group of one radio button has nothing to switch to.
    return @($out.ToArray() | Where-Object { $_.Kind -ne 'radio' -or @($_.Options).Count -ge 2 })
}

function Get-SwdSweepTabStep {
    <#  The allowlisted tabs to select, outermost first, for an input's TabPath (pure).
        Tab pages that are not on the allowlist are left as they are.  #>
    param([AllowNull()][string]$TabPath)
    if (-not $TabPath) { return }
    return @($TabPath.Split('|') | ForEach-Object { ConvertTo-SwdProbeLabel $_ } | Where-Object { $_ -and (Test-SwdProbeAllowedTab $_) })
}

function Get-SwdSweepChangeKey {
    <#  The keys of a trial's changes, for comparing repeats and finding residue (pure).  #>
    param($Changes)
    return @(@($Changes) | Where-Object { $null -ne $_ } | ForEach-Object { "$($_.Ch)|$($_.Owner)|$($_.Item)|$($_.Field)" } | Sort-Object -Unique)
}

function Assert-SwdProbeToggle {
    <#  A radio button or check box may be clicked only when MSAA says it IS one (role 44 or
        45). The window style cannot tell: every WinForms FlatStyle=Standard button reports
        BS_OWNERDRAW (swd_msg.ps1, measured 2026-08-28). The caption must clear the denylist.  #>
    param([Parameter(Mandatory)][int64]$Handle,
          [scriptblock]$Reader = { param($h) $n = @([SwdProbeNative]::Walk([intptr]$h, 2, 3000)); if ($n.Count) { $n[0] } })
    $n = & $Reader $Handle
    if (-not $n -or @('44', '45') -notcontains "$($n.Role)") {
        throw "Refusing to click handle ${Handle}: MSAA role '$(if ($n) { $n.Role })' is not a check box or radio button."
    }
    if (Get-SwdProbeDenyMatch (ConvertTo-SwdProbeLabel $n.Name)) { throw "Refusing to click toggle '$(ConvertTo-SwdSafeText $n.Name 40)': denylisted caption." }
    return $n
}

function Assert-SwdProbeClass {
    <#  Throws unless HANDLE is a live SurfHydrodynamics window whose class is LIKE (S8). The native
        list, combo and trackbar senders answer a BUTTON with 0, which reads as success, and a
        recycled handle would take the messages meant for the control the census named.  #>
    param([Parameter(Mandatory)][int64]$Handle, [Parameter(Mandatory)][string]$Like, [string]$What = 'control')
    if (-not (Test-SwdHandle -Handle $Handle)) { throw "The $What handle $Handle is not a live SurfHydrodynamics window. Refusing." }
    $sb = New-Object System.Text.StringBuilder 256
    [void][SwdWin]::GetClassName([intptr]$Handle, $sb, 256)
    if ($sb.ToString() -notlike $Like) { throw "The $What handle $Handle is class '$($sb.ToString())', not $Like. Refusing." }
}

# ---- live: app lifecycle, mode, view ------------------------------------------------------

function Get-SwdSweepPid {
    <#  The id of the one running SurfHydrodynamics process, or 0 (none, or more than one). Never throws.  #>
    $p = @(Get-Process SurfHydrodynamics -ErrorAction SilentlyContinue)
    if ($p.Count -eq 1) { return [int64]$p[0].Id }
    return [int64]0
}

function Get-SwdSweepTopWindows {
    <#  Visible top-level windows of the SWD process: Handle, Title, IsMain.  #>
    $p = Get-Process SurfHydrodynamics -ErrorAction SilentlyContinue
    if (-not $p -or $p -is [array]) { return }
    foreach ($line in [SwdWin]::TopLevelForPid($p.Id)) {
        $f = $line -split ([regex]::Escape([SwdWin]::SEP))
        if ($f.Count -ne [SwdWin]::TOPLEVEL_FIELDS -or $f[2] -ne 'True') { continue }
        $t = [SwdWin]::GetText([intptr][int64]$f[0], 2000)
        [pscustomobject]@{ Handle = [int64]$f[0]; Title = $t; IsMain = [bool]($t -and $t -like 'FYN Shaper Wave Dynamics*') }
    }
}

function Clear-SwdSweepPopup {
    <#  Waits out SWD's self-closing notices, then answers any dialog still up with the one
        button Select-SwdSweepDialogAction allows, or throws SWD-SWEEP-DIALOG. Returns a log
        line per dialog handled. -StopFile: the kill switch, checked on every pass of the wait
        and before every press (W3); Stop-SwdSweepApp leaves it out on purpose.  #>
    param([int]$TransientMs = 12000, [string[]]$Order = $script:SweepDialogSafeButtons, [string]$StopFile)
    $log = @()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if (-not (Test-Path variable:script:SweepKnownWindows)) { $script:SweepKnownWindows = @{} }
    while ($true) {
        if ($StopFile) { Assert-SwdProbeContinue -StopFile $StopFile }
        $pops = @(Get-SwdSweepTopWindows | Where-Object { -not $_.IsMain -and -not $script:SweepKnownWindows.ContainsKey([int64]$_.Handle) })
        if ($pops.Count -eq 0) { return $log }
        $real = @($pops | Where-Object { $t = "$($_.Title)"; -not @($script:SweepTransientLike | Where-Object { $t -like $_ }).Count })
        if ($real.Count -eq 0 -and $sw.ElapsedMilliseconds -lt 60000) { Start-Sleep -Milliseconds 500; continue }
        if ($sw.ElapsedMilliseconds -lt $TransientMs) { Start-Sleep -Milliseconds 500; continue }
        foreach ($d in $pops) {
            $kids = @(Get-SwdDialogControl -Handle $d.Handle -TimeoutMs 2000 -DeadlineMs 10000)
            $btns = @($kids | Where-Object { $_.Class -like '*BUTTON*' -and $_.Visible -and $_.Enabled -and $_.Text } | ForEach-Object { $_.Text })
            $texts = @($kids | Where-Object { $_.Class -notlike '*BUTTON*' -and $_.Text } | ForEach-Object { $_.Text })
            $line = "dialog '$(ConvertTo-SwdSafeText $d.Title 60)' [$(($texts | ForEach-Object { ConvertTo-SwdSafeText $_ 60 }) -join ' / ')] buttons [$($btns -join ', ')]"
            # A window with no button at all is not a dialog (a modal always offers one): a
            # floating panel or a notice that outlived the wait. Recorded and left alone.
            if ($btns.Count -eq 0) { $script:SweepKnownWindows[[int64]$d.Handle] = "$($d.Title)"; $log += "$line -> no buttons; ignored as a non-dialog window"; continue }
            $act = Select-SwdSweepDialogAction -Title $d.Title -Texts $texts -Buttons $btns -Order $Order
            if (-not $act) { throw "SWD-SWEEP-DIALOG: $line offers no safe button; stopping." }
            if ($StopFile) { Assert-SwdProbeContinue -StopFile $StopFile }
            $expect = if ($d.Title) { [Management.Automation.WildcardPattern]::Escape($d.Title) + '*' } else { $null }
            $r = if ($expect) { Invoke-SwdDialogButton -DialogHandle $d.Handle -ExpectLike $expect -ButtonLike ([Management.Automation.WildcardPattern]::Escape($act)) -Post -Confirm:$false } else { $null }
            if (-not $r -or -not $r.Attempted) { throw "SWD-SWEEP-DIALOG: $line - pressing '$act' was refused ($(if ($r) { $r.Reason } else { 'untitled dialog' }))." }
            $gone = Wait-SwdDialogGone -Handle $d.Handle -TimeoutMs 15000
            $log += "$line -> pressed '$act' (gone=$gone)"
            if (-not $gone) { throw "SWD-SWEEP-DIALOG: $line stayed up after '$act'." }
        }
        $sw.Restart()
    }
}

function Get-SwdSweepMode {
    <#  'D' when the Test Position page tab exists (Board Dynamics ON), else 'S'.  #>
    param([Parameter(Mandatory)][int64]$Handle)
    $r = [SwdProbeNative]::Act([intptr]$Handle, 'Test Position', '37', 0, 'read', $null, 6000, 20000)
    if ($r.Status -eq 'ok') { return 'D' }
    return 'S'
}

function Switch-SwdSweepMode {
    <#  Toggle Board Dynamics until the app is in -Mode. $true when it switched.  #>
    param([Parameter(Mandatory)][ValidateSet('S', 'D')][string]$Mode, [string]$StopFile)
    $m = Get-SwdProbeMain
    if ((Get-SwdSweepMode $m.Handle) -eq $Mode) { return $false }
    [void](Invoke-SwdProbeAcc -Handle $m.Handle -Name 'Board Dynamics' -Action default -StopFile $StopFile)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 30000) {
        Start-Sleep -Milliseconds 1000
        [void](Clear-SwdSweepPopup -StopFile $StopFile)
        $m = Get-SwdProbeMain
        if ((Get-SwdSweepMode $m.Handle) -eq $Mode) {
            [void](Wait-SwdProbeSettle -Handle $m.Handle -TimeoutMs 20000 -StopFile $StopFile)
            return $true
        }
    }
    throw "Board Dynamics did not put SWD in mode $Mode within 30 s."
}

function Find-SwdSweepTree {
    <#  HWND of the tree in the census whose designer name or tab is given. 0 when absent.  #>
    param([Parameter(Mandatory)]$Rows, [string]$AutomationId, [string]$Tab)
    $t = @(@($Rows) | Where-Object { $_.Type -eq 'Tree' -and $_.Hwnd -and (($AutomationId -and $_.AutomationId -eq $AutomationId) -or ($Tab -and $_.Tab -eq $Tab)) })
    if ($t.Count) { return [int64]$t[0].Hwnd }
    return 0
}

function Select-SwdSweepTreeItem {
    <#  Select the first visible tree item under Tree for which Pick is true. Tree items are
        MSAA simple children (role 36); the MSAA tree proxy does the selection, no cursor.  #>
    param([Parameter(Mandatory)][int64]$Tree, [Parameter(Mandatory)][scriptblock]$Pick, [string]$StopFile)
    $nodes = @([SwdProbeNative]::Walk([intptr]$Tree, 3000, 10000) | Where-Object { $_.Role -eq '36' -and -not $_.Hidden })
    $n = @($nodes | Where-Object { & $Pick $_ })
    if (-not $n.Count) { return $null }
    return (Invoke-SwdProbeAcc -Handle $Tree -Name $n[0].Name -Action select -AllowAmbiguous -StopFile $StopFile)
}

function Initialize-SwdSweepView {
    <#  The observation view for a mode: Project tree on the board (its property grid shows
        the Dynamics rows in D), and in D the Elements;analysis grid filled by selecting the
        current hydro element. Returns what it could set up; a grid that will not fill is
        reported, not fatal (the run continues without that channel).  #>
    param([Parameter(Mandatory)][string]$Mode, [Parameter(Mandatory)]$Ctx)
    $m = Get-SwdProbeMain
    $board = Get-SwdProbeBoardName $m.Title
    $rows = @($Ctx.Census.$Mode)
    $proj = Find-SwdSweepTree -Rows $rows -Tab 'Project'
    $out = [ordered]@{ Board = $null; Element = $null; GridCells = $null }
    if ($proj) {
        $r = Select-SwdSweepTreeItem -Tree $proj -Pick { param($n) $n.Name -eq "Board: $board" } -StopFile $Ctx.StopFile
        $out.Board = if ($r) { $r.Status } else { 'not-found' }
    }
    if ($Mode -eq 'D') {
        # A STOP is rethrown, never written down as a view note (W3).
        try { [void](Select-SwdProbeTab -Handle $m.Handle -Name 'Elements analysis' -StopFile $Ctx.StopFile) } catch {
            if ($_.Exception.Message -like 'SWD-*') { throw }
            $out.Element = "tab: $($_.Exception.Message)"
        }
        $el = Find-SwdSweepTree -Rows $rows -AutomationId 'TreeView_ActualElements'
        if ($el) {
            $r = Select-SwdSweepTreeItem -Tree $el -Pick { param($n) $n.Name -like 'Drift*' } -StopFile $Ctx.StopFile
            if (-not $out.Element) { $out.Element = if ($r) { $r.Status } else { 'not-found' } }
        }
        [void](Wait-SwdProbeSettle -Handle $m.Handle -TimeoutMs 15000 -StopFile $Ctx.StopFile)
        $cells = @((Get-SwdMsaaSnapshot -Handle $m.Handle).Nodes | Where-Object { $_.Role -eq '29' -and -not $_.Hidden })
        $out.GridCells = $cells.Count
    }
    return [pscustomobject]$out
}

function Start-SwdSweepApp {
    <#  Launch SWD and wait for its main window and the board it opens to read as a copy.
        -StopFile: the kill switch, checked before the launch and on every poll (W3): a STOP used
        to wait out the whole launch, its popups and its settle.  #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$ExpectBoard, [int]$TimeoutMs = 180000, [string]$StopFile)
    if (Get-Process SurfHydrodynamics -ErrorAction SilentlyContinue) { throw 'SWD is already running.' }
    if ($StopFile) { Assert-SwdProbeContinue -StopFile $StopFile }
    if (-not $PSCmdlet.ShouldProcess('ShaperWaveDynamics', 'launch')) { return $null }
    $exe = $script:SweepExe
    [void](Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) -PassThru)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        Start-Sleep -Seconds 3
        if ($StopFile) { Assert-SwdProbeContinue -StopFile $StopFile }
        $tops = @(Get-SwdSweepTopWindows)
        $main = @($tops | Where-Object IsMain)
        $splash = @($tops | Where-Object { "$($_.Title)" -like 'Loading ShaperWaveDynamics*' })
        if ($main.Count -eq 1 -and $splash.Count -eq 0) {
            [void](Clear-SwdSweepPopup -StopFile $StopFile)
            $m = Get-SwdProbeMain
            $board = Assert-SwdProbeBoard -Title $m.Title
            if ($ExpectBoard -and $board -ne $ExpectBoard) { throw "SWD-SWEEP-BOARD: SWD opened '$board', not '$ExpectBoard'." }
            [void](Wait-SwdProbeSettle -Handle $m.Handle -TimeoutMs 30000 -StopFile $StopFile)
            return $board
        }
    }
    throw "SWD did not show its main window within $([int]($TimeoutMs / 1000)) s."
}

function Invoke-SwdSweepWarmup {
    <#  One Apply Length round trip (+1 mm, back) per SWD session. The first Apply of a
        session switches the 3D camera to a top view and fills four empty fields, and only the
        first (T12, 2026-09-30): absorbed here so no trial's restore reads it as residue.  #>
    param([Parameter(Mandatory)]$Ctx)
    $p = Get-SwdProcess
    if ($Ctx.WarmPid -eq $p.Id) { return 'already warm' }
    # Shaping is disabled with Board Dynamics ON (measured: the Length EDIT reads disabled).
    [void](Switch-SwdSweepMode -Mode 'S' -StopFile $Ctx.StopFile)
    $m = Get-SwdProbeMain
    $len = [double](Get-SwdProbeLengthContext).LengthMm
    [void](Set-SwdProbeLength -ValueMm ($len + 1) -Main $m.Handle -StopFile $Ctx.StopFile)
    [void](Set-SwdProbeLength -ValueMm $len -Main $m.Handle -StopFile $Ctx.StopFile)
    $Ctx.WarmPid = $p.Id
    $Ctx.ModeNow = $null; $Ctx.TabNow = $null; $Ctx.ViewMode = $null
    return "warmed pid $($p.Id) at $len mm"
}

function Stop-SwdSweepApp {
    <#  Close SWD: WM_CLOSE to the main window, dialogs answered by the safe policy, then a
        forced stop only if it has not exited after 60 s (hung, or a quit prompt the policy
        declined). In-memory edits are discarded either way: SWD saves a board only on a scan.
        NOT gated by the kill switch, on purpose (W3): like T12's restore, closing is what puts
        a board an unfinished trial changed back to the file on disk, and a STOP or the cursor
        corner stops the Start-SwdSweepApp that follows a relaunch's close instead.  #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param()
    $p = Get-Process SurfHydrodynamics -ErrorAction SilentlyContinue
    if (-not $p) { return 'not-running' }
    if (-not $PSCmdlet.ShouldProcess('ShaperWaveDynamics', 'close')) { return 'whatif' }
    $main = @(Get-SwdSweepTopWindows | Where-Object IsMain)
    if ($main.Count) { [void][SwdWin]::PostMessage([intptr]$main[0].Handle, [SwdWin]::WM_CLOSE, [intptr]0, [intptr]0) }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 60000) {
        Start-Sleep -Seconds 2
        if ($p.HasExited) { return 'closed' }
        # Closing: 'No' (close without saving) before 'Cancel' (which would keep SWD open).
        try { [void](Clear-SwdSweepPopup -TransientMs 4000 -Order @('No', 'Non', 'Close', 'Fermer', 'Cancel', 'Annuler')) } catch { break }
    }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force; Start-Sleep -Seconds 3; return 'force-stopped' }
    return 'closed'
}

# ---- live: inputs ----------------------------------------------------------------------

function Get-SwdSweepHandle {
    <#  Live HWND for a designer name, from the current census map; 0 when absent or stale.  #>
    param([Parameter(Mandatory)][string]$Aid, [Parameter(Mandatory)]$Ctx)
    if (-not $Ctx.Map.ContainsKey($Aid)) { return 0 }
    $h = [int64]$Ctx.Map[$Aid]
    if (-not (Test-SwdHandle -Handle $h)) { return 0 }
    return $h
}

function Get-SwdSweepEditHandle {
    <#  The EDIT that takes the text for a designer name: the control itself, or for a
        NumericUpDown its inner UpDownEdit. The NumericUpDown's own window text is empty
        (measured 2026-10-01: every spinner read base ''), so it cannot be read or written.  #>
    param([Parameter(Mandatory)][string]$Aid, [Parameter(Mandatory)]$Ctx)
    $h = Get-SwdSweepHandle -Aid $Aid -Ctx $Ctx
    if (-not $h) { return 0 }
    $sb = New-Object System.Text.StringBuilder 256
    [void][SwdWin]::GetClassName([intptr]$h, $sb, 256)
    if ($sb.ToString() -like '*EDIT*') { return $h }
    foreach ($line in [SwdWin]::Children([intptr]$h)) {
        $r = ConvertFrom-SwdControlRecord -Line $line
        if ($r.Class -like '*EDIT*') { return [int64]$r.Handle }
    }
    return $h
}

function Get-SwdSweepGridView {
    <#  HWND of the Project property grid's view window (the one whose MSAA cells are rows).  #>
    param([Parameter(Mandatory)]$Ctx)
    $pg = Get-SwdSweepHandle -Aid 'PropertyGridProjet_objet_select' -Ctx $Ctx
    if (-not $pg) { return 0 }
    foreach ($c in @(Get-SwdControl)) {
        $h = [int64]$c.Handle; $x = $h
        for ($i = 0; $i -lt 3 -and $x; $i++) { $x = [int64][SwdWin]::GetParent([intptr]$x); if ($x -eq $pg) { break } }
        if ($x -eq $pg -and $c.Visible) {
            $cells = @([SwdProbeNative]::Walk([intptr]$h, 400, 5000) | Where-Object { $_.Role -eq '29' })
            if ($cells.Count) { return $h }
        }
    }
    return 0
}

function Read-SwdSweepInput {
    <#  Current value of an input, as the string the sweep compares.  #>
    param([Parameter(Mandatory)]$Spec, [Parameter(Mandatory)]$Ctx)
    switch ($Spec.Kind) {
        'grid' {
            $v = Get-SwdSweepGridView -Ctx $Ctx
            $r = [SwdProbeNative]::Act([intptr]$v, $Spec.Target, '29', 0, 'read', $null, 2000, 5000)
            if ($r.Status -ne 'ok') { throw "grid row '$($Spec.Target)' not readable: $($r.Status)" }
            return $r.Value
        }
        'radio' {
            foreach ($o in @($Spec.Options)) {
                $h = Get-SwdSweepHandle -Aid $o -Ctx $Ctx
                if ($h) { $n = @([SwdProbeNative]::Walk([intptr]$h, 2, 3000)); if ($n.Count -and ($n[0].State -band 0x10)) { return $o } }
            }
            return $null
        }
    }
    $h = Get-SwdSweepHandle -Aid $Spec.Target -Ctx $Ctx
    if (-not $h) { throw "control '$($Spec.Target)' not found in the current census" }
    switch ($Spec.Kind) {
        'numeric' { return (Get-SwdText -Handle (Get-SwdSweepEditHandle -Aid $Spec.Target -Ctx $Ctx)) }
        'combo' { return "$([SwdProbeNative]::ComboIndex([intptr]$h, 3000))" }
        'slider' { return "$([SwdProbeNative]::TrackPos([intptr]$h, 3000))" }
        'check' { $n = @([SwdProbeNative]::Walk([intptr]$h, 2, 3000)); return "$([bool]($n.Count -and ($n[0].State -band 0x10)))" }
    }
    throw "unknown input kind '$($Spec.Kind)'"
}

function Write-SwdSweepInput {
    <#  Set an input and press its paired, allowlisted Apply button. Returns the read-back.
        Every write is a message or an MSAA value; every click is a posted BM_CLICK on a
        caption or control type the guards have just re-checked. -StopFile: the kill switch,
        checked before the write and before the Apply (W3); a trial's RESTORE passes none, as
        T12's restore does, so a STOP never leaves the board holding the trial value (W1).  #>
    param([Parameter(Mandatory)]$Spec, [Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)]$Ctx, [string]$StopFile)
    if ($StopFile) { Assert-SwdProbeContinue -StopFile $StopFile }
    switch ($Spec.Kind) {
        'numeric' {
            $h = Get-SwdSweepEditHandle -Aid $Spec.Target -Ctx $Ctx
            if (-not $h) { throw "control '$($Spec.Target)' not found in the current census" }
            $r = Set-SwdNumeric -Handle $h -Value $Value -Confirm:$false
            if (-not $r.After -and -not $r.Ok) { throw "Set-SwdNumeric: $($r.Reason)" }
        }
        'combo' {
            $h = Get-SwdSweepHandle -Aid $Spec.Target -Ctx $Ctx
            Assert-SwdProbeClass -Handle $h -Like '*COMBOBOX*' -What 'combo box'
            if ([SwdProbeNative]::ComboSelect([intptr]$h, [int]$Value, 3000) -lt 0) { throw 'combo selection was not delivered' }
        }
        'slider' {
            $h = Get-SwdSweepHandle -Aid $Spec.Target -Ctx $Ctx
            Assert-SwdProbeClass -Handle $h -Like '*trackbar32*' -What 'trackbar'
            if ([SwdProbeNative]::TrackSet([intptr]$h, [int]$Value, 3000) -eq [int]::MinValue) { throw 'trackbar position was not delivered' }
        }
        'radio' {
            $h = Get-SwdSweepHandle -Aid $Value -Ctx $Ctx
            if (-not $h) { throw "radio option '$Value' not found" }
            [void](Assert-SwdProbeToggle -Handle $h)
            [void](Invoke-SwdButton -Handle $h -Post -Confirm:$false)
        }
        'check' {
            $h = Get-SwdSweepHandle -Aid $Spec.Target -Ctx $Ctx
            [void](Assert-SwdProbeToggle -Handle $h)
            [void](Invoke-SwdButton -Handle $h -Post -Confirm:$false)
        }
        'grid' {
            $v = Get-SwdSweepGridView -Ctx $Ctx
            if (-not $v) { throw 'Project property grid view not found' }
            $r = Invoke-SwdProbeAcc -Handle $v -Name $Spec.Target -Role '29' -Action setvalue -Value $Value -AllowedSetValue @($Spec.Target) -StopFile $StopFile
            if ($r.Status -ne 'ok') { throw "grid set '$($Spec.Target)': $($r.Status)" }
        }
    }
    if ($Spec.Apply) {
        $b = Get-SwdSweepHandle -Aid $Spec.Apply -Ctx $Ctx
        if (-not $b) { throw "apply button '$($Spec.Apply)' not found" }
        if ($StopFile) { Assert-SwdProbeContinue -StopFile $StopFile }
        [void](Assert-SwdProbeButton -Handle $b)
        [void](Invoke-SwdButton -Handle $b -Post -Confirm:$false)
    }
    $m = Get-SwdProbeMain
    $s = Wait-SwdProbeSettle -Handle $m.Handle -TimeoutMs 20000 -StopFile $StopFile
    $pops = @(Clear-SwdSweepPopup -StopFile $StopFile)
    return [pscustomobject]@{ ReadBack = (Read-SwdSweepInput -Spec $Spec -Ctx $Ctx); SettleMs = $s.SettleMs; TimedOut = $s.TimedOut; Dialogs = $pops }
}

# ---- live: census and naming -------------------------------------------------------------

function Invoke-SwdSweepUia3 {
    <#  swd_uia3.py dump (read-only), parsed.  #>
    param([Parameter(Mandatory)][string]$OutFile)
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    $o = @(& py -3.14 (Join-Path $script:ProbeRoot 'swd_uia3.py') dump $OutFile 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutFile)) { throw "swd_uia3.py failed: $(Format-MessageForDisplay (($o | ForEach-Object { "$_" }) -join ' '))" }
    $doc = Get-Content -LiteralPath $OutFile -Raw -Encoding UTF8 | ConvertFrom-Json
    # A walk cut short by its row or time cap would silently shorten every plan built on it (S15;
    # none of the 2026-10 dumps came near: 361 rows, 1.8 s at most). Refused, and set aside so no
    # reader of a cached '<pid>-*.json' census picks it up again.
    if ($doc.PSObject.Properties['truncated'] -and $doc.truncated) {
        Move-Item -LiteralPath $OutFile -Destination "$OutFile.truncated" -Force
        throw "swd_uia3.py cut its walk short ($($doc.elements) rows in $($doc.seconds) s); refusing a partial census."
    }
    return $doc
}

function Invoke-SwdSweepCensus {
    <#  Census of one mode: every allowlisted tab of that mode is selected in turn and dumped,
        so tab pages WinForms has not built yet get built. Fills Ctx.Census[mode] (rows, last
        dump per element wins), Ctx.Map (designer name -> HWND, all modes) and Ctx.Names.  #>
    param([Parameter(Mandatory)][string]$Mode, [Parameter(Mandatory)]$Ctx)
    [void](Switch-SwdSweepMode -Mode $Mode -StopFile $Ctx.StopFile)
    $m = Get-SwdProbeMain
    $dir = Join-Path $Ctx.Dir 'census'; [void][IO.Directory]::CreateDirectory($dir)
    # Named by SWD's pid: Import-SwdSweepCensus reuses them while that process lives.
    $pfx = "$($m.Process.Id)-$Mode"
    Assert-SwdProbeContinue -StopFile $Ctx.StopFile
    $first = Invoke-SwdSweepUia3 -OutFile (Join-Path $dir "$pfx-00.json")
    $byPath = [ordered]@{}
    foreach ($r in @($first.rows)) { $byPath[(Get-SwdSweepCensusKey $r)] = $r }
    $tabs = @(@($first.rows) | Where-Object { $_.Kind -eq 'tab' -and (Test-SwdProbeAllowedTab $_.Name) } | ForEach-Object { ConvertTo-SwdProbeLabel $_.Name } | Sort-Object -Unique)
    $Ctx.Census[$Mode] = @($byPath.Values)
    $i = 0
    foreach ($t in $tabs) {
        $i++
        # A STOP is rethrown, never noted as a tab that would not select (W3).
        try { [void](Select-SwdProbeTab -Handle $m.Handle -Name $t -StopFile $Ctx.StopFile) } catch {
            if ($_.Exception.Message -like 'SWD-*') { throw }
            $Ctx.Notes.Add("census $Mode tab '$t': $($_.Exception.Message)"); continue
        }
        [void](Wait-SwdProbeSettle -Handle $m.Handle -TimeoutMs 15000 -StopFile $Ctx.StopFile)
        if ($t -eq 'Fins') { $fin = Select-SwdSweepFin -Ctx $Ctx -Mode $Mode; $Ctx.Notes.Add("census $Mode fin selection: $fin") }
        Assert-SwdProbeContinue -StopFile $Ctx.StopFile
        $d = Invoke-SwdSweepUia3 -OutFile (Join-Path $dir ('{0}-{1:D2}.json' -f $pfx, $i))
        foreach ($r in @($d.rows)) { $byPath[(Get-SwdSweepCensusKey $r)] = $r }
        $Ctx.Census[$Mode] = @($byPath.Values)
        # A tab revealed by this one (Shape > Guides Sections) is visited too.
        foreach ($n in @(@($d.rows) | Where-Object { $_.Kind -eq 'tab' -and (Test-SwdProbeAllowedTab $_.Name) } | ForEach-Object { ConvertTo-SwdProbeLabel $_.Name })) {
            if ($tabs -notcontains $n) { $tabs += $n }
        }
    }
    Register-SwdSweepCensus -Rows @($byPath.Values) -Ctx $Ctx
    $Ctx.Pid = $m.Process.Id
}

function Get-SwdSweepCensusKey {
    <#  The key census rows are merged by across dumps (pure): the window handle when the row has one,
        else the uia3 Path. Path alone repeats for unnamed siblings of one type, and keying on it
        dropped 751 of 11,150 windows from the 2026-10-01 census (S16). A handle is unique for the
        life of the process, which is as long as a census is reused.  #>
    param([Parameter(Mandatory)]$Row)
    $h = if ($Row.PSObject.Properties['Hwnd']) { "$($Row.Hwnd)" } else { '' }
    if ($h -and $h -ne '0') { return "h$h" }
    return "p$(if ($Row.PSObject.Properties['Path']) { $Row.Path })"
}

function Register-SwdSweepCensus {
    <#  Designer name -> HWND (Ctx.Map) and HWND -> readable name (Ctx.Names) from census rows.  #>
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Rows, [Parameter(Mandatory)]$Ctx)
    foreach ($r in @($Rows)) {
        if (-not $r.Hwnd) { continue }
        $named = $r.AutomationId -and $r.AutomationId -notmatch '^\d+$'
        if ($named) { $Ctx.Map[$r.AutomationId] = [int64]$r.Hwnd }
        $Ctx.Names[[int64]$r.Hwnd] = $(if ($named) { $r.AutomationId } elseif ($r.Name) { "$($r.Type):$($r.Name)" } else { "$($r.Type)" })
    }
}

function Import-SwdSweepCensus {
    <#  Reuse this SWD process's census files (HWNDs live as long as the process). $true when
        both modes were found; otherwise the caller runs Invoke-SwdSweepCensus.  #>
    param([Parameter(Mandatory)]$Ctx, [string[]]$Modes = @('S', 'D'))
    $procId = (Get-SwdProcess).Id
    $dir = Join-Path $Ctx.Dir 'census'
    foreach ($mode in $Modes) {
        $files = @(Get-ChildItem -LiteralPath $dir -Filter "$procId-$mode-*.json" -ErrorAction SilentlyContinue | Sort-Object Name)
        if (-not $files.Count) { return $false }
        $byPath = [ordered]@{}
        foreach ($f in $files) { foreach ($r in @((Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).rows)) { $byPath[(Get-SwdSweepCensusKey $r)] = $r } }
        $Ctx.Census[$mode] = @($byPath.Values)
        Register-SwdSweepCensus -Rows @($byPath.Values) -Ctx $Ctx
    }
    $Ctx.Pid = $procId
    return $true
}

function Select-SwdSweepFin {
    <#  Fin parameters are disabled until a fin is selected (measured: 'NO FIN SELECTED').
        Expand 'Statics fins' in the Fins tree and select its first fin. Returns its name.  #>
    param([Parameter(Mandatory)]$Ctx, [string]$Mode = 'D')
    $rows = @($Ctx.Census.$Mode)
    $tree = Find-SwdSweepTree -Rows $rows -AutomationId 'TreeView_ailerons'
    if (-not $tree) {
        $d = Invoke-SwdSweepUia3 -OutFile (Join-Path $Ctx.Dir 'census\fins-tree.json')
        $tree = Find-SwdSweepTree -Rows @($d.rows) -AutomationId 'TreeView_ailerons'
    }
    if (-not $tree) { return 'no fins tree' }
    # Static fins first, then the dynamic (ADAC) ones: default_shortboard_Copy_1 has none of the
    # former and three of the latter (measured). A fin is a CHILD of its category: an MSAA
    # tree item's Value is its level, and a sibling category must never be taken for a fin.
    foreach ($cat in 'Statics fins', 'Dynamics Fyn') {
        $e = Invoke-SwdProbeAcc -Handle $tree -Name $cat -Action expand -StopFile $Ctx.StopFile
        if ($e.Status -eq 'not-found') { continue }
        Start-Sleep -Milliseconds 800
        $nodes = @([SwdProbeNative]::Walk([intptr]$tree, 500, 5000) | Where-Object { $_.Role -eq '36' })
        $i = [array]::IndexOf(@($nodes | ForEach-Object { $_.Name }), $cat)
        if ($i -lt 0 -or $i + 1 -ge $nodes.Count) { continue }
        $n = $nodes[$i + 1]
        if ($n.Hidden -or [int]"0$($n.Value)" -le [int]"0$($nodes[$i].Value)") { continue }
        $r = Invoke-SwdProbeAcc -Handle $tree -Name $n.Name -Action select -AllowAmbiguous -StopFile $Ctx.StopFile
        [void](Wait-SwdProbeSettle -Handle ([int64](Get-SwdProbeMain).Handle) -TimeoutMs 15000 -StopFile $Ctx.StopFile)
        return "$($n.Name) ($($r.Status))"
    }
    return 'no fin found under Statics fins or Dynamics Fyn'
}

function Resolve-SwdSweepOwner {
    <#  A readable owner for a HWND: its designer name, or the nearest named ancestor's.  #>
    param([int64]$Hwnd, [Parameter(Mandatory)]$Ctx)
    $x = $Hwnd
    for ($i = 0; $i -lt 6 -and $x; $i++) {
        if ($Ctx.Names.ContainsKey($x)) { return $(if ($i) { "$($Ctx.Names[$x])/~$i" } else { $Ctx.Names[$x] }) }
        $x = [int64][SwdWin]::GetParent([intptr]$x)
    }
    return "h$Hwnd"
}

function Resolve-SwdSweepBox {
    <#  The smallest census control containing a window-relative image box's centre.  #>
    param($Box, $Origin, [Parameter(Mandatory)]$Ctx, [string]$Mode, [string]$TabPath = '')
    $b = @($Box); $cx = $b[0] + $b[2] / 2 + $Origin[0]; $cy = $b[1] + $b[3] / 2 + $Origin[1]
    $best = $null; $area = [double]::MaxValue
    foreach ($r in @($Ctx.Census.$Mode)) {
        if (-not $r.PSObject.Properties['Rect'] -or $r.Offscreen) { continue }
        # Controls on other tab pages share the screen area: only the active tab path's count.
        $tp = if ($r.PSObject.Properties['TabPath']) { "$($r.TabPath)" } else { '' }
        if ($tp -and -not $TabPath.StartsWith($tp, [StringComparison]::Ordinal) -and @('Project', 'Elements;analysis') -notcontains $tp.Split('|')[0]) { continue }
        $q = @($r.Rect); if ($q.Count -ne 4 -or $q[2] -le 0 -or $q[3] -le 0) { continue }
        if ($cx -ge $q[0] -and $cx -lt $q[0] + $q[2] -and $cy -ge $q[1] -and $cy -lt $q[1] + $q[3] -and $q[2] * $q[3] -lt $area) {
            $area = $q[2] * $q[3]
            $best = $(if ($r.AutomationId -and $r.AutomationId -notmatch '^\d+$') { $r.AutomationId } elseif ($r.Name) { "$($r.Type):$($r.Name)" } else { $r.Type })
        }
    }
    if ($best) { return $best }
    return 'window'
}

function ConvertTo-SwdSweepChange {
    <#  A snapshot diff as named changes: Ch (win32 | msaa | image), Owner, Item, Field, From, To.  #>
    param([Parameter(Mandatory)]$Diff, $Origin, [Parameter(Mandatory)]$Ctx, [string]$Mode, [string]$TabPath = '')
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($d in @($Diff.Win32)) {
        if ($null -eq $d -or $d.Hidden) { continue }
        $out.Add([pscustomobject]@{ Ch = 'win32'; Owner = (Resolve-SwdSweepOwner -Hwnd ([int64]$d.Handle) -Ctx $Ctx); Item = ''; Field = $d.Field; From = "$($d.From)"; To = "$($d.To)"; InScope = [bool]$d.InScope; Kind = $d.Kind })
    }
    foreach ($d in @($Diff.Msaa)) {
        if ($null -eq $d -or $d.Hidden) { continue }
        $h = 0; $path = ''
        if ("$($d.Key)" -match '^h(\d+):([^|]*)') { $h = [int64]$Matches[1]; $path = $Matches[2] }
        # A caption that changes is keyed by its position, not by the caption it changed TO,
        # so the same label lines up across trials and ladder levels.
        $item = if ($d.Field -eq 'Name') { "#$path" } else { "$($d.Name)" }
        $out.Add([pscustomobject]@{ Ch = 'msaa'; Owner = (Resolve-SwdSweepOwner -Hwnd $h -Ctx $Ctx); Item = $item; Field = $d.Field; From = "$($d.From)"; To = "$($d.To)"; InScope = [bool]$d.InScope; Kind = $d.Kind })
    }
    foreach ($b in @($Diff.OutOfScope.ImageBoxes)) {
        if ($null -eq $b) { continue }
        $out.Add([pscustomobject]@{ Ch = 'image'; Owner = (Resolve-SwdSweepBox -Box $b -Origin $Origin -Ctx $Ctx -Mode $Mode -TabPath $TabPath); Item = (@($b) -join ','); Field = 'pixels'; From = ''; To = ''; InScope = $false; Kind = 'CHANGED' })
    }
    return $out.ToArray()
}

# ---- live: trials ------------------------------------------------------------------------

function Get-SwdSweepVolatility {
    <#  Ignore set for one mode and tab path: two null actions, 3 s apart.  #>
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)]$Ctx)
    if ($Ctx.Ignore.ContainsKey($Key)) { return $Ctx.Ignore[$Key] }
    $dir = Join-Path $Ctx.RunDir 'null'; [void][IO.Directory]::CreateDirectory($dir)
    $tag = ($Key -replace '[^\w]', '_')
    $ig = @{}
    $s0 = Get-SwdProbeSnapshot -Dir $dir -Label "$tag-0"
    foreach ($k in 1, 2) {
        Start-Sleep -Seconds 3
        $s1 = Get-SwdProbeSnapshot -Dir $dir -Label "$tag-$k"
        $d = Compare-SwdProbeSnapshot -Before $s0 -After $s1 -Mask $Ctx.Mask
        foreach ($kv in (Get-SwdProbeVolatility -MsaaDiff $d.Msaa -Win32Diff $d.Win32).GetEnumerator()) { $ig[$kv.Key] = $true }
        $s0 = $s1
    }
    $Ctx.Ignore[$Key] = $ig
    return $ig
}

function Enter-SwdSweepInputView {
    <#  Mode, observation view and the input's tabs, all re-established before a trial.  #>
    param([Parameter(Mandatory)]$Spec, [Parameter(Mandatory)]$Ctx)
    # Mode, view and tab are cached: each check is a full MSAA walk (~3 s), and consecutive
    # trials of one input share all three. Only this file toggles Board Dynamics or changes
    # tabs, and every relaunch or census clears the cache.
    if ($Ctx.ModeNow -ne $Spec.Mode) {
        [void](Switch-SwdSweepMode -Mode $Spec.Mode -StopFile $Ctx.StopFile)
        $Ctx.ModeNow = $Spec.Mode; $Ctx.ViewMode = $null; $Ctx.TabNow = $null
    }
    if ($Ctx.ViewMode -ne $Spec.Mode) { $Ctx.View = Initialize-SwdSweepView -Mode $Spec.Mode -Ctx $Ctx; $Ctx.ViewMode = $Spec.Mode; $Ctx.TabNow = $null }
    if ($Ctx.TabNow -ne $Spec.TabPath) {
        $m = Get-SwdProbeMain
        foreach ($t in @(Get-SwdSweepTabStep $Spec.TabPath)) { [void](Select-SwdProbeTab -Handle $m.Handle -Name $t -StopFile $Ctx.StopFile) }
        if (@(Get-SwdSweepTabStep $Spec.TabPath) -contains 'Fins' -and -not $Ctx.FinSelected) { $Ctx.Notes.Add("fin: $(Select-SwdSweepFin -Ctx $Ctx -Mode $Spec.Mode)"); $Ctx.FinSelected = $true }
        [void](Wait-SwdProbeSettle -Handle $m.Handle -TimeoutMs 15000 -StopFile $Ctx.StopFile)
        $Ctx.TabNow = $Spec.TabPath
    }
    return "$($Spec.Mode)|$($Spec.TabPath)"
}

function Invoke-SwdSweepTrial {
    <#  One trial: snapshot, set (+Apply), settle, snapshot, restore (+Apply), settle,
        snapshot. Returns the record written to trials.jsonl. Never throws for an input that
        misbehaves (that is a finding); throws only for STOP, dialogs and a lost app.  #>
    param([Parameter(Mandatory)]$Spec, [Parameter(Mandatory)][string]$Value, [int]$Rep = 1, [Parameter(Mandatory)]$Ctx)
    $id = "$($Spec.Id)|$Value|r$Rep"
    $dir = Join-Path $Ctx.RunDir 'trials'; [void][IO.Directory]::CreateDirectory($dir)
    $tag = ('{0:D4}' -f $Ctx.Seq) + '-' + (($Spec.Target + '-' + $Value + "-r$Rep") -replace '[^\w.-]', '_')
    $Ctx.Seq++
    $rec = [ordered]@{ Id = $id; Input = $Spec.Id; Mode = $Spec.Mode; Kind = $Spec.Kind; Target = $Spec.Target; Label = $Spec.Label
                       TabPath = $Spec.TabPath; Apply = $Spec.Apply; Value = $Value; Rep = $Rep; Started = (Get-Date).ToString('o') }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $view = Enter-SwdSweepInputView -Spec $Spec -Ctx $Ctx
    $ig = Get-SwdSweepVolatility -Key $view -Ctx $Ctx
    $base = Read-SwdSweepInput -Spec $Spec -Ctx $Ctx
    $rec.Base = $base
    $target = $Value
    if ($Spec.Kind -eq 'check') { $target = "$(-not [bool]::Parse($base))" }
    $rec.Expected = $target
    $b = Get-SwdProbeSnapshot -Dir $dir -Label "$tag-b"
    # W1: from the write until a restore is seen to be exact, SWD may hold the trial value. Saved
    # BEFORE the write, so a chunk killed in between is relaunched before its next trial.
    $pendingBefore = $Ctx.RestorePendingPid
    $Ctx.RestorePendingPid = [int64](Get-SwdProcess).Id
    Save-SwdSweepState -Ctx $Ctx
    $byRelaunch = Test-SwdProbeListed -List $script:SweepRestoreByRelaunch -Label "$($Spec.Target)"
    $w = $null; $err = $null; $halt = $null; $a = $null; $rErr = $null
    try {
        try { $w = Write-SwdSweepInput -Spec $Spec -Value $Value -Ctx $Ctx -StopFile $Ctx.StopFile } catch {
            if ($_.Exception.Message -like 'SWD-*') { $halt = $_.Exception.Message; throw }
            $err = Format-MessageForDisplay $_.Exception.Message
        }
        $a = Get-SwdProbeSnapshot -Dir $dir -Label "$tag-a"
    } finally {
        # Restore: the base value back, its Apply pressed again, WHATEVER happened above (W1): a
        # STOP or the cursor corner raised while the write settled used to skip it and leave the
        # board changed. No -StopFile, as T12's restore. Not after a dialog or a moved cursor: SWD
        # is then in a state the guards do not understand, the run halts, and the pending flag
        # relaunches it. A radio restores to the option that was checked; a check box is toggled
        # back only if it reads changed; an input on $script:SweepRestoreByRelaunch is never written
        # back (W2) and the Map loop relaunches after it instead.
        if ($null -ne $base -and -not $byRelaunch -and (-not $halt -or $halt -like 'SWD-PROBE-STOPPED*')) {
            try {
                $rv = $base
                if ($Spec.Kind -eq 'check') { $rv = if ("$(Read-SwdSweepInput -Spec $Spec -Ctx $Ctx)" -ne "$base") { 'toggle' } else { $null } }
                if ($null -ne $rv) { [void](Write-SwdSweepInput -Spec $Spec -Value $rv -Ctx $Ctx) }
            } catch {
                if ($_.Exception.Message -like 'SWD-*') { throw }
                $rErr = Format-MessageForDisplay $_.Exception.Message
            }
        }
    }
    $rec.WriteError = $err
    if ($w) { $rec.ReadBack = $w.ReadBack; $rec.SettleMs = $w.SettleMs; $rec.SettleTimedOut = $w.TimedOut; $rec.Dialogs = @($w.Dialogs) }
    $rec.TookValue = ($null -ne $w) -and ("$($w.ReadBack)" -eq "$target" -or ((ConvertTo-SwdNumber $w.ReadBack).Ok -and (ConvertTo-SwdNumber $target).Ok -and
                     [math]::Abs((ConvertTo-SwdNumber $w.ReadBack).Value - (ConvertTo-SwdNumber $target).Value) -lt 1e-6))
    $r = Get-SwdProbeSnapshot -Dir $dir -Label "$tag-r"
    $rec.RestoreError = $rErr
    $rec.RestoredTo = $null
    try { $rec.RestoredTo = Read-SwdSweepInput -Spec $Spec -Ctx $Ctx } catch { $rec.RestoredTo = $null }
    $expect = @()
    foreach ($aid in @($Spec.Target) + @($Spec.Options) + @($Spec.Apply)) { if ($aid) { $h = Get-SwdSweepHandle -Aid $aid -Ctx $Ctx; if ($h) { $expect += $h } } }
    $dA = Compare-SwdProbeSnapshot -Before $b -After $a -ExpectHandles $expect -Ignore $ig -Mask $Ctx.Mask
    $dR = Compare-SwdProbeSnapshot -Before $b -After $r -ExpectHandles $expect -Ignore $ig -Mask $Ctx.Mask
    $rec.Changes = @(ConvertTo-SwdSweepChange -Diff $dA -Origin $b.Origin -Ctx $Ctx -Mode $Spec.Mode -TabPath "$($Spec.TabPath)")
    $rec.Residue = @(ConvertTo-SwdSweepChange -Diff $dR -Origin $b.Origin -Ctx $Ctx -Mode $Spec.Mode -TabPath "$($Spec.TabPath)")
    $rec.ImageError = $dA.ImageError
    $rec.MsaaTruncated = $dA.MsaaTruncated -or $dR.MsaaTruncated
    $effect = @(Get-SwdSweepChangeKey @($rec.Changes | Where-Object { $_.Ch -ne 'image' -and $_.Field -ne 'Rect' }))
    $left = @(Get-SwdSweepChangeKey @($rec.Residue | Where-Object { $_.Ch -ne 'image' -and $_.Field -ne 'Rect' }))
    $rec.RestoreExact = (@($left | Where-Object { $effect -contains $_ }).Count -eq 0)
    # This trial left nothing behind: the flag goes back to what it was before the write. Never for
    # an input restored by relaunch alone: nothing was written back, whatever the diff shows.
    if ($rec.RestoreExact -and -not $rErr -and -not $byRelaunch) { $Ctx.RestorePendingPid = $pendingBefore }
    $rec.ElapsedMs = [int]$sw.ElapsedMilliseconds
    return [pscustomobject]$rec
}

function Invoke-SwdSweepCurve {
    <#  Pass 2 for one numeric input: a base snapshot, then each ladder level set (no restore
        between levels) and diffed against the base. Each level's changes carry From (base)
        and To (that level), keyed like the Map pass, so the matrix script reads the response
        curve straight off them. The caller restores the base.  #>
    param([Parameter(Mandatory)]$Spec, [Parameter(Mandatory)][string[]]$Levels, [Parameter(Mandatory)]$Ctx)
    $view = Enter-SwdSweepInputView -Spec $Spec -Ctx $Ctx
    $ig = Get-SwdSweepVolatility -Key $view -Ctx $Ctx
    $dir = Join-Path $Ctx.RunDir 'curves'; [void][IO.Directory]::CreateDirectory($dir)
    $tag = ($Spec.Target -replace '[^\w.-]', '_')
    $b = Get-SwdProbeSnapshot -Dir $dir -Label "$tag-base"
    foreach ($v in $Levels) {
        Assert-SwdProbeContinue -StopFile $Ctx.StopFile
        $w = Write-SwdSweepInput -Spec $Spec -Value $v -Ctx $Ctx -StopFile $Ctx.StopFile
        $a = Get-SwdProbeSnapshot -Dir $dir -Label "$tag-$($v -replace '[^\w.-]', '_')"
        $d = Compare-SwdProbeSnapshot -Before $b -After $a -Ignore $ig -Mask $Ctx.Mask
        [pscustomobject]@{ Input = $Spec.Id; Base = $Spec.Base; Value = $v; ReadBack = $w.ReadBack; Dialogs = @($w.Dialogs)
                           Changes = @(ConvertTo-SwdSweepChange -Diff $d -Origin $b.Origin -Ctx $Ctx -Mode $Spec.Mode | Where-Object { $_.Ch -ne 'image' })
                           ImageBoxes = @($d.OutOfScope.ImageBoxes).Count; ImageError = $d.ImageError; Time = (Get-Date).ToString('o') }
    }
}

# ---- driver ------------------------------------------------------------------------------

function Save-SwdSweepState {
    param([Parameter(Mandatory)]$Ctx)
    Write-SwdProbeJson -Path (Join-Path $Ctx.Dir 'state.json') -Object ([pscustomobject]@{
        Board = $Ctx.Board; Pid = $Ctx.Pid; Manifest = @($Ctx.Manifest); Done = @($Ctx.Done.Keys); Attempts = $Ctx.Attempts
        Skipped = @($Ctx.Skipped); Restarts = $Ctx.Restarts; WarmPid = $Ctx.WarmPid; Relaunched = @($Ctx.Relaunched); Halted = $Ctx.Halted; Seq = $Ctx.Seq; Notes = @($Ctx.Notes)
        # W1: the SWD process whose board a trial changed and no restore has yet been seen to undo (0: none).
        RestorePendingPid = [int64]$Ctx.RestorePendingPid }) -Depth 8
}

function Add-SwdSweepRecord {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$File, [Parameter(Mandatory)]$Record)
    $line = ($Record | ConvertTo-Json -Depth 8 -Compress) + "`n"
    [IO.File]::AppendAllText((Join-Path $Ctx.Dir $File), $line, (New-Object Text.UTF8Encoding $false))
}

function Test-SwdSweepSkipped {
    <#  $true for a manifest item the census rules never sweep (pure): a skip-listed designer name,
        or a property-grid row that is skip-listed or denylisted.  #>
    param([Parameter(Mandatory)]$Item)
    $t = "$($Item.Target)"
    if ($script:SweepSkipIds -contains $t) { return $true }
    $grid = $Item.PSObject.Properties['Kind'] -and $Item.Kind -eq 'grid'
    return [bool]($grid -and ($script:SweepGridSkip -contains $t -or (Get-SwdProbeDenyMatch $t)))
}

function Get-SwdSweepPlan {
    <#  Every trial id of a pass, in run order (pure over the manifest and the map results).
        Map: S inputs first (Volume last: writing it renames its Apply button for the rest of
        the session), then D. Each value twice, consecutively.  #>
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Manifest)
    # The census's never-sweep rules hold on a resumed manifest too (S11): they used to be applied
    # only when state.json was first built, so a later addition never reached a running sweep.
    $items = @(@($Manifest) | Where-Object { $_ -and -not (Test-SwdSweepSkipped $_) })
    $order = @($items | Where-Object { $_.Mode -eq 'S' -and $_.Target -notlike '*Volum*' }) + @($items | Where-Object { $_.Mode -eq 'S' -and $_.Target -like '*Volum*' }) + @($items | Where-Object { $_.Mode -eq 'D' })
    foreach ($i in $order) {
        foreach ($v in @($i.Values)) { foreach ($rep in 1, 2) { [pscustomobject]@{ Id = "$($i.Id)|$v|r$rep"; Input = $i; Value = "$v"; Rep = $rep } } }
    }
}

function Get-SwdSweepSituationLevel {
    <#  Levels for an 'Apply situation' input (pure): the Pass-2 ladder around the ORIGINAL base,
        plus 20 for flow speed (the hydroscan's own speed, so the single-point solution can be
        set beside the corpus), then the base itself LAST, so the run ends where it started.  #>
    param([Parameter(Mandatory)][double]$Base, [string]$Target)
    $lv = @(Get-SwdSweepCurveLevel -Base $Base)
    if ($Target -eq 'TextBox_speed_ms' -and $lv -notcontains '20') { $lv += '20' }
    return @($lv + @(Format-SwdSweepNumber $Base))
}

function Invoke-SwdSweepSituationLevel {
    <#  One level of an Apply-situation input, in a FRESH SWD session: 'Apply situation'
        disables itself after one press and neither a value edit nor a Board Dynamics toggle
        re-enables it, while a relaunch does (measured 2026-10-02). The value persists across
        relaunches (it came back as 11 after 11 was applied), so the before-snapshot holds the
        previous level and the after-snapshot this one; each record carries both.
        CORRECTED 2026-10-05: the edit here is a WM_SETTEXT. A TYPED edit (WM_CHAR) re-enables
        the button, so no relaunch is needed (Set-SwdSolverSituation; AI-USE.md E107 and its
        correcting entry). Kept as it ran, for the 2026-10-01 record.  #>
    param([Parameter(Mandatory)]$Spec, [Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)]$Ctx)
    $Ctx.Notes.Add("situation relaunch: $(Stop-SwdSweepApp)")
    $Ctx.Board = Start-SwdSweepApp -ExpectBoard $Ctx.Board -StopFile $Ctx.StopFile; $Ctx.Restarts++
    Invoke-SwdSweepCensus -Mode 'D' -Ctx $Ctx
    $Ctx.Ignore = @{}; $Ctx.ViewMode = $null; $Ctx.FinSelected = $false; $Ctx.ModeNow = $null; $Ctx.TabNow = $null
    $view = Enter-SwdSweepInputView -Spec $Spec -Ctx $Ctx
    $ig = Get-SwdSweepVolatility -Key $view -Ctx $Ctx
    $dir = Join-Path $Ctx.RunDir 'situation'; [void][IO.Directory]::CreateDirectory($dir)
    $tag = ($Spec.Target + '-' + $Value) -replace '[^\w.-]', '_'
    $prior = Read-SwdSweepInput -Spec $Spec -Ctx $Ctx
    $b = Get-SwdProbeSnapshot -Dir $dir -Label "$tag-b"
    $w = $null; $err = $null
    try { $w = Write-SwdSweepInput -Spec $Spec -Value $Value -Ctx $Ctx -StopFile $Ctx.StopFile } catch {
        if ($_.Exception.Message -like 'SWD-*') { throw }
        $err = Format-MessageForDisplay $_.Exception.Message
    }
    $a = Get-SwdProbeSnapshot -Dir $dir -Label "$tag-a"
    $d = Compare-SwdProbeSnapshot -Before $b -After $a -Ignore $ig -Mask $Ctx.Mask
    return [pscustomobject]@{ Input = $Spec.Id; Base = $Spec.Base; Prior = $prior; Value = $Value
                              ReadBack = $(if ($w) { $w.ReadBack } else { $null }); WriteError = $err
                              Changes = @(ConvertTo-SwdSweepChange -Diff $d -Origin $b.Origin -Ctx $Ctx -Mode 'D' -TabPath "$($Spec.TabPath)")
                              ImageError = $d.ImageError; Time = (Get-Date).ToString('o') }
}

function Get-SwdSweepModesLeft {
    <#  The modes the Map pass still has trials in (both when none are left, or for other passes).
        A census of a mode with nothing left to sweep is about 2 minutes of every relaunch.  #>
    param([Parameter(Mandatory)]$Ctx, [string]$Pass = 'Map')
    if ($Pass -eq 'Situation') { return @('D') }
    # Every Curve ladder relaunches SWD and censuses its own mode, so a chunk-start census is waste.
    if ($Pass -eq 'Curve') { return @() }
    if ($Pass -ne 'Map') { return @('S', 'D') }
    $left = @(@(Get-SwdSweepPlan -Manifest @($Ctx.Manifest)) | Where-Object { -not $Ctx.Done.ContainsKey($_.Id) } | ForEach-Object { $_.Input.Mode } | Sort-Object -Unique)
    if (-not $left.Count) { return @('S', 'D') }
    return $left
}

function Invoke-SwdSweep {
    <#  One chunk of the sweep, resumable: Census builds the manifest, Map runs trials until
        MaxMinutes, Curve runs ladders for inputs whose Map trials moved numeric outputs.
        State: <Dir>\state.json; results: trials.jsonl, curves.jsonl.  #>
    param([Parameter(Mandatory)][ValidateSet('Census', 'Map', 'Situation', 'Curve')][string]$Pass, [Parameter(Mandatory)][string]$Dir,
          [Parameter(Mandatory)][string]$RunDir, [Parameter(Mandatory)][string]$StopFile, [double]$MaxMinutes = 8)
    $deadline = (Get-Date).AddMinutes($MaxMinutes)
    if ([SwdProbeNative]::KeepAwake() -eq 0) { throw 'Failed to set thread execution state.' }
    [void][IO.Directory]::CreateDirectory($Dir)
    $statePath = Join-Path $Dir 'state.json'
    # Before the try, so an unreadable state file stops the chunk without finally overwriting it.
    $st = Read-SwdProbeState -Path $statePath
    $ctx = [pscustomobject]@{
        Dir = $Dir; RunDir = $RunDir; StopFile = $StopFile; Mask = (Find-SwdProbeNoiseMask)
        Board = $(if ($st) { $st.Board } else { $null }); Pid = 0
        Manifest = $(if ($st) { @($st.Manifest) } else { @() }); Done = @{}; Attempts = @{}; Skipped = New-Object System.Collections.Generic.List[string]
        Restarts = $(if ($st) { [int]$st.Restarts } else { 0 }); Halted = $(if ($st) { $st.Halted } else { $null }); Seq = $(if ($st) { [int]$st.Seq } else { 0 })
        Notes = New-Object System.Collections.Generic.List[string]; Census = @{}; Map = @{}; Names = @{}; Ignore = @{}
        View = $null; ViewMode = $null; FinSelected = $false; ModeNow = $null; TabNow = $null
        WarmPid = $(if ($st -and $st.PSObject.Properties['WarmPid']) { [int]$st.WarmPid } else { 0 })
        RestorePendingPid = $(if ($st -and $st.PSObject.Properties['RestorePendingPid']) { [int64]$st.RestorePendingPid } else { [int64]0 })
        # A typed list: '$(@(...))' unrolls a one-element array to a bare string, and '+=' on a string
        # concatenates (measured: the ids ran together and the once-per-input rule never matched).
        Relaunched = (New-Object System.Collections.Generic.List[string])
    }
    if ($st) {
        foreach ($k in @($st.Done)) { $ctx.Done[$k] = $true }
        if ($st.Attempts) { foreach ($p in $st.Attempts.PSObject.Properties) { $ctx.Attempts[$p.Name] = [int]$p.Value } }
        foreach ($k in @($st.Skipped)) { if ($k) { $ctx.Skipped.Add($k) } }
        foreach ($n in @($st.Notes)) { if ($n) { $ctx.Notes.Add($n) } }
        if ($st.PSObject.Properties['Relaunched']) { foreach ($k in @($st.Relaunched)) { if ($k) { $ctx.Relaunched.Add("$k") } } }
    }
    if ($ctx.Halted) { return [pscustomobject]@{ Pass = $Pass; Halted = $ctx.Halted; Message = 'sweep is halted; read state.json' } }
    if (-not (Get-Process SurfHydrodynamics -ErrorAction SilentlyContinue)) { $ctx.Board = Start-SwdSweepApp -ExpectBoard $ctx.Board -StopFile $StopFile; $ctx.Restarts++ }
    elseif ($ctx.RestorePendingPid -and (Get-SwdSweepPid) -eq $ctx.RestorePendingPid) {
        # W1: an earlier chunk stopped with a trial's restore unfinished or inexact in THIS process.
        # Relaunched before anything here reads a base value off the board it left changed.
        $ctx.Notes.Add("restore pending in pid $($ctx.RestorePendingPid) from an earlier chunk; relaunching: $(Stop-SwdSweepApp)")
        $ctx.Board = Start-SwdSweepApp -ExpectBoard $ctx.Board -StopFile $StopFile; $ctx.Restarts++
    }
    # Any other process is a fresh launch: its board is the one on disk.
    $ctx.RestorePendingPid = 0
    $m = Get-SwdProbeMain
    $board = Assert-SwdProbeBoard -Title $m.Title
    if ($ctx.Board -and $board -ne $ctx.Board) { throw "SWD-SWEEP-BOARD: SWD shows '$board', the sweep was started on '$($ctx.Board)'." }
    $ctx.Board = $board
    $done = 0; $failed = 0; $why = 'pass complete'
    try {
        # The census is per SWD session: designer names are stable, HWNDs are not.
        [void](Clear-SwdSweepPopup -StopFile $StopFile)
        $modes = if ($Pass -eq 'Census') { @('S', 'D') } else { @(Get-SwdSweepModesLeft -Ctx $ctx -Pass $Pass) }
        if ($Pass -eq 'Census' -or -not (Import-SwdSweepCensus -Ctx $ctx -Modes $modes)) { foreach ($mode in $modes) { Invoke-SwdSweepCensus -Mode $mode -Ctx $ctx } }
        $ctx.ModeNow = $null; $ctx.TabNow = $null; $ctx.ViewMode = $null
        if ($Pass -eq 'Census') {
            $man = @()
            foreach ($mode in 'S', 'D') { $man += @(ConvertTo-SwdSweepInput -Rows @($ctx.Census.$mode) -Mode $mode) }
            # Board Dynamics rows of the Project grid: editable (MSAA read-only clear), numeric or bool.
            [void](Switch-SwdSweepMode -Mode 'D' -StopFile $StopFile); $ctx.View = Initialize-SwdSweepView -Mode 'D' -Ctx $ctx; $ctx.ViewMode = 'D'
            $gv = Get-SwdSweepGridView -Ctx $ctx
            if ($gv) {
                foreach ($c in @([SwdProbeNative]::Walk([intptr]$gv, 400, 5000) | Where-Object { $_.Role -eq '29' -and -not $_.Hidden -and -not ($_.State -band 0x40) })) {
                    if ($script:SweepGridSkip -contains $c.Name -or (Get-SwdProbeDenyMatch $c.Name)) { continue }
                    if (-not (ConvertTo-SwdNumber $c.Value).Ok -and @('True', 'False') -notcontains $c.Value) { continue }
                    $man += [pscustomobject]@{ Id = "D/grid:$($c.Name)"; Mode = 'D'; TabPath = 'Test Position'; Kind = 'grid'; Target = $c.Name; Label = $c.Name; Apply = $null; Options = @(); Min = $null; Max = $null }
                }
            } else { $ctx.Notes.Add('census: Project property grid view not found; no grid inputs') }
            # Fins once, with Board Dynamics ON: their L/D readout exists only there (wiki, Fin and STL observations).
            $man = @($man | Where-Object { -not ($_.Mode -eq 'S' -and "$($_.TabPath)" -like 'Fins*') })
            $man = @($man | Sort-Object @{ e = { $_.Mode -eq 'D' } }, TabPath)
            foreach ($i in $man) {
                $base = $null
                try { [void](Enter-SwdSweepInputView -Spec $i -Ctx $ctx); $base = Read-SwdSweepInput -Spec $i -Ctx $ctx } catch {
                    if ($_.Exception.Message -like 'SWD-*') { throw }
                    $ctx.Notes.Add("base of $($i.Id): $(Format-MessageForDisplay $_.Exception.Message)")
                }
                $opts = @($i.Options)
                if ($i.Kind -eq 'combo') { $h = Get-SwdSweepHandle -Aid $i.Target -Ctx $ctx; $n = if ($h) { [SwdProbeNative]::ComboCount([intptr]$h, 3000) } else { 0 }; $opts = @(0..([math]::Max(0, $n - 1)) | ForEach-Object { "$_" }) }
                if ($i.Kind -eq 'slider') { $h = Get-SwdSweepHandle -Aid $i.Target -Ctx $ctx; if ($h) { $rg = [SwdProbeNative]::TrackRange([intptr]$h, 3000); $opts = @("$($rg[0])", "$($rg[1])", "$([int](($rg[0] + $rg[1]) / 2))"); $i.Min = $rg[0]; $i.Max = $rg[1] } }
                $k = if ($i.Kind -eq 'grid' -and @('True', 'False') -contains $base) { 'bool' } elseif ($i.Kind -eq 'grid') { 'numeric' } else { $i.Kind }
                $vals = @(Get-SwdSweepValue -Kind $k -Base $base -Min $i.Min -Max $i.Max -Options $opts)
                # Win32's enabled bit, not UIA's: in mode D the SizeConfig boxes and Apply buttons are
                # disabled while UIA still reported them enabled (measured 2026-10-01).
                $probe = @()
                if ($i.Kind -eq 'numeric') { $probe += Get-SwdSweepEditHandle -Aid $i.Target -Ctx $ctx }
                elseif ($i.Kind -eq 'radio') { foreach ($o in @($i.Options)) { $probe += Get-SwdSweepHandle -Aid $o -Ctx $ctx } }
                elseif ($i.Kind -ne 'grid') { $probe += Get-SwdSweepHandle -Aid $i.Target -Ctx $ctx }
                if ($i.Apply) { $probe += Get-SwdSweepHandle -Aid $i.Apply -Ctx $ctx }
                $off = @($probe | Where-Object { $_ -and -not [SwdWin]::IsWindowEnabled([intptr]$_) })
                $i | Add-Member -NotePropertyName Disabled -NotePropertyValue ([bool]$off.Count) -Force
                if ($off.Count) { $ctx.Notes.Add("dropped $($i.Id): disabled in mode $($i.Mode)") }
                $i | Add-Member -NotePropertyName Base -NotePropertyValue $base -Force
                $i | Add-Member -NotePropertyName Values -NotePropertyValue $vals -Force
            }
            $man = @($man | Where-Object { -not $_.Disabled })
            $ctx.Manifest = @($man)
            $why = "manifest: $($man.Count) inputs, $(@($man | ForEach-Object { @($_.Values).Count * 2 } | Measure-Object -Sum).Sum) map trials"
            return
        }
        if ($Pass -eq 'Map') { $ctx.Notes.Add("warm-up: $(Invoke-SwdSweepWarmup -Ctx $ctx)") }
        if ($Pass -eq 'Map') {
            foreach ($t in @(Get-SwdSweepPlan -Manifest $ctx.Manifest)) {
                if ($ctx.Done.ContainsKey($t.Id)) { continue }
                if ((Get-Date) -gt $deadline.AddSeconds(-75)) { $why = 'chunk time'; break }
                Assert-SwdProbeContinue -StopFile $StopFile
                $ctx.Attempts[$t.Id] = 1 + $(if ($ctx.Attempts.ContainsKey($t.Id)) { $ctx.Attempts[$t.Id] } else { 0 })
                try {
                    $rec = Invoke-SwdSweepTrial -Spec $t.Input -Value $t.Value -Rep $t.Rep -Ctx $ctx
                } catch {
                    $msg = $_.Exception.Message
                    if ($msg -like 'SWD-PROBE-STOPPED*' -or $msg -like 'SWD-SWEEP-DIALOG*' -or $msg -like 'SWD-SWEEP-BOARD*' -or $msg -like 'SWD-PROBE-CURSOR*') { throw }
                    $failed++
                    Add-SwdSweepRecord -Ctx $ctx -File 'trials.jsonl' -Record ([pscustomobject]@{ Id = $t.Id; Input = $t.Input.Id; Value = $t.Value; Rep = $t.Rep; Error = (Format-MessageForDisplay $msg); Time = (Get-Date).ToString('o') })
                    if ($ctx.Attempts[$t.Id] -ge 2) { $ctx.Done[$t.Id] = $true; $ctx.Skipped.Add("$($t.Id): $(Format-MessageForDisplay $msg)") }
                    # Relaunch only when the app is gone or hung; any other error is recorded and the input
                    # is tried once more. (A relaunch costs a census of both modes, about 5 minutes.)
                    $healthy = $false
                    try { $mm = Get-SwdProbeMain -WaitMs 5000; $healthy = ([SwdProbeNative]::NullRoundTripMs([intptr]$mm.Handle, 5000) -ge 0) } catch { $healthy = $false }
                    if ($healthy) { $ctx.ModeNow = $null; $ctx.TabNow = $null; $ctx.ViewMode = $null; $ctx.Notes.Add("error on '$($t.Id)', app healthy: $(Format-MessageForDisplay $msg)"); Save-SwdSweepState -Ctx $ctx; continue }
                    $ctx.Notes.Add("restart after '$($t.Id)': $(Stop-SwdSweepApp)"); $ctx.Board = Start-SwdSweepApp -ExpectBoard $ctx.Board -StopFile $StopFile; $ctx.Restarts++; $ctx.RestorePendingPid = 0
                    foreach ($mode in @(Get-SwdSweepModesLeft -Ctx $ctx)) { Invoke-SwdSweepCensus -Mode $mode -Ctx $ctx }
                    $ctx.Ignore = @{}; $ctx.ViewMode = $null; $ctx.FinSelected = $false; $ctx.ModeNow = $null; $ctx.TabNow = $null
                    $ctx.Notes.Add("warm-up: $(Invoke-SwdSweepWarmup -Ctx $ctx)")
                    continue
                }
                Add-SwdSweepRecord -Ctx $ctx -File 'trials.jsonl' -Record $rec
                $ctx.Done[$t.Id] = $true; $done++
                # One relaunch per INPUT at most: each trial diffs against its own before-snapshot, so
                # drift left by an inexact restore does not falsify later trials, while a relaunch and
                # census cost about 5 minutes (measured: the tail-bevel combo restores inexactly).
                # An input restored by relaunch alone gets one after EVERY trial (W2), cap permitting.
                $byRelaunch = Test-SwdProbeListed -List $script:SweepRestoreByRelaunch -Label "$($t.Input.Target)"
                $relaunch = ($byRelaunch -or -not $rec.RestoreExact) -and $ctx.Restarts -lt 25 -and ($byRelaunch -or $ctx.Relaunched -notcontains $t.Input.Id)
                if (-not $rec.RestoreExact -and -not $relaunch) { $ctx.Notes.Add("restore inexact after '$($t.Id)'; no relaunch (already relaunched for this input, or cap)") }
                if ($relaunch) {
                    if ($ctx.Relaunched -notcontains $t.Input.Id) { $ctx.Relaunched.Add($t.Input.Id) }
                    $ctx.Notes.Add("restore $(if ($byRelaunch) { 'by relaunch' } else { 'inexact' }) after '$($t.Id)'; relaunching for a clean baseline: $(Stop-SwdSweepApp)")
                    $ctx.Board = Start-SwdSweepApp -ExpectBoard $ctx.Board -StopFile $StopFile; $ctx.Restarts++; $ctx.RestorePendingPid = 0
                    foreach ($mode in @(Get-SwdSweepModesLeft -Ctx $ctx)) { Invoke-SwdSweepCensus -Mode $mode -Ctx $ctx }
                    $ctx.Ignore = @{}; $ctx.ViewMode = $null; $ctx.FinSelected = $false; $ctx.ModeNow = $null; $ctx.TabNow = $null
                    $ctx.Notes.Add("warm-up: $(Invoke-SwdSweepWarmup -Ctx $ctx)")
                }
                Save-SwdSweepState -Ctx $ctx
            }
            # W2: a chunk never ends holding a board a restore did not put back (2026-10-01 left 9
            # 'no relaunch' notes and handed SWD back changed). Closing discards SWD's in-memory edits
            # (it saves a board only on a scan) and the next chunk launches a closed SWD itself. A
            # close, not a relaunch: a relaunch and census cost about 5 minutes past the chunk's time.
            if ($ctx.RestorePendingPid -and (Get-SwdSweepPid) -eq $ctx.RestorePendingPid) {
                $ctx.Notes.Add("chunk end with a restore pending in pid $($ctx.RestorePendingPid): closing SWD: $(Stop-SwdSweepApp)")
            }
            $ctx.RestorePendingPid = 0
            return
        }
        if ($Pass -eq 'Situation') {
            foreach ($i in @($ctx.Manifest | Where-Object { $_.Apply -eq 'ButtonApply_test_parameters' -and $_.Kind -eq 'numeric' })) {
                if (-not (ConvertTo-SwdNumber $i.Base).Ok) { continue }
                foreach ($v in @(Get-SwdSweepSituationLevel -Base (ConvertTo-SwdNumber $i.Base).Value -Target $i.Target)) {
                    $sid = "situation|$($i.Id)|$v"
                    if ($ctx.Done.ContainsKey($sid)) { continue }
                    if ((Get-Date) -gt $deadline.AddMinutes(-4)) { $why = 'chunk time'; return }
                    Assert-SwdProbeContinue -StopFile $StopFile
                    $rec = Invoke-SwdSweepSituationLevel -Spec $i -Value $v -Ctx $ctx
                    Add-SwdSweepRecord -Ctx $ctx -File 'situation.jsonl' -Record $rec
                    $ctx.Done[$sid] = $true; $done++
                    Save-SwdSweepState -Ctx $ctx
                }
            }
            $why = 'pass complete'
            return
        }
        if ($Pass -eq 'Curve') {
            $recs = @()
            $tf = Join-Path $Dir 'trials.jsonl'
            if (Test-Path -LiteralPath $tf) { $recs = @(Get-Content -LiteralPath $tf -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) }
            # Apply-situation inputs have their own pass: their button arms once per session.
            foreach ($i in @($ctx.Manifest | Where-Object { @('numeric', 'grid') -contains $_.Kind -and $_.Apply -ne 'ButtonApply_test_parameters' })) {
                $cid = "curve|$($i.Id)"
                if ($ctx.Done.ContainsKey($cid)) { continue }
                # Only inputs whose Map trials moved something other than pixels and themselves.
                # Outputs other than the input itself, its pixels and layout; two or more to earn a ladder.
                # (Writing a stored grid row moves only that row: measured on 27 of 28 rows.)
                $moved = @($recs | Where-Object { $_.Input -eq $i.Id -and $_.PSObject.Properties['Changes'] } | ForEach-Object { @($_.Changes) } |
                           Where-Object { $_ -and $_.Ch -ne 'image' -and -not $_.InScope -and $_.Field -ne 'Rect' -and $_.Item -ne $i.Target -and $_.Owner -ne $i.Target } |
                           ForEach-Object { "$($_.Owner)|$($_.Item)|$($_.Field)" } | Sort-Object -Unique)
                # The volume box is a TARGET volume (10 L on a 34 L board), so a ladder around it is not a
                # response curve; the S-mode geometry duplicates the D-mode one with fewer outputs.
                $dup = ($i.Mode -eq 'S' -and @($ctx.Manifest | Where-Object { $_.Mode -eq 'D' -and $_.Target -eq $i.Target }).Count)
                if ($moved.Count -lt 2 -or $dup -or $i.Target -eq 'NumericUpDownBoardVolumeInput' -or -not (ConvertTo-SwdNumber $i.Base).Ok) { $ctx.Done[$cid] = $true; continue }
                if ((Get-Date) -gt $deadline.AddMinutes(-7)) { $why = 'chunk time'; return }
                Assert-SwdProbeContinue -StopFile $StopFile
                $baseNum = (ConvertTo-SwdNumber $i.Base).Value
                # A fresh session per ladder: a geometry change zeroes the dynamics solution until the next
                # Apply situation, which would flatten every later ladder.
                $ctx.Notes.Add("curve relaunch for $($i.Id): $(Stop-SwdSweepApp)"); $ctx.Board = Start-SwdSweepApp -ExpectBoard $ctx.Board -StopFile $StopFile; $ctx.Restarts++
                foreach ($mode in @($i.Mode)) { Invoke-SwdSweepCensus -Mode $mode -Ctx $ctx }
                $ctx.Ignore = @{}; $ctx.ViewMode = $null; $ctx.FinSelected = $false; $ctx.ModeNow = $null; $ctx.TabNow = $null
                $ctx.Notes.Add("warm-up: $(Invoke-SwdSweepWarmup -Ctx $ctx)")
                $fac = if (@('TextBox_board_length_mm', 'TextBoxBoard_width_mm') -contains $i.Target) { @(0.9, 0.95, 0.975, 1.025, 1.05, 1.1) } else { @(0.5, 0.75, 0.9, 1.1, 1.25, 1.5) }
                try {
                    foreach ($rec in @(Invoke-SwdSweepCurve -Spec $i -Levels @(Get-SwdSweepCurveLevel -Base $baseNum -Min $i.Min -Max $i.Max -Factors $fac) -Ctx $ctx)) {
                        Add-SwdSweepRecord -Ctx $ctx -File 'curves.jsonl' -Record $rec
                    }
                } catch {
                    $msg = $_.Exception.Message
                    if ($msg -like 'SWD-PROBE-STOPPED*' -or $msg -like 'SWD-SWEEP-DIALOG*' -or $msg -like 'SWD-SWEEP-BOARD*' -or $msg -like 'SWD-PROBE-CURSOR*') { throw }
                    $ctx.Skipped.Add("${cid}: $(Format-MessageForDisplay $msg)"); $failed++
                } finally {
                    try { [void](Write-SwdSweepInput -Spec $i -Value $i.Base -Ctx $ctx) } catch { $ctx.Notes.Add("curve restore of $($i.Id): $(Format-MessageForDisplay $_.Exception.Message)") }
                }
                $ctx.Done[$cid] = $true; $done++
                Save-SwdSweepState -Ctx $ctx
            }
            return
        }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -like 'SWD-SWEEP-DIALOG*' -or $msg -like 'SWD-SWEEP-BOARD*' -or $msg -like 'SWD-PROBE-CURSOR*') { $ctx.Halted = Format-MessageForDisplay $msg }
        $why = Format-MessageForDisplay $msg
        throw
    } finally {
        Save-SwdSweepState -Ctx $ctx
        $script:SweepChunk = [pscustomobject]@{ Pass = $Pass; Done = $done; Failed = $failed; Stopped = $why; TotalDone = $ctx.Done.Count
                                                Manifest = @($ctx.Manifest).Count; Restarts = $ctx.Restarts; Halted = $ctx.Halted
                                                Notes = @($ctx.Notes | Select-Object -Last 5) }
    }
}

# ---------------------------------------------------------------------------------------
# Live-solver campaign (2026-10-05): speed x slope x scan position, Board Dynamics ON
# ---------------------------------------------------------------------------------------
# Measured 2026-10-05 (Benjamin's hand-run round, then this file's live checks):
#   - 'Apply situation' pushes flow ms and Slope into the solver, then disables itself.
#     Characters TYPED into either box (WM_CHAR, what a keyboard delivers) re-enable it;
#     WM_SETTEXT does not. That is why the 2026-10-01 sweep wrongly concluded that every
#     level needs a relaunch (AI-USE.md E107).
#   - Writing a box and then sending Enter or Tab by message applies nothing.
#   - The analysis grid keeps showing old numbers until the object it shows changes.
#     Selecting a scan position in the Project tree (N HydroScans > drift > Pos Y > Pos X)
#     shows that position on the Elements;analysis tab, re-solved at the applied situation
#     (lift close to the weight: 801-807 N on default_shortboard_Copy_1, ~500 N stored).
# Loop order (Benjamin, 2026-10-05): speed -> slope -> drift -> Pos Y -> Pos X. One Apply per
# (speed, slope) block, then one select-and-read per position.

$script:SolverIds = @{ Speed = 'TextBox_speed_ms'; Slope = 'TextBox_relative_flow_pente_deg'; Apply = 'ButtonApply_test_parameters'
                       Tree = 'TreeView_projet'; Drifts = 'ListBox_angles_drift_rapport_hydro' }
# Built from char codes so this file stays ASCII (Windows PowerShell 5.1 reads a BOM-less file as ANSI).
$script:SolverDragRow = 'train' + [char]0x00E9 + 'e_globale_horizontale_n'
# The 2026-10-01 Situation pass on default_shortboard_Copy_1, element 'Drift 0, Pos Y=0, X=0.467'
# as SWD showed it at launch (wiki raw note, Situation tables; 5 m/s from its snapshot).
$script:SolverReference = @(
    @{ Speed = '5'; Slope = '0'; Friction = 33.208843; Angle = 12.61379 }
    @{ Speed = '7.5'; Slope = '0'; Friction = 71.2205; Angle = 8.685789 }
    @{ Speed = '9'; Slope = '0'; Friction = 100.228806; Angle = 7.39678955 }
    @{ Speed = '10'; Slope = '0'; Friction = 122.071617; Angle = 6.753789; Drag = 201.171249 }
    @{ Speed = '11'; Slope = '0'; Friction = 145.8814; Angle = 6.22878933 }
    @{ Speed = '12.5'; Slope = '0'; Friction = 185.225632; Angle = 5.598789 }
    @{ Speed = '15'; Slope = '0'; Friction = 260.2865; Angle = 4.82778931 }
    @{ Speed = '20'; Slope = '0'; Friction = 444.93576; Angle = 3.86578941 }
    @{ Speed = '10'; Slope = '-3'; Friction = 122.071617; Angle = 6.80478954; Drag = 244.719788 }
    @{ Speed = '10'; Slope = '-2'; Friction = 122.071617; Angle = 6.78078938; Drag = 230.068375 }
    @{ Speed = '10'; Slope = '-1'; Friction = 122.071617; Angle = 6.76678944; Drag = 215.572784 }
    @{ Speed = '10'; Slope = '1'; Friction = 122.071617; Angle = 6.741789; Drag = 186.853043 }
    @{ Speed = '10'; Slope = '2'; Friction = 122.071617; Angle = 6.730789; Drag = 172.607315 }
    @{ Speed = '10'; Slope = '3'; Friction = 122.071617; Angle = 6.71978951; Drag = 158.41687 }
)

function ConvertFrom-SwdSolverNode {
    <#  A Project-tree item name as a scan-position part (pure): Kind root | drift | y | x and
        its number. SWD spells them 'N HydroScans', 'Analyse Positions drift 0<deg>',
        'Positons Y 0.027' and 'Positon X 0.467' (sic, measured 2026-10-05). $null otherwise.  #>
    param([AllowNull()][string]$Name)
    if (-not $Name) { return $null }
    $num = '(-?[0-9]+(?:\.[0-9]+)?)'
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($Name -match '^[0-9]+ HydroScans$') { return [pscustomobject]@{ Kind = 'root'; Value = $null } }
    if ($Name -match "^Analy[sz]e? Positions drift $num") { return [pscustomobject]@{ Kind = 'drift'; Value = [double]::Parse($Matches[1], $inv) } }
    if ($Name -match "^Positi?ons? Y $num$") { return [pscustomobject]@{ Kind = 'y'; Value = [double]::Parse($Matches[1], $inv) } }
    if ($Name -match "^Positi?ons? X $num$") { return [pscustomobject]@{ Kind = 'x'; Value = [double]::Parse($Matches[1], $inv) } }
    return $null
}

function ConvertFrom-SwdSolverElement {
    <#  The Elements;analysis tree's current element, 'Drift 0<deg><CR><LF>Pos Y=0 X=0.467', as
        Drift, Y, X (pure); $null when it does not read that way. Anchored at BOTH ends, the same
        rule as swd_solver_table.py label_matches() (S19): 'X=0.4 7' is not position X=0.4.  #>
    param([AllowNull()][string]$Name)
    if (-not $Name -or $Name -notmatch '^Drift\s+(-?[0-9.]+)\D*?Pos Y=(-?[0-9.]+)\s+X=(-?[0-9.]+)\s*$') { return $null }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    return [pscustomobject]@{ Drift = [double]::Parse($Matches[1], $inv); Y = [double]::Parse($Matches[2], $inv); X = [double]::Parse($Matches[3], $inv) }
}

function Test-SwdSolverElementIs {
    <#  $true when the element read from the analysis tree is the position that was selected. Drift
        and Y are compared by magnitude: the Project tree labels a position 'Positons Y 0.027' and
        the analysis tree shows the same one as 'Pos Y=-0.027', and in the +3 deg slope blocks it
        labels drift-2 positions 'Drift -2' (measured 2026-10-05/06). The raw label is kept.  #>
    param($Element, $Position)
    if (-not $Element -or -not $Position) { return $false }
    return ([math]::Abs([math]::Abs($Element.Drift) - [math]::Abs($Position.Drift)) -lt 1e-6 -and [math]::Abs([math]::Abs($Element.Y) - [math]::Abs($Position.Y)) -lt 1e-6 -and [math]::Abs($Element.X - $Position.X) -lt 1e-6)
}

function Test-SwdSolverDriftWithin {
    <#  $true when a drift is inside -MaxDrift by MAGNITUDE (pure; S13). A one-sided '-le' let a
        drift of -25 through a limit of 20, and the tree's labels can carry a sign (measured:
        the analysis tree shows 'Drift -2').  #>
    param([Parameter(Mandatory)][double]$Drift, [Parameter(Mandatory)][double]$MaxDrift)
    return ([math]::Abs($Drift) -le $MaxDrift)
}

function Get-SwdSolverPositionList {
    <#  Every Pos X item under the HydroScans root, in tree order (pure over a walk of the
        Project tree): Drift, Y, X, the item's Name and Nth (its index among role-36 items of
        that name, which is how Act addresses it), and the drift and Pos Y items above it,
        which must be expanded before it can be selected. -MaxDrift leaves larger drifts out.  #>
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Nodes, [double]$MaxDrift = 90)
    $seen = @{}; $drift = $null; $y = $null; $inRoot = $false
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($n in @($Nodes)) {
        if ($null -eq $n -or "$($n.Role)" -ne '36' -or -not $n.Name) { continue }
        $nth = if ($seen.ContainsKey($n.Name)) { $seen[$n.Name] } else { 0 }
        $seen[$n.Name] = $nth + 1
        $p = ConvertFrom-SwdSolverNode $n.Name
        if (-not $p) { continue }
        switch ($p.Kind) {
            'root' { $inRoot = $true; $drift = $null; $y = $null }
            'drift' { $drift = [pscustomobject]@{ Value = $p.Value; Name = $n.Name; Nth = $nth }; $y = $null }
            'y' { $y = [pscustomobject]@{ Value = $p.Value; Name = $n.Name; Nth = $nth } }
            'x' {
                if ($inRoot -and $drift -and $y -and (Test-SwdSolverDriftWithin -Drift $drift.Value -MaxDrift $MaxDrift)) {
                    $out.Add([pscustomobject]@{ Drift = $drift.Value; Y = $y.Value; X = $p.Value; Name = $n.Name; Nth = $nth; DriftNode = $drift; YNode = $y })
                }
            }
        }
    }
    return $out.ToArray()
}

function Get-SwdSolverBlock {
    <#  The (speed, slope) blocks in run order (pure): speed outermost, slope inside it.  #>
    param([Parameter(Mandatory)][string[]]$Speeds, [Parameter(Mandatory)][string[]]$Slopes)
    foreach ($v in $Speeds) { foreach ($s in $Slopes) { [pscustomobject]@{ Speed = $v; Slope = $s; Id = "v=$v|s=$s" } } }
}

function ConvertTo-SwdSolverLevel {
    <#  A level list as plain decimal strings (pure). 'powershell -File' hands '5,10,20' over as
        ONE string, so commas are split here; every value must be a plain number.  #>
    param([AllowEmptyCollection()][string[]]$Levels)
    $out = @()
    foreach ($l in @($Levels)) { foreach ($p in ("$l" -split ',')) { $t = $p.Trim(); if ($t) { [void](ConvertTo-SwdSolverKey -Value $t); $out += $t } } }
    return $out
}

function Get-SwdSolverFingerprint {
    <#  A short SHA-256 over the board, the levels and the positions (pure): a resumed loop must
        be running the same plan, or its cursor means something else.  #>
    param([string]$Board, [string[]]$Speeds, [string[]]$Slopes, [AllowEmptyCollection()]$Positions)
    # Invariant culture (S14): '-f' formats a double in the CURRENT culture, so a resume under fr-FR
    # printed '0,467' and refused its own plan. Identical to the en-US text, so no saved print changes.
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $text = "$Board`n$($Speeds -join ',')`n$($Slopes -join ',')`n" + ((@($Positions) | ForEach-Object { [string]::Format($inv, '{0}|{1}|{2}', $_.Drift, $_.Y, $_.X) }) -join ';')
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-', '').Substring(0, 16) } finally { $sha.Dispose() }
}

function Get-SwdSolverCursor {
    <#  Read number -> (block index, position index) (pure). Reads are numbered block-major.  #>
    param([Parameter(Mandatory)][int]$Cursor, [Parameter(Mandatory)][int]$Positions)
    if ($Positions -le 0) { throw 'no positions' }
    return [pscustomobject]@{ Block = [int][math]::Floor($Cursor / $Positions); Position = $Cursor % $Positions }
}

function ConvertTo-SwdSolverKey {
    <#  The characters to type for a situation value (pure). Only a plain decimal number is
        ever typed into SWD: ASCII digits, one leading minus, one point. Anything else throws.  #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    # \A and \z, not ^ and $: .NET's $ also matches before a final line feed, so '10' + LF passed
    # and the LF (char 10) would have been typed into SWD (S1).
    if ($Value -notmatch '\A-?[0-9]{1,3}(\.[0-9]{1,4})?\z') { throw "Refusing to type '$(ConvertTo-SwdSafeText $Value 20)': not a plain decimal number." }
    return $Value.ToCharArray()
}

function Compare-SwdSolverRow {
    <#  Names of rows whose value differs between two reads (pure), absent rows included.  #>
    param($A, $B)
    $a = if ($A) { $A } else { @{} }; $b = if ($B) { $B } else { @{} }
    $names = @(@($a.Keys) + @($b.Keys) | Sort-Object -Unique)
    return @($names | Where-Object { -not ($a.Contains($_) -and $b.Contains($_) -and "$($a[$_])" -ceq "$($b[$_])") })
}

function Get-SwdSolverRelDiff {
    <#  |a - b| / |b| (pure); $null when either is not a number or b is zero.  #>
    param($A, $B)
    $x = ConvertTo-SwdNumber -Text "$A"; $y = ConvertTo-SwdNumber -Text "$B"
    if (-not $x.Ok -or -not $y.Ok -or [double]$y.Value -eq 0) { return $null }
    return [math]::Abs(([double]$x.Value - [double]$y.Value) / [double]$y.Value)
}

function Compare-SwdSolverPositionCount {
    <#  Pos X items per (drift, Pos Y) in the tree against rows per (drift_deg, roll_case) in
        elements.csv for one board (pure). roll_case k is the k-th Pos Y of that drift, ascending
        (wiki: SWD Operating Points Dataset). Returns one row per key with both counts.  #>
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Positions, [Parameter(Mandatory)][AllowEmptyCollection()]$ElementRows)
    $tree = @{}
    foreach ($g in @(@($Positions) | Group-Object Drift)) {
        $ys = @($g.Group | ForEach-Object { [double]$_.Y } | Sort-Object -Unique)
        for ($k = 0; $k -lt $ys.Count; $k++) { $tree['{0}|{1}' -f $g.Name, $k] = @($g.Group | Where-Object { [double]$_.Y -eq $ys[$k] }).Count }
    }
    $csv = @{}
    foreach ($r in @($ElementRows)) { $key = '{0}|{1}' -f [double]$r.drift_deg, [int]$r.roll_case; $csv[$key] = 1 + $(if ($csv.ContainsKey($key)) { $csv[$key] } else { 0 }) }
    $drifts = @(@($Positions) | ForEach-Object { "$([double]$_.Drift)" } | Sort-Object -Unique)
    $keys = @(@($tree.Keys) + @($csv.Keys | Where-Object { $drifts -contains $_.Split('|')[0] }) | Sort-Object -Unique)
    foreach ($k in $keys) {
        [pscustomobject]@{ Key = $k; Tree = $(if ($tree.ContainsKey($k)) { $tree[$k] } else { 0 }); Csv = $(if ($csv.ContainsKey($k)) { $csv[$k] } else { 0 }) }
    }
}

function ConvertTo-SwdSolverRecord {
    <#  One read as the record solver.jsonl holds (pure).  #>
    param([string]$Board, [string]$Speed, [string]$Slope, [Parameter(Mandatory)]$Position, $Read, [int]$Seq = 0)
    $rows = if ($Read -and $Read.Rows) { $Read.Rows } else { [ordered]@{} }
    $lift = if ($rows.Contains('portance_globale_verticale_n')) { $rows['portance_globale_verticale_n'] } else { $null }
    return [pscustomobject][ordered]@{
        Seq = $Seq; Board = $Board; Speed = $Speed; Slope = $Slope; Drift = $Position.Drift; Y = $Position.Y; X = $Position.X
        ElementMatch = $(if ($Read) { [bool]$Read.Match } else { $false }); Element = $(if ($Read) { $Read.ElementName } else { $null })
        Lift = $lift; SameAsPrevious = $(if ($Read) { [bool]$Read.SameAsPrevious } else { $false })
        SelectMs = $(if ($Read) { $Read.SelectMs } else { $null }); SettleMs = $(if ($Read) { $Read.SettleMs } else { $null })
        ReadMs = $(if ($Read) { $Read.ReadMs } else { $null }); Rows = $rows; Time = (Get-Date).ToString('o') }
}

# ---- live: session, situation, positions --------------------------------------------------

function Initialize-SwdSolverLaunch {
    <#  The part of a session that selects nothing in the Project tree: Board Dynamics ON, the Test
        Position and Elements;analysis tabs, and the 'view' census (cached per SWD process),
        registered in Ctx.Map. Pilot check P0 runs straight after it, on the element SWD shows at
        launch. Returns the census rows.
        The Project tab shows EITHER the property grid (a board or position selected) OR the
        hydroscan's drift list (the HydroScans root selected), and UIA3 sees only what is built and
        shown (measured 2026-10-05), so Initialize-SwdSolverSession adds a census per selection.  #>
    param([Parameter(Mandatory)]$Ctx)
    [void](Clear-SwdSweepPopup -StopFile $Ctx.StopFile)
    [void](Switch-SwdSweepMode -Mode 'D' -StopFile $Ctx.StopFile)
    $m = Get-SwdProbeMain
    foreach ($t in 'Test Position', 'Elements analysis') { [void](Select-SwdProbeTab -Handle $m.Handle -Name $t -StopFile $Ctx.StopFile) }
    [void](Wait-SwdProbeSettle -Handle $m.Handle -TimeoutMs 15000 -StopFile $Ctx.StopFile)
    $f = Join-Path $Ctx.Dir "census-$($m.Process.Id)-view.json"
    Assert-SwdProbeContinue -StopFile $Ctx.StopFile
    $rows = if (Test-Path -LiteralPath $f) { @((Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json).rows) } else { @((Invoke-SwdSweepUia3 -OutFile $f).rows) }
    Register-SwdSweepCensus -Rows $rows -Ctx $Ctx
    $Ctx.SpeedBox = Get-SwdSweepEditHandle -Aid $script:SolverIds.Speed -Ctx $Ctx
    $Ctx.SlopeBox = Get-SwdSweepEditHandle -Aid $script:SolverIds.Slope -Ctx $Ctx
    $Ctx.Board = Get-SwdProbeBoardName $m.Title
    return $rows
}

function Initialize-SwdSolverSession {
    <#  Per SWD session: Board Dynamics ON, the Test Position and Elements;analysis tabs shown,
        a UIA3 dump for the designer names (cached per SWD process), the HydroScans root
        expanded, the position list, and the board volume guard. Fills Ctx.  #>
    param([Parameter(Mandatory)]$Ctx, [double]$MaxDrift = 90, [double]$ExpectVolumeL = 0)
    $rows = Initialize-SwdSolverLaunch -Ctx $Ctx
    $m = Get-SwdProbeMain
    $census = { param($tag) Join-Path $Ctx.Dir "census-$($m.Process.Id)-$tag.json" }
    $load = { param($tag) $f = & $census $tag; if (Test-Path -LiteralPath $f) { @((Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json).rows) } else { @((Invoke-SwdSweepUia3 -OutFile $f).rows) } }
    $Ctx.Tree = Find-SwdSweepTree -Rows $rows -AutomationId $script:SolverIds.Tree
    if (-not $Ctx.Tree) { throw 'solver session: the Project tree was not found in the census' }
    $nodes = @([SwdProbeNative]::Walk([intptr]$Ctx.Tree, 6000, 20000))
    $root = @($nodes | Where-Object { $_.Role -eq '36' -and (ConvertFrom-SwdSolverNode $_.Name) -and (ConvertFrom-SwdSolverNode $_.Name).Kind -eq 'root' })
    if ($root.Count -ne 1) { throw "solver session: expected one HydroScans root in the Project tree, found $($root.Count)" }
    $Ctx.RootName = $root[0].Name
    $board = Get-SwdProbeBoardName $m.Title
    # The hydroscan's drift list: the tree shows ONE drift's positions, the one picked there
    # ("swap in the main HydroScan angle toggle", Benjamin 2026-09-29).
    Select-SwdSolverRoot -Ctx $Ctx
    if (-not (Get-SwdSweepHandle -Aid $script:SolverIds.Drifts -Ctx $Ctx)) { Register-SwdSweepCensus -Rows @(& $load 'root') -Ctx $Ctx }
    # Volume guard (the lesson of the 10 L restore flaw, 2026-10-01): the board grid's own volume.
    $r = Invoke-SwdProbeAcc -Handle $Ctx.Tree -Name "Board: $board" -Action select -Offscreen -StopFile $Ctx.StopFile
    [void](Wait-SwdProbeSettle -Handle $m.Handle -TimeoutMs 15000 -StopFile $Ctx.StopFile)
    if (-not (Get-SwdSweepHandle -Aid 'PropertyGridProjet_objet_select' -Ctx $Ctx)) { Register-SwdSweepCensus -Rows @(& $load 'board') -Ctx $Ctx }
    $Ctx.DriftList = Get-SwdSweepHandle -Aid $script:SolverIds.Drifts -Ctx $Ctx
    $Ctx.SpeedBox = Get-SwdSweepEditHandle -Aid $script:SolverIds.Speed -Ctx $Ctx
    $Ctx.SlopeBox = Get-SwdSweepEditHandle -Aid $script:SolverIds.Slope -Ctx $Ctx
    $Ctx.ApplyButton = Get-SwdSweepHandle -Aid $script:SolverIds.Apply -Ctx $Ctx
    foreach ($k in 'SpeedBox', 'SlopeBox', 'ApplyButton', 'DriftList') { if (-not $Ctx.$k) { throw "solver session: $k not found in the census" } }
    [void](Assert-SwdProbeButton -Handle $Ctx.ApplyButton)
    $Ctx.VolumeL = $null
    $gv = Get-SwdSweepGridView -Ctx $Ctx
    if ($r.Status -eq 'ok' -and $gv) {
        $v = @([SwdProbeNative]::Walk([intptr]$gv, 600, 8000) | Where-Object { $_.Role -eq '29' -and $_.Name -eq 'volume_litre' })
        if ($v.Count) { $Ctx.VolumeL = $v[0].Value }
    }
    $vol = ConvertTo-SwdNumber -Text "$($Ctx.VolumeL)"
    if ($ExpectVolumeL -gt 0 -and (-not $vol.Ok -or [math]::Abs([double]$vol.Value - $ExpectVolumeL) -gt 0.05)) {
        throw "SWD-SOLVER-VOLUME: the board grid reads volume_litre '$($Ctx.VolumeL)', expected $ExpectVolumeL L. Not reading a resized board."
    }
    # Every drift in the list, and the positions the tree shows for it.
    $e = Invoke-SwdProbeAcc -Handle $Ctx.Tree -Name $Ctx.RootName -Action expand -Offscreen -StopFile $Ctx.StopFile
    if ($e.Status -ne 'ok' -and $e.Status -notlike 'not-expandable (Collapse*') { throw "solver session: expanding '$($Ctx.RootName)': $($e.Status)" }
    Start-Sleep -Milliseconds 500
    $count = [SwdProbeNative]::ListCount([intptr]$Ctx.DriftList, 5000)
    if ($count -lt 1) { throw "solver session: the drift list reports $count items" }
    $all = New-Object System.Collections.Generic.List[object]
    $Ctx.Drifts = @()
    for ($i = 0; $i -lt $count; $i++) {
        Select-SwdSolverDrift -Index $i -Ctx $Ctx
        $ps = @(Get-SwdSolverPositionList -Nodes @([SwdProbeNative]::Walk([intptr]$Ctx.Tree, 6000, 20000)) -MaxDrift 90)
        $d = if ($ps.Count) { $ps[0].Drift } else { $null }
        $Ctx.Drifts += [pscustomobject]@{ Index = $i; Drift = $d; Positions = $ps.Count }
        foreach ($p in $ps) { if (Test-SwdSolverDriftWithin -Drift $p.Drift -MaxDrift $MaxDrift) { $p | Add-Member -NotePropertyName DriftIndex -NotePropertyValue $i -Force; $all.Add($p) } }
    }
    $Ctx.DriftNow = $count - 1
    $Ctx.Positions = $all.ToArray()
    if (-not $Ctx.Positions.Count) { throw 'solver session: no scan positions under the HydroScans root' }
    $Ctx.Expanded = @{}; $Ctx.Grid = 0; $Ctx.ElementTree = 0; $Ctx.LastRows = $null
    $Ctx.Board = $board
    return [pscustomobject]@{ Board = $board; VolumeL = $Ctx.VolumeL; Positions = $Ctx.Positions.Count; Pid = $m.Process.Id
                              Drifts = @($Ctx.Drifts | ForEach-Object { '{0}:{1}({2})' -f $_.Index, $_.Drift, $_.Positions }) }
}

function Select-SwdSolverRoot {
    <#  Make the HydroScans root the Project tree's selection (that is what shows the drift list).  #>
    param([Parameter(Mandatory)]$Ctx)
    $r = Invoke-SwdProbeAcc -Handle $Ctx.Tree -Name $Ctx.RootName -Action select -Offscreen -StopFile $Ctx.StopFile
    if ($r.Status -ne 'ok') { throw "solver: selecting '$($Ctx.RootName)': $($r.Status)" }
    [void](Wait-SwdProbeSettle -Handle (Get-SwdProbeMain).Handle -TimeoutMs 20000 -StopFile $Ctx.StopFile)
}

function Select-SwdSolverDrift {
    <#  Pick one drift in the hydroscan drift list (root selected first, so the list is shown).  #>
    param([Parameter(Mandatory)][int]$Index, [Parameter(Mandatory)]$Ctx)
    Select-SwdSolverRoot -Ctx $Ctx
    Assert-SwdProbeContinue -StopFile $Ctx.StopFile
    Assert-SwdProbeClass -Handle $Ctx.DriftList -Like '*LISTBOX*' -What 'drift list'
    $got = [SwdProbeNative]::ListSelect([intptr]$Ctx.DriftList, $Index, 5000)
    if ($got -ne $Index) { throw "solver: drift list asked for item $Index, reports $got" }
    [void](Wait-SwdProbeSettle -Handle (Get-SwdProbeMain).Handle -TimeoutMs 20000 -StopFile $Ctx.StopFile)
    $Ctx.DriftNow = $Index; $Ctx.Expanded = @{}
}

function Show-SwdSolverPosition {
    <#  Make one scan position the Project tree's selection: pick its drift in the hydroscan drift
        list if another is shown, expand its drift and Pos Y items, select its Pos X item. Tree
        items are reached even when scrolled out of view (-Offscreen); nothing uses the cursor.  #>
    param([Parameter(Mandatory)]$Position, [Parameter(Mandatory)]$Ctx)
    if ($Ctx.DriftNow -ne $Position.DriftIndex) { Select-SwdSolverDrift -Index ([int]$Position.DriftIndex) -Ctx $Ctx }
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        foreach ($a in @($Position.DriftNode, $Position.YNode)) {
            $k = "$($a.Name)#$($a.Nth)"
            if ($Ctx.Expanded.ContainsKey($k)) { continue }
            $e = Invoke-SwdProbeAcc -Handle $Ctx.Tree -Name $a.Name -Nth $a.Nth -Action expand -AllowAmbiguous -Offscreen -StopFile $Ctx.StopFile
            if ($e.Status -ne 'ok' -and $e.Status -notlike 'not-expandable (Collapse*') { throw "solver: expanding '$($a.Name)' #$($a.Nth): $($e.Status)" }
            $Ctx.Expanded[$k] = $true
            Start-Sleep -Milliseconds 300
        }
        $r = Invoke-SwdProbeAcc -Handle $Ctx.Tree -Name $Position.Name -Nth $Position.Nth -Action select -AllowAmbiguous -Offscreen -StopFile $Ctx.StopFile
        if ($r.Status -eq 'ok') { return $r }
        # SWD may rebuild or collapse the tree: forget what was expanded and try once more.
        $Ctx.Expanded = @{}
    }
    throw "solver: selecting '$($Position.Name)' #$($Position.Nth): $($r.Status)"
}

function Find-SwdSolverGrid {
    <#  The analysis grid's view window (it holds an Fx_friction_n row and is not the Project
        grid) and the Elements;analysis tree, from one walk of the main window.  #>
    param([Parameter(Mandatory)]$Ctx)
    $m = Get-SwdProbeMain
    $nodes = @((Get-SwdMsaaSnapshot -Handle $m.Handle).Nodes)
    $proj = Get-SwdSweepGridView -Ctx $Ctx
    $g = @($nodes | Where-Object { $_.Role -eq '29' -and $_.Name -eq 'Fx_friction_n' -and [int64]$_.Hwnd -ne [int64]$proj })
    $Ctx.Grid = if ($g.Count) { [int64]$g[0].Hwnd } else { 0 }
    $el = @($nodes | Where-Object { $_.Role -eq '36' -and (ConvertFrom-SwdSolverElement $_.Name) })
    $Ctx.ElementTree = if ($el.Count) { [int64]$el[0].Hwnd } else { 0 }
}

function Read-SwdSolverGrid {
    <#  The analysis grid as an ordered name -> value map, and the element it shows.  #>
    param([Parameter(Mandatory)]$Ctx)
    for ($try = 0; $try -lt 2; $try++) {
        if (-not $Ctx.Grid -or -not (Test-SwdHandle -Handle $Ctx.Grid) -or -not $Ctx.ElementTree) { Find-SwdSolverGrid -Ctx $Ctx }
        $rows = [ordered]@{}
        if ($Ctx.Grid) {
            foreach ($c in [SwdProbeNative]::Walk([intptr]$Ctx.Grid, 400, 5000)) { if ($c.Role -eq '29' -and $c.Name -and -not $rows.Contains($c.Name)) { $rows[$c.Name] = $c.Value } }
        }
        $name = $null
        if ($Ctx.ElementTree) {
            $first = @([SwdProbeNative]::Walk([intptr]$Ctx.ElementTree, 40, 3000) | Where-Object { $_.Role -eq '36' -and $_.Name } | Select-Object -First 1)
            if ($first.Count) { $name = $first[0].Name }
        }
        if ($rows.Contains('Fx_friction_n') -and $name) { return [pscustomobject]@{ Rows = $rows; ElementName = $name; Element = (ConvertFrom-SwdSolverElement $name) } }
        $Ctx.Grid = 0; $Ctx.ElementTree = 0
    }
    throw 'solver: the analysis grid or its element could not be read'
}

function Select-SwdSolverPosition {
    <#  Select one scan position in the Project tree (expanding its drift and Pos Y items
        first), wait for SWD to settle, and read the grid. A read whose element is not the one
        selected is retried; Match says how it ended. Never a cursor: MSAA select only.  #>
    param([Parameter(Mandatory)]$Position, [Parameter(Mandatory)]$Ctx)
    $m = Get-SwdProbeMain
    $sw = [Diagnostics.Stopwatch]::StartNew()
    [void](Show-SwdSolverPosition -Position $Position -Ctx $Ctx)
    $selMs = [int]$sw.ElapsedMilliseconds
    $s = Wait-SwdProbeSettle -Handle $m.Handle -TimeoutMs 20000 -StopFile $Ctx.StopFile
    $settleMs = [int]$sw.ElapsedMilliseconds - $selMs
    $read = $null
    for ($i = 0; $i -lt 4; $i++) {
        $read = Read-SwdSolverGrid -Ctx $Ctx
        if (Test-SwdSolverElementIs -Element $read.Element -Position $Position) { break }
        Start-Sleep -Milliseconds 500
    }
    $match = Test-SwdSolverElementIs -Element $read.Element -Position $Position
    $same = ($null -ne $Ctx.LastRows) -and (@(Compare-SwdSolverRow -A $Ctx.LastRows -B $read.Rows).Count -eq 0)
    $Ctx.LastRows = $read.Rows
    return [pscustomobject]@{ Rows = $read.Rows; ElementName = $read.ElementName; Match = $match; SameAsPrevious = $same
                              SelectMs = $selMs; SettleMs = $settleMs; SettleTimedOut = $s.TimedOut; ReadMs = [int]$sw.ElapsedMilliseconds - $selMs - $settleMs }
}

function Assert-SwdSolverBox {
    <#  Throws unless a situation box reads the requested value (S12). Checked right before and
        right after 'Apply situation': a keystroke still queued when the WM_SETTEXT fallback ran
        could concatenate ('10' + '10' = '1010'), and nothing compared the boxes with the request.  #>
    param([Parameter(Mandatory)][int64]$Handle, [Parameter(Mandatory)][string]$Value, [string]$What = 'situation',
          [scriptblock]$Reader = { param($h) Get-SwdText -Handle $h })
    $txt = & $Reader $Handle
    $got = ConvertTo-SwdNumber -Text "$txt"; $want = ConvertTo-SwdNumber -Text $Value
    if (-not $got.Ok -or -not $want.Ok -or [math]::Abs([double]$got.Value - [double]$want.Value) -ge 1e-9) {
        throw "solver: the $What box reads '$(ConvertTo-SwdSafeText "$txt" 20)', not '$(ConvertTo-SwdSafeText $Value 20)'."
    }
}

function Set-SwdSolverSituation {
    <#  Type speed and slope into their boxes as keystrokes (posted WM_CHAR after selecting the
        whole text), then press 'Apply situation' once. Typing is what re-enables the button
        (measured 2026-10-05); a box that does not read the value afterwards is set exactly by
        WM_SETTEXT before the press. The button's enabled bit is checked both sides.  #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Speed, [Parameter(Mandatory)][string]$Slope, [Parameter(Mandatory)]$Ctx)
    if (-not $PSCmdlet.ShouldProcess('SWD Test Position', "apply speed $Speed m/s, slope $Slope deg")) { return $null }
    $m = Get-SwdProbeMain
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $notes = @()
    foreach ($pair in @(@($Ctx.SpeedBox, $Speed, 'speed'), @($Ctx.SlopeBox, $Slope, 'slope'))) {
        $h = [int64]$pair[0]; $v = [string]$pair[1]
        $keys = ConvertTo-SwdSolverKey -Value $v
        # The kill switch before each box, before a fallback write and before the press (W3).
        Assert-SwdProbeContinue -StopFile $Ctx.StopFile
        if ([SwdProbeNative]::Send([intptr]$h, 0x00B1, 0, -1, 3000) -eq [long]::MinValue) { throw "solver: EM_SETSEL to the $($pair[2]) box was not delivered" }
        foreach ($c in $keys) { [void][SwdWin]::PostMessage([intptr]$h, 0x0102, [intptr][int]$c, [intptr]1) }
        $want = (ConvertTo-SwdNumber -Text $v).Value
        $t = [Diagnostics.Stopwatch]::StartNew(); $ok = $false; $txt = $null
        while ($t.ElapsedMilliseconds -lt 5000) {
            Start-Sleep -Milliseconds 100
            $txt = Get-SwdText -Handle $h; $got = ConvertTo-SwdNumber -Text "$txt"
            if ($got.Ok -and [math]::Abs([double]$got.Value - [double]$want) -lt 1e-9) { $ok = $true; break }
        }
        if (-not $ok) {
            $notes += "$($pair[2]): typed '$v' read '$txt'; set by WM_SETTEXT"
            Assert-SwdProbeContinue -StopFile $Ctx.StopFile
            $w = Set-SwdNumeric -Handle $h -Value $v -Confirm:$false
            if (-not $w.Ok) { throw "solver: the $($pair[2]) box would not take '$v' ($($w.Reason))" }
        }
    }
    $t = [Diagnostics.Stopwatch]::StartNew()
    while (-not [SwdWin]::IsWindowEnabled([intptr]$Ctx.ApplyButton) -and $t.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 100 }
    if (-not [SwdWin]::IsWindowEnabled([intptr]$Ctx.ApplyButton)) { throw 'solver: Apply situation did not re-enable after typing' }
    # Both boxes read what was asked right before the press, and again after it (S12).
    Assert-SwdSolverBox -Handle $Ctx.SpeedBox -Value $Speed -What 'speed'
    Assert-SwdSolverBox -Handle $Ctx.SlopeBox -Value $Slope -What 'slope'
    Assert-SwdProbeContinue -StopFile $Ctx.StopFile
    [void](Assert-SwdProbeButton -Handle $Ctx.ApplyButton)
    [void](Invoke-SwdButton -Handle $Ctx.ApplyButton -Post -Confirm:$false)
    $t = [Diagnostics.Stopwatch]::StartNew()
    while ([SwdWin]::IsWindowEnabled([intptr]$Ctx.ApplyButton) -and $t.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 100 }
    $applied = -not [SwdWin]::IsWindowEnabled([intptr]$Ctx.ApplyButton)
    [void](Wait-SwdProbeSettle -Handle $m.Handle -TimeoutMs 30000 -StopFile $Ctx.StopFile)
    $pops = @(Clear-SwdSweepPopup -TransientMs 3000 -StopFile $Ctx.StopFile)
    if (-not $applied) { throw 'solver: Apply situation was pressed but did not disable itself; the press may not have taken' }
    # A late keystroke after the press changed what it applied: never recorded as this block.
    Assert-SwdSolverBox -Handle $Ctx.SpeedBox -Value $Speed -What 'speed'
    Assert-SwdSolverBox -Handle $Ctx.SlopeBox -Value $Slope -What 'slope'
    $Ctx.Applied = "v=$Speed|s=$Slope"; $Ctx.LastRows = $null
    return [pscustomobject]@{ Speed = $Speed; Slope = $Slope; SpeedRead = (Get-SwdText -Handle $Ctx.SpeedBox); SlopeRead = (Get-SwdText -Handle $Ctx.SlopeBox)
                              ApplyMs = [int]$sw.ElapsedMilliseconds; Dialogs = $pops; Notes = $notes }
}

function Find-SwdSolverPosition {
    <#  The position at (Drift, Y, X), or $null.  #>
    param([Parameter(Mandatory)]$Ctx, [double]$Drift, [double]$Y, [double]$X)
    $p = @($Ctx.Positions | Where-Object { [math]::Abs($_.Drift - $Drift) -lt 1e-6 -and [math]::Abs($_.Y - $Y) -lt 1e-6 -and [math]::Abs($_.X - $X) -lt 1e-6 })
    if ($p.Count) { return $p[0] }
    return $null
}

# ---- live: pilot (P0-P9) and the loop ---------------------------------------------------

function Save-SwdSolverJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Object)
    Write-SwdProbeJson -Path $Path -Object $Object -Depth 10
}

function Read-SwdSolverJson {
    param([Parameter(Mandatory)][string]$Path)
    return (Read-SwdProbeState -Path $Path)
}

function Invoke-SwdSolverPilotCheck {
    <#  One pilot check by id. Returns @{ Pass = $true | $false | $null; ... } and appends every
        read it takes to pilot_reads.jsonl.  #>
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)]$Ctx)
    $board = $Ctx.Board
    # First / last of a possibly empty list: under StrictMode an out-of-range index throws.
    $one = { param($list, [switch]$Last) $a = @($list); if (-not $a.Count) { $null } elseif ($Last) { $a[$a.Count - 1] } else { $a[0] } }
    # P0 runs before the session lists positions (Initialize-SwdSolverLaunch only).
    if ($Id -ne 'P0') {
        $ref = Find-SwdSolverPosition -Ctx $Ctx -Drift 0 -Y 0 -X 0.467
        if (-not $ref) { $ref = & $one $Ctx.Positions -Last }
        if (-not $ref) { throw 'pilot: no scan positions' }
        $otherX = & $one @($Ctx.Positions | Where-Object { $_.Drift -eq $ref.Drift -and $_.Y -eq $ref.Y -and $_.X -ne $ref.X }) -Last
        $ys = @($Ctx.Positions | Where-Object { $_.Drift -eq $ref.Drift } | ForEach-Object { $_.Y } | Sort-Object -Unique)
        $otherY = if ($ys.Count -gt 1) { & $one @($Ctx.Positions | Where-Object { $_.Drift -eq $ref.Drift -and $_.Y -eq $ys[1] }) -Last } else { $null }
        $d1 = & $one @($Ctx.Positions | Where-Object { $_.Drift -gt $ref.Drift } | ForEach-Object { $_.Drift } | Sort-Object -Unique)
        $otherD = if ($null -ne $d1) { & $one @($Ctx.Positions | Where-Object { $_.Drift -eq $d1 -and $_.Y -eq $ref.Y }) -Last } else { $null }
    }
    $log = { param($tag, $speed, $slope, $pos, $read) Add-SwdSweepRecord -Ctx $Ctx -File 'pilot_reads.jsonl' -Record ([pscustomobject]@{ Check = $Id; Tag = $tag; Record = (ConvertTo-SwdSolverRecord -Board $board -Speed $speed -Slope $slope -Position $pos -Read $read) }) }
    $at = { param($pos) Select-SwdSolverPosition -Position $pos -Ctx $Ctx }
    $key = { param($read) [ordered]@{ Friction = $read.Rows['Fx_friction_n']; Lift = $read.Rows['portance_globale_verticale_n']; Angle = $read.Rows['angle_planing_effectif_deg']
                                        Drag = $read.Rows[$script:SolverDragRow]; Area = $read.Rows['surface_contact_m2']; Yaw = $read.Rows['Moment_yaw_hydrodynamic_nm'] } }
    switch ($Id) {
        'P0' {
            # The element SWD shows at launch, through the Elements;analysis tree, before any
            # Project-tree selection: the 2026-10-01 route. Only meaningful in a fresh session.
            $m = Get-SwdProbeMain
            $nodes = @((Get-SwdMsaaSnapshot -Handle $m.Handle).Nodes)
            $el = @($nodes | Where-Object { $_.Role -eq '36' -and (ConvertFrom-SwdSolverElement $_.Name) })
            if (-not $el.Count) { return @{ Pass = $null; Note = 'no element in the Elements;analysis tree' } }
            [void](Invoke-SwdProbeAcc -Handle $el[0].Hwnd -Name $el[0].Name -Action select -AllowAmbiguous -StopFile $Ctx.StopFile)
            [void](Wait-SwdProbeSettle -Handle $m.Handle -TimeoutMs 15000 -StopFile $Ctx.StopFile)
            $read = Read-SwdSolverGrid -Ctx $Ctx
            $sp = Get-SwdText -Handle $Ctx.SpeedBox; $sl = Get-SwdText -Handle $Ctx.SlopeBox
            $pos = if ($read.Element) { $read.Element } else { [pscustomobject]@{ Drift = $null; Y = $null; X = $null } }
            & $log 'launch' $sp $sl $pos ([pscustomobject]@{ Rows = $read.Rows; ElementName = $read.ElementName; Match = $true; SameAsPrevious = $false; SelectMs = $null; SettleMs = $null; ReadMs = $null })
            $refRow = @($script:SolverReference | Where-Object { $_.Speed -eq "$sp" -and $_.Slope -eq "$sl" })
            $k = & $key $read
            if (-not $refRow.Count) { return @{ Pass = $null; Boxes = "$sp / $sl"; Values = $k; Note = 'no 2026-10-01 reference for these boxes' } }
            $df = Get-SwdSolverRelDiff $k.Friction $refRow[0].Friction; $da = Get-SwdSolverRelDiff $k.Angle $refRow[0].Angle
            return @{ Pass = ($null -ne $df -and $df -lt 1e-5 -and $null -ne $da -and $da -lt 1e-5); Boxes = "$sp / $sl"; Element = $read.ElementName; Values = $k; RelDiffFriction = $df; RelDiffAngle = $da }
        }
        'P1' {
            $s = Set-SwdSolverSituation -Speed '10' -Slope '0' -Ctx $Ctx
            [void](& $at $otherX); $a = & $at $ref; & $log 'v10' '10' '0' $ref $a
            $s2 = Set-SwdSolverSituation -Speed '12.5' -Slope '0' -Ctx $Ctx
            $Ctx.P2Immediate = Read-SwdSolverGrid -Ctx $Ctx
            [void](& $at $otherX); $b = & $at $ref; & $log 'v12.5' '12.5' '0' $ref $b
            $want = 185.225632 / 122.071617
            $ratio = (ConvertTo-SwdNumber $b.Rows['Fx_friction_n']).Value / (ConvertTo-SwdNumber $a.Rows['Fx_friction_n']).Value
            return @{ Pass = ([math]::Abs($ratio / $want - 1) -lt 0.01); FrictionRatio = $ratio; ExpectedRatio = $want; At10 = (& $key $a); At12_5 = (& $key $b); Apply = @($s, $s2) }
        }
        'P2' {
            # Does the Apply itself refresh the grid, or only a re-selection? (P1 kept the read
            # taken straight after its 12.5 m/s Apply, before any re-selection.)
            $imm = $Ctx.P2Immediate
            [void](& $at $otherX); $b = & $at $ref; & $log 'reselect' '12.5' '0' $ref $b
            [void](& $at $otherX); $c = & $at $ref; & $log 'reselect-again' '12.5' '0' $ref $c
            $diffImm = if ($imm) { @(Compare-SwdSolverRow -A $imm.Rows -B $b.Rows).Count } else { $null }
            $diffAgain = @(Compare-SwdSolverRow -A $b.Rows -B $c.Rows).Count
            return @{ Pass = ($diffAgain -eq 0); RowsDifferingApplyVsReselect = $diffImm; ImmediateElement = $(if ($imm) { $imm.ElementName }); RowsDifferingBetweenReselects = $diffAgain
                      Note = 'RowsDifferingApplyVsReselect > 0 means the Apply alone left stale rows; 0 means it refreshed the grid itself' }
        }
        'P3' {
            [void](Set-SwdSolverSituation -Speed '10' -Slope '0' -Ctx $Ctx)
            $out = [ordered]@{}; $lifts = @()
            foreach ($pair in @(@('ref', $ref), @('otherX', $otherX), @('otherY', $otherY), @('otherDrift', $otherD))) {
                if (-not $pair[1]) { $out[$pair[0]] = 'none'; continue }
                $r = & $at $pair[1]; & $log $pair[0] '10' '0' $pair[1] $r
                $out[$pair[0]] = [ordered]@{ Position = '{0}|{1}|{2}' -f $pair[1].Drift, $pair[1].Y, $pair[1].X; Match = $r.Match; Values = (& $key $r) }
                $lifts += [double](ConvertTo-SwdNumber $r.Rows['portance_globale_verticale_n']).Value
            }
            $med = @($lifts | Sort-Object)[[int][math]::Floor(($lifts.Count - 1) / 2)]
            $dev = @($lifts | ForEach-Object { [math]::Abs($_ / $med - 1) })
            return @{ Pass = (@($dev | Where-Object { $_ -gt 0.01 }).Count -eq 0); MedianLift = $med; MaxLiftDeviation = (@($dev | Measure-Object -Maximum).Maximum); Reads = $out }
        }
        'P4' {
            $n = @($Ctx.Positions).Count
            $pick = @(0..9 | ForEach-Object { $Ctx.Positions[[int][math]::Floor($_ * ($n - 1) / 9)] })
            $fwd = @{}; $diff = [ordered]@{}
            foreach ($p in $pick) { $r = & $at $p; & $log 'forward' '10' '0' $p $r; $fwd['{0}|{1}|{2}' -f $p.Drift, $p.Y, $p.X] = $r.Rows }
            [array]::Reverse($pick)
            foreach ($p in $pick) {
                $k = '{0}|{1}|{2}' -f $p.Drift, $p.Y, $p.X
                $r = & $at $p; & $log 'reverse' '10' '0' $p $r
                $d = @(Compare-SwdSolverRow -A $fwd[$k] -B $r.Rows)
                if ($d.Count) { $diff[$k] = $d }
            }
            return @{ Pass = ($diff.Count -eq 0); Positions = $pick.Count; Differing = $diff }
        }
        'P5' {
            $res = @(); $worst = 0.0
            foreach ($lv in $script:SolverReference) {
                Assert-SwdProbeContinue -StopFile $Ctx.StopFile
                [void](Set-SwdSolverSituation -Speed $lv.Speed -Slope $lv.Slope -Ctx $Ctx)
                [void](& $at $otherX); $r = & $at $ref; & $log 'level' $lv.Speed $lv.Slope $ref $r
                $k = & $key $r
                $df = Get-SwdSolverRelDiff $k.Friction $lv.Friction; $da = Get-SwdSolverRelDiff $k.Angle $lv.Angle
                $dd = if ($lv.ContainsKey('Drag')) { Get-SwdSolverRelDiff $k.Drag $lv.Drag } else { $null }
                foreach ($x in @($df, $da, $dd)) { if ($null -ne $x -and $x -gt $worst) { $worst = $x } }
                $res += [ordered]@{ Speed = $lv.Speed; Slope = $lv.Slope; Friction = $k.Friction; Angle = $k.Angle; Drag = $k.Drag; Area = $k.Area; RelFriction = $df; RelAngle = $da; RelDrag = $dd }
            }
            [void](Set-SwdSolverSituation -Speed '10' -Slope '0' -Ctx $Ctx)
            return @{ Pass = ($worst -lt 1e-5); WorstRelDiff = $worst; Levels = $res; Route = 'Project-tree selection of the reference position' }
        }
        'P6' {
            $res = @()
            $base = & $at $ref
            $baseLift = (ConvertTo-SwdNumber $base.Rows['portance_globale_verticale_n']).Value
            foreach ($lv in @(@('3', '0'), @('4', '0'), @('25', '0'), @('10', '-30'), @('10', '-20'), @('10', '-10'), @('10', '10'), @('10', '20'), @('10', '30'))) {
                Assert-SwdProbeContinue -StopFile $Ctx.StopFile
                $row = [ordered]@{ Speed = $lv[0]; Slope = $lv[1] }
                try {
                    $s = Set-SwdSolverSituation -Speed $lv[0] -Slope $lv[1] -Ctx $Ctx
                    [void](& $at $otherX); $r = & $at $ref; & $log 'extreme' $lv[0] $lv[1] $ref $r
                    $lift = (ConvertTo-SwdNumber $r.Rows['portance_globale_verticale_n']).Value
                    $row.SpeedRead = $s.SpeedRead; $row.SlopeRead = $s.SlopeRead; $row.Dialogs = @($s.Dialogs); $row.Values = (& $key $r)
                    $row.LiftDeviation = [math]::Abs($lift / $baseLift - 1)
                    $row.Usable = ("$($s.SpeedRead)" -eq $lv[0] -and "$($s.SlopeRead)" -eq $lv[1] -and -not @($s.Dialogs).Count -and $row.LiftDeviation -lt 0.01)
                } catch {
                    if ($_.Exception.Message -like 'SWD-*') { throw }
                    $row.Error = Format-MessageForDisplay $_.Exception.Message; $row.Usable = $false
                }
                $res += $row
            }
            [void](Set-SwdSolverSituation -Speed '10' -Slope '0' -Ctx $Ctx)
            return @{ Pass = $null; Levels = $res; Note = 'informational: which extremes SWD accepts and solves' }
        }
        'P9b' {
            # Is each elements.csv row one tree position? Count Pos X items per (drift, Pos Y)
            # against rows per (drift, roll_case). Data only: no SWD interaction.
            $csvPath = Join-Path (Split-Path -Parent (Split-Path -Parent $script:ProbeRoot)) 'data\elements.csv'
            if (-not (Test-Path -LiteralPath $csvPath)) { return @{ Pass = $null; Note = 'elements.csv not found' } }
            $rows = @(Import-Csv -LiteralPath $csvPath -Encoding UTF8 | Where-Object { $_.board -eq $Ctx.Board })
            if (-not $rows.Count) { return @{ Pass = $null; Note = "no elements.csv rows for board '$($Ctx.Board)'" } }
            $cmp = @(Compare-SwdSolverPositionCount -Positions $Ctx.Positions -ElementRows $rows)
            $bad = @($cmp | Where-Object { $_.Tree -ne $_.Csv })
            return @{ Pass = ($bad.Count -eq 0); Keys = $cmp.Count; Mismatched = @($bad | ForEach-Object { '{0}: tree {1}, csv {2}' -f $_.Key, $_.Tree, $_.Csv })
                      TreePositions = @($Ctx.Positions).Count; CsvRows = @($rows | Where-Object { [double]$_.drift_deg -le ($Ctx.Positions | Measure-Object Drift -Maximum).Maximum }).Count }
        }
        'P9' {
            # Board Dynamics OFF: what the Project grid shows for a selected position (stored scan
            # values?), for comparison with elements.csv. Read-only apart from the mode toggle.
            # NOT RUN AGAIN (2026-10-05): selecting a position with Dynamics off raises a modal
            # 'Dynamics is off' Yes/No question that blocks the MSAA select until answered; the
            # one run was unblocked by answering No from a second process, and the grid then showed
            # live values, not stored ones. P9b answers the same question from data.
            throw 'P9 is retired: it blocks on a modal Yes/No question (see the comment); P9b replaces it.'
        }
    }
    throw "unknown pilot check '$Id'"
}

function Invoke-SwdSolver {
    <#  One chunk of the live-solver work, resumable.
          SolverPilot    checks P0-P6 and P9b (P7 timing and P8 safety are summarised from the
                         reads and by SolverRestore). State: <Dir>\pilot.json.
          SolverLoop     speed -> slope -> drift -> Pos Y -> Pos X over -Speeds x -Slopes,
                         drift <= -MaxDrift. State: <Dir>\loop_state.json; reads: solver.jsonl;
                         block controls: controls.jsonl.
          SolverRestore  types 10 m/s and 0 deg, applies, closes SWD, and compares the hash of
                         SWD's settings file with the 2026-09-30 backup (hash only; R9).  #>
    param([Parameter(Mandatory)][ValidateSet('SolverPilot', 'SolverLoop', 'SolverRestore')][string]$Pass, [Parameter(Mandatory)][string]$Dir,
          [Parameter(Mandatory)][string]$RunDir, [Parameter(Mandatory)][string]$StopFile, [double]$MaxMinutes = 8,
          [string[]]$Speeds = @('5', '10', '20'), [string[]]$Slopes = @('-3', '0', '3'), [double]$MaxDrift = 20, [double]$ExpectVolumeL = 0,
          [string]$SettingsBackup = (Join-Path $env:USERPROFILE 'SWD-backup\20260930\user.config'))
    $deadline = (Get-Date).AddMinutes($MaxMinutes)
    if ([SwdProbeNative]::KeepAwake() -eq 0) { throw 'Failed to set thread execution state.' }
    [void][IO.Directory]::CreateDirectory($Dir)
    $ctx = [pscustomobject]@{ Dir = $Dir; RunDir = $RunDir; StopFile = $StopFile; Map = @{}; Names = @{}; Census = @{}
                              SpeedBox = 0; SlopeBox = 0; ApplyButton = 0; Tree = 0; Grid = 0; ElementTree = 0; Positions = @(); Expanded = @{}
                              DriftList = 0; DriftNow = -1; Drifts = @(); RootName = $null
                              LastRows = $null; Applied = $null; Board = $null; VolumeL = $null; P2Immediate = $null }
    $done = 0; $why = 'pass complete'; $info = [ordered]@{}
    try {
        if ($Pass -eq 'SolverPilot') {
            $statePath = Join-Path $Dir 'pilot.json'
            $st = Read-SwdSolverJson -Path $statePath
            $checks = [ordered]@{}
            if ($st -and $st.PSObject.Properties['Checks']) { foreach ($p in $st.Checks.PSObject.Properties) { $checks[$p.Name] = $p.Value } }
            # P0 needs the element SWD shows at launch: a session no earlier chunk has touched. A
            # process started in the last 4 minutes (the runner's own launch) counts as fresh.
            $p = Get-Process SurfHydrodynamics -ErrorAction SilentlyContinue
            if (-not $checks.Contains('P0') -and $p -and ((Get-Date) - $p.StartTime).TotalMinutes -gt 4) { $info.Relaunch = Stop-SwdSweepApp }
            if (-not (Get-Process SurfHydrodynamics -ErrorAction SilentlyContinue)) { $info.Launched = Start-SwdSweepApp -StopFile $StopFile }
            if (-not $checks.Contains('P0')) {
                [void](Initialize-SwdSolverLaunch -Ctx $ctx)
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $r = Invoke-SwdSolverPilotCheck -Id 'P0' -Ctx $ctx
                $r.ElapsedMs = [int]$sw.ElapsedMilliseconds; $r.Time = (Get-Date).ToString('o')
                $checks['P0'] = $r; $done++
                Save-SwdSolverJson -Path $statePath -Object ([pscustomobject]@{ Board = $ctx.Board; VolumeL = $ctx.VolumeL; Checks = $checks })
            }
            $info.Session = Initialize-SwdSolverSession -Ctx $ctx -MaxDrift $MaxDrift -ExpectVolumeL $ExpectVolumeL
            foreach ($id in 'P1', 'P2', 'P3', 'P4', 'P5', 'P6', 'P9b') {
                if ($checks.Contains($id)) { continue }
                # P2 reads what P1 left in this process; if a chunk boundary fell between them, P1 reruns.
                if ($id -eq 'P2' -and -not $ctx.P2Immediate) { [void](Invoke-SwdSolverPilotCheck -Id 'P1' -Ctx $ctx) }
                if ((Get-Date) -gt $deadline.AddMinutes(-3)) { $why = 'chunk time'; break }
                Assert-SwdProbeContinue -StopFile $StopFile
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $r = Invoke-SwdSolverPilotCheck -Id $id -Ctx $ctx
                $r.ElapsedMs = [int]$sw.ElapsedMilliseconds; $r.Time = (Get-Date).ToString('o')
                $checks[$id] = $r; $done++
                Save-SwdSolverJson -Path $statePath -Object ([pscustomobject]@{ Board = $ctx.Board; VolumeL = $ctx.VolumeL; Checks = $checks })
            }
            $info.ChecksDone = @($checks.Keys)
            $info.Passes = [ordered]@{}; foreach ($k in $checks.Keys) { $info.Passes[$k] = $checks[$k].Pass }
            return
        }
        if ($Pass -eq 'SolverRestore') {
            if (-not (Get-Process SurfHydrodynamics -ErrorAction SilentlyContinue)) { $info.Launched = Start-SwdSweepApp -StopFile $StopFile }
            $info.Session = Initialize-SwdSolverSession -Ctx $ctx -MaxDrift 0 -ExpectVolumeL $ExpectVolumeL
            $info.Situation = Set-SwdSolverSituation -Speed '10' -Slope '0' -Ctx $ctx
            $info.Close = Stop-SwdSweepApp
            $cfg = @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'ShaperWaveDynamics') -Recurse -Filter 'user.config' -File -ErrorAction SilentlyContinue)
            $info.SettingsFiles = $cfg.Count
            if ($cfg.Count -eq 1 -and (Test-Path -LiteralPath $SettingsBackup)) {
                $info.SettingsMatchBackup = ((Get-FileHash -LiteralPath $cfg[0].FullName).Hash -eq (Get-FileHash -LiteralPath $SettingsBackup).Hash)
                # Setting NAMES only, never values: the file can hold library paths (R9).
                $names = { param($path) $h = @{}; foreach ($s in ([xml](Get-Content -LiteralPath $path -Raw)).SelectNodes('//setting')) { $h[$s.name] = $s.InnerXml }; $h }
                try {
                    $a = & $names $SettingsBackup; $b = & $names $cfg[0].FullName
                    $info.SettingsDiffer = @(@($a.Keys) + @($b.Keys) | Sort-Object -Unique | Where-Object { -not ($a.ContainsKey($_) -and $b.ContainsKey($_) -and $a[$_] -ceq $b[$_]) })
                } catch { $info.SettingsDiffer = "unreadable: $(Format-MessageForDisplay $_.Exception.Message)" }
            }
            $done = 1
            return
        }
        # SolverLoop
        $Speeds = @(ConvertTo-SwdSolverLevel $Speeds); $Slopes = @(ConvertTo-SwdSolverLevel $Slopes)
        if (-not (Get-Process SurfHydrodynamics -ErrorAction SilentlyContinue)) { $info.Launched = Start-SwdSweepApp -StopFile $StopFile }
        $info.Session = Initialize-SwdSolverSession -Ctx $ctx -MaxDrift $MaxDrift -ExpectVolumeL $ExpectVolumeL
        $blocks = @(Get-SwdSolverBlock -Speeds $Speeds -Slopes $Slopes)
        $n = @($ctx.Positions).Count
        $fp = Get-SwdSolverFingerprint -Board $ctx.Board -Speeds $Speeds -Slopes $Slopes -Positions $ctx.Positions
        $statePath = Join-Path $Dir 'loop_state.json'
        $st = Read-SwdSolverJson -Path $statePath
        if ($st -and $st.Fingerprint -ne $fp) { throw "SWD-SOLVER-PLAN: loop_state.json belongs to another plan ($($st.Fingerprint), now $fp). Use a new -SweepDir." }
        $cursor = if ($st) { [int]$st.Cursor } else { 0 }
        $first = @{}; if ($st -and $st.PSObject.Properties['BlockFirst'] -and $st.BlockFirst) { foreach ($p in $st.BlockFirst.PSObject.Properties) { $first[$p.Name] = $p.Value } }
        $total = $blocks.Count * $n
        $save = { Save-SwdSolverJson -Path $statePath -Object ([pscustomobject]@{ Fingerprint = $fp; Board = $ctx.Board; Speeds = $Speeds; Slopes = $Slopes; MaxDrift = $MaxDrift
                                                                                  Positions = $n; Total = $total; Cursor = $cursor; BlockFirst = $first }) }
        while ($cursor -lt $total) {
            if ((Get-Date) -gt $deadline.AddSeconds(-40)) { $why = 'chunk time'; break }
            Assert-SwdProbeContinue -StopFile $StopFile
            $c = Get-SwdSolverCursor -Cursor $cursor -Positions $n
            $b = $blocks[$c.Block]; $pos = $ctx.Positions[$c.Position]
            if ($ctx.Applied -ne $b.Id) {
                $s = Set-SwdSolverSituation -Speed $b.Speed -Slope $b.Slope -Ctx $ctx
                Add-SwdSweepRecord -Ctx $ctx -File 'situations.jsonl' -Record ([pscustomobject]@{ Block = $b.Id; Cursor = $cursor; Situation = $s; Time = (Get-Date).ToString('o') })
            }
            $r = Select-SwdSolverPosition -Position $pos -Ctx $ctx
            Add-SwdSweepRecord -Ctx $ctx -File 'solver.jsonl' -Record (ConvertTo-SwdSolverRecord -Board $ctx.Board -Speed $b.Speed -Slope $b.Slope -Position $pos -Read $r -Seq $cursor)
            if ($c.Position -eq 0) { $first[$b.Id] = $r.Rows }
            $cursor++; $done++
            # Block control: the block's first position read again at its end must match.
            if ($c.Position -eq $n - 1 -and $first.ContainsKey($b.Id)) {
                $r0 = Select-SwdSolverPosition -Position $ctx.Positions[0] -Ctx $ctx
                $ref0 = $first[$b.Id]
                $refRows = if ($ref0 -is [System.Collections.IDictionary]) { $ref0 } else { $h = [ordered]@{}; foreach ($p in $ref0.PSObject.Properties) { $h[$p.Name] = $p.Value }; $h }
                $d = @(Compare-SwdSolverRow -A $refRows -B $r0.Rows)
                Add-SwdSweepRecord -Ctx $ctx -File 'controls.jsonl' -Record ([pscustomobject]@{ Block = $b.Id; Match = ($d.Count -eq 0); Differing = $d; Time = (Get-Date).ToString('o') })
            }
            & $save
        }
        $info.Cursor = $cursor; $info.Total = $total; $info.Fingerprint = $fp
        if ($cursor -ge $total) { $why = 'pass complete' }
    } catch {
        $why = Format-MessageForDisplay $_.Exception.Message
        throw
    } finally {
        $script:SweepChunk = [pscustomobject]@{ Pass = $Pass; Done = $done; Stopped = $why; Info = $info }
    }
}

# ---------------------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------------------

function Invoke-SwdProbe {
    param([Parameter(Mandatory)][string]$Name, [double]$DeltaMm = 1.0, [int]$Repeats = 5, [string]$LogDir, [switch]$SkipLibraryHash,
          [string]$Pass = 'Map', [double]$MaxMinutes = 8, [string]$SweepDir,
          [string[]]$Speeds = @('5', '10', '20'), [string[]]$Slopes = @('-3', '0', '3'), [double]$MaxDrift = 20, [double]$ExpectVolumeL = 0)
    $solver = ($Name -eq 'Sweep' -and $Pass -like 'Solver*')
    # The default state directory is DATED (<LogDir>\<yyyy-MM-dd>\solver), so a multi-chunk loop
    # that crosses midnight would silently start over in a new, empty one (measured 2026-10-06:
    # two chunks re-ran reads 0-146). A loop names its state directory.
    if ($solver -and $Pass -eq 'SolverLoop' -and -not $SweepDir) { throw 'SolverLoop needs -SweepDir: the default state directory changes at midnight and the loop would start over.' }
    $root = Get-SwdProbeLogDir -Override $LogDir
    $run = Join-Path $root ('{0}-{1}' -f (Get-Date -Format 'HHmmss'), $(if ($Name -eq 'Sweep') { "Sweep-$Pass" } else { $Name }))
    [void][IO.Directory]::CreateDirectory($run)
    $stop = Join-Path $root $script:ProbeStopFileName
    if (Test-Path -LiteralPath $stop) { throw "A STOP file is present at $stop. Delete it by hand to run probes." }
    $transcript = Join-Path $run 'transcript.txt'
    Start-Transcript -LiteralPath $transcript | Out-Null
    $summary = [ordered]@{ Probe = $Name; Started = (Get-Date).ToString('o'); RunDir = $run
                           ReviewStatus = $(if ($solver) { 'solver pre-SQA (owner override 2026-09-30; Benjamin 2026-10-05: run tonight, SQA after)' }
                                            elseif ($Name -eq 'Sweep') { 'sweep pre-SQA (owner override 2026-09-30, extended 2026-10-01)' } else { 'SQA pass 2026-10-01' }) }
    # Before the try: finally reads them, and under StrictMode an unassigned variable there
    # would throw over the original error.
    $lib = $null; $libBefore = $null
    # Not '$sweepDir': PowerShell names are case-insensitive, so that local WAS the -SweepDir
    # parameter, and '$sweepDir = $null' threw the caller's directory away (found 2026-10-05:
    # -SweepDir was always ignored; no 2026-10-01 run passed it).
    $stateDir = $null
    if ($Name -eq 'Sweep') {
        $stateDir = Resolve-SwdWritableTarget -Path $(if ($SweepDir) { $SweepDir } else { Join-Path $root $(if ($solver) { 'solver' } else { 'sweep' }) })
        if (-not $stateDir) { throw 'Refusing the sweep directory (path guard).' }
    }
    try {
        # Hashed BEFORE anything can act on SWD (W4, SQA 2026-10-06). A Sweep may launch SWD just
        # below, and Start-SwdSweepApp answers dialogs (No, Cancel, Close, a lone OK): hashed after
        # it, a library change made during the launch was invisible, and a launch that threw left
        # the run with no library verdict. The T probes only READ until their own function acts.
        $lib = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'ShaperWaveDynamics documents\biblio'
        if ($Name -eq 'Sweep' -and -not $SkipLibraryHash) { $libBefore = Get-SwdLibraryHash -Root $lib }
        # The sweep relaunches SWD itself if it is gone: the board it expects is in state.json.
        if ($Name -eq 'Sweep' -and -not (Get-Process SurfHydrodynamics -ErrorAction SilentlyContinue)) {
            $sst = Read-SwdProbeState -Path (Join-Path $stateDir 'state.json')
            $expect = if ($sst -and $sst.PSObject.Properties['Board']) { $sst.Board } else { $null }
            $summary.Launched = Start-SwdSweepApp -ExpectBoard $expect -StopFile $stop
        }
        if ($Name -ne 'T17') {
            $self = [SwdWin]::IntegritySid($PID)
            $main = Get-SwdProbeMain
            $swdInt = [SwdWin]::IntegritySid($main.Process.Id)
            if ($self -ne $swdInt) { throw "Integrity mismatch: probe $(Format-Integrity $self), SWD $(Format-Integrity $swdInt). Run elevated." }
            $summary.Board = Assert-SwdProbeBoard -Title $main.Title
            $summary.Integrity = Format-Integrity $swdInt
        }
        if ($Name -ne 'T17' -and -not $SkipLibraryHash -and $null -eq $libBefore) { $libBefore = Get-SwdLibraryHash -Root $lib }
        $result = switch ($Name) {
            'Snapshot' { Invoke-SwdProbeSnapshotOnly -RunDir $run }
            'T9'  { Invoke-SwdProbeT9  -RunDir $run -StopFile $stop }
            'T11' { Invoke-SwdProbeT11 -RunDir $run -StopFile $stop }
            'T12' { Invoke-SwdProbeT12 -RunDir $run -StopFile $stop -DeltaMm $DeltaMm }
            'T13' { Invoke-SwdProbeT13 -RunDir $run -StopFile $stop -DeltaMm $DeltaMm -Repeats $Repeats }
            'T14' { Invoke-SwdProbeT14 -RunDir $run -StopFile $stop -DeltaMm $DeltaMm }
            'T17' { Invoke-SwdProbeT17 -RunDir $run }
            'Sweep' {
                $script:SweepChunk = $null
                if ($solver) {
                    Invoke-SwdSolver -Pass $Pass -Dir $stateDir -RunDir $run -StopFile $stop -MaxMinutes $MaxMinutes -Speeds $Speeds -Slopes $Slopes `
                                     -MaxDrift $MaxDrift -ExpectVolumeL $ExpectVolumeL
                } else { Invoke-SwdSweep -Pass $Pass -Dir $stateDir -RunDir $run -StopFile $stop -MaxMinutes $MaxMinutes }
                $script:SweepChunk
            }
        }
        $summary.Result = $result
        $summary.Outcome = 'completed'
    } catch {
        $summary.Outcome = 'error'
        $summary.Error = Format-MessageForDisplay $_.Exception.Message
        if ($Name -eq 'Sweep' -and (Test-Path variable:script:SweepChunk) -and $script:SweepChunk) { $summary.Result = $script:SweepChunk }
        throw
    } finally {
        # The only on-disk detector of an SWD write, so it runs on EVERY path (W3): a STOP,
        # a failed diff or a crashed probe is exactly the run that needs it. Its own
        # try/catch keeps a failed re-hash from replacing the original error.
        if ($libBefore) {
            try {
                $cmp = Compare-SwdLibraryHash -Before $libBefore -After (Get-SwdLibraryHash -Root $lib)
                $summary.Library = $cmp
                if (-not $cmp.Ok) { Write-Warning "LIBRARY CHANGED: added $($cmp.Added.Count), removed $($cmp.Removed.Count), changed $($cmp.Changed.Count)" }
            } catch {
                $why = Format-MessageForDisplay $_.Exception.Message
                $summary.Library = [pscustomobject]@{ Ok = $null; Error = $why }
                Write-Warning "LIBRARY NOT RE-CHECKED: $why"
            }
        }
        $summary.Finished = (Get-Date).ToString('o')
        Write-SwdProbeJson -Path (Join-Path $run 'summary.json') -Object ([pscustomobject]$summary) -Depth 8
        Stop-Transcript | Out-Null
    }
    return [pscustomobject]$summary
}

if ($Probe) {
    $ErrorActionPreference = 'Stop'
    $r = Invoke-SwdProbe -Name $Probe -DeltaMm $DeltaMm -Repeats $Repeats -LogDir $LogDir -SkipLibraryHash:$SkipLibraryHash `
                         -Pass $Pass -MaxMinutes $MaxMinutes -SweepDir $SweepDir -Speeds $Speeds -Slopes $Slopes -MaxDrift $MaxDrift -ExpectVolumeL $ExpectVolumeL
    $r.Result | ConvertTo-Json -Depth 6
    if ($r.PSObject.Properties['Library']) { 'Library: ' + ($r.Library | ConvertTo-Json -Compress) }
    "summary: $(Join-Path $r.RunDir 'summary.json')"
}
