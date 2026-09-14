<#
    Offline tests for verify_2b.ps1 - the live-run driver for TODO 2b.5 / 2b.6.

    SWD MUST BE CLOSED. Nothing here talks to it, and the guard below refuses to
    run if it is up: swd_msg.ps1 comes along with the driver and its own suites
    refuse for good reason.

    HOW THE DRIVER'S BODY IS EXERCISED WITH SWD CLOSED, which is the whole point
    of this file. The previous version only ever ran -DotSourceOnly, which returns
    before any section acts, so eight of its twenty-seven tests re-implemented the
    driver's own expressions inline and executed no driver code at all. Five
    deliberate defects were seeded into verify_2b.ps1 and the suite stayed 27/27
    green through every one - including deleting the AlreadyLoaded guard, which
    turns 'E 2b.5 INCONCLUSIVE' into 'E 2b.5 CONFIRMED', the exact false positive
    the driver exists to prevent.

    So a sandbox is staged instead: a BYTE-IDENTICAL copy of verify_2b.ps1 beside
    STUB swd_board.ps1 and swd_geometry.ps1 files. The driver resolves both from
    $PSScriptRoot, so the copy dot-sources the stubs and the real body then runs -
    every section, every gate, every verdict - against a fake application this file
    controls. The stub swd_board.ps1 dot-sources the REAL swd_msg.ps1, so
    ConvertTo-SwdSafeText, ConvertTo-SwdCsvCell, Resolve-SwdWritableTarget and
    [SwdWin] are the real ones and are not faked. A test asserts the copy's SHA-256
    equals the original's, so this can never quietly test a stale driver.

    IT NO LONGER READS THE REAL BOARD LIBRARY 38 TIMES. It used to: every driver
    invocation hashes the library in section A and again in section G, which came
    to ~3.72 GB of reads across one suite run, and NOTHING asserted on the result.
    Worse, the library sits on a OneDrive Files-On-Demand tree - all 29 files are
    hydrated today, but one "Free up space" turns that volume into network
    transfer inside the guard. So the driver gained -LibraryRoot, every run below
    points it at a small fake library, and exactly ONE test uses the real one -
    with an assertion on section G, which is more coverage than the 38 runs had
    between them. Read-only either way: FileShare.Read, never written, never
    deserialised, and these tests refuse to run while SWD is up.

    NOT COVERED HERE, and named rather than left to be discovered:
      - every real UIA path (Get-SwdBoardList, Get-SwdMenuItem, Select-SwdBoard);
        they belong to swd_board.Tests.ps1 and to the live run itself. What IS
        covered is how the driver INTERPRETS whatever they return.
      - Get-SwdGeometry and the Configuration panel; swd_geometry.Tests.ps1
      - Resolve-SwdWritableTarget, covered by swd_msg.Tests.ps1
      - whether SWD actually raises a dialog of some class other than #32770.
        The gate no longer assumes; it diffs against a preflight baseline.
#>

BeforeAll {
    $script:Phase2  = Split-Path -Parent $PSScriptRoot
    $script:Driver  = Join-Path $script:Phase2 'verify_2b.ps1'

    if (Get-Process -Name 'SurfHydrodynamics' -ErrorAction SilentlyContinue) {
        throw 'SurfHydrodynamics is RUNNING. These tests must never be pointed at it - close it first.'
    }

    $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ("verify2b-" + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($script:Sandbox)

    # -DotSourceOnly returns before any section acts, so this defines the helpers
    # and nothing else. -LogDir is pointed at a sandbox so the real logs/ folder
    # is never touched by a test run.
    . $script:Driver -DotSourceOnly -LogDir $script:Sandbox

    # ---------------------------------------------------------------- the harness
    $script:Harness = Join-Path $script:Sandbox 'harness'
    [void][IO.Directory]::CreateDirectory($script:Harness)
    Copy-Item -LiteralPath $script:Driver -Destination (Join-Path $script:Harness 'verify_2b.ps1') -Force

    # The stubs are written from here rather than committed as fixture files so
    # they cannot drift out of sight of the tests that depend on them. Every one
    # reads a key of the $SwdStub hashtable that script:Invoke-Verify2b builds per
    # run in its own scope - see the comment there for why that is reachable.
    $realMsg = Join-Path $script:Phase2 'swd_msg.ps1'
    Set-Content -LiteralPath (Join-Path $script:Harness 'swd_board.ps1') -Encoding UTF8 -Value @"
# TEST DOUBLE for swd_board.ps1. The REAL message layer is loaded, so
# ConvertTo-SwdSafeText, ConvertTo-SwdCsvCell, Resolve-SwdWritableTarget and
# [SwdWin] are genuine; only the UI Automation surface is faked.
. '$realMsg'

function Get-SwdProcess {
    if (`$SwdStub.ProcessThrows) { throw `$SwdStub.ProcessThrowMessage }
    # Faithful to the real one: Get-Process by NAME finds nothing once the process
    # is gone, and Get-SwdProcess throws rather than handing back a dead object.
    if (`$SwdStub.Process -and `$SwdStub.Process.HasExited) {
        throw 'stub: SurfHydrodynamics is not running. Launch it by hand first.'
    }
    return `$SwdStub.Process
}
function Get-SwdWindowTitle {
    [CmdletBinding()] param([int]`$TimeoutMs = 2000, [int]`$DeadlineMs = 6000)
    return `$SwdStub.Title
}
function Get-SwdLoadedBoard {
    [CmdletBinding()] param([int]`$TimeoutMs = 2000, [int]`$DeadlineMs = 6000)
    return [pscustomobject]@{
        Board = `$SwdStub.ResidentBoard
        LengthMm = 1800.0
        Title = `$SwdStub.Title
        Parsed = [bool]`$SwdStub.ResidentBoard
        ReadError = `$null
    }
}
function Get-SwdBoardList {
    [CmdletBinding()] param([object] `$Window)
    `$out = @()
    foreach (`$n in @(`$SwdStub.TreeNames)) {
        `$out += [pscustomobject]@{ Name = `$n; Element = `$null; Selectable = `$true; Expandable = `$false }
    }
    foreach (`$n in @(`$SwdStub.FolderNames)) {
        `$out += [pscustomobject]@{ Name = `$n; Element = `$null; Selectable = `$false; Expandable = `$true }
    }
    return ,`$out
}
function Get-SwdMenuItem {
    [CmdletBinding()] param([string] `$Like = '*', [object] `$Window)
    `$out = @()
    foreach (`$m in @(`$SwdStub.MenuItems)) { `$out += `$m }
    return ,`$out
}
function Select-SwdBoard {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string] `$Name, [int] `$TimeoutMs = 15000, [int] `$PollMs = 250)
    `$SwdStub.SelectCalls += @(`$Name)
    if (`$SwdStub.SelectThrows) { throw "stub: no tree item named '`$Name'." }
    if (-not `$PSCmdlet.ShouldProcess('SWD board tree', "select '`$Name'")) {
        return [pscustomobject]@{
            Requested = `$Name; Selected = `$false; AlreadyLoaded = `$false
            TitleBoard = `$null; LengthMm = `$null; ElapsedMs = 0
            Reason = `$(if (`$WhatIfPreference) { 'whatif' } else { 'not-confirmed' })
        }
    }
    # Past ShouldProcess this is a LIVE selection, not a -WhatIf rehearsal. The two
    # are counted separately because section D rehearses every canonical name, so a
    # single total cannot tell "the sweep was cut short" from "D ran".
    `$SwdStub.LiveCalls += @(`$Name)
    # Raise a REAL #32770 inside the target pid, mid-sweep, and do not return until
    # it is visible - so the driver's own gate meets a genuine modal rather than a
    # record fixture, deterministically.
    if (`$SwdStub.DialogOnSelect) {
        Set-Content -LiteralPath `$SwdStub.DialogOnSelect.Flag -Value 'go' -Encoding ASCII
        `$sw = [Diagnostics.Stopwatch]::StartNew()
        while (`$sw.ElapsedMilliseconds -lt 20000) {
            # ContainsKey, not .Class: StrictMode makes a missing hashtable key a
            # THROW, and a stub that throws is indistinguishable from the driver
            # failing - it cost two green-looking failures to find that out.
            `$want = '#32770'
            if (`$SwdStub.DialogOnSelect.ContainsKey('Class')) { `$want = `$SwdStub.DialogOnSelect.Class }
            `$up = `$false
            foreach (`$line in [SwdWin]::TopLevelForPid(`$SwdStub.DialogOnSelect.Pid)) {
                `$f = `$line -split ([regex]::Escape([SwdWin]::SEP))
                if (`$f.Count -eq [SwdWin]::TOPLEVEL_FIELDS -and `$f[1] -like "`$want*" -and [bool]::Parse(`$f[2])) { `$up = `$true }
            }
            if (`$up) { break }
            Start-Sleep -Milliseconds 100
        }
        `$SwdStub.DialogOnSelect = `$null
    }
    # SWD dying mid-sweep, deterministically: the process is killed here rather
    # than by a timer, so the driver's liveness check runs against a genuinely
    # exited process on the very next line of its own loop.
    if (`$SwdStub.KillOnSelect) {
        Stop-Process -Id `$SwdStub.KillOnSelect.Id -Force -ErrorAction SilentlyContinue
        [void]`$SwdStub.KillOnSelect.WaitForExit(5000)
        `$SwdStub.KillOnSelect = `$null
    }
    # SWD restarting itself mid-sweep - the save-and-load-a-copy branch - is a
    # different fault from dying, and it invalidates the same baseline.
    if (`$SwdStub.RestartOnSelect) {
        `$SwdStub.Process = `$SwdStub.RestartOnSelect
        `$SwdStub.RestartOnSelect = `$null
    }
    `$fail = @(`$SwdStub.FailBoards) -contains `$Name
    return [pscustomobject]@{
        Requested = `$Name
        Selected = (-not `$fail)
        AlreadyLoaded = `$(if (`$fail) { `$null } else { [bool]`$SwdStub.AlreadyLoaded })
        TitleBoard = `$(if (`$fail) { `$null } else { `$Name })
        LengthMm = `$(if (`$fail) { `$null } else { 1800.0 })
        ElapsedMs = 5
        Reason = `$(if (`$fail) { 'timeout' } else { 'ok' })
    }
}
"@
    Set-Content -LiteralPath (Join-Path $script:Harness 'swd_geometry.ps1') -Encoding UTF8 -Value @"
function Get-SwdGeometry {
    [CmdletBinding()] param()
    if (`$SwdStub.Geometry) { return `$SwdStub.Geometry }
    throw 'stub: the Configuration panel is not readable offline.'
}
"@

    # Runs the real driver body against the stubs and returns everything a test
    # needs to assert on. Every run gets its own -LogDir: the artefact names carry
    # a whole-second timestamp, so two runs in the same second would collide.
    function script:Invoke-Verify2b {
        param([hashtable] $Stub = @{}, [hashtable] $Driver = @{}, [switch] $PassThruError)

        $run = Join-Path $script:Sandbox ('run-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($run)

        # ONE hashtable, in THIS function's scope - no global variables. PowerShell
        # resolves an unqualified variable read up the CALL stack, so the driver
        # invoked below, and the stub functions it dot-sources, all see $SwdStub;
        # and because the stubs MUTATE the hashtable rather than rebind the name,
        # what they record comes back here. Globals would work too, and sixteen of
        # them leaking between tests is a cross-test coupling waiting to happen -
        # which is what PSScriptAnalyzer's PSAvoidGlobalVars is warning about.
        $SwdStub = @{
            Process             = Get-Process -Id $PID
            ProcessThrows       = $false
            ProcessThrowMessage = 'stub: SurfHydrodynamics is not running.'
            Title               = 'FYN Shaper Wave Dynamics 1.0.8.1'
            ResidentBoard       = 'resident_board'
            TreeNames           = @('alpha', 'beta', 'gamma')
            FolderNames         = @()
            MenuItems           = @()
            AlreadyLoaded       = $false
            SelectThrows        = $false
            FailBoards          = @()
            Geometry            = $null
            KillOnSelect        = $null
            RestartOnSelect     = $null
            SelectCalls         = @()
            LiveCalls           = @()
            DialogOnSelect      = $null
        }
        foreach ($k in $Stub.Keys) { $SwdStub[$k] = $Stub[$k] }

        # A small FAKE library by default. One test opts back into the real one.
        $p = @{ LogDir = $run; SkipGeometry = $true; LibraryRoot = $script:FakeLib }
        foreach ($k in $Driver.Keys) { $p[$k] = $Driver[$k] }
        if (-not $p.ContainsKey('BoardsCsv')) {
            $csv = Join-Path $run 'boards.csv'
            $canon = @(if ($Stub.ContainsKey('CanonicalBoards')) { $Stub['CanonicalBoards'] } else { $SwdStub.TreeNames })
            # Through ConvertTo-Csv, not string concatenation: a board name holding a
            # comma or a quote - which is exactly what the injection fixtures use -
            # would otherwise be split across columns and the fixture would silently
            # test a different name than the one in the tree.
            $lines = @(@($canon | ForEach-Object { [pscustomobject]@{ board = $_ } }) | ConvertTo-Csv -NoTypeInformation)
            [IO.File]::WriteAllLines($csv, $lines, (New-Object Text.UTF8Encoding($false)))
            $p['BoardsCsv'] = $csv
        }

        $threw = $null
        try { & (Join-Path $script:Harness 'verify_2b.ps1') @p | Out-Null }
        catch { $threw = $_ ; if (-not $PassThruError) { throw } }

        $logFile = Get-ChildItem -LiteralPath $run -Filter '*-2b-verify.log' -ErrorAction SilentlyContinue |
                        Select-Object -First 1
        $rowsFile = Get-ChildItem -LiteralPath $run -Filter '*-2b-boards.csv' -ErrorAction SilentlyContinue |
                        Select-Object -First 1
        # Built into locals first. A statement block used as a hashtable value emits
        # its output through the pipeline, which UNROLLS an array and collapses a
        # one-element result to a scalar - the same trap the `return ,$out` rule in
        # swd_board.ps1 exists for, one layer up.
        $logText  = if ($logFile)  { [IO.File]::ReadAllText($logFile.FullName) } else { '' }
        $rowsPath = if ($rowsFile) { $rowsFile.FullName } else { $null }
        # @() OUTSIDE the if, not inside: assigning an if-statement pipes its output,
        # which unrolls the inner array and collapses a ONE-row result to a scalar.
        $rows     = @(if ($rowsFile) { Import-Csv -LiteralPath $rowsFile.FullName })
        [pscustomobject]@{
            LogDir   = $run
            Log      = $logText
            RowsPath = $rowsPath
            Rows     = $rows
            Selected = @($SwdStub.SelectCalls)
            Live     = @($SwdStub.LiveCalls)
            Error    = $threw
        }
    }

    # The summary line for one section, e.g. 'ok' for 'B'. Read out of the log the
    # driver actually wrote rather than out of any in-memory state.
    function script:Get-Verdict {
        param([Parameter(Mandatory)] $Result, [Parameter(Mandatory)][string] $Section)
        $m = [regex]::Match($Result.Log, "(?m)^\s{2}$([regex]::Escape($Section))\s\s(?<v>.*)$")
        if (-not $m.Success) { return $null }
        return $m.Groups['v'].Value.TrimEnd()
    }

    # Two .fynbs, one nested, one decoy - enough to exercise recursion, the
    # extension filter and the section-G diff without touching the real library.
    $script:FakeLib = Join-Path $script:Sandbox 'fakelib'
    [void][IO.Directory]::CreateDirectory((Join-Path $script:FakeLib 'ShortBoards'))
    Set-Content -LiteralPath (Join-Path $script:FakeLib 'a.fynbs') -Value 'aaa' -NoNewline
    Set-Content -LiteralPath (Join-Path $script:FakeLib 'ShortBoards\b.fynbs') -Value 'bbb' -NoNewline
    Set-Content -LiteralPath (Join-Path $script:FakeLib 'notaboard.txt') -Value 'ccc' -NoNewline

    # A child process that raises ONE top-level window on demand: a #32770 via
    # MessageBox, or a plain WinForms Form whose class is WindowsForms10.*. Both
    # are real Win32 windows in a real other process - the gate is never handed a
    # fixture record for this. Hidden until the flag file appears, so preflight
    # sees a clean baseline.
    # The child runs a SCRIPT FILE, not a -Command string. Building the command
    # inline was quoting-fragile enough to produce two failures that looked like
    # driver defects and were not.
    $script:WinFixtureScript = Join-Path $script:Sandbox 'winfixture.ps1'
    Set-Content -LiteralPath $script:WinFixtureScript -Encoding UTF8 -Value @'
param([Parameter(Mandatory)][string]$Flag, [ValidateSet('MessageBox', 'Form')][string]$Kind = 'MessageBox')
while (-not (Test-Path -LiteralPath $Flag)) { Start-Sleep -Milliseconds 50 }
Add-Type -AssemblyName System.Windows.Forms
if ($Kind -eq 'MessageBox') {
    [void][System.Windows.Forms.MessageBox]::Show('sqa fixture')
} else {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'sqa fixture'
    [void]$form.ShowDialog()
}
'@

    function script:Start-WindowFixture {
        param([ValidateSet('MessageBox', 'Form')][string]$Kind)
        $flag = Join-Path $script:Sandbox ('win-' + [guid]::NewGuid().ToString('N') + '.flag')
        $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:WinFixtureScript,
                       '-Flag', $flag, '-Kind', $Kind)
        # -WindowStyle Hidden for the MessageBox only. Measured: Hidden sets
        # STARTF_USESHOWWINDOW/SW_HIDE, which WinForms HONOURS for the first form
        # shown (so a Form never appears) while MessageBox ignores it. Started
        # without it, the Form reliably materialises in ~1.3 s.
        $proc = if ($Kind -eq 'MessageBox') {
            Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList $childArgs
        } else {
            Start-Process -FilePath 'powershell.exe' -PassThru -ArgumentList $childArgs
        }
        return [pscustomobject]@{ Process = $proc; Flag = $flag; Kind = $Kind }
    }
    function script:Stop-WindowFixture {
        param($Fixture)
        if (-not $Fixture) { return }
        Stop-Process -Id $Fixture.Process.Id -Force -ErrorAction SilentlyContinue
        $Fixture.Process.WaitForExit(5000) | Out-Null
    }

    $script:SEP = [SwdWin]::SEP
    function script:New-TopLevelRecord {
        param([int64]$Handle, [string]$Class = '#32770', [bool]$Visible = $true, [int64]$Owner = 999)
        return (@($Handle, $Class, $Visible.ToString(), $Owner) -join [SwdWin]::SEP)
    }
}

AfterAll {
    if ($script:Sandbox -and (Test-Path -LiteralPath $script:Sandbox)) {
        Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'verify_2b.ps1 loads without acting' {
    It 'defines every helper the driver body depends on' {
        foreach ($fn in 'Write-Line', 'Write-Section', 'Show-Target', 'Save-Text',
                        'Save-Csv', 'Get-BoardLibraryPath', 'Get-BoardHash',
                        'Get-UnexpectedDialog', 'Test-PathAtOrUnder', 'Get-RepositoryRoot') {
            Get-Command $fn -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because "$fn must exist"
        }
    }

    It 'brings the already-SQA''d layers with it rather than reimplementing them' {
        Get-Command Select-SwdBoard  -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Get-SwdMenuItem  -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Get-SwdGeometry  -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'wrote nothing into an empty directory, because -DotSourceOnly runs no section' {
        # A directory of its own, not the shared sandbox: the old version of this
        # test passed only because it happened to run before any Describe that
        # wrote a file, so Describe ordering was load-bearing on the assertion.
        $empty = Join-Path $script:Sandbox ('dotsource-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($empty)
        . $script:Driver -DotSourceOnly -LogDir $empty
        @(Get-ChildItem -LiteralPath $empty -Force).Count | Should -Be 0
    }

    It 'does not create a -LogDir that does not exist yet when only dot-sourcing' {
        $absent = Join-Path $script:Sandbox ('never-' + [guid]::NewGuid().ToString('N'))
        . $script:Driver -DotSourceOnly -LogDir $absent
        Test-Path -LiteralPath $absent | Should -BeFalse
    }

    It 'refuses a negative -MaxBoards before anything is dot-sourced' {
        { & $script:Driver -DotSourceOnly -MaxBoards -1 } | Should -Throw '*MaxBoards must be 0 or more*'
    }

    It 'stages a BYTE-IDENTICAL copy of the driver, so no test can pass against a stale one' {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $a = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($script:Driver)))
            $b = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes((Join-Path $script:Harness 'verify_2b.ps1'))))
        } finally { $sha.Dispose() }
        $b | Should -Be $a
    }
}

Describe 'No section may report a verdict it did not measure  (SQA C1)' {
    # With no canonical list, $missing is empty so the census halt never fires, D
    # rehearses zero names and prints "every name resolves", and the sweep selects
    # nothing - a wholly green summary over a run that measured nothing. Measured
    # 2026-09-02 on the pre-fix driver: B ok / D ok / F "0 of 0", no HALT line.
    It 'HALTs when -BoardsCsv does not exist, instead of reporting B ok' {
        $r = script:Invoke-Verify2b -Driver @{ BoardsCsv = (Join-Path $script:Sandbox 'no-such-file.csv') }
        $r.Log | Should -Match 'HALT'
        # The exact string, not merely "not ok": B has two halt reasons and naming
        # the wrong one sends the operator to expand folders that are already open.
        (script:Get-Verdict $r 'B') | Should -Be 'HALT - no canonical board list to diff against'
        (script:Get-Verdict $r 'D') | Should -Not -BeLike 'ok*'
    }

    It 'selects nothing at all when there is no canonical list' {
        $r = script:Invoke-Verify2b -Driver @{ BoardsCsv = (Join-Path $script:Sandbox 'no-such-file.csv') }
        $r.Selected.Count | Should -Be 0
        (script:Get-Verdict $r 'E') | Should -BeLike 'skipped*'
    }

    It 'HALTs on a header-only boards.csv' {
        $csv = Join-Path $script:Sandbox ('hdr-' + [guid]::NewGuid().ToString('N') + '.csv')
        [IO.File]::WriteAllLines($csv, @('board'), (New-Object Text.UTF8Encoding($false)))
        $r = script:Invoke-Verify2b -Driver @{ BoardsCsv = $csv }
        $r.Log | Should -Match 'HALT'
        $r.Selected.Count | Should -Be 0
    }

    It 'HALTs on a boards.csv with no board column' {
        $csv = Join-Path $script:Sandbox ('nocol-' + [guid]::NewGuid().ToString('N') + '.csv')
        [IO.File]::WriteAllLines($csv, @('name,length', 'alpha,1800'), (New-Object Text.UTF8Encoding($false)))
        $r = script:Invoke-Verify2b -Driver @{ BoardsCsv = $csv }
        $r.Log | Should -Match 'HALT'
        $r.Selected.Count | Should -Be 0
    }

    It 'still reports B ok and D ok on a census that really did match' {
        # The other half of the gate: it must not halt a good run. Without this the
        # C1 fix could be "always halt", which passes every test above.
        $r = script:Invoke-Verify2b
        (script:Get-Verdict $r 'B') | Should -Be 'ok'
        (script:Get-Verdict $r 'D') | Should -BeLike 'ok - every name resolves*'
        $r.Selected.Count | Should -BeGreaterThan 0
    }

    It 'D does not claim every name resolved when only some were rehearsed' {
        # Directly on the verdict expression: three canonical names, one of which
        # Select-SwdBoard -WhatIf refuses.
        $r = script:Invoke-Verify2b -Stub @{ SelectThrows = $true }
        (script:Get-Verdict $r 'D') | Should -Not -BeLike 'ok*'
    }
}

Describe 'The census diff decides whether the run halts  (SQA W1)' {
    It 'names the boards a collapsed folder hid' {
        $r = script:Invoke-Verify2b -Stub @{ TreeNames = @('alpha') ; CanonicalBoards = @('alpha', 'beta', 'gamma') }
        $r.Log | Should -Match 'missing        : beta \| gamma'
        $r.Log | Should -Match 'HALT'
        $r.Selected.Count | Should -Be 0
    }

    It 'reports a tree item absent from boards.csv as extra rather than ignoring it' {
        # SWD's copy branch writes new boards into biblio/Boards/ rather than the
        # original's subfolder, so the tree CAN legitimately hold a board the
        # extracted corpus has never seen. That is a finding, not noise.
        $r = script:Invoke-Verify2b -Stub @{ TreeNames = @('alpha', 'alpha_Copy_1') ; CanonicalBoards = @('alpha') }
        $r.Log | Should -Match 'extra in tree  : alpha_Copy_1'
    }

    It 'does not conflate a board with its _Copy_1 sibling' {
        $r = script:Invoke-Verify2b -Stub @{
            TreeNames = @('2003_Taylor_Knox_channel_island_Copy_1')
            CanonicalBoards = @('2003_Taylor_Knox_channel_island') }
        $r.Log | Should -Match 'HALT' -Because 'a substring match here would report a false all-clear'
    }

    It 'treats a soft-hyphenated tree name as MISSING, the way the selector will' {
        # -notcontains is invariant-culture linguistic: measured,
        # @('al<U+00AD>pha') -notcontains 'alpha' is False, i.e. "not missing", so
        # the run did not halt and Select-SwdBoard - which compares
        # OrdinalIgnoreCase - then threw for that very name.
        $tricky = 'al' + [string][char]0x00AD + 'pha'
        $r = script:Invoke-Verify2b -Stub @{ TreeNames = @($tricky) ; CanonicalBoards = @('alpha') }
        $r.Log | Should -Match 'HALT'
        $r.Selected.Count | Should -Be 0
    }

    It 'treats an NFD spelling of an accented name as MISSING too' {
        # A different ignorable-difference dimension from the soft hyphen: combining
        # acute versus precomposed. A cloud-synced library written by seven authors
        # on two operating systems is where this turns up.
        $nfd = 'e' + [string][char]0x0301 + 'lement_board'
        $nfc = [string][char]0x00E9 + 'lement_board'
        $r = script:Invoke-Verify2b -Stub @{ TreeNames = @($nfd) ; CanonicalBoards = @($nfc) }
        $r.Log | Should -Match 'HALT'
        $r.Selected.Count | Should -Be 0
    }

    It 'still matches a name that differs only in case' {
        # Ordinal-IGNORE-case, not ordinal. The docstring promises exact and
        # case-insensitive, and so does Select-SwdBoard.
        $r = script:Invoke-Verify2b -Stub @{ TreeNames = @('Alpha', 'BETA') ; CanonicalBoards = @('alpha', 'beta') }
        $r.Log | Should -Match 'missing        : none'
        $r.Log | Should -Match 'extra in tree  : none'
    }
}

Describe 'The sweep must stop failing loudly rather than quietly  (SQA W2)' {
    It 'HALTs after three consecutive failed selections instead of issuing all of them' {
        # Measured 2026-09-02 on the pre-fix driver with an always-throwing
        # Select-SwdBoard: 5 of 5 attempted, no HALT. At 29 boards x TimeoutMs
        # 15000 that is the "logs but keeps selecting" worst case.
        $boards = @('b1', 'b2', 'b3', 'b4', 'b5', 'b6', 'b7', 'b8')
        $r = script:Invoke-Verify2b -Stub @{ TreeNames = $boards; FailBoards = $boards }
        $r.Log | Should -Match 'consecutive selections failed'
        $r.Live.Count | Should -Be 3 -Because 'the gate is three in a row, and the sweep must stop there'
        (script:Get-Verdict $r 'F') | Should -BeLike '*SWEEP CUT SHORT*'
    }

    It 'does NOT halt on isolated failures, so one stale name cannot end a session' {
        # The other direction. A gate that stops on the first failure throws away
        # the 28 measurements a supervised session was spent on.
        $boards = @('b1', 'b2', 'b3', 'b4', 'b5', 'b6')
        $r = script:Invoke-Verify2b -Stub @{ TreeNames = $boards; FailBoards = @('b2', 'b4', 'b6') }
        $r.Log | Should -Not -Match 'consecutive selections failed'
        $r.Live.Count | Should -Be $boards.Count
        (script:Get-Verdict $r 'F') | Should -Not -BeLike '*SWEEP CUT SHORT*'
    }

    It 'HALTs when SWD exits mid-sweep, not reading an empty window list as "gate clear"' {
        # [SwdWin]::TopLevelForPid throws only on pid <= 0, so a dead but POSITIVE
        # pid enumerates nothing and the dialog gate reads clear. The process is
        # asked directly instead. The fixture process is alive at preflight and is
        # killed by the first live selection, so this is the real mid-sweep case
        # rather than a process that was already gone.
        $victim = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
                    -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 120'
        try {
            $r = script:Invoke-Verify2b -Stub @{
                Process = $victim; KillOnSelect = $victim
                TreeNames = @('b1', 'b2', 'b3', 'b4', 'b5') }
            $r.Log | Should -Match 'did not answer'
            $r.Live.Count | Should -Be 1 -Because 'the halt lands after the first selection, not after all five'
            (script:Get-Verdict $r 'F') | Should -BeLike '*SWEEP CUT SHORT*'
        } finally {
            Stop-Process -Id $victim.Id -Force -ErrorAction SilentlyContinue
        }
    }

    It 'HALTs when a REAL #32770 appears MID-SWEEP, not just at preflight' {
        # The sweep gate had zero coverage: replacing `if ($dlg.Count -gt 0)` with
        # `if ($false)` passed the whole suite. The only modal fixture exercised the
        # PREFLIGHT gate. This one is clean at preflight and raises a genuine
        # #32770 inside the target pid during the first live selection, which is
        # the state that guards the other 28 Select() calls against a blocked pump.
        $f = script:Start-WindowFixture -Kind 'MessageBox'
        try {
            $r = script:Invoke-Verify2b -Stub @{
                Process = $f.Process
                DialogOnSelect = @{ Flag = $f.Flag; Pid = $f.Process.Id }
                TreeNames = @('b1', 'b2', 'b3', 'b4', 'b5') }
            $r.Log | Should -Match 'unexpected top-level window'
            $r.Log | Should -Match '#32770'
            $r.Live.Count | Should -Be 1 -Because 'the sweep must stop at the board that raised it'
            (script:Get-Verdict $r 'F') | Should -BeLike '*SWEEP CUT SHORT*'
            # The selection that landed before the modal still answers 2b.5, and the
            # phrase must match: this is the halt path, where E was NOT set at index
            # 1, so the $proof block names board 1 and must not call it 'not the first'.
            (script:Get-Verdict $r 'E') | Should -Be '2b.5 CONFIRMED - Select() loaded a board that was not resident (board 1 of the sweep)'
        } finally { script:Stop-WindowFixture $f }
    }

    It 'HALTs on a mid-sweep window that is NOT #32770, which the class rule alone misses' {
        # The whole point of the -KnownHandle baseline. SCAN-FLOW establishes the
        # class for two observed dialogs and no more, so a modal of another class
        # must still stop the sweep. Dropping -KnownHandle from the sweep gate
        # leaves every other test green, because they all use #32770.
        $f = script:Start-WindowFixture -Kind 'Form'
        try {
            $r = script:Invoke-Verify2b -Stub @{
                Process = $f.Process
                DialogOnSelect = @{ Flag = $f.Flag; Pid = $f.Process.Id; Class = 'WindowsForms10' }
                TreeNames = @('b1', 'b2', 'b3', 'b4', 'b5') }
            $r.Log | Should -Match 'unexpected top-level window'
            $r.Log | Should -Match 'WindowsForms10' -Because 'the halt must name the class it actually saw'
            $r.Log | Should -Match 'new-window' -Because 'it is the BASELINE rule that caught it, not the class rule'
            $r.Live.Count | Should -Be 1
        } finally { script:Stop-WindowFixture $f }
    }

    It 'HALTs when SWD RESTARTS mid-sweep, because the baseline belonged to the old pid' {
        # SWD is on record as saving and loading a COPY mid-operation, which is a
        # restart in everything but name: $swd, the window baseline and the resident
        # caption all belonged to the process that is now gone.
        $replacement = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
                        -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 120'
        try {
            $r = script:Invoke-Verify2b -Stub @{
                RestartOnSelect = $replacement
                TreeNames = @('b1', 'b2', 'b3', 'b4', 'b5') }
            $r.Log | Should -Match 'SWD restarted mid-sweep'
            $r.Live.Count | Should -Be 1
        } finally {
            Stop-Process -Id $replacement.Id -Force -ErrorAction SilentlyContinue
        }
    }

    It 'F says how far the sweep actually got when it was cut short' {
        $boards = @('b1', 'b2', 'b3', 'b4', 'b5')
        $r = script:Invoke-Verify2b -Stub @{ TreeNames = $boards; FailBoards = $boards }
        (script:Get-Verdict $r 'F') | Should -Match 'SWEEP CUT SHORT - 3 of 5 boards attempted'
    }

    It 'F says so when -MaxBoards, not a halt, is what stopped the sweep' {
        # -MaxBoards truncates $order before F counts against it, so 'F 2 of 2
        # landed' gave no sign that three canonical boards were never tried.
        $r = script:Invoke-Verify2b -Stub @{ TreeNames = @('b1', 'b2', 'b3', 'b4', 'b5') } `
                                    -Driver @{ MaxBoards = 2 }
        $r.Live.Count | Should -Be 2
        (script:Get-Verdict $r 'F') | Should -Match '-MaxBoards CAPPED the sweep at 2 of 5 canonical boards'
    }

    It 'F does not mention -MaxBoards when it did not bite' {
        $r = script:Invoke-Verify2b -Stub @{ TreeNames = @('b1', 'b2') } -Driver @{ MaxBoards = 9 }
        (script:Get-Verdict $r 'F') | Should -Not -Match 'MaxBoards'
    }

    It 'F does not claim a cut-short sweep when every board was attempted' {
        $r = script:Invoke-Verify2b -Stub @{ TreeNames = @('b1', 'b2') ; CanonicalBoards = @('b1', 'b2') }
        (script:Get-Verdict $r 'F') | Should -Be '2 of 2 attempted selections landed'
    }
}

Describe 'Section E must start from a board that is NOT resident' {
    # This is the single check that decides whether 2b.5 is answered at all. A board
    # already loaded agrees with the caption whatever Select() does, so a sweep that
    # began on the resident board would report Selected=$true having tested nothing.
    It 'moves the resident board to the end of the sweep order' {
        $r = script:Invoke-Verify2b -Stub @{ TreeNames = @('alpha', 'beta', 'gamma'); ResidentBoard = 'alpha' }
        $live = @($r.Rows | ForEach-Object { $_.Board })
        $live[0]  | Should -Be 'beta'
        $live[-1] | Should -Be 'alpha'
        $live.Count | Should -Be 3 -Because 'reordering must not drop or duplicate a board'
    }

    It 'compares ordinally, so a soft-hyphenated caption cannot displace the plain name' {
        # PowerShell's -eq on strings is invariant-culture linguistic: measured,
        # "Sa<U+00AD>ve" -eq "Save" is True. Under a linguistic comparison the
        # caption below would match 'alpha' and push it to the end, starting the
        # sweep on 'beta' for no reason.
        $tricky = 'al' + [string][char]0x00AD + 'pha'
        $r = script:Invoke-Verify2b -Stub @{ TreeNames = @('alpha', 'beta'); ResidentBoard = $tricky }
        @($r.Rows | ForEach-Object { $_.Board })[0] | Should -Be 'alpha'
    }

    It 'compares ordinally for an NFD caption too' {
        $nfd = 'e' + [string][char]0x0301 + 'lement'
        $nfc = [string][char]0x00E9 + 'lement'
        $r = script:Invoke-Verify2b -Stub @{ TreeNames = @($nfc, 'beta'); ResidentBoard = $nfd }
        @($r.Rows | ForEach-Object { $_.Board })[0] | Should -Be $nfc
    }

    It 'moves a resident board that differs only in case, because the match is case-insensitive' {
        $r = script:Invoke-Verify2b -Stub @{ TreeNames = @('alpha', 'beta'); ResidentBoard = 'ALPHA' }
        @($r.Rows | ForEach-Object { $_.Board })[0] | Should -Be 'beta'
    }

    It 'leaves the order untouched when the resident board is not in the list' {
        $r = script:Invoke-Verify2b -Stub @{ TreeNames = @('alpha', 'beta'); ResidentBoard = 'zeta' }
        $live = @($r.Rows | ForEach-Object { $_.Board })
        $live.Count | Should -Be 2
        $live[0] | Should -Be 'alpha'
    }
}

Describe 'The 2b.5 verdict may not outrun its precondition  (round-2 Critical)' {
    # Get-SwdWindowTitle returns $null for THREE did-not-answer states
    # (swd_board.ps1:247-257): deadline hit, no matching window, two or more
    # matching. All arrive as Parsed=$false, which is ALSO what a genuinely
    # different board looks like to AlreadyLoaded. Measured before the fix: the
    # run printed 'A ok' under its own '<caption did not parse>' line, skipped the
    # anti-collision reorder, and headlined '2b.5 CONFIRMED'.
    It 'reports E INCONCLUSIVE, never CONFIRMED, when the caption never answered' {
        $r = script:Invoke-Verify2b -Stub @{ ResidentBoard = $null; Title = $null; TreeNames = @('alpha', 'beta') }
        (script:Get-Verdict $r 'E') | Should -BeLike '2b.5 INCONCLUSIVE*'
        (script:Get-Verdict $r 'E') | Should -Not -BeLike '*CONFIRMED*'
    }

    It 'does not let section A report a plain ok when it could not read the resident board' {
        $r = script:Invoke-Verify2b -Stub @{ ResidentBoard = $null; Title = $null }
        (script:Get-Verdict $r 'A') | Should -Not -Be 'ok'
        (script:Get-Verdict $r 'A') | Should -BeLike '*resident board was NOT read*'
    }

    It 'names the gap in the "does NOT establish" block, which is what a reader scans' {
        $r = script:Invoke-Verify2b -Stub @{ ResidentBoard = $null; Title = $null }
        $r.Log | Should -Match 'NOTHING ABOUT 2b\.5'
    }

    It 'treats a PARSED but EMPTY board name as unread, not as identified' {
        # The same defect one branch over, and the reason Parsed alone is not the
        # precondition. Get-SwdLoadedBoard's regex is '<Board:\s*(?<name>.+?)\(...'
        # followed by .Trim(), so a caption reading '<Board:   (1800.0mm)>' MATCHES:
        # it hands back Parsed = $true with Board = '   '. A whitespace-only string
        # is truthy in PowerShell, so the stub reproduces that state exactly without
        # needing a knob of its own - which is precisely why the driver could not
        # tell this apart from a real identification.
        #
        # Keyed on Parsed alone, the run reported the board as KNOWN, skipped the
        # anti-collision reorder, and could headline '2b.5 CONFIRMED' having never
        # learnt which board was loaded.
        $r = script:Invoke-Verify2b -Stub @{ ResidentBoard = '   '; TreeNames = @('alpha', 'beta') }
        (script:Get-Verdict $r 'A') | Should -Not -Be 'ok'
        (script:Get-Verdict $r 'A') | Should -BeLike '*resident board was NOT read*'
        (script:Get-Verdict $r 'E') | Should -BeLike '2b.5 INCONCLUSIVE*'
        (script:Get-Verdict $r 'E') | Should -Not -BeLike '*CONFIRMED*'
        $r.Log | Should -Match 'NOTHING ABOUT 2b\.5'
    }

    It 'says nothing of the sort when the caption DID answer' {
        # The other direction: the guard must not blanket-suppress a real answer.
        $r = script:Invoke-Verify2b -Stub @{ ResidentBoard = 'resident_board'; TreeNames = @('alpha') }
        (script:Get-Verdict $r 'A') | Should -Be 'ok'
        (script:Get-Verdict $r 'E') | Should -BeLike '2b.5 CONFIRMED*'
        $r.Log | Should -Not -Match 'NOTHING ABOUT 2b\.5'
    }

    It 'trusts section A over AlreadyLoaded when the two disagree about board 1' {
        # AlreadyLoaded is Select-SwdBoard's report from ONE caption read it takes
        # itself; a read that failed there yields $false for a board that WAS
        # resident. Section A observed it independently, so a disagreement means
        # the question was not answered - not that Select() worked.
        $r = script:Invoke-Verify2b -Stub @{
            ResidentBoard = 'alpha'; TreeNames = @('alpha'); AlreadyLoaded = $false }
        (script:Get-Verdict $r 'E') | Should -BeLike '2b.5 INCONCLUSIVE*'
        (script:Get-Verdict $r 'E') | Should -Not -BeLike '*CONFIRMED*'
    }

    It 'does not upgrade off a later board that section A had named as resident' {
        # The $proof block widened the same false CONFIRMED across the whole sweep.
        $r = script:Invoke-Verify2b -Stub @{
            ResidentBoard = 'beta'; TreeNames = @('alpha', 'beta')
            FailBoards = @('alpha'); AlreadyLoaded = $false }
        (script:Get-Verdict $r 'E') | Should -Not -BeLike '*CONFIRMED*'
    }
}

Describe 'The 2b.5 verdict - AlreadyLoaded is what stops a false CONFIRMED' {
    It 'reports INCONCLUSIVE, never CONFIRMED, when the board was already resident' {
        # Deleting the AlreadyLoaded guard turns this into CONFIRMED - the precise
        # false positive the whole script exists to prevent, and a mutant the
        # previous suite did not notice.
        $r = script:Invoke-Verify2b -Stub @{ TreeNames = @('alpha'); AlreadyLoaded = $true }
        (script:Get-Verdict $r 'E') | Should -BeLike '2b.5 INCONCLUSIVE*'
        (script:Get-Verdict $r 'E') | Should -Not -BeLike '*CONFIRMED*'
    }

    It 'reports CONFIRMED when a board that was not resident actually loaded' {
        $r = script:Invoke-Verify2b -Stub @{ TreeNames = @('alpha'); AlreadyLoaded = $false }
        (script:Get-Verdict $r 'E') | Should -BeLike '2b.5 CONFIRMED*'
    }

    It 'reports FAILED, not CONFIRMED, when nothing landed at all' {
        $r = script:Invoke-Verify2b -Stub @{ TreeNames = @('alpha'); FailBoards = @('alpha') }
        (script:Get-Verdict $r 'E') | Should -BeLike '2b.5 FAILED*'
    }

    It 'still answers 2b.5 from a later board when the first one failed' {
        # The verdict used to be bound to $index -eq 1, so a first board that failed
        # for its own reasons discarded an answer the sweep had already produced -
        # and getting it again costs another supervised session.
        $r = script:Invoke-Verify2b -Stub @{ TreeNames = @('alpha', 'beta', 'gamma'); FailBoards = @('alpha') }
        (script:Get-Verdict $r 'E') | Should -BeLike '2b.5 CONFIRMED*'
        (script:Get-Verdict $r 'E') | Should -BeLike '*not the first*'
    }

    It 'does not upgrade to CONFIRMED off a board that was already resident' {
        $r = script:Invoke-Verify2b -Stub @{
            TreeNames = @('alpha', 'beta'); AlreadyLoaded = $true; FailBoards = @() }
        (script:Get-Verdict $r 'E') | Should -Not -BeLike '*CONFIRMED*'
    }
}

Describe 'Get-UnexpectedDialog - the gate that halts the sweep  (SQA W7)' {
    # Exercised through the real function with -Record, not by re-implementing its
    # expressions in the test. Three seeded mutants survived the inline version:
    # inverting the class test, forcing the visibility test, and making the filter
    # permanently blind.
    It 'reports a visible #32770 as a dialog' {
        $r = Get-UnexpectedDialog -Record @(script:New-TopLevelRecord -Handle 4242)
        $r.Count | Should -Be 1
        $r[0].Handle | Should -Be 4242
        $r[0].Why | Should -Be 'dialog-class'
    }

    It 'does NOT report an invisible #32770' {
        # A hidden window is not a modal in front of the operator. Forcing the
        # visibility test either way is caught by this test and the one above.
        $r = Get-UnexpectedDialog -Record @(script:New-TopLevelRecord -Handle 4242 -Visible $false)
        $r.Count | Should -Be 0
    }

    It 'does NOT report an ordinary visible window that was already there' {
        $known = @{ [int64]77 = 'WindowsForms10.Window.8' }
        $r = Get-UnexpectedDialog -KnownHandle $known -Record @(
            script:New-TopLevelRecord -Handle 77 -Class 'WindowsForms10.Window.8')
        $r.Count | Should -Be 0
    }

    It 'reports a NEW visible window of any class, not just #32770  (W7)' {
        # SCAN-FLOW.md s1 lists THREE dialogs IN TOTAL - not four - and the third
        # of them, the duration confirmation, has never been read from the live
        # control, so the class is confirmed for TWO. A modal of any other class
        # used to read as clear.
        $known = @{ [int64]77 = 'WindowsForms10.Window.8' }
        $r = Get-UnexpectedDialog -KnownHandle $known -Record @(
            (script:New-TopLevelRecord -Handle 77 -Class 'WindowsForms10.Window.8'),
            (script:New-TopLevelRecord -Handle 88 -Class 'SomeOtherModalClass'))
        $r.Count | Should -Be 1
        $r[0].Handle | Should -Be 88
        $r[0].Why | Should -Be 'new-window'
    }

    It 'still reports a #32770 that was open at preflight' {
        # Both rules are independent: being in the baseline does not launder a modal.
        $known = @{ [int64]4242 = '#32770' }
        $r = Get-UnexpectedDialog -KnownHandle $known -Record @(script:New-TopLevelRecord -Handle 4242)
        $r.Count | Should -Be 1
    }

    It 'applies only the class rule when no baseline is supplied' {
        $r = Get-UnexpectedDialog -Record @(
            script:New-TopLevelRecord -Handle 55 -Class 'WindowsForms10.Window.8')
        $r.Count | Should -Be 0
    }

    It 'reports a malformed record as unreadable rather than skipping it' {
        # An unparseable record is not evidence of no dialog. Get-SwdDialog throws
        # on one; this gate runs after Select() has acted, so it reports instead.
        $r = Get-UnexpectedDialog -Record @('only' + [SwdWin]::SEP + 'two')
        $r.Count | Should -Be 1
        $r[0].Why | Should -Be 'unreadable'
    }

    It 'distinguishes an unreadable record from a modal in the preflight halt text' {
        # Both halt, but a modal is dismissed by hand and an unparseable record has
        # nothing on screen to dismiss. 'modal dialog(s) ... handles: -1' sent the
        # operator looking for a window that does not exist.
        $r = Get-UnexpectedDialog -Record @('only' + [SwdWin]::SEP + 'two')
        $r[0].Why | Should -Be 'unreadable'
        $r[0].Handle | Should -Be -1
    }

    It 'refuses a non-positive pid rather than enumerating the whole desktop' {
        # [SwdWin]::TopLevelForPid throws on pid 0 - the value
        # GetWindowThreadProcessId leaves behind when it fails. Without that, every
        # top-level window on the machine becomes a dialog candidate.
        { Get-UnexpectedDialog -ProcessId 0 } | Should -Throw
    }

    It 'returns an empty ARRAY, not $null, when the process has no dialogs' {
        # `return ,$out` is what stops an empty array unrolling to $null, at which
        # point .Count throws under StrictMode. An SWD with no modal open is the
        # NORMAL state, so this is the common path, and the one a caller reads as
        # "gate clear". Should -Not -BeNullOrEmpty is the WRONG assertion here: an
        # empty array is legitimately empty. What matters is that it is still an
        # array and that .Count answers instead of throwing.
        $r = Get-UnexpectedDialog -ProcessId ([Diagnostics.Process]::GetCurrentProcess().Id)
        , $r | Should -BeOfType [System.Object[]]
        { $r.Count } | Should -Not -Throw
    }

    It 'takes a preflight baseline of the visible top-level windows' {
        $r = script:Invoke-Verify2b
        $r.Log | Should -Match 'top-level      : \d+ visible window'
    }

    It 'HALTs the whole run when a REAL #32770 is already open on the target pid' {
        # End to end, against a genuine Win32 modal rather than a record fixture:
        # a child powershell raises a MessageBox, the driver is pointed at that
        # pid, and preflight must stop before a single board is selected. This is
        # the one gate that protects a supervised session, so it is exercised
        # against the real window class rather than only against strings.
        $child = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
            "Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show('sqa fixture')")
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $up = $false
            while ($sw.ElapsedMilliseconds -lt 20000 -and -not $up) {
                # ASSIGN, THEN COUNT. Get-UnexpectedDialog ends in `return ,$out`, so
                # @(Get-UnexpectedDialog ...) wraps the array in another array and
                # .Count is 1 whatever it found - measured, this poll passed in 12 ms
                # with no window open at all, and the run below then raced the
                # MessageBox and lost.
                $seen = Get-UnexpectedDialog -ProcessId $child.Id
                $up = $seen.Count -gt 0
                if (-not $up) { Start-Sleep -Milliseconds 200 }
            }
            $up | Should -BeTrue -Because 'the fixture MessageBox must be up before the driver looks'

            $r = script:Invoke-Verify2b -Stub @{ Process = $child }
            $r.Log | Should -Match 'DIALOG         : 1 modal dialog'
            $r.Selected.Count | Should -Be 0 -Because 'nothing may be selected with a modal already open'
        } finally {
            # Force, and in a finally: a fixture that can leave a modal on the
            # operator's screen is worse than no fixture.
            Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
            $child.WaitForExit(5000) | Out-Null
        }
    }
}

Describe 'Target text may not forge the structure of the log  (SQA W4)' {
    It 'escapes a newline so a caption cannot start a line at column 0' {
        # Measured on the real 12:15 log: a control caption whose second physical
        # line began at column 0, typographically identical to a script-emitted line.
        (Show-Target "Board`nFAILED: nothing") | Should -Not -Match "`n"
    }

    It 'renders $null as <null>, distinct from an empty caption' {
        # A timed-out WM_GETTEXT is $null; a control with no caption is ''. Those
        # are different facts and the log must not merge them.
        (Show-Target $null)  | Should -Be '<null>'
        (Show-Target '')     | Should -Not -Be '<null>'
    }

    It 'passes an accented French board name through unchanged' {
        $name = [string][char]0x00E9 + 'lement_test'
        (Show-Target $name) | Should -Be $name
    }

    It 'cuts over-length text rather than letting one caption flood the log' {
        (Show-Target ('x' * 500) 40).Length | Should -BeLessOrEqual 60
    }

    It 'writes one physical line per Write-Line even when the caption carries a CR' {
        # Get-SwdLoadedBoard's regex (swd_board.ps1:296) uses '.', which matches CR
        # in .NET, so a board name carrying \r parses and used to reach the
        # 'resident was' line raw. Measured on the pre-fix driver: one call produced
        # TWO physical lines, the second reading 'changed        : none' - byte
        # identical to section G's own conclusion further down the same file.
        $evil = "shortboard`rchanged        : none"
        $r = script:Invoke-Verify2b -Stub @{ ResidentBoard = $evil }
        $lone = ([regex]::Matches($r.Log, "`r(?!`n)")).Count
        $lone | Should -Be 0 -Because 'a lone CR is a forged line break'
        $r.Log | Should -Match 'resident was   : shortboard\\r'
    }

    It 'escapes a tree name carrying a CR before it reaches the missing/extra lines' {
        $evil = "ghost`rHALT           : nothing is wrong"
        $r = script:Invoke-Verify2b -Stub @{ TreeNames = @('alpha', $evil); CanonicalBoards = @('alpha') }
        ([regex]::Matches($r.Log, "`r(?!`n)")).Count | Should -Be 0
    }

    It 'escapes the -BoardsCsv path, the one log sink that used to bypass Show-Target' {
        # Operator-supplied rather than SWD-supplied, so there is no attacker path -
        # but the file claims every value reaching a log line is escaped, and a
        # CR+LF in a pasted path forges a well-formed second line all the same.
        $evil = "C:\nosuch`r`nHALT           : forged by a pasted path\b.csv"
        $r = script:Invoke-Verify2b -Driver @{ BoardsCsv = $evil }
        ([regex]::Matches($r.Log, "`r(?!`n)")).Count | Should -Be 0
        # Asserted on structure rather than on the exact escape spelling: the
        # encoding also DOUBLES backslashes so it stays reversible, so pinning the
        # literal would be testing ConvertTo-SwdSafeText's private format.
        $r.Log | Should -Match 'forged by a pasted path' -Because 'the text must really have reached the log'
        $r.Log | Should -Not -Match '(?m)^HALT           : forged' -Because 'and it must not have started a line'
    }

    It 'escapes an exception message before it reaches the SUMMARY block' {
        # $verdict entries used to store the raw message and the summary printed it
        # unescaped, so the section body was escaped and the summary was not.
        $evil = "boom`r  G  no library file changed during this run"
        $r = script:Invoke-Verify2b -Stub @{ ProcessThrows = $true; ProcessThrowMessage = $evil }
        ([regex]::Matches($r.Log, "`r(?!`n)")).Count | Should -Be 0
    }
}

Describe 'Artefact encoding - a BOM breaks the Python readers downstream' {
    It 'Save-Text writes UTF-8 with NO byte-order mark' {
        $p = Join-Path $script:Sandbox 'plain.txt'
        Save-Text -Path $p -Content @('alpha', 'beta')
        $bytes = [IO.File]::ReadAllBytes($p)
        # EF BB BF is the UTF-8 BOM; FF FE is the UTF-16LE one Out-File emits on 5.1.
        $bytes[0] | Should -Not -Be 0xEF
        $bytes[0] | Should -Not -Be 0xFF
        [IO.File]::ReadAllText($p) | Should -Match 'alpha'
    }

    It 'Save-Csv writes UTF-8 with no BOM and a real header' {
        $p = Join-Path $script:Sandbox 'rows.csv'
        $null = Save-Csv -Path $p -Rows @([pscustomobject]@{ A = 1; B = 'x' }) -Columns @('A', 'B')
        [IO.File]::ReadAllBytes($p)[0] | Should -Not -Be 0xEF
        $back = Import-Csv -LiteralPath $p
        $back.A | Should -Be '1'
        $back.B | Should -Be 'x'
    }

    It 'Save-Csv still writes a header row when there is nothing to record' {
        # A halted run produces zero rows. A zero-byte file is indistinguishable
        # from a crashed one; a header-only file says "we looked and found none".
        # The header is quoted exactly as it is when rows are present: one file
        # family with two header shapes is what a naive reader trips over.
        $p = Join-Path $script:Sandbox 'empty.csv'
        $null = Save-Csv -Path $p -Rows @() -Columns @('Index', 'Board')
        (Get-Content -LiteralPath $p -Raw).Trim() | Should -Be '"Index","Board"'
    }

    It 'Save-Csv emits the columns in the order asked for, not alphabetically' {
        $p = Join-Path $script:Sandbox 'order.csv'
        $null = Save-Csv -Path $p -Rows @([pscustomobject]@{ Zulu = 1; Alpha = 2 }) -Columns @('Zulu', 'Alpha')
        (Get-Content -LiteralPath $p)[0] | Should -Be '"Zulu","Alpha"'
    }

    It 'Save-Csv tolerates a row that is missing a requested column' {
        $p = Join-Path $script:Sandbox 'sparse.csv'
        $null = Save-Csv -Path $p -Rows @([pscustomobject]@{ A = 1 }) -Columns @('A', 'B')
        (Import-Csv -LiteralPath $p).B | Should -Be ''
    }
}

Describe 'CSV formula injection - quoting is not neutralisation  (SQA W5)' {
    It 'neutralises every leading character a spreadsheet would evaluate' {
        $hostile = @('=cmd|''/c calc''!A1', '+1+1', '-2+3', '@SUM(A1)', "`tlead", "`rlead", "`nlead", "'lead")
        $p = Join-Path $script:Sandbox ('inj-' + [guid]::NewGuid().ToString('N') + '.csv')
        $rows = @($hostile | ForEach-Object { [pscustomobject]@{ Name = $_ } })
        $n = Save-Csv -Path $p -Rows $rows -Columns @('Name') -TextColumns @('Name')
        $n | Should -Be $hostile.Count
        foreach ($cell in (Import-Csv -LiteralPath $p).Name) {
            $cell[0] | Should -Be "'" -Because 'a spreadsheet must see literal text'
        }
    }

    It 'leaves ordinary text alone' {
        $p = Join-Path $script:Sandbox ('plain-' + [guid]::NewGuid().ToString('N') + '.csv')
        $n = Save-Csv -Path $p -Rows @([pscustomobject]@{ Name = 'default_shortboard' }) -Columns @('Name') -TextColumns @('Name')
        $n | Should -Be 0
        (Import-Csv -LiteralPath $p).Name | Should -Be 'default_shortboard'
    }

    It 'never touches a numeric column, because an apostrophe there is corruption' {
        # swd_diagnose.ps1 records the same choice: this project already has a
        # virtual desktop with a negative origin, so prefixing every negative
        # number would break the readers it is meant to protect.
        $p = Join-Path $script:Sandbox ('num-' + [guid]::NewGuid().ToString('N') + '.csv')
        $null = Save-Csv -Path $p -Rows @([pscustomobject]@{ Name = 'ok'; LengthMm = -1800.5 }) `
                        -Columns @('Name', 'LengthMm') -TextColumns @('Name')
        (Import-Csv -LiteralPath $p).LengthMm | Should -Be '-1800.5'
    }

    It 'neutralises a hostile board name in the real run artefact' {
        $r = script:Invoke-Verify2b -Stub @{
            TreeNames = @('=HYPERLINK("http://x","click")') ; CanonicalBoards = @('=HYPERLINK("http://x","click")') }
        $r.Rows.Count | Should -Be 1
        $r.Rows[0].Board[0] | Should -Be "'"
        $r.Log | Should -Match 'csv injection  : \d+ cell'
    }

    It 'keeps every hostile value readable end to end' {
        # Escaping must be reversible or it is data loss dressed as safety: the
        # reader's contract is "strip ONE leading apostrophe".
        $hostile = @('=x', '+x', '-x', '@x', "'x", 'plain', 'a,b', 'a"b')
        $p = Join-Path $script:Sandbox ('rt-' + [guid]::NewGuid().ToString('N') + '.csv')
        $null = Save-Csv -Path $p -Rows @($hostile | ForEach-Object { [pscustomobject]@{ Name = $_ } }) `
                        -Columns @('Name') -TextColumns @('Name')
        $back = @((Import-Csv -LiteralPath $p).Name | ForEach-Object {
            if ($_.StartsWith("'")) { $_.Substring(1) } else { $_ } })
        $back | Should -Be $hostile
    }
}

Describe 'Get-BoardHash - the evidence for "did selecting a board write to disk?"' {
    BeforeAll {
        $script:Lib = Join-Path $script:Sandbox 'lib'
        [void][IO.Directory]::CreateDirectory((Join-Path $script:Lib 'ShortBoards'))
        Set-Content -LiteralPath (Join-Path $script:Lib 'root.fynbs') -Value 'aaa' -NoNewline
        Set-Content -LiteralPath (Join-Path $script:Lib 'ShortBoards\nested.fynbs') -Value 'bbb' -NoNewline
        Set-Content -LiteralPath (Join-Path $script:Lib 'notaboard.txt') -Value 'ccc' -NoNewline
    }

    It 'recurses into folders, because 23 of the 29 boards live in subfolders' {
        $h = Get-BoardHash -Root $script:Lib
        @($h).Count | Should -Be 2
    }

    It 'hashes only .fynbs' {
        $h = Get-BoardHash -Root $script:Lib
        @($h | Where-Object { $_.Rel -like '*notaboard*' }).Count | Should -Be 0
    }

    It 'uses forward slashes so a manifest is comparable across runs' {
        $h = Get-BoardHash -Root $script:Lib
        @($h | Where-Object { $_.Rel -eq 'ShortBoards/nested.fynbs' }).Count | Should -Be 1
    }

    It 'changes the hash when a byte changes, and not otherwise' {
        $first = Get-BoardHash -Root $script:Lib
        $again = Get-BoardHash -Root $script:Lib
        ($first | Where-Object { $_.Rel -eq 'root.fynbs' }).Sha256 |
            Should -Be ($again | Where-Object { $_.Rel -eq 'root.fynbs' }).Sha256

        Set-Content -LiteralPath (Join-Path $script:Lib 'root.fynbs') -Value 'aab' -NoNewline
        $after = Get-BoardHash -Root $script:Lib
        ($after | Where-Object { $_.Rel -eq 'root.fynbs' }).Sha256 |
            Should -Not -Be ($first | Where-Object { $_.Rel -eq 'root.fynbs' }).Sha256
    }

    It 'returns an array even for an empty library' {
        $empty = Join-Path $script:Sandbox 'emptylib'
        [void][IO.Directory]::CreateDirectory($empty)
        $r = Get-BoardHash -Root $empty
        @($r).Count | Should -Be 0
    }

    It 'records an unreadable file instead of aborting the whole baseline' {
        # This runs from section A, before anything has been measured, over a
        # cloud-synced library. One IO exception used to escape into section A's
        # catch and halt the entire supervised session at preflight.
        $lockDir = Join-Path $script:Sandbox 'locklib'
        [void][IO.Directory]::CreateDirectory($lockDir)
        Set-Content -LiteralPath (Join-Path $lockDir 'ok.fynbs') -Value 'aaa' -NoNewline
        $lockedPath = Join-Path $lockDir 'locked.fynbs'
        Set-Content -LiteralPath $lockedPath -Value 'bbb' -NoNewline
        $fs = [IO.File]::Open($lockedPath, 'Open', 'Read', 'None')
        try {
            # NOT @(Get-BoardHash ...): the function ends in `return ,$out`, so
            # wrapping the CALL gives a one-element array holding the array.
            $h = Get-BoardHash -Root $lockDir
            @($h).Count | Should -Be 2
            ($h | Where-Object { $_.Rel -eq 'ok.fynbs' }).Sha256 | Should -Not -BeNullOrEmpty
            ($h | Where-Object { $_.Rel -eq 'locked.fynbs' }).Sha256 | Should -BeNullOrEmpty
            ($h | Where-Object { $_.Rel -eq 'locked.fynbs' }).ReadError | Should -Not -BeNullOrEmpty
        } finally { $fs.Dispose() }
    }
}

Describe 'A -LogDir inside the repository leaks into a commit  (SQA W6)' {
    # Measured 2026-09-02: git check-ignore returns NO MATCH for
    # SWD/tools/phase2/run1/*-2b-boards.csv, -menu.csv and -hashes.csv, and outside
    # phase2/ even the .log is tracked. The log carries the library path - operator
    # username and OneDrive tenant. Repo rule R9.
    It 'refuses a -LogDir inside the working tree but outside phase2\logs' {
        $inRepo = Join-Path $script:Phase2 ('sqa-scratch-' + [guid]::NewGuid().ToString('N'))
        { & $script:Driver -DotSourceOnly -LogDir $inRepo } |
            Should -Throw '*inside the git working tree*'
        Test-Path -LiteralPath $inRepo | Should -BeFalse -Because 'a refused run must not create the directory'
    }

    It 'refuses a repository path reached through a relative spelling' {
        $sneaky = Join-Path $script:Phase2 ('logs\..\sqa-scratch-' + [guid]::NewGuid().ToString('N'))
        { & $script:Driver -DotSourceOnly -LogDir $sneaky } |
            Should -Throw '*inside the git working tree*'
    }

    It 'accepts the default phase2\logs, which .gitignore does cover' {
        { & $script:Driver -DotSourceOnly } | Should -Not -Throw
    }

    It 'accepts a subdirectory of phase2\logs, without creating it' {
        # A unique leaf, asserted absent afterwards, cleaned up in a finally. The
        # first version of this test named a fixed 'logs\run1' and asserted nothing
        # about it - and a mutation run that removed the -DotSourceOnly guard left
        # exactly that directory behind in the working tree. A test that can litter
        # the repository it is protecting is the wrong shape.
        $sub = Join-Path $script:Phase2 ('logs\sqa-' + [guid]::NewGuid().ToString('N'))
        try {
            { & $script:Driver -DotSourceOnly -LogDir $sub } | Should -Not -Throw
            Test-Path -LiteralPath $sub | Should -BeFalse -Because 'dot-sourcing must not create it either'
        } finally {
            if (Test-Path -LiteralPath $sub) { Remove-Item -LiteralPath $sub -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'accepts a directory outside the repository' {
        { & $script:Driver -DotSourceOnly -LogDir $script:Sandbox } | Should -Not -Throw
    }

    It 'refuses a -LogDir inside a DIFFERENT git working tree' {
        # THE ROUND-2 REGRESSION, and the case the first W6 Describe omitted: the
        # containment root was walked up from $ScriptDir, so the question asked was
        # "is this inside MY repo", and any other working tree on the machine took
        # all four artefacts tracked. There is more than one on this machine.
        $foreign = Join-Path $script:Sandbox ('foreignrepo-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($foreign)
        & git -C $foreign init -q 2>&1 | Out-Null
        Test-Path -LiteralPath (Join-Path $foreign '.git') | Should -BeTrue -Because 'the fixture must really be a repo'
        { & $script:Driver -DotSourceOnly -LogDir (Join-Path $foreign 'leak') } |
            Should -Throw '*inside the git working tree*'
        { & $script:Driver -DotSourceOnly -LogDir $foreign } |
            Should -Throw '*inside the git working tree*'
    }

    It 'refuses the repository reached through an 8.3 short name' {
        # Lexical prefix tests are defeated by 8.3, which this project has already
        # measured twice. Verified live: HYDROD~1 resolves on this volume.
        $fso = New-Object -ComObject Scripting.FileSystemObject
        $short = $fso.GetFolder($script:Phase2).ShortPath
        $short | Should -Not -Be $script:Phase2 -Because '8.3 must really be in play for this to test anything'
        { & $script:Driver -DotSourceOnly -LogDir (Join-Path $short 'sqa-8dot3-probe') } |
            Should -Throw '*inside the git working tree*'
    }

    It 'refuses a junction that points back into the repository' {
        $link = Join-Path $script:Sandbox ('junc-' + [guid]::NewGuid().ToString('N'))
        $made = $null
        try {
            $made = New-Item -ItemType Junction -Path $link -Target $script:Phase2 -ErrorAction Stop
            { & $script:Driver -DotSourceOnly -LogDir (Join-Path $link 'sqa-junction-probe') } |
                Should -Throw '*inside the git working tree*'
        } finally {
            if ($made) { [IO.Directory]::Delete($link) }
        }
    }

    It 'still refuses the SWD library and install, which is a different rule' {
        { & $script:Driver -DotSourceOnly -LogDir 'C:\Program Files\ShaperWaveDynamics\logs' } |
            Should -Throw '*not a permitted output directory*'
    }
}

Describe 'Path containment - the comparison every guard here depends on' {
    It 'treats a path as under its own root' {
        Test-PathAtOrUnder -Path 'C:\a\b' -Root 'C:\a' | Should -BeTrue
    }

    It 'treats a root as at itself, trailing separator or not' {
        Test-PathAtOrUnder -Path 'C:\a' -Root 'C:\a\'  | Should -BeTrue
        Test-PathAtOrUnder -Path 'C:\a\' -Root 'C:\a'  | Should -BeTrue
    }

    It 'ignores case, the way the filesystem does' {
        Test-PathAtOrUnder -Path 'C:\A\B' -Root 'c:\a' | Should -BeTrue
    }

    It 'does not treat a sibling with a shared prefix as inside' {
        # 'C:\repo-backup' must not read as being inside 'C:\repo'.
        Test-PathAtOrUnder -Path 'C:\repo-backup\x' -Root 'C:\repo' | Should -BeFalse
    }

    It 'answers false rather than throwing on a null or empty side' {
        Test-PathAtOrUnder -Path $null   -Root 'C:\a' | Should -BeFalse
        Test-PathAtOrUnder -Path 'C:\a'  -Root ''     | Should -BeFalse
    }

    It 'finds the repository root from inside the tree' {
        $root = Get-RepositoryRoot -From $script:Phase2
        $root | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $root '.git') | Should -BeTrue
    }

    It 'returns $null when there is no repository above the path' {
        Get-RepositoryRoot -From ([IO.Path]::GetPathRoot([IO.Path]::GetTempPath())) | Should -BeNullOrEmpty
    }
}

Describe 'Reporting what was not measured' {
    It 'says so in the log when -SkipGeometry blanked the Conf columns' {
        $r = script:Invoke-Verify2b
        $r.Log | Should -Match 'geometry       : SKIPPED'
        $r.Rows[0].GeomReason | Should -Be 'skipped - -SkipGeometry'
    }

    It 'leaves GeomReason empty when geometry really was attempted' {
        $r = script:Invoke-Verify2b -Stub @{
            Geometry = [pscustomobject]@{
                Configuration = [pscustomobject]@{
                    VolumeL = 30.0; LengthMm = 1800.0; WidthMm = 480.0; ThickMm = 62.0
                    LengthOverWidth = 3.75; WidthOverThick = 7.7; LengthOverThick = 29.0 }
                Boxes = @(); Title = 'x'; TitleLengthMm = 1800.0; Homothety = $null; Agree = $true }
        } -Driver @{ SkipGeometry = $false }
        $r.Rows[0].GeomReason | Should -Be ''
        $r.Rows[0].GeomAgree  | Should -Be 'True'
    }

    It 'prints a body line under a section banner that was skipped by a halt' {
        $r = script:Invoke-Verify2b -Driver @{ BoardsCsv = (Join-Path $script:Sandbox 'no-such-file.csv') }
        $r.Log | Should -Match 'skipped        : the run halted before this section'
    }

    It 'names only the artefacts that were actually written' {
        $r = script:Invoke-Verify2b
        $m = [regex]::Match($r.Log, '(?s)artefacts written:(?<list>.*?)finished')
        $m.Success | Should -BeTrue
        $listed = @()
        foreach ($line in ($m.Groups['list'].Value -split "`r`n|`n")) {
            $t = $line.Trim()
            if ($t -and $t -notmatch '^(not written|the section)') { $listed += $t }
        }
        # ASSERTED NON-EMPTY FIRST. Without this the foreach below is satisfied
        # vacuously by an empty list, so the test passed whether or not the driver
        # listed anything at all - it checked a property of nothing.
        $listed.Count | Should -BeGreaterThan 0 -Because 'a completed run writes four artefacts'
        foreach ($t in $listed) {
            Test-Path -LiteralPath $t | Should -BeTrue -Because "$t was listed as written"
        }
    }

    It 'hashes the library -LibraryRoot names, not the one in Documents' {
        # Without this the seam could be ignored entirely and every test would
        # still pass - while quietly reading the real 48 MB library 49 times.
        $r = script:Invoke-Verify2b
        $r.Log | Should -Match 'library        : .+\(from -LibraryRoot\)'
        $r.Log | Should -Match 'hashed         : 2 \.fynbs'
    }

    It 'runs the real library exactly once, and ASSERTS on what section G concluded' {
        # The other 40-odd runs point -LibraryRoot at a small fake. This one uses
        # the real library, because section G's whole claim is about that tree -
        # and it asserts the conclusion, which none of the previous 38 real-library
        # reads ever did. Read-only: nothing here selects a board.
        $r = script:Invoke-Verify2b -Driver @{ LibraryRoot = $null; CensusOnly = $true }
        $r.Log | Should -Match 'library        : .+\(from Documents\)'
        (script:Get-Verdict $r 'G') | Should -Be 'no library file changed during this run'
        $r.Log | Should -Match 'changed        : none'
    }
}
