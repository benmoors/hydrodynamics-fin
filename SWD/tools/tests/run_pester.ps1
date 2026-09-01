$ErrorActionPreference = 'Stop'

# The suite EXECUTES the target (the containment tests spawn it), so it must run
# against a disposable copy staged into temp, never the live repo. The copy is
# hash-checked against the original so a stale stage cannot pass as the real
# thing. SWD_EXTRACT_TARGET already set (mutation harness) is left alone.
if (-not $env:SWD_EXTRACT_TARGET) {
    # Derived from this script's own location (tests\ -> tools\), so the suite
    # runs from any clone. Hardcoding it meant it only ran on one machine.
    $live = Join-Path (Split-Path -Parent $PSScriptRoot) 'swd_extract.ps1'
    if (-not (Test-Path -LiteralPath $live)) { throw "target not found beside tests\: $live" }
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('swd-stage-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $copy = Join-Path $stage 'swd_extract.ps1'
    Copy-Item -LiteralPath $live -Destination $copy
    # Get-FileHash is NOT available in this Windows PowerShell 5.1 host
    # (measured: CommandNotFoundException), so hash through .NET directly.
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $a = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($live))).Replace('-', '')
        $b = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($copy))).Replace('-', '')
    } finally { $sha.Dispose() }
    if ($a -ne $b) { throw "staged copy does not match the live script ($a vs $b)" }
    Write-Output "staged $live -> $copy  (SHA256 $a)"
    $env:SWD_EXTRACT_TARGET = $copy
    # The staged copy sits in temp, so a test cannot walk up to SWD/data from it.
    # Hand over the real data directory explicitly.
    $env:SWD_DATA_DIR = Join-Path (Split-Path -Parent (Split-Path -Parent $live)) 'data'
    $script:cleanup = $stage
}

Import-Module Pester -MinimumVersion 6.0.0 -Force
$cfg = New-PesterConfiguration
$cfg.Run.Path = $args[0]
$cfg.Output.Verbosity = 'Detailed'
$cfg.Run.Exit = $false
# PassThru defaults to False, so without this Invoke-Pester returns nothing and the
# SUMMARY line below prints empty counts - which it did, silently, until 2026-08-31.
$cfg.Run.PassThru = $true
$r = Invoke-Pester -Configuration $cfg
Write-Output ("SUMMARY passed={0} failed={1} skipped={2}" -f $r.PassedCount, $r.FailedCount, $r.SkippedCount)

if ($script:cleanup -and (Test-Path -LiteralPath $script:cleanup)) {
    Remove-Item -LiteralPath $script:cleanup -Recurse -Force -ErrorAction SilentlyContinue
}
