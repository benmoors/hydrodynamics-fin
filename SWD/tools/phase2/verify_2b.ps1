<#
.SYNOPSIS
    TODO items 2b.5 and 2b.6 - does SelectionItemPattern.Select() actually load a
    board, and is Save As reachable via InvokePattern.

.DESCRIPTION
    swd_board.ps1 and swd_geometry.ps1 have 86 Pester tests and three SQA rounds
    behind them. Every one of those verdicts is about the INSTRUMENT. Neither file
    has ever run against a live SWD, and tests/swd_board.Tests.ps1:457-459 names
    both questions above as structurally out of reach offline.

    THIS SCRIPT ADDS NO CAPABILITY. It calls only functions that already passed
    SQA, in a fixed order, recording what each returned. The single state-changing
    call in the whole file is Select-SwdBoard. Nothing is invoked from the File
    menu: section C reads Invokable and Enabled off the elements and stops there,
    which is the user's explicit decision of 2026-09-02 and the reason this script
    cannot write into the EUR 210 machine-bound library at all.

    WHAT "SELECTED" IS AND IS NOT. Select-SwdBoard acts through UIA and confirms
    through WM_GETTEXT on the window caption - a different subsystem, so a stale
    element cannot certify itself. But a board that is ALREADY resident agrees with
    the caption before Select() is called, so such a run says nothing about the
    pattern. Section E therefore picks a board that section A proved is NOT loaded,
    and V2 fails if AlreadyLoaded comes back true.

    EVERY SECTION IS INDEPENDENTLY FALLIBLE. A section that throws is caught,
    recorded as NOT CHECKED, and the run continues to the summary. It never falls
    through to the conclusion it would have printed had it succeeded. Five gates
    are different and HALT the run, because everything downstream of each is
    meaningless: an EMPTY canonical list (nothing to diff or sweep against), a
    tree census short of that list, an unexpected top-level window, three
    consecutive failed selections, and SWD exiting mid-sweep.

    A SECTION MAY NOT REPORT A VERDICT IT DID NOT MEASURE. B says 'ok' only when a
    canonical list was actually read and diffed; D says 'every name resolves' only
    when every canonical name was actually rehearsed. Measured 2026-09-02, before
    the gates existed: a missing -BoardsCsv produced 'B ok' and 'D ok - every name
    resolves' over zero rehearsals, and the run ended 'F 0 of 0' with no HALT.

.NOTES
    Windows PowerShell 5.1 (Desktop) only - UIAutomationClient is .NET Framework.

    RUN IT ELEVATED, from a VISIBLE console. SWD's manifest asks for
    highestAvailable, so on an admin account it runs at High integrity and UIPI
    refuses state-changing input from a Medium-integrity client - measured, with
    lastError=5 (RESUME.md:103-113). Section A reports both integrity levels rather
    than assuming. A visible console matters separately: an invisible confirmation
    prompt in a background shell has already hung a process past taskkill
    (LIVE-RUN-FINDINGS.md:173-182).

    Test-SwdOwnsForeground is never called from here - that is the function which
    raised that prompt.

.PARAMETER LogDir
    Where run artefacts go. Validated through Resolve-SwdWritableTarget, so it
    refuses to resolve inside the SWD install or the SWD library (CLAUDE.md s4).

    IT ALSO REFUSES ANY OTHER LOCATION INSIDE THIS GIT WORKING TREE. The default
    phase2\logs is the one in-repository destination permitted, and it is the only
    one .gitignore covers: measured 2026-09-02, git check-ignore returns NO MATCH
    for a *-2b-boards.csv / -menu.csv / -hashes.csv written under any other folder
    below phase2\, and outside phase2\ even the .log is tracked. Those artefacts
    carry the library path - operator username and OneDrive tenant - plus board
    and menu captions. .gitignore:52-54 says in terms that its phase2 rules are
    path-literal and cover the default location only. Repo rule R9.

.PARAMETER BoardsCsv
    The canonical board list the tree census is diffed against. Its row order is
    the library tree order. Read only.

.PARAMETER LibraryRoot
    Where the .fynbs library lives, overriding the Documents lookup. READ ONLY -
    section A hashes it before any selection and section G re-hashes it after, and
    nothing here ever opens a .fynbs as an object, so the provenance gate is not
    involved.

    It exists for two reasons. A relocated or OneDrive-detached library was
    otherwise unreachable. And the offline suite had no way to avoid the real one:
    measured, every driver invocation SHA-256s the whole library twice, which came
    to ~3.72 GB of reads across one suite run with no assertion reading the result
    - on a Files-On-Demand tree that is potentially network transfer, not disk.

.PARAMETER CensusOnly
    Sections A-D only. Nothing is ever selected, so the run changes no application
    state whatsoever. Use it for a first look before committing to the sweep.

.PARAMETER SkipGeometry
    Drop the Configuration-panel read from section F. The sweep still runs; it just
    records selection results and not geometry.

.PARAMETER MaxBoards
    Cap the section F sweep. 0 means every board the census found.

.PARAMETER DotSourceOnly
    Define the helpers and return without running a section. This exists for the
    Pester suite: it is what lets the parsing, diffing, encoding and dialog-filter
    logic be tested with SWD closed.
#>
param(
    [string]$LogDir,
    [string]$BoardsCsv,
    [string]$LibraryRoot,
    [switch]$CensusOnly,
    [switch]$SkipGeometry,
    [int]$MaxBoards = 0,
    [switch]$DotSourceOnly
)

# Declared rather than inherited. swd_board.ps1 sets it too, and dot-sourcing puts
# that in this scope - so the body has always run strict - but that made this file's
# behaviour depend on a line in a sibling nobody may edit here. Measured: with
# StrictMode Latest, (Import-Csv x).board on a CSV with no 'board' column THROWS,
# which is what turns two of the three empty-canonical cases into a caught error
# rather than a silent @(). The third (-BoardsCsv absent) is gated in section B.
Set-StrictMode -Version Latest

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Windows PowerShell 5.1 required (UIAutomationClient is .NET Framework only).'
}
if ($MaxBoards -lt 0) { throw "MaxBoards must be 0 or more; got $MaxBoards." }

# $PSScriptRoot is empty inside a param() default on 5.1 - resolved after the block
# instead, the same trap swd_diagnose.ps1 records.
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

. (Join-Path $ScriptDir 'swd_board.ps1')
. (Join-Path $ScriptDir 'swd_geometry.ps1')

$DefaultLogDir = Join-Path $ScriptDir 'logs'
if (-not $LogDir)    { $LogDir    = $DefaultLogDir }
if (-not $BoardsCsv) { $BoardsCsv = Join-Path $ScriptDir '..\..\data\boards.csv' }

# Ordinal, and both sides trimmed, because every path comparison in this project
# that used PowerShell's -eq turned out to be invariant-culture linguistic. A
# directory separator is appended before the prefix test so 'C:\repo-backup' is
# not read as being inside 'C:\repo'.
function Test-PathAtOrUnder {
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Path,
          [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Root)
    if (-not $Path -or -not $Root) { return $false }
    $p = $Path.TrimEnd('\', '/')
    $r = $Root.TrimEnd('\', '/')
    if (-not $r) { return $false }
    if ([string]::Equals($p, $r, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $p.StartsWith($r + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

# The nearest ancestor holding a .git entry, or $null. A worktree or submodule
# checkout has a .git FILE rather than a directory, so this tests for either.
function Get-RepositoryRoot {
    param([Parameter(Mandatory)][string]$From)
    $cur = $From
    while ($cur) {
        if (Test-Path -LiteralPath (Join-Path $cur '.git')) { return $cur }
        $parent = Split-Path -Parent $cur
        if (-not $parent -or [string]::Equals($parent, $cur, [StringComparison]::OrdinalIgnoreCase)) { return $null }
        $cur = $parent
    }
    return $null
}

# THE RESOLVED PATH IS WHAT GETS WRITTEN. Validating the raw string and then
# writing to a different resolution of it is the hole this ordering closes.
$rawLog = $LogDir
$LogDir = Resolve-SwdWritableTarget -Path $rawLog
if (-not $LogDir) {
    throw "Refusing to run: '$rawLog' is not a permitted output directory (CLAUDE.md section 4)."
}

# A SECOND REFUSAL, FOR A DIFFERENT REASON. Resolve-SwdWritableTarget protects the
# SWD install and library; this protects the repository. Three of the four
# artefacts are CSVs that no .gitignore rule reaches outside phase2\logs\, and the
# log itself is only covered while it stays under phase2\ - measured with
# git check-ignore on 2026-09-02. They carry the library path (username, OneDrive
# tenant) and third-party board and menu captions. Repo rule R9.
#
# Canonicalised on both sides through the same resolver the writer used, so an 8.3
# spelling or a junction cannot walk back into the tree - the exact defeat this
# project has already measured twice against a lexical-only test.
# WALKED UP FROM THE DESTINATION, NOT FROM $ScriptDir. Asking "is -LogDir inside
# MY repository" closes exactly one repository. Measured 2026-09-02 against the
# earlier version of this block: a -LogDir inside a DIFFERENT working tree on this
# machine - there is more than one - came back ALLOWED, its .git was real, and git
# check-ignore returned no match for a *-2b-boards.csv written there, so all four
# artefacts landed TRACKED while the in-repo positive controls were correctly
# refused. Containment is a property of where the file goes, so it is asked of
# where the file goes.
$destRepo = Get-RepositoryRoot -From $LogDir
if ($destRepo) {
    $canonRepo = Resolve-SwdCanonicalTarget -Path $destRepo
    if (-not $canonRepo) { $canonRepo = $destRepo }
    $canonDefault = Resolve-SwdCanonicalTarget -Path $DefaultLogDir
    if (-not $canonDefault) { $canonDefault = [IO.Path]::GetFullPath($DefaultLogDir) }
    if (-not (Test-PathAtOrUnder -Path $LogDir -Root $canonDefault)) {
        throw ("Refusing to run: '$rawLog' resolves to '$LogDir', inside the git working " +
               "tree at '$canonRepo'. The artefacts carry the library path (operator " +
               'username and OneDrive tenant) and third-party board and menu captions, and ' +
               'no .gitignore rule covers them outside the default location. Use the ' +
               "default -LogDir ('$canonDefault') or a directory in no repository at all.")
    }
}

# NOT under -DotSourceOnly: that switch exists so the Pester suite can define the
# helpers, and defining them must not leave a directory behind.
if (-not $DotSourceOnly -and -not (Test-Path -LiteralPath $LogDir)) {
    [void][IO.Directory]::CreateDirectory($LogDir)
}

# MILLISECONDS. The stamp is the only thing separating two runs' artefacts, and
# at whole-second resolution two runs in the same second APPEND to one log and
# OVERWRITE each other's CSVs - silently, since the log is append-only by design.
# The offline suite hit exactly this and had to give every run its own directory.
$stamp    = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$logPath  = Join-Path $LogDir "$stamp-2b-verify.log"
$rowsPath = Join-Path $LogDir "$stamp-2b-boards.csv"
$menuPath = Join-Path $LogDir "$stamp-2b-menu.csv"
$hashPath = Join-Path $LogDir "$stamp-2b-hashes.csv"

# UTF-8 WITHOUT A BOM, on every artefact. Tee-Object and Out-File both write
# UTF-16LE-with-BOM under 5.1, and a BOM breaks the Python readers downstream
# (CLAUDE.md section 5). swd_diagnose.ps1 measured this the hard way.
$script:NoBom = New-Object Text.UTF8Encoding($false)

# APPENDED, not buffered to the end. This run can HALT mid-sweep by design, and a
# log that only exists if the script reaches its last line is exactly the artefact
# you do not have when you need it.
function Write-Line {
    param([string]$Text = '')
    $Text | Out-Host
    [IO.File]::AppendAllText($logPath, $Text + [Environment]::NewLine, $script:NoBom)
}
function Write-Section {
    param([string]$Title)
    Write-Line ''
    Write-Line ('=' * 72)
    Write-Line $Title
    Write-Line ('=' * 72)
}

# Board names and menu captions come from a third-party application, so they are
# escaped at the log boundary rather than trusted to be one printable line - a
# caption whose second physical line starts at column 0 is indistinguishable from
# a line this script emitted (swd_msg.ps1 SQA W17, measured).
function Show-Target {
    param([AllowNull()]$Text, [int]$MaxLength = 120)
    return (ConvertTo-SwdSafeText $Text $MaxLength)
}

function Save-Text {
    param([string]$Path, [string[]]$Content)
    [IO.File]::WriteAllLines($Path, $Content, $script:NoBom)
}
# -TextColumns names the columns whose content comes from SWD rather than from
# this script, and they are the only ones neutralised against CSV formula
# injection. Excel and LibreOffice evaluate a cell beginning = + - @ or a leading
# control character, and QUOTING IS NOT NEUTRALISATION - measured 2026-09-02,
# ConvertTo-Csv round-trips all thirteen hostile values correctly and still writes
# "=cmd|calc" as the first thing Excel sees. ConvertTo-SwdCsvCell is the
# project's existing mutation for this and swd_diagnose.ps1:398-403 already
# applies it to the identical data class; it is reused rather than reinvented.
#
# The numeric and boolean columns are deliberately NOT in that list, for the
# reason swd_diagnose records: they are built by this project, and neutralising
# them would put an apostrophe in front of every negative number.
#
# The mutation is counted and returned so the caller can report it rather than
# change data silently. A downstream Python reader strips ONE leading apostrophe.
#
# KNOWN RESIDUAL, measured 2026-09-02 and NOT fixed here. ConvertTo-SwdCsvCell
# tests only $s[0], so a hostile lead behind a SPACE survives: ' =1+1' comes back
# unprefixed while '=1+1', '+1', '-1', '@x', a leading TAB and a leading
# apostrophe are all neutralised. The fix belongs to that helper's leading set in
# swd_msg.ps1, which is frozen for this pass - and writing a second, divergent
# neutraliser here would be worse than the gap, because the two would drift.
# Recorded so the next pass on that file has the case.
function Save-Csv {
    param([string]$Path, $Rows, [string[]]$Columns, [string[]]$TextColumns = @())
    $injected = 0
    if (-not $Rows -or @($Rows).Count -eq 0) {
        # The same shape as a file with rows, minus the rows. A header quoted in
        # one case and bare in the other is one file family with two formats.
        Save-Text -Path $Path -Content @(@($Columns | ForEach-Object { '"' + $_ + '"' }) -join ',')
        return 0
    }
    $safe = foreach ($r in @($Rows)) {
        $cells = [ordered]@{}
        foreach ($c in $Columns) {
            # Select-Object yielded $null for an absent property and StrictMode makes
            # a direct read throw for one, so absence is answered here instead. Read
            # through PSObject.Properties rather than $r.$c: InjectionHunter flags
            # dynamic member access, and this file is held at zero findings.
            $prop = $r.PSObject.Properties[$c]
            $v = if ($prop) { $prop.Value } else { $null }
            if ($TextColumns -contains $c) {
                $n = ConvertTo-SwdCsvCell $v
                if ($n -ne $v) { $injected++ }
                $v = $n
            }
            $cells[$c] = $v
        }
        [pscustomobject]$cells
    }
    Save-Text -Path $Path -Content (@($safe) | ConvertTo-Csv -NoTypeInformation)
    return $injected
}

# The library is read for hashing only. Never written, never deserialised - the
# provenance gate is not involved because nothing here opens a .fynbs as an object.
function Get-BoardLibraryPath {
    # -LibraryRoot first, so the Documents lookup is an inference of last resort
    # rather than the only answer. $null when the given root does not exist, which
    # is the same "V5 cannot be answered" branch a missing library already takes -
    # NOT a throw, because an unreadable library must not cost the whole run.
    if ($LibraryRoot) {
        if (Test-Path -LiteralPath $LibraryRoot) { return $LibraryRoot }
        return $null
    }
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $p = Join-Path $docs 'ShaperWaveDynamics documents\biblio\Boards'
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}
# NOT Get-FileHash, and this was measured rather than preferred. That cmdlet lives
# in Microsoft.PowerShell.Utility, and a powershell.exe started from a pwsh 7
# environment inherits pwsh's PSModulePath - under which 5.1 resolves the WindowsApps
# copy of that module and Get-FileHash is simply absent. Verified both ways here on
# 2026-09-02: absent with the inherited path, present once PSModulePath is reset to
# the 5.1 pair. The .NET provider cannot be shadowed that way, so the evidence for
# "did selecting a board write to the library?" does not depend on which shell
# launched the run.
function Get-BoardHash {
    param([Parameter(Mandatory)][string]$Root)
    $out = @()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($f in Get-ChildItem -LiteralPath $Root -Filter '*.fynbs' -Recurse -File) {
            # ONE UNREADABLE FILE MUST NOT KILL THE RUN. This is called from section A,
            # before anything has been measured, over a 627 MB cloud-synced library
            # with SWD holding it open. An IO exception here used to escape into
            # section A's catch, halt the whole supervised session at preflight, and
            # answer none of 2b.5 or 2b.6. Sha256 = $null means NOT READ, which
            # section G reports separately from 'changed'.
            $digest = $null
            $err = $null
            try {
                $stream = [IO.File]::OpenRead($f.FullName)
                try {
                    $digest = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '')
                } finally {
                    $stream.Dispose()
                }
            } catch {
                $err = $_.Exception.Message
            }
            $out += [pscustomobject]@{
                Rel    = $f.FullName.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
                Bytes  = $f.Length
                Sha256 = $digest
                ReadError = $err
            }
        }
    } finally {
        $sha.Dispose()
    }
    return ,$out
}

# THE CLASS CLAIM THIS USED TO REST ON IS NOT SUPPORTED BY ITS OWN SOURCE, and
# the first correction of it over-counted in the other direction.
# SCAN-FLOW.md s1 lists THREE dialogs IN TOTAL, not four: the protected-board
# gate, the load-the-copy confirmation, and the duration confirmation - and the
# third of those is recorded as "Not yet captured ... has never been read from
# the live control", with its wording flagged as a paraphrase. So the class is
# confirmed for TWO observed dialogs and asserted for none beyond them. A modal
# of any other class read as clear, and 28 further selections then proceeded
# against a possibly blocked pump.
#
# So the gate no longer rests on the class alone. -KnownHandle is the set of
# visible top-level windows section A saw BEFORE anything was selected; anything
# visible that is not in it is unexpected whatever its class, which needs no claim
# about classes at all. #32770 stays as a second, independent rule so a modal that
# somehow was open at preflight is still named as one.
#
# It still looks for a class rather than calling Wait-SwdDialog with no -TitleLike:
# that form returns the MAIN window on its first poll (LIVE-RUN-FINDINGS.md:98-122).
#
# -Record is the offline seam. It is a separate MANDATORY parameter set, so it can
# never be reached by accident or default to empty - a gate that silently reads
# "clear" from an unset parameter is the failure this whole function exists to
# prevent. The driver body only ever calls the -ProcessId set.
function Get-UnexpectedDialog {
    [CmdletBinding(DefaultParameterSetName = 'Pid')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Pid')][int]$ProcessId,
        [Parameter(Mandatory, ParameterSetName = 'Record')][AllowEmptyCollection()][string[]]$Record,
        [AllowNull()][hashtable]$KnownHandle
    )
    if ($PSCmdlet.ParameterSetName -eq 'Pid') { $Record = [SwdWin]::TopLevelForPid($ProcessId) }
    $out = @()
    foreach ($line in $Record) {
        $f = $line -split ([regex]::Escape([SwdWin]::SEP))
        if ($f.Count -ne [SwdWin]::TOPLEVEL_FIELDS) {
            # A record this function cannot parse is not evidence of no dialog.
            # Get-SwdDialog throws on one; this runs after Select() has acted, where
            # a throw abandons the run with SWD changed, so it is REPORTED as
            # unreadable - which halts the sweep - rather than skipped.
            $out += [pscustomobject]@{ Handle = -1; Class = '<malformed>'; Owner = -1; Why = 'unreadable' }
            continue
        }
        if (-not [bool]::Parse($f[2])) { continue }
        # Linguistic -eq is deliberate and is the SAFE direction here: it treats a
        # class name carrying an ignorable character as equal to '#32770', so such a
        # window is reported rather than skipped. Ordinal would fail open.
        $isDialog = ($f[1] -eq '#32770')
        $handle   = [int64]$f[0]
        $isNew    = ($null -ne $KnownHandle -and -not $KnownHandle.ContainsKey($handle))
        if (-not ($isDialog -or $isNew)) { continue }
        $out += [pscustomobject]@{
            Handle = $handle; Class = $f[1]; Owner = [int64]$f[3]
            Why    = if ($isDialog) { 'dialog-class' } else { 'new-window' }
        }
    }
    return ,$out
}

# EVERYTHING ABOVE IS DEFINITION; EVERYTHING BELOW ACTS. -DotSourceOnly stops
# here so the Pester suite can exercise the helpers without a live SWD and
# without running a single section. A script that can only be tested by running
# it end to end against the application is a script with no offline tests, which
# is how the two files this one verifies ended up needing a live run in the first
# place.
if ($DotSourceOnly) { return }

$verdict  = [ordered]@{}
$notes    = New-Object Collections.Generic.List[string]
$halted   = $false
$haltWhy  = $null
# The visible top-level windows of the SWD process as they stood BEFORE anything was
# selected. The sweep's gate diffs against this, so it does not need to know what
# class a modal will be - see Get-UnexpectedDialog.
$knownWindows = $null

Write-Line "verify_2b.ps1  -  live verification of TODO 2b.5 / 2b.6"
Write-Line "started        : $(Get-Date -Format o)"
Write-Line "host           : $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition)"
Write-Line "log            : $logPath"
Write-Line "mode           : $(if ($CensusOnly) { 'CENSUS ONLY - nothing will be selected' } else { 'full - sections E and F select boards' })"

# ---------------------------------------------------------------- A  preflight
Write-Section 'A. Preflight - process identity, integrity, resident board'
$swd = $null; $before = $null; $hashesBefore = @(); $libRoot = $null
# THE ANTI-COLLISION PRECONDITION, held in one variable because three separate
# places depend on it and none of them used to say so.
#
# Get-SwdWindowTitle returns $null for THREE distinct did-not-answer states
# (swd_board.ps1:247-257): the deadline was hit, no top-level window matched the
# main-window pattern, or two or more did and it refuses to guess between them.
# All three arrive here as Parsed=$false, and $false is also what an ordinary
# read gives for "a different board is loaded". UNOBSERVED IS NOT DIFFERENT.
#
# Measured 2026-09-02 before this existed: with the caption unread, section A
# printed 'ok' under its own '<caption did not parse>' line, the reorder below
# was silently skipped so the resident board could sit at $order[0], and the run
# headline read '2b.5 CONFIRMED - Select() loaded a board that was not resident'
# with nothing in the 'does NOT establish' block. That is the exact failure
# .DESCRIPTION forbids, on the one question this script exists to answer.
$residentKnown = $false
try {
    $swd = Get-SwdProcess
    Write-Line "pid            : $($swd.Id)"
    Write-Line "started        : $($swd.StartTime.ToString('o'))"

    $mine  = [SwdWin]::IntegritySid([Diagnostics.Process]::GetCurrentProcess().Id)
    $theirs = [SwdWin]::IntegritySid($swd.Id)
    Write-Line "integrity us   : $(if ($mine)   { $mine }   else { 'unreadable' })"
    Write-Line "integrity SWD  : $(if ($theirs) { $theirs } else { 'unreadable - SWD sits HIGHER than this shell' })"
    if (-not $theirs) {
        $notes.Add('SWD integrity unreadable from here, which IS the answer: it is higher than this shell. UIPI will refuse Select(). Re-run elevated.')
    } elseif ($mine -and $theirs -and $mine -ne $theirs) {
        $notes.Add("Integrity mismatch (us $mine, SWD $theirs). UIPI may refuse Select().")
    }

    $title = Get-SwdWindowTitle
    Write-Line "caption        : $(if ($null -eq $title) { '<did not answer>' } else { Show-Target $title 200 })"
    $before = Get-SwdLoadedBoard
    # PARSED IS NOT THE SAME AS IDENTIFIED, and treating it as such is the round-2
    # Critical one branch over. Get-SwdLoadedBoard's regex (swd_board.ps1:296) is
    # '<Board:\s*(?<name>.+?)\(...' followed by .Trim(), so a caption reading
    # '<Board:   (1800.0mm)>' matches, sets Parsed = $true, and hands back Board = ''.
    # Keyed on Parsed alone, that state reports the board as KNOWN: the anti-collision
    # reorder below becomes a no-op, $wasResident is always $false, and section E can
    # print '2b.5 CONFIRMED' having never learnt which board was loaded - the exact
    # false positive this file exists to prevent.
    #
    # The added term can only ever turn a claimed answer into INCONCLUSIVE, never the
    # reverse, so it is safe in the one direction that matters here.
    $residentKnown = [bool]$before.Parsed -and
        -not [string]::IsNullOrWhiteSpace($before.Board)
    Write-Line "resident board : $(if ($residentKnown) { "$(Show-Target $before.Board)  ($($before.LengthMm) mm)" } else { '<caption did not parse> - 2b.5 CANNOT be answered this run' })"

    # An EMPTY -KnownHandle makes every visible top-level window 'new', which is how
    # the baseline is taken: one enumeration answers both "is a modal already up?"
    # and "what does normal look like for this session?".
    $baselineWindows = Get-UnexpectedDialog -ProcessId $swd.Id -KnownHandle @{}
    $knownWindows = @{}
    foreach ($w in $baselineWindows) { $knownWindows[$w.Handle] = $w.Class }
    Write-Line "top-level      : $($baselineWindows.Count) visible window(s) - $((@($baselineWindows | ForEach-Object { Show-Target $_.Class 40 }) | Sort-Object -Unique) -join ' | ')"

    # Two different faults, two different remedies: a modal is dismissed by hand,
    # an unreadable record means the enumeration itself is not to be trusted and
    # there is nothing on screen to dismiss. Both halt; saying "dialog ... handles:
    # -1" for the second sends the operator looking for a window that is not there.
    $preDialog = @($baselineWindows | Where-Object { $_.Why -eq 'dialog-class' })
    $preBad    = @($baselineWindows | Where-Object { $_.Why -eq 'unreadable' })
    if ($preDialog.Count -gt 0 -or $preBad.Count -gt 0) {
        $halted = $true
        $haltWhy = if ($preDialog.Count -gt 0) {
            "$($preDialog.Count) modal dialog(s) already open before the run started (handles: $(($preDialog | ForEach-Object { $_.Handle }) -join ', ')). Dismiss them by hand and re-run."
        } else {
            "$($preBad.Count) top-level window record(s) could not be parsed, so the question 'is a modal open?' was not answered. Nothing is on screen to dismiss; re-run, and if it persists the enumeration is at fault."
        }
        Write-Line "DIALOG         : $haltWhy"
    } else {
        Write-Line 'dialogs open   : none'
    }

    $libRoot = Get-BoardLibraryPath
    if ($libRoot) {
        $hashesBefore = Get-BoardHash -Root $libRoot
        Write-Line "library        : $(Show-Target $libRoot 200)$(if ($LibraryRoot) { '  (from -LibraryRoot)' } else { '  (from Documents)' })"
        Write-Line "hashed         : $($hashesBefore.Count) .fynbs (baseline AFTER launch, BEFORE any selection)"
    } else {
        $notes.Add('Board library not found; V5 (does selection write to disk?) cannot be answered.')
        Write-Line 'library        : NOT FOUND - V5 will read NOT CHECKED'
    }
    # NOT an unconditional 'ok'. A preflight that could not read the resident
    # board did most of its job and failed the one part section E depends on.
    $verdict['A'] = if ($residentKnown) { 'ok' }
                    else { 'ok EXCEPT the resident board was NOT read - see E' }
    if (-not $residentKnown) {
        $notes.Add('The window caption did not yield a resident board. Get-SwdWindowTitle returns $null for a deadline hit, for no matching window and for two or more matching - so this is UNOBSERVED, not "no board". Section E is reported INCONCLUSIVE on that account alone.')
    }
} catch {
    $verdict['A'] = "NOT CHECKED - $(Show-Target $_.Exception.Message 300)"
    Write-Line "A FAILED       : $(Show-Target $_.Exception.Message 300)"
    $halted = $true
    $haltWhy = 'preflight failed; nothing downstream is meaningful'
}

# --------------------------------------------------------------- B  tree census
Write-Section 'B. Tree census - every TreeItem UIA can see, diffed against boards.csv'
$treeItems = @(); $canonical = @(); $missing = @(); $extra = @()
if (-not $halted) {
    try {
        $treeItems = Get-SwdBoardList
        $selectable = @($treeItems | Where-Object { $_.Selectable })
        $folders    = @($treeItems | Where-Object { -not $_.Selectable })
        Write-Line "tree items     : $($treeItems.Count)  ($($selectable.Count) selectable, $($folders.Count) not)"
        if ($folders.Count -gt 0) {
            Write-Line "folder nodes   : $(($folders | ForEach-Object { Show-Target $_.Name 60 }) -join ' | ')"
        }

        if (Test-Path -LiteralPath $BoardsCsv) {
            $canonical = @((Import-Csv -LiteralPath $BoardsCsv).board)
            $seen = @($selectable | ForEach-Object { $_.Name })
            # ORDINAL, NOT -notcontains. PowerShell's -contains/-notcontains are
            # invariant-culture LINGUISTIC: measured 2026-09-02,
            # @('al<U+00AD>pha') -notcontains 'alpha' is False - i.e. "not missing" -
            # and so is the NFD-vs-NFC pair. The selector this gate protects
            # (swd_board.ps1:479) is OrdinalIgnoreCase and would then throw
            # "no tree item named 'alpha'" for a name the gate had just cleared.
            # A gate must use the comparison of the thing it gates. A cloud-synced
            # library written by seven authors is exactly where an NFD spelling or a
            # stray soft hyphen turns up.
            $seenSet  = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($n in $seen)      { [void]$seenSet.Add([string]$n) }
            $canonSet = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($n in $canonical) { [void]$canonSet.Add([string]$n) }
            $missing = @($canonical | Where-Object { -not $seenSet.Contains([string]$_) })
            $extra   = @($seen      | Where-Object { -not $canonSet.Contains([string]$_) })
            Write-Line "boards.csv     : $($canonical.Count) canonical names"
            Write-Line "missing        : $(if ($missing.Count) { (@($missing | ForEach-Object { Show-Target $_ 60 }) -join ' | ') } else { 'none' })"
            Write-Line "extra in tree  : $(if ($extra.Count)   { (@($extra   | ForEach-Object { Show-Target $_ 60 }) -join ' | ') } else { 'none' })"

            if ($missing.Count -gt 0) {
                $halted = $true
                $haltWhy = ("$($missing.Count) canonical board(s) are not selectable in the tree. " +
                            'A folder was almost certainly left collapsed - Select-SwdBoard never ' +
                            'expands, so a board under a closed folder is absent from the UIA tree ' +
                            'entirely. Expand all 11 folders and re-run.')
                Write-Line "HALT           : $haltWhy"
            }
        } else {
            $notes.Add("boards.csv not found at '$(Show-Target $BoardsCsv 200)'; the census could not be diffed.")
            # Operator-supplied rather than SWD-supplied, so no attacker path - but the
            # claim one screen up is that EVERY value reaching a log line is escaped,
            # and a CR+LF in a pasted path forges a well-formed second line all the same.
            Write-Line "boards.csv     : NOT FOUND at $(Show-Target $BoardsCsv 200)"
        }

        # AN EMPTY CANONICAL LIST IS NOT A PASS - it is the absence of a measurement.
        # With $canonical empty, $missing is empty too, so the halt above never fires;
        # D then rehearses zero names and prints 'every name resolves'; the sweep
        # order is empty and F ends '0 of 0 attempted selections landed'. Measured
        # 2026-09-02 with -BoardsCsv pointed at a path that does not exist: a wholly
        # green summary over a run that selected nothing, with no HALT line anywhere.
        if (-not $halted -and $canonical.Count -eq 0) {
            $halted = $true
            $haltWhy = ("no canonical board names were read from '$(Show-Target $BoardsCsv 200)', so the tree " +
                        'census was diffed against nothing and there is nothing to rehearse ' +
                        'or to sweep. Every verdict below would be vacuous. Point -BoardsCsv ' +
                        'at SWD/data/boards.csv and re-run.')
            Write-Line "HALT           : $haltWhy"
        }

        $verdict['B'] = if ($canonical.Count -eq 0) { 'HALT - no canonical board list to diff against' }
                        elseif ($halted)            { 'HALT - census short of canonical list' }
                        else                        { 'ok' }
    } catch {
        $verdict['B'] = "NOT CHECKED - $(Show-Target $_.Exception.Message 300)"
        Write-Line "B FAILED       : $(Show-Target $_.Exception.Message 300)"
        $halted = $true
        $haltWhy = 'tree census failed'
    }
} else {
    $verdict['B'] = 'skipped - halted earlier'
    Write-Line 'skipped        : the run halted before this section; see HALT in the summary.'
}

# --------------------------------------------------------------- C  menu census
# 2b.6, and the ONLY section that answers it. Every item is dumped, not just the
# Save-like ones: an earlier -Like '*Save*' probe returned a false positive on a
# build with no Save item at all (swd_board.ps1:563-569), so the useful evidence is
# the whole list of captions, which nobody has ever read.
Write-Section 'C. Menu census - 2b.6, read-only. NOTHING IS INVOKED.'
$menuItems = @()
if (-not $halted) {
    try {
        $menuItems = Get-SwdMenuItem -Like '*'
        Write-Line "menu items     : $($menuItems.Count)"
        foreach ($m in $menuItems) {
            $shown = if ([string]::IsNullOrEmpty($m.Name)) { '<unnamed>' } else { Show-Target $m.Name 60 }
            Write-Line ("  {0,-32} Invokable={1,-5} Enabled={2}" -f $shown, $m.Invokable, $m.Enabled)
        }
        $saveish = @($menuItems | Where-Object { $_.Name -and $_.Name -like '*Save*' })
        if ($saveish.Count -gt 0) {
            Write-Line ''
            foreach ($s in $saveish) {
                Write-Line "SAVE ITEM      : '$(Show-Target $s.Name 60)' Invokable=$($s.Invokable) Enabled=$($s.Enabled)"
            }
            $ready = @($saveish | Where-Object { $_.Invokable -and $_.Enabled })
            $verdict['C'] = if ($ready.Count -gt 0) { '2b.6 REACHABLE' } else { '2b.6 present but not invokable/enabled' }
        } else {
            Write-Line ''
            Write-Line 'no Save-like item in the UIA tree.'
            Write-Line 'This is INCONCLUSIVE, not a No: WinForms builds ToolStripDropDown items'
            Write-Line 'lazily and the dropdown is a separate top-level window, so submenu items'
            Write-Line 'need not be descendants of the main window until File has been opened.'
            $verdict['C'] = '2b.6 INCONCLUSIVE - no Save-like item; dropdown probably not built'
            $notes.Add('2b.6 inconclusive. The write-free escalation is to invoke the top-level File item (-Allow ''File''), which opens a dropdown and writes nothing, then re-enumerate across the process top-level windows. Not done here by design.')
        }
    } catch {
        $verdict['C'] = "NOT CHECKED - $(Show-Target $_.Exception.Message 300)"
        Write-Line "C FAILED       : $(Show-Target $_.Exception.Message 300)"
    }
} else {
    $verdict['C'] = 'skipped - halted earlier'
    Write-Line 'skipped        : the run halted before this section; see HALT in the summary.'
}

# ----------------------------------------------------------------- D  rehearsal
Write-Section 'D. Rehearsal - Select-SwdBoard -WhatIf over every canonical board'
$rehearsal = @()
if (-not $halted) {
    try {
        foreach ($name in $canonical) {
            $row = [ordered]@{ Board = $name; Resolved = $false; Reason = $null }
            try {
                $r = Select-SwdBoard -Name $name -WhatIf
                $row.Resolved = ($r.Reason -eq 'whatif')
                $row.Reason   = $r.Reason
            } catch {
                $row.Reason = (Show-Target $_.Exception.Message 300)
            }
            $rehearsal += [pscustomobject]$row
        }
        $bad = @($rehearsal | Where-Object { -not $_.Resolved })
        Write-Line "rehearsed      : $($rehearsal.Count)"
        Write-Line "unresolved     : $($bad.Count)"
        foreach ($b in $bad) { Write-Line "  $(Show-Target $b.Board 60) -> $(Show-Target $b.Reason 300)" }
        # A COUNT OF ZERO IS NOT A CLEAN SHEET. 'every name resolves' may only be
        # printed once every canonical name has actually been rehearsed. An empty
        # $canonical reached that string having rehearsed nothing - measured
        # 2026-09-02, 'rehearsed : 0 / unresolved : 0' above a green D. Section B
        # now halts before this point in that case; the count is asserted here as
        # well because the verdict, not the gate, is what a reader believes.
        $verdict['D'] = if ($canonical.Count -gt 0 -and $rehearsal.Count -eq $canonical.Count -and $bad.Count -eq 0) {
                            'ok - every name resolves to exactly one selectable item'
                        } elseif ($bad.Count -gt 0) {
                            "$($bad.Count) name(s) did not resolve"
                        } else {
                            "NOT CHECKED - rehearsed $($rehearsal.Count) of $($canonical.Count) canonical name(s)"
                        }
    } catch {
        $verdict['D'] = "NOT CHECKED - $(Show-Target $_.Exception.Message 300)"
        Write-Line "D FAILED       : $(Show-Target $_.Exception.Message 300)"
    }
} else {
    $verdict['D'] = 'skipped - halted earlier'
    Write-Line 'skipped        : the run halted before this section; see HALT in the summary.'
}

# ------------------------------------------------------- E/F  the selection sweep
# The order matters and is not cosmetic. Section E deliberately starts from a board
# that section A proved is NOT resident, because a board already loaded agrees with
# the caption whatever Select() does - so a sweep that happened to begin on the
# resident board would report Selected=$true having tested nothing.
$results = @()
if ($CensusOnly) {
    $verdict['E'] = 'skipped - -CensusOnly'
    $verdict['F'] = 'skipped - -CensusOnly'
    Write-Section 'E/F. Skipped - -CensusOnly was passed, so no board was selected.'
} elseif ($halted) {
    $verdict['E'] = 'skipped - halted earlier'
    $verdict['F'] = 'skipped - halted earlier'
    Write-Section 'E/F. Skipped - the run halted before any board was selected.'
} else {
    # NOT filtered by $missing. That filter read as a live guard and was provably
    # dead: $missing is only ever non-empty on a path that sets $halted, and a
    # halted run took the elseif above. It was also a second linguistic
    # -notcontains on a safety-shaped expression, which is the W1 defect - so it
    # is removed rather than converted.
    $order = @($canonical)
    if ($residentKnown) {
        $first = @($order | Where-Object {
            -not [string]::Equals($_, $before.Board, [StringComparison]::OrdinalIgnoreCase) })
        $order = @($first) + @($order | Where-Object {
            [string]::Equals($_, $before.Board, [StringComparison]::OrdinalIgnoreCase) })
    }
    # Remembered BEFORE the cap, because F reports against $order and would
    # otherwise print "5 of 5 landed" over 24 canonical boards nobody tried.
    $canonicalCount = $order.Count
    if ($MaxBoards -gt 0 -and $order.Count -gt $MaxBoards) { $order = @($order[0..($MaxBoards - 1)]) }

    Write-Section "E. First live selection - '$(if ($order.Count) { Show-Target $order[0] 60 } else { '<none>' })'"
    # Show-Target, not the raw caption. Get-SwdLoadedBoard's regex (swd_board.ps1:296)
    # uses '.', which matches CR in .NET, so a board name carrying \r parses and used
    # to reach this line raw. Measured 2026-09-02 against the real Write-Line: one
    # call produced TWO physical log lines, the second reading 'changed        : none'
    # - byte-identical to section G's own conclusion further down the same file.
    Write-Line "resident was   : $(if ($residentKnown) { Show-Target $before.Board 60 } else { '<UNREAD - see A; 2b.5 will read INCONCLUSIVE>' })"
    Write-Line "geometry       : $(if ($SkipGeometry) { 'SKIPPED - -SkipGeometry was passed, so every Conf* and GeomAgree cell below is unmeasured' } else { 'read from the Configuration panel after each selection' })"
    Write-Line 'This is 2b.5. AlreadyLoaded MUST come back False or the run proves nothing.'
    Write-Line ''

    # THE SWEEP'S OWN FAILURE GATE. Without it a run against an absent or
    # input-refusing SWD issues all 29 selections and logs 29 identical failures -
    # the "logs but keeps selecting" worst case. Measured 2026-09-02 with an
    # always-throwing Select-SwdBoard: 5 of 5 attempted, no HALT anywhere.
    #
    # THREE consecutive, not one. A single board can legitimately fail - a name in
    # boards.csv that is not in the tree, a caption that did not parse - without the
    # session being broken, and stopping on the first would throw away the other 28
    # measurements a supervised session was spent on. Three in a row is not bad luck.
    # It also bounds the pathological case: 3 x TimeoutMs rather than 29 x.
    $consecutiveFailures = 0
    $maxConsecutiveFailures = 3

    $index = 0
    foreach ($name in $order) {
        $index++
        $row = [ordered]@{
            Index = $index; Board = $name; Selected = $false; AlreadyLoaded = $null
            TitleBoard = $null; LengthMm = $null; ElapsedMs = $null; Reason = $null
            Dialog = $null
            ConfVolumeL = $null; ConfLengthMm = $null; ConfWidthMm = $null; ConfThickMm = $null
            ConfLoverW = $null; ConfWoverT = $null; ConfLoverT = $null
            GeomAgree = $null; GeomReason = $null
        }
        try {
            $r = Select-SwdBoard -Name $name -Confirm:$false
            $row.Selected      = $r.Selected
            $row.AlreadyLoaded = $r.AlreadyLoaded
            $row.TitleBoard    = $r.TitleBoard
            $row.LengthMm      = $r.LengthMm
            $row.ElapsedMs     = $r.ElapsedMs
            $row.Reason        = $r.Reason
        } catch {
            $row.Reason = "threw: $(Show-Target $_.Exception.Message 300)"
        }

        # DID SWD SURVIVE THAT? TopLevelForPid throws only on pid <= 0, so a dead but
        # positive pid enumerates nothing and the dialog gate below reads "clear" -
        # a cleared gate that measured nothing, which is the failure this file's own
        # .DESCRIPTION forbids.
        #
        # NOT $swd.HasExited, and that choice is the point. HasExited needs a process
        # HANDLE, and this script is documented to run against an SWD that may sit at
        # a HIGHER integrity level than the shell - the same boundary that already
        # makes IntegritySid come back unreadable in section A. A refused handle would
        # then read as "exited" and halt a healthy run at the first board.
        # Get-SwdProcess asks the process TABLE by name, which needs no handle at all,
        # and it answers a second question for free: SWD is on record as restarting
        # itself mid-operation - the save-and-load-a-copy branch of 2026-08-31 - and a
        # new pid invalidates $swd, $knownWindows and the section-A baseline together.
        $aliveWhy = $null
        try {
            $nowProc = Get-SwdProcess
            if ($nowProc.Id -ne $swd.Id) {
                $aliveWhy = "SWD restarted mid-sweep: pid $($swd.Id) did not answer, pid $($nowProc.Id) did"
            }
        } catch {
            $aliveWhy = "SWD (pid $($swd.Id)) did not answer: $(Show-Target $_.Exception.Message 200)"
        }
        if ($aliveWhy) {
            $row.Reason = "$($row.Reason); $aliveWhy"
            $results += [pscustomobject]$row
            $halted = $true
            $haltWhy = ("$aliveWhy - after selecting '$(Show-Target $name 60)'. Everything " +
                        'downstream would be measured against a process that is not the one ' +
                        'section A baselined.')
            Write-Line "  [$index/$($order.Count)] $(Show-Target $name 60) -> HALT: $haltWhy"
            break
        }

        # The dialog gate. Never dismissed automatically - nothing on this path
        # belongs here, so a window appearing is a finding, not an obstacle to clear.
        # -KnownHandle is section A's baseline, so this catches an unexpected window
        # WHATEVER its class; see Get-UnexpectedDialog for why the class alone was
        # never enough.
        # A FAILED CHECK IS NOT A CLEAR ONE. If the enumeration itself throws, the
        # question "is a modal up?" was not answered, and the safe reading of an
        # unanswered gate is to stop - the alternative is 28 more selections made
        # blind to a dialog that may already be blocking SWD's message pump.
        $dlg = @()
        try {
            $dlg = Get-UnexpectedDialog -ProcessId $swd.Id -KnownHandle $knownWindows
        } catch {
            $row.Dialog = 'gate-unreadable'
            $results += [pscustomobject]$row
            $halted = $true
            $haltWhy = ("the dialog gate could not be read after selecting " +
                        "'$(Show-Target $name 60)': $(Show-Target $_.Exception.Message 200). " +
                        'Stopping rather than sweeping blind.')
            Write-Line "  [$index/$($order.Count)] $(Show-Target $name 60) -> HALT: $haltWhy"
            break
        }
        if ($dlg.Count -gt 0) {
            $row.Dialog = ($dlg | ForEach-Object { $_.Handle }) -join ';'
            $results += [pscustomobject]$row
            $halted = $true
            $haltWhy = ("an unexpected top-level window appeared after selecting " +
                        "'$(Show-Target $name 60)' (handle(s) $($row.Dialog); " +
                        "$((@($dlg | ForEach-Object { "$(Show-Target $_.Class 40)/$($_.Why)" }) | Sort-Object -Unique) -join ', ')). " +
                        'Nothing was dismissed. Read it on screen, then dismiss it by hand.')
            Write-Line "  [$index/$($order.Count)] $(Show-Target $name 60) -> HALT: $haltWhy"
            break
        }

        if ($SkipGeometry) {
            # Otherwise an unmeasured GeomAgree is an empty cell, byte-identical to
            # the tri-state $null that Get-SwdGeometry returns for "the two oracles
            # were read and could not be compared". Those are different facts.
            $row.GeomReason = 'skipped - -SkipGeometry'
        } else {
            try {
                $g = Get-SwdGeometry
                $row.ConfVolumeL  = $g.Configuration.VolumeL
                $row.ConfLengthMm = $g.Configuration.LengthMm
                $row.ConfWidthMm  = $g.Configuration.WidthMm
                $row.ConfThickMm  = $g.Configuration.ThickMm
                $row.ConfLoverW   = $g.Configuration.LengthOverWidth
                $row.ConfWoverT   = $g.Configuration.WidthOverThick
                $row.ConfLoverT   = $g.Configuration.LengthOverThick
                $row.GeomAgree    = $g.Agree
            } catch {
                $row.GeomReason = (Show-Target $_.Exception.Message 300)
            }
        }

        $results += [pscustomobject]$row
        Write-Line ("  [{0}/{1}] {2,-42} Selected={3,-5} Already={4,-5} {5,6} ms  {6}" -f
            $index, $order.Count, (Show-Target $name 42), $row.Selected, $row.AlreadyLoaded, $row.ElapsedMs, $row.Reason)

        # A SECOND, INDEPENDENT WITNESS. AlreadyLoaded is Select-SwdBoard's report
        # from ONE caption read it takes itself (swd_board.ps1:455-458), so a read
        # that failed there yields AlreadyLoaded=$false for a board that WAS
        # resident. Section A observed the resident board through a separate call
        # at a separate time; when the two disagree the question was not answered.
        # Normally false at index 1, because the reorder above put the resident
        # board last - so this changes nothing on the good path.
        $wasResident = ($residentKnown -and
                        [string]::Equals($name, $before.Board, [StringComparison]::OrdinalIgnoreCase))

        if ($index -eq 1) {
            $verdict['E'] = if (-not $residentKnown) {
                '2b.5 INCONCLUSIVE - section A never read which board was resident, so AlreadyLoaded=False means UNOBSERVED here, not "a different board"'
            } elseif ($wasResident) {
                '2b.5 INCONCLUSIVE - section A had observed this very board as resident, whatever AlreadyLoaded reports'
            } elseif ($row.Selected -and $row.AlreadyLoaded -eq $false) {
                '2b.5 CONFIRMED - Select() loaded a board that was not resident'
            } elseif ($row.Selected -and $row.AlreadyLoaded) {
                '2b.5 INCONCLUSIVE - the board was already resident, so Select() was not tested'
            } else {
                "2b.5 FAILED - $($row.Reason)"
            }
            Write-Section "F. Sweep - the remaining $($order.Count - 1) boards"
        }

        if ($row.Selected) { $consecutiveFailures = 0 } else { $consecutiveFailures++ }
        if ($consecutiveFailures -ge $maxConsecutiveFailures) {
            $halted = $true
            $haltWhy = ("$consecutiveFailures consecutive selections failed, the last being " +
                        "'$(Show-Target $name 60)' ($(Show-Target $row.Reason 120)). SWD is not " +
                        'taking input, or the tree does not hold these names. Stopping rather ' +
                        "than issuing $($order.Count - $index) more.")
            Write-Line "  HALT: $haltWhy"
            break
        }
    }
    if (-not $verdict.Contains('E')) {
        $verdict['E'] = if ($results.Count -gt 0) {
            '2b.5 NOT CHECKED - the first selection was attempted but the run halted before it could be judged'
        } else {
            '2b.5 NOT CHECKED - no board was attempted'
        }
    }
    # A LATER BOARD STILL ANSWERS 2b.5. The verdict was bound to $index -eq 1, so a
    # first board that failed for its own reasons - a stale name, a caption that did
    # not parse - discarded an answer the rest of the sweep had already produced, and
    # getting it again costs another supervised session. Only ever an upgrade: a
    # CONFIRMED at index 1 is never revisited, and nothing here can turn a real
    # failure into a pass.
    # Gated on the SAME precondition as index 1, and on the same second witness.
    # Without that gate this block widened a false CONFIRMED from board 1 to any
    # board in the sweep - it made the Critical worse, not better.
    $proof = @()
    if ($residentKnown) {
        $proof = @($results | Where-Object {
            $_.Selected -and $_.AlreadyLoaded -eq $false -and
            -not [string]::Equals($_.Board, $before.Board, [StringComparison]::OrdinalIgnoreCase) })
    }
    if ($proof.Count -gt 0 -and $verdict['E'] -notlike '2b.5 CONFIRMED*') {
        # 'not the first' only when it really was not the first: the halt paths
        # reach here with board 1 in $proof and used to print the phrase anyway.
        $where = if ($proof[0].Index -eq 1) { 'board 1 of the sweep' }
                 else { "board $($proof[0].Index) of the sweep, not the first" }
        $verdict['E'] = "2b.5 CONFIRMED - Select() loaded a board that was not resident ($where)"
    }
    $swept = @($results | Where-Object { $_.Selected })
    $verdict['F'] = "$($swept.Count) of $($results.Count) attempted selections landed" +
                    $(if ($results.Count -lt $order.Count) {
                        "; SWEEP CUT SHORT - $($results.Count) of $($order.Count) boards attempted"
                      } else { '' }) +
                    $(if ($order.Count -lt $canonicalCount) {
                        "; -MaxBoards CAPPED the sweep at $($order.Count) of $canonicalCount canonical boards"
                      } else { '' })
}

# ------------------------------------------------------------- G  disk integrity
Write-Section 'G. Did any of that write to the library?'
if ($libRoot -and $hashesBefore.Count -gt 0) {
    try {
        $after = Get-BoardHash -Root $libRoot
        $map = @{}
        foreach ($h in $hashesBefore) { $map[$h.Rel] = $h.Sha256 }
        $changed = @(); $added = @(); $unreadable = @()
        foreach ($h in $after) {
            if (-not $map.ContainsKey($h.Rel)) { $added += $h.Rel }
            # A NULL HASH MEANS NOT READ, NOT UNCHANGED - and it must not be read as
            # 'changed' either. Either side missing makes the comparison impossible,
            # which is a third answer.
            elseif ($null -eq $h.Sha256 -or $null -eq $map[$h.Rel]) { $unreadable += $h.Rel }
            elseif ($map[$h.Rel] -ne $h.Sha256) { $changed += $h.Rel }
        }
        $afterRels = @{}
        foreach ($h in $after) { $afterRels[$h.Rel] = $true }
        $removed = @($hashesBefore | Where-Object { -not $afterRels.ContainsKey($_.Rel) } | ForEach-Object { $_.Rel })
        Write-Line "files before   : $($hashesBefore.Count)"
        Write-Line "files after    : $($after.Count)"
        Write-Line "changed        : $(if ($changed.Count) { (@($changed | ForEach-Object { Show-Target $_ 80 }) -join ' | ') } else { 'none' })"
        Write-Line "added          : $(if ($added.Count)   { (@($added   | ForEach-Object { Show-Target $_ 80 }) -join ' | ') } else { 'none' })"
        Write-Line "removed        : $(if ($removed.Count) { (@($removed | ForEach-Object { Show-Target $_ 80 }) -join ' | ') } else { 'none' })"
        Write-Line "unreadable     : $(if ($unreadable.Count) { (@($unreadable | ForEach-Object { Show-Target $_ 80 }) -join ' | ') } else { 'none' })"
        $verdict['G'] = if ($changed.Count -eq 0 -and $added.Count -eq 0 -and $removed.Count -eq 0 -and $unreadable.Count -eq 0) {
            'no library file changed during this run'
        } elseif ($changed.Count -eq 0 -and $added.Count -eq 0 -and $removed.Count -eq 0) {
            "INCOMPLETE - nothing seen to change, but $($unreadable.Count) file(s) could not be hashed"
        } else {
            "LIBRARY CHANGED: $($changed.Count) modified, $($added.Count) added, $($removed.Count) removed, $($unreadable.Count) unreadable"
        }
        # Rel is a filename SWD chose - the copy branch names files after the board -
        # so it is third-party text and gets the CSV mutation. Bytes and Sha256 are
        # numeric and hex.
        $gInjected = Save-Csv -Path $hashPath -Rows $after -Columns @('Rel', 'Bytes', 'Sha256', 'ReadError') -TextColumns @('Rel', 'ReadError')
        if ($gInjected -gt 0) { $notes.Add("$gInjected cell(s) in the hashes CSV were prefixed with an apostrophe against formula injection; strip one leading apostrophe when reading.") }
    } catch {
        $verdict['G'] = "NOT CHECKED - $(Show-Target $_.Exception.Message 300)"
        Write-Line "G FAILED       : $(Show-Target $_.Exception.Message 300)"
    }
} else {
    $verdict['G'] = 'NOT CHECKED - no baseline was taken'
    Write-Line 'no baseline was taken in section A, so nothing can be compared.'
}

# ------------------------------------------------------------------- artefacts
try {
    # -TextColumns is every column carrying text SWD chose. Board is a canonical name
    # from boards.csv, TitleBoard came out of the live caption, Reason and GeomReason
    # can carry an exception message; the rest are numbers and booleans this script
    # produced, and an apostrophe in front of one of those would be data corruption.
    $injected = Save-Csv -Path $rowsPath -Rows $results -Columns @(
        'Index', 'Board', 'Selected', 'AlreadyLoaded', 'TitleBoard', 'LengthMm', 'ElapsedMs',
        'Reason', 'Dialog', 'ConfVolumeL', 'ConfLengthMm', 'ConfWidthMm', 'ConfThickMm',
        'ConfLoverW', 'ConfWoverT', 'ConfLoverT', 'GeomAgree', 'GeomReason') `
        -TextColumns @('Board', 'TitleBoard', 'Reason', 'GeomReason')
    $injected += Save-Csv -Path $menuPath -Rows $menuItems -Columns @('Name', 'Invokable', 'Enabled') `
        -TextColumns @('Name')
    if ($injected -gt 0) {
        $notes.Add("$injected cell(s) in the boards/menu CSVs were prefixed with an apostrophe against formula injection (SQA W5); strip one leading apostrophe when reading.")
        Write-Line "csv injection  : $injected cell(s) neutralised with a leading apostrophe"
    }
} catch {
    Write-Line "artefact write failed: $(Show-Target $_.Exception.Message 300)"
}

# --------------------------------------------------------------------- summary
Write-Section 'SUMMARY'
foreach ($k in $verdict.Keys) { Write-Line ("  {0}  {1}" -f $k, $verdict[$k]) }
if ($halted) {
    Write-Line ''
    Write-Line "HALTED: $haltWhy"
}
if ($notes.Count -gt 0) {
    Write-Line ''
    Write-Line 'Notes:'
    foreach ($n in $notes) { Write-Line "  - $n" }
}
Write-Line ''
Write-Line 'What this run does NOT establish, whatever it printed:'
Write-Line '  - nothing about the three Apply buttons; Set-SwdGeometry was never called'
Write-Line '  - nothing about saving; Invoke-SwdMenuItem was never called, so 2b.6 rests on'
Write-Line '    the pattern being ADVERTISED, not on Invoke() having been fired'
Write-Line '  - nothing about scanning; no .fynrhydro was written or read'
Write-Line '  - section G is one observation over one short run, and does not generalise'
Write-Line '    to a 12-minute scan, which is separately on record as writing to the library'
# Conditional, and it belongs HERE rather than only in the E verdict: this block is
# what a reader scans to find out what a green run did not cover, and the one thing
# it did not cover has to appear in it.
if (-not $residentKnown) {
    Write-Line '  - NOTHING ABOUT 2b.5. The window caption never yielded a resident board, so'
    Write-Line '    section A could not establish which board to avoid, the sweep order was not'
    Write-Line '    rotated, and AlreadyLoaded=False below means UNOBSERVED rather than'
    Write-Line '    "a different board". Re-run once the caption reads.'
}
Write-Line ''
# Only what actually landed. Naming a path that was never written invites a reader
# to go looking for evidence that does not exist - the dry run of 2026-09-02 listed
# a hashes CSV that section G had skipped.
Write-Line 'artefacts written:'
foreach ($p in $logPath, $rowsPath, $menuPath, $hashPath) {
    if (Test-Path -LiteralPath $p) { Write-Line "  $p" }
}
$absent = @($rowsPath, $menuPath, $hashPath | Where-Object { -not (Test-Path -LiteralPath $_) })
if ($absent.Count -gt 0) {
    Write-Line 'not written (the section that produces them did not complete):'
    foreach ($p in $absent) { Write-Line "  $p" }
}
Write-Line "finished       : $(Get-Date -Format o)"
