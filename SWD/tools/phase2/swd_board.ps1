<#
.SYNOPSIS
    Select a board in SWD's library tree, and invoke File-menu items, via UI Automation.

.DESCRIPTION
    The message layer (swd_msg.ps1) drives SWD through WM_SETTEXT / BM_CLICK / WM_GETTEXT
    straight to HWNDs. Two things it structurally cannot reach:

      * The library tree. SysTreeView32 selection across a process boundary needs a
        TVITEM in SWD's own address space - VirtualAllocEx plus WriteProcessMemory.
        That is writing into another process's memory, and this installation is a
        EUR 210 machine-bound licence. REJECTED, not deferred.

      * The File menu. It is a WinForms MenuStrip; its items are not HWNDs at all, so
        EnumChildWindows cannot see them. All 645 rows across the three captured
        control maps contain zero Save / Save As entries. Not a gap in the capture -
        a gap in what HWND enumeration can express.

    UI Automation reaches both, through CONTROL PATTERNS rather than synthetic input:
    SelectionItemPattern.Select() on a TreeItem, InvokePattern.Invoke() on a MenuItem.
    No cursor, no screen coordinates, no DPI arithmetic, no memory writes. This is
    Microsoft's sanctioned cross-process route and WinForms exposes both patterns.

    WHAT THIS DELIBERATELY DOES NOT DO. swd_ui.ps1 also uses UIA, but only to compute a
    bounding rectangle and then fire SendInput at its centre. That approach depends on
    DPI scaling, virtual-desktop origin and window z-order, and it calls
    SetProcessDPIAware() at load - which is PROCESS-WIDE AND IRREVERSIBLE, so merely
    dot-sourcing it permanently changes the calling shell. This file never dot-sources
    swd_ui.ps1, never computes a coordinate, and never falls back to clicking. If a
    pattern is unavailable it REFUSES and says so.

    VERIFICATION CROSSES MECHANISMS. Selection is performed through UIA and confirmed by
    reading the window title with WM_GETTEXT - a different subsystem entirely. A driver
    that scans variant n while reporting variant m is the worst failure available here,
    and confirming a UIA action with a UIA read would not catch a stale element.

.NOTES
    Windows PowerShell 5.1 (Desktop) only: UIAutomationClient is a .NET Framework
    assembly and does not load on .NET Core.

    Dot-source this file; it sends nothing to SWD on load. It is NOT inert on load
    though, and two of the three effects are permanent in the calling shell:

      * Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes loads two .NET
        Framework assemblies into the session and they cannot be unloaded.
      * swd_msg.ps1 is dot-sourced from $PSScriptRoot when not already present, which
        brings Set-StrictMode into the caller's scope - documented behaviour of that
        file - and compiles the [SwdWin] P/Invoke type.

    It is still far short of swd_ui.ps1, whose SetProcessDPIAware() at load changes the
    process irreversibly.
#>

Set-StrictMode -Version Latest

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Windows PowerShell 5.1 required (UIAutomationClient is .NET Framework only).'
}

# Capture the script root at load time. Inside a [CmdletBinding()] param() default,
# $PSScriptRoot is empty on 5.1 - a trap already documented in phase2/RESUME.md.
$script:SwdBoardRoot = $PSScriptRoot
if (-not $script:SwdBoardRoot) {
    $script:SwdBoardRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

# Reuse the hardened message layer rather than re-implementing process identity and a
# timeout-protected text read. Get-SwdProcess already refuses when SWD is absent, when
# MORE THAN ONE instance is running, or when the main window handle is zero.
#
# Every function this file calls is listed. Most are paired with a parameter that only
# the HARDENED version of that function has; Get-SwdProcess is mapped to $null because
# it has NO such parameter, so that one entry is a PRESENCE CHECK ONLY - the comment
# used to overstate what it does. `Get-Command <name>` on its own resolves an
# Application, an alias or a stub just as readily as the real function, and the
# realistic trigger is an operator who dot-sourced an older swd_msg.ps1 out of a backup
# snapshot. What it still cannot detect is right signatures over wrong bodies: there is
# no version constant in that file to check against.
$script:BoardRequiredMsgApi = [ordered]@{
    'Get-SwdProcess'      = $null
    'Get-SwdText'         = 'TimeoutMs'
    'ConvertTo-SwdNumber' = 'Text'
}

function Test-SwdBoardMsgApi {
    <#
    .SYNOPSIS
        Names of $script:BoardRequiredMsgApi entries that are absent or not hardened.
    #>
    [CmdletBinding()]
    param()
    $bad = @()
    foreach ($name in $script:BoardRequiredMsgApi.Keys) {
        $cmd = Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue
        if (-not $cmd) { $bad += "$name (not loaded as a function)"; continue }
        $param = $script:BoardRequiredMsgApi[$name]
        if ($param -and -not $cmd.Parameters.ContainsKey($param)) {
            $bad += "$name (loaded, but has no -$param - this is an OLD swd_msg.ps1)"
        }
    }
    return ,$bad
}

if ((Test-SwdBoardMsgApi).Count -gt 0) {
    $msg = Join-Path $script:SwdBoardRoot 'swd_msg.ps1'
    if (-not (Test-Path -LiteralPath $msg)) {
        throw "swd_msg.ps1 not found beside this script at '$msg'."
    }
    . $msg
    $stillBad = Test-SwdBoardMsgApi
    if ($stillBad.Count -gt 0) {
        throw ("swd_msg.ps1 was loaded from '$msg' but does not provide the hardened API " +
               "this file requires: $($stillBad -join '; ').")
    }
}
# [SwdWin] is the P/Invoke type swd_msg.ps1 compiles; Get-SwdWindowTitle enumerates
# top-level windows through it. Checked separately because a type is not a command.
if (-not ('SwdWin' -as [type])) {
    throw 'swd_msg.ps1 loaded but the [SwdWin] type is absent; the message layer is incomplete.'
}

$script:UIA = [System.Windows.Automation.AutomationElement]
$script:TreeScope = [System.Windows.Automation.TreeScope]

# Title pattern for SWD's main window. The caption carries the loaded board and its
# length, e.g.
#   FYN Shaper Wave Dynamics  <Board: default_shortboard(1800.0mm)>  <no Wave>  ...
# It is the only board-identity oracle SWD offers.
$script:MainTitleLike = 'FYN Shaper Wave Dynamics*'


function Get-SwdUiaWindow {
    <#
    .SYNOPSIS
        The pinned main-window AutomationElement for the single SWD process.
    .DESCRIPTION
        Process.MainWindowHandle is NOT usable here. It returned three different values
        in one session during the 2026-08-31 live run, and once returned a window whose
        caption was 'Starting HydroScan' - a modal dialog. Resolving by pid alone has
        the same defect: RootElement.FindFirst(Children, pid) returns *a* top-level
        window for that process, which during a scan may be a dialog.

        So the window is identified by pid AND a title matching the main-window pattern,
        and the result is verified to be a window rather than a dialog before use.
    .OUTPUTS
        System.Windows.Automation.AutomationElement
    #>
    [CmdletBinding()]
    param()

    $swd = Get-SwdProcess          # throws unless exactly one SWD is running

    $byPid = New-Object System.Windows.Automation.PropertyCondition(
        $script:UIA::ProcessIdProperty, $swd.Id)
    $tops = $script:UIA::RootElement.FindAll($script:TreeScope::Children, $byPid)

    # $found, not $matches. The reason recorded here previously - that a local $matches
    # would shadow the automatic $Matches which Get-SwdLoadedBoard relies on - is
    # FACTUALLY WRONG and was measured to be: $Matches is per-scope, so a local
    # assignment in THIS function cannot reach another function's, and even within one
    # scope the next -match rebuilds it. The rename is kept anyway because $found says
    # what the variable holds and shadowing an automatic variable is worth avoiding on
    # its own account - just not for the stated reason.
    $found = @()
    foreach ($element in $tops) {
        $name = $element.Current.Name
        if ($name -and $name -like $script:MainTitleLike) { $found += $element }
    }

    if ($found.Count -eq 0) {
        throw ("no top-level window for pid $($swd.Id) has a title like " +
               "'$script:MainTitleLike'. $($tops.Count) window(s) seen. If a modal " +
               'dialog is open, dismiss it before selecting a board.')
    }
    if ($found.Count -gt 1) {
        # Never guess between two plausible main windows.
        throw "$($found.Count) windows match '$script:MainTitleLike' for pid $($swd.Id); refusing to guess."
    }
    return $found[0]
}


function Get-SwdWindowTitle {
    <#
    .SYNOPSIS
        Main-window caption read through WM_GETTEXT - the cross-mechanism oracle.
    .DESCRIPTION
        Process.MainWindowHandle IS NOT USED, for the reason Get-SwdUiaWindow sets out
        above: it returned three different values in one session during the 2026-08-31
        live run and once named a modal dialog captioned 'Starting HydroScan'. Reading
        that handle would have made the caption oracle - the thing that decides WHICH
        BOARD IS LOADED before a 12-minute scan - report a dialog's caption whenever the
        application was busiest, which is exactly when a batch driver is watching.

        The window is resolved the same way Get-SwdUiaWindow resolves it, one subsystem
        down: every top-level window of the SWD process, filtered by a caption matching
        the main-window pattern, refusing to guess between two. No UI Automation is
        involved on this path - that is the whole point of it being the cross-mechanism
        oracle for a UIA action.
        IT IS BOUNDED, because it is no longer one read. Resolving by title means a
        sweep, and every window costs TWO messages each carrying the full -TimeoutMs, so
        against a hung SWD the worst case is windows x 2 x TimeoutMs with nothing
        capping it - the same arithmetic Get-SwdControl grew -DeadlineMs for. Three
        things bound it: invisible windows are skipped (a hidden window is never the
        main one, and TopLevelForPid already reports visibility), the deadline is tested
        BEFORE each read rather than after, and both knobs are parameters so a caller
        polling on its own budget can reach them.

        A DEADLINE HIT RETURNS $null, not a partial answer. Stopping early means the
        sweep never proved there was exactly one matching window, and 'probably that
        one' is the guess this function refuses to make.
    .OUTPUTS
        System.String, or $null if no single main window answered within the deadline.
        $null means DID NOT ANSWER; an empty string would mean answered empty.
    #>
    [CmdletBinding()]
    param([int] $TimeoutMs = 2000, [int] $DeadlineMs = 6000)

    $swd = Get-SwdProcess
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $found = @()
    $ranOut = $false
    foreach ($line in [SwdWin]::TopLevelForPid($swd.Id)) {
        $f = $line -split ([regex]::Escape([SwdWin]::SEP))
        if ($f.Count -ne [SwdWin]::TOPLEVEL_FIELDS) {
            # Get-SwdDialog throws on this; here it must not. That function is called
            # before anything is actuated, this one from inside Select-SwdBoard's poll
            # loop AFTER Select() has acted, where a throw abandons the run with the
            # application changed and no result object. Skipping costs at worst a
            # $null answer, which is the safe direction.
            Write-Verbose "Malformed top-level record ($($f.Count) fields); skipped."
            continue
        }
        if (-not [bool]::Parse($f[2])) { continue }   # invisible: never the main window
        if ($DeadlineMs -gt 0 -and $watch.ElapsedMilliseconds -ge $DeadlineMs) {
            $ranOut = $true
            break
        }
        $text = Get-SwdText -Handle ([int64]$f[0]) -TimeoutMs $TimeoutMs
        if ($text -and $text -like $script:MainTitleLike) { $found += $text }
    }
    $watch.Stop()

    # NO PATH HERE THROWS, for the reason given at the malformed-record skip above.
    if ($ranOut) {
        Write-Verbose ("Get-SwdWindowTitle hit its $DeadlineMs ms deadline; the window " +
                       'list was not fully read, so no caption is claimed.')
        return $null
    }
    if ($found.Count -eq 1) { return $found[0] }
    if ($found.Count -gt 1) {
        Write-Verbose ("$($found.Count) top-level windows match '$script:MainTitleLike' " +
                       "for pid $($swd.Id); refusing to guess between them.")
    }
    return $null
}


function Get-SwdLoadedBoard {
    <#
    .SYNOPSIS
        Board name and length parsed out of the window caption.
    .DESCRIPTION
        Parses the '<Board: NAME(LENGTH.Xmm)>' segment. Returns nulls rather than
        guessing when the caption does not match - a caption that has changed shape is
        a reason to stop, not to pattern-match harder.

        THE LENGTH IS PARSED, NOT CAST. [\d.]+ admits '1.2.3', and [double]'1.2.3'
        THROWS - from inside Select-SwdBoard's poll loop, i.e. after Select() has
        already acted, abandoning the run with the application changed and no result
        object. ConvertTo-SwdNumber answers Ok=$false instead, which is what the
        docstring above has always promised. The character class also admits a comma so
        a French-rendered caption reaches the parser rather than failing the match
        outright; whether it then parses is the parser's answer to give.
    .OUTPUTS
        PSCustomObject with Board, LengthMm, Title, Parsed, ReadError. Parsed=$false
        with a non-null Title means the caption ANSWERED but did not carry a readable
        board segment; Title=$null means no main window answered at all. ReadError is
        $null here and is set only by Read-SwdLoadedBoard - the shape is shared so a
        caller can read either result without a StrictMode accident.

        -TimeoutMs and -DeadlineMs exist so a caller polling on its own budget can
        bound the underlying window sweep. Declaring this param() empty meant
        Select-SwdBoard -TimeoutMs could not reach it and every observation ran at the
        default no matter what the caller asked for.
    #>
    [CmdletBinding()]
    param([int] $TimeoutMs = 2000, [int] $DeadlineMs = 6000)

    $title = Get-SwdWindowTitle -TimeoutMs $TimeoutMs -DeadlineMs $DeadlineMs
    $board = $null; $length = $null
    $parsed = $false

    if ($title -and $title -match '<Board:\s*(?<name>.+?)\((?<len>[\d.,]+)\s*mm\)>') {
        $number = ConvertTo-SwdNumber -Text $Matches['len']
        if ($number.Ok) {
            $board = $Matches['name'].Trim()
            $length = $number.Value
            $parsed = $true
        }
    }
    return [pscustomobject]@{
        Board = $board; LengthMm = $length; Title = $title; Parsed = $parsed
        ReadError = $null
    }
}


function Read-SwdLoadedBoard {
    <#
    .SYNOPSIS
        Get-SwdLoadedBoard that reports failure in the result instead of throwing.
    .DESCRIPTION
        For the poll loop that runs AFTER SelectionItemPattern.Select() has acted.
        Get-SwdLoadedBoard reaches Get-SwdProcess, which throws when SWD is absent, when
        a second instance appears, or when the main window handle is zero - all three of
        which are live possibilities during a board load, and all three of which would
        otherwise abandon the caller with the application already changed and no result
        object. Select-SwdBoard's own documentation asserts that cannot happen; this is
        what makes that true.

        Twin of Read-SwdGeometryState in swd_geometry.ps1, same discipline, same reason.
        It returns the FULL shape with ReadError set rather than $null, because the
        poll loop reads .Parsed and .Board on whatever comes back.
    #>
    [CmdletBinding()]
    param([int] $TimeoutMs = 2000, [int] $DeadlineMs = 6000)
    try {
        return Get-SwdLoadedBoard -TimeoutMs $TimeoutMs -DeadlineMs $DeadlineMs
    } catch {
        Write-Verbose "board caption read failed: $($_.Exception.Message)"
        return [pscustomobject]@{
            Board = $null; LengthMm = $null; Title = $null; Parsed = $false
            ReadError = $_.Exception.Message
        }
    }
}


function Get-SwdBoardList {
    <#
    .SYNOPSIS
        Every TreeItem in SWD's library tree.
    .DESCRIPTION
        Returns the elements themselves, not just names, so a caller can select without
        a second lookup - the element is the handle, and re-finding by name between
        enumeration and selection is a race.
    .OUTPUTS
        PSCustomObject with Name, Element, Selectable, Expandable.
    #>
    [CmdletBinding()]
    param([System.Windows.Automation.AutomationElement] $Window)

    if (-not $Window) { $Window = Get-SwdUiaWindow }

    $isTreeItem = New-Object System.Windows.Automation.PropertyCondition(
        $script:UIA::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::TreeItem)
    $items = $Window.FindAll($script:TreeScope::Descendants, $isTreeItem)

    $out = @()
    foreach ($item in $items) {
        $selectable = $false
        $expandable = $false
        # GetCurrentPattern throws when a pattern is absent; TryGetCurrentPattern does
        # not. Absence is normal here (a folder node is expandable but not selectable),
        # so it must not be an exception path.
        $sink = $null
        if ($item.TryGetCurrentPattern(
                [System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$sink)) {
            $selectable = $true
        }
        if ($item.TryGetCurrentPattern(
                [System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$sink)) {
            $expandable = $true
        }
        $out += [pscustomobject]@{
            Name = $item.Current.Name; Element = $item
            Selectable = $selectable; Expandable = $expandable
        }
    }
    # Comma operator: an empty returned array unrolls to $null and .Count then
    # throws under StrictMode. An empty tree is a legitimate state, not an error.
    #
    # CALLERS: assign this to a variable before piping it. Piped directly, the
    # wrapper means $_ is the WHOLE array rather than each item.
    return ,$out
}


function Select-SwdBoard {
    <#
    .SYNOPSIS
        Select one board in the library tree and verify it actually loaded.
    .DESCRIPTION
        Calls SelectionItemPattern.Select(), then confirms through the window caption -
        a different subsystem from the one that acted.

        IT DOES NOT EXPAND ANYTHING. There is no ExpandCollapsePattern.Expand() call in
        this file, and the docstring here used to claim otherwise. A board sitting under
        a COLLAPSED folder is typically not in the UIA tree at all, so it comes back as
        'no tree item named X' - a message that misdirects unless it says so. Expanding
        would be a state-changing action on the application, which this file does not
        take on its own initiative; expand the folder in SWD, or call
        ExpandCollapsePattern on the Element that Get-SwdBoardList reports Expandable.

        Selection is reported as Selected only when the caption agrees. A pattern call
        that returns without throwing is NOT evidence the board loaded: the live run of
        2026-08-31 recorded 'Apply situation' returning Sent=True, Observed=handled,
        LastError=0 with every caption byte-identical either side. Transport was
        demonstrated; actuation was not.

        TWO THINGS Selected DOES NOT MEAN.

        It does not mean Select() worked. When the requested board was ALREADY loaded
        the caption agrees before anything is called, so the run says nothing about the
        pattern - AlreadyLoaded distinguishes the two, and a run meant to test Select()
        itself must start from a different board.

        It does not stay true. The result is point-in-time. SWD reloads the tree on its
        own during a scan: on 2026-08-31 scanning a write-protected original made SWD
        save and load a COPY, which came back with turn_radius_m 22.806 -> 100000 and
        the speed setting 10 -> 20 (CLAUDE.md section 9). Re-read the caption after any
        operation that could have triggered that branch; never carry this answer across
        one.
    .PARAMETER Name
        Exact board name as it appears in the tree. Matching is exact and
        case-insensitive; a substring match would conflate
        '2003_Taylor_Knox_channel_island' with its '_Copy_1'.
    .PARAMETER TimeoutMs
        How long to wait for the caption to show the requested board.
    .OUTPUTS
        PSCustomObject with Requested, Selected, AlreadyLoaded, TitleBoard, LengthMm,
        ElapsedMs, Reason.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Name,
        [int] $TimeoutMs = 15000,
        [int] $PollMs = 250
    )

    # Validate BEFORE anything acts. Without this, -PollMs -1 throws out of Start-Sleep
    # inside the poll loop - i.e. AFTER SelectionItemPattern.Select() has already acted -
    # abandoning the caller with SWD changed and no result object, which is exactly what
    # this function's docstring promises cannot happen. The identical guard was added to
    # Set-SwdGeometry in round 3 and not copied here; SQA round 3 W1.
    if ($TimeoutMs -lt 0) { throw "TimeoutMs must be 0 or more; got $TimeoutMs." }
    if ($PollMs -lt 1)    { throw "PollMs must be 1 or more; got $PollMs." }

    $window = Get-SwdUiaWindow
    $before = Get-SwdLoadedBoard
    # The whole reason to read the caption first: if the board is ALREADY resident, the
    # caption agrees whatever Select() does, so this run cannot answer whether the
    # pattern works. Reported rather than folded into Selected.
    $alreadyLoaded = ($before.Parsed -and $before.Board -eq $Name)

    # OrdinalIgnoreCase, because PowerShell's -eq on strings is CULTURE-sensitive:
    # measured, a name carrying U+00AD or U+200D compares EQUAL to the plain one, as
    # do NFC and NFD spellings of the same accented name. The docstring above
    # promises exact-and-case-insensitive matching; only ordinal delivers that, and
    # conflating two tree items is the '_Copy_1' hazard that promise exists for.
    # ASSIGN FIRST, THEN FILTER - do NOT pipe this call directly. Get-SwdBoardList and
    # Get-SwdMenuItem both end in `return ,$out`, which stops an EMPTY result unrolling
    # to $null; the cost is that a NON-empty result arrives at a pipeline as ONE object
    # that IS the array. Measured: `f | Measure-Object` counts 1 where the array holds 2,
    # and @(f).Count is 1. Assigning to a variable first gives the array, and piping the
    # VARIABLE enumerates its elements normally.
    #
    # Piped directly, $_ is the whole array, so $_.Name is an array of names - and
    # `array -eq 'x'` is a FILTER returning the matches, whose non-empty result is
    # truthy. That is why this read as working: every item passed as a single blob,
    # .Count came back 1, and the failure only surfaced downstream where a method is
    # called on what turns out to be Object[].
    $items = Get-SwdBoardList -Window $window
    $candidates = @($items | Where-Object {
        $_.Name -and [string]::Equals($_.Name, $Name, [StringComparison]::OrdinalIgnoreCase) })
    if ($candidates.Count -eq 0) {
        throw ("no tree item named '$Name'. Use Get-SwdBoardList to see what is present " +
               '- and note that a board under a COLLAPSED folder is usually not in the ' +
               'UIA tree at all, so absence here is not proof the board is absent from ' +
               'the library. This function never expands anything.')
    }
    if ($candidates.Count -gt 1) {
        throw "$($candidates.Count) tree items are named '$Name'; refusing to guess which."
    }
    $target = $candidates[0]
    if (-not $target.Selectable) {
        throw ("tree item '$Name' exposes no SelectionItemPattern, so it is a folder " +
               'or a disabled node rather than a selectable board. Refusing; this ' +
               'script never falls back to clicking a coordinate.')
    }

    if (-not $PSCmdlet.ShouldProcess("SWD board tree", "select '$Name'")) {
        # A rehearsal and a declined confirm both land here and are different events.
        return [pscustomobject]@{
            Requested = $Name; Selected = $false; AlreadyLoaded = $alreadyLoaded
            TitleBoard = $before.Board; LengthMm = $before.LengthMm; ElapsedMs = 0
            Reason = if ($WhatIfPreference) { 'whatif' } else { 'not-confirmed' }
        }
    }

    $sink = $null
    if (-not $target.Element.TryGetCurrentPattern(
            [System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$sink)) {
        throw "SelectionItemPattern vanished between enumeration and use for '$Name'."
    }
    $sink.Select()

    # Observe the load; never infer it. A board load is not instantaneous and the
    # caption is the only thing that proves which board is resident. Observe FIRST and
    # sleep after: an already-loaded board or an instant switch used to cost a full
    # PollMs before anything was even looked at.
    #
    # Read-SwdLoadedBoard, not Get-: past this line Select() HAS ACTED, so nothing may
    # throw its way out of here. One observation is also not allowed to outlast the
    # budget it is being polled within, hence the derived deadline rather than the
    # function's own default.
    $readDeadline = [math]::Max(1000, [math]::Min($TimeoutMs, 6000))
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $reason = 'timeout'
    $current = $before
    while ($true) {
        $current = Read-SwdLoadedBoard -DeadlineMs $readDeadline
        if ($current.Parsed -and
            [string]::Equals($current.Board, $Name, [StringComparison]::OrdinalIgnoreCase)) {
            $reason = 'ok'; break
        }
        if ($watch.ElapsedMilliseconds -ge $TimeoutMs) { break }
        Start-Sleep -Milliseconds $PollMs
    }
    $watch.Stop()

    # Three different failures, three different remedies: no main window answered at
    # all, a caption that answered but carries no readable board segment, and a caption
    # that reads a DIFFERENT board.
    if ($reason -ne 'ok') {
        if ($null -eq $current.Title)  { $reason = 'title-unreadable' }
        elseif (-not $current.Parsed)  { $reason = 'title-unparseable' }
    }

    return [pscustomobject]@{
        Requested     = $Name
        Selected      = ($reason -eq 'ok')
        # $true means the caption ALREADY named this board before Select() was called,
        # so Selected here is evidence about the end state and none at all about the
        # SelectionItemPattern.
        AlreadyLoaded = $alreadyLoaded
        TitleBoard    = $current.Board
        LengthMm      = $current.LengthMm
        ElapsedMs     = [int]$watch.ElapsedMilliseconds
        Reason        = $reason
    }
}


function Get-SwdMenuItem {
    <#
    .SYNOPSIS
        Menu items exposing InvokePattern, which HWND enumeration cannot see at all.
    .PARAMETER Like
        Wildcard filter over the item name. AN UNNAMED ITEM CANNOT MATCH A SPECIFIC
        PATTERN: the filter used to be skipped entirely when the name was empty, so
        every unnamed item survived whatever -Like said, and a capability probe such as
        -Like '*Save*' came back non-empty on a build with no Save item at all - the
        exact question this function exists to answer. '' -like '*' is $true, so the
        default still lists unnamed items; only a specific pattern excludes them.
    .OUTPUTS
        PSCustomObject with Name, Element, Invokable, Enabled.
    #>
    [CmdletBinding()]
    param(
        [string] $Like = '*',
        [System.Windows.Automation.AutomationElement] $Window
    )

    if (-not $Window) { $Window = Get-SwdUiaWindow }

    $isMenuItem = New-Object System.Windows.Automation.PropertyCondition(
        $script:UIA::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::MenuItem)
    $items = $Window.FindAll($script:TreeScope::Descendants, $isMenuItem)

    $out = @()
    foreach ($item in $items) {
        $name = $item.Current.Name
        if ($name -notlike $Like) { continue }
        $sink = $null
        $invokable = $item.TryGetCurrentPattern(
            [System.Windows.Automation.InvokePattern]::Pattern, [ref]$sink)
        $out += [pscustomobject]@{
            Name = $name; Element = $item
            Invokable = $invokable; Enabled = $item.Current.IsEnabled
        }
    }
    # Same wrapper, same caller rule as Get-SwdBoardList: assign before piping.
    return ,$out
}


function Invoke-SwdMenuItem {
    <#
    .SYNOPSIS
        Invoke one menu item by exact name, from a caller-supplied allowlist.
    .DESCRIPTION
        THE GATE IS -Allow, AND IT IS EMPTY BY DEFAULT. Nothing is invocable until the
        caller names it. There is no denylist and no built-in opinion about which items
        are safe: this file cannot see SWD's menu at authoring time, so any list of
        'dangerous' names would be a guess that fails open on everything it failed to
        think of - and the File menu contains Save, which writes into the EUR 210
        machine-bound, cloud-synced library.

        ConfirmImpact IS NOT THE GATE, and used to be treated as one. Measured:
        -Confirm:$false proceeds, $ConfirmPreference='None' proceeds, and a bare call
        under -NonInteractive throws - so the unattended batch driver this file exists
        to serve had to remove the only control there was in order to run at all. It is
        kept as a second, interactive-only speed bump; -Allow is what actually decides.

        Refuses on an unlisted name, an ambiguous name, a disabled item, or a missing
        InvokePattern.

        This function CANNOT confirm the effect of what it invoked - a Save As opens a
        modal dialog that must then be driven by swd_msg.ps1's dialog helpers. It
        therefore reports Invoked (the call returned) and never 'Saved'.
    .PARAMETER Name
        Exact item name, matched ORDINALLY and case-insensitively.
    .PARAMETER Allow
        The names this call is permitted to invoke. Exact strings, NOT wildcards - a
        pattern here would let '*' switch the gate off, which is the whole thing being
        prevented. Anything not listed is refused.

        'EXACT' MEANS ORDINAL, AND IT DID NOT BEFORE. PowerShell's -eq and -contains
        compare strings by CULTURE, under which zero-weight characters vanish: measured,
        "Sa<U+00AD>ve" -eq 'Save' is True, so is the U+200D form, and so is NFD
        against NFC. Both halves of this function used -eq, so a caller could allowlist
        a soft-hyphenated string, have it accepted, and then watch the selector match
        the REAL Save item by the same loose rule. Gate and selector are now both
        ordinal, so the item invoked is ordinally the string that was allowed.

        Positional binding is off. -Allow is an explicit opt-in to writing into the
        library and must be typed as one; a second positional argument silently becoming
        that opt-in is not the shape a gate should have.
        THERE IS NO -Force. It existed for one round and was deleted: see the comment at
        the disabled-item check below. Note that Invoke-SwdButton's -Force is a genuine
        override - BM_CLICK reaches the window procedure with no framework in between -
        so do not carry that intuition across to this function.
    .EXAMPLE
        Invoke-SwdMenuItem -Name 'Save As...' -Allow 'Save As...' -Confirm:$false
    .OUTPUTS
        PSCustomObject with Name, Invoked, Reason.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', PositionalBinding = $false)]
    param(
        [Parameter(Mandatory)][string] $Name,
        [string[]] $Allow = @()
    )

    # Default-deny, before anything is enumerated or touched. Ordinal, not -notcontains:
    # see the -Allow help above for what culture-sensitive comparison lets through.
    $permitted = @(@($Allow) | Where-Object {
        $null -ne $_ -and [string]::Equals($_, $Name, [StringComparison]::OrdinalIgnoreCase) })
    if ($permitted.Count -eq 0) {
        throw ("menu item '$Name' is not in the caller's allowlist, so it will not be " +
               "invoked. Pass it explicitly: -Allow '$Name' (exact names, not " +
               'wildcards; -Allow is empty by default and every item is refused until ' +
               'named). Get-SwdMenuItem lists what is present without invoking anything.')
    }

    # Assign first, then filter - see the note in Select-SwdBoard for what piping a
    # `return ,$out` function directly does to $_.
    $items = Get-SwdMenuItem
    $candidates = @($items | Where-Object {
        [string]::Equals($_.Name, $Name, [StringComparison]::OrdinalIgnoreCase) })
    if ($candidates.Count -eq 0) {
        throw "no menu item named '$Name'. Use Get-SwdMenuItem to list them."
    }
    if ($candidates.Count -gt 1) {
        throw "$($candidates.Count) menu items are named '$Name'; refusing to guess."
    }
    $item = $candidates[0]

    if (-not $item.Invokable) {
        throw "menu item '$Name' exposes no InvokePattern; refusing."
    }
    # No -Force override, deliberately, and it was DELETED rather than documented.
    # InvokePattern.Invoke() is specified to raise ElementNotEnabledException on a
    # disabled element, so the switch could only ever turn a clean refusal into an
    # exception - on the one path in this repository that reaches Save. An escape hatch
    # with no demonstrated capability is a hatch that gets reached for anyway; CLAUDE.md
    # section 4 records that pattern by name. Re-add it with evidence if one appears.
    if (-not $item.Enabled) {
        throw ("menu item '$Name' is disabled. SWD disabled it for a reason, and this " +
               'function offers no override.')
    }

    if (-not $PSCmdlet.ShouldProcess("SWD menu", "invoke '$Name'")) {
        # A rehearsal and an operator declining the confirm are different events, and on
        # the one path that can reach Save the difference is worth a word.
        return [pscustomobject]@{
            Name = $Name; Invoked = $false
            Reason = if ($WhatIfPreference) { 'whatif' } else { 'not-confirmed' }
        }
    }

    # Re-identify the ELEMENT, not merely re-fetch the pattern. A stale reference that
    # still answers TryGetCurrentPattern proves the pattern is there, never that it is
    # still attached to the item that was allowlisted - and the menu is rebuilt often
    # enough that the two questions are different ones. Reading .Current.Name here also
    # throws on a dead element, which is a loud failure BEFORE anything is invoked.
    $liveName = $item.Element.Current.Name
    if (-not [string]::Equals($liveName, $Name, [StringComparison]::OrdinalIgnoreCase)) {
        throw ("menu item '$Name' changed identity between enumeration and use " +
               "(it now reads '$liveName'); refusing to invoke it.")
    }

    $sink = $null
    if (-not $item.Element.TryGetCurrentPattern(
            [System.Windows.Automation.InvokePattern]::Pattern, [ref]$sink)) {
        throw "InvokePattern vanished between enumeration and use for '$Name'."
    }
    $sink.Invoke()
    return [pscustomobject]@{ Name = $Name; Invoked = $true; Reason = 'invoked' }
}
