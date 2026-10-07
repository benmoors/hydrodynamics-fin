<#
.SYNOPSIS
    Night driver for the SWD live-solver campaign (Stage 2, 2026-10-06).
.DESCRIPTION
    Runs swd_probe.ps1 -Probe Sweep -Pass SolverLoop chunk after chunk until the first of: the
    night's end (no (speed, slope) block can finish by StopBy - 10 min), the campaign's end, a
    failed or timed-out chunk, a library hash that is not confirmed unchanged, or the STOP file.
    Then it runs SolverRestore (RestoreBoard reopened, 10 m/s and 0 deg, SWD closed, settings
    hash compared), EXCEPT when the STOP file is present (SWD is then closed without restoring:
    STOP means stop acting on SWD, SQA 2026-10-08) or when no chunk ran and SWD is not running.
    Every child has a wall-clock limit and is force-stopped past it, and SWD is force-stopped if
    it is still running at the end, so SWD is closed before StopBy and the laptop can leave for
    uni at 07:30 (Benjamin, 2026-10-06). A night lasts at most 14 h: a driver started after
    StopBy no longer runs until the next morning. The next night resumes from loop_state.json in
    the same -SweepDir.
    Log: <SweepDir>\driver.log; each child's stdout and stderr: <SweepDir>\driver-out\.

    Started detached (Invoke-CimMethod Win32_Process Create), so no Claude Code job ceiling can
    reap it, from an elevated session: SWD runs at High integrity and the probe checks that it
    matches.
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File swd_solver_driver.ps1 -SweepDir <dir>\solver -LogDir <dir> -ExpectVolumeL 24.5
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SweepDir,
    [Parameter(Mandatory)][string]$LogDir,
    [string]$Board = 'default_shortboard',
    [string]$Speeds = '1,2,3,4,5,6,7,8,9,10',
    [string]$Slopes = '-10,-5,0,5,10,15,20',
    [ValidateRange(0, 90)][double]$MaxDrift = 20,
    [ValidateRange(0, 1000)][double]$ExpectVolumeL = 0,
    [ValidatePattern('\A([01][0-9]|2[0-3]):[0-5][0-9]\z')][string]$StopBy = '07:00',
    [ValidateRange(1, 30)][int]$ChunkMinutes = 30,
    [string]$RestoreBoard = 'default_shortboard_Copy_1',
    [ValidateRange(0, 1000)][double]$RestoreVolumeL = 33.95
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$probe = Join-Path $here 'swd_probe.ps1'
$ps51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$swd = 'SurfHydrodynamics'
# The path guard before anything is created (W8, SQA 2026-10-08): this script runs elevated.
# swd_msg.ps1 only: swd_probe.ps1's param block would overwrite this script's parameters.
. (Join-Path $here 'swd_msg.ps1')
$SweepDir = Resolve-SwdWritableTarget -Path $SweepDir
$LogDir = Resolve-SwdWritableTarget -Path $LogDir
if (-not $SweepDir -or -not $LogDir) { throw 'Refusing -SweepDir or -LogDir (path guard).' }
$outDir = Join-Path $SweepDir 'driver-out'
[void][IO.Directory]::CreateDirectory($outDir)
$log = Join-Path $SweepDir 'driver.log'
$inv = [Globalization.CultureInfo]::InvariantCulture

function Write-DriverLog([string]$Text) {
    # No profile or tenant name in the log (R9; S1, SQA 2026-10-08): collapsed as swd_probe.ps1's
    # Format-MessageForDisplay does, OneDrive first because it sits under USERPROFILE.
    $ic = [Text.RegularExpressions.RegexOptions]::IgnoreCase
    foreach ($od in @($env:OneDriveCommercial, $env:OneDriveConsumer, $env:OneDrive)) { if ($od) { $Text = [regex]::Replace($Text, [regex]::Escape($od), '~\OneDrive', $ic) } }
    if ($env:USERPROFILE) { $Text = [regex]::Replace($Text, [regex]::Escape($env:USERPROFILE), '~', $ic) }
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Text" | Out-File -Append -LiteralPath $log -Encoding utf8
}

function Get-DriverStopTime {
    <#  The next StopBy ('HH:mm') after Now, but at most 14 h away (S5, SQA 2026-10-08): started
        after StopBy, a night used to run until the next morning, about 24 h.  #>
    param([Parameter(Mandatory)][datetime]$Now, [Parameter(Mandatory)][string]$At)
    $t = [datetime]::ParseExact($At, 'HH:mm', $inv)
    $s = $Now.Date.Add($t.TimeOfDay)
    if ($s -le $Now) { $s = $s.AddDays(1) }
    if ($s -gt $Now.AddHours(14)) { $s = $Now.AddHours(14) }
    return $s
}

function Get-DriverChunkLength {
    <#  A chunk's -MaxMinutes: ChunkMinutes, or the whole minutes Left if fewer. [double], because
        the Int32 overload of Min rounded 27.78 up to 28 (W6; driver.log 2026-10-08 06:27).  #>
    param([Parameter(Mandatory)][int]$ChunkMinutes, [Parameter(Mandatory)][double]$Left)
    return [int][math]::Floor([math]::Min([double]$ChunkMinutes, $Left))
}

function Get-DriverWaitLimit {
    <#  The minutes a child may run (C1): Want, but never past By, and never below 0. 0.0, not 0:
        Max(0, 2.5) binds the Int32 overload and gives 2 (the W6 trap; caught by its test).  #>
    param([Parameter(Mandatory)][double]$Want, [Parameter(Mandatory)][datetime]$By, [datetime]$Now = (Get-Date))
    return [math]::Max(0.0, [math]::Min($Want, ($By - $Now).TotalMinutes))
}

function ConvertTo-DriverArgument([string]$Text) {
    # One argument of a Windows command line: Start-Process joins -ArgumentList with spaces and
    # quotes nothing on 5.1. Quoted when it holds a space or a quote; backslashes before a quote,
    # and at the end of a quoted argument, doubled (the CommandLineToArgvW rules).
    if ($Text -and $Text -notmatch '[\s"]') { return $Text }
    return '"' + (($Text -replace '(\\*)"', '$1$1\"') -replace '(\\+)\z', '$1$1') + '"'
}

function Invoke-DriverChild {
    <#  One Windows PowerShell 5.1 child with a wall-clock limit (C1, SQA 2026-10-08): the probe's
        own limits cannot stop a hang inside a cross-process call. stdout and stderr go to files in
        driver-out, so a stderr line no longer kills the child under ErrorActionPreference Stop
        (W3). Past Minutes the child is force-stopped and Code is $null; SWD itself is left to the
        caller's close. Returns the exit code, the stdout lines and the summary the probe printed.  #>
    param([Parameter(Mandatory)][string]$Tag, [Parameter(Mandatory)][string[]]$Arguments, [Parameter(Mandatory)][double]$Minutes)
    if ($Minutes -le 0) { Write-DriverLog "    $Tag not started: no time left"; return [pscustomobject]@{ Code = $null; Out = @(); Summary = $null } }
    $base = Join-Path $outDir ('{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Tag)
    $line = @(@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass') + $Arguments | ForEach-Object { ConvertTo-DriverArgument $_ }) -join ' '
    $p = Start-Process -FilePath $ps51 -ArgumentList $line -NoNewWindow -PassThru -RedirectStandardOutput "$base.out.txt" -RedirectStandardError "$base.err.txt"
    # Read once now: on 5.1 the exit code of a process Start-Process returned is lost otherwise.
    [void]$p.Handle
    $code = $null
    if ($p.WaitForExit([int]($Minutes * 60000))) { $code = $p.ExitCode }
    else {
        Write-DriverLog "    $Tag ran past $([math]::Round($Minutes, 1)) min: force-stopped"
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        [void]$p.WaitForExit(10000)
    }
    # Decoded as the console decodes a child's output, which is what '& powershell.exe' did. An
    # unreadable file reads as empty: no summary, so the night stops (the safe direction).
    $read = { param($f) try { @([IO.File]::ReadAllLines($f, [Console]::OutputEncoding)) } catch { @() } }
    $out = @(& $read "$base.out.txt"); $err = @(& $read "$base.err.txt" | Where-Object { $_.Trim() })
    $sum = $null
    $m = @($out | Select-String -Pattern '^summary: (.+)$' | Select-Object -Last 1)
    if ($m.Count) {
        $f = $m[0].Matches[0].Groups[1].Value.Trim()
        if (Test-Path -LiteralPath $f) { $sum = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json }
    }
    # -cmatch (S1): '-match SWD-' also matched the 'swd-probe' folder of every summary path.
    foreach ($l in @($out | Where-Object { $_ -cmatch '"Stopped"|SWD-|Exception|rror|WARNING' }) + @($err | Select-Object -Last 15)) { Write-DriverLog "    $($l.Trim())" }
    return [pscustomobject]@{ Code = $code; Out = $out; Summary = $sum }
}

function Get-DriverResult {
    <#  The chunk result object from a summary, or $null.  #>
    param($Summary)
    if ($Summary -and $Summary.PSObject.Properties['Result'] -and $Summary.Result) { return $Summary.Result }
    return $null
}

function Get-DriverLibrary {
    <#  A summary's library verdict, for the log and the stop rule (W3: a failed chunk's too).  #>
    param($Summary)
    if (-not $Summary -or -not $Summary.PSObject.Properties['Library'] -or -not $Summary.Library) { return 'no verdict' }
    if ($Summary.Library.Ok -eq $true) { return 'unchanged' }
    if ($Summary.Library.Ok -eq $false) { return 'CHANGED' }
    return 'not re-checked'
}

$stopAt = Get-DriverStopTime -Now (Get-Date) -At $StopBy
$endBy = $stopAt.AddMinutes(-10)
$hard = $stopAt.AddMinutes(-5)
# Every child is gone by closeBy (C1), and SWD is force-stopped after that if it still runs. A loop
# chunk ends 3 min before it, which leaves a 2-minute restore its time.
$closeBy = $stopAt.AddMinutes(-1)
Write-DriverLog "night start: board $Board, speeds $Speeds, slopes $Slopes, drift <= $MaxDrift; blocks end by $($endBy.ToString('yyyy-MM-dd HH:mm', $inv)), SWD closed by $($stopAt.ToString('yyyy-MM-dd HH:mm', $inv))"
$why = $null; $n = 0
try {
    while (-not $why) {
        if (Test-Path -LiteralPath (Join-Path $LogDir 'STOP')) { $why = 'STOP file'; break }
        $left = ($hard - (Get-Date)).TotalMinutes
        if ($left -lt 3) { $why = 'night end (clock)'; break }
        $n++
        $mins = Get-DriverChunkLength -ChunkMinutes $ChunkMinutes -Left $left
        $lim = Get-DriverWaitLimit -Want ($mins + 5) -By $closeBy.AddMinutes(-3)
        Write-DriverLog "chunk $n start ($mins min; stopped after $([math]::Round($lim, 1)) min at most)"
        $c = Invoke-DriverChild -Tag "chunk$n" -Minutes $lim -Arguments @(
            '-File', $probe, '-Probe', 'Sweep', '-Pass', 'SolverLoop', '-SweepDir', $SweepDir, '-LogDir', $LogDir, '-Board', $Board, '-Speeds', $Speeds,
            '-Slopes', $Slopes, '-MaxDrift', $MaxDrift.ToString($inv), '-ExpectVolumeL', $ExpectVolumeL.ToString($inv), '-MaxMinutes', "$mins",
            '-EndBy', $endBy.ToString('yyyy-MM-ddTHH:mm:ss', $inv))
        $res = Get-DriverResult $c.Summary
        $stopped = if ($res) { "$($res.Stopped)" } else { '' }
        $cur = if ($res -and $res.PSObject.Properties['Info'] -and $res.Info -and $res.Info.PSObject.Properties['Cursor']) { "$($res.Info.Cursor)/$($res.Info.Total)" } else { '?' }
        $lib = Get-DriverLibrary $c.Summary
        Write-DriverLog "chunk $n exit $(if ($null -eq $c.Code) { 'none' } else { $c.Code }), stopped '$stopped', cursor $cur, library $lib"
        if ($null -eq $c.Code) { $why = 'chunk timed out'; break }
        if ($c.Code -ne 0) { $why = "chunk failed (exit $($c.Code))"; break }
        if ($lib -ne 'unchanged') { $why = 'library hash not confirmed unchanged'; break }
        if ($stopped -eq 'night end') { $why = 'night end'; break }
        if ($stopped -eq 'pass complete') { $why = 'campaign complete'; break }
    }
} catch {
    $why = "driver error: $($_.Exception.Message)"
} finally {
    # Each step in its own try: a failed restore never skips the close, nor the close the force-stop.
    # STOP is honoured here too (SQA 2026-10-08): SolverRestore launches SWD, drives a modal picker
    # and presses Apply, so with STOP present SWD is only closed.
    try {
        if (Test-Path -LiteralPath (Join-Path $LogDir 'STOP')) { Write-DriverLog "stopping: $why; restore skipped: STOP; SWD closed without restoring" }
        elseif ($n -eq 0 -and -not (Get-Process $swd -ErrorAction SilentlyContinue)) { Write-DriverLog "stopping: $why; restore skipped: no chunk ran and SWD is not running" }
        else {
            Write-DriverLog "stopping: $why; restoring $RestoreBoard"
            $r = Invoke-DriverChild -Tag 'restore' -Minutes (Get-DriverWaitLimit -Want 8 -By $closeBy) -Arguments @(
                '-File', $probe, '-Probe', 'Sweep', '-Pass', 'SolverRestore', '-SweepDir', $SweepDir, '-LogDir', $LogDir, '-Board', $RestoreBoard,
                '-ExpectVolumeL', $RestoreVolumeL.ToString($inv))
            $ri = Get-DriverResult $r.Summary
            $info = if ($ri -and $ri.PSObject.Properties['Info']) { $ri.Info } else { $null }
            $match = if ($info -and $info.PSObject.Properties['SettingsMatchBackup']) { $info.SettingsMatchBackup } else { '?' }
            $differ = if ($info -and $info.PSObject.Properties['SettingsDiffer']) { @($info.SettingsDiffer) -join ', ' } else { '' }
            Write-DriverLog "restore exit $(if ($null -eq $r.Code) { 'none' } else { $r.Code }); settings match backup: $match $differ; library $(Get-DriverLibrary $r.Summary)"
        }
    } catch { Write-DriverLog "restore error: $($_.Exception.Message)" }
    # Last resort, STOP or not (Stop-SwdSweepApp is exempt from the kill switch by design): SWD is
    # never left running for the morning. It answers dialogs by the safe policy and discards
    # in-memory state (SWD saves a board only on a scan).
    try {
        if (Get-Process $swd -ErrorAction SilentlyContinue) {
            Write-DriverLog 'SWD still running: closing it'
            $q = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($probe)
            $o = Invoke-DriverChild -Tag 'close' -Minutes (Get-DriverWaitLimit -Want 8 -By $closeBy) -Arguments @('-Command', "& { . '$q'; Stop-SwdSweepApp }")
            Write-DriverLog "    close: exit $(if ($null -eq $o.Code) { 'none' } else { $o.Code }), $((@($o.Out) | Select-Object -Last 2) -join ' ')"
        }
    } catch { Write-DriverLog "close error: $($_.Exception.Message)" }
    # And if even that failed: force-stopped, by closeBy, before StopBy (C1).
    try {
        if (Get-Process $swd -ErrorAction SilentlyContinue) {
            Write-DriverLog 'SWD still running after the close: force-stopping it'
            Stop-Process -Name $swd -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }
    } catch { Write-DriverLog "force-stop error: $($_.Exception.Message)" }
    Write-DriverLog "DONE: $why; SWD running: $([bool](Get-Process $swd -ErrorAction SilentlyContinue))"
}
