# Message layer for driving SWD. Added 2026-08-27 for the headless Phase 2 route.
# Revised the same day against SQA verdict Critical=6 | Warning=11 | Suggestion=14,
# then again by the code-reviewer intake round, which VERIFIED each of those fixes
# against a throwaway WinForms target instead of trusting them. One of them was
# wrong - see Resolve-SwdWritableTarget - and one suspected defect was refuted by
# a corrected fixture, recorded there too rather than quietly dropped.
#
# swd_ui.ps1 (beside this file) drives SWD by moving a cursor. This one drives it
# by sending messages straight to a control's window handle: no cursor, no
# coordinates, no focus. SWD can sit minimised while the machine is used for
# something else, and both coordinate traps swd_ui.ps1 exists to work around -
# 173% DPI scaling and a virtual desktop with a negative origin - are irrelevant
# on this path. swd_ui.ps1 is kept as the fallback, not deleted.
#
# THE GOVERNING RULE, learned the expensive way and then re-learned from SQA:
# NEVER REPORT A SUCCESS YOU DID NOT OBSERVE. Phase 2 stalled the first time on
# automation that returned success while every input was discarded. The SQA pass
# found five separate instruments in the first draft of this file doing the same
# thing in miniature. Hence:
#   - Invoke-SwdButton returns `Sent`, never `Ok`. BM_CLICK is documented to
#     always return zero, so a successful send says NOTHING about whether the
#     control did anything. Only observing the application can say that.
#   - Set-SwdNumeric validates BEFORE it writes, and reads back after.
#   - Activation reports what was MEASURED, not what was requested.
#   - A timed-out read is $null and is never silently equal to an empty answer,
#     and Get-SwdControl publishes an aggregate timeout count, so a hung SWD
#     cannot masquerade as an application with no matching controls.
#
# Reads go through SendMessageTimeout with SMTO_ABORTIFHUNG. A plain SendMessage
# to a window that is mid-scan blocks the caller for the entire scan.
#
# Read-and-message only. Nothing here writes to disk except Save-SwdWindowImage.
#
# NOTE: this file sets StrictMode for the scope that dot-sources it. Deliberate
# for the diagnostic and the scan driver; a host that does not want it should
# dot-source into a child scope.

Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Drawing

# Captured at load time. Inside a function, $PSScriptRoot resolves at CALL time
# and points at the CALLING script, not at this one - so a default of
# (Join-Path $PSScriptRoot 'logs') would write beside whoever dot-sourced this.
$script:SwdMsgRoot = $PSScriptRoot
if (-not $script:SwdMsgRoot) { $script:SwdMsgRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }

# Published by Get-SwdControl after every enumeration. Initialised here so
# StrictMode cannot trip on a read taken before the first call.
$script:SwdControlStats = [pscustomobject]@{
    Scope = 'none - no enumeration has run'
    Total = 0; WithText = 0; TimedOut = 0; Skipped = 0
    DeadlineHit = $false; NoText = $false; ElapsedMs = 0
}

if (-not ('SwdWin' -as [type])) {
Add-Type @'
using System;using System.Text;using System.Runtime.InteropServices;
// Named SwdWin, not W. A single-letter type in the global namespace behind an
// "if not already defined" guard binds silently to a foreign W if anything else
// in the session defined one first - and swd_ui.ps1, in this same directory,
// already declares a global "U" the same way, so the collision pattern is not
// hypothetical. (SQA suggestion S26, accepted.)
public class SwdWin {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  // No SetLastError: MSDN documents no error for SetForegroundWindow, so
  // GetLastWin32Error after it returns whatever an unrelated call last set.
  // IsForeground below is the honest signal and the only one reported.
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out PT p);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool BlockInput(bool block);
  [DllImport("user32.dll",SetLastError=true)]
    public static extern IntPtr SendMessageTimeout(IntPtr h,uint m,IntPtr w,IntPtr l,uint f,uint ms,out IntPtr res);
  [DllImport("user32.dll",SetLastError=true,CharSet=CharSet.Unicode,EntryPoint="SendMessageTimeoutW")]
    public static extern IntPtr SendMessageTimeoutSb(IntPtr h,uint m,IntPtr w,StringBuilder l,uint f,uint ms,out IntPtr res);
  [DllImport("user32.dll",SetLastError=true,CharSet=CharSet.Unicode,EntryPoint="SendMessageTimeoutW")]
    public static extern IntPtr SendMessageTimeoutStr(IntPtr h,uint m,IntPtr w,string l,uint f,uint ms,out IntPtr res);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
  [DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Unicode)]
    public static extern IntPtr CreateFileW(string path, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
  [DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Unicode)]
    public static extern uint GetFinalPathNameByHandleW(IntPtr h, StringBuilder buf, uint cch, uint flags);
  [DllImport("kernel32.dll",SetLastError=true)] public static extern IntPtr OpenProcess(uint a,bool inh,int pid);
  [DllImport("kernel32.dll",SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
  [DllImport("advapi32.dll",SetLastError=true)] public static extern bool OpenProcessToken(IntPtr p,uint a,out IntPtr t);
  [DllImport("advapi32.dll",SetLastError=true)] public static extern bool GetTokenInformation(IntPtr t,int cls,IntPtr buf,int len,out int ret);
  [DllImport("advapi32.dll",SetLastError=true,CharSet=CharSet.Unicode)] public static extern bool ConvertSidToStringSidW(IntPtr sid, out IntPtr str);
  [DllImport("kernel32.dll")] public static extern IntPtr LocalFree(IntPtr p);

  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left,Top,Right,Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct PT { public int X,Y; }

  public const uint WM_GETTEXT=0x000D, WM_GETTEXTLENGTH=0x000E, WM_SETTEXT=0x000C;
  public const uint WM_KILLFOCUS=0x0008, WM_KEYDOWN=0x0100, WM_KEYUP=0x0101;
  public const uint BM_CLICK=0x00F5, BM_GETCHECK=0x00F0, BM_GETSTATE=0x00F2;
  public const uint SMTO_ABORTIFHUNG=0x0002;

  // Win32 error captured at the exact point a call below failed. SetLastError is
  // declared on every entry point that has one and was previously never read -
  // ERROR_ACCESS_DENIED (5) is the UIPI signature and the single most useful
  // datum a filtered call can report. (SQA suggestion S23.)
  // ponytail: plain static field, single-threaded PowerShell host. Make it
  // [ThreadStatic] if this layer ever runs on more than one thread.
  public static int LastError = 0;

  // US (0x1F) separates fields. A class name cannot contain it, whereas '|' is
  // merely unlikely - and "merely unlikely" is how silent parse corruption gets
  // in. The caller asserts the field count rather than trusting the split.
  public const string SEP = "\u001F";
  public const int FIELDS = 7;

  public static string[] Children(IntPtr parent){
    // A NULL parent makes EnumChildWindows enumerate the ENTIRE DESKTOP.
    // Measured by SQA: 479 windows belonging to other processes, which then flow
    // into the control map and become legitimate-looking BM_CLICK targets.
    if(parent==IntPtr.Zero) throw new ArgumentException("Children() refuses a NULL parent: EnumChildWindows would walk the whole desktop.");
    var list=new System.Collections.Generic.List<string>();
    EnumChildWindows(parent, delegate(IntPtr h, IntPtr l){
      var sb=new StringBuilder(512);
      int n=GetClassName(h,sb,512);
      // n==0 is FAILURE, and an empty string is a perfectly plausible class name
      // to a reader, so the two are separated here rather than downstream.
      string cls = (n==0) ? "UNKNOWN" : ((n>=511) ? sb.ToString()+"<TRUNCATED>" : sb.ToString());
      RECT r; bool gotRect=GetWindowRect(h,out r);
      string rect = gotRect ? (r.Left+","+r.Top+","+r.Right+","+r.Bottom) : "UNKNOWN";
      list.Add(string.Join(SEP, new string[]{
        h.ToInt64().ToString(), cls, GetDlgCtrlID(h).ToString(),
        IsWindowVisible(h).ToString(), IsWindowEnabled(h).ToString(),
        rect, GetParent(h).ToInt64().ToString() }));
      return true;
    }, IntPtr.Zero);
    return list.ToArray();
  }

  // Reported in LastError when a caption is refused for length rather than for
  // a Win32 failure. Negative on purpose: every real Win32 error is >= 0, so a
  // caller can always tell the two apart. Without this, an over-long caption
  // returned the same (null, LastError 0) as a window that never answered -
  // the C6 conflation in miniature, found by mutation testing.
  public const int ERR_TEXT_TOO_LONG = -1;
  public const int MAX_TEXT = 32768;

  // null means the window did not answer in time. That is DISTINCT from "" which
  // means it answered with empty text, and every consumer must test for it.
  public static string GetText(IntPtr h, uint timeoutMs){
    LastError = 0;
    IntPtr res;
    if(SendMessageTimeout(h,WM_GETTEXTLENGTH,IntPtr.Zero,IntPtr.Zero,SMTO_ABORTIFHUNG,timeoutMs,out res)==IntPtr.Zero){
      LastError = Marshal.GetLastWin32Error(); return null; }
    int len=res.ToInt32();
    if(len<0||len>MAX_TEXT){ LastError = ERR_TEXT_TOO_LONG; return null; }
    var sb=new StringBuilder(len+1);
    if(SendMessageTimeoutSb(h,WM_GETTEXT,new IntPtr(len+1),sb,SMTO_ABORTIFHUNG,timeoutMs,out res)==IntPtr.Zero){
      LastError = Marshal.GetLastWin32Error(); return null; }
    return sb.ToString();
  }

  public static bool SetText(IntPtr h, string v, uint timeoutMs){
    LastError = 0;
    IntPtr res;
    bool ok = SendMessageTimeoutStr(h,WM_SETTEXT,IntPtr.Zero,v,SMTO_ABORTIFHUNG,timeoutMs,out res)!=IntPtr.Zero;
    if(!ok) LastError = Marshal.GetLastWin32Error();
    return ok;
  }

  public static int OwnerPid(IntPtr h){ int pid; GetWindowThreadProcessId(h, out pid); return pid; }

  // ---- top-level / modal dialog support -----------------------------------
  // A modal dialog is a SEPARATE TOP-LEVEL WINDOW owned by the process, not a
  // child of the main form. EnumChildWindows from the main HWND therefore
  // cannot see it - which is exactly why the toolchain was blind to SWD's
  // "HydroScan can takes more than 60 mn" confirmation on 2026-08-28, and why a
  // sent BM_CLICK came back lastError=1460 (ERROR_TIMEOUT): the modal had
  // blocked the message pump while the click itself had already landed.
  public const uint WM_CLOSE=0x0010;
  public const uint GW_OWNER=4;
  public const int  TOPLEVEL_FIELDS=4;
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);

  // The style word, for telling a PUSHBUTTON from a CheckBox or RadioButton.
  // GetWindowLongW rather than GetWindowLongPtrW on purpose: a window style is a
  // DWORD on every architecture, so the 32-bit entry point is correct on x64 and
  // the Ptr form does not exist on x86. 0 is returned on failure AND is not a
  // reachable style for a real child control (WS_CHILD is always set), so the
  // caller treats 0 as UNREADABLE rather than as BS_PUSHBUTTON.
  [DllImport("user32.dll",SetLastError=true,EntryPoint="GetWindowLongW")]
    public static extern int GetWindowLong(IntPtr h, int i);
  public const int GWL_STYLE = -16;
  public const int BS_TYPEMASK = 0x0F;

  // "handle|class|visible|owner" for every top-level window of one process.
  //
  // The pid filter is the ONLY thing standing between this and every top-level
  // window on the desktop, which is the same hazard Children() throws over. A
  // mutation study on 2026-08-28 removed this filter and the whole suite stayed
  // green, so it is now asserted directly by a test as well as guarded here.
  //
  // want<=0 is refused: GetWindowThreadProcessId leaves pid at 0 when it FAILS,
  // so a caller passing 0 would collect precisely the windows whose owner could
  // not be determined - the worst possible selection.
  public static string[] TopLevelForPid(int want){
    if(want<=0) throw new ArgumentException("TopLevelForPid refuses a non-positive pid: 0 is what GetWindowThreadProcessId leaves behind when it fails.");
    var list=new System.Collections.Generic.List<string>();
    EnumWindows(delegate(IntPtr h, IntPtr l){
      int pid; GetWindowThreadProcessId(h, out pid);
      if(pid==want){
        var sb=new StringBuilder(512); int n=GetClassName(h,sb,512);
        // n==0 is FAILURE and an empty class name is plausible to a reader, so
        // the two are separated here exactly as Children() separates them.
        string cls=(n==0)?"UNKNOWN":((n>=511)?sb.ToString()+"<TRUNCATED>":sb.ToString());
        list.Add(string.Join(SEP, new string[]{
          h.ToInt64().ToString(), cls,
          IsWindowVisible(h).ToString(),
          GetWindow(h,GW_OWNER).ToInt64().ToString() }));
      }
      return true;
    }, IntPtr.Zero);
    return list.ToArray();
  }

  // null means the token could not be opened, which from a Medium-integrity
  // caller IS the answer: the target sits higher.
  // S-1-16-8192 Medium, S-1-16-12288 High.
  public static string IntegritySid(int pid){
    IntPtr proc=OpenProcess(0x0400,false,pid); if(proc==IntPtr.Zero) return null;
    try{
      IntPtr tok;
      if(!OpenProcessToken(proc,0x0008,out tok)) return null;
      try{
        int need=0; GetTokenInformation(tok,25,IntPtr.Zero,0,out need);
        if(need<=0) return null;
        IntPtr buf=Marshal.AllocHGlobal(need);
        try{
          if(!GetTokenInformation(tok,25,buf,need,out need)) return null;
          IntPtr sid=Marshal.ReadIntPtr(buf); IntPtr str;
          if(!ConvertSidToStringSidW(sid,out str)) return null;
          try { return Marshal.PtrToStringUni(str); } finally { LocalFree(str); }
        } finally { Marshal.FreeHGlobal(buf); }
      } finally { CloseHandle(tok); }
    } finally { CloseHandle(proc); }
  }
}
'@
}

# ---------------------------------------------------------------------------
#  Pure helpers. Everything in this block is testable with SWD closed and is
#  covered by tests\swd_msg.Tests.ps1.
# ---------------------------------------------------------------------------

$script:SwdIntegrityNames = @{
    'S-1-16-4096'  = 'Low'
    'S-1-16-8192'  = 'Medium'
    'S-1-16-8448'  = 'Medium Plus'
    'S-1-16-12288' = 'High'
    'S-1-16-16384' = 'System'
}

function Format-Integrity {
    <#  Integrity SID -> readable name. $null means the token could not be opened,
        which is itself the answer from a lower-integrity caller and must never
        render as a blank or as a level.

        Lives here rather than in swd_diagnose.ps1 so it can be tested without
        executing the diagnostic.  #>
    param([AllowNull()]$Sid)
    if ($null -eq $Sid) { return 'UNREADABLE (token access denied)' }
    $key = [string]$Sid
    if ($script:SwdIntegrityNames.ContainsKey($key)) { return "$($script:SwdIntegrityNames[$key])  [$key]" }
    return $key
}

function ConvertTo-SwdSafeText {
    <#  Renders target-controlled text so it cannot forge the structure of
        whatever it is written into.

        SQA W17, measured: the live 12:15 log contains a control caption whose
        second physical line begins at column 0, typographically indistinguishable
        from a line the script emitted itself, and four cells of control-map.csv
        contain newlines. Control text comes from a third-party application, so it
        is escaped at the boundary rather than trusted to be one line.

        CR, LF and TAB become visible escapes; every other C0/C1 control plus the
        Unicode line and paragraph separators become \uXXXX. Printable text,
        including accented French captions, is returned unchanged.

        Over-length text is cut with a '<CUT>' marker, deliberately NOT the
        '<TRUNCATED>' marker [SwdWin]::Children uses. That one means GetClassName
        ran out of buffer and the real class name is longer; this one means the
        log line was shortened. Two different facts must not share one marker in
        the same file.

        The cut lands on an ESCAPE BOUNDARY, never inside one, and a literal
        backslash is doubled so the output is unambiguous. Otherwise a line cut
        mid-sequence ends in a dangling backslash or a half-written \u00, which
        is exactly the forged-structure problem this function exists to prevent.

        $null renders as <null>, NOT as an empty string: a timed-out WM_GETTEXT is
        $null and must stay distinguishable from a control with no caption (C6).
        The parameter is deliberately untyped - [string]$Text would coerce $null
        to '' before the function ever saw it.  #>
    param([AllowNull()]$Text, [int]$MaxLength = 300)
    if ($null -eq $Text) { return '<null>' }
    $s = [string]$Text
    $sb = New-Object System.Text.StringBuilder
    $chars = $s.ToCharArray()
    for ($k = 0; $k -lt $chars.Length; $k++) {
        $ch = $chars[$k]
        $c = [int]$ch
        # A surrogate PAIR is one unit. Escapes were already atomic; characters
        # were not, so a cut could land between the halves and emit a lone
        # surrogate - a technically ill-formed string in a log that exists to be
        # unambiguous. Measured: 3 lone surrogates over 240 adversarial cuts.
        if ([char]::IsHighSurrogate($ch) -and ($k + 1) -lt $chars.Length -and [char]::IsLowSurrogate($chars[$k + 1])) {
            $u = [string]$ch + [string]$chars[$k + 1]
            if ($MaxLength -gt 0 -and ($sb.Length + $u.Length) -gt $MaxLength) { return $sb.ToString() + '<CUT>' }
            [void]$sb.Append($u)
            $k++
            continue
        }
        # One UNIT per source character, appended whole or not at all, so a
        # truncation can never land inside an escape. Round 2 caught the previous
        # version asserting a dangling backslash in a test whose own title said
        # that must not happen.
        if     ($c -eq 0x0D) { $u = '\r' }
        elseif ($c -eq 0x0A) { $u = '\n' }
        elseif ($c -eq 0x09) { $u = '\t' }
        elseif ($c -eq 0x5C) { $u = '\\' }   # a literal backslash, DOUBLED, so every
                                             # backslash in the output opens an escape
                                             # and the encoding stays reversible
        elseif ($c -lt 0x20 -or ($c -ge 0x7F -and $c -le 0x9F) -or $c -eq 0x2028 -or $c -eq 0x2029) {
            $u = '\u{0:X4}' -f $c
        }
        else { $u = [string]$ch }

        if ($MaxLength -gt 0 -and ($sb.Length + $u.Length) -gt $MaxLength) {
            return $sb.ToString() + '<CUT>'
        }
        [void]$sb.Append($u)
    }
    return $sb.ToString()
}

function ConvertTo-SwdCsvCell {
    <#  Neutralises CSV formula injection (SQA S27). Excel and LibreOffice
        evaluate a cell beginning = + - @ or a leading control character;
        Export-Csv quotes such a cell, and quoting is not neutralisation.

        The mutation is one leading apostrophe, the spreadsheet convention for
        "this is literal text". It IS a mutation, so the caller counts and reports
        the cells it touched rather than changing data silently, and a downstream
        Python reader must strip a single leading apostrophe. Zero occurrences in
        the 181 live rows as of 2026-08-27.  #>
    param([AllowNull()]$Text)
    if ($null -eq $Text) { return $Text }
    $s = [string]$Text
    if ($s.Length -eq 0) { return $s }
    # The apostrophe itself is in the set. A reader is told to strip ONE leading
    # apostrophe, so a caption that genuinely begins with one would lose it on
    # the round trip unless it is doubled here. Escaping must be reversible or it
    # is data loss dressed as safety.
    $leading = [char[]]@('=', '+', '-', '@', "'", "`t", "`r", "`n")
    if ($leading -contains $s[0]) { return "'" + $s }
    return $s
}

function ConvertFrom-SwdControlRecord {
    <#  Parses one US-separated record emitted by [SwdWin]::Children.

        Split out of Get-SwdControl so it can be tested without a window: it is
        the point where a field-count mistake becomes silent data corruption,
        which is exactly what the '|' delimiter in the first draft risked.  #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    $f = $Line -split ([regex]::Escape([SwdWin]::SEP))
    if ($f.Count -ne [SwdWin]::FIELDS) {
        throw "Malformed control record ($($f.Count) fields, expected $([SwdWin]::FIELDS))."
    }
    [pscustomobject]@{
        Handle  = [int64]$f[0]
        Class   = $f[1]
        CtrlId  = [int]$f[2]
        Visible = [bool]::Parse($f[3])
        Enabled = [bool]::Parse($f[4])
        Rect    = $f[5]
        Parent  = [int64]$f[6]
    }
}

function ConvertTo-SwdNumber {
    <#  Parses with InvariantCulture first, then current culture, and REPORTS
        which one answered.

        The first draft compared [double]::TryParse (current culture) against
        [double]$Value (invariant) - two different cultures on the two sides of
        one equality. SQA measured it under fr-FR: TryParse('10.5') is False
        while [double]'10.5' is 10.5, and TryParse('10,5') is 10.5 while
        [double]'10,5' is *105*. SWD is French in origin and CLAUDE.md section 5
        already records its XML using comma decimal separators, so this is not
        hypothetical.

        A $null argument coerces to '' at the parameter, which TryParse rejects -
        the same Ok=$false answer, so the null case needs no separate branch.  #>
    param([AllowNull()][string]$Text)
    $n = 0.0
    $style = [Globalization.NumberStyles]::Float
    if ([double]::TryParse($Text, $style, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
        return [pscustomobject]@{ Ok = $true; Value = $n; Culture = 'Invariant' }
    }
    if ([double]::TryParse($Text, $style, [Globalization.CultureInfo]::CurrentCulture, [ref]$n)) {
        return [pscustomobject]@{ Ok = $true; Value = $n; Culture = [Globalization.CultureInfo]::CurrentCulture.Name }
    }
    return [pscustomobject]@{ Ok = $false; Value = $null; Culture = $null }
}

function Compare-SwdMap {
    <#  Diffs two control maps by handle. This is the detector section F needs,
        and BM_GETCHECK is not it: measured cross-process 2026-08-27, a WinForms
        FlatStyle=Standard CheckBox that was genuinely checked answered
        BM_GETCHECK=0 and BM_GETSTATE=0x8, and its window text never changed,
        while the identical control at FlatStyle=System answered 1. SWD is
        entirely WindowsForms10.*, so the single measurement the whole headless
        route rests on was being taken with a blind instrument.  (SQA C2.)

        A row that timed out on either side is reported UNCOMPARABLE rather than
        CHANGED: $null (no answer) versus '' (empty caption) is a real difference
        to PowerShell and no difference at all as evidence.  (SQA C6.)  #>
    param($Before, $After, [int64]$ProbeHandle = 0, [int64]$ProbeParent = 0)
    $b = @{}; foreach ($r in @($Before)) { $b[[int64]$r.Handle] = $r }
    $a = @{}; foreach ($r in @($After))  { $a[[int64]$r.Handle] = $r }
    $out = New-Object System.Collections.Generic.List[object]

    # Explicit parameters, not closure over the enclosing scope: PowerShell's
    # dynamic scoping would make this work either way, but it is not visible to
    # a reader or to PSScriptAnalyzer, which flagged the enclosing parameters as
    # unused.
    function Test-OnTarget {
        param([int64]$H, $Row, [int64]$PHandle, [int64]$PParent)
        if ($PHandle -eq 0) { return $false }
        if ($H -eq $PHandle) { return $true }
        if ($null -eq $Row) { return $false }
        if ($PParent -ne 0 -and [int64]$Row.Parent -eq $PParent) { return $true }
        return ([int64]$Row.Parent -eq $PHandle)
    }

    foreach ($h in $a.Keys) {
        if (-not $b.ContainsKey($h)) {
            $out.Add([pscustomobject]@{ Handle = $h; Kind = 'APPEARED'; Field = '-'
                                        From = '-'; To = (ConvertTo-SwdSafeText $a[$h].Text 60)
                                        OnTarget = (Test-OnTarget $h $a[$h] $ProbeHandle $ProbeParent) })
            continue
        }
        $br = $b[$h]; $ar = $a[$h]
        $onTarget = Test-OnTarget $h $ar $ProbeHandle $ProbeParent
        # Written out rather than looped over a dynamic member name: $f was a
        # literal every time, but $row.$f is dynamic member access and
        # InjectionHunter flags it, and a rule you have to re-explain on every
        # pass costs more than four lines.
        $pairs = @(
            @{ Name = 'Text';    B = $br.Text;    A = $ar.Text }
            @{ Name = 'Enabled'; B = $br.Enabled; A = $ar.Enabled }
            @{ Name = 'Visible'; B = $br.Visible; A = $ar.Visible }
            @{ Name = 'Rect';    B = $br.Rect;    A = $ar.Rect }
        )
        foreach ($p in $pairs) {
            if ($p.Name -eq 'Text' -and ($br.TimedOut -or $ar.TimedOut)) {
                $out.Add([pscustomobject]@{ Handle = $h; Kind = 'UNCOMPARABLE'; Field = $p.Name
                                            From = (ConvertTo-SwdSafeText $p.B 60); To = (ConvertTo-SwdSafeText $p.A 60)
                                            OnTarget = $onTarget })
                continue
            }
            if (($null -eq $p.B) -ne ($null -eq $p.A) -or ($null -ne $p.B -and $p.B -cne $p.A)) {
                $out.Add([pscustomobject]@{ Handle = $h; Kind = 'CHANGED'; Field = $p.Name
                                            From = (ConvertTo-SwdSafeText $p.B 60); To = (ConvertTo-SwdSafeText $p.A 60)
                                            OnTarget = $onTarget })
            }
        }
    }
    foreach ($h in $b.Keys) {
        if (-not $a.ContainsKey($h)) {
            $out.Add([pscustomobject]@{ Handle = $h; Kind = 'VANISHED'; Field = '-'
                                        From = (ConvertTo-SwdSafeText $b[$h].Text 60); To = '-'
                                        OnTarget = (Test-OnTarget $h $b[$h] $ProbeHandle $ProbeParent) })
        }
    }
    # Returned as a plain array and wrapped in @() at the call site. Both halves
    # are needed and the obvious 'improvement' is wrong, measured three ways:
    #   return $out          - PowerShell unrolls it, so a ONE-element diff
    #                          arrives as a bare object and $diff.Count throws
    #                          under StrictMode. Hit on the first harness run.
    #   return ,$out.ToArray() - the comma stops the unroll one level too late:
    #                          n=0 gives Count 1 and throws on the first filter,
    #                          and n=3 gives Count 1 - a SILENT UNDERCOUNT of the
    #                          number this section exists to report. Measured.
    #   return $out.ToArray() + @() at the call site - correct at n=0, 1 and 3.
    return $out.ToArray()
}

function ConvertTo-Kmh {
    <#  SWD's speed boxes are NumericUpDownScanSpeed{1,2,3}kmh - KILOMETRES PER
        HOUR - while every number in this project is m/s. Typing 10 into a km/h
        box asks for 2.78 m/s, not 10. Convert, never type.
            20 m/s = 72 km/h  (what all 132 existing scans ran at)
            10 m/s = 36 km/h  (the verification target)  #>
    param([Parameter(Mandatory)][double]$Ms)
    [math]::Round($Ms * 3.6, 4)
}

function Resolve-SwdWritableTarget {
    <#  Returns THE PATH THE WRITER MUST USE, or $null if writing there would
        break CLAUDE.md section 4. Test-SwdWritableTarget is the boolean wrapper.

        WHY IT RETURNS A PATH RATHER THAN A BOOLEAN. Round 2, W1, proven: the
        guard validated one spelling and the writers resolved another. Three
        resolvers were in play - [IO.Path]::GetFullPath in the guard, the
        PowerShell PROVIDER in New-Item -Path, and .NET in
        [IO.File]::AppendAllText - and they disagree. Measured, every one of
        these passed the old guard and still landed inside a protected folder:

          ~\...\ShaperWaveDynamics documents\biblio   GetFullPath left the '~'
                                                      literal; the provider
                                                      expanded it to the real
                                                      library.
          ~\..\..\Program Files\ShaperWaveDynamics    same, into the install.
          C:\...\ShaperWaveDynamics \x                Win32 STRIPS a trailing
                                                      space on create - verified
                                                      by asking for 'sub ' in a
                                                      temp folder and getting
                                                      'sub'.
          \\?\C:\... and \\.\C:\...                   prefixes that bypass path
                                                      normalisation entirely.
          \\localhost\c$\Program Files\...            the install by another name.

        This is the SECOND time this project has hit "validated with one
        resolver, acted on with another" - swd_extract.ps1 had the same shape.
        The fix is structural, not another pattern in a list: resolve ONCE, the
        way the writer will, and hand the caller that exact string.

        KNOWN LIMIT: NTFS junctions and symlinks are not resolved (no LinkTarget
        on .NET Framework 4.x), so a reparse point aimed into a protected folder
        would pass. The threat model is operator error, not an operator with
        mklink.  #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { Write-Warning 'Empty path refused.'; return $null }

    # UNC and the \\?\ / \\.\ prefixes are refused outright rather than parsed.
    # Everything this project writes - logs, control-map.csv, PNGs - is local and
    # beside the scripts, so there is no legitimate spelling to lose, and each of
    # these defeats the normalisation the rest of this function depends on.
    if ($Path.StartsWith('\\') -or $Path.StartsWith('//')) {
        Write-Warning "'$Path' is a UNC or device path. Refused: this project writes locally only."
        return $null
    }

    # Resolve the way New-Item -Path will: through the PROVIDER, so '~', PSDrives
    # and relative paths land where the writer would actually put them. The
    # Unresolved form does not require the path to exist yet.
    try {
        $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    } catch {
        Write-Warning "'$Path' is not a usable filesystem path: $($_.Exception.Message)"
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($full) -or $full.StartsWith('\\')) {
        Write-Warning "'$Path' did not resolve to a local filesystem path."
        return $null
    }
    try { $full = [IO.Path]::GetFullPath($full) } catch {
        Write-Warning "'$full' is not a usable filesystem path: $($_.Exception.Message)"
        return $null
    }

    $full = ConvertTo-SwdWin32Path $full

    # CANONICAL AND LEXICAL, both sides, because either test alone has been
    # measured wrong here.
    #
    # Round 3's Critical: the lexical test is defeated by an 8.3 short name.
    # Measured, 'C:\PROGRA~1\SHAPER~1\logs' was ALLOWED and came back as
    # 'C:\Program Files\SHAPER~1\logs' - a HALF-expanded string the writer then
    # used, creating a directory inside the SWD install. The library was reachable
    # the same way via ONEDRI~1\DOCUME~1\SHAPER~1. Round 1 had measured that
    # [IO.Path]::GetFullPath expands 8.3; round 2 moved the guard onto
    # GetUnresolvedProviderPathFromPSPath, which does not, and the property was
    # assumed of the replacement rather than re-measured.
    #
    # Canonicalisation can also FAIL - a root that does not exist, a permissions
    # refusal - and swd_extract.ps1 records that falling back to the lexical test
    # is safer than falling back to no test. So every combination is tested.
    $canonFull = Resolve-SwdCanonicalTarget -Path $full
    $lexRoots  = @(Get-SwdForbiddenPath)
    $allRoots  = @($lexRoots) + @(foreach ($r in $lexRoots) { Resolve-SwdCanonicalTarget -Path $r }) |
                    Where-Object { $_ }
    foreach ($candidate in @($full, $canonFull) | Where-Object { $_ }) {
        foreach ($f in $allRoots) {
            $ff = "$f".TrimEnd('\')
            if (-not $ff) { continue }
            if ($candidate -eq $ff -or
                $candidate.StartsWith($ff + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Warning "'$Path' resolves to '$candidate', which is at or under the protected SWD path '$ff'. CLAUDE.md section 4."
                return $null
            }
        }
    }
    # The CANONICAL string is what the writer gets, so no caller can re-resolve a
    # half-expanded spelling into somewhere else.
    if ($canonFull) { return $canonFull }
    return $full
}

function Get-SwdCanonicalDirectory {
    <#  The path Windows itself resolves this directory to: 8.3 names expanded,
        junctions, symlinks and subst drives followed.

        PORTED FROM swd_extract.ps1's Get-CanonicalDirectory - deliberately not
        reinvented. That file hit this exact problem, records that "a lexical
        prefix test is defeated by an 8.3 short name, a junction, a subst drive
        or a \?\ prefix", and settled on GetFinalPathNameByHandle as the only
        call that does all of it in one step. It needs the directory to EXIST.
        FILE_FLAG_BACKUP_SEMANTICS (0x02000000) is what lets CreateFile open a
        directory handle at all. $null when the path cannot be opened.  #>
    param([Parameter(Mandatory)][string]$Path)
    $h = [SwdWin]::CreateFileW($Path, 0, 7, [IntPtr]::Zero, 3, 0x02000000, [IntPtr]::Zero)
    if ($h -eq [IntPtr](-1)) { return $null }
    try {
        $sb = New-Object System.Text.StringBuilder 32768
        if ([SwdWin]::GetFinalPathNameByHandleW($h, $sb, 32767, 0) -eq 0) { return $null }
        $q = $sb.ToString()
        if ($q.StartsWith('\\?\UNC\')) { return '\\' + $q.Substring(8) }
        if ($q.StartsWith('\\?\'))     { return $q.Substring(4) }
        return $q
    } finally { [void][SwdWin]::CloseHandle($h) }
}

function Resolve-SwdCanonicalTarget {
    <#  Canonical form of a path that MAY NOT EXIST YET: canonicalise the nearest
        existing ancestor and re-append the missing tail.

        PORTED FROM swd_extract.ps1's Resolve-CanonicalTarget. The point of the
        ancestor walk is that it refuses a junction'd or 8.3 target WITHOUT
        creating it first - nothing is ever made inside a protected tree, not
        even briefly. $null if nothing on the path resolves.  #>
    param([Parameter(Mandatory)][string]$Path)
    $tail = New-Object 'System.Collections.Generic.List[string]'
    $cur = $Path.TrimEnd('\')
    while ($cur) {
        $c = Get-SwdCanonicalDirectory -Path $cur
        if ($c) {
            $c = $c.TrimEnd('\')
            if ($tail.Count -eq 0) { return $c }
            $t = @($tail.ToArray()); [array]::Reverse($t)
            return (Join-Path $c ($t -join '\')).TrimEnd('\')
        }
        $parent = Split-Path -Parent $cur
        if (-not $parent -or $parent -eq $cur) { return $null }
        [void]$tail.Add((Split-Path -Leaf $cur))
        $cur = $parent
    }
    return $null
}

function ConvertTo-SwdWin32Path {
    <#  Applies the trailing-space and trailing-dot stripping that Win32 performs
        on every path component at create time, so the string compared is the
        string the filesystem will use. Measured: New-Item for 'sub ' produces
        'sub'. Without this, 'ShaperWaveDynamics \x' compares as a different
        folder and writes into the real one.  #>
    param([Parameter(Mandatory)][string]$Path)
    $parts = $Path.TrimEnd('\', '/') -split '[\\/]+'
    for ($i = 1; $i -lt $parts.Length; $i++) { $parts[$i] = $parts[$i].TrimEnd(' ', '.') }
    ($parts -join [IO.Path]::DirectorySeparatorChar)
}

function Get-SwdForbiddenPath {
    <#  The directories CLAUDE.md section 4 protects, normalised the same way the
        candidate is. Both spellings are added for each Documents candidate
        because the two ways of finding Documents disagree here: $env:OneDrive is
        the OneDrive ROOT, GetFolderPath('MyDocuments') is already the Documents
        folder inside it - and on this machine Documents IS redirected, which is
        the hole round 1 found.  #>
    $out = @()
    foreach ($r in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432)) {
        if ($r) { $out += (Join-Path $r 'ShaperWaveDynamics') }
    }
    foreach ($d in @([Environment]::GetFolderPath('MyDocuments'), $env:USERPROFILE,
                     $env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer)) {
        if (-not $d) { continue }
        $out += (Join-Path $d 'ShaperWaveDynamics documents')
        $out += (Join-Path $d 'Documents\ShaperWaveDynamics documents')
    }
    $seen = @()
    foreach ($f in $out) {
        $n = $null
        try { $n = ConvertTo-SwdWin32Path ([IO.Path]::GetFullPath($f)) } catch { $n = $null }
        if ($n -and $seen -notcontains $n) { $seen += $n }
    }
    return $seen
}

function Test-SwdWritableTarget {
    <#  Boolean wrapper over Resolve-SwdWritableTarget, kept because the callers
        that only need a yes/no read better for it. ANY CALLER THAT GOES ON TO
        WRITE must use Resolve-SwdWritableTarget and write to the string it
        returns - see the W1 note there for why a boolean is not enough.  #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    return [bool](Resolve-SwdWritableTarget -Path $Path)
}

# ---------------------------------------------------------------------------
#  Live-application layer. Everything below needs SWD running.
# ---------------------------------------------------------------------------

function Get-SwdProcess {
    <#  The main window handle is validated here rather than at each call site,
        because a zero handle is not merely useless - it makes EnumChildWindows
        walk the entire desktop.

        NOT CACHED, deliberately. SQA S29 is right that this scans the whole
        process table: measured min-of-5 on this machine, Get-Process <name> is
        17.17 ms against 0.60 ms to refresh a held Process object. It is called
        once per enumeration and once per click, so configuring a scan pays it a
        handful of times against a 12-21 minute scan. A cache would trade that for
        a stale-handle hazard in the one file whose governing rule is "never
        report a success you did not observe". Revisit only if a caller appears
        that validates handles in a loop.  #>
    $p = Get-Process SurfHydrodynamics -ErrorAction SilentlyContinue
    if (-not $p)        { throw 'SurfHydrodynamics is not running. Launch it by hand first.' }
    if ($p -is [array]) { throw "More than one SurfHydrodynamics process is running ($($p.Count)). Close all but one." }
    if ($p.MainWindowHandle -eq 0) {
        throw 'SurfHydrodynamics is running but has no main window yet (starting, hidden, or exiting). Refusing to enumerate.'
    }
    return $p
}

function Test-SwdHandle {
    <#  Does this handle still exist AND belong to SWD? Both halves matter: a
        stale handle can be recycled by another process, and the first draft of
        the diagnostic accepted any handle that appeared in its own map - a map
        that could itself contain foreign windows.  #>
    param([Parameter(Mandatory)][int64]$Handle)
    if ($Handle -eq 0) { return $false }
    $h = [intptr]$Handle
    if (-not [SwdWin]::IsWindow($h)) { return $false }
    try { $swd = Get-SwdProcess } catch { return $false }
    return ([SwdWin]::OwnerPid($h) -eq $swd.Id)
}

function Test-SwdOwnsForeground {
    <#  Does the given process own the foreground - through ANY of its windows,
        including a modal dialog? THREE-STATE: $true, $false, or $null meaning
        the question could not be answered.

        Lives here rather than in swd_diagnose.ps1 so it can be tested without
        executing the diagnostic - the same reason Format-Integrity was moved
        here. It had ZERO effective coverage while it lived there: mutants
        returning unconditional $true and unconditional $false BOTH passed the
        full 18-test diagnostic suite.

        WHY $null EXISTS, AND WHY THIS IS THE FIX. The previous version returned
        $false for every unanswerable case, and $false is not "unanswered" - it
        is the claim "SWD does NOT hold the foreground", which is the exact
        premise section F needs to print THE CLICK LANDED WITHOUT FOCUS. That is
        this project's load-bearing headless claim, and it was being asserted
        from an unmeasured state. Three ways to reach it:

          GetForegroundWindow returns 0   no foreground window at all: the
                                          workstation is locked, the secure
                                          desktop (UAC) is up, or focus is
                                          between windows.
          the handle is not a window      stale or already destroyed.
          OwnerPid returns 0              GetWindowThreadProcessId FAILED and
                                          left pid at 0; 0 is never a real
                                          process id here.

        None of those is evidence of anything, so none of them returns $false.
        Callers MUST test for $null explicitly: PowerShell treats it as falsy in
        -and/-or, so `if ($x)` silently reads unknown as "no".  #>
    param([Parameter(Mandatory)][int64]$Handle, [Parameter(Mandatory)][int]$ProcessId)
    if ($ProcessId -le 0) { return $null }
    if ($Handle -eq 0)    { return $null }
    $h = [intptr]$Handle
    if (-not [SwdWin]::IsWindow($h)) { return $null }
    $owner = [SwdWin]::OwnerPid($h)
    if ($owner -eq 0) { return $null }
    return ($owner -eq $ProcessId)
}

function Get-SwdControl {
    <#  Every descendant window of SWD's main form, with class, control id and
        current text. This map is what the whole message route rests on: the
        assembly names the controls (Button_hydro_scan and friends) but only a
        handle can be addressed, so the two must be matched up by text and class.

        TimedOut is emitted per row and MUST be checked, and the aggregate is
        published by Get-SwdControlSummary. A fully hung SWD otherwise returns a
        complete-looking map in milliseconds with every Text $null - which,
        untested, reads exactly like an application with no matching controls.

        -DeadlineMs caps the WHOLE enumeration. The worst case without one is
        controls x 2 messages x TimeoutMs: 181 x 2 x 2000 ms = 724 s, the same
        order as the scan this exists to observe, and SMTO_ABORTIFHUNG does not
        help a window that is slow but still pumping. Rows past the deadline come
        back Text=$null, TimedOut=$true, Skipped=$true - never silently missing.
        0 disables the cap. Measured cost when SWD answers normally: 0.135 ms per
        control, so the deadline is dead weight in the healthy case by design.

        -NoText skips the two round trips per control when only structure is
        wanted. It CHANGES WHAT IS RETURNED, so every row is marked Skipped, the
        stats record NoText, and a warning is emitted. Never a silent default: a
        faster enumeration that quietly returns less text is the same defect class
        as the success this file exists not to report.  #>
    param([int]$TimeoutMs = 2000, [int]$DeadlineMs = 60000, [switch]$NoText)

    $p = Get-SwdProcess
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $total = 0; $withText = 0; $timedOut = 0; $skipped = 0; $deadlineHit = $false

    foreach ($line in [SwdWin]::Children($p.MainWindowHandle)) {
        $row = ConvertFrom-SwdControlRecord -Line $line
        $total++

        $text = $null; $rowTimedOut = $false; $rowSkipped = $false; $lastErr = 0
        if ($NoText) {
            $rowSkipped = $true
        } elseif ($DeadlineMs -gt 0 -and $sw.ElapsedMilliseconds -ge $DeadlineMs) {
            $deadlineHit = $true; $rowSkipped = $true; $rowTimedOut = $true
        } else {
            $text = [SwdWin]::GetText([intptr]$row.Handle, $TimeoutMs)
            if ($null -eq $text) { $rowTimedOut = $true; $lastErr = [SwdWin]::LastError } else { $withText++ }
        }
        if ($rowSkipped)  { $skipped++ }
        if ($rowTimedOut) { $timedOut++ }

        [pscustomobject]@{
            Handle    = $row.Handle
            Class     = $row.Class
            CtrlId    = $row.CtrlId
            Visible   = $row.Visible
            Enabled   = $row.Enabled
            Rect      = $row.Rect
            Parent    = $row.Parent
            Text      = $text
            TimedOut  = $rowTimedOut
            Skipped   = $rowSkipped
            LastError = $lastErr
        }
    }

    $sw.Stop()
    # Scope names WHAT was counted. Get-SwdDialogControl publishes into this same
    # one aggregate, and a summary that cannot say which enumeration it describes
    # is the same defect as an enumeration that never published one.
    $script:SwdControlStats = [pscustomobject]@{
        Scope = "MainWindow $($p.MainWindowHandle)"
        Total = $total; WithText = $withText; TimedOut = $timedOut; Skipped = $skipped
        DeadlineHit = $deadlineHit; NoText = [bool]$NoText; ElapsedMs = [int]$sw.ElapsedMilliseconds
    }
    if ($NoText) {
        Write-Warning "Get-SwdControl -NoText: text was NOT read for any of $total controls."
    }
    if ($deadlineHit) {
        Write-Warning "Get-SwdControl hit its $DeadlineMs ms deadline: $skipped of $total controls were not read."
    } elseif ($timedOut -gt 0) {
        Write-Warning "Get-SwdControl: $timedOut of $total controls did not answer WM_GETTEXT in $TimeoutMs ms."
    }
}

function Get-SwdControlSummary {
    <#  Aggregate outcome of the last Get-SwdControl call. Separate from the row
        stream because a pipeline of rows cannot carry a summary, and a summary
        nobody can reach is how "controls whose text mentions scan: 0" came to be
        indistinguishable from a hung application.  #>
    $script:SwdControlStats
}

function Get-SwdText {
    <#  Returns $null on timeout, '' on a genuinely empty answer. Callers MUST
        distinguish the two - see Get-SwdControl's note.  #>
    param([Parameter(Mandatory)][int64]$Handle, [int]$TimeoutMs = 2000)
    [SwdWin]::GetText([intptr]$Handle, $TimeoutMs)
}

function Set-SwdForeground {
    <#  Activation, honestly reported.

        SetActiveWindow only acts within the CALLING thread's own message queue,
        so against another process it does nothing and returns IntPtr.Zero - SQA
        measured exactly that, and measured the first draft reporting
        Activated=$true regardless. SetForegroundWindow does work cross-process,
        subject to the foreground lock, so it can still fail. Either way the
        result here is what GetForegroundWindow actually reports afterwards, never
        what was asked for. Verified against a throwaway WinForms target on
        2026-08-27: Called=$false, IsForeground=$false - the honest answer.

        SupportsShouldProcess because this genuinely changes system state and a
        scan driver rehearsing with -WhatIf must not steal the foreground.

        Polls rather than sleeping a fixed 250 ms (SQA S30): it returns as soon as
        the foreground actually changes, and a busy machine gets the whole budget
        instead of a false negative.  #>
    [CmdletBinding(SupportsShouldProcess)]
    param([int]$SettleMs = 1000)
    $p = Get-SwdProcess
    if (-not $PSCmdlet.ShouldProcess("SWD main window $($p.MainWindowHandle)", 'bring to foreground')) {
        return [pscustomobject]@{
            Called = $false; Foreground = [int64][SwdWin]::GetForegroundWindow()
            SwdMain = [int64]$p.MainWindowHandle; IsForeground = $null
            WhatIf = $true; WaitedMs = 0
        }
    }
    # No LastError here, deliberately. SetForegroundWindow documents no error
    # code, so reading GetLastWin32Error after it reports whatever an unrelated
    # call last set - the same stale-value defect already fixed for SetCursorPos
    # in the diagnostic. IsForeground is what was actually measured.
    $called = [SwdWin]::SetForegroundWindow($p.MainWindowHandle)

    # BY OWNING PROCESS, not handle identity. Comparing against MainWindowHandle
    # made activation onto SWD OWN MODAL read as failure - which is the defect
    # Test-SwdOwnsForeground was written to fix one level up, in the diagnostic,
    # and which was left standing here. Same question, so the same predicate,
    # and that means IsForeground is THREE-STATE: $null is "could not be
    # measured", never "did not happen".
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $fg = [SwdWin]::GetForegroundWindow()
    $owns = Test-SwdOwnsForeground -Handle $fg -ProcessId $p.Id
    while ($owns -ne $true -and $sw.ElapsedMilliseconds -lt $SettleMs) {
        Start-Sleep -Milliseconds 25
        $fg = [SwdWin]::GetForegroundWindow()
        $owns = Test-SwdOwnsForeground -Handle $fg -ProcessId $p.Id
    }
    $sw.Stop()

    [pscustomobject]@{
        Called       = $called
        Foreground   = [int64]$fg
        SwdMain      = [int64]$p.MainWindowHandle
        IsForeground = $owns          # $true / $false / $null = NOT MEASURED
        WhatIf       = $false
        WaitedMs     = [int]$sw.ElapsedMilliseconds
    }
}

function Invoke-SwdButton {
    <#  BM_CLICK straight to a button handle.

        THERE IS NO `Ok` FIELD, DELIBERATELY. BM_CLICK is documented to always
        return zero, so a successful send tells you the message was delivered and
        nothing about whether the control did anything. The first draft returned
        SendMessageTimeout's transport status as `Ok`; SQA measured that returning
        $true for a click on a plain Label and on a DISABLED checkbox. `Sent` is
        the honest name for what is actually known.

        Verification is the caller's job and must be done by OBSERVING THE
        APPLICATION - see swd_diagnose.ps1 section F, which diffs the whole
        control map across the click. BM_GETCHECK is NOT sufficient: measured
        cross-process 2026-08-27, a WinForms FlatStyle=Standard CheckBox that was
        genuinely checked answered BM_GETCHECK=0 and BM_GETSTATE=0x8, and its
        window text never changed.

        -Post      fire and forget. REQUIRED for anything long-running: a sent
                   BM_CLICK returns only once the handler returns, so sending it
                   to the scan button would block the caller for the whole scan.
        -Activate  bring SWD to the foreground first, and report whether that
                   actually happened. Costs the headless property when it works.
        -Force     permit a disabled or non-BUTTON target. Without it both are
                   refused: measured, an unfocused BM_CLICK toggled a DISABLED
                   WinForms CheckBox from unchecked to checked, bypassing the
                   application's own precondition guard.

                   NOTE THE ASYMMETRY WITH Invoke-SwdDialogButton, which is
                   deliberate: there, -Force covers only the button TYPE and can
                   never permit a disabled or invisible control. A disabled OK on
                   a modal means the application is not ready, and no override
                   should exist for that. Here, -Force is the documented escape
                   hatch for driving a control the application has greyed out.

        SupportsShouldProcess, like both sibling mutators. It was a SIMPLE
        function until round 2 and that was a Critical: a simple function does
        not inherit $WhatIfPreference, so a scan driver rehearsing a
        configuration with -WhatIf suppressed every numeric write and then
        PRESSED THE BUTTONS FOR REAL. Measured cross-process: the target's click
        counter advanced during the rehearsal.  #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][int64]$Handle,
        [switch]$Post,
        [switch]$Activate,
        [switch]$Force,
        [int]$TimeoutMs = 5000
    )
    if (-not (Test-SwdHandle -Handle $Handle)) {
        throw "Handle $Handle is not a live window belonging to SurfHydrodynamics. Refusing to click."
    }
    $h = [intptr]$Handle
    $enabled = [SwdWin]::IsWindowEnabled($h)
    $sb = New-Object System.Text.StringBuilder 512
    $n  = [SwdWin]::GetClassName($h, $sb, 512)
    # 0 means the call FAILED; without this it reads as a control with an empty
    # class name, and the -notmatch 'BUTTON' guard below would then refuse it for
    # the wrong reason. Same separation as [SwdWin]::Children.
    $className = if ($n -eq 0) { 'UNKNOWN' } elseif ($n -ge 511) { $sb.ToString() + '<TRUNCATED>' } else { $sb.ToString() }
    if (-not $Force) {
        if (-not $enabled) {
            throw "Handle $Handle is DISABLED (class '$className'). Use -Force only if you mean to bypass the application's own guard."
        }
        if ($className -notmatch 'BUTTON') {
            throw "Handle $Handle is class '$className', not a BUTTON. Use -Force to override."
        }
    }

    # BEFORE activation as well as before the click: -Activate changes the
    # foreground, which is system state a rehearsal must not touch either.
    if (-not $PSCmdlet.ShouldProcess("SWD control $Handle (class '$className')", 'send BM_CLICK')) {
        return [pscustomobject]@{
            Handle = $Handle; Class = $className; Enabled = $enabled
            Method = 'none'; Sent = $false; Observed = 'not-attempted'; LastError = 0
            ActivateAsked = [bool]$Activate; ActivateAchieved = $null
            Forced = [bool]$Force; WhatIf = $true
        }
    }

    $achieved = $null
    if ($Activate) { $achieved = (Set-SwdForeground).IsForeground }

    if ($Post) {
        $method = 'PostMessage'
        $sent   = [SwdWin]::PostMessage($h, [SwdWin]::BM_CLICK, [intptr]0, [intptr]0)
    } else {
        $method = 'SendMessageTimeout'
        $res    = [intptr]0
        $sent   = ([SwdWin]::SendMessageTimeout($h, [SwdWin]::BM_CLICK, [intptr]0, [intptr]0,
                                                [SwdWin]::SMTO_ABORTIFHUNG, $TimeoutMs, [ref]$res) -ne [intptr]0)
    }
    # SetLastError is declared on both entry points; read it, because
    # ERROR_ACCESS_DENIED (5) here is the UIPI signature and is the single most
    # useful datum a filtered call can report.
    $err = 0
    if (-not $sent) { $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error() }

    [pscustomobject]@{
        Handle           = $Handle
        Class            = $className
        Enabled          = $enabled
        Method           = $method
        Sent             = $sent      # the transport CALL succeeded - see Observed
        Observed         = (Get-SwdTransportOutcome -Method $method -Ok $sent -LastError $err)
        LastError        = $err       # 5 = ERROR_ACCESS_DENIED, the UIPI signature
        ActivateAsked    = [bool]$Activate
        ActivateAchieved = $achieved  # $null when not asked for
        Forced           = [bool]$Force
        WhatIf           = $false
    }
}

function Set-SwdNumeric {
    <#  A NumericUpDown is an EDIT plus an msctls_updown32 buddy. Text written to
        the EDIT is NOT the control's .Value until the control validates, so this
        writes, forces validation, then READS BACK AND ASSERTS.

        VALIDATION HAPPENS BEFORE THE WRITE. The first draft cast [double]$Value
        *after* the WM_SETTEXT, so a non-numeric request mutated the live control
        and then threw - SQA measured a control already moved 12.50 -> 30 when the
        cast blew up, with no result object returned at all. Under
        $ErrorActionPreference='Stop' that aborts the run with SWD in a changed,
        unlogged state.

        Ok is true only if the readback parses and equals the request within
        tolerance. A control that clamps 40 to its maximum of 30 returns Ok=$false
        with After=30 and a Reason saying so - the honest answer, not a failure to
        retry. Verified end to end against a throwaway WinForms NumericUpDown on
        2026-08-27: 'abc' left the control at 12.50, -WhatIf left it at 12.50,
        '20.25' committed, '40' came back After=30.00 Ok=$false.

        -SettleMs is a POLL DEADLINE, not a fixed sleep (SQA S30). The common case
        returns in tens of milliseconds instead of always paying 250 ms, and a
        machine under load gets the whole budget instead of a false Ok=$false.  #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][int64]$Handle,
        [Parameter(Mandatory)][string]$Value,
        [int]$TimeoutMs = 2000,
        [double]$Tolerance = 1e-6,
        [int]$SettleMs = 1000
    )
    # Named Format-Result, not New-Result: PSUseShouldProcessForStateChangingFunctions
    # fires on the New- verb, and this nested helper only builds an object.
    function Format-Result {
        # BeforeTimedOut is separate from TimedOut, which has always meant the
        # READBACK. A timed-out pre-read left Before=$null with TimedOut=$false,
        # so "the control did not answer" and "the control answered empty" were
        # the same row on that side of the write - the exact $null-versus-''
        # conflation this file corrects everywhere else.
        param($Before, $After, $Ok, $Reason, $Culture, $TimedOut, $Rehearsed, $LastError,
              $BeforeTimedOut = $false)
        [pscustomobject]@{ Handle=$Handle; Requested=$Value; Before=$Before; After=$After
                           Ok=$Ok; Reason=$Reason; Culture=$Culture; TimedOut=$TimedOut
                           BeforeTimedOut=$BeforeTimedOut
                           WhatIf=$Rehearsed; LastError=$LastError }
    }

    $want = ConvertTo-SwdNumber -Text $Value
    if (-not $want.Ok) {
        return Format-Result $null $null $false 'requested value is not numeric - nothing sent' $null $false $false 0
    }
    if (-not (Test-SwdHandle -Handle $Handle)) {
        return Format-Result $null $null $false 'handle is not a live SWD window - nothing sent' $null $false $false 0
    }
    # ShouldProcess BEFORE any message reaches the control, so -WhatIf really is
    # inert. The first draft pre-read the control first, sending two messages.
    # WhatIf is its own field so a rehearsal is never confused with a failure.
    if (-not $PSCmdlet.ShouldProcess("SWD control $Handle", "set to '$Value'")) {
        return Format-Result $null $null $false 'WhatIf - nothing was sent' $null $false $true 0
    }

    $before = [SwdWin]::GetText([intptr]$Handle, $TimeoutMs)
    $beforeTimedOut = ($null -eq $before)
    $wrote  = [SwdWin]::SetText([intptr]$Handle, $Value, $TimeoutMs)
    $setErr = [SwdWin]::LastError

    # Commit without stealing foreground: Enter, then kill focus.
    #
    # SENT, not posted - round 2, W2. PostMessage only QUEUES, and a sent
    # WM_GETTEXT is serviced by the target's pump ahead of anything still in the
    # posted queue. So the readback could observe the echo of the WM_SETTEXT
    # above before the control had validated anything, and report Ok=$true for a
    # value the control went on to reject (40 against a Maximum of 30).
    # SendMessageTimeout returns only once the target has processed the message,
    # which is exactly the ordering guarantee the readback needs, and it is still
    # bounded so a mid-scan SWD cannot hang the caller. The return values are
    # kept rather than discarded: an undelivered commit is why a readback would
    # otherwise look like a rejection.
    $res = [intptr]0
    $commit = $true
    # lParam carries the keystroke message flags. A real Enter has repeat
    # count 1 (bits 0-15); WM_KEYUP additionally sets the transition and
    # previous-state bits (0xC0000000). WM_CHAR is deliberately NOT sent:
    # WM_KILLFOCUS is what commits a WinForms NumericUpDown, and adding a
    # message to a path that was just hardened for ordering, with no
    # demonstrated need, is a change without evidence.
    foreach ($m in @(@([SwdWin]::WM_KEYDOWN, 13, 0x00000001),
                     @([SwdWin]::WM_KEYUP,   13, 0xC0000001),
                     @([SwdWin]::WM_KILLFOCUS, 0, 0))) {
        $rc = [SwdWin]::SendMessageTimeout([intptr]$Handle, [uint32]$m[0], [intptr]$m[1], [intptr]$m[2],
                                           [SwdWin]::SMTO_ABORTIFHUNG, $TimeoutMs, [ref]$res)
        if ($rc -eq [intptr]0) { $commit = $false }
    }

    # The commit messages are now known to have been PROCESSED, so a readback
    # observes the control rather than the write. Polling continues only to let a
    # control that repaints asynchronously settle; it must NOT exit merely
    # because the text differs from `before`, which was the echo test that made
    # this dishonest. Exit on two identical consecutive reads, or on the deadline.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $after = [SwdWin]::GetText([intptr]$Handle, $TimeoutMs)
    while ($sw.ElapsedMilliseconds -lt $SettleMs) {
        Start-Sleep -Milliseconds 25
        $again = [SwdWin]::GetText([intptr]$Handle, $TimeoutMs)
        if ($null -ne $after -and $again -eq $after) { break }
        $after = $again
    }
    $sw.Stop()

    if ($null -eq $after) {
        return Format-Result $before $null $false 'readback TIMED OUT - control state is UNKNOWN' $null $true $false ([SwdWin]::LastError) $beforeTimedOut
    }
    $got = ConvertTo-SwdNumber -Text $after
    $ok  = $wrote -and $commit -and $got.Ok -and ([math]::Abs($got.Value - $want.Value) -lt $Tolerance)
    if ($ok)                 { $reason = 'ok' }
    elseif (-not $wrote)     { $reason = 'WM_SETTEXT was not delivered' }
    elseif (-not $commit)    { $reason = 'the commit keys were not delivered - the control may never have validated' }
    elseif (-not $got.Ok)    { $reason = 'readback is not numeric' }
    else                     { $reason = 'control did not take the value (clamped or rejected)' }

    Format-Result $before $after $ok $reason $got.Culture $false $false $setErr $beforeTimedOut
}

function Save-SwdWindowImage {
    <#  PrintWindow against SWD's own HWND, deliberately NOT CopyFromScreen.

        CopyFromScreen grabs whatever is on the display. With SWD minimised - the
        entire point of the headless route - that is the user's own screen:
        useless as evidence and a privacy problem. PrintWindow renders the target
        window itself and captures nothing belonging to anyone else.

        RETURNS $null WHEN PrintWindow FAILS, and writes no file. The first draft
        returned the path anyway, breaking the "a path means success" contract
        every other exit in this file follows, on the one path that produces a
        useless image.

        24bppRgb, not the default 32bppArgb (SQA S31). Two measured reasons, both
        2026-08-27 against a throwaway WinForms window:
          - 25.0% less memory, exactly: 428,400 bytes against 571,200 for the same
            420x340 window, and the saved PNG shrank 10,262 -> 8,997 bytes.
          - An undrawn pixel of a 32bppArgb bitmap is A=0 and saves to PNG as
            fully TRANSPARENT (verified by reading the file back). The same pixel
            in 24bppRgb is opaque black. If PrintWindow only partly paints - which
            is exactly the open question for SWD's DX11-composited child window -
            32bpp hides the gap and 24bpp shows it. An invisible failure is the
            one thing this file may not produce.

        A region or scale option was considered and NOT added: the bitmap is
        transient and disposed on every path including exceptions (SQA verified
        that independently), leaving one short-lived 0.4 MB allocation per
        capture.

        SupportsShouldProcess, like every other mutator here. It was missed by
        the round-3 sibling-guard sweep because it is not a CLICK - but it
        creates a directory and writes a PNG, and being a simple function it
        could not even inherit $WhatIfPreference, so it wrote files in a run
        where all four other mutators correctly did nothing.

        A rehearsal returns $null and writes nothing. That is the SAME return as
        a PrintWindow failure, and deliberately so: both mean "no file exists",
        which is the only fact a caller acts on. PowerShell own "What if:" line
        is what distinguishes them for a human.  #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Name = 'swd',
        [string]$Dir = (Join-Path $script:SwdMsgRoot 'logs')
    )
    # The RESOLVED path is what gets written, not $Dir: validating one spelling
    # and writing another is round 2's W1, and New-Item -Path resolves '~' and
    # PSDrives that the raw string does not show.
    $Dir = Resolve-SwdWritableTarget -Path $Dir
    if (-not $Dir) { throw 'Refusing to write images there - see the warning above.' }
    $p = Get-SwdProcess
    $h = $p.MainWindowHandle

    $r = New-Object 'SwdWin+RECT'
    if (-not [SwdWin]::GetWindowRect($h, [ref]$r)) { Write-Warning 'GetWindowRect failed'; return $null }
    $w = $r.Right - $r.Left; $ht = $r.Bottom - $r.Top
    if ($w -le 0 -or $ht -le 0) { Write-Warning "Window rect is empty ($w x $ht)"; return $null }

    $out = Join-Path $Dir ('{0}-{1}.png' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Name)
    # BEFORE the directory create as well as before the write: mkdir is a
    # filesystem mutation and a rehearsal must not leave one behind either.
    if (-not $PSCmdlet.ShouldProcess($out, 'render the SWD window and write a PNG')) { return $null }

    # See the note in swd_diagnose.ps1: New-Item has no -LiteralPath in either host.
    if (-not (Test-Path -LiteralPath $Dir)) { [void][IO.Directory]::CreateDirectory($Dir) }

    $ok  = $false
    $bmp = New-Object System.Drawing.Bitmap($w, $ht, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $dc = $g.GetHdc()
            try   { $ok = [SwdWin]::PrintWindow($h, $dc, 0x00000002) }   # PW_RENDERFULLCONTENT
            finally { $g.ReleaseHdc($dc) }
        } finally { $g.Dispose() }
        if ($ok) { $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png) }
    } finally { $bmp.Dispose() }

    if (-not $ok) { Write-Warning "PrintWindow returned false for '$Name' - no image written."; return $null }
    return $out
}

# ============================================================================
# MODAL DIALOG LAYER - added 2026-08-28.
#
# WHY: on the first driven hydroscan, clicking "Hydrodynamics Scanner" raised a
# confirmation ("HydroScan can takes more than 60 mn...") and the scan did not
# start until a human pressed OK. Nothing in this toolchain could see that
# dialog, because Get-SwdControl walks EnumChildWindows from the MAIN window and
# a modal is a separate TOP-LEVEL window. An unattended driver was therefore
# impossible.
#
# THE SAFETY PROPERTY, and it is the whole point of this layer:
# Invoke-SwdDialogButton REFUSES to click unless the dialog's own text matches a
# pattern the caller states in advance. A driver that blind-clicks "OK" on
# whatever dialog happens to be up will eventually accept "Delete this
# hydroscan?" or "Overwrite?" - and on a licensed installation with 143 reports
# in it, that is not a recoverable mistake. The caller must say what it expects
# to see; a mismatch is refused and logged, never guessed at.
# ============================================================================

function Get-SwdDialog {
    <#  Top-level windows owned by the SWD process, excluding the main window.
        These are the dialogs Get-SwdControl structurally cannot reach.

        THE OWNING PROCESS IS RE-CHECKED HERE as well as inside
        [SwdWin]::TopLevelForPid, and the redundancy is deliberate. This is one
        of the three functions that decide WHICH WINDOW the driver acts on, and
        a mutation study on 2026-08-28 deleted the C# pid filter with the whole
        suite still green - at which point every top-level window on the desktop
        became a dialog candidate. That is the defect [SwdWin]::Children already
        throws to prevent, after SQA measured 479 foreign windows flowing into
        the control map. Both layers now carry their own test.  #>
    param([switch]$IncludeInvisible, [int]$TimeoutMs = 2000, [int]$DeadlineMs = 15000)
    $p = Get-SwdProcess
    $sw = [Diagnostics.Stopwatch]::StartNew()
    foreach ($line in [SwdWin]::TopLevelForPid($p.Id)) {
        $f = $line -split ([regex]::Escape([SwdWin]::SEP))
        if ($f.Count -ne [SwdWin]::TOPLEVEL_FIELDS) {
            throw "Malformed top-level record ($($f.Count) fields, expected $([SwdWin]::TOPLEVEL_FIELDS))."
        }
        $h = [int64]$f[0]
        if ($h -eq [int64]$p.MainWindowHandle) { continue }
        # Belt and braces, and cheap: one Win32 call per top-level window.
        if ([SwdWin]::OwnerPid([intptr]$h) -ne $p.Id) { continue }
        $vis = [bool]::Parse($f[2])
        if (-not $vis -and -not $IncludeInvisible) { continue }
        # Bounded like Get-SwdControl. Wait-SwdDialog calls this in a poll loop,
        # so an unbounded enumeration was N x TimeoutMs PER ITERATION against a
        # hung SWD. A window past the deadline comes back Title=$null with
        # TimedOut=$true - never silently missing.
        if ($DeadlineMs -gt 0 -and $sw.ElapsedMilliseconds -ge $DeadlineMs) {
            [pscustomobject]@{
                Handle = $h; Class = $f[1]; Visible = $vis
                Owner = [int64]$f[3]; Title = $null; TimedOut = $true
            }
            continue
        }
        $title = [SwdWin]::GetText([intptr]$h, $TimeoutMs)
        [pscustomobject]@{
            Handle   = $h
            Class    = $f[1]
            Visible  = $vis
            Owner    = [int64]$f[3]
            Title    = $title
            TimedOut = ($null -eq $title)
        }
    }
}

function Get-SwdDialogControl {
    <#  Children of one dialog. Same record shape as Get-SwdControl so a caller
        can treat them alike, but it does NOT go through the main window - the
        dialog handle is the enumeration root.

        MIRRORS Get-SwdControl, and that word is load-bearing because the first
        version said it mirrored and did not:

          - no Skipped field, so reading .Skipped threw under the
            Set-StrictMode -Version Latest this file installs - and
            swd_diagnose.ps1 already consumes .Skipped on sibling rows;
          - $script:SwdControlStats was never updated, so after enumerating five
            dialog children Get-SwdControlSummary still reported the PREVIOUS
            call Total=0: an aggregate describing an enumeration it never saw;
          - no Write-Warning when a control failed to answer.

        Because both enumerations write that one aggregate, it now carries a
        Scope field naming what was counted. A summary that cannot say what it
        summarised is the same defect one level up.

        -DeadlineMs caps the WHOLE enumeration, exactly as in Get-SwdControl.
        Without it the worst case was TimeoutMs + N x 2 x TimeoutMs, which at the
        5000 ms Invoke-SwdDialogButton passes is over three minutes for a
        20-control dialog - on the one path whose whole job is to answer a modal
        promptly. 0 disables the cap.  #>
    param(
        [Parameter(Mandatory)][int64]$Handle,
        [int]$TimeoutMs = 2000,
        [int]$DeadlineMs = 30000
    )
    if (-not [SwdWin]::IsWindow([intptr]$Handle)) { throw "Handle $Handle is not a live window." }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $total = 0; $withText = 0; $timedOut = 0; $skipped = 0; $deadlineHit = $false

    foreach ($line in [SwdWin]::Children([intptr]$Handle)) {
        # ConvertFrom-SwdControlRecord parses the STRUCTURAL record only - it
        # does not read control text, and returns no Text field at all. The
        # first draft of this function assumed it did, so Invoke-SwdDialogButton
        # matched against a property that was never populated: fail-safe, but for
        # entirely the wrong reason.
        $row = ConvertFrom-SwdControlRecord -Line $line
        $total++

        $text = $null; $rowTimedOut = $false; $rowSkipped = $false; $lastErr = 0
        if ($DeadlineMs -gt 0 -and $sw.ElapsedMilliseconds -ge $DeadlineMs) {
            $deadlineHit = $true; $rowSkipped = $true; $rowTimedOut = $true
        } else {
            $text = [SwdWin]::GetText([intptr]$row.Handle, $TimeoutMs)
            if ($null -eq $text) { $rowTimedOut = $true; $lastErr = [SwdWin]::LastError } else { $withText++ }
        }
        if ($rowSkipped)  { $skipped++ }
        if ($rowTimedOut) { $timedOut++ }

        [pscustomobject]@{
            Handle    = $row.Handle
            Class     = $row.Class
            CtrlId    = $row.CtrlId
            Visible   = $row.Visible
            Enabled   = $row.Enabled
            Rect      = $row.Rect
            Parent    = $row.Parent
            Text      = $text
            TimedOut  = $rowTimedOut
            Skipped   = $rowSkipped
            LastError = $lastErr
        }
    }

    $sw.Stop()
    $script:SwdControlStats = [pscustomobject]@{
        Scope = "Dialog $Handle"
        Total = $total; WithText = $withText; TimedOut = $timedOut; Skipped = $skipped
        DeadlineHit = $deadlineHit; NoText = $false; ElapsedMs = [int]$sw.ElapsedMilliseconds
    }
    if ($deadlineHit) {
        Write-Warning "Get-SwdDialogControl hit its $DeadlineMs ms deadline: $skipped of $total controls were not read."
    } elseif ($timedOut -gt 0) {
        Write-Warning "Get-SwdDialogControl: $timedOut of $total controls did not answer WM_GETTEXT in $TimeoutMs ms."
    }
}

function Wait-SwdDialog {
    <#  Poll for a dialog to appear. Returns the dialog, or $null on timeout -
        and $null means NOT SEEN, never "there was none". Same distinction
        Get-SwdText draws for a timed-out read.

        A modal blocks the owning message pump, so a read against the MAIN
        window may hang while the dialog is up. Only top-level windows are
        polled here.

        -TitleLike is a FILTER, and a mutation that ignored it left the whole
        suite green: the caller then silently gets whichever dialog EnumWindows
        happened to return first. It is now asserted against a target that
        carries two of them.

        WHEN SEVERAL DIALOGS MATCH -TitleLike, THE FIRST IS RETURNED - by
        enumeration order, which is not a decision procedure. That is
        deliberately UNLIKE Invoke-SwdDialogButton, which refuses an ambiguous
        -ButtonLike outright, and the asymmetry is safe for one reason only:
        finding a dialog changes nothing, and the -ExpectLike gate on the click
        is the backstop that has to agree before anything is pressed. If you
        ever act on a Wait-SwdDialog result WITHOUT going through that gate,
        this becomes a real ambiguity and needs the same refusal.

        The elapsed check used to sit only at the top of the loop, so the real
        bound was -TimeoutMs plus a whole poll interval plus an enumeration. The
        sleep is now clamped to what is left. One enumeration can still overrun
        the deadline - it is the unit of work and cannot be halved - so read
        -TimeoutMs as "no NEW attempt begins after this", which is what it can
        honestly mean.  #>
    param(
        [int]$TimeoutMs = 20000,
        [int]$PollMs    = 250,
        [string]$TitleLike
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $warnedUnreadable = $false
    while ($true) {
        foreach ($d in @(Get-SwdDialog)) {
            if (-not $TitleLike) { return $d }
            # A dialog whose title did not answer WM_GETTEXT cannot be matched
            # against -TitleLike, so it is skipped - and skipping it silently
            # would let "present but unreadable" leave through the $null exit
            # marked NOT SEEN. Warned once per call, not once per poll.
            if ($d.TimedOut) {
                if (-not $warnedUnreadable) {
                    Write-Warning "Wait-SwdDialog: top-level window $($d.Handle) is up but its title did not answer WM_GETTEXT, so it cannot be matched against -TitleLike. It is being SKIPPED, not ruled out."
                    $warnedUnreadable = $true
                }
                continue
            }
            if ($d.Title -like $TitleLike) { return $d }
        }
        $left = $TimeoutMs - $sw.ElapsedMilliseconds
        if ($left -le 0) { return $null }
        Start-Sleep -Milliseconds ([math]::Min([int]$PollMs, [int]$left))
    }
}

function Wait-SwdDialogGone {
    <#  Poll until a dialog handle stops being a live window belonging to SWD.
        $true if it went away inside the budget, $false if it is still up.

        THIS IS THE OBSERVATION THE REST OF THE LAYER REFUSES TO FAKE.
        Invoke-SwdDialogButton reports transport and nothing more, and
        Format-SwdSendError 1460 is ambiguous by measurement, so the only way to
        learn that an OK was actually taken is to watch the dialog go. A driver
        that clicks and then checks nothing has reported a success it did not
        observe.

        IsWindow, not a re-enumeration and not a WM_GETTEXT: the question is
        about ONE handle, and a destroyed handle answers immediately even while
        the process is busy - so a blocked pump cannot make a dismissed dialog
        look present. The owning process is re-checked because Windows recycles
        HWNDs, the same belt and braces Test-SwdHandle applies.  #>
    param(
        [Parameter(Mandatory)][int64]$Handle,
        [int]$TimeoutMs = 20000,
        [int]$PollMs    = 250
    )
    # If SWD has gone entirely then so has its dialog; not an error here.
    $p = $null
    try { $p = Get-SwdProcess } catch { $p = $null }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        if (-not [SwdWin]::IsWindow([intptr]$Handle)) { return $true }
        if ($p -and [SwdWin]::OwnerPid([intptr]$Handle) -ne $p.Id) { return $true }
        $left = $TimeoutMs - $sw.ElapsedMilliseconds
        if ($left -le 0) { return $false }
        Start-Sleep -Milliseconds ([math]::Min([int]$PollMs, [int]$left))
    }
}

function Invoke-SwdDialogButton {
    <#  Click a button inside a dialog - ONLY if the dialog says what the caller
        expected it to say, ONLY if the whole dialog was readable, and ONLY if
        exactly one button matches.

        -ExpectLike  wildcard matched against the dialog title AND the text of
                     its child controls. REQUIRED. A dialog that does not match
                     is REFUSED, never guessed at.
        -ButtonLike  wildcard for the button caption ('OK', 'Yes', 'Oui').
                     REQUIRED - it used to default to 'OK', which is precisely
                     the caption a blind driver would press on the wrong dialog.
                     Ampersands are stripped from both sides, so '&Yes' matches
                     'Yes'. A bare 'Yes' does NOT match 'Yes to All'.
        -Post        fire and forget, exactly as Invoke-SwdButton means it, and
                     REQUIRED for the same reason: a SENT BM_CLICK returns only
                     once the handler returns, so sending it to the OK that
                     starts a ~31 minute scan blocks the caller for the whole
                     scan and then reports the ambiguous 1460. Measured
                     2026-08-28 against a throwaway WinForms target, because a
                     transport that did not actuate the control would be a worse
                     trap than the one it fixes: a POSTED BM_CLICK DOES operate a
                     FlatStyle=Standard button, 'PST 0' -> 'PST 1'.
        -Force       permit a button whose style says it is a checkbox, radio
                     button or group box. See the BS_TYPE measurement below.

        WHAT THE RESULT MEANS, AND THE FIELD THAT USED TO LIE:

          Matched    the -ExpectLike gate passed AND the whole dialog was read.
          Attempted  a BM_CLICK was dispatched to ButtonHandle. This REPLACES the
                     old Clicked, which was set $true BEFORE the send and never
                     reconciled: against a stale handle it returned
                     Matched=True Clicked=True Sent=False LastError=1400 - a
                     click that never happened, reported as one that did, in the
                     one file whose governing rule is never to report a success
                     it did not observe. No field here may be named for an
                     outcome that was not measured, and "clicked" is such a name.
          Sent       TRANSPORT ONLY. BM_CLICK returns zero regardless, so even
                     Sent=$true is not proof the application did anything.
                     Confirm with Wait-SwdDialogGone.

        THE READ-COVERAGE GATE. The body used to be built by joining the title
        and every child Text INCLUDING the $null left behind by a timed-out
        WM_GETTEXT, which PowerShell renders as an empty string. So a dialog that
        was only half read could still satisfy -ExpectLike and be clicked -
        measured: one child with TimedOut=$true and Text=$null still produced
        Matched=True, Sent=True and a real click. Symmetrically, Matched=$false
        could not be told apart from "could not read it", which is exactly the
        retry-versus-abort decision an unattended driver has to make. Only text
        that was actually read now enters the body, an incompletely read dialog
        is REFUSED, and TitleRead / ChildCount / UnreadCount / FullyRead report
        the coverage so the caller can tell the two apart.

        THE BUTTON-TYPE GUARD IS ADVISORY, AND IS PROBABLY INERT AGAINST SWD.
        Say that first, because an earlier version of this comment justified the
        guard with "SWD scan confirmation is a real #32770" and NOTHING MEASURED
        THAT. It is not in any diagnostic log, any test, or any note; the modal
        that was actually observed belonged to a throwaway harness process. The
        claim is withdrawn - SWD dialog class is UNKNOWN until a control map is
        captured with one open.

        The problem it addresses is real: class '*BUTTON*' matches a CheckBox and
        a RadioButton as well as a pushbutton, and this project has already
        measured BM_CLICK toggling a WinForms checkbox with no observable trace
        whatsoever. The style word separates them only sometimes. Measured
        2026-08-28 on this build, all four FlatStyle values x three control
        kinds:

          FlatStyle=Standard   Button 11  CheckBox 11  RadioButton 11  IDENTICAL
          FlatStyle=Flat       Button 11  CheckBox 11  RadioButton 11  IDENTICAL
          FlatStyle=Popup      Button 11  CheckBox 11  RadioButton 11  IDENTICAL
          FlatStyle=System     Button  0  CheckBox  5  RadioButton  4  SEPARATED
          real MessageBox (#32770)  OK 1, Cancel 0                     SEPARATED

        So it discriminates in exactly two situations, and SWD is built entirely
        from WindowsForms10.* whose default FlatStyle is Standard. Treat the
        guard as covering native dialogs only, and assume it does nothing on
        SWD own forms until measured otherwise.

        TypeAmbiguous GATES NOTHING - it is a report, deliberately. It records
        that the check did not run, so a log or an operator can see the guard
        was inert rather than assume it passed. Do NOT read a click that
        succeeded with TypeAmbiguous=$true as type-checked. And do NOT "fix" the
        guard by refusing type 11: on the table above that refuses every WinForms
        button there is.

        AMBIGUITY IS REFUSED, NOT RESOLVED. Two buttons matching -ButtonLike used
        to be settled by Select-Object -First 1 - that is, by Z-order, silently.
        On a licensed installation holding 143 reports, guessing which button to
        press is not a recoverable mistake.

        WILDCARD GOTCHA: both patterns are -like, so a literal '[' opens a
        character class and the pattern quietly stops matching what it appears
        to. Both consequences here are REFUSALS, so it fails safe - but pass any
        caption or message text you did not type literally through
        [Management.Automation.WildcardPattern]::Escape() first.  #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][int64]$DialogHandle,
        [Parameter(Mandatory)][string]$ExpectLike,
        [Parameter(Mandatory)][string]$ButtonLike,
        [switch]$AnyText,
        [switch]$Post,
        [switch]$Force,
        [int]$TimeoutMs = 5000,
        [int]$DeadlineMs = 30000
    )
    # -ButtonLike was made mandatory because 'OK' is the caption a blind driver
    # would press on the wrong dialog. '*' is that same defect one level up, and
    # it matters more than when it was first flagged: the round-2 review proved
    # the button-type guard inert against WinForms and Visible unconsulted, so
    # -ExpectLike is the ONLY gate here that is load-bearing. Refused rather
    # than merely documented; -AnyText is the way to say you meant it.
    if (-not $AnyText -and $ExpectLike.Trim() -match '^\*+$') {
        throw "-ExpectLike '$ExpectLike' matches every dialog, which defeats the only gate this layer has. Name the text you expect to see, or pass -AnyText if you genuinely mean any dialog."
    }
    if (-not [SwdWin]::IsWindow([intptr]$DialogHandle)) { throw "Dialog $DialogHandle is not a live window." }
    $p = Get-SwdProcess
    if ([SwdWin]::OwnerPid([intptr]$DialogHandle) -ne $p.Id) {
        throw "Dialog $DialogHandle does not belong to SurfHydrodynamics. Refusing."
    }

    $title     = [SwdWin]::GetText([intptr]$DialogHandle, $TimeoutMs)
    $titleRead = ($null -ne $title)
    $children  = @(Get-SwdDialogControl -Handle $DialogHandle -TimeoutMs $TimeoutMs -DeadlineMs $DeadlineMs)
    $unread    = @($children | Where-Object { $_.TimedOut -or $_.Skipped }).Count

    # ONLY TEXT THAT WAS ACTUALLY READ. Joining $null in turned an unread control
    # into an empty string inside the very string the safety gate matches on.
    $parts = @()
    if ($titleRead) { $parts += [string]$title }
    foreach ($c in $children) {
        if (-not ($c.TimedOut -or $c.Skipped)) { $parts += [string]$c.Text }
    }
    $body      = $parts -join ' '
    $fullyRead = $titleRead -and ($unread -eq 0)
    # No ($null -ne $body) test: -join always returns a String, so that was dead
    # code that read like a guard. $fullyRead is the real precondition.
    $matched   = $fullyRead -and ($body -like $ExpectLike)

    $result = [ordered]@{
        DialogHandle  = $DialogHandle
        Title         = $title
        ExpectLike    = $ExpectLike
        TitleRead     = $titleRead
        ChildCount    = $children.Count
        UnreadCount   = $unread
        FullyRead     = $fullyRead
        Matched       = $matched
        ButtonLike    = $ButtonLike
        Candidates    = 0
        ButtonHandle  = $null
        ButtonType    = $null
        TypeAmbiguous = $false
        Method        = 'none'
        Attempted     = $false      # a BM_CLICK was dispatched - observed
        Sent          = $false      # the transport CALL succeeded - see Observed
        Observed      = 'not-attempted'   # what was actually observed, per transport
        LastError     = 0
        WhatIf        = $false
        Reason        = ''
    }

    if (-not $fullyRead) {
        $result.Reason = "dialog was NOT fully read (title read=$titleRead; $unread of $($children.Count) children did not answer WM_GETTEXT in $TimeoutMs ms); REFUSED without clicking. This is NOT a text mismatch - it is that the dialog could not be checked at all."
        return [pscustomobject]$result
    }
    if (-not $matched) {
        $result.Reason = 'dialog text does not match -ExpectLike; REFUSED without clicking'
        return [pscustomobject]$result
    }

    $wanted = $ButtonLike -replace '&', ''
    $named  = @($children | Where-Object {
        $_.Class -like '*BUTTON*' -and $_.Text -and (($_.Text -replace '&', '') -like $wanted)
    })
    # VISIBLE as well as ENABLED. Visible was captured on every row and never
    # consulted, and that is not hypothetical here: measured in SWD own
    # control-map.csv, 13 of 53 *BUTTON* rows are Visible=False with
    # Enabled=True, captioned 'Apply', 'Clean Shape' and 'UnLock' among others.
    # A caption match alone therefore selects controls the operator cannot see,
    # on a layout this application is already known to ship.
    $cands = @($named | Where-Object { $_.Enabled -and $_.Visible })
    $result.Candidates = $cands.Count

    if ($cands.Count -eq 0) {
        # Three different facts, and a driver deciding whether to wait, to abort
        # or to fix its pattern needs to tell them apart.
        $disabled  = @($named | Where-Object { -not $_.Enabled }).Count
        $invisible = @($named | Where-Object { $_.Enabled -and -not $_.Visible }).Count
        $result.Reason =
            if ($named.Count -eq 0) {
                "no BUTTON matching '$ButtonLike' in this dialog"
            } else {
                "$($named.Count) BUTTON(s) match '$ButtonLike' but none is both visible and enabled ($disabled disabled, $invisible enabled-but-INVISIBLE). Nothing sent."
            }
        return [pscustomobject]$result
    }
    if ($cands.Count -gt 1) {
        $caps = ($cands | ForEach-Object { "'" + (ConvertTo-SwdSafeText $_.Text 40) + "'" }) -join ', '
        $result.Reason = "AMBIGUOUS: $($cands.Count) enabled BUTTONs match '$ButtonLike' ($caps). REFUSED rather than resolved by Z-order - narrow -ButtonLike."
        return [pscustomobject]$result
    }

    $btn = $cands[0]
    $result.ButtonHandle = $btn.Handle

    $style = [SwdWin]::GetWindowLong([intptr]$btn.Handle, [SwdWin]::GWL_STYLE)
    # 0 is BOTH the failure return and an unreachable style for a real child
    # window (WS_CHILD is always set), so it is recorded as UNREADABLE ($null)
    # rather than as BS_PUSHBUTTON (0).
    #
    # An unreadable style is then PERMITTED, exactly as BS_OWNERDRAW is - the
    # earlier wording here implied it was refused, which it never was. It is
    # permitted because refusing on a transient GetWindowLong failure would
    # block a scan for no measured reason, and because -ExpectLike is the gate
    # that actually carries the safety. What it must not do is pass SILENTLY:
    # TypeAmbiguous records that the check did not run.
    $btype = $(if ($style -eq 0) { $null } else { $style -band [SwdWin]::BS_TYPEMASK })
    $result.ButtonType    = $btype
    $result.TypeAmbiguous = ($null -eq $btype) -or ($btype -eq 11)   # 11 = BS_OWNERDRAW
    # 2,3 checkbox; 4,9 radio; 5,6 three-state; 7 group box.
    $notPush = ($null -ne $btype) -and (@(2, 3, 4, 5, 6, 7, 9) -contains $btype)
    if ($notPush -and -not $Force) {
        $result.Reason = "button '$(ConvertTo-SwdSafeText $btn.Text 40)' has BS_TYPE=$btype - a checkbox, radio button or group box, NOT a pushbutton. BM_CLICK toggles those with no observable trace. Use -Force only if that is genuinely what you mean."
        return [pscustomobject]$result
    }

    # ShouldProcess, like all three sibling mutators. Its absence here was the
    # round-2 Critical reintroduced verbatim: without the attribute the function
    # does not inherit $WhatIfPreference either, so a scan driver rehearsing with
    # -WhatIf suppressed every numeric write and then answered the application
    # confirmation dialogs FOR REAL.
    #
    # The gate sits AFTER the reads, deliberately diverging from Set-SwdNumeric,
    # which gates before every message. There the pre-read was pointless during a
    # rehearsal; here it is the entire value of one - a dry run that reports
    # whether the dialog matched, whether it could be read at all, and which
    # button it resolved is exactly what a driver needs before it is trusted with
    # the real thing. WM_GETTEXT changes no state.
    $what = "SWD dialog $DialogHandle button $($btn.Handle) ('$(ConvertTo-SwdSafeText $btn.Text 40)')"
    if (-not $PSCmdlet.ShouldProcess($what, 'send BM_CLICK')) {
        $result.WhatIf = $true
        $result.Reason = 'WhatIf - the dialog matched and the button was resolved, but NOTHING was sent'
        return [pscustomobject]$result
    }

    # Re-validated immediately before the send, as Invoke-SwdButton does with
    # Test-SwdHandle. Between enumerating the children and clicking, a human can
    # dismiss the dialog; the old code sent into the hole, got lastError=1400,
    # and had already reported Clicked=$true.
    if (-not [SwdWin]::IsWindow([intptr]$btn.Handle)) {
        $result.Reason = 'the button stopped being a window between enumeration and the click (dialog dismissed?); nothing was sent'
        return [pscustomobject]$result
    }

    $result.Attempted = $true
    if ($Post) {
        $result.Method = 'PostMessage'
        $ok = [SwdWin]::PostMessage([intptr]$btn.Handle, [SwdWin]::BM_CLICK, [intptr]0, [intptr]0)
    } else {
        $result.Method = 'SendMessageTimeout'
        $res = [intptr]0
        $ok = ([SwdWin]::SendMessageTimeout([intptr]$btn.Handle, [SwdWin]::BM_CLICK,
                   [intptr]0, [intptr]0, [SwdWin]::SMTO_ABORTIFHUNG, $TimeoutMs, [ref]$res) -ne [intptr]0)
    }
    $result.Sent = $ok
    if (-not $ok) { $result.LastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error() }
    # Observed, not Sent, is the field a caller should branch on: with -Post,
    # Sent is a constant that cannot fail and means only "queued".
    $result.Observed = Get-SwdTransportOutcome -Method $result.Method -Ok $ok -LastError $result.LastError
    $result.Reason   = Format-SwdSendError -LastError $result.LastError -Sent $ok -Method $result.Method
    return [pscustomobject]$result
}

function Get-SwdTransportOutcome {
    <#  What was ACTUALLY OBSERVED of a BM_CLICK, named per transport.

        `Sent` answers "did the transport call succeed", and that question means
        two different things depending on which call was used - which is how a
        posted click came to report Sent=$true, Reason='delivered' having
        observed only that a message entered a queue. This returns the observed
        fact instead of the call return:

          not-attempted  no message was dispatched at all
          queued         PostMessage succeeded. The message is on the target
                         thread queue. NOTHING is known about it being processed,
                         and this outcome essentially cannot fail against a live
                         window, so it is not evidence of anything.
          handled        SendMessageTimeout returned. The target window procedure
                         ran to completion for this message - which still says
                         nothing about what the control did with it.
          ambiguous      the send did not complete and lastError is 1460. See
                         Format-SwdSendError: both readings produce that code.
          refused        the transport call failed for any other reason.

        This is the third round in which a newly written reporting field claimed
        more than it observed (Clicked, then Sent, then Reason). The rule the
        three share: NAME THE OBSERVATION, NOT THE HOPE.  #>
    param(
        [Parameter(Mandatory)][ValidateSet('PostMessage', 'SendMessageTimeout', 'none')][string]$Method,
        [Parameter(Mandatory)][bool]$Ok,
        [int]$LastError = 0
    )
    if ($Method -eq 'none') { return 'not-attempted' }
    if (-not $Ok)           { return $(if ($LastError -eq 1460) { 'ambiguous' } else { 'refused' }) }
    if ($Method -eq 'PostMessage') { return 'queued' }
    return 'handled'
}

function Format-SwdSendError {
    <#  Turns a Win32 error from a BM_CLICK into an honest reading.

        1460 (ERROR_TIMEOUT) IS AMBIGUOUS. This helper was first written
        asserting the opposite - "the click most likely LANDED ... do NOT read
        this as failure" - which replaced one confident wrong reading with the
        confident opposite one. Both readings produce the identical error code.
        Measured 2026-08-28 against a throwaway cross-process WinForms target:

          pump BLOCKED by a sleeping UI thread, click sent during the block:
            two sends, both sent=False lastError=1460, and after the thread
            resumed the target click counter still read 'CNT 0'.
            NEITHER CLICK LANDED.
          click LANDS and its handler opens a modal:
            sent=False lastError=1460, and the target caption advanced.
            THE CLICK LANDED.

        The code cannot separate them and neither can this function. Only
        observation can: poll with Wait-SwdDialog for a modal appearing, or
        Wait-SwdDialogGone for one being dismissed, and read the target own
        state.  #>
    param(
        [Parameter(Mandatory)][int]$LastError,
        [bool]$Sent = $false,
        [ValidateSet('PostMessage', 'SendMessageTimeout', 'none')][string]$Method = 'SendMessageTimeout'
    )
    # A SUCCESSFUL POST IS NOT A DELIVERY. PostMessage returns non-zero for
    # placing the message on the target thread queue; it has observed nothing
    # about the message being processed, and against a live window it
    # essentially cannot fail - so on this path `Sent` is a constant and the
    # 5 / 1460 / 1400 taxonomy below is unreachable. Measured 2026-08-28
    # against a blocked pump: Sent=True LastError=0 while the target log showed
    # the click had not run and never did. Saying 'delivered' there was
    # Clicked-before-the-send in its third costume.
    if ($Sent -and $Method -eq 'PostMessage') {
        return 'QUEUED ONLY - PostMessage placed the message on the target queue and observed nothing further. It cannot report delivery, and on this path it cannot fail, so a success here is not evidence. Confirm by observing: Wait-SwdDialogGone, or the target own state.'
    }
    if ($Sent) { return 'delivered - the target window procedure processed the message, which still says nothing about what the control DID with it.' }
    switch ($LastError) {
        5       { 'REFUSED by UIPI (ERROR_ACCESS_DENIED) - this shell is lower integrity than SWD. Re-run elevated.' }
        1460    { 'TIMED OUT (ERROR_TIMEOUT) - AMBIGUOUS, and this code cannot resolve it. The send did not complete in time, which happens BOTH when the click landed and opened a modal that blocks the pump, AND when the pump was already blocked and the click never landed at all. Measured both ways 2026-08-28. Treat it as neither success nor failure; observe instead, with Wait-SwdDialog or Wait-SwdDialogGone plus the target own state.' }
        1400    { 'INVALID WINDOW HANDLE - the control is gone.' }
        0       { 'send returned false with no error code - state unknown.' }
        default { "send returned false, lastError=$LastError" }
    }
}
