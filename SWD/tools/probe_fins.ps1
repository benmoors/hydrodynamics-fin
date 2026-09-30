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
    NOT YET SQA'D - listed in SQA-LOG.md at the repo root. CLAUDE.md s4: do not run it before that pass.

.EXAMPLE
    # CSV here is UTF-8 WITHOUT a BOM. In Windows PowerShell 5.1, '>' writes UTF-16LE with a
    # BOM, so capture the rows through a UTF-8 console and write them explicitly:
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
    $rows = powershell.exe -NoProfile -File SWD\tools\probe_fins.ps1
    [IO.File]::WriteAllLines("$env:TEMP\fins.csv", $rows, (New-Object Text.UTF8Encoding $false))
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

# Keep the username and the OneDrive tenant out of anything printed (R9). Both ported from
# census_board.ps1: the OneDrive roots are replaced FIRST, because they sit under USERPROFILE
# and '~' alone leaves the tenant folder name in place.
function Format-PathForDisplay {
    param([string] $Path)
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

function Format-MessageForDisplay {
    # A .NET IOException embeds the full absolute path, so an error message is a second route out.
    param([string] $Message)
    foreach ($root in @($env:OneDriveCommercial, $env:OneDriveConsumer, $env:OneDrive)) {
        if ($root) { $Message = $Message.Replace($root, '~\OneDrive') }
    }
    if ($env:USERPROFILE) { $Message = $Message.Replace($env:USERPROFILE, '~') }
    return $Message
}

# A missing root otherwise surfaces later as a Get-ChildItem or LoadFrom error whose text
# carries the full path (census_board.ps1 does the same).
foreach ($p in @($BiblioPath, $InstallPath)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Path not found: $(Format-PathForDisplay $p)" }
}

# Resolved through the same provider that just validated them, so a '~' or relative spelling
# cannot produce a protected root that points nowhere (census_board.ps1:92-105).
try {
    $BiblioPath  = (Convert-Path -LiteralPath $BiblioPath).TrimEnd('\')
    $InstallPath = (Convert-Path -LiteralPath $InstallPath).TrimEnd('\')
} catch {
    throw "Could not resolve a read-only root to a canonical path: $(Format-MessageForDisplay $_.Exception.Message)"
}

# --- read-only roots, compared canonically (ported from census_board.ps1:167-260) ---------
# Each supplied root AND its parent is protected, and paths are compared by the name Windows
# resolves them to, so an 8.3 name, a junction or a subst drive cannot slip past.
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
    # The path Windows resolves this to, or $null. FILE_FLAG_BACKUP_SEMANTICS (0x02000000)
    # lets CreateFile open a directory handle.
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
    # Canonical form of a path that may not exist yet: the nearest existing ancestor,
    # canonicalised, with the missing tail re-appended. $null if nothing resolves.
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
    # Each read-only path AND its parent. A drive root is skipped.
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
    # The first root $Path sits at or under, else $null. The separator matters:
    # "...DynamicsOther" is not under "...Dynamics".
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
$canonRoots = @(foreach ($r in $protectedRoots) { Resolve-CanonicalTarget -Path $r })
$allRoots = @($protectedRoots) + @($canonRoots | Where-Object { $_ })

# --- trust manifest ----------------------------------------------------------
# Read-only here, but refused inside a protected tree: a manifest read from inside the
# library would let a tampered library vouch for itself (census_board.ps1:278-299, S14).
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
if (-not (Test-Path -LiteralPath $TrustManifest)) { throw 'Trust manifest not found; run swd_extract.ps1 -TrustCurrentLibrary first.' }
$trusted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($e in (Get-Content -Raw -LiteralPath $TrustManifest | ConvertFrom-Json).files) { [void]$trusted.Add([string]$e.sha256) }

function Get-StreamSha256 {
    # One hasher per stream (S14): a SHA256 whose ComputeHash threw mid-read keeps the bytes
    # it had absorbed, so a hasher shared across files hashed the NEXT file wrong (measured
    # 2026-10-01 on SHA256Managed), and that trusted board was skipped as untrusted.
    param([Parameter(Mandatory)][IO.Stream] $Stream)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Stream)).Replace('-', '') } finally { $sha.Dispose() }
}

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
$boardsRoot = Join-Path $BiblioPath 'Boards'
if (-not (Test-Path -LiteralPath $boardsRoot)) { throw "Boards folder not found: $(Format-PathForDisplay $boardsRoot)" }
$boardFiles = @(Get-ChildItem -LiteralPath $boardsRoot -Recurse -Filter *.fynbs -File)
foreach ($file in $boardFiles) {
    $board = $null
    $fs = $null
    try {
        $fs = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        # Hash the OPEN stream, then rewind: no window to swap the file between check and use.
        $hex = Get-StreamSha256 -Stream $fs
        if (-not $trusted.Contains($hex)) {
            [Console]::Error.WriteLine("untrusted, skipped: $($file.Name)")
            continue
        }
        $fs.Position = 0
        $board = $fmt.Deserialize($fs)
    } catch {
        [Console]::Error.WriteLine("read failed, skipped: $($file.Name) :: $(Format-MessageForDisplay $_.Exception.Message)")
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
