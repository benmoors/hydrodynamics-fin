<#
    Pester 6.x, Windows PowerShell 5.1. Runs with SWD CLOSED and never starts it.

    Covers swd_solver_driver.ps1 as SQA 2026-10-08 found it: child time limits (C1), a stderr
    line under ErrorActionPreference Stop (W3), the last-resort close (W4), the chunk length (W6),
    the path guard (W8), the log's R9 hygiene (S1), STOP before the restore, and the night's
    length (S5). The pure helpers are defined from the driver's own AST, so no night runs. The
    night itself runs as a staged copy in $TestDrive beside a FAKE swd_probe.ps1, with the SWD
    process name replaced by one unique to the run: a renamed copy of PING.EXE stands in for a
    running SWD. Unique, because parallel runs that shared one name stopped each other's stand-in.
#>

BeforeAll {
    $script:Phase2 = Split-Path -Parent $PSScriptRoot
    $script:Driver = Join-Path $script:Phase2 'swd_solver_driver.ps1'
    $ast = [Management.Automation.Language.Parser]::ParseFile($script:Driver, [ref]$null, [ref]$null)
    foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
    # What the helpers read from the driver's script scope.
    $script:inv = [Globalization.CultureInfo]::InvariantCulture
    $ps51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $outDir = Join-Path $TestDrive 'driver-out'
    [void][IO.Directory]::CreateDirectory($outDir)
    $script:log = Join-Path $TestDrive 'unit-driver.log'
    $script:FakeName = 'FakeSwd' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $script:Fake = @'
# Fake swd_probe.ps1 for the driver tests: records each call; $env:FAKE_PROBE_MODE picks the behaviour.
param([string]$Probe = '', [string]$Pass = '', [string]$SweepDir, [string]$LogDir, [string]$Board, [string]$Speeds, [string]$Slopes,
      [string]$MaxDrift, [string]$ExpectVolumeL, [string]$MaxMinutes, [string]$EndBy)
$calls = Join-Path $PSScriptRoot 'calls.txt'
function Stop-SwdSweepApp { Add-Content -LiteralPath $calls -Value 'close'; 'closed' }
if ($Probe) {
    Add-Content -LiteralPath $calls -Value "$Pass|$MaxMinutes|$Board"
    if ($env:FAKE_PROBE_MODE -eq 'nosummary' -and $Pass -eq 'SolverLoop') { exit 0 }
    $run = Join-Path $LogDir ('swd-probe-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    [void][IO.Directory]::CreateDirectory($run)
    $stopped = if ($Pass -eq 'SolverRestore') { 'pass complete' } else { 'night end' }
    [pscustomobject]@{ Result = [pscustomobject]@{ Stopped = $stopped; Info = [pscustomobject]@{ Cursor = 5; Total = 10; SettingsMatchBackup = $true } }
                       Library = [pscustomobject]@{ Ok = $true } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $run 'summary.json') -Encoding UTF8
    "WARNING: a note naming $($env:USERPROFILE.ToUpperInvariant())\x"
    "summary: $(Join-Path $run 'summary.json')"
    if ($env:FAKE_PROBE_MODE -eq 'stderr' -and $Pass -eq 'SolverLoop') { [Console]::Error.WriteLine('SWD-SOLVER-TEST: a line on stderr'); exit 1 }
    exit 0
}
'@
    function Invoke-StagedNight {
        <#  Stages the driver (SWD's name replaced) beside the fake probe in $TestDrive\<Folder>, runs
            one night with StopBy InMinutes from now, and returns the log, the calls and the exit code.  #>
        param([string]$Folder = 'stage', [int]$InMinutes = 30, [string]$Mode = '', [switch]$Stop, [string]$SweepDir, [string]$LogDir)
        $stage = Join-Path $TestDrive $Folder
        New-Item -ItemType Directory -Force -Path $stage | Out-Null
        $text = [IO.File]::ReadAllText($script:Driver).Replace("'SurfHydrodynamics'", "'$script:FakeName'")
        [IO.File]::WriteAllText((Join-Path $stage 'swd_solver_driver.ps1'), $text, (New-Object Text.UTF8Encoding $false))
        Copy-Item -LiteralPath (Join-Path $script:Phase2 'swd_msg.ps1') -Destination $stage
        [IO.File]::WriteAllText((Join-Path $stage 'swd_probe.ps1'), $script:Fake, (New-Object Text.UTF8Encoding $false))
        if (-not $SweepDir) { $SweepDir = Join-Path $stage 'sweep' }
        if (-not $LogDir) { $LogDir = Join-Path $stage 'swd-probe-log' }
        if ($Stop) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null; New-Item -ItemType File -Force -Path (Join-Path $LogDir 'STOP') | Out-Null }
        $env:FAKE_PROBE_MODE = $Mode
        try {
            $q = { param($s) '"' + $s + '"' }
            $argv = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File $(& $q (Join-Path $stage 'swd_solver_driver.ps1')) -SweepDir $(& $q $SweepDir) -LogDir $(& $q $LogDir) -StopBy $((Get-Date).AddMinutes($InMinutes).ToString('HH:mm'))"
            $p = Start-Process -FilePath $ps51 -ArgumentList $argv -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $stage 'driver.out') -RedirectStandardError (Join-Path $stage 'driver.err')
            [void]$p.Handle
            if (-not $p.WaitForExit(120000)) { Stop-Process -Id $p.Id -Force; throw 'the staged night did not finish in 120 s' }
        } finally { $env:FAKE_PROBE_MODE = $null }
        $logFile = Join-Path $SweepDir 'driver.log'
        $callFile = Join-Path $stage 'calls.txt'
        return [pscustomobject]@{
            Code = $p.ExitCode
            Log = $(if (Test-Path -LiteralPath $logFile) { Get-Content -LiteralPath $logFile -Raw -Encoding UTF8 } else { '' })
            Calls = @(if (Test-Path -LiteralPath $callFile) { Get-Content -LiteralPath $callFile })
        }
    }
}

Describe 'driver: the night''s end (S5)' {
    It 'is the next StopBy: <Case>' -ForEach @(
        @{ Case = 'evening, before midnight'; Now = '2026-10-08 21:30:00'; At = '07:00'; Want = '2026-10-09 07:00:00' }
        @{ Case = 'after midnight'; Now = '2026-10-09 00:30:00'; At = '07:00'; Want = '2026-10-09 07:00:00' }
        @{ Case = 'exactly 14 h before'; Now = '2026-10-08 17:00:00'; At = '07:00'; Want = '2026-10-09 07:00:00' }
        @{ Case = 'a minute before StopBy'; Now = '2026-10-09 06:59:00'; At = '07:00'; Want = '2026-10-09 07:00:00' }
        @{ Case = 'StopBy 00:00'; Now = '2026-10-08 23:59:30'; At = '00:00'; Want = '2026-10-09 00:00:00' }
    ) {
        Get-DriverStopTime -Now ([datetime]$Now) -At $At | Should -Be ([datetime]$Want)
    }
    It 'is at most 14 h away: <Case>' -ForEach @(
        @{ Case = 'started at StopBy'; Now = '2026-10-09 07:00:00'; At = '07:00'; Want = '2026-10-09 21:00:00' }
        @{ Case = 'started after StopBy'; Now = '2026-10-09 07:30:00'; At = '07:00'; Want = '2026-10-09 21:30:00' }
        @{ Case = 'a second over 14 h'; Now = '2026-10-08 16:59:59'; At = '07:00'; Want = '2026-10-09 06:59:59' }
        @{ Case = 'afternoon, StopBy 23:59'; Now = '2026-10-09 00:00:00'; At = '23:59'; Want = '2026-10-09 14:00:00' }
    ) {
        Get-DriverStopTime -Now ([datetime]$Now) -At $At | Should -Be ([datetime]$Want)
    }
    It 'refuses a StopBy that is not a time of day: <_>' -ForEach @('24:00', '29:59', '7:00', '07:60', '0700', '07:00 ') {
        $pat = @((Get-Command $script:Driver).Parameters['StopBy'].Attributes | Where-Object { $_ -is [ValidatePattern] })[0].RegexPattern
        $_ -match $pat | Should -BeFalse
    }
    It 'accepts every time of day: <_>' -ForEach @('00:00', '07:00', '09:59', '19:30', '23:59') {
        $pat = @((Get-Command $script:Driver).Parameters['StopBy'].Attributes | Where-Object { $_ -is [ValidatePattern] })[0].RegexPattern
        $_ -match $pat | Should -BeTrue
    }
}

Describe 'driver: a chunk''s length (W6) and a child''s time limit (C1)' {
    It 'MaxMinutes is the whole minutes left, never rounded up: <Left> min left' -ForEach @(
        @{ Left = 27.78; Want = 27 }
        @{ Left = 27.5; Want = 27 }
        @{ Left = 27.49; Want = 27 }
        @{ Left = 3.0; Want = 3 }
        @{ Left = 3.99; Want = 3 }
        @{ Left = 45.0; Want = 30 }
        @{ Left = 30.0; Want = 30 }
    ) {
        Get-DriverChunkLength -ChunkMinutes 30 -Left $Left | Should -Be $Want
    }
    It 'a child gets Want minutes, but never past By, and never below 0' {
        $now = [datetime]'2026-10-09 06:00:00'
        Get-DriverWaitLimit -Want 8 -By $now.AddMinutes(30) -Now $now | Should -Be 8
        Get-DriverWaitLimit -Want 8 -By $now.AddMinutes(2.5) -Now $now | Should -Be 2.5
        Get-DriverWaitLimit -Want 8 -By $now.AddMinutes(-1) -Now $now | Should -Be 0
    }
}

Describe 'driver: one child, bounded, its streams in files (C1, W3)' {
    It 'quotes an argument for the Windows command line: <Case>' -ForEach @(
        @{ Case = 'plain'; Text = '-10,-5,0,5'; Want = '-10,-5,0,5' }
        @{ Case = 'spaces'; Text = 'C:\a b\c'; Want = '"C:\a b\c"' }
        @{ Case = 'a trailing backslash'; Text = 'C:\a b\'; Want = '"C:\a b\\"' }
        @{ Case = 'a quote'; Text = 'a"b'; Want = '"a\"b"' }
        @{ Case = 'backslashes before a quote'; Text = 'a\\"b'; Want = '"a\\\\\"b"' }
        @{ Case = 'empty'; Text = ''; Want = '""' }
    ) {
        ConvertTo-DriverArgument $Text | Should -BeExactly $Want
    }
    It 'every argument arrives in the child as it was given' {
        $given = @('C:\Users\x y\OneDrive - Fixture Tenant\it''s here', ('Anna' + [char]0x2019 + 's Arc'), 'C:\trailing dir\', '-10,-5,0,5,10', '2026-10-09T06:50:00', 'x"y')
        $script:EchoFile = Join-Path $TestDrive 'echo.txt'
        $echo = Join-Path $TestDrive 'echo.ps1'
        [IO.File]::WriteAllText($echo, '$args | ForEach-Object { "<$_>" } | Set-Content -LiteralPath $env:DRIVER_ECHO -Encoding UTF8', (New-Object Text.UTF8Encoding $false))
        $env:DRIVER_ECHO = $script:EchoFile
        try { $r = Invoke-DriverChild -Tag 'echo' -Minutes 1 -Arguments (@('-File', $echo) + $given) } finally { $env:DRIVER_ECHO = $null }
        $r.Code | Should -Be 0
        @(Get-Content -LiteralPath $script:EchoFile -Encoding UTF8) | Should -Be @($given | ForEach-Object { "<$_>" })
    }
    It 'returns the exit code of a child that ends by itself' {
        (Invoke-DriverChild -Tag 'code' -Minutes 1 -Arguments @('-Command', 'exit 3')).Code | Should -Be 3
    }
    It 'force-stops a child past its limit and returns no exit code' {
        $env:DRIVER_PID = Join-Path $TestDrive 'hang.pid'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try { $r = Invoke-DriverChild -Tag 'hang' -Minutes 0.1 -Arguments @('-Command', '$PID | Set-Content -LiteralPath $env:DRIVER_PID; Start-Sleep -Seconds 120') }
        finally { $env:DRIVER_PID = $null }
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 30
        $r.Code | Should -BeNullOrEmpty
        $id = [int](Get-Content -LiteralPath (Join-Path $TestDrive 'hang.pid'))
        Get-Process -Id $id -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
    It 'starts no child when no time is left' {
        $r = Invoke-DriverChild -Tag 'none' -Minutes 0 -Arguments @('-Command', 'exit 0')
        $r.Code | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $outDir -Filter '*-none.*').Count | Should -Be 0
    }
    It 'a stderr line neither kills the child nor hides its summary (W3)' {
        $run = Join-Path $TestDrive 'w3run'; New-Item -ItemType Directory -Force -Path $run | Out-Null
        $sum = Join-Path $run 'summary.json'
        '{"Result":{"Stopped":"night end"},"Library":{"Ok":true}}' | Set-Content -LiteralPath $sum -Encoding UTF8
        $cmd = "[Console]::Error.WriteLine('first stderr line'); Start-Sleep -Milliseconds 500; 'after the stderr line'; 'summary: $sum'; exit 0"
        $r = Invoke-DriverChild -Tag 'stderr' -Minutes 1 -Arguments @('-Command', $cmd)
        $r.Code | Should -Be 0
        $r.Out | Should -Contain 'after the stderr line'
        $r.Summary.Result.Stopped | Should -Be 'night end'
        Get-DriverLibrary $r.Summary | Should -Be 'unchanged'
        Get-Content -LiteralPath $log -Raw | Should -Match 'first stderr line'
    }
}

Describe 'driver: the log carries no profile or tenant name (S1, R9)' {
    It 'collapses the profile <_>' -ForEach @('as written', 'upper-cased', 'lower-cased') {
        $up = switch ($_) { 'upper-cased' { $env:USERPROFILE.ToUpperInvariant() } 'lower-cased' { $env:USERPROFILE.ToLowerInvariant() } default { $env:USERPROFILE } }
        Write-DriverLog "at $up\AppData\x"
        $t = Get-Content -LiteralPath $log -Raw
        $t | Should -Not -Match ([regex]::Escape($env:USERPROFILE))
        $t | Should -Match ([regex]::Escape('at ~\AppData\x'))
    }
    It 'collapses a OneDrive root to ~\OneDrive, not just to ~' {
        $saved = $env:OneDriveCommercial
        try {
            $env:OneDriveCommercial = Join-Path $env:USERPROFILE 'OneDrive - Contoso Fixture Tenant'
            Write-DriverLog "file $env:OneDriveCommercial\Documents\a.txt"
        } finally { $env:OneDriveCommercial = $saved }
        $t = Get-Content -LiteralPath $log -Raw
        $t | Should -Match ([regex]::Escape('file ~\OneDrive\Documents\a.txt'))
        $t | Should -Not -Match 'Contoso Fixture Tenant'
    }
}

Describe 'driver: a whole night, staged with a fake probe' {
    BeforeAll {
        $script:FakeExe = Join-Path $TestDrive "$script:FakeName.exe"
        Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\PING.EXE') -Destination $script:FakeExe
    }
    AfterEach { Get-Process $script:FakeName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
    It 'a chunk that writes to stderr and fails is logged as failed, not as a driver error, and the restore runs (W3)' {
        $n = Invoke-StagedNight -Folder 'w3' -Mode 'stderr'
        $n.Code | Should -Be 0
        $n.Log | Should -Match 'chunk 1 exit 1, stopped .night end., cursor 5/10, library unchanged'
        $n.Log | Should -Match 'stopping: chunk failed \(exit 1\); restoring'
        $n.Log | Should -Match 'SWD-SOLVER-TEST: a line on stderr'
        $n.Log | Should -Not -Match 'driver error'
        @($n.Calls | Where-Object { $_ -like 'SolverRestore|*' }).Count | Should -Be 1
    }
    It 'with STOP present: no restore, SWD closed, and force-stopped if the close leaves it up (staged in <Folder>)' -ForEach @(
        @{ Folder = 'stop plain' }
        @{ Folder = "stop it's" }
        @{ Folder = ('stop Anna' + [char]0x2019 + 's copy') }
    ) {
        $fake = Start-Process -FilePath $script:FakeExe -ArgumentList '-n 120 127.0.0.1' -WindowStyle Hidden -PassThru
        $n = Invoke-StagedNight -Folder $Folder -Stop
        $n.Calls | Should -Be @('close')
        $n.Log | Should -Match 'stopping: STOP file; restore skipped: STOP; SWD closed without restoring'
        $n.Log | Should -Match 'close: exit 0, closed'
        $n.Log | Should -Match 'force-stopping'
        $n.Log | Should -Match 'SWD running: False'
        $fake.HasExited | Should -BeTrue
    }
    It 'with no chunk run and SWD not running, no restore launches SWD (S5)' {
        $n = Invoke-StagedNight -Folder 's5' -InMinutes 5
        $n.Calls.Count | Should -Be 0
        $n.Log | Should -Match 'night end \(clock\); restore skipped: no chunk ran and SWD is not running'
    }
    It 'a normal night logs no profile name, though the probe prints it (S1)' {
        $n = Invoke-StagedNight -Folder 's1'
        @($n.Calls | ForEach-Object { ($_ -split '\|')[0] }) | Should -Be @('SolverLoop', 'SolverRestore')
        $n.Log | Should -Match 'stopping: night end; restoring'
        # The chunk's own limit leaves the restore its 3 minutes (C1): StopBy is 30 min away, so
        # 24 or 25 min chunks, stopped after StopBy - 4 min at most, not after MaxMinutes + 5.
        $m = [regex]::Match($n.Log, 'chunk 1 start \((\d+) min; stopped after ([\d.]+) min at most\)')
        $m.Success | Should -BeTrue
        [double]$m.Groups[2].Value | Should -BeLessOrEqual ([double]$m.Groups[1].Value + 2)
        $n.Log | Should -Not -Match ([regex]::Escape($env:USERPROFILE))
        # The WARNING is logged (redacted); the summary path, under a 'swd-probe' folder, is not.
        $n.Log | Should -Match 'WARNING: a note naming ~\\x'
        $n.Log | Should -Not -Match 'summary:'
    }
    It 'a chunk that exits 0 but leaves no summary stops the night: no library verdict' {
        $n = Invoke-StagedNight -Folder 'nosum' -Mode 'nosummary'
        $n.Log | Should -Match 'chunk 1 exit 0, stopped .., cursor \?, library no verdict'
        $n.Log | Should -Match 'stopping: library hash not confirmed unchanged; restoring'
        @($n.Calls | ForEach-Object { ($_ -split '\|')[0] }) | Should -Be @('SolverLoop', 'SolverRestore')
    }
    It 'refuses a protected <Which> before creating anything (W8)' -ForEach @(
        @{ Which = 'SweepDir'; Leaf = 'ShaperWaveDynamics documents\biblio\solver' }
        @{ Which = 'LogDir'; Leaf = 'ShaperWaveDynamics documents\biblio\logs' }
        @{ Which = 'SweepDir, upper-cased'; Leaf = 'SHAPERWAVEDYNAMICS DOCUMENTS\BIBLIO\solver' }
    ) {
        $saved = $env:OneDriveCommercial
        $od = Join-Path $TestDrive ('od-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $bad = Join-Path $od "Documents\$Leaf"
        $ok = Join-Path $TestDrive ('ok-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $stage = 'w8-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
        try {
            $env:OneDriveCommercial = $od
            $n = if ($Which -like 'LogDir*') { Invoke-StagedNight -Folder $stage -SweepDir $ok -LogDir $bad } else { Invoke-StagedNight -Folder $stage -SweepDir $bad -LogDir $ok }
        } finally { $env:OneDriveCommercial = $saved }
        $n.Code | Should -Be 1
        Test-Path -LiteralPath (Join-Path $od 'Documents') | Should -BeFalse
        Test-Path -LiteralPath $ok | Should -BeFalse
        $n.Calls.Count | Should -Be 0
    }
}
