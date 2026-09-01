<#
.SYNOPSIS
    Read-only structural probe of the nested containers the census flagged as
    'reference': what is actually inside list_incidences_deg, list_posx/posy,
    elements_internes, vecteur_mecanique_* and the geometry polygons.

.DESCRIPTION
    The census answers "which fields exist". This answers "what is inside the
    ones holding objects", which decides whether they are extractable as CSV
    columns. Prints structure and a few sample values; writes nothing but stdout.

.NOTES
    Windows PowerShell 5.1 only, x64 only. Read-only. SWD is never launched.
#>
[CmdletBinding()]
param(
    [string] $BoardName   = 'default_shortboard',
    [string] $DriftFile   = 'drift_10.fynrhydro',
    [string] $BiblioPath  = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'ShaperWaveDynamics documents\biblio'),
    [string] $InstallPath = 'C:\Program Files\ShaperWaveDynamics\ShaperWaveDynamics',
    [string] $TrustManifest = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Windows PowerShell 5.1 required (BinaryFormatter).' }
if (-not [Environment]::Is64BitProcess)      { throw '64-bit process required.' }

if ([string]::IsNullOrWhiteSpace($TrustManifest)) {
    $TrustManifest = Join-Path $env:LOCALAPPDATA 'swd-extract\trusted_files.json'
}
$trusted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
if (Test-Path -LiteralPath $TrustManifest) {
    foreach ($e in (Get-Content -Raw -LiteralPath $TrustManifest | ConvertFrom-Json).files) { [void]$trusted.Add([string]$e.sha256) }
} else { throw "Trust manifest not found: $TrustManifest" }

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

$path = Join-Path (Join-Path (Join-Path $BiblioPath 'rapports_hydro') $BoardName) $DriftFile
$sha = [Security.Cryptography.SHA256]::Create()
$hash = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($path))).Replace('-','')
$sha.Dispose()
if (-not $trusted.Contains($hash)) { throw "UNTRUSTED file, refusing to deserialise: $DriftFile" }

$fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try { $rep = $fmt.Deserialize($fs) } finally { $fs.Dispose() }

function Get-F { param($o, [string]$n, [Type]$t) $fi = $t.GetField($n, $BIND); if ($fi) { return $fi.GetValue($o) } return $null }

Write-Host "=== $DriftFile ==="
Write-Host "angle_drift_deg = $(Get-F $rep 'angle_drift_deg' $T_report)"

$cases = Get-F $rep 'list_elements_hydro' $T_report
Write-Host "roll cases: $($cases.Count)"

# --- report-level parallel lists -------------------------------------------
foreach ($ln in @('list_incidences_deg','list_posx','list_posy',
                  'list_index_point_ligne_attaque_1_index_axe_roulis',
                  'list_index_point_ligne_attaque_2_index_axe_roulis')) {
    $lst = Get-F $rep $ln $T_report
    if (-not $lst) { Write-Host "`n$ln : NULL"; continue }
    Write-Host ""
    Write-Host "$ln : outer=$($lst.Count)"
    for ($i = 0; $i -lt $lst.Count; $i++) {
        $inner = $lst[$i]
        if ($null -eq $inner) { Write-Host "  [$i] null"; continue }
        $tn = $inner.GetType().Name
        $cnt = -1
        if ($inner -is [Array]) { $cnt = $inner.Length } elseif ($inner -is [Collections.ICollection]) { $cnt = $inner.Count }
        $nElem = if ($null -ne $cases[$i]) { $cases[$i].Count } else { -1 }
        $sample = ''
        if ($cnt -gt 0) {
            $take = [Math]::Min(6, $cnt)
            $vals = @()
            for ($k = 0; $k -lt $take; $k++) {
                $v = $inner[$k]
                if ($null -eq $v) { $vals += 'null' }
                elseif ($v -is [ValueType]) { $vals += ([double]$v).ToString('G6', [Globalization.CultureInfo]::InvariantCulture) }
                else { $vals += $v.GetType().Name }
            }
            $sample = ' :: ' + ($vals -join ', ')
        }
        Write-Host "  [$i] $tn count=$cnt (elements in case=$nElem)$sample"
    }
}

# --- one element, in depth --------------------------------------------------
$case0 = $cases[0]
$el = $case0[0]
Write-Host ""
Write-Host "=== element [case 0][elem 0] ==="
foreach ($n in @('nom','infos')) { Write-Host "  $n = $(Get-F $el $n $T_element)" }

foreach ($n in @('_point_application_global_normal','PremierPoint_m','DernierPoint_m',
                 'point_intersect_ligne_attack_ligne_roulis_normal')) {
    $v = Get-F $el $n $T_element
    if ($null -eq $v) { Write-Host "  $n = null"; continue }
    Write-Host ("  {0} = X {1:G6}  Y {2:G6}  Z {3:G6}" -f $n, $v.X, $v.Y, $v.Z)
}

foreach ($n in @('equation_plan_rotation_yaw','equation_plan_rotation_pitch','equation_plan_rotation_roll')) {
    $v = Get-F $el $n $T_element
    if ($v) { Write-Host "  $n = [$(($v | ForEach-Object { $_.ToString('G6',[Globalization.CultureInfo]::InvariantCulture) }) -join ', ')]" }
}

# vecteur_mecanique: enumerate its own fields, since the type is unknown here.
foreach ($n in @('vecteur_mecanique_axe_yaw','vecteur_mecanique_axe_pitch','vecteur_mecanique_axe_roll')) {
    $v = Get-F $el $n $T_element
    if ($null -eq $v) { Write-Host "  $n = null"; continue }
    $vt = $v.GetType()
    Write-Host "  $n : $($vt.Name)"
    foreach ($fi in $vt.GetFields($BIND)) {
        $fv = $fi.GetValue($v)
        $desc =
            if ($null -eq $fv) { 'null' }
            elseif ($fv -is [ValueType] -and $fv.GetType().Name -eq 'Vector3') { "Vec3 X $($fv.X) Y $($fv.Y) Z $($fv.Z)" }
            elseif ($fv -is [ValueType]) { "$fv" }
            else { $fv.GetType().Name }
        Write-Host "      $($fi.Name) = $desc"
    }
}

# --- elements_internes ------------------------------------------------------
$ei = Get-F $el 'elements_internes' $T_element
Write-Host ""
if ($null -eq $ei) { Write-Host "elements_internes = null" }
else {
    $eiN = if ($ei -is [Array]) { $ei.Length } else { $ei.Count }
    Write-Host "elements_internes: count=$eiN"
    $probe = @('_Fz_planing_n','_Fx_planing','_Fx_friction_n','_largeur_B_element_mm',
               '_longueur_mouill' + [char]0xE9 + 'e_element_mm',
               '_section_frontale_flux_d' + [char]0xE9 + 'vi' + [char]0xE9 + '_m2_planing',
               'inclinaison_roulis_rad_ligne_attack')
    for ($i = 0; $i -lt $eiN; $i++) {
        $sub = $ei[$i]
        if ($null -eq $sub) { Write-Host "  [$i] null"; continue }
        $parts = @()
        foreach ($p in $probe) {
            $v = Get-F $sub $p $T_element
            $parts += ('{0}={1}' -f $p.Substring(0, [Math]::Min(14, $p.Length)),
                       $(if ($null -eq $v) { 'null' } else { ([double]$v).ToString('G5', [Globalization.CultureInfo]::InvariantCulture) }))
        }
        Write-Host "  [$i] $($parts -join '  ')"
    }
}

# --- geometry polygons ------------------------------------------------------
Write-Host ""
foreach ($n in @('tableau_points_graphique_polygone_outline_element_echelle_1_en_metres_index_axe_roulis',
                 'tableau_points_graphique_polygone_surface_contact_eau_echelle_1_en_metres',
                 'array_vector2_normal_ligne_fond_du_rail_vers_ligne_contact',
                 'array_vector3_normal_coupe_verticale_axe_roulis_repere_planche')) {
    $v = Get-F $el $n $T_element
    if ($null -eq $v) { Write-Host "$n : null"; continue }
    $cnt = if ($v -is [Array]) { $v.Length } else { $v.Count }
    Write-Host "$n : count=$cnt"
    $take = [Math]::Min(3, $cnt)
    for ($k = 0; $k -lt $take; $k++) {
        $p = $v[$k]
        if ($null -eq $p) { Write-Host "   [$k] null"; continue }
        $pt = $p.GetType()
        if ($pt.Name -eq 'Vector3')      { Write-Host ("   [{0}] Vec3 X {1:G6} Y {2:G6} Z {3:G6}" -f $k, $p.X, $p.Y, $p.Z) }
        elseif ($pt.Name -eq 'Vector2')  { Write-Host ("   [{0}] Vec2 X {1:G6} Y {2:G6}" -f $k, $p.X, $p.Y) }
        else {
            $fnames = ($pt.GetFields($BIND) | Select-Object -First 8 | ForEach-Object { $_.Name }) -join ', '
            Write-Host "   [$k] $($pt.Name) fields: $fnames"
        }
    }
}

# --- Is element[0] an aggregate of the rest? -------------------------------
Write-Host ""
Write-Host "=== aggregate test: case 0, per-element nom + forces ==="
$FZ = '_Fz_planing_n'; $FX = '_Fx_planing'
$FT = '_train' + [char]0xE9 + 'e_globale_horizontale_n'
$PT = '_portance_globale_verticale_n'
$sumFz = 0.0; $sumFx = 0.0; $sumFt = 0.0; $sumPt = 0.0
for ($i = 0; $i -lt $case0.Count; $i++) {
    $e0 = $case0[$i]
    $nm = Get-F $e0 'nom' $T_element
    $fz = [double](Get-F $e0 $FZ $T_element); $fx = [double](Get-F $e0 $FX $T_element)
    $ft = [double](Get-F $e0 $FT $T_element); $pt = [double](Get-F $e0 $PT $T_element)
    Write-Host ("  [{0}] nom={1,-10} Fz_planing={2,12:N2}  Fx_planing={3,10:N2}  drag_tot={4,10:N2}  lift_tot={5,12:N2}" -f $i,$nm,$fz,$fx,$ft,$pt)
    if ($i -gt 0) { $sumFz += $fz; $sumFx += $fx; $sumFt += $ft; $sumPt += $pt }
}
Write-Host ("  SUM of [1..n]         Fz_planing={0,12:N2}  Fx_planing={1,10:N2}  drag_tot={2,10:N2}  lift_tot={3,12:N2}" -f $sumFz,$sumFx,$sumFt,$sumPt)
