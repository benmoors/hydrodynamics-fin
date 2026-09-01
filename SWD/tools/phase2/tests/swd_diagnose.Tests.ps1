<#
    Pester 6.x tests for swd_diagnose.ps1.  Round-3 finding W2.

    THE GAP THIS CLOSES. swd_diagnose.ps1 had ZERO automated coverage: the suite
    dot-sourced only swd_msg.ps1, so 639 lines - including two headline fixes -
    were verified by reading. A combined revert re-introducing the Section F
    self-contradiction AND the W4 stale-map regression passed the whole suite at
    155/155. The green-suite-that-does-not-bite failure mode had migrated out of
    the library into the untested script.

    HOW. The script is a script, not a module, so it is DRIVEN rather than
    dot-sourced, and the assertions are on the log it emits. Two contexts:

      1. SWD absent - the honest default state. Covers argument handling, the
         CLAUDE.md section 4 refusals, encoding, and the skip reporting. This is
         the context that would have caught the New-Item -LiteralPath regression,
         which threw on the first run into a log directory that did not exist.
      2. Against a THROWAWAY WinForms target, with Get-SwdProcess re-pointed in a
         STAGED COPY under $TestDrive. Nothing in the repository is modified and
         SWD is never contacted - it is not running, and nothing here launches it.

    RUN WITH SWD CLOSED.
#>

BeforeAll {
    $script:Phase2   = Split-Path -Parent $PSScriptRoot
    $script:Diagnose = Join-Path $script:Phase2 'swd_diagnose.ps1'
    $script:MsgLib   = Join-Path $script:Phase2 'swd_msg.ps1'
    foreach ($f in $script:Diagnose, $script:MsgLib) {
        if (-not (Test-Path -LiteralPath $f)) { throw "Cannot find $f" }
    }
    if (Get-Process SurfHydrodynamics -ErrorAction SilentlyContinue) {
        throw 'SurfHydrodynamics is RUNNING. These tests must never be pointed at it - close it first.'
    }

    function Invoke-Diagnose {
        <# Runs a diagnostic under Windows PowerShell 5.1 and returns the log it
           wrote, plus the raw bytes so encoding can be asserted. #>
        param([string]$Script, [string]$LogDir, [string[]]$ExtraArgs = @())
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script,
               '-SkipCursorTest', '-LogDir', $LogDir) + $ExtraArgs
        $out = & powershell.exe @a 2>&1 | Out-String
        $log = Get-ChildItem -LiteralPath $LogDir -Filter '*-diagnose.log' -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
        [pscustomobject]@{
            Console = $out
            LogPath = $(if ($log) { $log.FullName } else { $null })
            Text    = $(if ($log) { [IO.File]::ReadAllText($log.FullName) } else { '' })
            Bytes   = $(if ($log) { [IO.File]::ReadAllBytes($log.FullName) } else { @() })
        }
    }

    function Get-ShortPath {
        param([string]$Path)
        $sb = New-Object System.Text.StringBuilder 512
        if ([SwdDiagTest.Sh]::GetShortPathNameW($Path, $sb, 512) -eq 0) { return $null }
        $sb.ToString()
    }
    # A HERE-STRING, not a plain quoted one. This is the only deliberate
    # multi-line string literal in the suite, and leaving it as '...' would
    # force the source-hygiene check in swd_msg.Tests.ps1 to carry an exception
    # list - which is exactly where a real broken-quote defect would hide.
    Add-Type -Namespace SwdDiagTest -Name Sh -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern uint GetShortPathNameW(string lpszLongPath, System.Text.StringBuilder lpszShortPath, uint cchBuffer);
'@
}

Describe 'swd_diagnose.ps1 with SWD absent' {
    BeforeAll {
        $script:LogDir = Join-Path $TestDrive 'never-created-yet\logs'
        # deliberately NOT pre-created: the script must make it
        $script:Run = Invoke-Diagnose -Script $script:Diagnose -LogDir $script:LogDir
    }

    It 'creates a log directory that did not exist, and runs through to the Summary' {
        # THE REGRESSION THIS CATCHES. Round 2 changed New-Item -Path to
        # -LiteralPath; New-Item has no such parameter in EITHER host, so the
        # very first run into a fresh directory threw before section A. Every
        # smoke test had pre-created the directory, so nothing noticed.
        Test-Path -LiteralPath $script:LogDir | Should -BeTrue
        $script:Run.LogPath | Should -Not -BeNullOrEmpty
        $script:Run.Text | Should -BeLike '*=== Summary ===*'
        $script:Run.Console | Should -Not -BeLike '*ParameterBindingException*'
    }

    It 'writes the log as UTF-8 with NO BOM' {
        # CLAUDE.md section 5: a BOM breaks the Python readers downstream, and
        # Tee-Object/Out-File both write UTF-16LE under 5.1.
        $b = $script:Run.Bytes
        $b.Length | Should -BeGreaterThan 0
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should -BeFalse
        ($b[0] -eq 0xFF -and $b[1] -eq 0xFE) | Should -BeFalse
        $b[0] | Should -Be 0x53      # 'S' of "SWD Phase 2 diagnostic"
    }

    It 'emits every section header, so a truncated run is visible' {
        foreach ($h in 'A. Host', 'B. SWD process and integrity', 'C. Residual input block',
                       'D. UI Automation tree', 'E. Win32 child windows',
                       'F. Unfocused BM_CLICK probe', 'Summary') {
            $script:Run.Text | Should -BeLike "*=== $h ===*"
        }
    }

    It 'reports skipped sections as NOT CHECKED rather than as success' {
        # "all sections completed" used to print whenever nothing THREW, including
        # a run where C, D, E and F all skipped without measuring anything.
        $script:Run.Text | Should -BeLike '*SECTIONS NOT CHECKED (skipped, not passing)*'
        $script:Run.Text | Should -Not -BeLike '*all sections completed*'
    }

    It 'does not write the account IDENTITY into the log' {
        # S25. The log also carries the board name and surfer mass; $elev plus
        # the integrity SID answer every question section A asks.
        #
        # The assertion is on the section-A 'user' FIELD, not on the username
        # appearing anywhere: the log path itself is under the user profile, so a
        # blanket search for $env:USERNAME matches a line that is not an identity
        # disclosure at all. The first version of this test did exactly that and
        # failed on its own log header.
        $script:Run.Text | Should -Not -Match '(?m)^user +:'
        $script:Run.Text | Should -BeLike '*own integrity*'
    }

    It 'does not claim to have written a control map' {
        $script:Run.Text | Should -Not -BeLike '*control map -> *'
    }

    It 'skips section F rather than pretending it measured anything' {
        # With SWD absent, F cannot run at all. The "NOT RUN - no -ClickProbe"
        # guidance lives on a DIFFERENT branch, reachable only when a target
        # exists; asserting it here was simply wrong about control flow, and it
        # is covered in the target context instead.
        $script:Run.Text | Should -BeLike '*=== F. Unfocused BM_CLICK probe ===*skipped - SWD not running*'
    }

    It 'refuses a -LogDir inside <label> before creating anything' -ForEach @(
        @{ label = 'the SWD install';             kind = 'install' }
        @{ label = 'the SWD install spelled 8.3'; kind = 'install83' }
        @{ label = 'the SWD library';             kind = 'library' }
    ) {
        # CLAUDE.md section 4, enforced at the consumer. The 8.3 case is round
        # 3's Critical seen from the caller's side: the guard passed it and the
        # script then ran a directory create on the string it was handed.
        $inst = Join-Path $env:ProgramFiles 'ShaperWaveDynamics'
        $lib  = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'ShaperWaveDynamics documents'
        $target = switch ($kind) {
            'install'   { if (Test-Path -LiteralPath $inst) { Join-Path $inst 'swd-test-logs' } else { $null } }
            'library'   { if (Test-Path -LiteralPath $lib)  { Join-Path $lib  'swd-test-logs' } else { $null } }
            'install83' {
                if (-not (Test-Path -LiteralPath $inst)) { $null }
                else {
                    $s = Get-ShortPath $inst
                    if ($s -and $s -ne $inst) { Join-Path $s 'swd-test-logs' } else { $null }
                }
            }
        }
        if (-not $target) { Set-ItResult -Skipped -Because 'that protected path or its 8.3 alias is unavailable here'; return }

        $r = Invoke-Diagnose -Script $script:Diagnose -LogDir $target
        $r.Console | Should -BeLike '*Refusing to run*'
        $r.LogPath | Should -BeNullOrEmpty
        Test-Path -LiteralPath $target | Should -BeFalse   # and nothing was created
    }
}

Describe 'swd_diagnose.ps1 section F against a throwaway WinForms target' {
    BeforeAll {
        # Stage COPIES. The repository is never modified, and the only edit is to
        # the seam every live-application function routes through.
        $script:Stage = Join-Path $TestDrive 'stage'
        [void][IO.Directory]::CreateDirectory($script:Stage)
        Copy-Item -LiteralPath $script:MsgLib   -Destination $script:Stage
        Copy-Item -LiteralPath $script:Diagnose -Destination $script:Stage
        $script:StagedDiag = Join-Path $script:Stage 'swd_diagnose.ps1'
        $staged = Join-Path $script:Stage 'swd_msg.ps1'

        $targetPs = Join-Path $TestDrive 'ftarget.ps1'
        Set-Content -LiteralPath $targetPs -Encoding ASCII -Value @(
            'Add-Type -AssemblyName System.Windows.Forms'
            'Add-Type -AssemblyName System.Drawing'
            '$f = New-Object System.Windows.Forms.Form'
            "`$f.Text = 'SWD-F-TARGET'"
            "`$f.StartPosition = 'Manual'"
            '$f.Location = New-Object System.Drawing.Point(-32000, -32000)'
            '$b = New-Object System.Windows.Forms.Button'
            "`$b.Text = 'clicks 0'; `$b.Width = 160; `$f.Controls.Add(`$b)"
            '$script:n = 0'
            '$b.Add_Click({ $script:n++; $b.Text = "clicks $script:n" })'
            # SLOW blocks the target pump from INSIDE its click handler for longer
            # than Invoke-SwdButton's 5000 ms send timeout, which is the only way
            # to make section F's lastError=1460 branch fire deterministically.
            # It is the exact shape of SWD's scan button opening a modal.
            '$s = New-Object System.Windows.Forms.Button'
            '$s.Text = "SLOW 0"; $s.Width = 160; $s.Top = 40; $f.Controls.Add($s)'
            '$script:m = 0'
            '$s.Add_Click({ [System.Threading.Thread]::Sleep(8000); $script:m++; $s.Text = "SLOW $script:m" })'
            '[System.Windows.Forms.Application]::Run($f)'
        )
        # -WindowStyle Hidden goes to powershell.exe, never to Start-Process: as a
        # Start-Process parameter it sets SW_HIDE in the STARTUPINFO, WinForms
        # honours that for the first form, and MainWindowHandle - which only
        # returns VISIBLE top-level windows - then stays 0 forever.
        $script:FTarget = Start-Process powershell.exe -PassThru -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', $targetPs)
        $h = 0
        for ($i = 0; $i -lt 80 -and $h -eq 0; $i++) {
            Start-Sleep -Milliseconds 250
            $h = (Get-Process -Id $script:FTarget.Id -ErrorAction Stop).MainWindowHandle
        }
        if ($h -eq 0) { throw 'throwaway target never produced a visible window' }

        $src = [IO.File]::ReadAllText($staged)
        $seam = '    $p = Get-Process SurfHydrodynamics -ErrorAction SilentlyContinue'
        if (-not $src.Contains($seam)) { throw 'Get-SwdProcess seam not found in the staged copy' }
        [IO.File]::WriteAllText($staged, $src.Replace($seam,
            "    `$p = Get-Process -Id $($script:FTarget.Id) -ErrorAction SilentlyContinue   # TEST STAGE: throwaway target, NOT SWD"))

        . $staged
        $script:BtnH = (Get-SwdControl | Where-Object { $_.Text -like 'clicks*' } | Select-Object -First 1).Handle
        if (-not $script:BtnH) { throw 'could not find the target button' }
        $script:SlowH = (Get-SwdControl | Where-Object { $_.Text -like 'SLOW*' } | Select-Object -First 1).Handle
        if (-not $script:SlowH) { throw 'could not find the SLOW button' }

        $script:FLog = Join-Path $TestDrive 'flogs'
        $script:FRun = Invoke-Diagnose -Script $script:StagedDiag -LogDir $script:FLog `
                                       -ExtraArgs @('-ClickProbe', "$($script:BtnH)")
    }

    AfterAll {
        if ($script:FTarget) { Stop-Process -Id $script:FTarget.Id -Force -ErrorAction SilentlyContinue }
    }

    It 'takes a FRESH before-snapshot and reports the measurement window' {
        # W4. Reusing section E's map put the CSV write, all of E's logging and
        # two state probes inside the window, so a self-updating control read as
        # CHANGED - and inside the probe's parent group, as "THE CLICK LANDED".
        $script:FRun.Text | Should -BeLike '*before read   : text read for*snapshot took * ms*'
        # the log line must sit OUTSIDE the window it describes
        $script:FRun.Text.IndexOf('before read   :') | Should -BeLessThan $script:FRun.Text.IndexOf('measurement window:')
        $script:FRun.Text | Should -BeLike '*measurement window:*ms from the BEFORE snapshot to the AFTER snapshot*'
    }

    It 'detects the click by diffing the whole control map' {
        $script:FRun.Text | Should -BeLike '*map diff      : *'
        $script:FRun.Text | Should -BeLike "*'clicks 0' -> 'clicks 1'*"
        $script:FRun.Text | Should -BeLike '*onTarget=True*'
    }

    It 'does NOT claim the unfocused case when -Activate was used' {
        # Section F's self-contradiction: it printed "THE CLICK LANDED WITHOUT
        # FOCUS" directly beneath "SWD focused   : True", with its own warning
        # above it ignored. The conclusion has to CARRY the caveat, not sit near
        # it.
        #
        # Driven with -Activate rather than by waiting for the target to happen
        # to hold the foreground. A first version branched on the observed focus
        # state and was therefore FLAKY BY DESIGN: on a run where the target did
        # not hold focus it asserted the opposite thing and a revert of the fix
        # sailed through. -Activate makes the caveat branch fire deterministically.
        $act = Invoke-Diagnose -Script $script:StagedDiag -LogDir (Join-Path $TestDrive 'actlogs') `
                               -ExtraArgs @('-ClickProbe', "$($script:BtnH)", '-Activate')
        $act.Text | Should -BeLike '*activateAsked=True*'
        $act.Text | Should -BeLike '*THE CLICK LANDED*'
        $act.Text | Should -Not -BeLike '*THE CLICK LANDED WITHOUT FOCUS*'
        $act.Text | Should -BeLike '*does NOT demonstrate the*'
        $act.Text | Should -BeLike '*Repeat WITHOUT it.*'
    }

    It 'claims the unfocused case only when the target did not hold the foreground' {
        # The other direction, so the conclusion cannot rot into always-cautious.
        if ($script:FRun.Text -like '*SWD focused   : True*') {
            $script:FRun.Text | Should -Not -BeLike '*THE CLICK LANDED WITHOUT FOCUS*'
        } else {
            $script:FRun.Text | Should -BeLike '*THE CLICK LANDED WITHOUT FOCUS*'
        }
    }

    It 'reports the transport honestly - what was OBSERVED, per transport' {
        # ROUND 2, C1. `sent` answers "did the transport call succeed", and that
        # means two different things depending on the call: a POSTED BM_CLICK
        # returns success for entering a queue and essentially cannot fail. So
        # the line now carries `observed` and the gloss explains the difference.
        $script:FRun.Text | Should -BeLike '*BM_CLICK      : method=*sent=True*observed=handled*'
        $script:FRun.Text | Should -BeLike '*queued means only that a posted message entered*'
        $script:FRun.Text | Should -BeLike '*handled says nothing about what the control DID*'
    }

    It 'writes control-map.csv as UTF-8 with no BOM, carrying the timeout columns' {
        $map = Join-Path $script:Stage 'control-map.csv'
        Test-Path -LiteralPath $map | Should -BeTrue
        $b = [IO.File]::ReadAllBytes($map)
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should -BeFalse
        $rows = @(Import-Csv -LiteralPath $map)
        foreach ($c in 'Handle', 'Class', 'Text', 'TimedOut', 'Skipped', 'LastError') {
            $rows[0].PSObject.Properties.Name | Should -Contain $c
        }
    }

    It 'without -ClickProbe, explains how to settle the headless question and warns about checkboxes' {
        # The branch that tells the operator what to do next. Reachable only with
        # a target present and no probe handle, so it needs its own run.
        $noProbe = Invoke-Diagnose -Script $script:StagedDiag -LogDir (Join-Path $TestDrive 'noprobe')
        $noProbe.Text | Should -BeLike '*NOT RUN - no -ClickProbe handle given*'
        $noProbe.Text | Should -BeLike '*BM_GETCHECK=0*'
        $noProbe.Text | Should -BeLike '*never the*scan button*'
    }

    It 'publishes the read status, so a zero count cannot pass for a measurement' {
        $script:FRun.Text | Should -BeLike '*read status: text read for * of *; * timed out; * skipped*'
    }

    It 'reports lastError=1460 as AMBIGUOUS, committing to neither reading' {
        # C3, at the consumer. This branch has now been wrong in BOTH directions:
        # it printed "THE SEND FAILED. Nothing was measured", then "the click most
        # likely LANDED ... This is NOT failure" - the same mistake with the sign
        # flipped. Measured 2026-08-28 on a throwaway target, 1460 appears BOTH
        # when the click landed and opened a modal AND when the pump was already
        # blocked so it never landed.
        #
        # SLOW blocks the target pump for 8 s from inside its own click handler,
        # which is longer than Invoke-SwdButton's 5000 ms send timeout, so the
        # send cannot be acknowledged and 1460 is produced deterministically.
        $slow = Invoke-Diagnose -Script $script:StagedDiag -LogDir (Join-Path $TestDrive 'slowlogs') `
                                -ExtraArgs @('-ClickProbe', "$($script:SlowH)")
        $slow.Text | Should -BeLike '*lastError=1460*'
        $slow.Text | Should -BeLike '*AMBIGUOUS*'
        # both readings must be named ...
        $slow.Text | Should -BeLike '*never landed*'
        $slow.Text | Should -BeLike '*Wait-SwdDialog*'
        # ... and neither asserted.
        $slow.Text | Should -Not -BeLike '*most likely LANDED*'
        $slow.Text | Should -Not -BeLike '*This is NOT failure*'
        $slow.Text | Should -Not -BeLike '*THE SEND FAILED*'
    }

    It 'refuses the UNFOCUSED claim when the foreground could not be measured' {
        # W4, and the mutant this exists to kill. Collapsing the three-state
        # $heldFocus back to `$fgOwned -or $fgOwnedAfter` maps UNKNOWN onto
        # $false, which is not "unknown" - it is the affirmative claim that SWD
        # did NOT hold the foreground, and that claim is the sole premise for
        # "THE CLICK LANDED WITHOUT FOCUS", this project's load-bearing headless
        # result. Measured: that mutation passed the whole suite until this test
        # existed, because on an interactive desktop GetForegroundWindow always
        # answers and the $null path is never reached.
        #
        # So the $null is INJECTED, through the same staged-copy seam the harness
        # already uses for Get-SwdProcess. Nothing in the repository is touched
        # and SWD is never contacted.
        $stage2 = Join-Path $TestDrive 'stage-unknownfg'
        [void][IO.Directory]::CreateDirectory($stage2)
        foreach ($f in 'swd_msg.ps1', 'swd_diagnose.ps1') {
            Copy-Item -LiteralPath (Join-Path $script:Stage $f) -Destination $stage2
        }
        $lib = Join-Path $stage2 'swd_msg.ps1'
        # NORMALISED TO LF BEFORE MATCHING. The anchor spans two lines, and the
        # first version hard-coded "`n" - so one editor save that rewrote
        # swd_msg.ps1 as CRLF would turn this into a permanent false alarm that
        # throws rather than fails. swd_diagnose.ps1 in this same directory is
        # already CRLF, so that is one save away, not hypothetical. The staged
        # copy is a throwaway and PowerShell runs either ending, so normalising
        # it costs nothing.
        $txt = ([IO.File]::ReadAllText($lib)) -replace "`r`n", "`n"
        $anchor = "    param([Parameter(Mandatory)][int64]`$Handle, [Parameter(Mandatory)][int]`$ProcessId)`n    if (`$ProcessId -le 0) { return `$null }"
        if (-not $txt.Contains($anchor)) { throw 'Test-SwdOwnsForeground seam not found in the staged copy' }
        [IO.File]::WriteAllText($lib, $txt.Replace($anchor,
            "    param([Parameter(Mandatory)][int64]`$Handle, [Parameter(Mandatory)][int]`$ProcessId)`n    return `$null   # TEST STAGE: force the UNKNOWN state`n    if (`$ProcessId -le 0) { return `$null }"))

        $u = Invoke-Diagnose -Script (Join-Path $stage2 'swd_diagnose.ps1') `
                             -LogDir (Join-Path $TestDrive 'unknownfg') `
                             -ExtraArgs @('-ClickProbe', "$($script:BtnH)")
        # the state is reported as unknown ...
        $u.Text | Should -BeLike '*SWD focused   : UNKNOWN*'
        $u.Text | Should -BeLike '*the foreground could not be read*'
        # ... and the conclusion refuses to trade on it.
        $u.Text | Should -BeLike '*FOREGROUND STATE WAS NEVER*'
        $u.Text | Should -Not -BeLike '*THE CLICK LANDED WITHOUT FOCUS*'
    }

    It 'renders an unreadable foreground as UNKNOWN rather than as "not focused"' {
        # W4 at the consumer. The predicate is three-state now; this asserts the
        # log can SAY so. The $null path itself needs a session with no
        # foreground window (locked workstation, UAC secure desktop) and is not
        # reachable from a test - see the run report. What IS asserted here is
        # that the value printed is the one the predicate returned, so a mutant
        # that collapses three states back to two changes this line.
        $script:FRun.Text | Should -Match '(?m)^SWD focused   : (True|False|UNKNOWN)  \(by owning process'
    }
}
