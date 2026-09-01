<#
.SYNOPSIS
    Is element[0] of each roll case a GLOBAL aggregate rather than a strip?

.DESCRIPTION
    element[0] carries nom='global', infos='Contains all hydrodynamics elements'.
    If it is the sum of the remaining elements, then summing every element of a
    roll case - which swd_extract.ps1 does to build operating_points.csv - counts
    the whole board twice.

    Read-only. Prints only; writes nothing.
#>
[CmdletBinding()]
param(
    [string] $BoardName   = 'default_shortboard',
    [string] $BiblioPath  = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'ShaperWaveDynamics documents\biblio'),
    [string] $InstallPath = 'C:\Program Files\ShaperWaveDynamics\ShaperWaveDynamics'
)
$ErrorActionPreference = 'Stop'
# Deliberately NOT StrictMode: this probe walks heterogeneous object graphs and
# a missing member here should be visible as a null, not a terminating error.

if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Windows PowerShell 5.1 required.' }

$TrustManifest = Join-Path $env:LOCALAPPDATA 'swd-extract\trusted_files.json'
$trusted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($e in (Get-Content -Raw -LiteralPath $TrustManifest | ConvertFrom-Json).files) { [void]$trusted.Add([string]$e.sha256) }

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
$T_report  = $asm.GetType('SurfHydrodynamics.Class_rapport_hydrodynamique')
$T_element = $asm.GetType('SurfHydrodynamics.element_hydrodynamique')
$BIND = [Reflection.BindingFlags]'Public,NonPublic,Instance'
$fmt  = New-Object System.Runtime.Serialization.Formatters.Binary.BinaryFormatter

$E  = [char]0xE9
$FT = "_train${E}e_globale_horizontale_n"
$PT = '_portance_globale_verticale_n'
$FZ = '_Fz_planing_n'
$WL = "_longueur_mouill${E}e_element_mm"

function Get-F { param($o, [string]$n) $fi = $T_element.GetField($n, $BIND); if ($fi) { return $fi.GetValue($o) } return $null }
function Get-D { param($o, [string]$n) $v = Get-F $o $n; if ($null -eq $v) { return [double]::NaN } return [double]$v }

$scanDir = Join-Path (Join-Path $BiblioPath 'rapports_hydro') $BoardName
$files = @(Get-ChildItem -LiteralPath $scanDir -Filter '*.fynrhydro' -File | Sort-Object Name)

$nGlobal = 0; $nTotal = 0; $agree = 0; $disagree = 0
$script:subSeen = 0; $script:subNull = 0; $script:subNonZero = 0
$script:subSamples = New-Object 'System.Collections.Generic.List[string]' 
foreach ($rf in $files) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $hash = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($rf.FullName))).Replace('-','')
    $sha.Dispose()
    if (-not $trusted.Contains($hash)) { Write-Warning "untrusted, skipped: $($rf.Name)"; continue }
    $fs = [IO.File]::Open($rf.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { $rep = $fmt.Deserialize($fs) } finally { $fs.Dispose() }

    $drift = $T_report.GetField('angle_drift_deg', $BIND).GetValue($rep)
    $cases = $T_report.GetField('list_elements_hydro', $BIND).GetValue($rep)
    if (-not $cases) { continue }

    for ($ci = 0; $ci -lt $cases.Count; $ci++) {
        $case = $cases[$ci]
        if (-not $case) { continue }
        $names = @()
        $sumFT = 0.0; $sumPT = 0.0; $sumFZ = 0.0
        $g_FT = [double]::NaN; $g_PT = [double]::NaN; $g_FZ = [double]::NaN
        for ($ei = 0; $ei -lt $case.Count; $ei++) {
            $el = $case[$ei]
            if (-not $el) { continue }
            $nTotal++
            $nm = [string](Get-F $el 'nom')
            $names += $nm
            $eint = Get-F $el 'elements_internes'
            if ($eint) {
                $n2 = if ($eint -is [Array]) { $eint.Length } else { $eint.Count }
                for ($k = 0; $k -lt $n2; $k++) {
                    $sub = $eint[$k]
                    if ($null -eq $sub) { $script:subNull++; continue }
                    $script:subSeen++
                    $sfz = Get-D $sub $FZ; $swl = Get-D $sub $WL
                    if (-not [double]::IsNaN($sfz) -and $sfz -ne 0) { $script:subNonZero++ }
                    if ($script:subSamples.Count -lt 8) { [void]$script:subSamples.Add(("Fz={0:N3} wet_mm={1:N2}" -f $sfz, $swl)) }
                }
            }
            if ($nm -eq 'global') {
                $nGlobal++
                $g_FT = Get-D $el $FT; $g_PT = Get-D $el $PT; $g_FZ = Get-D $el $FZ
            } else {
                $sumFT += (Get-D $el $FT); $sumPT += (Get-D $el $PT); $sumFZ += (Get-D $el $FZ)
            }
        }
        if (-not [double]::IsNaN($g_PT) -and $sumPT -ne 0) {
            $ratio = $g_PT / $sumPT
            if ([Math]::Abs($ratio - 1.0) -lt 0.01) { $agree++ } else { $disagree++ }
            if ($ci -eq 0 -or $drift -eq 10) {
                Write-Host ("drift {0,3}  case {1}  n={2,2}  global_lift={3,12:N2}  sum_others={4,12:N2}  ratio={5:N4}   global_drag={6,10:N2} sum={7,10:N2}" -f `
                    $drift, $ci, $case.Count, $g_PT, $sumPT, $ratio, $g_FT, $sumFT)
            }
        }
    }
}
Write-Host ""
Write-Host "elements total: $nTotal    named 'global': $nGlobal"
Write-Host "roll cases where global == sum(others) within 1%: $agree     differing: $disagree"
Write-Host ""
Write-Host "elements_internes: seen=$($script:subSeen)  null=$($script:subNull)  with non-zero Fz_planing=$($script:subNonZero)"
foreach ($x in $script:subSamples) { Write-Host "   $x" }
