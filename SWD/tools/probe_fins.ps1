<#
.SYNOPSIS
    Read-only probe: every board's fins (Class_surfboard.ailerons), one CSV row per fin, on stdout.

.DESCRIPTION
    Board files store their fins; hydroscan reports do not. The report class holds only drift
    and hull-element lists, and every fin force on the board is [NonSerialized]
    (SWD/data/default_shortboard/field_census.csv). So this is the only file-side record of which
    fins a scanned board carried, which the fin test needs (wiki: SWD Fin and STL Observations
    2026-09-30).

    For each .fynbs under biblio\Boards it emits one row per fin with every SCALAR field of the
    fin type (primitives, strings, enums). A reference-typed field is never formatted, because
    formatting the cyclic object graph can overflow the stack (.claude/rules/swd-technical-facts.md).
    A [NonSerialized] field is marked "[ns]" in the header: it deserialises as 0/null whatever
    the physics.

    Writes nothing but stdout (and warnings on stderr). SWD is never launched and Form_shaper
    is never constructed. Output may carry fin names; review it before committing any of it (R9).

.NOTES
    Windows PowerShell 5.1 only (BinaryFormatter), x64 only.
    Same provenance gate as swd_extract.ps1: the SHA-256 is computed on the open stream and
    checked against the trust manifest BEFORE BinaryFormatter sees it; untrusted files are skipped.
    NOT YET SQA'D - listed in SWD/docs/SQA-LOG.md. CLAUDE.md s4: do not run it before that pass.

.EXAMPLE
    powershell.exe -NoProfile -File SWD\tools\probe_fins.ps1 > "$env:TEMP\fins.csv"
#>
[CmdletBinding()]
param(
    [string] $BiblioPath    = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'ShaperWaveDynamics documents\biblio'),
    [string] $InstallPath   = 'C:\Program Files\ShaperWaveDynamics\ShaperWaveDynamics',
    [string] $TrustManifest = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Windows PowerShell 5.1 required (BinaryFormatter).' }
if (-not [Environment]::Is64BitProcess)      { throw '64-bit process required.' }

function Format-ForDisplay {
    # Keep the username and tenant out of anything printed (R9).
    param([string] $Text)
    if ($env:USERPROFILE) { $Text = $Text.Replace($env:USERPROFILE, '~') }
    return $Text
}

# --- trust manifest ----------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($TrustManifest)) {
    $TrustManifest = Join-Path $env:LOCALAPPDATA 'swd-extract\trusted_files.json'
}
if (-not (Test-Path -LiteralPath $TrustManifest)) { throw 'Trust manifest not found; run swd_extract.ps1 -TrustCurrentLibrary first.' }
$trusted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($e in (Get-Content -Raw -LiteralPath $TrustManifest | ConvertFrom-Json).files) { [void]$trusted.Add([string]$e.sha256) }

# --- assembly ------------------------------------------------------------------
# The handler returns an already-loaded assembly and NEVER calls LoadFrom itself: doing so
# recursed into an uncatchable StackOverflowException twice (swd-technical-facts).
$onResolve = [System.ResolveEventHandler] {
    param($src, $e)
    $null = $src # ResolveEventHandler delegate signature
    $n = ($e.Name -split ',')[0]
    foreach ($a in [AppDomain]::CurrentDomain.GetAssemblies()) { if ($a.GetName().Name -eq $n) { return $a } }
    return $null
}
[AppDomain]::CurrentDomain.add_AssemblyResolve($onResolve)
[void][Reflection.Assembly]::LoadFrom((Join-Path $InstallPath 'SurfHydrodynamics.exe'))
[void][Reflection.Assembly]::LoadFrom((Join-Path $InstallPath 'SlimDX.dll'))
$asm = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'SurfHydrodynamics' } | Select-Object -First 1
if (-not $asm) { throw 'SurfHydrodynamics assembly did not load.' }

$BIND    = [Reflection.BindingFlags]'Public,NonPublic,Instance'
$T_board = $asm.GetType('SurfHydrodynamics.Class_surfboard')     # GetType(name), never bare GetTypes()
if (-not $T_board) { throw 'Class_surfboard not found in the assembly.' }
$fAil = $T_board.GetField('ailerons', $BIND)
if (-not $fAil) { throw 'Class_surfboard.ailerons not found.' }
$T_fin = $fAil.FieldType.GetElementType()
if (-not $T_fin) { throw "ailerons is $($fAil.FieldType.Name), not an array." }

$scalar = @($T_fin.GetFields($BIND) | Where-Object {
    $_.FieldType.IsPrimitive -or $_.FieldType.IsEnum -or $_.FieldType -eq [string] -or $_.FieldType -eq [decimal]
} | Sort-Object Name)
$reference = @($T_fin.GetFields($BIND) | Where-Object { $scalar -notcontains $_ } | Sort-Object Name)
if ($reference.Count) {
    [Console]::Error.WriteLine("reference fields not emitted ($($reference.Count)): " + (($reference | ForEach-Object Name) -join ', '))
}

function ConvertTo-CsvCell {
    param($Value)
    if ($null -eq $Value) { return '""' }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $s = if ($Value -is [double] -or $Value -is [single]) { $Value.ToString('R', $inv) }
         elseif ($Value -is [IFormattable]) { $Value.ToString($null, $inv) }
         else { [string]$Value }
    return '"' + $s.Replace('"', '""') + '"'
}

$header = @('board', 'fin_index', 'fin_type') + @($scalar | ForEach-Object {
    if ($_.IsNotSerialized) { "$($_.Name) [ns]" } else { $_.Name }
})
Write-Output (($header | ForEach-Object { ConvertTo-CsvCell $_ }) -join ',')

# --- boards ------------------------------------------------------------------------
$fmt = New-Object System.Runtime.Serialization.Formatters.Binary.BinaryFormatter
$sha = [Security.Cryptography.SHA256]::Create()
$boardFiles = @(Get-ChildItem -LiteralPath (Join-Path $BiblioPath 'Boards') -Recurse -Filter *.fynbs -File)
try {
    foreach ($file in $boardFiles) {
        $board = $null
        $fs = $null
        try {
            $fs = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            # Hash the OPEN stream, then rewind: no window to swap the file between check and use.
            $hex = [BitConverter]::ToString($sha.ComputeHash($fs)).Replace('-', '')
            if (-not $trusted.Contains($hex)) {
                [Console]::Error.WriteLine("untrusted, skipped: $($file.Name)")
                continue
            }
            $fs.Position = 0
            $board = $fmt.Deserialize($fs)
        } catch {
            [Console]::Error.WriteLine("read failed, skipped: $($file.Name) :: $(Format-ForDisplay $_.Exception.Message)")
            continue
        } finally {
            if ($fs) { $fs.Dispose() }
        }

        $fins = $fAil.GetValue($board)
        if ($null -eq $fins -or $fins.Length -eq 0) {
            Write-Output ((@($file.BaseName, '-1', 'none') | ForEach-Object { ConvertTo-CsvCell $_ }) -join ',')
            continue
        }
        for ($i = 0; $i -lt $fins.Length; $i++) {
            $fin = $fins[$i]
            $row = @($file.BaseName, [string]$i)
            if ($null -eq $fin) {
                $row += 'null'
            } else {
                $row += $fin.GetType().Name
                foreach ($f in $scalar) { $row += , $f.GetValue($fin) }
            }
            Write-Output (($row | ForEach-Object { ConvertTo-CsvCell $_ }) -join ',')
        }
    }
} finally {
    $sha.Dispose()
}
