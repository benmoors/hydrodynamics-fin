<#
.SYNOPSIS
    Extract every usable value from ONE SWD board into ML-ready CSVs.

.DESCRIPTION
    Companion to census_board.ps1, which decides WHICH fields are real. This one
    writes them out. Beyond swd_extract.ps1 it adds:

      * every serialised numeric field, auto-discovered, not a hand-picked 22
      * elements_internes - 10 sub-elements per element, ~4,670 rows, previously
        ignored entirely
      * the report-level parallel lists (incidence, posx, posy, attack indices),
        which carry the planing angle SWD actually used
      * the wetted contact polygon in metres, per element
      * Single.MaxValue sentinel detection - SWD leaves _largeur_B_element_mm at
        3.4028235e38 on non-contact elements, and it passes silently through any
        reader that only checks for null or for all-zero columns

    DENSITY AND SPEED ARE INFERRED, AND THE INFERENCE CAN REFUSE.

      rho_kgm3      one of the eight densities SWD's own lookup table can select,
                    recovered by dividing the measured rho*V by a FIXED reference
                    velocity of 20.000 m/s and snapping. NOT decomposed against
                    the board's stored vitesse_flux_relatif_ms, which is the GUI
                    speed box as last saved and is not the scan condition.
      scan_speed_ms rho*V divided by that snapped density. It carries the
                    measurement residual, so it is a check on the inference
                    rather than an independent measurement of speed.
      rho_v_kg_m2_s the raw measured product, ALWAYS emitted. Nothing about the
                    decomposition can destroy it.

    When the snap residual exceeds the tolerance the first two are NaN and the
    run warns. A scan that did not run at 20.000 m/s must surface as missing
    data, never as a confident wrong density.

    READ-ONLY against the installation and library. Nothing is written outside
    -OutDir. SWD is never launched; Form_shaper is never constructed.

.NOTES
    Windows PowerShell 5.1 only (BinaryFormatter), x64 only.

    extract_manifest.json is written LAST and any stale one is deleted first, so
    it is a completion sentinel: no manifest means the CSVs beside it are a
    partial or mixed-vintage set and must not be read as one dataset. Anything
    this run did not produce is removed for the same reason.
#>
[CmdletBinding()]
param(
    [string] $BoardName   = 'default_shortboard',
    [string] $BiblioPath  = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'ShaperWaveDynamics documents\biblio'),
    [string] $InstallPath = 'C:\Program Files\ShaperWaveDynamics\ShaperWaveDynamics',
    [string] $OutDir      = '',
    [string] $TrustManifest = ''
)

$ErrorActionPreference = 'Stop'
# Parity with census_board.ps1 and swd_extract.ps1. Without it an unset variable
# reads as $null and a typo'd property silently yields nothing, which in a script
# whose entire job is "do not emit a fake number" is the wrong default.
Set-StrictMode -Version Latest

# ConvertTo-Csv formats a double with the CURRENT culture, so on an fr-FR or
# de-DE host 1.5 renders as "1,5" - which is also the CSV delimiter, so the
# writer quotes it and every numeric column arrives in pandas as text. Pin the
# whole run to InvariantCulture rather than formatting at each call site.
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture

if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Windows PowerShell 5.1 required (BinaryFormatter was removed in .NET 9).' }
if (-not [Environment]::Is64BitProcess)      { throw '64-bit process required (x64-only images).' }

function Format-PathForDisplay {
    <# Collapse the personal prefixes before a path reaches the console. The
       OneDrive roots are tested FIRST and separately: they live under
       $env:USERPROFILE, so the plain '~' substitution leaves the tenant folder
       name ("OneDrive - <Organisation>") intact, and a pasted log is the easiest
       accidental route for that to leave the machine. #>
    param([string] $Path)
    if (-not $Path) { return '' }
    # Separators normalised before the prefix test: a caller can pass
    # 'C:/Users/...' and an ordinal compare against 'C:\Users\...' then matches
    # nothing, printing the very path this function exists to hide.
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

$script:WarnedOnce = New-Object 'System.Collections.Generic.HashSet[string]'
function Write-WarningOnce {
    <# Same message once per run: a per-element warning repeats thousands of
       times and buries everything else. Ported from swd_extract.ps1:463. #>
    param([Parameter(Mandatory)][string] $Message)
    if ($script:WarnedOnce.Add($Message)) { Write-Warning $Message }
}

# --- Read-only roots ---------------------------------------------------------
# A missing library or install directory otherwise surfaces hundreds of lines
# later as a Get-ChildItem or LoadFrom failure, and the raw error text carries
# the full absolute path (username + OneDrive tenant) into the console.
foreach ($p in @($BiblioPath, $InstallPath)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Path not found: $(Format-PathForDisplay $p)" }
}
# Resolved through the SAME provider that just validated them. Load-bearing, not
# tidying: Test-Path -LiteralPath resolves PowerShell provider forms - '~', and a
# relative path against $PWD - that [IO.Path]::GetFullPath does not
# (GetFullPath('~\x') returns '<cwd>\~\x'). Recomputing the roots with bare
# GetFullPath let a '~'-spelled -BiblioPath validate as real and then produce a
# protected root pointing at a directory that does not exist, so both the lexical
# and the canonical test missed and the guard silently never fired. Measured in
# swd_extract.ps1; ported here before it could be rediscovered.
try {
    $BiblioPath  = (Convert-Path -LiteralPath $BiblioPath).TrimEnd('\')
    $InstallPath = (Convert-Path -LiteralPath $InstallPath).TrimEnd('\')
} catch {
    throw "Could not resolve a read-only root to a canonical path, so containment cannot be enforced: $($_.Exception.Message)"
}

# --- BoardName is a folder NAME, never a path --------------------------------
# It is interpolated into the default -OutDir ("data\$BoardName") and joined onto
# the library root to find the reports, so a separator or a '..' in it steers
# both. Measured before this guard: -BoardName '..\..\..\' resolved the default
# -OutDir to C:\Users\<user>\ - which the write section would then have created,
# written into, and swept for stale outputs, deleting five CSV names from a home
# directory. Rejected outright rather than sanitised: a real board name is one
# library folder name, so there is nothing legitimate to salvage from a path.
if ([string]::IsNullOrWhiteSpace($BoardName)) { throw '-BoardName must not be empty.' }
$badChars = @([IO.Path]::GetInvalidFileNameChars()) + @([char]0x2F, [char]0x5C)
foreach ($c in $badChars) {
    if ($BoardName.IndexOf($c) -ge 0) {
        throw "-BoardName must be a single library folder name, not a path. It contains a character that cannot appear in one."
    }
}
if ($BoardName -eq '.' -or $BoardName -eq '..' -or $BoardName.Trim() -ne $BoardName) {
    throw "-BoardName must be a single library folder name, not a path or a relative reference: '$BoardName'"
}

# --- Output directory --------------------------------------------------------
# $PSScriptRoot is empty when the script is dot-sourced or run through
# Invoke-Expression, and Split-Path -Parent '' THROWS. Same fallback as
# swd_extract.ps1:164.
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $root = $PSScriptRoot
    if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
    if (-not $root) { throw 'Cannot resolve the script directory; pass -OutDir explicitly.' }
    $OutDir = Join-Path (Split-Path -Parent $root) "data\$BoardName"
}
# [IO.Path]::GetFullPath resolves a relative path against
# [Environment]::CurrentDirectory, which PowerShell never syncs with $PWD: after
# Set-Location $env:TEMP, GetFullPath('out') still returned a path under the
# directory the process started in. Anchor a relative -OutDir to $PWD instead.
if (-not [IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path $PWD.ProviderPath $OutDir }
# \\?\ and \\.\ bypass path normalisation entirely, and UNC has no local
# canonical form this guard can reason about, so all three are refused rather
# than half-checked. Measured in swd_extract.ps1: each was accepted by the
# lexical-only guard it replaced.
if ($OutDir.StartsWith('\\')) {
    throw '-OutDir must be a local drive path. Extended-length, device and UNC paths are refused.'
}
$OutDir = [IO.Path]::GetFullPath($OutDir).TrimEnd('\')

# --- Containment -------------------------------------------------------------
# The install directory is licence-bound (EUR 210, machine-bound to one registry
# value) and the library is the user's only copy of the board data; both are
# read-only, always. Ported from swd_extract.ps1:207-296, where two INDEPENDENT
# defects were found and fixed:
#
#   WHICH roots are protected. Testing only the two supplied paths is not enough,
#   because both defaults sit one level INSIDE the tree that must not be written
#   to. $InstallPath defaults to the inner ShaperWaveDynamics\ShaperWaveDynamics,
#   so the product root above it was open; $BiblioPath defaults to biblio\ inside
#   "ShaperWaveDynamics documents\", which also holds swdshare\, fonds\,
#   home boards\ and video\. Each supplied path AND its parent is protected.
#
#   HOW paths are compared. A lexical prefix test is defeated by an 8.3 short
#   name, a junction, a subst drive or an extended-length prefix - GetFullPath
#   expands none of them, and all four were measured as ACCEPTED. Comparison is
#   canonical.
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
# Created only AFTER the guard has cleared it. Creating it first would put a
# directory inside a protected tree before anything had checked it.
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

# --- Trust manifest ----------------------------------------------------------
# READ-ONLY here (only swd_extract.ps1 -TrustCurrentLibrary writes it), but it is
# still refused inside a protected tree: a manifest read from inside the library
# would let a library that had been tampered with vouch for itself, and pointing
# -TrustManifest at a path under the install directory is not a thing any honest
# run needs to do.
if ([string]::IsNullOrWhiteSpace($TrustManifest)) {
    $TrustManifest = Join-Path $env:LOCALAPPDATA 'swd-extract\trusted_files.json'
}
if (-not [IO.Path]::IsPathRooted($TrustManifest)) { $TrustManifest = Join-Path $PWD.ProviderPath $TrustManifest }
if ($TrustManifest.StartsWith('\\')) {
    throw '-TrustManifest must be a local drive path. Extended-length, device and UNC paths are refused.'
}
$TrustManifest = [IO.Path]::GetFullPath($TrustManifest)
$tmCanon = Resolve-CanonicalTarget -Path $TrustManifest
if (-not $tmCanon) { $tmCanon = $TrustManifest }
foreach ($candidate in @($TrustManifest, $tmCanon)) {
    $hit = Test-PathUnderRoot -Path $candidate -Root $allRoots
    if ($hit) {
        throw "-TrustManifest must not resolve inside a read-only SWD directory. '$(Format-PathForDisplay $TrustManifest)' resolves to '$(Format-PathForDisplay $candidate)', which is at or under '$(Format-PathForDisplay $hit)'."
    }
}

# extract_manifest.json is the completion sentinel (see the WRITE section). Any
# stale one is deleted up front so an aborted run cannot leave the previous run's
# manifest vouching for a half-written directory.
$manifestPath = Join-Path $OutDir 'extract_manifest.json'
if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force }

# --- Provenance gate ---------------------------------------------------------
# -TrustManifest was resolved and containment-tested above, beside -OutDir.
$trusted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
if (-not (Test-Path -LiteralPath $TrustManifest)) { throw "Trust manifest not found: $(Format-PathForDisplay $TrustManifest)" }
foreach ($e in (Get-Content -Raw -LiteralPath $TrustManifest | ConvertFrom-Json).files) { [void]$trusted.Add([string]$e.sha256) }

function Test-Trusted {
    param([string] $Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $h = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path))).Replace('-','') }
    finally { $sha.Dispose() }
    return $trusted.Contains($h)
}

# --- Assembly ----------------------------------------------------------------
# Handler returns an already-loaded assembly and never calls LoadFrom: an
# unguarded LoadFrom here recurses into an uncatchable StackOverflowException.
$onResolve = [System.ResolveEventHandler] {
    param($src, $e)
    $n = ($e.Name -split ',')[0]
    foreach ($a in [AppDomain]::CurrentDomain.GetAssemblies()) { if ($a.GetName().Name -eq $n) { return $a } }
    return $null
}
[AppDomain]::CurrentDomain.add_AssemblyResolve($onResolve)
[void][Reflection.Assembly]::LoadFrom((Join-Path $InstallPath 'SurfHydrodynamics.exe'))
[void][Reflection.Assembly]::LoadFrom((Join-Path $InstallPath 'SlimDX.dll'))
$asm = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'SurfHydrodynamics' } | Select-Object -First 1
if (-not $asm) { throw 'Failed to load SurfHydrodynamics assembly.' }

# GetType(name), never GetTypes(): the latter throws ReflectionTypeLoadException
# on this build. A missing type must fail here, not as a null-method call several
# hundred reports into the run - by which point nothing has been written.
$T_board   = $asm.GetType('SurfHydrodynamics.Class_surfboard')
$T_report  = $asm.GetType('SurfHydrodynamics.Class_rapport_hydrodynamique')
$T_element = $asm.GetType('SurfHydrodynamics.element_hydrodynamique')
foreach ($t in @($T_board, $T_report, $T_element)) { if (-not $t) { throw 'Expected SWD type missing.' } }

$BIND = [Reflection.BindingFlags]'Public,NonPublic,Instance'
$fmt  = New-Object System.Runtime.Serialization.Formatters.Binary.BinaryFormatter

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

# Accented names built by code point so this file's encoding cannot corrupt them.
$E = [char]0xE9

# --- Field discovery ---------------------------------------------------------
# Auto-discover every serialised numeric field rather than hand-listing 22. New
# SWD builds gain columns for free; nothing silently goes missing.
$NUMERIC = @('Single','Double','Int32','Int16','Int64','Boolean','Byte')
$elemFields = @($T_element.GetFields($BIND) |
                Where-Object { -not $_.IsNotSerialized -and $NUMERIC -contains $_.FieldType.Name } |
                Sort-Object Name)
Write-Host "numeric serialised fields on element_hydrodynamique: $($elemFields.Count)"

# ASCII-fold accented names for CSV headers; DATA-DICTIONARY.md maps them back.
function ConvertTo-ColumnName {
    param([string] $Name)
    $s = $Name -replace [char]0xE9, 'e' -replace [char]0xE8, 'e' -replace [char]0xEA, 'e' -replace [char]0xE0, 'a' -replace [char]0xE7, 'c' -replace [char]0xF4, 'o' -replace [char]0xEE, 'i'
    return ($s -replace '^_', '')
}

# --- Value reading -----------------------------------------------------------
# SWD leaves some fields at Single.MaxValue (3.4028235e38) on non-contact
# elements - a sentinel, not a measurement. Mapped to NaN and counted. A plain
# cast would carry it into the CSV, where one such value destroys any
# standardisation of that column.
$script:SentinelHits = @{}
$SENTINEL_LIMIT = 1e30

function Get-Num {
    param($Object, [Reflection.FieldInfo] $Fi)
    # A field this build does not have resolves to $null; the caller warned once
    # already, and NaN is the honest column value. Guarding here rather than at
    # each of the nine call sites - they all route through this one function.
    if ($null -eq $Fi) { return [double]::NaN }
    $v = $Fi.GetValue($Object)
    # [double]$null is 0, so a naive cast turns missing data into a measured zero.
    if ($null -eq $v) { return [double]::NaN }
    if ($v -is [bool]) { return [double]([int]$v) }
    $d = [double]$v
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d) -or [Math]::Abs($d) -gt $SENTINEL_LIMIT) {
        $k = $Fi.Name
        if (-not $script:SentinelHits.ContainsKey($k)) { $script:SentinelHits[$k] = 0 }
        $script:SentinelHits[$k]++
        return [double]::NaN
    }
    return $d
}

function Get-ListItem {
    param($List, [int] $Index)
    if ($null -eq $List) { return [double]::NaN }
    $n = if ($List -is [Array]) { $List.Length } else { $List.Count }
    if ($Index -ge $n) { return [double]::NaN }
    $v = $List[$Index]
    if ($null -eq $v) { return [double]::NaN }
    return [double]$v
}

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

function Get-Count { param($C) if ($null -eq $C) { return 0 }; if ($C -is [Array]) { return $C.Length }; return $C.Count }

function Format-MessageForDisplay {
    <# A .NET IOException embeds the full absolute path, so an error message is a
       second route for the username and the OneDrive tenant folder to reach a
       pasted console log. Same redaction as Format-PathForDisplay, applied to
       free text. Longest roots first: OneDrive lives under USERPROFILE. #>
    param([string] $Message)
    foreach ($root in @($env:OneDriveCommercial, $env:OneDriveConsumer, $env:OneDrive)) {
        if ($root) { $Message = $Message.Replace($root, '~\OneDrive') }
    }
    if ($env:USERPROFILE) { $Message = $Message.Replace($env:USERPROFILE, '~') }
    return $Message
}

$script:UntrustedSeen = New-Object 'System.Collections.Generic.List[string]'
$script:ParseFailures = New-Object 'System.Collections.Generic.List[string]'
function Read-Swd {
    <# Deserialise one .fyn* file, or $null. The trust check is FIRST:
       BinaryFormatter must never see a stream whose provenance is unapproved.

       EVERYTHING is inside the try, the trust check included, and that is not
       tidiness. Test-Trusted hashes the file, so ReadAllBytes there is the run's
       FIRST I/O on it - putting the try around only the Deserialize (which is
       where the original defect was reported) leaves the real abort point
       uncovered. Measured: with one report exclusively locked, the run died in
       Test-Trusted having read 0 of 11 and written nothing, exit code 1.

       Skips are counted and reported at the end, because a run that read 1 of
       154 reports otherwise prints the same shape of success as one that read
       all 154. Only the leaf name is logged; the directory is the library path. #>
    param([string] $Path)
    $leaf = Split-Path -Leaf $Path
    $fs = $null
    try {
        if (-not (Test-Trusted -Path $Path)) {
            Write-Warning "UNTRUSTED, skipped: $leaf"
            $script:UntrustedSeen.Add($leaf)
            return $null
        }
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        return $fmt.Deserialize($fs)
    } catch {
        Write-Warning "read failed, skipped: $leaf :: $(Format-MessageForDisplay $_.Exception.Message)"
        $script:ParseFailures.Add($leaf)
        return $null
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

function Resolve-Field {
    <# FieldInfo by name, with swd_extract.ps1:797's accent-variant fallback.
       Four of the names here are built from e-acute code points and SWD's builds
       have differed on them, so an exact miss is retried against every field
       whose name matches once non-ASCII characters are collapsed. Returns $null
       after warning once; every caller treats $null as "column is NaN/absent"
       rather than dereferencing it. #>
    param([Parameter(Mandatory)][Type] $Type, [Parameter(Mandatory)][string] $Name)
    $fi = $Type.GetField($Name, $BIND)
    if ($fi) { return $fi }
    $alt = $Type.GetFields($BIND) | Where-Object {
        ($_.Name -replace '[^\x20-\x7E]', '?') -eq ($Name -replace '[^\x20-\x7E]', '?')
    } | Select-Object -First 1
    if ($alt) {
        Write-WarningOnce "field name differs by accent on $($Type.Name); using '$($alt.Name)' for '$Name'"
        return $alt
    }
    Write-WarningOnce "field not found on $($Type.Name), dependent columns will be NaN or absent: $Name"
    return $null
}

# --- Board -------------------------------------------------------------------
$boardsRoot = Join-Path $BiblioPath 'Boards'
if (-not (Test-Path -LiteralPath $boardsRoot)) { throw "No Boards directory in the library: $(Format-PathForDisplay $boardsRoot)" }
# Sorted before the take, so a duplicate BaseName does not make the chosen file
# depend on Get-ChildItem's enumeration order, and warned about rather than
# resolved silently - the library holds copies at several depths.
$bfAll = @(Get-ChildItem -LiteralPath $boardsRoot -Recurse -Filter '*.fynbs' -File -ErrorAction SilentlyContinue |
           Where-Object { $_.BaseName -eq $BoardName } | Sort-Object FullName)
if ($bfAll.Count -gt 1) {
    Write-Warning "$($bfAll.Count) .fynbs files are named '$BoardName'; using the first by path and IGNORING the rest:"
    foreach ($d in $bfAll) { Write-Warning "    $(Format-PathForDisplay $d.FullName)" }
}
$bf = $bfAll | Select-Object -First 1
$boardRow = $null
if ($bf) {
    $bd = Read-Swd -Path $bf.FullName
    if ($bd) {
        $boardRow = [ordered]@{ board = $BoardName }
        foreach ($fi in @($T_board.GetFields($BIND) | Where-Object { -not $_.IsNotSerialized -and $NUMERIC -contains $_.FieldType.Name } | Sort-Object Name)) {
            $boardRow[(ConvertTo-ColumnName $fi.Name)] = Get-Num $bd $fi
        }
    }
}

# --- Reports -----------------------------------------------------------------
$scanDir = Join-Path (Join-Path $BiblioPath 'rapports_hydro') $BoardName
# Checked, so the failure is a named board rather than Get-ChildItem's raw
# DirectoryNotFoundException - which prints the full absolute path.
if (-not (Test-Path -LiteralPath $scanDir)) { throw "No reports directory for '$BoardName': $(Format-PathForDisplay $scanDir)" }
$files = @(Get-ChildItem -LiteralPath $scanDir -Filter '*.fynrhydro' -File | Sort-Object Name)
Write-Host "reports: $($files.Count)"

$elemRows = New-Object 'System.Collections.Generic.List[object]'
$subRows  = New-Object 'System.Collections.Generic.List[object]'
$geomRows = New-Object 'System.Collections.Generic.List[object]'
$opRows   = New-Object 'System.Collections.Generic.List[object]'

$F_FRONT = "_section_frontale_flux_d${E}vi${E}_m2_planing"
$F_FLUX  = "_masse_flux_d${E}vi${E}_kg_sec_planing"
$F_WET   = "_longueur_mouill${E}e_element_mm"
$F_DRAG  = "_train${E}e_globale_horizontale_n"
$F_LIFT  = '_portance_globale_verticale_n'
$F_WIDTH = '_largeur_B_element_mm'

# Every FieldInfo is resolved ONCE, here, through Resolve-Field - which warns and
# returns $null instead of handing back something a later .GetValue() would
# dereference. Eight of these used to be dereferenced unchecked inside the loop:
# because every write happens at the end of the script, one missing field on a
# different SWD build produced zero CSVs and an exception, not a degraded run.
$fiFront = Resolve-Field -Type $T_element -Name $F_FRONT
$fiFlux  = Resolve-Field -Type $T_element -Name $F_FLUX
$fiWet   = Resolve-Field -Type $T_element -Name $F_WET
$fiWidth = Resolve-Field -Type $T_element -Name $F_WIDTH
$fiDrag  = Resolve-Field -Type $T_element -Name $F_DRAG
$fiLift  = Resolve-Field -Type $T_element -Name $F_LIFT
$fiInt   = Resolve-Field -Type $T_element -Name 'elements_internes'
$fiContact = Resolve-Field -Type $T_element -Name 'tableau_points_graphique_polygone_surface_contact_eau_echelle_1_en_metres'

$fiDrift = Resolve-Field -Type $T_report -Name 'angle_drift_deg'
$fiCases = Resolve-Field -Type $T_report -Name 'list_elements_hydro'
if (-not $fiCases) { throw 'Class_rapport_hydrodynamique has no list_elements_hydro; there is nothing to extract.' }
$fiLInc  = Resolve-Field -Type $T_report -Name 'list_incidences_deg'
$fiLPosX = Resolve-Field -Type $T_report -Name 'list_posx'
$fiLPosY = Resolve-Field -Type $T_report -Name 'list_posy'
$fiLA1   = Resolve-Field -Type $T_report -Name 'list_index_point_ligne_attaque_1_index_axe_roulis'
$fiLA2   = Resolve-Field -Type $T_report -Name 'list_index_point_ligne_attaque_2_index_axe_roulis'

# Column names for the six fields the derived quantities need. The per-element
# loop below already reads every numeric field once into $row; re-reading these
# six through Get-Num afterwards double-counted them in $script:SentinelHits, so
# the derived block now reads back out of $row instead.
$C_FRONT = if ($fiFront) { ConvertTo-ColumnName $fiFront.Name } else { $null }
$C_FLUX  = if ($fiFlux)  { ConvertTo-ColumnName $fiFlux.Name }  else { $null }
$C_WET   = if ($fiWet)   { ConvertTo-ColumnName $fiWet.Name }   else { $null }
$C_WIDTH = if ($fiWidth) { ConvertTo-ColumnName $fiWidth.Name } else { $null }
$C_DRAG  = if ($fiDrag)  { ConvertTo-ColumnName $fiDrag.Name }  else { $null }
$C_LIFT  = if ($fiLift)  { ConvertTo-ColumnName $fiLift.Name }  else { $null }

function Get-RowVal {
    <# A value already read into the row, or NaN if that column does not exist on
       this build. Reading from the row rather than calling Get-Num a second time
       keeps the sentinel tally honest - it is a count of VALUES SEEN, and six
       fields were being counted twice per element. #>
    param($Row, [string] $Key)
    if ($Key -and $Row.Contains($Key)) { return [double]$Row[$Key] }
    return [double]::NaN
}

# point_graphique's two coordinate FieldInfos, resolved on first sight of the type
# rather than per point: the contact polygons hold ~59,000 points on this board
# alone, and Type.GetField was being called twice for each of them.
$ptType = $null; $fiPx = $null; $fiPy = $null

$reportsRead = 0
foreach ($rf in $files) {
    $rep = Read-Swd -Path $rf.FullName
    if (-not $rep) { continue }
    $reportsRead++
    # Get-Num, not a bare [double] cast: drift_deg is a grouping key, and
    # [double]$null is 0.0 - a missing drift angle would silently join every
    # report onto the 0-degree case.
    $drift = Get-Num $rep $fiDrift
    $cases = $fiCases.GetValue($rep)
    if (-not $cases) { continue }
    $lInc  = if ($fiLInc)  { $fiLInc.GetValue($rep) }  else { $null }
    $lPosX = if ($fiLPosX) { $fiLPosX.GetValue($rep) } else { $null }
    $lPosY = if ($fiLPosY) { $fiLPosY.GetValue($rep) } else { $null }
    $lA1   = if ($fiLA1)   { $fiLA1.GetValue($rep) }   else { $null }
    $lA2   = if ($fiLA2)   { $fiLA2.GetValue($rep) }   else { $null }

    for ($ci = 0; $ci -lt $cases.Count; $ci++) {
        $case = $cases[$ci]
        if (-not $case) { continue }
        $cInc  = if ($null -ne $lInc  -and $ci -lt (Get-Count $lInc))  { $lInc[$ci] }  else { $null }
        $cPosX = if ($null -ne $lPosX -and $ci -lt (Get-Count $lPosX)) { $lPosX[$ci] } else { $null }
        $cPosY = if ($null -ne $lPosY -and $ci -lt (Get-Count $lPosY)) { $lPosY[$ci] } else { $null }
        $cA1   = if ($null -ne $lA1   -and $ci -lt (Get-Count $lA1))   { $lA1[$ci] }   else { $null }
        $cA2   = if ($null -ne $lA2   -and $ci -lt (Get-Count $lA2))   { $lA2[$ci] }   else { $null }

        $sumDrag = 0.0; $sumLift = 0.0; $nEl = 0
        # incidence_deg_mean used to average over $cInc's FULL length - every
        # element of the board, including the ones not in contact for this roll
        # case - while n_elements counted only those in contact. Accumulated here
        # instead, over exactly the elements this operating point is built from.
        $incAcc = 0.0; $incCnt = 0
        for ($ei = 0; $ei -lt $case.Count; $ei++) {
            $el = $case[$ei]
            if (-not $el) { continue }
            $nEl++

            $row = [ordered]@{
                board = $BoardName; drift_deg = $drift; roll_case = $ci; element_index = $ei
            }
            foreach ($fi in $elemFields) { $row[(ConvertTo-ColumnName $fi.Name)] = Get-Num $el $fi }

            # Report-level parallel lists, indexed by element.
            $storedInc = Get-ListItem $cInc $ei
            $row['incidence_deg_stored'] = $storedInc
            $row['pos_x']                = Get-ListItem $cPosX $ei
            $row['pos_y']                = Get-ListItem $cPosY $ei
            $row['attack_index_1']       = Get-ListItem $cA1   $ei
            $row['attack_index_2']       = Get-ListItem $cA2   $ei

            # Derived, flagged as such in DATA-DICTIONARY.md.
            $S = Get-RowVal $row $C_FRONT
            $Q = Get-RowVal $row $C_FLUX
            $L = (Get-RowVal $row $C_WET)   / 1000.0
            $W = (Get-RowVal $row $C_WIDTH) / 1000.0
            # S -ne 0, not S -gt 0. SWD signs S and Q together by flow direction:
            # on 40 of this board's sub-element rows both are negative, so Q/S is
            # a perfectly clean +20460.000 that the old -gt 0 gate threw away.
            $rhoV = if ($S -ne 0 -and -not [double]::IsNaN($S)) { $Q / $S } else { [double]::NaN }
            $row['rho_v_kg_m2_s'] = $rhoV
            $rho = Get-InferredRho -RhoV $rhoV
            $row['rho_kgm3'] = $rho
            # rho is a SNAPPED table value, so this is rho*V divided by it: it
            # carries the measurement residual around V_REF, and it is NOT an
            # independent measurement of speed. NaN when the snap was refused.
            $row['scan_speed_ms'] = if (-not [double]::IsNaN($rhoV) -and $rho -gt 0) { $rhoV / $rho } else { [double]::NaN }
            # Abs(): Asin is defined only on [-1, 1] and returns NaN outside it,
            # so the old one-sided $sinA -le 1.0 reached the same NaN by relying
            # on that behaviour instead of stating the domain. Same output either
            # way - sinA < -1 occurs nowhere in this corpus - so this is a
            # defensive rewrite, not a behaviour change.
            #
            # The negative angles that DO occur (40 sub-element rows, to -10.75
            # deg) are kept as-is, and the sign is NOT claimed to be physical:
            # S and Q are negative together so Q/S is a clean +20460, but the
            # parent strip's stored incidence on those same rows is POSITIVE
            # (+0.61 to +10.46 deg). Whether the sub-panel genuinely faces the
            # other way - plausible near a rail, cf. delta_plan_horizontal_deg -
            # or SWD's differencing simply signs the pair, is not decidable from
            # the data here. Taking Abs() would pick one reading with no evidence,
            # so the signed value is emitted and incidence_deg_stored_parent is
            # emitted beside it so the disagreement is visible.
            $sinA = if ($L -gt 0 -and $W -gt 0) { $S / ($L * $W) } else { [double]::NaN }
            $derivedInc = if (-not [double]::IsNaN($sinA) -and [Math]::Abs($sinA) -le 1.0) { [Math]::Asin($sinA) * 180.0 / [Math]::PI } else { [double]::NaN }
            $row['incidence_deg_derived'] = $derivedInc
            # The two incidence columns are NOT interchangeable and the residual
            # is how a consumer finds that out from the data alone: of the 454
            # rows where both exist, 30.0% differ by more than 1 degree, 4.4% by
            # more than 5, and the worst is +60.17. asin(S/(L*w)) inverts Eq 20
            # under assumptions SWD's own planing solver does not hold to; on 13
            # further rows it produces nothing at all (9 give sinA > 1, 4 have a
            # sentinel width), which is why the residual is NaN there rather than
            # zero.
            $row['incidence_deg_residual'] = $derivedInc - $storedInc
            $subs = if ($fiInt) { $fiInt.GetValue($el) } else { $null }
            $nSub = Get-Count $subs
            $row['n_sub_elements'] = $nSub
            $elemRows.Add([pscustomobject]$row)

            $sumDrag += (Get-RowVal $row $C_DRAG); $sumLift += (Get-RowVal $row $C_LIFT)
            if (-not [double]::IsNaN($storedInc)) { $incAcc += $storedInc; $incCnt++ }

            # --- sub-elements ---
            for ($k = 0; $k -lt $nSub; $k++) {
                $sub = $subs[$k]
                if ($null -eq $sub) { continue }
                $srow = [ordered]@{
                    board = $BoardName; drift_deg = $drift; roll_case = $ci
                    element_index = $ei; sub_index = $k
                }
                foreach ($fi in $elemFields) { $srow[(ConvertTo-ColumnName $fi.Name)] = Get-Num $sub $fi }
                $sS = Get-RowVal $srow $C_FRONT
                $sQ = Get-RowVal $srow $C_FLUX
                $sL = (Get-RowVal $srow $C_WET)   / 1000.0
                $sW = (Get-RowVal $srow $C_WIDTH) / 1000.0
                $sRhoV = if ($sS -ne 0 -and -not [double]::IsNaN($sS)) { $sQ / $sS } else { [double]::NaN }
                $srow['rho_v_kg_m2_s'] = $sRhoV
                $sRho = Get-InferredRho -RhoV $sRhoV
                $srow['rho_kgm3'] = $sRho
                $srow['scan_speed_ms'] = if (-not [double]::IsNaN($sRhoV) -and $sRho -gt 0) { $sRhoV / $sRho } else { [double]::NaN }
                $ss = if ($sL -gt 0 -and $sW -gt 0) { $sS / ($sL * $sW) } else { [double]::NaN }
                $srow['incidence_deg_derived'] = if (-not [double]::IsNaN($ss) -and [Math]::Abs($ss) -le 1.0) { [Math]::Asin($ss) * 180.0 / [Math]::PI } else { [double]::NaN }
                # There is no stored incidence per SUB-element - the report's
                # list_incidences_deg is indexed by element - so this file would
                # otherwise carry a lone incidence_deg_derived with nothing to
                # judge it against, reading like a measurement. This is the PARENT
                # STRIP's stored value, repeated across its 10 sub-elements. It is
                # NOT the same quantity and must not be differenced blindly; it is
                # here so a consumer can see the two disagree (most sharply on the
                # 40 rows where the derived value is negative and the parent's is
                # not) instead of taking the derived column at face value.
                $srow['incidence_deg_stored_parent'] = $storedInc
                $subRows.Add([pscustomobject]$srow)
            }

            # --- wetted contact polygon, in metres ---
            if ($fiContact) {
                $poly = $fiContact.GetValue($el)
                $np = Get-Count $poly
                for ($k = 0; $k -lt $np; $k++) {
                    $pt = $poly[$k]
                    if ($null -eq $pt) { continue }
                    # point_graphique is 2-D: _coordonne_x / _coordonne_y (Double).
                    # SlimDX Vector2/Vector3 also appear in sibling arrays, so both
                    # shapes are handled rather than assuming one.
                    $px = $null; $py = $null
                    $ptt = $pt.GetType()
                    if ($ptt.Name -eq 'point_graphique') {
                        if ($ptt -ne $ptType) {
                            $ptType = $ptt
                            $fiPx = Resolve-Field -Type $ptt -Name '_coordonne_x'
                            $fiPy = Resolve-Field -Type $ptt -Name '_coordonne_y'
                        }
                        if ($fiPx) { $px = $fiPx.GetValue($pt) }
                        if ($fiPy) { $py = $fiPy.GetValue($pt) }
                    } elseif ($ptt.Name -eq 'Vector2' -or $ptt.Name -eq 'Vector3') {
                        $px = $pt.X; $py = $pt.Y
                    }
                    # BOTH, not just x. [double]$null is 0.0, so a point with a
                    # readable x and a null y used to be written as a vertex
                    # sitting exactly on the axis.
                    if ($null -eq $px -or $null -eq $py) { continue }
                    $geomRows.Add([pscustomobject][ordered]@{
                        board = $BoardName; drift_deg = $drift; roll_case = $ci
                        element_index = $ei; point_index = $k
                        x_m = [double]$px; y_m = [double]$py
                    })
                }
            }
        }

        # A roll case with no elements in contact is not an operating point. It
        # used to emit one anyway, with drag_total_n and lift_total_n at exactly
        # 0.0 - which reads as "measured no force" rather than "measured nothing".
        # Same guard as swd_extract.ps1:1008.
        if ($nEl -eq 0) { continue }

        $opRows.Add([pscustomobject][ordered]@{
            board = $BoardName; drift_deg = $drift; roll_case = $ci
            n_elements = $nEl
            # NaN propagates through the sums on purpose: a missing element force
            # makes the total unknown, and NaN is the arithmetic that says so.
            drag_total_n = $sumDrag
            lift_total_n = $sumLift
            # The mean, by contrast, SKIPS missing values - so its denominator is
            # published beside it rather than left to be assumed equal to
            # n_elements. On this board the two are equal on all 51 cases (every
            # element has a stored incidence), so this column is the guard that
            # makes a future divergence visible, not a correction to today's data.
            incidence_deg_mean = $(if ($incCnt -gt 0) { $incAcc / $incCnt } else { [double]::NaN })
            n_incidence = $incCnt
            # Element 0's value, and that is safe rather than arbitrary: measured
            # over all 51 roll cases of this board, pos_y is constant within a
            # case to better than 1e-12.
            pos_y = Get-ListItem $cPosY 0
        })
    }
}

# --- Write -------------------------------------------------------------------
# Everything lands here, together, and extract_manifest.json lands LAST. Any throw
# before this point leaves the previous run's files untouched with no manifest, so
# a partial set is detectable from disk alone. Ported from swd_extract.ps1:1088.
#
# UTF-8 without BOM: a BOM breaks the Python readers downstream.
$script:WrittenTables = [ordered]@{}
function Write-CsvNoBom {
    param($Rows, [string] $Path)
    $name = Split-Path -Leaf $Path
    # Leaf, not the full path: the sibling warning printed an absolute path while
    # the success line printed a leaf, so a failure was the noisier of the two.
    if ($Rows.Count -eq 0) { Write-Warning "no rows for $name - not written"; return }
    $csv = ($Rows | ConvertTo-Csv -NoTypeInformation) -join "`r`n"
    [IO.File]::WriteAllText($Path, $csv + "`r`n", (New-Object Text.UTF8Encoding($false)))
    $script:WrittenTables[$name] = [ordered]@{
        rows = $Rows.Count
        cols = @($Rows[0].PSObject.Properties).Count
    }
    Write-Host ("  {0,-22} {1,7} rows" -f $name, $Rows.Count)
}

Write-Host ""
Write-Host "writing to $(Format-PathForDisplay $OutDir)"
Write-CsvNoBom -Rows $elemRows -Path (Join-Path $OutDir 'elements.csv')
Write-CsvNoBom -Rows $subRows  -Path (Join-Path $OutDir 'sub_elements.csv')
Write-CsvNoBom -Rows $opRows   -Path (Join-Path $OutDir 'operating_points.csv')
Write-CsvNoBom -Rows $geomRows -Path (Join-Path $OutDir 'geometry_contact.csv')
if ($boardRow) { Write-CsvNoBom -Rows @([pscustomobject]$boardRow) -Path (Join-Path $OutDir 'board.csv') }
else           { Write-Warning "board.csv - no .fynbs named '$BoardName' was read, so there is no board row" }

# Anything this run did not produce is REMOVED, so -OutDir holds exactly one
# run's output or none. Without this a run that skipped board.csv (missing or
# untrusted .fynbs) or emptied a table left the previous run's file in place and
# the manifest below then vouched for a mixed-vintage set as one dataset.
#
# The list is exactly this script's own five outputs. field_census.csv,
# DATA-DICTIONARY.md, PROGRESS.md and trajectory.csv are produced by other tools
# and are never touched.
foreach ($known in @('elements.csv', 'sub_elements.csv', 'operating_points.csv', 'geometry_contact.csv', 'board.csv')) {
    if ($script:WrittenTables.Contains($known)) { continue }
    $stale = Join-Path $OutDir $known
    if (Test-Path -LiteralPath $stale) {
        Write-Warning "removing $known - this run did not produce it, and leaving it would let the completion sentinel vouch for a table from a different run."
        Remove-Item -LiteralPath $stale -Force
    }
}

Write-Host ""
if ($script:SentinelHits.Count -eq 0) {
    Write-Host 'sentinel values (Single.MaxValue / Inf / NaN): none'
} else {
    Write-Host 'sentinel values mapped to NaN (SWD leaves these set on non-contact elements):'
    foreach ($k in ($script:SentinelHits.Keys | Sort-Object)) { Write-Host ("    {0,-40} {1,5}" -f $k, $script:SentinelHits[$k]) }
}

# A short read is a silently SMALLER dataset - the one failure this whole script
# is built to make visible - so the counts are printed whether or not they are 0.
#
# reportsRead is counted in the loop, NOT derived as found - untrusted - failed:
# those two lists are RUN-WIDE and include the .fynbs board file, so the
# subtraction printed "11 found, -1 read, 12 untrusted" on a fully-untrusted run.
Write-Host ""
Write-Host ("reports: {0} found, {1} read" -f $files.Count, $reportsRead)
Write-Host ("files not deserialised (board + reports): {0} untrusted, {1} failed" -f `
            $script:UntrustedSeen.Count, $script:ParseFailures.Count)
if ($script:UntrustedSeen.Count -gt 0) {
    Write-Warning "$($script:UntrustedSeen.Count) file(s) were NOT deserialised - absent from the trust manifest. The tables above are INCOMPLETE by exactly those files."
    Write-Warning 'Review each, then re-run swd_extract.ps1 -TrustCurrentLibrary to approve the library as it now stands.'
}
if ($script:ParseFailures.Count -gt 0) {
    Write-Warning "$($script:ParseFailures.Count) file(s) failed to deserialise; the tables above are INCOMPLETE by exactly those files."
}
if ($script:RhoSnapMisses -gt 0) {
    # Never silent. This firing means the premise behind $V_REF has failed for
    # some rows - most likely a scan that did NOT run at 20.000 m/s - and those
    # rows carry rho_kgm3 = NaN and scan_speed_ms = NaN rather than a guess.
    Write-Warning ("rho did not snap to a table value on {0} row(s); worst relative residual {1:e3}. rho_kgm3 and scan_speed_ms are NaN there. Re-derive V_REF before trusting any density on this board." -f $script:RhoSnapMisses, $script:RhoSnapWorst)
}

# Completion sentinel, written last and deleted at startup: its presence is the
# only thing on disk saying the CSVs beside it came from one complete run. It
# carries no absolute paths - swd_extract.ps1's used to, and put the username and
# the OneDrive tenant name into a directory with a public remote.
if ($script:WrittenTables.Count -eq 0) {
    Write-Warning 'no tables were written, so no completion sentinel is created. The output directory holds no data from this run.'
} else {
    $manifest = [ordered]@{
        generated_utc = (Get-Date).ToUniversalTime().ToString('o')
        board         = $BoardName
        tables        = $script:WrittenTables
        reports       = [ordered]@{
            found      = $files.Count
            read       = $reportsRead
        }
        # Run-wide: these include the .fynbs board file, not just the reports.
        not_deserialised = [ordered]@{
            untrusted  = $script:UntrustedSeen.Count
            failed     = $script:ParseFailures.Count
        }
        rho           = [ordered]@{
            v_ref_ms        = $V_REF
            snap_rtol       = $RHO_SNAP_RTOL
            snap_misses     = $script:RhoSnapMisses
            snap_worst_rel  = $script:RhoSnapWorst
        }
        sentinel_hits = $script:SentinelHits
        complete      = $true
    }
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    Write-Host "  wrote $([IO.Path]::GetFileName($manifestPath))  <- completion sentinel"
}
