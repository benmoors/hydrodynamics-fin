<#
.SYNOPSIS
    Read-only field census of ONE SWD board: what values actually exist to extract.

.DESCRIPTION
    swd_extract.ps1 maps 22 columns out of element_hydrodynamique's 101 fields.
    This script answers the prior question - which of the 101 are real - by
    reflecting over EVERY field of Class_surfboard, Class_rapport_hydrodynamique
    and element_hydrodynamique across one board's reports, and classifying each.

    Five failure modes are separated, because they look identical in a CSV:
      nonserialized  - [NonSerialized]; deserialises as 0/null whatever the physics
      constant_zero  - serialised, but SWD's hydroscan path never assigns it
      sentinel       - every readable value is Single.MaxValue / Inf / NaN
      constant       - genuinely uniform on this board (e.g. a per-board setting)
      populated      - carries information
    Only 'populated' columns are usable as features.

    Sentinels are counted in n_sentinel and EXCLUDED from min/max/mean/n_distinct,
    so those statistics describe the real measurements. Including them reported
    _largeur_B_element_mm's mean as 2.9e+36 against a true 455.77 mm, and would
    label an all-sentinel field 'constant' - the exact opposite of the truth, in
    the one artifact whose job is deciding which fields are real.

    READ-ONLY against the SWD installation and library. Nothing is written outside
    -OutDir. SWD is never launched and Form_shaper is never constructed.

.NOTES
    Windows PowerShell 5.1 only (BinaryFormatter was removed in .NET 9), x64 only
    (SurfHydrodynamics.exe and SlimDX.dll are x64-only images).
#>
[CmdletBinding()]
param(
    [string] $BoardName   = 'default_shortboard',
    [string] $BiblioPath  = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'ShaperWaveDynamics documents\biblio'),
    [string] $InstallPath = 'C:\Program Files\ShaperWaveDynamics\ShaperWaveDynamics',
    [string] $OutDir      = '',
    [string] $TrustManifest = '',
    [switch] $AllowUntrustedFiles
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ConvertTo-Csv formats a double with the CURRENT culture, so on an fr-FR or
# de-DE host 1.5 renders as "1,5" - which is also the CSV delimiter, so the
# writer quotes it and every numeric column arrives in pandas as text. Pin the
# whole run to InvariantCulture rather than formatting at each call site: this is
# the only place that can be forgotten once.
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw "Must run under Windows PowerShell 5.1 (powershell.exe). Detected PSEdition=$($PSVersionTable.PSEdition). BinaryFormatter was removed in .NET 9."
}
if (-not [Environment]::Is64BitProcess) {
    throw 'Must run in a 64-bit process. SurfHydrodynamics.exe and SlimDX.dll are x64-only images.'
}

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

# --- Provenance gate (same contract as swd_extract.ps1) ----------------------
# BinaryFormatter.Deserialize on an untrusted stream is arbitrary code execution
# in this process at this user's privilege. Nothing is deserialised unless its
# content hash is already approved.
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

$script:TrustedHashes = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
if (Test-Path -LiteralPath $TrustManifest) {
    $tmDoc = Get-Content -Raw -LiteralPath $TrustManifest | ConvertFrom-Json
    foreach ($e in $tmDoc.files) { [void]$script:TrustedHashes.Add([string]$e.sha256) }
} elseif (-not $AllowUntrustedFiles) {
    throw "Trust manifest not found: $(Format-PathForDisplay $TrustManifest). Run swd_extract.ps1 -TrustCurrentLibrary first."
}

# The bypass is announced HERE, before the long walk, not only in the summary:
# a banner that appears after several minutes of output is one the operator has
# already stopped watching for. provenance-gate.md section 2 makes reporting it
# part of the contract, so it is also recorded in census_manifest.json below -
# a field_census.csv produced with the gate off must not be indistinguishable
# from one produced with it on.
$script:UntrustedSeen = New-Object 'System.Collections.Generic.List[string]'
if ($AllowUntrustedFiles) {
    Write-Warning '****************************************************************'
    Write-Warning '*  PROVENANCE GATE BYPASSED (-AllowUntrustedFiles)             *'
    Write-Warning '*  Every .fyn* file will be handed to BinaryFormatter with NO   *'
    Write-Warning '*  trust check. BinaryFormatter.Deserialize on an unapproved    *'
    Write-Warning '*  stream is arbitrary code execution at this user privilege.   *'
    Write-Warning '****************************************************************'
}

function Get-Sha256Hex {
    # Get-FileHash is NOT available in this Windows PowerShell 5.1 host - measured,
    # it throws CommandNotFoundException - so hash through .NET directly.
    param([Parameter(Mandatory)][string] $Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Test-SwdFileTrusted {
    param([Parameter(Mandatory)][string] $Path)
    if ($AllowUntrustedFiles) { return $true }
    return $script:TrustedHashes.Contains((Get-Sha256Hex -Path $Path))
}

# --- Assembly resolution -----------------------------------------------------
# Reports are stamped "SurfHydrodynamics, Version=1.0.0.5" but the installed
# assembly is 1.0.8.1, so the default binder fails and AssemblyResolve fires.
# The handler MUST return an already-loaded assembly and MUST NOT call LoadFrom:
# an unguarded LoadFrom here re-enters the handler and dies with an uncatchable
# StackOverflowException. This has happened twice.
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

# GetType(name), never GetTypes(): the latter throws ReflectionTypeLoadException
# on this build.
$T_board   = $asm.GetType('SurfHydrodynamics.Class_surfboard')
$T_report  = $asm.GetType('SurfHydrodynamics.Class_rapport_hydrodynamique')
$T_element = $asm.GetType('SurfHydrodynamics.element_hydrodynamique')
foreach ($t in @($T_board, $T_report, $T_element)) { if (-not $t) { throw 'Expected SWD type missing.' } }

$BIND = [Reflection.BindingFlags]'Public,NonPublic,Instance'
$fmt  = New-Object System.Runtime.Serialization.Formatters.Binary.BinaryFormatter

function Format-MessageForDisplay {
    <# A .NET IOException embeds the full absolute path, so an error message is a
       second route for the username and the OneDrive tenant folder to reach a
       pasted console log. Longest roots first: OneDrive lives under USERPROFILE. #>
    param([string] $Message)
    foreach ($root in @($env:OneDriveCommercial, $env:OneDriveConsumer, $env:OneDrive)) {
        if ($root) { $Message = $Message.Replace($root, '~\OneDrive') }
    }
    if ($env:USERPROFILE) { $Message = $Message.Replace($env:USERPROFILE, '~') }
    return $Message
}

function Read-SwdFile {
    <# The trust check is FIRST - BinaryFormatter must never see an unapproved
       stream - and INSIDE the try, which is load-bearing rather than tidy:
       Test-SwdFileTrusted hashes the file, so its ReadAllBytes is the run's first
       I/O on it. With the try around only the Deserialize, one exclusively locked
       report threw out of the hash and, under $ErrorActionPreference = 'Stop',
       took the whole run with it - measured on extract_board.ps1's identical
       arrangement, which died having read 0 of 11 reports. #>
    param([Parameter(Mandatory)][string] $Path)
    $leaf = Split-Path -Leaf $Path
    $fs = $null
    try {
        if (-not (Test-SwdFileTrusted -Path $Path)) {
            Write-Warning "UNTRUSTED, skipped: $leaf"
            $script:UntrustedSeen.Add($leaf)
            return $null
        }
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        return $fmt.Deserialize($fs)
    } catch {
        Write-Warning "read failed, skipped: $leaf :: $(Format-MessageForDisplay $_.Exception.Message)"
        return $null
    } finally { if ($fs) { $fs.Dispose() } }
}

# --- Census accumulator ------------------------------------------------------
# One record per (type, field).
#
# A reference-typed field is NEVER string-interpolated or formatted. These object
# graphs are cyclic - planche_ref back-references the parent board - and
# formatting one is the second known route into a StackOverflowException. Only
# the concrete type name and a collection length are ever taken from them.
$script:Census = [ordered]@{}

# SWD leaves some Single fields at Single.MaxValue (3.4028235e38) on non-contact
# elements: a sentinel, not a measurement. Same threshold and treatment as
# extract_board.ps1's Get-Num, ported rather than re-invented.
#
# Letting it into the statistics is not cosmetic. The shipped field_census.csv
# reported _largeur_B_element_mm with mean 2.914624e+36 against a true 455.77 mm,
# and a field that is sentinel on EVERY row would have come back n_distinct = 1,
# i.e. 'constant' - the exact opposite of the truth, in the one artifact whose
# job is deciding which fields are real. Sentinels are counted in their own
# column and kept out of sum/min/max/distinct.
$SENTINEL_LIMIT = 1e30

function Get-CensusSlot {
    param([Parameter(Mandatory)][Type] $Type, [Parameter(Mandatory)][Reflection.FieldInfo] $Fi)
    $key = "$($Type.Name)|$($Fi.Name)"
    if (-not $script:Census.Contains($key)) {
        $script:Census[$key] = [ordered]@{
            type        = $Type.Name
            field       = $Fi.Name
            dotnet_type = $Fi.FieldType.Name
            serialized  = (-not $Fi.IsNotSerialized)
            n_seen      = 0
            n_null      = 0
            n_numeric   = 0
            n_sentinel  = 0
            distinct    = (New-Object 'System.Collections.Generic.HashSet[string]')
            min         = [double]::NaN
            max         = [double]::NaN
            sum         = 0.0
            shape_min   = [int]::MaxValue
            shape_max   = -1
            ref_type    = ''
        }
    }
    return $script:Census[$key]
}

function Add-CensusSample {
    param([Parameter(Mandatory)][Type] $Type, [Parameter(Mandatory)][Reflection.FieldInfo] $Fi, $Owner)
    $slot = Get-CensusSlot -Type $Type -Fi $Fi
    $slot.n_seen++
    $v = $null
    try { $v = $Fi.GetValue($Owner) } catch { $slot.ref_type = 'READ_ERROR'; return }
    if ($null -eq $v) { $slot.n_null++; return }

    if ($v -is [ValueType] -and $v -isnot [datetime]) {
        # Single/Double/Int32/Boolean. Structs (SlimDX.Vector3) are value types
        # too, so gate on a successful numeric conversion rather than on kind.
        $d = $null
        try { $d = [double]$v } catch { $d = $null }
        if ($null -ne $d) {
            # NaN / +-Infinity / Single.MaxValue are SWD's not-a-measurement
            # markers. Counted separately; they never reach sum, min, max or the
            # distinct set, which is what made the width column's mean 1e36.
            if ([double]::IsNaN($d) -or [double]::IsInfinity($d) -or [Math]::Abs($d) -gt $SENTINEL_LIMIT) {
                $slot.n_sentinel++
                return
            }
            $slot.n_numeric++
            $slot.sum += $d
            if ([double]::IsNaN($slot.min) -or $d -lt $slot.min) { $slot.min = $d }
            if ([double]::IsNaN($slot.max) -or $d -gt $slot.max) { $slot.max = $d }
            if ($slot.distinct.Count -lt 5000) {
                # No signed-zero normalisation here, deliberately. It looks like
                # -0.0 and 0.0 would key differently and split an all-zero field
                # into 2 distinct values, labelling it 'populated' instead of
                # 'constant_zero'. They do not: .NET Framework's ToString('R')
                # renders BOTH as "0" (measured in this host - the IEEE-compliant
                # formatting that emits "-0" arrived in .NET Core 3.0). This
                # script throws on any PSEdition but Desktop, so the .NET Core
                # behaviour is unreachable by construction.
                [void]$slot.distinct.Add($d.ToString('R', [Globalization.CultureInfo]::InvariantCulture))
            }
            return
        }
        $slot.ref_type = $v.GetType().Name
        return
    }

    $slot.ref_type = $v.GetType().Name
    $n = -1
    try {
        if     ($v -is [Array])                   { $n = $v.Length }
        elseif ($v -is [Collections.ICollection])  { $n = $v.Count }
        elseif ($v -is [string])                   { $n = $v.Length }
    } catch { $n = -1 }
    if ($n -ge 0) {
        if ($n -lt $slot.shape_min) { $slot.shape_min = $n }
        if ($n -gt $slot.shape_max) { $slot.shape_max = $n }
    }
}

function Add-AllFields {
    param([Parameter(Mandatory)][Type] $Type, $Owner)
    foreach ($fi in $Type.GetFields($BIND)) { Add-CensusSample -Type $Type -Fi $fi -Owner $Owner }
}

# --- Walk the board ----------------------------------------------------------
Write-Host "census: $BoardName"
Write-Host "  library: $(Format-PathForDisplay $BiblioPath)"

$boardsRoot = Join-Path $BiblioPath 'Boards'
$boardFiles = @()
if (Test-Path -LiteralPath $boardsRoot) {
    $boardFiles = @(Get-ChildItem -LiteralPath $boardsRoot -Recurse -Filter '*.fynbs' -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.BaseName -eq $BoardName })
}
Write-Host "  .fynbs files: $($boardFiles.Count)"
if ($boardFiles.Count -gt 1) {
    # The library holds copies at several depths, so two .fynbs can share a
    # BaseName. Every match is censused into one set of per-field slots here,
    # which silently mixes two boards' values into one 'constant'/'populated'
    # verdict. Kept (a census of all of them is the honest read of an ambiguous
    # name) but no longer silent - extract_board.ps1 takes the first and warns.
    Write-Warning "$($boardFiles.Count) .fynbs files are named '$BoardName'; the census below MERGES all of them:"
    foreach ($d in $boardFiles) { Write-Warning "    $(Format-PathForDisplay $d.FullName)" }
}
foreach ($bf in $boardFiles) {
    $bd = Read-SwdFile -Path $bf.FullName
    if ($bd) { Add-AllFields -Type $T_board -Owner $bd }
}

$scanDir = Join-Path (Join-Path $BiblioPath 'rapports_hydro') $BoardName
if (-not (Test-Path -LiteralPath $scanDir)) { throw "No reports directory for '$BoardName': $(Format-PathForDisplay $scanDir)" }
$reportFiles = @(Get-ChildItem -LiteralPath $scanDir -Filter '*.fynrhydro' -File | Sort-Object Name)
Write-Host "  .fynrhydro files: $($reportFiles.Count)"

$nCases = 0; $nElements = 0; $nFail = 0
foreach ($rf in $reportFiles) {
    $rep = Read-SwdFile -Path $rf.FullName
    if (-not $rep) { $nFail++; continue }
    Add-AllFields -Type $T_report -Owner $rep

    $fiCases = $T_report.GetField('list_elements_hydro', $BIND)
    if (-not $fiCases) { continue }
    $cases = $fiCases.GetValue($rep)
    if (-not $cases) { continue }
    # Ragged ArrayList of roll cases; fewer elements stay in contact as the board heels.
    for ($ci = 0; $ci -lt $cases.Count; $ci++) {
        $case = $cases[$ci]
        if (-not $case) { continue }
        $nCases++
        for ($ei = 0; $ei -lt $case.Count; $ei++) {
            $el = $case[$ei]
            if (-not $el) { continue }
            $nElements++
            Add-AllFields -Type $T_element -Owner $el
        }
    }
}
Write-Host "  roll cases: $nCases   elements: $nElements   failed reports: $nFail"

# --- Classify and write ------------------------------------------------------
$rows = @()
foreach ($key in $script:Census.Keys) {
    $s = $script:Census[$key]
    $nDistinct = $s.distinct.Count
    # No 'not_seen' branch: a slot only exists because Add-CensusSample created it
    # and immediately incremented n_seen, so n_seen -eq 0 was unreachable and read
    # as a state the census could report. A field that is never visited simply has
    # no row.
    $status =
        if     (-not $s.serialized)                    { 'nonserialized' }
        elseif ($s.n_null -eq $s.n_seen)               { 'null' }
        elseif ($s.n_numeric -eq 0 -and
                $s.n_sentinel -gt 0)                   { 'sentinel' }
        elseif ($s.n_numeric -eq 0)                    { 'reference' }
        elseif ($nDistinct -eq 1 -and $s.min -eq 0.0)  { 'constant_zero' }
        elseif ($nDistinct -eq 1)                      { 'constant' }
        else                                           { 'populated' }

    $rows += [pscustomobject][ordered]@{
        type        = $s.type
        field       = $s.field
        dotnet_type = $s.dotnet_type
        serialized  = [int][bool]$s.serialized
        status      = $status
        n_seen      = $s.n_seen
        n_null      = $s.n_null
        n_sentinel  = $s.n_sentinel
        n_distinct  = $nDistinct
        min         = $(if ($s.n_numeric -gt 0) { $s.min } else { '' })
        max         = $(if ($s.n_numeric -gt 0) { $s.max } else { '' })
        mean        = $(if ($s.n_numeric -gt 0) { $s.sum / $s.n_numeric } else { '' })
        ref_type    = $s.ref_type
        shape_min   = $(if ($s.shape_max -ge 0) { $s.shape_min } else { '' })
        shape_max   = $(if ($s.shape_max -ge 0) { $s.shape_max } else { '' })
    }
}

# UTF-8 without BOM: a BOM breaks the Python readers downstream. Export-Csv
# -Encoding UTF8 writes one, and Out-File on 5.1 writes UTF-16LE.
$csvPath = Join-Path $OutDir 'field_census.csv'
$csv = ($rows | Sort-Object type, field | ConvertTo-Csv -NoTypeInformation) -join "`r`n"
[IO.File]::WriteAllText($csvPath, $csv + "`r`n", (New-Object Text.UTF8Encoding($false)))
Write-Host ""
Write-Host "wrote $(Format-PathForDisplay $csvPath)  ($($rows.Count) fields)"

foreach ($t in @('Class_surfboard', 'Class_rapport_hydrodynamique', 'element_hydrodynamique')) {
    $sub = @($rows | Where-Object { $_.type -eq $t })
    if ($sub.Count -eq 0) { continue }
    Write-Host ""
    Write-Host "$t  ($($sub.Count) fields)"
    $sub | Group-Object status | Sort-Object Count -Descending | ForEach-Object {
        Write-Host ("    {0,-14} {1,4}" -f $_.Name, $_.Count)
    }
}

# Named, not just counted in a column nobody opens: min/max/mean for these fields
# are computed over the NON-sentinel rows only, so the ranges below are narrower
# than a naive reader of the raw field would get.
$sentinelRows = @($rows | Where-Object { $_.n_sentinel -gt 0 })
Write-Host ""
if ($sentinelRows.Count -eq 0) {
    Write-Host 'sentinel values (Single.MaxValue / Inf / NaN): none'
} else {
    Write-Host 'sentinel values excluded from min/max/mean/n_distinct:'
    foreach ($sr in ($sentinelRows | Sort-Object -Property @{E='n_sentinel';D=$true})) {
        Write-Host ("    {0,-42} {1,6} of {2,-6} status={3}" -f $sr.field, $sr.n_sentinel, $sr.n_seen, $sr.status)
    }
}
if ($nFail -gt 0) { Write-Warning "$nFail report(s) were skipped (untrusted or failed to deserialise); the census above covers the rest." }

# --- Run record --------------------------------------------------------------
# field_census.csv is one row per field and has nowhere to carry a run-level
# fact, so the provenance state lives beside it. Written LAST, after the CSV, so
# its presence also means the census completed. It carries no absolute paths.
$censusManifest = Join-Path $OutDir 'census_manifest.json'
$doc = [ordered]@{
    generated_utc         = (Get-Date).ToUniversalTime().ToString('o')
    board                 = $BoardName
    fields                = $rows.Count
    reports_found         = $reportFiles.Count
    reports_failed        = $nFail
    roll_cases            = $nCases
    elements              = $nElements
    untrusted_skipped     = $script:UntrustedSeen.Count
    # The whole point of this file. A census taken with the gate off is not the
    # same artifact as one taken with it on, and nothing else on disk says which.
    provenance_gate       = $(if ($AllowUntrustedFiles) { 'BYPASSED (-AllowUntrustedFiles)' } else { 'enforced' })
    sentinel_fields       = $sentinelRows.Count
}
[IO.File]::WriteAllText($censusManifest, ($doc | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
Write-Host "wrote $([IO.Path]::GetFileName($censusManifest))"

if ($AllowUntrustedFiles) {
    Write-Warning 'PROVENANCE GATE BYPASSED (-AllowUntrustedFiles): every .fyn* was deserialised without a trust check. Recorded in census_manifest.json.'
} elseif ($script:UntrustedSeen.Count -gt 0) {
    Write-Warning "$($script:UntrustedSeen.Count) file(s) were NOT deserialised - absent from the trust manifest:"
    foreach ($u in $script:UntrustedSeen) { Write-Warning "    $u" }
    Write-Warning 'The census above is INCOMPLETE by exactly those files.'
}
