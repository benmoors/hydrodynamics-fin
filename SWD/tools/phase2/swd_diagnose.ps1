<#
.SYNOPSIS
    Step 0 of WP3 - settle why automation was blocked, and whether the headless
    route is available.

.DESCRIPTION
    Two incompatible diagnoses of the Phase 2 blocker are on record:

      phase2-hydroscan.md  a stuck BlockInput held by some screen-control tool,
                           and explicitly "same integrity level as SWD, so UIPI
                           is not the cause"
      the WP3 plan         UIPI - SWD's manifest asks for highestAvailable, so on
                           an admin account it runs at High integrity and refuses
                           messages from a Medium-integrity client

    They prescribe different fixes, so this script measures rather than assumes.
    It is READ-ONLY: it sends no click and changes no application state unless
    -ClickProbe is given an explicit handle, which is the one deliberate action
    and is never chosen automatically.

    Run it TWICE - once from a normal shell, once from an elevated one. The
    difference between the two runs is the entire answer.

    A section that throws is caught, logged as NOT CHECKED, and the run
    continues to the Summary. A section that cannot measure says so; it never
    falls through to the conclusion it would have printed had it succeeded.

.PARAMETER ClickProbe
    Handle of a HARMLESS control to send an unfocused BM_CLICK to. Pick it from
    control-map.csv after reading the map. Never pass the scan button here.

.PARAMETER Activate
    Only meaningful with -ClickProbe. Bring SWD to the foreground before the
    click, and report whether that actually happened. This is the documented
    fallback if the unfocused click does not land - it costs the headless
    property, which is why it is off by default and why the probe exists.

.PARAMETER SkipCursorTest
    Skip section C, which briefly moves the mouse pointer and puts it back. Use
    this if the machine is being used for something else at the time.

.PARAMETER LogDir
    Where to write the run log. Validated against CLAUDE.md section 4: the run
    refuses to start if it resolves inside the SWD install or the SWD library.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File swd_diagnose.ps1
    Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','<full path>\swd_diagnose.ps1'
#>
[CmdletBinding()]
param(
    [int64]$ClickProbe = 0,
    [switch]$Activate,
    [switch]$SkipCursorTest,
    # NOT defaulted to a $PSScriptRoot expression - see the note below. Resolved
    # after the param block instead.
    [string]$LogDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# MEASURED TRAP, Windows PowerShell 5.1: with [CmdletBinding()] present,
# $PSScriptRoot is EMPTY inside param() default values. Remove the attribute and
# the same default works. Isolated 2026-08-27 by bisecting a minimal repro - the
# help block and the relative-vs-absolute -File path were both ruled out first.
# The failure is a bind error before the first line of the body runs, so it is
# loud rather than silent, but it would have hit the elevated run identically.
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ScriptDir) { throw 'Cannot determine the script directory.' }
if (-not $LogDir)    { $LogDir = Join-Path $ScriptDir 'logs' }

. (Join-Path $ScriptDir 'swd_msg.ps1')

# CLAUDE.md section 4 forbids writing inside the SWD install and inside the SWD
# library. Both output paths are checked BEFORE anything is created: New-Item
# -Force would otherwise happily build a directory tree under
# C:\Program Files\ShaperWaveDynamics\ on request from an elevated run, which is
# the exact shape of "a hard rule with no code behind it".  (SQA W15b, W16.)
# THE RESOLVED PATHS ARE WHAT GET WRITTEN. Validating $LogDir and then handing
# the raw string to New-Item is round 2's W1: New-Item -Path goes through the
# PowerShell PROVIDER, which expands '~' and PSDrives that [IO.Path] leaves
# alone, so a '~'-spelled library path passed the old check and wrote into the
# real biblio. Resolve once, reassign, and never touch the raw string again.
$rawLog  = $LogDir
$LogDir  = Resolve-SwdWritableTarget -Path $rawLog
if (-not $LogDir) { throw "Refusing to run: '$rawLog' is not a permitted output directory (CLAUDE.md section 4)." }
$rawMap  = Join-Path $ScriptDir 'control-map.csv'
$mapPath = Resolve-SwdWritableTarget -Path $rawMap
if (-not $mapPath) { throw "Refusing to run: '$rawMap' is not a permitted output path (CLAUDE.md section 4)." }

# -LiteralPath on BOTH: Test-Path -LiteralPath beside New-Item -Path was two
# resolvers on one line, the same defect in miniature.
# [IO.Directory]::CreateDirectory, not New-Item: New-Item has NO -LiteralPath
# parameter in EITHER host (measured, 5.1 and 7.6.5), so the -LiteralPath
# spelling introduced in round 2 threw on the very first run into a log
# directory that did not exist yet - never noticed because every smoke test
# had pre-created it. The .NET call takes the path literally, which is also
# what the one-resolver rule wants: no provider re-parsing of a string the
# guard already canonicalised.
if (-not (Test-Path -LiteralPath $LogDir)) { [void][IO.Directory]::CreateDirectory($LogDir) }
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $LogDir "$stamp-diagnose.log"

# UTF-8 with NO BOM. Tee-Object and Out-File both write UTF-16LE-with-BOM under
# Windows PowerShell 5.1, which is the trap CLAUDE.md section 5 already records
# ("a BOM breaks the Python readers downstream"). Measured here on the first
# elevated run: the log came back as 'ff fe 53 00' - UTF-16LE.
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Log {
    param([string]$Text = '')
    $Text | Out-Host
    [IO.File]::AppendAllText($logPath, $Text + [Environment]::NewLine, $script:Utf8NoBom)
}
function Section { param([string]$T) ; Log '' ; Log "=== $T ===" }

# Test-SwdOwnsForeground now lives in swd_msg.ps1, dot-sourced above. It moved
# because it had ZERO effective coverage here: mutants returning unconditional
# $true and unconditional $false BOTH passed this file whole 18-test suite. It
# is also three-state now - $null means the question could not be answered - so
# every consumer below must test for $null explicitly rather than let PowerShell
# read unknown as "no".

function Write-SectionFailure {
    <#  SQA W14: sections E and F were unguarded under $ErrorActionPreference =
        'Stop', so any throw killed the run before the Summary - and because Log
        only writes what it is handed, the exception never reached the log file
        at all. The artifact ended mid-section with no marker, which is
        indistinguishable from a clean run that found nothing.

        Every section now routes its failure through here. A failed section is
        recorded as NOT CHECKED, never as passing.  #>
    param([Parameter(Mandatory)]$Err, [Parameter(Mandatory)][string]$Name)
    Log ''
    Log "  !! SECTION $Name FAILED - NOT CHECKED, not passing."
    # Escaped: an exception message can carry a control caption verbatim - a
    # refusal from Invoke-SwdButton quotes the class name - so this is a log
    # boundary like any other, and target text must not forge a line here either.
    Log "     $($Err.Exception.GetType().Name): $(ConvertTo-SwdSafeText $Err.Exception.Message 300)"
    if ($Err.InvocationInfo) {
        Log "     at line $($Err.InvocationInfo.ScriptLineNumber): $(ConvertTo-SwdSafeText $Err.InvocationInfo.Line.Trim() 200)"
    }
    $script:SectionFailures += $Name
}
$script:SectionFailures = @()
$script:SectionSkips = @()
function Write-SectionSkip {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Why)
    Log "skipped - $Why"
    $script:SectionSkips += $Name
}

Log "SWD Phase 2 diagnostic - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Log "log: $logPath"

$elev    = $false
$selfSid = $null
$swd     = $null
$ctrls   = @()
$ctrlStats = $null
$script:MapWritten = $false

# ---------------------------------------------------------------- A. the host
Section 'A. Host'
try {
    $id   = [Security.Principal.WindowsIdentity]::GetCurrent()
    $elev = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    # Ask the token, do not infer from WindowsIdentity.Groups. Measured 2026-08-27:
    # the Groups test reported "Medium-or-lower" on an elevated run where the token
    # query in section B said High. Two sections of one report disagreeing is the
    # failure mode this whole exercise exists to avoid.
    $selfSid = [SwdWin]::IntegritySid($PID)
    # The account name is NOT logged. $elev plus the integrity SID answer every
    # question this section asks, and the log otherwise carries an identity into
    # a file that also holds the board name and surfer mass.  (SQA S25.)
    Log "PowerShell    : $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    Log "ELEVATED      : $elev"
    Log "own integrity : $(Format-Integrity $selfSid)"
    if (-not $elev) {
        Log ''
        Log '  NOTE: this run is NOT elevated. If SWD is elevated, sections D-F are'
        Log '  EXPECTED to fail, and that failure is the finding. Re-run from an'
        Log '  elevated shell to complete the comparison:'
        Log "    Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$PSCommandPath'"
    }
} catch { Write-SectionFailure $_ 'A' }

# ------------------------------------------------------------- B. the process
Section 'B. SWD process and integrity'
try {
    try { $swd = Get-SwdProcess } catch { Log "SWD NOT USABLE - $($_.Exception.Message)" }

    if ($swd) {
        Log "pid           : $($swd.Id)"
        Log "session       : $($swd.SessionId)"
        Log "main HWND     : $($swd.MainWindowHandle)"
        # Escaped: the title is target-controlled and is one of the four fields
        # SQA found capable of forging a line break in this log.  (SQA W17.)
        Log "title         : $(ConvertTo-SwdSafeText $swd.MainWindowTitle 200)"
        Log "started       : $($swd.StartTime)"
        Log "minimised     : $([SwdWin]::IsIconic($swd.MainWindowHandle))"

        $swdSid = [SwdWin]::IntegritySid($swd.Id)
        Log "this shell    : $(Format-Integrity $selfSid)"
        Log "SWD           : $(Format-Integrity $swdSid)"

        if ($null -eq $swdSid) {
            Log ''
            Log "  >> SWD's token could not be opened from here. From a Medium-integrity"
            Log '     caller that IS the answer: SWD sits higher. UIPI is the blocker,'
            Log '     and the fix is to run this automation elevated.'
        } elseif ($swdSid -eq $selfSid) {
            Log ''
            Log '  >> Same integrity level. UIPI is NOT the blocker between these two'
            Log '     processes. If messages still do not land, section C is where to look.'
        } else {
            Log ''
            Log '  >> DIFFERENT integrity levels. Messages from the lower to the higher'
            Log '     are filtered by UIPI. Match them before concluding anything else.'
        }
    }
} catch { Write-SectionFailure $_ 'B' }

# --------------------------------------------------------- C. the input block
Section 'C. Residual input block'
try {
    if ($SkipCursorTest) {
        Write-SectionSkip 'C' 'the cursor test was skipped with -SkipCursorTest; NOT CHECKED, not passing'
    } else {
        $orig = New-Object 'SwdWin+PT'
        $haveOrig = [SwdWin]::GetCursorPos([ref]$orig)
        Log "cursor now    : $(if ($haveOrig) { "($($orig.X),$($orig.Y))" } else { 'GetCursorPos FAILED' })"

        if (-not $haveOrig) {
            # SQA S21: the first draft went ahead anyway. With GetCursorPos failed,
            # $orig is a fresh PT at (0,0), so the "nudge one pixel" moved the
            # pointer to (1,0) - and the restore was gated on $haveOrig, so it
            # was never moved back. Do not move a pointer you cannot put back.
            Log 'SetCursorPos  : NOT ATTEMPTED - the original position is unknown, so the'
            Log '                pointer could not be restored afterwards. NOT CHECKED.'
            Log ''
            Log '  >> Section C could not run. It says nothing either way about an input'
            Log '     block; do not read this as a pass.'
        } else {
            # Nudge one pixel and put it straight back. The pairing is the real test:
            # a stuck BlockInput makes SetCursorPos return False, and makes every other
            # automation API return success while discarding the input.
            $target = @{ X = $orig.X + 1; Y = $orig.Y }
            $setOk  = [SwdWin]::SetCursorPos($target.X, $target.Y)
            $err    = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Start-Sleep -Milliseconds 60
            $after  = New-Object 'SwdWin+PT'
            $gotAfter = [SwdWin]::GetCursorPos([ref]$after)
            $landed = ($gotAfter -and $after.X -eq $target.X -and $after.Y -eq $target.Y)
            [void][SwdWin]::SetCursorPos($orig.X, $orig.Y)

            # lastError is only meaningful when the call FAILED: Win32 does not
            # clear it on success. Run 2 logged "returned True (lastError=183)" -
            # ERROR_ALREADY_EXISTS, stale from an unrelated call, presented as if
            # it described this one. BlockInput below is different: False is its
            # normal answer, and 5-versus-0 there is the elevated/non-elevated
            # comparison this whole script exists to make.
            $errNote = ''
            if (-not $setOk) { $errNote = " (lastError=$err)" }
            Log "SetCursorPos  : returned $setOk$errNote"
            # W3: $gotAfter gates the PRINT as well as $landed. A fresh PT is
            # (0,0), so an ungated read-back printed a fabricated pointer position
            # as a measurement - in the section that decides whether input is
            # blocked. The first read at the top of this block already gates.
            $gotNote = if ($gotAfter) { "got ($($after.X),$($after.Y))" } else { 'the read-back FAILED, so no position was measured' }
            Log "cursor landed : $landed  (asked ($($target.X),$($target.Y)), $gotNote)"

            $blockOk  = [SwdWin]::BlockInput($false)
            $blockErr = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Log "BlockInput(0) : returned $blockOk (lastError=$blockErr)"

            Log ''
            if ($setOk -and $landed) {
                Log '  >> No input block. The 2026-08-26 BlockInput diagnosis does not'
                Log '     reproduce; whatever held it is gone.'
            } else {
                Log '  >> INPUT MAY BE BLOCKED. SetCursorPos must return True AND the'
                Log '     cursor must land - both, not either, and one of them did not.'
                # SQA W8: the first draft asserted, unconditionally and without even
                # testing $blockErr, that "lastError=5 means another process holds the
                # block". This script's OWN notes refute that: on 2026-08-27 a
                # non-elevated run measured BlockInput(false) = False with lastError 5
                # while the cursor moved freely, and the elevated run measured False
                # with lastError 0. Error 5 is what a non-elevated caller gets. It
                # sent the operator hunting a process that does not exist.
                if ($blockErr -eq 5) {
                    Log "     BlockInput(false) reported lastError=5. On this machine that has"
                    Log "     been measured on a NON-ELEVATED run whose cursor moved freely, so"
                    Log '     on its own it means "not elevated", NOT "another process holds a'
                    Log '     block". Compare an elevated run before drawing any conclusion.'
                }
                Log '     A held block is only one explanation. Check section B first:'
                Log '     UIPI produces the same "call succeeds, nothing happens" shape.'
            }
        }
    }
} catch { Write-SectionFailure $_ 'C' }

# ------------------------------------------------------------------- D. UIA
Section 'D. UI Automation tree'
try {
    if (-not $swd) { Write-SectionSkip 'D' 'SWD not running' } else {
        try {
            Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop
            $root = [System.Windows.Automation.AutomationElement]::RootElement
            $cond = New-Object System.Windows.Automation.PropertyCondition(
                        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $swd.Id)
            $main = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
            if (-not $main) { Log 'no top-level UIA element for SWD' } else {
                # NO CacheRequest here, and that is a measured decision, not an
                # oversight. SQA S28 proposed one; min-of-5 against a throwaway
                # WinForms target it measured 3.50 ms against 3.17 ms uncached at
                # n=8 - SLOWER. This section runs once per run at about 3 ms and is
                # not a hot path, so the Knuth bar applies. Re-measure at n=131
                # (the elevated SWD figure) before revisiting; do not re-derive.
                $all = $main.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                         (New-Object System.Windows.Automation.PropertyCondition(
                            [System.Windows.Automation.AutomationElement]::IsControlElementProperty, $true)))
                Log "descendant control elements: $($all.Count)"
                $byType = @{}
                $named  = 0
                foreach ($e in $all) {
                    $t = $e.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
                    if (-not $byType.ContainsKey($t)) { $byType[$t] = 0 }
                    $byType[$t]++
                    if ($e.Current.Name) { $named++ }
                }
                foreach ($k in ($byType.Keys | Sort-Object)) { Log ("  {0,-16} {1}" -f $k, $byType[$k]) }
                Log "  named elements : $named of $($all.Count)"
                Log ''
                # SQA W13: with $all.Count -eq 0, Keys.Count -le 1 was True but
                # ContainsKey('Pane') was False, so control fell through to
                # "Named control types are visible, so UIA can reach the provider" -
                # the exact opposite conclusion, printed from an empty tree.
                if ($all.Count -eq 0) {
                    Log '  >> ZERO control elements. This is NOT "the provider is reachable".'
                    Log '     Either SWD has no UIA-visible content or this client cannot see'
                    Log '     into it at all. Compare section B and re-run elevated.'
                } elseif ($byType.Keys.Count -le 1 -and $byType.ContainsKey('Pane')) {
                    Log '  >> EVERY element is a bare Pane, so UIA is falling back to the'
                    Log "     generic HWND provider instead of SWD's own in-process provider."
                    Log '     An integrity mismatch is the usual cause - but NOT the only one.'
                    Log '     Measured 2026-08-27 against a throwaway WinForms window at the'
                    Log '     SAME integrity as its client: 8 of 8 elements came back Pane,'
                    Log '     with names intact. Read this together with section B and with'
                    Log '     the named count above; on its own it does not prove UIPI.'
                } else {
                    Log '  >> Named control types are visible, so UIA can reach the provider.'
                    Log '     If a previous run saw only Panes, elevation is what changed.'
                }
            }
        } catch {
            Log "UIA unavailable in this host: $($_.Exception.Message)"
            Log '  (UIAutomationClient is a .NET Framework assembly - use powershell.exe 5.1, not pwsh 7.)'
        }
    }
} catch { Write-SectionFailure $_ 'D' }

# -------------------------------------------------------- E. child windows
Section 'E. Win32 child windows'
try {
    if (-not $swd) { Write-SectionSkip 'E' 'SWD not running' } else {
        $ctrls = @(Get-SwdControl)
        $ctrlStats = Get-SwdControlSummary
        Log "child windows found: $($ctrls.Count)   (the plan records 165; 181 was measured 2026-08-27)"
        # SQA C6: this is the number that makes the rest of the section readable.
        # A fully hung SWD returns a complete-looking map in milliseconds with
        # every Text $null, and without this line "controls whose text mentions
        # scan: 0" is indistinguishable from a genuine zero.
        Log ("read status: text read for {0} of {1}; {2} timed out; {3} skipped; {4} ms{5}" -f
             $ctrlStats.WithText, $ctrlStats.Total, $ctrlStats.TimedOut, $ctrlStats.Skipped,
             $ctrlStats.ElapsedMs, $(if ($ctrlStats.DeadlineHit) { '  ** DEADLINE HIT **' } else { '' }))
        if ($ctrlStats.TimedOut -gt 0) {
            $errs = @($ctrls | Where-Object { $_.TimedOut -and $_.LastError -ne 0 } |
                        Group-Object LastError | ForEach-Object { "$($_.Name)x$($_.Count)" })
            Log '  >> SOME CONTROLS DID NOT ANSWER. Every count below is a LOWER BOUND,'
            Log '     not a measurement. A zero here may mean "hung", not "absent".'
            if ($errs) { Log "     Win32 errors on the failed reads: $($errs -join ', ')  (5 = ACCESS_DENIED, the UIPI signature)" }
        }

        # UTF-8 with NO BOM: Export-Csv -Encoding UTF8 writes a BOM under 5.1 and
        # the live control-map.csv begins ef bb bf. The log was fixed for exactly
        # this trap one line away, and the CSV - the file downstream Python
        # actually parses - was missed.  (SQA W9.)
        #
        # Only Class and Text are neutralised against formula injection: they are
        # the two columns whose content comes from the target application. The
        # numeric columns are built by this project's own C# from Win32
        # primitives, and neutralising them would put an apostrophe in front of
        # every negative Rect - and this project already has a virtual desktop
        # with a negative origin.  (SQA S27.)
        $injected = 0
        $safeRows = foreach ($r in ($ctrls | Sort-Object Class, Handle)) {
            $cls = ConvertTo-SwdCsvCell $r.Class
            $txt = ConvertTo-SwdCsvCell $r.Text
            if ($cls -ne $r.Class) { $injected++ }
            if ($txt -ne $r.Text)  { $injected++ }
            [pscustomobject][ordered]@{
                Handle = $r.Handle; Class = $cls; CtrlId = $r.CtrlId
                Visible = $r.Visible; Enabled = $r.Enabled; Rect = $r.Rect; Parent = $r.Parent
                Text = $txt; TimedOut = $r.TimedOut; Skipped = $r.Skipped; LastError = $r.LastError
            }
        }
        [IO.File]::WriteAllLines($mapPath, @($safeRows | ConvertTo-Csv -NoTypeInformation), $script:Utf8NoBom)
        $script:MapWritten = $true
        Log "control map -> $mapPath  (UTF-8, no BOM)"
        if ($injected -gt 0) {
            Log "  NOTE: $injected cell(s) began with = + - @ or a control character and were"
            Log "  prefixed with an apostrophe so a spreadsheet cannot evaluate them. A reader"
            Log '  must strip one leading apostrophe from Class and Text.'
        }

        Log ''
        Log 'by window class:'
        $ctrls | Group-Object Class | Sort-Object Count -Descending |
            ForEach-Object { Log ("  {0,-44} {1}" -f (ConvertTo-SwdSafeText $_.Name 120), $_.Count) }

        # NumericUpDown is a container holding an EDIT plus an msctls_updown32 buddy.
        # Finding the buddies is how the numeric fields are located without names.
        $updowns = @($ctrls | Where-Object { $_.Class -like '*updown*' })
        Log ''
        Log "up-down buddies (=> NumericUpDown controls): $($updowns.Count)"
        foreach ($u in $updowns) {
            $sibs = @($ctrls | Where-Object { $_.Parent -eq $u.Parent -and $_.Class -like '*EDIT*' })
            foreach ($s in $sibs) {
                Log ("  updown {0,-12} edit {1,-12} value='{2}' rect={3}" -f
                     $u.Handle, $s.Handle, (ConvertTo-SwdSafeText $s.Text 40), $s.Rect)
            }
        }

        Log ''
        Log 'buttons carrying text (BM_CLICK targets):'
        $ctrls | Where-Object { $_.Class -like '*BUTTON*' -and $_.Text } |
            ForEach-Object { Log ("  {0,-12} enabled={1,-5} '{2}'" -f $_.Handle, $_.Enabled, (ConvertTo-SwdSafeText $_.Text 80)) }
        Log '  (a DISABLED control here is not a safe target: measured, an unfocused'
        Log "   BM_CLICK toggled a disabled WinForms CheckBox. Invoke-SwdButton refuses"
        Log '   one unless -Force is given.)'

        $scanish = @($ctrls | Where-Object { $_.Text -and $_.Text -match 'scan|hydro|drift|speed|vitesse' })
        Log ''
        Log "controls whose text mentions scan/hydro/drift/speed: $($scanish.Count)$(if ($ctrlStats.TimedOut -gt 0) { ' (LOWER BOUND - see read status)' } else { '' })"
        $scanish | ForEach-Object { Log ("  {0,-12} {1,-38} '{2}'" -f $_.Handle, (ConvertTo-SwdSafeText $_.Class 38), (ConvertTo-SwdSafeText $_.Text 80)) }

        if ($ctrls.Count -eq 0) {
            Log ''
            Log '  >> ZERO child windows. Either the handle is wrong or this process'
            Log '     cannot see into SWD at all. Check section B before anything else.'
        }
    }
} catch { Write-SectionFailure $_ 'E' }

# ------------------------------------------------------- F. the headless test
Section 'F. Unfocused BM_CLICK probe'
try {
    if (-not $swd) { Write-SectionSkip 'F' 'SWD not running' }
    elseif ($ClickProbe -eq 0) {
        Log 'NOT RUN - no -ClickProbe handle given.'
        Log ''
        Log 'This is the measurement the whole headless route rests on. Microsoft'
        Log 'documents that BM_CLICK "might fail" on a button in a dialog that is not'
        Log 'active; if that applies here, SWD has to hold focus and the scan cannot'
        Log 'run quietly in the background.'
        Log ''
        Log 'To settle it: read control-map.csv and pick a HARMLESS control - never the'
        Log 'scan button. Pick one whose CAPTION changes when it is operated, not a'
        Log 'checkbox: measured 2026-08-27, a WinForms FlatStyle=Standard CheckBox that'
        Log 'was genuinely checked still answered BM_GETCHECK=0 and never changed its'
        Log 'window text, so a checkbox can toggle invisibly. Then re-run with'
        Log '-ClickProbe <handle>.'
    }
    elseif ($ctrls.Count -eq 0) {
        Log 'NOT RUN - section E produced no control map, so there is nothing to diff'
        Log 'against and no way to check that the handle belongs to SWD.'
    }
    else {
        # E19 said this section re-enumerated to answer a membership question
        # section E had already answered. That is still true and section E's map
        # still answers it, for free - but it is NOT a usable BEFORE snapshot for
        # the click, and round 2 (W4) was right that reusing it was a regression.
        # E's map predates the CSV write, all of E's logging and the state probes
        # below, so any control that updates itself in that window read as
        # CHANGED - and inside the probe's own parent group, as "THE CLICK
        # LANDED". That is the project's central experiment reporting a result it
        # did not measure, which is the one thing this code may not do.
        #
        # So: membership from E's map (free), and a FRESH enumeration immediately
        # before the click. That costs one extra enumeration when -ClickProbe is
        # given and it is worth it - E19 was never worth this.
        $probe = $ctrls | Where-Object { $_.Handle -eq $ClickProbe } | Select-Object -First 1
        if (-not $probe) { Log "handle $ClickProbe is not a child window of SWD - refusing." } else {
            $fg = [SwdWin]::GetForegroundWindow()
            Log "probe target  : $($probe.Handle)  class=$(ConvertTo-SwdSafeText $probe.Class 60)  text='$(ConvertTo-SwdSafeText $probe.Text 80)'"
            Log "foreground now: $fg  (SWD main is $($swd.MainWindowHandle))"
            # $null is UNKNOWN and is rendered as such. It used to be unreachable:
            # the predicate returned $false for a null foreground (a locked
            # session, or the UAC secure desktop) and for a dead handle, and
            # $false is the exact premise the UNFOCUSED conclusion rests on.
            $fgOwned = Test-SwdOwnsForeground -Handle $fg -ProcessId $swd.Id
            Log "SWD focused   : $(if ($null -eq $fgOwned) { 'UNKNOWN' } else { $fgOwned })  (by owning process, not handle identity)"
            if ($null -eq $fgOwned) {
                Log ''
                Log '  WARNING: the foreground could not be read (no foreground window, or'
                Log '  its owner could not be determined). This run cannot speak to the'
                Log '  focused/unfocused question in either direction.'
            } elseif ($fgOwned -and -not $Activate) {
                Log ''
                Log '  WARNING: SWD currently HAS focus, so this probe cannot distinguish'
                Log '  focused from unfocused behaviour. Click another window first.'
            }

            # BM_GETCHECK is recorded because it is free and occasionally
            # informative, and is explicitly NOT used to conclude anything.
            $chk = [intptr]0
            [void][SwdWin]::SendMessageTimeout([intptr]$ClickProbe, [SwdWin]::BM_GETCHECK, [intptr]0, [intptr]0,
                                               [SwdWin]::SMTO_ABORTIFHUNG, 2000, [ref]$chk)
            $st = [intptr]0
            [void][SwdWin]::SendMessageTimeout([intptr]$ClickProbe, [SwdWin]::BM_GETSTATE, [intptr]0, [intptr]0,
                                               [SwdWin]::SMTO_ABORTIFHUNG, 2000, [ref]$st)
            Log ("before        : checkState={0} buttonState=0x{1:X}  (both UNRELIABLE on FlatStyle=Standard)" -f $chk.ToInt64(), $st.ToInt64())

            # THE BEFORE SNAPSHOT, TAKEN LAST. Everything above this line - the
            # CSV write, section E's logging, the two state probes - happens
            # BEFORE it, so none of it lands inside the measurement window. The
            # window is now (this enumeration) -> (click) -> (that enumeration),
            # and its width is logged so a reader can judge it.  (Round 2, W4.)
            $beforeMap = @(Get-SwdControl)
            $beforeStats = Get-SwdControlSummary
            # Logged BEFORE the stopwatch starts. Writing to the log inside
            # the measurement window sends nothing to SWD, so W4 held in
            # substance - but "nothing state-changing remains in the window"
            # was not literally true, and a claim that needs a footnote is
            # cheaper to make true. The before-enumeration's own duration is
            # reported too: the window below is measured from AFTER it, so
            # the map is that much older than the window width suggests.
            Log ("before read   : text read for {0} of {1}; {2} timed out; snapshot took {3} ms" -f
                 $beforeStats.WithText, $beforeStats.Total, $beforeStats.TimedOut, $beforeStats.ElapsedMs)
            $windowSw = [Diagnostics.Stopwatch]::StartNew()

            $r = $null
            try {
                $r = Invoke-SwdButton -Handle $ClickProbe -Activate:$Activate
            } catch {
                Log ''
                Log "  REFUSED: $(ConvertTo-SwdSafeText $_.Exception.Message 300)"
                Log '  Pick an ENABLED control of class *BUTTON* from control-map.csv.'
            }

            if ($r) {
                # activateAchieved is THREE-STATE now that Set-SwdForeground
                # measures by owning process: $null means "could not be
                # measured", which is NOT the same as "was not asked for".
                # Rendering both as 'n/a' put an unmeasured state and an
                # unattempted one on the same line.
                $ach = if (-not $r.ActivateAsked)        { 'n/a (not asked)' }
                       elseif ($null -eq $r.ActivateAchieved) { 'UNKNOWN (not measured)' }
                       else                              { $r.ActivateAchieved }
                Log ("BM_CLICK      : method={0} sent={1} observed={2} lastError={3} activateAsked={4} activateAchieved={5}" -f
                     $r.Method, $r.Sent, $r.Observed, $r.LastError, $r.ActivateAsked, $ach)
                Log '  (sent is the TRANSPORT CALL returning success, nothing more. Read'
                Log '   observed instead: queued means only that a posted message entered'
                Log '   the target queue, handled means the window procedure ran - and even'
                Log '   handled says nothing about what the control DID.)'
                Start-Sleep -Milliseconds 400

                $after = @(Get-SwdControl)
                $afterStats = Get-SwdControlSummary
                Log ("after read    : text read for {0} of {1}; {2} timed out" -f
                     $afterStats.WithText, $afterStats.Total, $afterStats.TimedOut)

                $windowSw.Stop()
                # Re-sampled AFTER the click. $fg was taken once, before the
                # window even opened, and then drove the UNFOCUSED conclusion -
                # so a foreground change during the window was invisible to the
                # one claim that depends on it. Both samples must agree.
                $fgAfter = [SwdWin]::GetForegroundWindow()
                # QA Warning 1: this used to compare handle identity against a
                # MainWindowHandle cached once at section B. SWD holding the
                # foreground through a SECOND top-level window - a modal, which
                # it demonstrably raises - then read as "not focused", printing
                # THE CLICK LANDED WITHOUT FOCUS for a run that was focused.
                # Ask which PROCESS owns the foreground instead. OwnerPid already
                # existed and was already used correctly elsewhere in this file.
                # THREE-STATE COMBINATION, and -or gets it wrong: PowerShell treats
                # $null as falsy, so "unknown or unknown" would come out $false -
                # the affirmative claim "SWD did NOT hold the foreground", asserted
                # from two unmeasured samples. Held wins, then unknown; only two
                # measured negatives give $false.
                $fgOwnedAfter = Test-SwdOwnsForeground -Handle $fgAfter -ProcessId $swd.Id
                $heldFocus =
                    if ($fgOwned -eq $true -or $fgOwnedAfter -eq $true)     { $true }
                    elseif ($null -eq $fgOwned -or $null -eq $fgOwnedAfter) { $null }
                    else                                                    { $false }
                if ($fg -ne $fgAfter) {
                    Log "foreground moved during the window: $fg -> $fgAfter"
                }
                Log ("measurement window: {0} ms from the BEFORE snapshot to the AFTER snapshot" -f [int]$windowSw.ElapsedMilliseconds)

                $diff = @(Compare-SwdMap -Before $beforeMap -After $after `
                                         -ProbeHandle $ClickProbe -ProbeParent ([int64]$probe.Parent))
                $changed      = @($diff | Where-Object { $_.Kind -ne 'UNCOMPARABLE' })
                $uncomparable = @($diff | Where-Object { $_.Kind -eq 'UNCOMPARABLE' })
                $onTarget     = @($changed | Where-Object { $_.OnTarget })

                Log ''
                Log "map diff      : $($changed.Count) change(s), $($onTarget.Count) on or beside the probed control, $($uncomparable.Count) uncomparable"
                foreach ($d in $diff | Select-Object -First 40) {
                    Log ("  {0,-12} {1,-12} {2,-8} onTarget={3,-5} '{4}' -> '{5}'" -f
                         $d.Handle, $d.Kind, $d.Field, $d.OnTarget, $d.From, $d.To)
                }
                if ($diff.Count -gt 40) { Log "  ... $($diff.Count - 40) more" }

                Log ''
                # The conclusion ladder. Every rung reports what was MEASURED. The
                # thing this must never do is print "no observable state change"
                # as if it were "the click did not land": SQA C2 measured a
                # genuinely-toggled WinForms checkbox that produced exactly zero
                # observable change through BM_GETCHECK and WM_GETTEXT.
                if (-not $r.Sent -and $r.LastError -eq 5) {
                    Log '  >> THE SEND ITSELF WAS REFUSED, lastError=5 (ERROR_ACCESS_DENIED).'
                    Log '     That is the UIPI signature and it IS the answer for this shell:'
                    Log '     re-run elevated and compare. Nothing about the click can be'
                    Log '     concluded from an unelevated run that was filtered.'
                } elseif (-not $r.Sent -and $r.LastError -eq 1460) {
                    # This branch has now been wrong in BOTH directions. It first
                    # printed "THE SEND FAILED. Nothing was measured"; that was
                    # replaced by "the click most likely LANDED ... do NOT read
                    # this as failure", which is the same mistake with the sign
                    # flipped. Measured 2026-08-28 on a throwaway cross-process
                    # WinForms target, BOTH of these return exactly 1460:
                    #   pump blocked, click sent during the block - two sends,
                    #     both 1460, click counter still 'CNT 0'. NEVER LANDED.
                    #   click lands and its handler opens a modal - 1460, and the
                    #     caption advanced. LANDED.
                    # The code therefore says nothing. Only observation does.
                    Log '  >> THE SEND TIMED OUT, lastError=1460 (ERROR_TIMEOUT). AMBIGUOUS.'
                    Log '     This is neither success nor failure, and this run cannot tell'
                    Log '     which. The same code appears when the click LANDED and opened a'
                    Log '     modal that blocks the pump, AND when the pump was ALREADY'
                    Log '     blocked so the click never landed. Both measured 2026-08-28.'
                    Log '     Settle it by OBSERVING: poll Wait-SwdDialog for a modal, and'
                    Log '     read the map diff logged just above. A diff on the target is'
                    Log '     evidence the click landed; an empty diff is NOT evidence that'
                    Log '     it did not - and with the pump blocked the AFTER read may'
                    Log '     itself have timed out, leaving no diff to read at all.'
                } elseif (-not $r.Sent) {
                    Log "  >> THE SEND FAILED, lastError=$($r.LastError). Nothing was measured."
                    Log "     $(Format-SwdSendError -LastError $r.LastError -Sent $false)"
                } elseif ($afterStats.TimedOut -gt 0 -or $beforeStats.TimedOut -gt 0) {
                    Log '  >> MEASUREMENT INVALID. Controls timed out on one or both sides of'
                    Log '     the click, so an absence of change is an absence of data. Re-run'
                    Log '     when SWD is idle before reading anything into this.'
                } elseif ($onTarget.Count -gt 0) {
                    # The UNFOCUSED claim is only made when the run was actually
                    # unfocused. Observed on a harness run that printed "THE CLICK
                    # LANDED WITHOUT FOCUS" immediately under "SWD focused: True",
                    # with the warning above it ignored - the conclusion has to
                    # carry the caveat, not merely sit near it.
                    if ($null -eq $heldFocus) {
                        Log '  >> THE CLICK LANDED - but the FOREGROUND STATE WAS NEVER'
                        Log '     MEASURED, so this run says NOTHING about the unfocused case,'
                        Log '     which is the whole question. Repeat on an unlocked,'
                        Log '     interactive session where GetForegroundWindow answers.'
                    } elseif ($heldFocus -or $r.ActivateAsked) {
                        Log '  >> THE CLICK LANDED - but this run does NOT demonstrate the'
                        Log '     UNFOCUSED case, which is the whole question. SWD held the'
                        if ($r.ActivateAsked) {
                            Log '     foreground because -Activate was used. Repeat WITHOUT it.'
                        } else {
                            Log '     foreground when the click was sent. Click another window'
                            Log '     first, then repeat.'
                        }
                    } else {
                        Log '  >> THE CLICK LANDED WITHOUT FOCUS. The probed control, or a sibling'
                        Log '     in the same container, changed across the click, and SWD did not'
                        Log '     hold the foreground. The headless route is available:'
                        Log "     Invoke-SwdButton stays on its -Activate:`$false default, SWD can"
                        Log '     be minimised, and the scan runs without taking the machine.'
                    }
                } elseif ($changed.Count -gt 0) {
                    Log '  >> SOMETHING CHANGED, BUT NOT AT THE TARGET. The application moved'
                    Log '     somewhere else in the tree - a clock, a status bar, a redraw.'
                    Log '     AMBIGUOUS: this is not evidence the click landed. Repeat on a'
                    Log '     control whose own caption changes.'
                } else {
                    Log '  >> INCONCLUSIVE - no observable change. This is NOT evidence that'
                    Log '     the click failed. Measured 2026-08-27: an unfocused BM_CLICK'
                    Log '     that DID toggle a WinForms FlatStyle=Standard CheckBox produced'
                    Log '     no change in BM_GETCHECK, BM_GETSTATE or window text, so a'
                    Log '     control can move invisibly to every instrument here.'
                    Log ''
                    Log '     Next, in order: (1) repeat on a control whose CAPTION changes,'
                    Log '     or one that opens a panel - the child-window count then moves;'
                    Log '     (2) if it still shows nothing, re-run with -Activate. If'
                    Log '     activation is what fixes it, the headless route needs tscon and'
                    Log '     route 2 of the plan applies. -Activate now reports the'
                    Log '     foreground it actually MEASURED afterwards, so a failed'
                    Log '     activation can no longer read as a successful one.'
                }
            }
        }
    }
} catch { Write-SectionFailure $_ 'F' }

Section 'Summary'
Log "elevated=$elev  swdRunning=$([bool]$swd)"
if ($ctrlStats) {
    Log "controls=$($ctrlStats.Total)  textRead=$($ctrlStats.WithText)  timedOut=$($ctrlStats.TimedOut)  skipped=$($ctrlStats.Skipped)"
}
# "all sections completed" was printed whenever nothing THREW - including a run
# where SWD was absent and C, D, E and F all skipped without measuring anything.
# A skip is NOT CHECKED, which is the same discipline section C already applies
# to -SkipCursorTest, so it is reported rather than folded into success.
if ($script:SectionFailures.Count -gt 0) {
    Log "SECTIONS THAT FAILED (NOT CHECKED): $($script:SectionFailures -join ', ')"
}
if ($script:SectionSkips.Count -gt 0) {
    Log "SECTIONS NOT CHECKED (skipped, not passing): $($script:SectionSkips -join ', ')"
}
if ($script:SectionFailures.Count -eq 0 -and $script:SectionSkips.Count -eq 0) {
    Log 'all sections completed'
}
Log "full log: $logPath"
# Only reported when THIS run wrote it. Test-Path alone would advertise a
# stale map from an earlier run as though it were this run's output.
if ($script:MapWritten) { Log "control map: $mapPath" }
elseif (Test-Path -LiteralPath $mapPath) { Log "control map: NOT written this run; $mapPath is from an earlier run" }
