<#
.SYNOPSIS
    Extract ShaperWaveDynamics (SWD) hydrodynamic data to CSV for machine learning.

.DESCRIPTION
    SWD ships no CSV or Excel export. Its .fyn* files are .NET BinaryFormatter
    graphs of SWD's own [Serializable] types, so this script loads SWD's assembly
    as a type library and deserialises the files against it. SWD itself is never
    launched, Form_shaper is never constructed, no DirectX device is created and
    nothing in its install directory is written.

    "Purely a type library" would overstate it. SlimDX.dll is a mixed-mode x64
    image (CLI flags 0x18, COMIMAGE_FLAGS_NATIVE_ENTRYPOINT; it imports d3d9.dll,
    d3d11.dll and dxgi.dll), so its native DllMain and CRT initialisation do run
    at LoadFrom. That is unavoidable if the managed types are to resolve, and is
    still a long way short of creating a device. Both assemblies are x64-only,
    which is why the entry guard checks process bitness as well as PSEdition.

    Emits four tables into -OutDir:

      boards.csv           one row per .fynbs (speed setting, turn radius, mass)
      operating_points.csv one row per (board, drift angle, roll case)  <- TRAINING TABLE
      elements.csv         one row per hydrodynamic element             <- NOT a sample table
      fin_polars.csv       fin profile polars from fyn_profile_data_base.xml

    TWO COLUMN-SET DECISIONS, BOTH DELIBERATE:

      shaper_name is NOT exported. The library holds boards by seven different
      authors, including third parties by full name, and -OutDir defaults into a
      git working tree with a public remote. It was never an ML feature, so the
      column is dropped rather than protected. This is data minimisation; do not
      add it back.

      Columns that are zero on every single row are dropped at write time, with a
      warning naming them. 13 element columns and structure_mass_kg are in that
      state today. They are NOT [NonSerialized] - reflection over
      FieldAttributes.NotSerialized confirms all of them are genuinely serialised
      - SWD's hydroscan path simply never assigns them, so they deserialise as a
      real 0.0 that no null check can catch. A constant-zero column carries no
      information and reads as data, so it is removed and reported. The check is
      dynamic, so if a future SWD build does populate them the column reappears
      and the run says so.

    TWO SPEED COLUMNS, AND THEY MEAN DIFFERENT THINGS:

      rho_v_kg_m2_s          mass_flux / frontal_section. Exactly rho*V, and
                             MEASURED - always emitted, so nothing about the
                             decomposition below can destroy the raw fact.
      rho_kgm3               which of the eight densities SWD's own lookup table
                             selected, recovered by dividing rho*V by a fixed
                             reference velocity of 20.000 m/s and snapping. NaN
                             if the residual is too large to call.
      scan_speed_ms          rho*V divided by that snapped density. This is the
                             physical condition and the one to use as an ML
                             feature. It carries the measurement residual, so it
                             is a check on the inference rather than an
                             independent measurement of speed.
      board_speed_setting_ms the speed stored in the .fynbs. This is the GUI's
                             speed box as it stood when the board was last saved
                             and is NOT the scan condition.

    The stored setting and the real one were assumed to be the same at first.
    They are not: the stored setting varies over 2-20 m/s while every scan in
    the library ran at 20.000. Two near-identical shortboards stored at 20 and
    5 m/s have a median drag ratio of 1.11x, where V^2 scaling would demand 16x,
    and Spearman correlation between the stored setting and drag is -0.15.
    Treating the stored setting as the scan speed would train a model on a label
    that does not describe the physics.

    THE 20.0391 m/s SECOND VALUE THIS HEADER USED TO REPORT WAS AN ARTEFACT OF
    THIS SCRIPT, NOT A PROPERTY OF THE DATA. It came from pinning rho at 1023
    and dividing the elements that were actually scanned at 1025 kg/m^3, i.e.
    20500/1023 = 20.0391 exactly. There is one scan speed in this library, at
    two water temperatures.

.PARAMETER BiblioPath
    SWD library root containing Boards\ and rapports_hydro\.

.PARAMETER InstallPath
    SWD install directory. Read-only: used only to load the assembly and the
    profile database.

.PARAMETER OutDir
    Directory to write the CSVs into. Created if absent.

.PARAMETER SkipElements
    Skip the large per-element table (~5,900 rows).

.NOTES
    MUST run under Windows PowerShell 5.1 (powershell.exe), NOT pwsh 7+:
    BinaryFormatter was removed in .NET 9. The script enforces this on entry.

    Writes are confined to -OutDir, which is refused if it resolves inside the
    install directory or the library. No writes to the SWD install directory or
    the library; the registry is never touched.

    extract_manifest.json is written last, and any stale one is deleted first, so
    it is a completion sentinel: no manifest means the CSVs beside it are a
    partial or mixed-vintage set and must not be trusted as one dataset.
#>
[CmdletBinding()]
param(
    # Documents is redirected into OneDrive on this machine, so ask the OS where it
    # actually is rather than spelling the path out: GetFolderPath is correct whether
    # Known Folder Move is on or off. The old literal carried a username and a tenant
    # folder name into a repo with a public remote - the same leak class the manifest
    # was fixed for below. Same idiom the phase2 tests already use.
    [string] $BiblioPath  = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'ShaperWaveDynamics documents\biblio'),
    [string] $InstallPath = 'C:\Program Files\ShaperWaveDynamics\ShaperWaveDynamics',
    [string] $OutDir      = '',
    [switch] $SkipElements,

    # --- provenance gate (see .NOTES) --------------------------------------
    # Where the approved-file manifest lives. Defaults to per-machine state under
    # LOCALAPPDATA, deliberately NOT into -OutDir: the manifest is machine-local
    # security state, not part of the published dataset, and keeping it out of the
    # repo means it can never be committed or leak library file names.
    [string] $TrustManifest = '',
    # Record the CURRENT library into the manifest and exit without extracting.
    # Run once, by hand, when the library is believed clean.
    [switch] $TrustCurrentLibrary,
    # Escape hatch. Off by default and reported loudly when used.
    [switch] $AllowUntrustedFiles
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ConvertTo-Csv formats a double with the CURRENT culture, so on an fr-FR or
# de-DE host 1.5 renders as "1,5" - which is also the CSV delimiter, so the
# writer quotes it and every numeric column arrives in pandas as text. Pin the
# whole run to InvariantCulture rather than formatting at each call site: this is
# the only place that can be forgotten once. Same pin as extract_board.ps1.
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture

# --- Guard: BinaryFormatter only exists on .NET Framework -------------------
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw "Must run under Windows PowerShell 5.1 (powershell.exe). Detected PSEdition=$($PSVersionTable.PSEdition). BinaryFormatter was removed in .NET 9, so pwsh 7+ cannot deserialise .fyn* files."
}
# SurfHydrodynamics.exe and SlimDX.dll are both x64-only images, so a 32-bit
# host fails at LoadFrom with a BadImageFormatException that reads like a
# missing-file error.
if (-not [Environment]::Is64BitProcess) {
    throw 'Must run in a 64-bit process. SurfHydrodynamics.exe and SlimDX.dll are x64-only images.'
}
function Format-PathForDisplay {
    <# Collapse the personal prefixes before a path reaches the console. A pasted
       log is the easiest accidental route for these to leave the machine, and the
       leading segments carry no diagnostic value.

       The OneDrive roots are tested FIRST and separately. They live UNDER
       $env:USERPROFILE, so a plain '~' substitution leaves the tenant folder name
       ("OneDrive - <Organisation>") intact on every line - which is what the
       earlier version of this function did on every run of this script.

       Separators are normalised before the prefix test: a caller can pass
       'C:/Users/...' and an ordinal compare against 'C:\Users\...' then matches
       nothing, printing the very path this function exists to hide. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Path)
    if (-not $Path) { return '' }
    $p = $Path.Replace('/', '\')
    foreach ($od in @($env:OneDriveCommercial, $env:OneDriveConsumer, $env:OneDrive)) {
        if ($od -and $p.StartsWith($od.Replace('/', '\'), [StringComparison]::OrdinalIgnoreCase)) {
            return '~\OneDrive' + $p.Substring($od.Length)
        }
    }
    $up = $env:USERPROFILE
    if ($up -and $p.StartsWith($up.Replace('/', '\'), [StringComparison]::OrdinalIgnoreCase)) { return '~' + $p.Substring($up.Length) }
    return $p
}

foreach ($p in @($BiblioPath, $InstallPath)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Path not found: $(Format-PathForDisplay $p)" }
}
# Resolve the read-only roots through the SAME provider that just validated them.
# Load-bearing, not tidying. Test-Path -LiteralPath resolves PowerShell provider
# forms - '~', and a relative path against $PWD - that [IO.Path]::GetFullPath does
# not. Get-ProtectedRoot used to recompute these roots with bare GetFullPath, so a
# '~'-spelled or relative -BiblioPath validated as real here and then produced a
# protected root pointing at a directory that does not exist (measured:
# GetFullPath('~\x') returns '<cwd>\~\x'). Both the lexical and the canonical test
# then missed, the containment guard silently never fired, an -OutDir inside the
# library was accepted, and a file there was deleted. Convert-Path is the
# resolution Test-Path itself used, so both sides of the comparison below now
# share one path grammar.
try {
    $BiblioPath  = (Convert-Path -LiteralPath $BiblioPath).TrimEnd('\')
    $InstallPath = (Convert-Path -LiteralPath $InstallPath).TrimEnd('\')
} catch {
    # Refuse rather than proceed: an unresolvable root means the guard below would
    # be comparing -OutDir against nothing.
    throw "Could not resolve a read-only root to a canonical path, so containment cannot be enforced: $($_.Exception.Message)"
}
# $PSScriptRoot is not populated inside a param() default block, so the
# default is resolved here instead.
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $root = $PSScriptRoot
    if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $OutDir = Join-Path $root '..\data'
}
# [IO.Path]::GetFullPath resolves a relative path against
# [Environment]::CurrentDirectory, which PowerShell never syncs with $PWD: after
# Set-Location $env:TEMP, GetFullPath('swdout') still returned a path under the
# directory the process started in. Anchor a relative -OutDir to $PWD instead.
if (-not [IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path $PWD.ProviderPath $OutDir }
# \\?\ and \\.\ bypass path normalisation entirely, and UNC has no local
# canonical form this guard can reason about, so all three are refused rather
# than half-checked. Measured: each was accepted by the lexical-only guard.
if ($OutDir.StartsWith('\\')) {
    throw "-OutDir must be a local drive path. Extended-length (\\?\), device (\\.\) and UNC paths are refused: '$OutDir'"
}
$OutDir = [IO.Path]::GetFullPath($OutDir).TrimEnd('\')

# --- Containment ------------------------------------------------------------
# The install directory is licence-bound and the library is the user's only copy
# of the board data; both are read-only, always. Two INDEPENDENT defects were
# found in the first version of this guard and they need separate fixes:
#
#   WHICH roots are protected. It tested only the two supplied paths, and both
#   defaults sit one level INSIDE the tree that must not be written to.
#   $InstallPath defaults to the inner ShaperWaveDynamics\ShaperWaveDynamics, so
#   the product root above it was open; $BiblioPath defaults to biblio\ inside
#   "ShaperWaveDynamics documents\", which also holds swdshare\ (29 ctr* folders),
#   fonds\, home boards\ and video\, none of which were covered. Each supplied
#   path AND its parent is protected now.
#
#   HOW paths are compared. A lexical prefix test is defeated by an 8.3 short
#   name, a junction, a subst drive or a \\?\ prefix - GetFullPath expands none
#   of them, and all four were measured as ACCEPTED. Comparison is canonical now.
Add-Type -Namespace SwdPath -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
    System.IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, System.IntPtr hTemplateFile);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern uint GetFinalPathNameByHandleW(System.IntPtr hFile, System.Text.StringBuilder lpszFilePath, uint cchFilePath, uint dwFlags);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool CloseHandle(System.IntPtr hObject);
'@

function Get-CanonicalDirectory {
    <# The path Windows itself resolves this to: 8.3 names expanded, junctions,
       symlinks and subst followed. GetFinalPathNameByHandle is the only call
       that does all of that in one step, and it needs the directory to exist.
       $null when the path cannot be opened. FILE_FLAG_BACKUP_SEMANTICS
       (0x02000000) is what lets CreateFile open a DIRECTORY handle at all. #>
    param([Parameter(Mandatory)][string] $Path)
    $h = [SwdPath.Native]::CreateFileW($Path, 0, 7, [IntPtr]::Zero, 3, 0x02000000, [IntPtr]::Zero)
    if ($h -eq [IntPtr](-1)) { return $null }
    try {
        $sb = New-Object System.Text.StringBuilder 32768
        if ([SwdPath.Native]::GetFinalPathNameByHandleW($h, $sb, 32767, 0) -eq 0) { return $null }
        $p = $sb.ToString()
        if ($p.StartsWith('\\?\UNC\')) { return '\\' + $p.Substring(8) }
        if ($p.StartsWith('\\?\'))        { return $p.Substring(4) }
        return $p
    } finally { [void][SwdPath.Native]::CloseHandle($h) }
}

function Resolve-CanonicalTarget {
    <# Canonical form of a path that may not exist yet: canonicalise the nearest
       existing ancestor and re-append the missing tail. That lets the guard
       refuse a junction'd or 8.3 target WITHOUT creating it first, which beats
       create-then-recheck - nothing is ever made inside a protected tree, not
       even briefly. $null if nothing on the path resolves. #>
    param([Parameter(Mandatory)][string] $Path)
    $tail = New-Object 'System.Collections.Generic.List[string]'
    $cur = $Path.TrimEnd('\')
    while ($cur) {
        $c = Get-CanonicalDirectory -Path $cur
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

function Get-ProtectedRoot {
    <# Each read-only path AND its parent, because both defaults sit one level
       inside the tree that must stay untouched. A drive root is skipped:
       protecting all of C:\ would make the script unusable rather than safe. #>
    param([Parameter(Mandatory)][string[]] $Path)
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in $Path) {
        $full = [IO.Path]::GetFullPath($p).TrimEnd('\')
        if ($full.Length -gt 2 -and -not $out.Contains($full)) { [void]$out.Add($full) }
        $parent = Split-Path -Parent $full
        if ($parent) {
            $parent = $parent.TrimEnd('\')
            if ($parent.Length -gt 2 -and -not $out.Contains($parent)) { [void]$out.Add($parent) }
        }
    }
    return $out.ToArray()
}

function Test-PathUnderRoot {
    <# The first root $Path sits at or under, else $null. Ordinal-insensitive,
       and the trailing separator matters: without it "...DynamicsOther" would
       read as being under "...Dynamics". #>
    param([Parameter(Mandatory)][string] $Path, [string[]] $Root = @())
    $p = "$Path".TrimEnd('\')
    foreach ($r in $Root) {
        $rr = "$r".TrimEnd('\')
        if (-not $rr) { continue }
        if ($p -eq $rr -or $p.StartsWith($rr + '\', [StringComparison]::OrdinalIgnoreCase)) { return $rr }
    }
    return $null
}

$protectedRoots = @(Get-ProtectedRoot -Path @($InstallPath, $BiblioPath))
# Canonical AND lexical roots are both tested. Canonicalisation can fail - a root
# that does not exist, a permissions refusal - and falling back to the lexical
# test is safer than falling back to no test.
$canonRoots = @(foreach ($r in $protectedRoots) { Resolve-CanonicalTarget -Path $r })
$canonOut   = Resolve-CanonicalTarget -Path $OutDir
if (-not $canonOut) { $canonOut = $OutDir }
$allRoots = @($protectedRoots) + @($canonRoots | Where-Object { $_ })
foreach ($candidate in @($OutDir, $canonOut)) {
    $hit = Test-PathUnderRoot -Path $candidate -Root $allRoots
    if ($hit) {
        throw "-OutDir must not resolve inside a read-only SWD directory. '$(Format-PathForDisplay $OutDir)' resolves to '$(Format-PathForDisplay $candidate)', which is at or under '$(Format-PathForDisplay $hit)'."
    }
}
$OutDir = $canonOut
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

# extract_manifest.json is the completion sentinel (see .NOTES). Delete any
# stale one up front so an aborted run cannot leave the previous run's manifest
# vouching for a half-replaced set of CSVs.
$manifestPath = Join-Path $OutDir 'extract_manifest.json'
if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force }

# --- Provenance gate --------------------------------------------------------
# BinaryFormatter.Deserialize on an attacker-controlled stream is arbitrary code
# execution in this process, at this user's privilege. Microsoft's position is
# that the type cannot be made secure; it is obsolete-as-error from .NET 5 and
# removed in .NET 9, which is exactly why this script is pinned to PowerShell 5.1.
#
# The usual mitigation - "these are the user's own files" - does not hold here.
# The library is cloud-synced and holds board files authored by other people, and
# unlike SWD (which deserialises only what you explicitly open) this script
# recursively globs and auto-opens EVERY .fyn* in the tree. A hostile file that
# merely ARRIVES, by sync or by a traded board file, would be executed without
# anyone opening it. This gate restores SWD's own narrower boundary: nothing is
# deserialised unless its content hash is already approved.
#
# It does NOT make BinaryFormatter safe. A hostile file built only from approved
# hashes is still deserialised - but it can no longer be a file that simply
# appeared. Trust-on-first-use: -TrustCurrentLibrary blesses whatever is present
# at that moment, so run it when you believe the library is clean, not blindly.
if ([string]::IsNullOrWhiteSpace($TrustManifest)) {
    $TrustManifest = Join-Path $env:LOCALAPPDATA 'swd-extract\trusted_files.json'
}
if (-not [IO.Path]::IsPathRooted($TrustManifest)) {
    $TrustManifest = Join-Path $PWD.ProviderPath $TrustManifest
}
if ($TrustManifest.StartsWith('\')) {
    throw "-TrustManifest must be a local drive path. Extended-length (\?\), device (\.\) and UNC paths are refused."
}
$TrustManifest = [IO.Path]::GetFullPath($TrustManifest)
# The manifest is a WRITE target, so it gets the same containment treatment as
# -OutDir. Without this an explicitly supplied -TrustManifest would write into the
# install directory or the library - a write path outside the guard, which is the
# one thing this script must never have.
$tmCanon = Resolve-CanonicalTarget -Path $TrustManifest
if (-not $tmCanon) { $tmCanon = $TrustManifest }
foreach ($candidate in @($TrustManifest, $tmCanon)) {
    $hit = Test-PathUnderRoot -Path $candidate -Root $allRoots
    if ($hit) {
        throw "-TrustManifest must not resolve inside a read-only SWD directory. '$(Format-PathForDisplay $TrustManifest)' resolves to '$(Format-PathForDisplay $candidate)', which is at or under '$(Format-PathForDisplay $hit)'."
    }
}

function Get-Sha256Hex {
    <# Get-FileHash is NOT available in this Windows PowerShell 5.1 host - measured,
       it throws CommandNotFoundException - so hash through .NET directly rather
       than through the cmdlet the docs would suggest. #>
    param([Parameter(Mandatory)][string] $Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-LibraryRelativePath {
    <# Path relative to the library root. The manifest stores ONLY these, never an
       absolute path: an absolute one carries the username and the institutional
       tenant, and re-leaking those through a new file is precisely what the
       output-directory restriction exists to prevent. #>
    param([Parameter(Mandatory)][string] $Path)
    $root = $BiblioPath.TrimEnd('\') + '\'
    if ($Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($root.Length)
    }
    return [IO.Path]::GetFileName($Path)
}

$script:TrustedHashes = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:UntrustedSeen = New-Object 'System.Collections.Generic.List[string]'
if (Test-Path -LiteralPath $TrustManifest) {
    $tmDoc = Get-Content -Raw -LiteralPath $TrustManifest | ConvertFrom-Json
    foreach ($e in $tmDoc.files) { [void]$script:TrustedHashes.Add([string]$e.sha256) }
}

function Test-SwdFileTrusted {
    <# SHA-256 of the content against the approved set. A hash, not a path: a path
       allowlist would still trust a file whose bytes changed underneath it. #>
    param([Parameter(Mandatory)][string] $Path)
    if ($AllowUntrustedFiles) { return $true }
    $h = Get-Sha256Hex -Path $Path
    if ($script:TrustedHashes.Contains($h)) { return $true }
    [void]$script:UntrustedSeen.Add((Get-LibraryRelativePath -Path $Path))
    return $false
}

if ($TrustCurrentLibrary) {
    # -Include is unreliable beside -LiteralPath, so filter on the extension.
    $allFyn = @(Get-ChildItem -LiteralPath $BiblioPath -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -like '.fyn*' })
    $entries = @(foreach ($f in $allFyn) {
        [ordered]@{ path = (Get-LibraryRelativePath -Path $f.FullName); sha256 = (Get-Sha256Hex -Path $f.FullName) }
    })
    $tmDir = Split-Path -Parent $TrustManifest
    if ($tmDir -and -not (Test-Path -LiteralPath $tmDir)) { New-Item -ItemType Directory -Force -Path $tmDir | Out-Null }
    $doc = [ordered]@{
        generated_utc = (Get-Date).ToUniversalTime().ToString('o')
        file_count    = $entries.Count
        files         = $entries
    }
    [IO.File]::WriteAllText($TrustManifest, ($doc | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    Write-Host "recorded $($entries.Count) file(s) into $(Format-PathForDisplay $TrustManifest)"
    Write-Host 'Nothing was extracted. Re-run without -TrustCurrentLibrary to extract.'
    return
}

# --- Assembly resolution ----------------------------------------------------
# Reports are stamped "SurfHydrodynamics, Version=1.0.0.5" but the installed
# assembly is 1.0.8.1, so the default binder fails and AssemblyResolve fires.
# The handler MUST return an already-loaded assembly before trying LoadFrom:
# an unguarded LoadFrom here re-enters the handler and dies with an
# uncatchable StackOverflowException.
$onResolve = [System.ResolveEventHandler] {
    param($src, $e)
    $name = ($e.Name -split ',')[0]
    foreach ($a in [AppDomain]::CurrentDomain.GetAssemblies()) {
        if ($a.GetName().Name -eq $name) { return $a }
    }
    return $null
}
[AppDomain]::CurrentDomain.add_AssemblyResolve($onResolve)

[void][Reflection.Assembly]::LoadFrom((Join-Path $InstallPath 'SurfHydrodynamics.exe'))
[void][Reflection.Assembly]::LoadFrom((Join-Path $InstallPath 'SlimDX.dll'))
$asm = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'SurfHydrodynamics' } | Select-Object -First 1
if (-not $asm) { throw 'Failed to load SurfHydrodynamics assembly.' }

# GetType(name) rather than GetTypes(): the latter throws
# ReflectionTypeLoadException on this build (some types reference absent deps).
$T_board   = $asm.GetType('SurfHydrodynamics.Class_surfboard')
$T_report  = $asm.GetType('SurfHydrodynamics.Class_rapport_hydrodynamique')
$T_element = $asm.GetType('SurfHydrodynamics.element_hydrodynamique')
foreach ($t in @($T_board, $T_report, $T_element)) { if (-not $t) { throw 'Expected SWD type missing.' } }

# THE 1023.154 / +0.015%-BIAS ACCOUNT THAT STOOD HERE WAS WRONG, and wrong in a
# way that produced a phantom speed. It read the corpus mean of
# mass_flux/frontal_section (20463.09, sd 10.68) as one number with scatter. It
# is not one number: it is a BIMODAL MIXTURE of exactly two values, and the
# "standard deviation" was the gap between them. Pinning rho at 1023.0 then
# divided the 1025 group by the wrong density and generated 20500/1023 =
# 20.0391 m/s - a speed no scan ever ran at, on 154 of 720 operating points.
#
# The block below is COPIED VERBATIM from extract_board.ps1, not re-derived.
# tests/extract_board.Tests.ps1 asserts the two copies stay byte-identical, so a
# change to one that is not made to the other fails the suite rather than
# silently forking the physics.
# Water density is NOT a single constant and NOT a formula. Recovered from
# Form_shaper.actualiser_fluide(): SWD looks it up from a 4-entry table indexed by
# temperature_eau, which must be one of 0/10/20/30 C, with separate salt and fresh
# arrays. rho can only ever be one of these eight values:
#
#     salt : 1028 / 1027 / 1025 / 1023          (0 / 10 / 20 / 30 C)
#     fresh: 999.87 / 999.73 / 998.23 / 995.67
#
# This settles a standing question. mass_flux/frontal_section is exactly rho*V,
# and across the corpus it takes exactly TWO values: 20460.0 (5,404 elements) and
# 20500.0 (1,404). Those are 1023*20.000 and 1025*20.000 - ONE flow speed at TWO
# water temperatures, not two speeds. Dividing the 1025 group by an assumed 1023
# is what produced the phantom "20.0391 m/s": 20500/1023 = 20.0391 exactly.
#
# So rho is inferred per element: the measured rho*V is divided by the fixed
# hydroscan velocity V_REF below and the result snapped to the nearest table
# entry, with the residual TESTED rather than assumed (see $RHO_SNAP_RTOL). The
# old note about a +0.015% bias described an artifact of averaging a bimodal
# mixture, and no longer applies.
$RHO_TABLE = @(1028.0, 1027.0, 1025.0, 1023.0, 999.87, 999.73, 998.23, 995.67)

# V_REF IS AN INFERENCE, and it is the one thing here that would be worth
# re-testing if a scan ever runs at another speed. The evidence:
#
#   * rho*V is measured to ~1e-6 relative and takes exactly TWO values across the
#     whole corpus - 20460.0 (5,404 elements) and 20500.0 (1,404). That is all
#     6,865 of the 6,867 rows that have a computable rho*V at all.
#   * Each is an exact product of ONE table density and the SAME velocity:
#     1023 * 20.000 and 1025 * 20.000, both with residual identically ZERO.
#
#     THIS IS A PLAUSIBILITY BOUND, NOT A UNIQUENESS PROOF, and an earlier
#     version of this comment claimed otherwise. Searching all 64 (rho1, rho2)
#     pairs, EXACTLY ONE other velocity also decomposes both corpus values onto
#     the table inside $RHO_SNAP_RTOL: V = 20460/1025 = 19.960976 m/s, which puts
#     the 20500 group at 1027.0038 - residual 3.807e-06, still 5.3x inside the
#     tolerance. It is not excluded by the arithmetic. 20.000 is preferred for
#     two reasons that are weaker than a proof and are stated as such: its
#     residual is exactly zero where the alternative's is not, and 20.000 is a
#     round figure a speed box would hold where 19.960976 is not. The earlier
#     comment tested only rho = 1028 for the 20460 group, found 1030.0 for the
#     other, and stopped - one counterexample short of the one that survives.
#   * The 2026-08-31 live run set the GUI flow box to 10 m/s and all 53 new
#     operating points still recovered ~20.04 m/s, i.e. the same rho*V.
#
# So the hydroscan runs at a FIXED 20.000 m/s regardless of the board's stored
# vitesse_flux_relatif_ms. Decomposing against that stored setting - which is
# what this function used to do - is the same mistake CLAUDE.md section 6 and
# swd_extract.ps1:50-52 both warn about: on the 8 of 14 scanned boards whose
# setting is not 20, rho*V / setting lands at 1578-10230 kg/m^3, up to 9.95x
# outside the table, and the nearest-neighbour snap still returned a confident
# 1028 with scan_speed_ms = 19.9027.
$V_REF = 20.000

# Relative tolerance on the snap. Bounded from BOTH sides, and the binding
# constraint is not the obvious one:
#
#   floor - the worst residual over those 6,865 elements is 5.27e-6
#           (default_shortboard's own worst is 2.5e-7). Below that the guard
#           starts refusing real measurements.
#   cap   - it must be under HALF the gap to the next table entry, or the whole
#           interval between two entries is accepted and the guard can never
#           reject anything there. The closest pair is NOT 1028/1027 (9.7e-4
#           apart, half-gap 4.9e-4) but the fresh-water 999.87/999.73, only
#           1.40e-4 apart - half-gap 7.0e-5.
#
# 2e-5 is 3.8x the worst observed residual and 3.5x inside that half-gap. Note
# the discrimination is asymmetric and this is a real limit, not a rounding of
# one: 24x of margin against the salt entries the corpus actually uses, 3.5x
# against the two closest fresh-water ones. Outside the tolerance rho and
# scan_speed_ms are refused (NaN) and the run warns - a scan at a genuinely
# different speed must surface as missing data, never as a wrong density.
$RHO_SNAP_RTOL = 2e-5

$script:RhoSnapMisses = 0
$script:RhoSnapWorst  = 0.0
function Get-InferredRho {
    <# Which tabulated density this element's rho*V implies, at the fixed
       hydroscan velocity V_REF.

       rho*V is measured to ~1e-6 relative. Dividing it by V_REF gives a density
       candidate that must land on one of the eight values SWD can select; the
       nearest is taken, and the RESIDUAL IS TESTED. Outside $RHO_SNAP_RTOL the
       premise has failed - either the scan did not run at V_REF, or rho*V is not
       what it is believed to be - and the honest answer is NaN, not the nearest
       table entry. Returning the nearest unconditionally is what let an
       out-of-table candidate of 10230 kg/m^3 come back as a confident 1028.

       Deliberately does NOT take the board's stored speed setting: see $V_REF. #>
    param([double] $RhoV)
    if ([double]::IsNaN($RhoV)) { return [double]::NaN }
    $cand = $RhoV / $V_REF
    $best = [double]::NaN; $bestD = [double]::MaxValue
    foreach ($r in $RHO_TABLE) {
        $d = [Math]::Abs($r - $cand)
        if ($d -lt $bestD) { $bestD = $d; $best = $r }
    }
    # Tracked on EVERY call, not only on a miss. Updating it inside the miss
    # branch meant a clean run published snap_worst_rel = 0.0 - which reads as
    # "perfect" and is the single number that makes V_REF credible. The live
    # manifest said 0 where the true worst residual was 2.5095e-07.
    $rel = $bestD / $best
    if ($rel -gt $script:RhoSnapWorst) { $script:RhoSnapWorst = $rel }
    if ($rel -gt $RHO_SNAP_RTOL) {
        $script:RhoSnapMisses++
        return [double]::NaN
    }
    return $best
}


$BIND = [Reflection.BindingFlags]'Public,NonPublic,Instance'
$fmt  = New-Object System.Runtime.Serialization.Formatters.Binary.BinaryFormatter

# Accented field names are built by code point so this file's own encoding
# cannot corrupt them. e9 = e-acute.
$E = [char]0xE9
$F_DRAG_TOTAL = "_train${E}e_globale_horizontale_n"
$F_WET_LEN    = "_longueur_mouill${E}e_element_mm"
$F_FRONT_SEC  = "_section_frontale_flux_d${E}vi${E}_m2_planing"
$F_MASS_FLUX  = "_masse_flux_d${E}vi${E}_kg_sec_planing"

$script:WarnedOnce = New-Object 'System.Collections.Generic.HashSet[string]'
function Write-WarningOnce {
    <# Same message once per run: a per-board or per-element warning would
       otherwise repeat thousands of times and bury everything else. #>
    param([Parameter(Mandatory)][string] $Message)
    if ($script:WarnedOnce.Add($Message)) { Write-Warning $Message }
}

function Get-FieldValue {
    <# Read a field by name, returning $null if the type has no such field. #>
    param([Parameter(Mandatory)] $Object, [Parameter(Mandatory)][string] $Name, $Type = $null)
    if (-not $Type) { $Type = $Object.GetType() }
    $fi = $Type.GetField($Name, $BIND)
    if (-not $fi) { return $null }
    return $fi.GetValue($Object)
}

$script:SentinelHits = @{}
$SENTINEL_LIMIT = 1e30

function ConvertTo-Measurement {
    <# A raw field value as a MEASUREMENT, or NaN.

       SWD leaves some Single fields at Single.MaxValue (3.4028235e38) on
       non-contact elements: a sentinel, not a number. A plain [double] cast
       carries it into the CSV, where it reads as data and destroys any
       standardisation of the column - the shipped elements.csv carried 68 rows of
       element_width_mm = 3.40282346638529E+38 for exactly this reason, because
       this script had the clamp extract_board.ps1 had and swd_extract.ps1 did
       not. Counted per field name and reported at the end. #>
    param($Value, [string] $Name)
    if ($null -eq $Value) { return [double]::NaN }
    if ($Value -is [bool]) { return [double]([int]$Value) }
    $d = [double]$Value
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d) -or [Math]::Abs($d) -gt $SENTINEL_LIMIT) {
        if (-not $script:SentinelHits.ContainsKey($Name)) { $script:SentinelHits[$Name] = 0 }
        $script:SentinelHits[$Name]++
        return [double]::NaN
    }
    return $d
}

function Get-FieldDouble {
    <# Field -> double, mapping BOTH an absent field and a null value to NaN.
       [double]$null is 0, so the obvious cast turns missing data into a real
       measurement of zero - the fake-zero failure this script exists to avoid.
       The element path has always done this; the board path used to cast
       straight to [double] and silently reported 0.0 kg. #>
    param([Parameter(Mandatory)] $Object, [Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][Type] $Type)
    $fi = $Type.GetField($Name, $BIND)
    if (-not $fi) {
        Write-WarningOnce "field not found on $($Type.Name), writing NaN: $Name"
        return [double]::NaN
    }
    $v = $fi.GetValue($Object)
    if ($null -eq $v) {
        Write-WarningOnce "field is null on $($Type.Name), writing NaN: $Name"
        return [double]::NaN
    }
    return ConvertTo-Measurement -Value $v -Name $Name
}

function Measure-PolarBlockCount {
    <# Independent count of the <Table4> blocks, by raw text scan rather than a
       second XmlReader pass, so the check does not share the parser it checks.
       This exists because the reader loop below silently returned exactly half
       the database for the whole life of the first version. #>
    param([Parameter(Mandatory)][string] $Path)
    $count = 0
    $srdr = New-Object System.IO.StreamReader($Path)
    try {
        while ($null -ne ($line = $srdr.ReadLine())) {
            $at = 0
            while (($at = $line.IndexOf('<Table4', $at, [StringComparison]::Ordinal)) -ge 0) {
                $after = if ($at + 7 -lt $line.Length) { $line[$at + 7] } else { [char]0x3E }
                if ($after -eq [char]0x3E -or $after -eq [char]0x20 -or $after -eq [char]0x09 -or $after -eq [char]0x2F) {
                    $count++
                }
                $at += 7
            }
        }
    } finally { $srdr.Dispose() }
    return $count
}

function Read-PolarDatabase {
    <# Parse fyn_profile_data_base.xml into polar rows. A FUNCTION rather than an
       inline loop specifically so the every-second-block defect has behavioural
       test coverage: the previous round could only assert the loop's SHAPE from
       source text, which is not the same as proving it reads every block.

       XmlReader streams the 26.9 MB file rather than holding it all as one DOM.
       Each block is still materialised as its own small XmlDocument by
       ReadOuterXml + [xml]; "no DOM at all" would overstate it. Measured block
       size: mean 14,245 bytes, range 12,318 - 14,582 over all 1,890 blocks. An
       earlier "~28 KB" here was a fossil of the halved block count - 26.9 MB
       over the 945 blocks that version actually parsed.

       Returns @{ Rows; Blocks; Expected }. THROWS if Blocks != Expected. #>
    param([Parameter(Mandatory)][string] $Path)
    $expected = Measure-PolarBlockCount -Path $Path
    $rows        = New-Object System.Collections.ArrayList
    $xmlSettings = New-Object System.Xml.XmlReaderSettings
    $xmlSettings.IgnoreWhitespace = $true
    $reader = [System.Xml.XmlReader]::Create($Path, $xmlSettings)
    $blocks = 0
    try {
        # NOT ReadToFollowing. ReadOuterXml leaves the reader ON the next node,
        # and ReadToFollowing calls Read() before it tests - so with
        # IgnoreWhitespace (no text nodes between blocks) that next node IS the
        # following <Table4> and it got stepped over. Every second block was
        # dropped and the run reported the halved row count as success. Test the
        # current node instead of advancing to find one.
        while (-not $reader.EOF) {
            if ($reader.NodeType -ne [System.Xml.XmlNodeType]::Element -or $reader.LocalName -ne 'Table4') {
                [void]$reader.Read()
                continue
            }
            $blocks++
            $node = [xml]$reader.ReadOuterXml()
            $t = $node.DocumentElement
            $angles = @(ConvertTo-DoubleList (Get-XmlText $t 'list_angles'))
            $cls    = @(ConvertTo-DoubleList (Get-XmlText $t 'list_cl'))
            $cds    = @(ConvertTo-DoubleList (Get-XmlText $t 'list_cd'))
            $cms    = @(ConvertTo-DoubleList (Get-XmlText $t 'list_cm'))
            $counts = @($angles.Count, $cls.Count, $cds.Count)
            $nPts = ($counts | Measure-Object -Minimum).Minimum
            $mPts = ($counts | Measure-Object -Maximum).Maximum
            if (-not $nPts -or $nPts -eq 0) { continue }
            # Truncating to the shortest list silently discards the tail of the
            # longer ones, so count it and report it.
            if ($mPts -ne $nPts) { $script:PolarTruncated++ }

            $ic = [Globalization.CultureInfo]::InvariantCulture
            $re = 0.0;  [void][double]::TryParse(((Get-XmlText $t 'Re')        -replace ',', '.'), [Globalization.NumberStyles]::Float, $ic, [ref]$re)
            $th = 0.0;  [void][double]::TryParse(((Get-XmlText $t 'epaisseur') -replace ',', '.'), [Globalization.NumberStyles]::Float, $ic, [ref]$th)
            $prof = [string](Get-XmlText $t 'nom_profil')

            for ($i = 0; $i -lt $nPts; $i++) {
                [void]$rows.Add([pscustomobject][ordered]@{
                    profile      = $prof
                    thickness    = $th
                    reynolds     = $re
                    angle_deg    = $angles[$i]
                    cl           = $cls[$i]
                    cd           = $cds[$i]
                    cm           = if ($i -lt $cms.Count) { $cms[$i] } else { [double]::NaN }
                })
            }
        }
    } finally { $reader.Dispose() }

    # Permanent assertion. Terminating, not a warning: a half-parsed polar table
    # is indistinguishable from a complete one by row count alone, and that is
    # exactly how the defect survived.
    if ($blocks -ne $expected) {
        throw "fin polar parse incomplete: parsed $blocks of $expected <Table4> blocks in $Path. The known cause is advancing the XmlReader past a block after ReadOuterXml."
    }
    return @{ Rows = $rows; Blocks = $blocks; Expected = $expected }
}

function Get-MedianDouble {
    <# True median of a double list. sorted[Count/2] on its own is the
       upper-middle value on an even count (1,2,3,4 -> 3), i.e. a quantile.
       Returns NaN for an empty list rather than throwing. #>
    param([Parameter(Mandatory)] $Values)
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { return [double]::NaN }
    $mid = [int][math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) { return [double]$sorted[$mid] }
    return ([double]$sorted[$mid - 1] + [double]$sorted[$mid]) / 2.0
}

function Get-BoardNameFromPath {
    <# The board a report belongs to: the FIRST path segment under
       rapports_hydro. -Recurse admits a report at any depth, and the immediate
       parent's name would then be an intermediate directory that matches no row
       in boards.csv. Falls back to the old one-level hop for a path outside the
       root rather than throwing. #>
    param([Parameter(Mandatory)][string] $FullName, [Parameter(Mandatory)][string] $ScanRoot)
    $rootFull = [IO.Path]::GetFullPath($ScanRoot).TrimEnd('\')
    if ($FullName.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        return ($FullName.Substring($rootFull.Length + 1) -split '[\\/]')[0]
    }
    return Split-Path (Split-Path $FullName -Parent) -Leaf
}

function Get-XmlText {
    <# Text of a child element by local name, $null if absent. Matched over
       ChildNodes rather than by property access: the file carries a default
       xmlns, and Set-StrictMode turns a missing property into a terminating
       error, which would abort the whole run over one optional element. #>
    param([Parameter(Mandatory)] $Element, [Parameter(Mandatory)][string] $Name)
    foreach ($c in $Element.ChildNodes) { if ($c.LocalName -eq $Name) { return $c.InnerText } }
    return $null
}

function ConvertTo-DoubleList {
    <# "0,9956;0,0004;..." -> double[]. Comma is the decimal point here. #>
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $ic = [Globalization.CultureInfo]::InvariantCulture
    return @(
        foreach ($tok in $Text.Split(';')) {
            $t = $tok.Trim()
            if ($t) {
                $d = 0.0
                if ([double]::TryParse($t.Replace(',', '.'), [Globalization.NumberStyles]::Float, $ic, [ref]$d)) { $d }
                # Dropping a token silently would shift every later index and
                # mis-pair angle/cl/cd, so unparseable tokens are counted and
                # reported at the end of the polar section.
                else { $script:PolarBadTokens++ }
            }
        }
    )
}

function Format-MessageForDisplay {
    <# A .NET IOException embeds the full absolute path, so an error message is a
       second route for the username and the institutional tenant folder to reach
       a pasted console log - the same leak Format-PathForDisplay exists to close,
       arriving through free text instead of a path parameter. Longest roots
       first: OneDrive lives under USERPROFILE. #>
    param([string] $Message)
    foreach ($root in @($env:OneDriveCommercial, $env:OneDriveConsumer, $env:OneDrive)) {
        if ($root) { $Message = $Message.Replace($root, '~\OneDrive') }
    }
    if ($env:USERPROFILE) { $Message = $Message.Replace($env:USERPROFILE, '~') }
    return $Message
}

function Read-SwdFile {
    <# Deserialise one .fyn* file. Returns $null on failure (caller counts it).
       The trust check is FIRST - BinaryFormatter must never see a stream whose
       provenance has not been approved - and it is INSIDE the try, which is
       load-bearing rather than tidy: Test-SwdFileTrusted hashes the file, so its
       ReadAllBytes is the run's FIRST I/O on it. With the try around only the
       Deserialize, a single locked or unreadable file threw out of the hash and,
       under $ErrorActionPreference = 'Stop', took the whole run with it before
       anything was written. Measured on the identical arrangement in
       extract_board.ps1: one exclusively-locked report ended the run having read
       0 of 11 files and produced no CSVs at all. #>
    param([Parameter(Mandatory)][string] $Path)
    $fs = $null
    try {
        if (-not (Test-SwdFileTrusted -Path $Path)) { return $null }
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        return $fmt.Deserialize($fs)
    } catch {
        Write-Warning "read failed, skipped: $(Format-PathForDisplay $Path) :: $(Format-MessageForDisplay $_.Exception.Message)"
        return $null
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

$script:DroppedColumns = [ordered]@{}
# Which tables THIS run actually wrote. The completion sentinel is built from
# this and nothing else, so it can never vouch for a file left behind by an
# earlier run.
$script:WrittenTables = [ordered]@{}
function Get-ConstantZeroColumn {
    <# Names of numeric columns that are zero on EVERY row.

       These are not caught by any null check: SWD's hydroscan path leaves a
       number of genuinely-[Serializable] fields unassigned, so they deserialise
       as a real 0.0. A column of those looks exactly like measured data. The
       scan drops a candidate the moment it sees a non-zero, so the common case
       costs one comparison per column. -Keep protects structural index columns,
       which are legitimately all-zero on a single-board or single-case run. #>
    param([Parameter(Mandatory)] $Rows, [string[]] $Keep = @())
    $rows = @($Rows)
    if ($rows.Count -eq 0) { return @() }
    $cand = New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in $rows[0].PSObject.Properties) {
        if ($Keep -contains $p.Name) { continue }
        if ($p.Value -is [string] -or $p.Value -is [bool]) { continue }
        [void]$cand.Add($p.Name)
    }
    foreach ($r in $rows) {
        if ($cand.Count -eq 0) { break }
        for ($i = $cand.Count - 1; $i -ge 0; $i--) {
            $v = $r.($cand[$i])
            # -as, not a [double] cast: the cast THROWS on a value that is not
            # numeric (a DateTime column, a nested object), which would abort the
            # whole run from inside a purely advisory check. -as yields $null and
            # the column is kept, which is the safe direction.
            if ($null -ne $v) {
                $d = $v -as [double]
                if ($null -eq $d -or $d -ne 0.0) { $cand.RemoveAt($i) }
            }
        }
    }
    return $cand.ToArray()
}

function Write-CsvNoBom {
    <# CSV without a UTF-8 BOM: Python's json/csv readers choke on it.
       Streamed rather than -join'ed: fin_polars.csv is ~100 MB of text and
       materialising it as one string first is pure transient allocation.
       ConvertTo-Csv still does the quoting, so the bytes are unchanged. #>
    param([Parameter(Mandatory)] $Rows, [Parameter(Mandatory)][string] $Path, [string[]] $Keep = @())
    $rows  = @($Rows)
    $count = $rows.Count
    if ($count -eq 0) { Write-Warning "no rows for $([IO.Path]::GetFileName($Path)) - not written"; return }

    $name = [IO.Path]::GetFileName($Path)
    $drop = @(Get-ConstantZeroColumn -Rows $rows -Keep $Keep)
    if ($drop.Count -gt 0) {
        Write-Warning "$name : dropping $($drop.Count) column(s) that are zero on every one of the $count rows - SWD never populates them, and exporting them would read as data: $($drop -join ', ')"
        $script:DroppedColumns[$name] = @($drop)
        $rows = @($rows | Select-Object -Property * -ExcludeProperty $drop)
    } else {
        $script:DroppedColumns[$name] = @()
    }

    $sw = New-Object System.IO.StreamWriter($Path, $false, (New-Object Text.UTF8Encoding($false)))
    try {
        $sw.NewLine = "`r`n"
        foreach ($line in ($rows | ConvertTo-Csv -NoTypeInformation)) { $sw.WriteLine($line) }
    } finally { $sw.Dispose() }
    $script:WrittenTables[$name] = [ordered]@{
        rows = $count
        cols = @($rows[0].PSObject.Properties).Count
    }
    "  wrote $name  rows=$count  cols=$(@($rows[0].PSObject.Properties).Count)"
}

# ---------------------------------------------------------------------------
# Serialised element fields worth exporting.
#
# 36 of element_hydrodynamique's 101 fields are [NonSerialized]. Those come back
# as 0/null after deserialisation regardless of what the physics was, so
# exporting them would produce columns of fake zeros that look like data. Every
# name below was checked to be genuinely serialised. Notable exclusions:
# _moment_yaw_total_nm, _moment_yaw_hydrodynamic_nm, all _projection_*,
# _list_vitesse_moyenne_veine_ms, planche_ref, infos_planing.
# Yaw rate is derived instead, as R_z = V / R.
#
# THAT CHECK IS NOT SUFFICIENT ON ITS OWN, and believing it was is how 13 of
# these columns shipped as fake zeros anyway. [NonSerialized] is only the first
# failure mode; the second is a field that IS serialised and that SWD's
# hydroscan path never assigns, which deserialises to a real 0.0 that no null
# check can distinguish from a measurement. Reflection over
# FieldAttributes.NotSerialized says every name below is serialised - and 13 of
# them are still zero on all 5,914 rows. The runtime constant-zero drop in
# Write-CsvNoBom is what actually catches that, so keep the list here honest
# about intent and let the writer decide what reaches the CSV.
# ---------------------------------------------------------------------------
$ELEMENT_FIELDS = [ordered]@{
    roll_attack_rad        = 'inclinaison_roulis_rad_ligne_attack'
    roll_surface_rad       = 'inclinaison_roulis_rad_ligne_surface'
    drag_total_n           = $F_DRAG_TOTAL
    drag_friction_n        = '_Fx_friction_n'
    drag_planing_n         = '_Fx_planing'
    drag_rail_n            = '_Fx_rail_n'
    drag_rocker_n          = '_Fx_rocker'
    lift_total_n           = '_portance_globale_verticale_n'
    lift_planing_n         = '_Fz_planing_n'
    contact_area_m2        = '_surface_contact_m2'
    max_area_m2            = '_surface_max_element_m2'
    immersed_section_m2    = '_surface_coupe_partie_immergee_m2'
    frontal_section_m2     = $F_FRONT_SEC
    mass_flux_kg_s         = $F_MASS_FLUX
    dynamic_pressure_pa    = '_pression_dynamique_B'
    cv_savitsky            = '_Cv_Savitsky'
    lambda_savitsky        = '_lamda_Savitsky'
    cl0_savitsky           = '_Cl0_Savitsky'
    cl0_theoretical        = '_Cl0_theorique'
    boundary_layer_mm      = '_boundary_layer_mm'
    laminar_bl_mm          = '_laminar_boundary_layer_mm'
    lam_turb_transition_mm = '_laminar_turbulent_transition_mm'
    element_length_mm      = '_longueur_element_mm'
    wetted_length_mm       = $F_WET_LEN
    element_width_mm       = '_largeur_B_element_mm'
    plane_delta_deg        = '_delta_plan_horizontal_deg'
    rail_deviation_deg     = '_deviation_rail_deg'
    volume_litres          = '_volume_litres'
}
# Two names above differ by accent between builds; resolve each once against the
# real type and drop any that genuinely do not exist.
$resolved = [ordered]@{}
foreach ($k in $ELEMENT_FIELDS.Keys) {
    $fieldName = $ELEMENT_FIELDS[$k]
    if ($T_element.GetField($fieldName, $BIND)) { $resolved[$k] = $fieldName; continue }
    $alt = $T_element.GetFields($BIND) | Where-Object {
        ($_.Name -replace '[^\x20-\x7E]', '?') -eq ($fieldName -replace '[^\x20-\x7E]', '?')
    } | Select-Object -First 1
    if ($alt) { $resolved[$k] = $alt.Name }
    else { Write-Warning "element field not found, skipping column: $fieldName" }
}
$ELEMENT_FIELDS = $resolved

# The element loop reads ~165,000 fields. Going through an advanced function
# that calls Type.GetField on every read pays a string lookup and a full
# PowerShell function invocation each time; resolving FieldInfo once and calling
# GetValue directly is by a wide margin the largest saving available here.
#
# -SkipElements only needs the ten fields the operating-point aggregates consume,
# so it reads ten instead of twenty-eight rather than computing the rest and
# throwing them away.
$OP_KEYS = @(
    'roll_attack_rad', 'drag_total_n', 'drag_friction_n', 'drag_planing_n', 'drag_rail_n',
    'lift_total_n', 'contact_area_m2', 'volume_litres', 'mass_flux_kg_s', 'frontal_section_m2'
)
$READ_KEYS = if ($SkipElements) { @($OP_KEYS | Where-Object { $ELEMENT_FIELDS.Contains($_) }) }
             else               { @($ELEMENT_FIELDS.Keys) }
$READ_FI   = @(foreach ($k in $READ_KEYS) { $T_element.GetField($ELEMENT_FIELDS[$k], $BIND) })

# An aggregate whose source column failed to resolve would otherwise sum $null
# as zero. Say so once, and fill NaN so the sum is visibly missing instead.
$OP_MISSING = @($OP_KEYS | Where-Object { $READ_KEYS -notcontains $_ })
if ($OP_MISSING.Count -gt 0) {
    Write-Warning "operating-point aggregates have no source column for: $($OP_MISSING -join ', ') - those sums will be NaN"
}

# Run-scoped counters. Declared here because Set-StrictMode makes ++ on an
# undefined variable an error, and because every one of them is reported at the
# end: a count that is never printed is a count nobody acts on.
$script:PolarBadTokens = 0
$script:PolarTruncated = 0
$script:NanAggregates  = 0
$script:SpeedSpreadHits = 0
$script:SpeedSpreadWorst = 0.0

Write-Host "SWD extract"
Write-Host "  assembly : $($asm.GetName().FullName)"
Write-Host "  biblio   : $(Format-PathForDisplay $BiblioPath)"
Write-Host "  out      : $(Format-PathForDisplay $OutDir)"
Write-Host "  element columns resolved: $($ELEMENT_FIELDS.Count)"

# ===========================================================================
# 1. BOARDS
# ===========================================================================
Write-Host "`n[1/4] boards"
$scanRoot   = Join-Path $BiblioPath 'rapports_hydro'
$boardFiles = @(Get-ChildItem -LiteralPath (Join-Path $BiblioPath 'Boards') -Recurse -Filter *.fynbs -File)
$boardRows  = @()
# Ordinal, not the default case-insensitive comparer: two .fynbs differing only
# in case are two different files on NTFS and must not collide into one entry.
$boardIndex = New-Object 'System.Collections.Hashtable' ([StringComparer]::Ordinal)
$boardFail  = 0

foreach ($bf in $boardFiles) {
    $name = [IO.Path]::GetFileNameWithoutExtension($bf.Name)
    $bd = Read-SwdFile -Path $bf.FullName
    if (-not $bd) { $boardFail++; continue }

    $scanDir  = Join-Path $scanRoot $name
    $scanCount = 0
    if (Test-Path -LiteralPath $scanDir) {
        $scanCount = @(Get-ChildItem -LiteralPath $scanDir -Filter *.fynrhydro -File -ErrorAction SilentlyContinue).Count
    }

    # Get-FieldDouble, not [double](Get-FieldValue ...): the cast turns a missing
    # or null field into 0.0, which is indistinguishable from a measured zero.
    $speed  = Get-FieldDouble -Object $bd -Name '_vitesse_flux_relatif_ms' -Type $T_board
    $radius = Get-FieldDouble -Object $bd -Name 'rayon_planning_m'         -Type $T_board

    # shaper_name is deliberately not exported - see the header. It named seven
    # people, including third parties, in a file that lands in a git tree with a
    # public remote, and it was never an ML feature.
    $row = [pscustomobject][ordered]@{
        board             = $name
        board_speed_setting_ms = $speed
        turn_radius_m     = $radius
        yaw_rate_rad_s    = if ($radius -ne 0 -and -not [double]::IsNaN($radius)) { $speed / $radius } else { [double]::NaN }
        total_mass_kg     = Get-FieldDouble -Object $bd -Name 'total_mass_kg'           -Type $T_board
        volume_shape_l    = Get-FieldDouble -Object $bd -Name 'volume_shape_litres'     -Type $T_board
        volume_float_l    = Get-FieldDouble -Object $bd -Name 'volume_flotaison_litres' -Type $T_board
        foam_mass_kg      = Get-FieldDouble -Object $bd -Name 'foam_mass_kg'            -Type $T_board
        structure_mass_kg = Get-FieldDouble -Object $bd -Name 'structure_mass_kg'       -Type $T_board
        scan_files        = $scanCount
        # 1/0 rather than $true/$false: ConvertTo-Csv renders a bool as the
        # strings "True"/"False", which pandas reads as an object column.
        has_hydroscan     = [int]($scanCount -gt 0)
    }
    $boardRows += $row
    $boardIndex[$name] = $row
}
Write-Host "  boards parsed: $($boardRows.Count) / $($boardFiles.Count)  (failed: $boardFail)"
Write-Host "  with hydroscan: $(@($boardRows | Where-Object has_hydroscan).Count)"
# All four CSVs are written together at the end, not here: writing boards.csv now
# and then throwing in section 2 leaves one fresh file beside three stale ones,
# with nothing on disk to say so.

# ===========================================================================
# 2. REPORTS -> operating points + elements
#
# Structure: one .fynrhydro per drift angle. list_elements_hydro is a ragged
# ArrayList of roll cases (observed 5 cases of 12/10/9/8/7 elements); fewer
# elements remain in contact as the board heels.
#
# An operating point is one (board, drift, roll case). Forces are summed across
# that case's elements, because a single element is a slice of the board, not an
# independent observation.
# ===========================================================================
Write-Host "`n[2/4] hydro reports"
$opRows      = @()
$elemRows    = @()
$reportFail  = 0
$reportFiles = @()
if (Test-Path -LiteralPath $scanRoot) {
    $reportFiles = @(Get-ChildItem -LiteralPath $scanRoot -Recurse -Filter *.fynrhydro -File)
}
Write-Host "  report files: $($reportFiles.Count)"

$reportIdx = 0
foreach ($rf in $reportFiles) {
    $reportIdx++
    if ($reportIdx % 25 -eq 0) { Write-Host "    $reportIdx / $($reportFiles.Count)" }

    $boardName = Get-BoardNameFromPath -FullName $rf.FullName -ScanRoot $scanRoot
    $rep = Read-SwdFile -Path $rf.FullName
    if (-not $rep) { $reportFail++; continue }

    $drift = Get-FieldDouble -Object $rep -Name 'angle_drift_deg' -Type $T_report
    $cases = Get-FieldValue -Object $rep -Name 'list_elements_hydro' -Type $T_report
    if (-not $cases) { continue }

    $b = $boardIndex[$boardName]
    if (-not $b) {
        Write-WarningOnce "no boards.csv row for '$boardName' - its reports get NaN speed/radius/mass and a board value matching no board row"
    }
    $boardSet = if ($b) { $b.board_speed_setting_ms } else { [double]::NaN }
    $radius   = if ($b) { $b.turn_radius_m }         else { [double]::NaN }
    $massKg   = if ($b) { $b.total_mass_kg }         else { [double]::NaN }

    for ($ci = 0; $ci -lt $cases.Count; $ci++) {
        $case = $cases[$ci]
        if (-not $case) { continue }

        $sumDrag = 0.0; $sumFric = 0.0; $sumPlan = 0.0; $sumRail = 0.0
        $sumLift = 0.0; $sumArea = 0.0; $sumVol  = 0.0
        # rollMin/rollMax start at NaN, not +/-Infinity: every comparison against
        # NaN is false, so seeded infinities would survive to the CSV as a real
        # -1.#INF reading. rollCount tracks how many rolls were actually present.
        $rollSum = 0.0; $rollMin = [double]::NaN; $rollMax = [double]::NaN
        $rollCount = 0
        $count = 0
        $scanSpeeds = New-Object System.Collections.Generic.List[double]
        $rhoVs      = New-Object System.Collections.Generic.List[double]
        $rhoRefused = 0
        $caseRhos   = New-Object 'System.Collections.Generic.HashSet[double]'

        for ($ei = 0; $ei -lt $case.Count; $ei++) {
            $el = $case[$ei]
            if (-not $el) { continue }
            $count++

            # Cached FieldInfo, indexed rather than enumerated: see $READ_FI.
            $vals = [ordered]@{}
            for ($fx = 0; $fx -lt $READ_KEYS.Count; $fx++) {
                $v = $READ_FI[$fx].GetValue($el)
                # ConvertTo-Measurement, not a bare [double] cast: the cast is what
                # let Single.MaxValue through as element_width_mm = 3.4e38.
                $vals[$READ_KEYS[$fx]] = ConvertTo-Measurement -Value $v -Name $ELEMENT_FIELDS[$READ_KEYS[$fx]]
            }
            foreach ($mk in $OP_MISSING) { $vals[$mk] = [double]::NaN }

            # The actual flow speed the scan ran at, recovered from the planing
            # mass balance  m_dot = rho * A * V.  This is NOT the board's stored
            # speed setting: see the header note on board_speed_setting_ms.
            #
            # rho is INFERRED per element rather than pinned - see $V_REF - so a
            # scan at a water temperature other than 30 C no longer has its
            # density error re-expressed as a fake speed.
            #
            # $fa -ne 0, not $fa -gt 0: SWD signs the frontal section and the
            # mass flux together by flow direction, so on the rows where both are
            # negative the quotient is a perfectly clean +20460 that the old
            # positive-only gate discarded.
            $mf = $vals['mass_flux_kg_s']; $fa = $vals['frontal_section_m2']
            $rhoV = if ($fa -ne 0 -and -not [double]::IsNaN($fa) -and -not [double]::IsNaN($mf)) { $mf / $fa } else { [double]::NaN }
            $rho  = Get-InferredRho -RhoV $rhoV
            $elSpeed = if (-not [double]::IsNaN($rhoV) -and $rho -gt 0) { $rhoV / $rho } else { [double]::NaN }
            # rho*V is collected whenever it was MEASURED, independently of whether
            # the snap then succeeded. Gating it on $elSpeed made the header's own
            # guarantee false ("always emitted, so nothing about the decomposition
            # can destroy the raw fact") and was the worst possible failure mode
            # for a future scan at another speed: the guard would refuse loudly and
            # simultaneously destroy the only quantity the true velocity could be
            # recovered from.
            if (-not [double]::IsNaN($rhoV)) { $rhoVs.Add($rhoV) }
            if (-not [double]::IsNaN($elSpeed)) { $scanSpeeds.Add($elSpeed) }
            # One scan runs at one water temperature, so every element of a case
            # must imply the SAME table density. Collected as a set: more than one
            # means the premise failed, and the operating point says so with NaN
            # rather than averaging two densities into a third that SWD cannot use.
            if (-not [double]::IsNaN($rho)) { [void]$caseRhos.Add($rho) } else { $rhoRefused++ }

            $roll = $vals['roll_attack_rad']
            if (-not [double]::IsNaN($roll)) {
                $rollCount++
                $rollSum += $roll
                if ([double]::IsNaN($rollMin) -or $roll -lt $rollMin) { $rollMin = $roll }
                if ([double]::IsNaN($rollMax) -or $roll -gt $rollMax) { $rollMax = $roll }
            }

            $sumDrag += $vals['drag_total_n']
            $sumFric += $vals['drag_friction_n']
            $sumPlan += $vals['drag_planing_n']
            $sumRail += $vals['drag_rail_n']
            $sumLift += $vals['lift_total_n']
            $sumArea += $vals['contact_area_m2']
            $sumVol  += $vals['volume_litres']

            if (-not $SkipElements) {
                $er = [ordered]@{
                    board         = $boardName
                    drift_deg     = $drift
                    roll_case     = $ci
                    element_index = $ei
                    board_speed_setting_ms = $boardSet
                    rho_v_kg_m2_s = $rhoV
                    rho_kgm3      = $rho
                    scan_speed_ms = $elSpeed
                    turn_radius_m = $radius
                }
                foreach ($k in $ELEMENT_FIELDS.Keys) { $er[$k] = $vals[$k] }
                $elemRows += [pscustomobject]$er
            }
        }

        if ($count -eq 0) { continue }

        # Median rather than mean, because the per-element values are claimed to
        # agree to ~6 significant figures and this just picks the representative
        # one. The agreement claim is CHECKED below rather than asserted.
        $scanSpeed = Get-MedianDouble -Values $scanSpeeds
        if ($scanSpeeds.Count -gt 0 -and $scanSpeed -ne 0) {
            $sorted = @($scanSpeeds | Sort-Object)
            $relSpread = [math]::Abs(($sorted[-1] - $sorted[0]) / $scanSpeed)
            if ($relSpread -gt 1e-6) { $script:SpeedSpreadHits++ }
            if ($relSpread -gt $script:SpeedSpreadWorst) { $script:SpeedSpreadWorst = $relSpread }
        }

        # A NaN element poisons its sum, which is the correct arithmetic but must
        # not be silent - a NaN force reads as "no data", not "zero force".
        foreach ($sm in @($sumDrag, $sumFric, $sumPlan, $sumRail, $sumLift, $sumArea, $sumVol)) {
            if ([double]::IsNaN($sm)) { $script:NanAggregates++ }
        }
        $yawRate = if ($radius -ne 0 -and -not [double]::IsNaN($radius) -and -not [double]::IsNaN($scanSpeed)) {
            $scanSpeed / $radius
        } else { [double]::NaN }

        $opRows += [pscustomobject][ordered]@{
            board            = $boardName
            drift_deg        = $drift
            roll_case        = $ci
            n_elements       = $count
            rho_v_kg_m2_s    = (Get-MedianDouble -Values $rhoVs)
            rho_kgm3         = $(if ($caseRhos.Count -eq 1) { @($caseRhos)[0] } else { [double]::NaN })
            # Without this a case where 39 of 40 elements REFUSED to snap is byte
            # identical to a clean one: the surviving element still sets
            # rho_kgm3 = 1023 and n_elements still reads 40. The count is the only
            # thing that distinguishes them, so it is published, not inferred.
            n_rho_refused    = $rhoRefused
            scan_speed_ms    = $scanSpeed
            board_speed_setting_ms = $boardSet
            roll_rad         = if ($rollCount -gt 0) { $rollSum / $rollCount } else { [double]::NaN }
            roll_min_rad     = $rollMin
            roll_max_rad     = $rollMax
            turn_radius_m    = $radius
            yaw_rate_rad_s   = $yawRate
            drag_total_n     = $sumDrag
            drag_friction_n  = $sumFric
            drag_planing_n   = $sumPlan
            drag_rail_n      = $sumRail
            lift_total_n     = $sumLift
            contact_area_m2  = $sumArea
            volume_litres    = $sumVol
            total_mass_kg    = $massKg
        }
    }
}

Write-Host "  reports parsed : $($reportFiles.Count - $reportFail) / $($reportFiles.Count)  (failed: $reportFail)"
Write-Host "  operating points: $($opRows.Count)"
Write-Host "  element rows    : $($elemRows.Count)"

# ===========================================================================
# 3. FIN POLARS  (plain XML per xml_structure.xsd - no .NET involved)
#
# Values use French locale conventions: comma decimal separator, semicolon list
# separator. Parsed explicitly rather than trusting the current culture.
# ===========================================================================
Write-Host "`n[3/4] fin polars"
$polarPath = Join-Path $InstallPath 'fyn_profile_data_base.xml'
$polarOut  = Join-Path $OutDir 'fin_polars.csv'
$polarRows = $null
$blocks    = 0
if (-not (Test-Path -LiteralPath $polarPath)) {
    Write-Warning "profile database not found: $polarPath"
} else {
    $polar = Read-PolarDatabase -Path $polarPath
    $polarRows = $polar.Rows
    $blocks    = $polar.Blocks
    if ($script:PolarTruncated -gt 0) {
        Write-Warning "$($script:PolarTruncated) polar block(s) had angle/cl/cd lists of unequal length and were truncated to the shortest."
    }
    if ($script:PolarBadTokens -gt 0) {
        Write-Warning "$($script:PolarBadTokens) polar value(s) failed to parse and were dropped; angle/cl/cd pairing in the affected blocks is not trustworthy."
    }
    Write-Host "  polar blocks: $blocks / $($polar.Expected)"
    Write-Host "  polar rows: $($polarRows.Count)"
}

# ===========================================================================
# 4. WRITE
#
# All four CSVs land here, together, and extract_manifest.json lands last. Any
# throw before this point leaves the previous run's CSVs untouched and no
# manifest, so a partial or mixed-vintage set is detectable from disk alone -
# which it was not when each section wrote as it finished.
#
# -Keep protects columns that are structurally allowed to be all-zero on a
# narrow corpus (a single roll case, one element per case, one drift angle)
# from the constant-zero drop, which is meant for SWD's unpopulated fields.
# ===========================================================================
Write-Host "`n[4/4] write"
Write-CsvNoBom -Rows $boardRows -Path (Join-Path $OutDir 'boards.csv') -Keep @('board', 'scan_files', 'has_hydroscan')
Write-CsvNoBom -Rows $opRows    -Path (Join-Path $OutDir 'operating_points.csv') -Keep @('drift_deg', 'roll_case')
if (-not $SkipElements) {
    Write-CsvNoBom -Rows $elemRows -Path (Join-Path $OutDir 'elements.csv') -Keep @('drift_deg', 'roll_case', 'element_index')
}
if ($null -ne $polarRows) {
    # thickness and reynolds complete the grouping key (profile, thickness,
    # reynolds); dropping either would make polar rows unjoinable.
    Write-CsvNoBom -Rows $polarRows -Path $polarOut -Keep @('profile', 'thickness', 'reynolds', 'angle_deg')
}

# Anything this run did not write is REMOVED. A -SkipElements run used to leave
# the previous run's elements.csv untouched and then stamp complete:true beside
# it - measured, byte-identical SHA-256 across a full run and a later
# -SkipElements run. The same reached fin_polars.csv when the profile database
# was missing, and any table via the zero-row early return. The directory now
# holds exactly one run's output, or none.
foreach ($known in @('boards.csv', 'operating_points.csv', 'elements.csv', 'fin_polars.csv')) {
    if ($script:WrittenTables.Contains($known)) { continue }
    $stale = Join-Path $OutDir $known
    if (Test-Path -LiteralPath $stale) {
        Write-Warning "removing $known - this run did not produce it, and leaving it would let the completion sentinel vouch for a table from a different run."
        Remove-Item -LiteralPath $stale -Force
    }
}

# ===========================================================================
# 5. SUMMARY
# ===========================================================================
Write-Host "`n[5/5] summary"
# Piped, NOT $boardRows.prop member enumeration. Under Set-StrictMode -Version
# Latest, enumerating a member on an EMPTY array is a terminating
# PropertyNotFoundStrict error, so a valid but empty corpus - a scoped run over
# the 15 shipped boards that have no hydroscan - crashed the summary. A pipeline
# over zero objects never evaluates the property at all.
$boardSettings = @($boardRows | ForEach-Object { $_.board_speed_setting_ms } | Sort-Object -Unique)
$scanSp   = @($opRows | ForEach-Object { $_.scan_speed_ms } | Where-Object { -not [double]::IsNaN($_) } | ForEach-Object { [math]::Round($_, 3) } | Sort-Object -Unique)
$radii    = @($boardRows | ForEach-Object { $_.turn_radius_m } | Sort-Object -Unique)
$rolls    = @($opRows | Where-Object { -not [double]::IsNaN($_.roll_rad) })
Write-Host "  scan speed   (m/s)   : $($scanSp -join ', ')   <- the physical condition"
Write-Host "  board setting (m/s)  : $($boardSettings -join ', ')   <- metadata, NOT the scan condition"
if ($radii.Count -gt 0) {
    Write-Host "  distinct radii  (m)  : $($radii.Count) values, $($radii[0]) .. $($radii[-1])"
}
if ($rolls.Count) {
    $rmin = ($rolls | Measure-Object roll_min_rad -Minimum).Minimum
    $rmax = ($rolls | Measure-Object roll_max_rad -Maximum).Maximum
    Write-Host "  roll (rad)           : $rmin .. $rmax"
}
# The median comment claims the per-element scan speeds agree to ~6 s.f. This
# reports whether that actually held this run, rather than leaving it asserted.
Write-Host "  scan-speed spread    : $($script:SpeedSpreadHits) / $($opRows.Count) operating points exceed 1e-6 relative; worst $([math]::Round($script:SpeedSpreadWorst, 9))"
if ($script:SpeedSpreadHits -gt 0) {
    Write-Warning "per-element scan speeds do not agree to 6 s.f. in $($script:SpeedSpreadHits) operating point(s); the median is no longer merely 'the representative one'."
}
if ($script:NanAggregates -gt 0) {
    Write-Warning "$($script:NanAggregates) summed force/area/volume value(s) are NaN because an element field was missing. NaN is correct arithmetic for missing data - do not read it as zero."
}
Write-Host "  parse failures       : boards=$boardFail reports=$reportFail"
if ($script:SentinelHits.Count -eq 0) {
    Write-Host '  sentinel values      : none'
} else {
    Write-Host '  sentinel values mapped to NaN (SWD leaves these set on non-contact elements):'
    foreach ($k in ($script:SentinelHits.Keys | Sort-Object)) { Write-Host ("      {0,-40} {1,6}" -f $k, $script:SentinelHits[$k]) }
}
Write-Host "  rho snap             : $($script:RhoSnapMisses) element(s) did not snap to a table density; worst relative residual $([math]::Round($script:RhoSnapWorst, 9))"
if ($script:RhoSnapMisses -gt 0) {
    Write-Warning "rho did not snap on $($script:RhoSnapMisses) element(s), so rho_kgm3 and scan_speed_ms are NaN there. That means the fixed-V_REF premise failed for those rows - re-derive V_REF before trusting any density in this run."
}
if ($AllowUntrustedFiles) {
    Write-Warning 'PROVENANCE GATE BYPASSED (-AllowUntrustedFiles): every .fyn* was deserialised without a trust check.'
} elseif ($script:UntrustedSeen.Count -gt 0) {
    # Loud, and listed: a refused file is a silently SHORTER dataset, which is the
    # failure mode this whole loop exists to prevent.
    Write-Warning "$($script:UntrustedSeen.Count) file(s) were NOT deserialised - absent from the trust manifest $(Format-PathForDisplay $TrustManifest):"
    foreach ($u in $script:UntrustedSeen) { Write-Warning "    $u" }
    Write-Warning 'Review each, then re-run with -TrustCurrentLibrary to approve the library as it now stands.'
    Write-Warning 'The tables above are INCOMPLETE by exactly those files.'
}
if ($boardFail -or $reportFail) { Write-Warning 'Some files failed to parse - see warnings above.' }

# Completion sentinel, written last and deleted at startup: its presence is the
# only thing on disk that says the CSVs beside it came from one complete run.
#
# It carries NO absolute paths and no tenant name. The manifest used to record
# $PSCommandPath, $BiblioPath and $InstallPath verbatim, which put the username
# and the OneDrive tenant folder name into SWD/data/ - a directory that is not
# gitignored, in a repo with a public remote. That is the same class of leak as
# the shaper_name column removed in the round before, reintroduced through a new
# file, so the manifest is restricted to what a consumer of the CSVs needs.
if ($script:WrittenTables.Count -eq 0) {
    Write-Warning "no tables were written, so no completion sentinel is created. The output directory holds no data from this run."
} else {
    $manifest = [ordered]@{
        generated_utc   = (Get-Date).ToUniversalTime().ToString('o')
        skip_elements   = [bool]$SkipElements
        tables          = $script:WrittenTables
        polar_blocks    = $(if ($null -eq $polarRows) { $null } else { $blocks })
        dropped_columns = $script:DroppedColumns
        parse_failures  = [ordered]@{ boards = $boardFail; reports = $reportFail }
        sentinel_hits   = $script:SentinelHits
        rho             = [ordered]@{
            v_ref_ms        = $V_REF
            snap_rtol       = $RHO_SNAP_RTOL
            snap_misses     = $script:RhoSnapMisses
            snap_worst_rel  = $script:RhoSnapWorst
        }
        warnings        = [ordered]@{
            nan_aggregates      = $script:NanAggregates
            polar_bad_tokens    = $script:PolarBadTokens
            polar_truncated     = $script:PolarTruncated
            scan_speed_spread   = $script:SpeedSpreadHits
        }
        complete        = $true
    }
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    Write-Host "  wrote $([IO.Path]::GetFileName($manifestPath))  <- completion sentinel"
}

Write-Host "`ndone -> $(Format-PathForDisplay $OutDir)"
