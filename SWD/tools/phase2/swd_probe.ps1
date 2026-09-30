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
        checked against a DENYLIST (scan, delete, unlock, save, export, share, rename,
        create, reset, upload, CNC) immediately before every click.
      - Only tabs on an allowlist can be selected.
      - The loaded board's name must contain '_Copy'. Originals are refused.
      - Logs go only where swd_msg.ps1's path guard allows (never the install or library).
      - The SWD library is hashed before and after every run (SWD's own temp\ excluded);
        any other change is reported as LIBRARY CHANGED.
      - Every geometry probe restores the value it started from.

    REVIEW STATUS: written 2026-09-30 and RUN LIVE BEFORE ITS SQA PASS at Benjamin's
    explicit instruction (AI-USE.md section 4, 2026-09-30), overriding CLAUDE.md section 4
    for this file only. The SQA pass is owed.

    Windows PowerShell 5.1, elevated (SWD runs at High integrity; AI-USE.md E16/E17).
.PARAMETER Probe
    Snapshot | T9 | T11 | T12 | T13 | T14 | T17. Omit to dot-source the functions only.
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
    [ValidateSet('', 'Snapshot', 'T9', 'T11', 'T12', 'T13', 'T14', 'T17')]
    [string]$Probe = '',
    [ValidateRange(0.1, 50)][double]$DeltaMm = 1.0,
    [ValidateRange(1, 50)][int]$Repeats = 5,
    [string]$LogDir,
    [switch]$SkipLibraryHash
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
# Tabs a probe may select through MSAA.
$script:ProbeAllowedTabs = @('Shape', 'Fins', 'SizeConfig', 'Outline', 'Rockers', 'Guides Sections')
# Defence in depth: refused even if someone widens the allowlist.
$script:ProbeDenyPattern = '(?i)hydro\s*scan|scanner|delete|supprim|unlock|save|enregistr|export|share|partag|rename|renomm|create|cr[e\u00e9]er|sous-dossier|reset|upload|cnc|surfcommunity'
# Window-relative rectangles (x, y, w, h) in the 1845x1111 PrintWindow frame that change
# on their own: status-bar CPU and RAM readouts, the UnLock/section-slider block (T5), and
# the title bar, whose colour follows focus (T4c). Zeroed before frame hashing.
$script:ProbeNoiseRects = @(
    @(1504, 864, 224, 224), @(192, 1056, 64, 55), @(352, 1056, 64, 55), @(0, 0, 1845, 32), @(1280, 128, 32, 32)
)
# MSAA names that change with no action (status bar). Extended at run time by the
# volatility a null action reveals (T14 negative control).
$script:ProbeMsaaNoiseLike = @('Cpu:*', 'Available RAM*', 'Os:*')
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

  private static object[] Kids(IAccessible acc) {
    int count = 0;
    try { count = acc.accChildCount; } catch { return new object[0]; }
    if (count <= 0 || count > 10000) return new object[0];
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
}
'@
}

# ---------------------------------------------------------------------------------------
# Pure helpers (tested without SWD)
# ---------------------------------------------------------------------------------------

function ConvertTo-SwdProbeLabel {
    <#  Normalise a control or tab caption for allowlist matching: '&' accelerators,
        MSAA's ';' line breaks and runs of whitespace collapse; case is kept.  #>
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    return (($Text -replace '&', '' -replace '[;\r\n\t]+', ' ') -replace '\s+', ' ').Trim()
}

function Get-SwdProbeDenyMatch {
    param([AllowNull()][string]$Text)
    if (-not $Text) { return $null }
    $m = [regex]::Match($Text, $script:ProbeDenyPattern)
    if ($m.Success) { return $m.Value }
    return $null
}

function Test-SwdProbeAllowedButton {
    <#  $true only for an exact allowlisted caption that also clears the denylist.  #>
    param([AllowNull()][string]$Text)
    $label = ConvertTo-SwdProbeLabel $Text
    if (-not $label) { return $false }
    if (Get-SwdProbeDenyMatch $label) { return $false }
    return ($script:ProbeAllowedButtons -ccontains $label)
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
    return ($script:ProbeAllowedTabs -ccontains $label)
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
    if (Test-Path -LiteralPath $StopFile) { return "stop file present: $StopFile" }
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
    if (-not (Test-Path -LiteralPath $Root)) { throw "Library root not found: $Root" }
    $full = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\')
    $map = @{}
    foreach ($f in Get-ChildItem -LiteralPath $full -Recurse -File) {
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
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Object, [int]$Depth = 6)
    $json = $Object | ConvertTo-Json -Depth $Depth
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding $false))
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
    <#  Main window handle, verified by caption (MainWindowHandle is unstable: LIVE-RUN-FINDINGS).  #>
    $p = Get-SwdProcess
    $h = [int64]$p.MainWindowHandle
    $title = Get-SwdText -Handle $h
    if (-not $title -or $title -notlike 'FYN Shaper Wave Dynamics*') {
        throw "MainWindowHandle $h is captioned '$(ConvertTo-SwdSafeText $title 60)', not the SWD main window. Close dialogs and retry."
    }
    return [pscustomobject]@{ Process = $p; Handle = $h; Title = $title }
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
        Image = $img; ElapsedMs = [int]$sw.ElapsedMilliseconds
    }
    Write-SwdProbeJson -Path (Join-Path $Dir "$Label.json") -Object ([pscustomobject]@{
        Label = $snap.Label; Time = $snap.Time; Title = $snap.Title; Origin = $snap.Origin; Image = $snap.Image
        MsaaTruncated = $snap.MsaaTruncated; Controls = $controls; Msaa = $snap.Msaa }) -Depth 4
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
    param([Parameter(Mandatory)][string]$BeforeImage, [Parameter(Mandatory)][string]$AfterImage, [string]$Mask, $ExpectRects = @())
    $args2 = @((Join-Path $script:ProbeRoot 'swd_diff.py'), 'pair', $BeforeImage, $AfterImage)
    if ($Mask) { $args2 += @('--mask', $Mask) }
    # A loop, not a pipeline: piping an array of 4-element arrays can unroll them.
    $rects = @(); foreach ($r in @($ExpectRects)) { if ($null -ne $r -and @($r).Count -eq 4) { $rects += ,(@($r) -join ',') } }
    if ($rects.Count) { $args2 += '--expect'; $args2 += $rects }
    $json = & python @args2 2>&1
    if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Error = ($json -join ' ') } }
    return (($json -join "`n") | ConvertFrom-Json)
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
    $img = $null
    if ($Before.Image -and $After.Image) { $img = Invoke-SwdProbeImageDiff -BeforeImage $Before.Image -AfterImage $After.Image -Mask $Mask -ExpectRects $ExpectRects }
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
        Win32 = $win; Msaa = $ms; Image = $img
        OutOfScope = [pscustomobject]@{ Win32 = $outW; Msaa = $outM; ImageBoxes = $imgOut }
        OutOfScopeCount = $outW.Count + $outM.Count + $imgOut.Count
        InScopeCount = @($win | Where-Object { $_.InScope }).Count + @($ms | Where-Object { $_.InScope }).Count
        HiddenStructural = @($win | Where-Object { $_.Hidden }).Count + @($ms | Where-Object { $_.Hidden }).Count
    }
}

function Format-SwdProbeDiff {
    <#  Short human-readable lines for the console and the summary.  #>
    param($Diff, [int]$Max = 25)
    $lines = @()
    foreach ($d in @($Diff.OutOfScope.Win32) | Select-Object -First $Max) { $lines += "  W32  $($d.Kind) $($d.Field) h=$($d.Handle): '$($d.From)' -> '$($d.To)'" }
    foreach ($d in @($Diff.OutOfScope.Msaa) | Select-Object -First $Max) { $lines += "  MSAA $($d.Kind) $($d.Field) [$(ConvertTo-SwdSafeText $d.Name 40)]: '$(ConvertTo-SwdSafeText "$($d.From)" 40)' -> '$(ConvertTo-SwdSafeText "$($d.To)" 40)'" }
    foreach ($b in @($Diff.OutOfScope.ImageBoxes) | Select-Object -First $Max) { $lines += "  IMG  box $($b -join ',')" }
    return $lines
}

function Select-SwdProbeTab {
    <#  Select an allowlisted tab by TCM_SETCURFOCUS (T11). The MSAA walk finds the page tab
        by exact name; its window-anchored Key gives the owning tab control and the index.
        Never a mouse click: see SwdProbeNative.SelectTab.  #>
    param([Parameter(Mandatory)][int64]$Handle, [Parameter(Mandatory)][string]$Name)
    if (-not (Test-SwdProbeAllowedTab $Name)) { throw "Tab '$Name' is not on the probe allowlist." }
    $nodes = @((Get-SwdMsaaSnapshot -Handle $Handle).Nodes | Where-Object { $_.Role -eq '37' -and (ConvertTo-SwdProbeLabel $_.Name) -ceq $Name })
    if ($nodes.Count -ne 1) { throw "Expected exactly one '$Name' page tab, found $($nodes.Count)." }
    $n = $nodes[0]
    if ($n.Key -notmatch '^h(\d+):.*/(\d+)$') { throw "Page tab '$Name' has no usable key '$($n.Key)'." }
    $tab = [int64]$Matches[1]; $index = [int]$Matches[2]
    $sb = New-Object System.Text.StringBuilder 256
    [void][SwdWin]::GetClassName([intptr]$tab, $sb, 256)
    if ($sb.ToString() -notlike '*SysTabControl32*') { throw "Page tab '$Name' is owned by '$($sb.ToString())', not a tab control. Refusing." }
    $got = [SwdProbeNative]::SelectTab([intptr]$tab, $index)
    if ($got -ne $index) { throw "Tab '$Name': asked for index $index, tab control reports $got." }
    return [pscustomobject]@{ Tab = $Name; TabControl = $tab; Index = $index; Selected = $got }
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
        anything else. RUN LAST: it leaves the Apply Volume caption changed until the board
        is reloaded, which blocks Set-SwdGeometry (T12-T14).  #>
    param([string]$RunDir, [string]$StopFile)
    $res = Resolve-SwdGeometryControl
    if (-not $res.Volume -or -not $res.Volume.Edit) { throw "Volume target box not resolved: $($res.Missing -join '; ')" }
    $h = [int64]$res.Volume.Edit
    $orig = Get-SwdText -Handle $h
    $n = ConvertTo-SwdNumber -Text $orig
    if (-not $n.Ok) { throw "Volume target box reads '$orig', not a number." }
    $s0 = Get-SwdProbeSnapshot -Dir $RunDir -Label 't9-0-before'
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
        # Only a board reload does. Set-SwdGeometry then refuses every axis (it resolves all
        # three Apply buttons), so run T9 LAST and reload the board afterwards.
        LeavesResidue = ($d2.OutOfScopeCount -gt 0)
        ApplyVolumeCaption = @(Get-SwdControl | Where-Object { $_.Class -like '*BUTTON*' -and $_.Parent -eq $res.Volume.Group } | ForEach-Object { $_.Text })
    }
}

function Invoke-SwdProbeT11 {
    <#  Tab switch through MSAA default action, then back. Checks the page really showed.  #>
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
        Exact = ($d.OutOfScopeCount -eq 0); Residual = $d.OutOfScopeCount; Lines = (Format-SwdProbeDiff $d 40)
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
    $rows | Export-Csv (Join-Path $RunDir 't13-settle.csv') -NoTypeInformation -Encoding UTF8
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
                                       ImageBoxes = @($d.OutOfScope.ImageBoxes).Count; Lines = (Format-SwdProbeDiff $d) }
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
    return [pscustomobject]@{ Negative = $neg; Positive = $pos; VolatileKeys = $ignore.Count
                              NegativeClean = (@($neg | Where-Object { $_.Win32 + $_.Msaa + $_.ImageBoxes -gt 0 }).Count -eq 0)
                              PositiveDetected = (@($pos | Where-Object { $_.OutOfScope -gt 0 }).Count -eq $pos.Count) }
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
# Runner
# ---------------------------------------------------------------------------------------

function Invoke-SwdProbe {
    param([Parameter(Mandatory)][string]$Name, [double]$DeltaMm = 1.0, [int]$Repeats = 5, [string]$LogDir, [switch]$SkipLibraryHash)
    $root = Get-SwdProbeLogDir -Override $LogDir
    $run = Join-Path $root ('{0}-{1}' -f (Get-Date -Format 'HHmmss'), $Name)
    [void][IO.Directory]::CreateDirectory($run)
    $stop = Join-Path $root $script:ProbeStopFileName
    if (Test-Path -LiteralPath $stop) { throw "A STOP file is present at $stop. Delete it by hand to run probes." }
    $transcript = Join-Path $run 'transcript.txt'
    Start-Transcript -LiteralPath $transcript | Out-Null
    $summary = [ordered]@{ Probe = $Name; Started = (Get-Date).ToString('o'); RunDir = $run; ReviewStatus = 'pre-SQA (owner override 2026-09-30)' }
    try {
        if ($Name -ne 'T17') {
            $self = [SwdWin]::IntegritySid($PID)
            $main = Get-SwdProbeMain
            $swdInt = [SwdWin]::IntegritySid($main.Process.Id)
            if ($self -ne $swdInt) { throw "Integrity mismatch: probe $(Format-Integrity $self), SWD $(Format-Integrity $swdInt). Run elevated." }
            $summary.Board = Assert-SwdProbeBoard -Title $main.Title
            $summary.Integrity = Format-Integrity $swdInt
        }
        $lib = $null; $libBefore = $null
        if ($Name -ne 'T17' -and -not $SkipLibraryHash) {
            $lib = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'ShaperWaveDynamics documents\biblio'
            $libBefore = Get-SwdLibraryHash -Root $lib
        }
        $result = switch ($Name) {
            'Snapshot' { Invoke-SwdProbeSnapshotOnly -RunDir $run }
            'T9'  { Invoke-SwdProbeT9  -RunDir $run -StopFile $stop }
            'T11' { Invoke-SwdProbeT11 -RunDir $run -StopFile $stop }
            'T12' { Invoke-SwdProbeT12 -RunDir $run -StopFile $stop -DeltaMm $DeltaMm }
            'T13' { Invoke-SwdProbeT13 -RunDir $run -StopFile $stop -DeltaMm $DeltaMm -Repeats $Repeats }
            'T14' { Invoke-SwdProbeT14 -RunDir $run -StopFile $stop -DeltaMm $DeltaMm }
            'T17' { Invoke-SwdProbeT17 -RunDir $run }
        }
        $summary.Result = $result
        if ($libBefore) {
            $cmp = Compare-SwdLibraryHash -Before $libBefore -After (Get-SwdLibraryHash -Root $lib)
            $summary.Library = $cmp
            if (-not $cmp.Ok) { Write-Warning "LIBRARY CHANGED: added $($cmp.Added.Count), removed $($cmp.Removed.Count), changed $($cmp.Changed.Count)" }
        }
        $summary.Outcome = 'completed'
    } catch {
        $summary.Outcome = 'error'
        $summary.Error = $_.Exception.Message
        throw
    } finally {
        $summary.Finished = (Get-Date).ToString('o')
        Write-SwdProbeJson -Path (Join-Path $run 'summary.json') -Object ([pscustomobject]$summary) -Depth 8
        Stop-Transcript | Out-Null
    }
    return [pscustomobject]$summary
}

if ($Probe) {
    $ErrorActionPreference = 'Stop'
    $r = Invoke-SwdProbe -Name $Probe -DeltaMm $DeltaMm -Repeats $Repeats -LogDir $LogDir -SkipLibraryHash:$SkipLibraryHash
    $r.Result | ConvertTo-Json -Depth 6
    if ($r.PSObject.Properties['Library']) { 'Library: ' + ($r.Library | ConvertTo-Json -Compress) }
    "summary: $(Join-Path $r.RunDir 'summary.json')"
}
