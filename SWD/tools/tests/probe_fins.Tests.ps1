#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }
<#
    Pester 6 tests for probe_fins.ps1, Windows PowerShell 5.1.

    probe_fins.ps1 must not run against the real install or library before its SQA pass
    (CLAUDE.md section 4), and these tests keep it that way. Every run is a STAGED COPY of the
    script, out of process, against a FAKE SWD built here: a stand-in SurfHydrodynamics assembly
    compiled with the framework's own csc.exe (one type, one field: what the probe reads),
    BinaryFormatter boards serialised from it, and a trust manifest of their hashes. The fake is
    built in a child process, so the stand-in assembly never loads into the Pester process.
    Every path handed to the probe is asserted to sit under TestDrive.

    The fake library sits under a fake OneDrive root whose folder name stands in for the tenant,
    and the child sees that root in its OneDrive variables, so redaction (R9) is tested without
    the real tenant appearing anywhere.

    $env:PROBE_FINS_TARGET, when set, is staged instead of the live script (fail-before runs).
#>

BeforeAll {
    $live = $env:PROBE_FINS_TARGET
    if (-not $live) { $live = Join-Path (Split-Path -Parent $PSScriptRoot) 'probe_fins.ps1' }
    $script:Stage = Join-Path $TestDrive 'stage'
    New-Item -ItemType Directory -Force -Path $script:Stage | Out-Null
    $script:Probe = Join-Path $script:Stage 'probe_fins.ps1'
    Copy-Item -LiteralPath $live -Destination $script:Probe
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $a = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($live))).Replace('-', '')
        $b = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($script:Probe))).Replace('-', '')
    } finally { $sha.Dispose() }
    if ($a -ne $b) { throw "staged copy does not match the script under test ($a vs $b)" }

    $script:Tenant = 'Contoso Fixture Tenant'
    $script:FakeOneDrive = Join-Path $TestDrive "OneDrive - $($script:Tenant)"
    $script:Biblio = Join-Path $script:FakeOneDrive 'Documents\ShaperWaveDynamics documents\biblio'
    $script:Install = Join-Path $TestDrive 'Program Files\ShaperWaveDynamics\ShaperWaveDynamics'
    $script:Manifest = Join-Path $TestDrive 'LocalAppData\swd-extract\trusted_files.json'

    $builder = Join-Path $TestDrive 'build_fake_swd.ps1'
    [IO.File]::WriteAllText($builder, @'
param([Parameter(Mandatory)][string]$Install, [Parameter(Mandatory)][string]$Biblio, [Parameter(Mandatory)][string]$Manifest)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$boards = Join-Path $Biblio 'Boards'
New-Item -ItemType Directory -Force -Path $Install, (Join-Path $boards 'sub') | Out-Null
$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
$src = Join-Path $Install 'fake.cs'
[IO.File]::WriteAllText($src, 'using System; namespace SurfHydrodynamics { [Serializable] public class Fin { public string nom; public double hauteur_mm; public int type_code; public bool actif; [NonSerialized] public double force_n; public Class_surfboard owner; } [Serializable] public class Class_surfboard { public string name; public Fin[] ailerons; } }')
& $csc /nologo /target:library "/out:$(Join-Path $Install 'SurfHydrodynamics.exe')" $src | Out-Null
if ($LASTEXITCODE -ne 0) { throw "csc failed ($LASTEXITCODE)" }
[IO.File]::WriteAllText($src, 'namespace SlimDX { public class Stub { } }')
& $csc /nologo /target:library "/out:$(Join-Path $Install 'SlimDX.dll')" $src | Out-Null
if ($LASTEXITCODE -ne 0) { throw "csc failed ($LASTEXITCODE)" }
Remove-Item -LiteralPath $src
[void][Reflection.Assembly]::LoadFrom((Join-Path $Install 'SurfHydrodynamics.exe'))
$fmt = New-Object Runtime.Serialization.Formatters.Binary.BinaryFormatter
function New-Fin([string]$Nom, [double]$H, [int]$T) {
    $f = New-Object SurfHydrodynamics.Fin
    $f.nom = $Nom; $f.hauteur_mm = $H; $f.type_code = $T; $f.actif = $true; $f.force_n = 99.5
    return $f
}
function Save-Board([string]$Dir, [string]$Name, $Fins, [switch]$NullAilerons) {
    $b = New-Object SurfHydrodynamics.Class_surfboard
    $b.name = $Name
    if (-not $NullAilerons) {
        $arr = [Array]::CreateInstance([SurfHydrodynamics.Fin], @($Fins).Count)
        for ($i = 0; $i -lt @($Fins).Count; $i++) {
            $f = @($Fins)[$i]
            if ($null -ne $f) { $f.owner = $b }
            $arr[$i] = $f
        }
        $b.ailerons = $arr
    }
    $fs = [IO.File]::Create((Join-Path $Dir "$Name.fynbs"))
    try { $fmt.Serialize($fs, $b) } finally { $fs.Dispose() }
}
Save-Board $boards 'board_quad' @((New-Fin 'left, "rear"' 114.3 1), (New-Fin 'right' 114.3 1), (New-Fin 'center' 0.5 2), (New-Fin 'trailer' 88 3))
Save-Board $boards 'board_nofins' $null -NullAilerons
Save-Board $boards 'board_emptyfins' @()
Save-Board $boards 'board_holey' @((New-Fin 'single' 120 1), $null)
Save-Board (Join-Path $boards 'sub') 'board_nested' @((New-Fin 'keel' 150 4))
Save-Board $boards 'board_untrusted' @((New-Fin 'x' 1 1))
[IO.File]::WriteAllBytes((Join-Path $boards 'board_garbage.fynbs'), [byte[]](1..64))
Save-Board $boards 'board_locked' @((New-Fin 'y' 2 2))
$entries = @()
foreach ($f in Get-ChildItem -LiteralPath $boards -Recurse -Filter *.fynbs -File) {
    if ($f.BaseName -eq 'board_untrusted') { continue }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $h = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($f.FullName))).Replace('-', '') } finally { $sha.Dispose() }
    $entries += [ordered]@{ path = $f.FullName.Substring($Biblio.Length).TrimStart('\'); sha256 = $h }
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Manifest) | Out-Null
$doc = [ordered]@{ generated_utc = (Get-Date).ToUniversalTime().ToString('o'); file_count = $entries.Count; files = $entries }
[IO.File]::WriteAllText($Manifest, ($doc | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
'@)
    $bo = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builder -Install $script:Install -Biblio $script:Biblio -Manifest $script:Manifest 2>&1
    if ($LASTEXITCODE -ne 0) { throw "fake SWD build failed: $($bo -join ' ')" }

    function Invoke-ProbeFins {
        <#  Runs the staged copy out of process. Exit code, stdout, stderr.  #>
        param([string]$Biblio = $script:Biblio, [string]$Install = $script:Install, [string]$Manifest = $script:Manifest,
              [string]$WorkDir = $TestDrive)
        foreach ($p in @($Biblio, $Install, $Manifest, $WorkDir)) {
            # A test must never point the probe at the real install or library. A relative
            # manifest is checked against the working directory it will resolve against.
            $full = if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $WorkDir $p }
            $full = $full -replace '^\\\\\?\\', ''
            if (-not [IO.Path]::GetFullPath($full).StartsWith([IO.Path]::GetFullPath($TestDrive), [StringComparison]::OrdinalIgnoreCase)) {
                throw "test path outside TestDrive: $p"
            }
        }
        $id = [guid]::NewGuid().ToString('N')
        $out = Join-Path $TestDrive "pf-$id.out"; $err = Join-Path $TestDrive "pf-$id.err"
        $q = { param($s) '"' + $s + '"' }
        $argv = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (& $q $script:Probe),
                  '-BiblioPath', (& $q $Biblio), '-InstallPath', (& $q $Install), '-TrustManifest', (& $q $Manifest))
        $names = @('OneDriveCommercial', 'OneDriveConsumer', 'OneDrive')
        $saved = @{}; foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
        try {
            # The child inherits these: its OneDrive root is the fake one.
            foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $script:FakeOneDrive) }
            $p = Start-Process -FilePath 'powershell.exe' -Wait -PassThru -NoNewWindow -WorkingDirectory $WorkDir `
                 -RedirectStandardOutput $out -RedirectStandardError $err -ArgumentList $argv
        } finally { foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) } }
        return @{ Exit = $p.ExitCode
                  Out = @(Get-Content -LiteralPath $out)
                  Err = [string](Get-Content -Raw -LiteralPath $err) }
    }
    # The first line of stderr that carries $Needle: the message itself, not PowerShell's
    # own 'At <script path>' position text, which is a separate, pre-existing leak.
    function Get-ErrLine([string]$Err, [string]$Needle) {
        @($Err -split "`r?`n" | Where-Object { $_.Contains($Needle) })[0]
    }
}

Describe 'probe_fins.ps1 against a fake SWD: what it emits' {
    BeforeAll { $script:Run = Invoke-ProbeFins }
    It 'exits 0' { $script:Run.Exit | Should -Be 0 }
    It 'writes the header with every scalar fin field, sorted, and marks a [NonSerialized] one' {
        $script:Run.Out[0] | Should -BeExactly '"board","fin_index","fin_type","actif","force_n [ns]","hauteur_mm","nom","type_code"'
    }
    It 'writes one row per fin, quoting CSV cells, and a [NonSerialized] field reads 0' {
        $script:Run.Out | Should -Contain '"board_quad","0","Fin","True","0","114.3","left, ""rear""","1"'
        $script:Run.Out | Should -Contain '"board_quad","3","Fin","True","0","88","trailer","3"'
        @($script:Run.Out | Where-Object { $_.StartsWith('"board_quad",') }).Count | Should -Be 4
    }
    It 'writes a fins-free row for a null and for an empty fin array, and a null row for a null fin' {
        $script:Run.Out | Should -Contain '"board_nofins","-1","none"'
        $script:Run.Out | Should -Contain '"board_emptyfins","-1","none"'
        $script:Run.Out | Should -Contain '"board_holey","1","null"'
    }
    It 'reads boards in subfolders' { $script:Run.Out | Should -Contain '"board_nested","0","Fin","True","0","150","keel","4"' }
    It 'skips an untrusted board without deserialising it, and says so on stderr' {
        @($script:Run.Out | Where-Object { $_.StartsWith('"board_untrusted",') }).Count | Should -Be 0
        $script:Run.Err | Should -Match 'untrusted, skipped: board_untrusted\.fynbs'
    }
    It 'skips a trusted board that is not a board, and says so' {
        $script:Run.Err | Should -Match 'read failed, skipped: board_garbage\.fynbs'
    }
    It 'names the reference-typed field it did not emit, and never formats it' {
        $script:Run.Err | Should -Match 'reference fields not emitted \(1\): owner'
    }
}

Describe 'probe_fins.ps1 error text names no username or tenant (SQA W4)' {
    It 'a missing library root' {
        $r = Invoke-ProbeFins -Biblio (Join-Path $script:FakeOneDrive 'Documents\missing\biblio')
        $r.Exit | Should -Not -Be 0
        $line = Get-ErrLine $r.Err 'not found'
        $line | Should -Match ([regex]::Escape('~\OneDrive\Documents\missing\biblio'))
        $line | Should -Not -Match $script:Tenant
        $line | Should -Not -Match ([regex]::Escape($env:USERPROFILE))
    }
    It 'a missing install path' {
        $r = Invoke-ProbeFins -Install (Join-Path $script:FakeOneDrive 'no install here')
        $r.Exit | Should -Not -Be 0
        $line = Get-ErrLine $r.Err 'not found'
        $line | Should -Match ([regex]::Escape('~\OneDrive\no install here'))
        $line | Should -Not -Match $script:Tenant
    }
    It 'a library with no Boards folder' {
        $bare = Join-Path $script:FakeOneDrive 'Documents\bare\biblio'
        New-Item -ItemType Directory -Force -Path $bare | Out-Null
        $r = Invoke-ProbeFins -Biblio $bare
        $r.Exit | Should -Not -Be 0
        $line = Get-ErrLine $r.Err 'not found'
        $line | Should -Match ([regex]::Escape('~\OneDrive\Documents\bare\biblio\Boards'))
        $line | Should -Not -Match $script:Tenant
        $line | Should -Not -Match ([regex]::Escape($env:USERPROFILE))
    }
    It 'a board another process holds open is skipped, and its error is redacted' {
        $locked = [IO.File]::Open((Join-Path $script:Biblio 'Boards\board_locked.fynbs'), 'Open', 'Read', 'None')
        try { $r = Invoke-ProbeFins } finally { $locked.Dispose() }
        $r.Exit | Should -Be 0
        $line = Get-ErrLine $r.Err 'board_locked.fynbs'
        $line | Should -Match 'read failed, skipped'
        $line | Should -Match ([regex]::Escape('~\OneDrive\'))
        $line | Should -Not -Match $script:Tenant
        $line | Should -Not -Match ([regex]::Escape($env:USERPROFILE))
    }
}

Describe 'probe_fins.ps1 refuses a trust manifest inside a read-only SWD tree (SQA S14)' {
    # A manifest read from inside the library would let a tampered library vouch for itself.
    BeforeAll {
        function Copy-Manifest([string]$To) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $To) | Out-Null
            Copy-Item -LiteralPath $script:Manifest -Destination $To -Force
            return $To
        }
    }
    It 'refuses one <label>' -ForEach @(
        @{ label = 'inside the library'; where = 'biblio' }
        @{ label = 'in the library''s parent folder'; where = 'docs' }
        @{ label = 'inside the install folder'; where = 'install' }
        @{ label = 'in the install folder''s parent'; where = 'installparent' }
    ) {
        $dir = switch ($where) {
            'biblio' { $script:Biblio }
            'docs' { Split-Path -Parent $script:Biblio }
            'install' { $script:Install }
            'installparent' { Split-Path -Parent $script:Install }
        }
        $m = Copy-Manifest (Join-Path $dir 'trusted_files.json')
        try {
            $r = Invoke-ProbeFins -Manifest $m
            $r.Exit | Should -Not -Be 0
            $line = Get-ErrLine $r.Err 'must not resolve inside a read-only SWD directory'
            $line | Should -Not -BeNullOrEmpty
            $line | Should -Not -Match $script:Tenant
            $line | Should -Not -Match ([regex]::Escape($env:USERPROFILE))
            @($r.Out | Where-Object { $_ -like '"board_*' }).Count | Should -Be 0
        } finally { Remove-Item -LiteralPath $m -Force }
    }
    It 'refuses one reached through a junction into the library (compared canonically)' {
        $j = Join-Path $TestDrive 'LocalAppData\looks-safe'
        New-Item -ItemType Junction -Path $j -Target $script:Biblio | Out-Null
        $m = Copy-Manifest (Join-Path $script:Biblio 'via-junction.json')
        try {
            $r = Invoke-ProbeFins -Manifest (Join-Path $j 'via-junction.json')
            $r.Exit | Should -Not -Be 0
            Get-ErrLine $r.Err 'must not resolve inside a read-only SWD directory' | Should -Not -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $m -Force; [IO.Directory]::Delete($j) }
    }
    It 'refuses one spelled <label>' -ForEach @(
        @{ label = 'as a relative path'; kind = 'relative' }
        @{ label = 'with forward slashes'; kind = 'slash' }
        @{ label = 'with an extended-length prefix'; kind = 'extended' }
    ) {
        $m = Copy-Manifest (Join-Path $script:Biblio 'spelled.json')
        try {
            $r = switch ($kind) {
                'relative' { Invoke-ProbeFins -Manifest 'spelled.json' -WorkDir $script:Biblio }
                'slash' { Invoke-ProbeFins -Manifest $m.Replace('\', '/') }
                'extended' { Invoke-ProbeFins -Manifest ('\\?\' + $m) }
            }
            $r.Exit | Should -Not -Be 0
            $r.Err | Should -Match '(must not resolve inside a read-only SWD directory|Extended-length, device and UNC paths are refused)'
        } finally { Remove-Item -LiteralPath $m -Force }
    }
}

Describe 'probe_fins.ps1 hashes each board with its own hasher (SQA S14)' {
    BeforeAll {
        $errs = $null
        $script:PfAst = [System.Management.Automation.Language.Parser]::ParseFile($script:Probe, [ref]$null, [ref]$errs)
        if ($errs) { throw 'probe_fins.ps1 does not parse' }
    }
    It 'a read that dies mid-stream leaves the next board''s hash correct' {
        $fn = @($script:PfAst.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Get-StreamSha256' }, $true))
        $fn.Count | Should -Be 1
        . ([scriptblock]::Create($fn[0].Extent.Text))
        if (-not ('SqaThrowAfterFirstRead' -as [type])) {
            Add-Type -TypeDefinition @'
using System.IO;
public class SqaThrowAfterFirstRead : MemoryStream {
    int reads;
    public SqaThrowAfterFirstRead(byte[] b) : base(b) { }
    public override int Read(byte[] buffer, int offset, int count) {
        if (reads++ > 0) throw new IOException("device went away mid-read");
        return base.Read(buffer, offset, count);
    }
}
'@
        }
        $bad = New-Object byte[] 20000; (New-Object Random 7).NextBytes($bad)
        $good = [byte[]](1..100)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $expected = [BitConverter]::ToString($sha.ComputeHash($good)).Replace('-', '') } finally { $sha.Dispose() }
        { Get-StreamSha256 -Stream (New-Object SqaThrowAfterFirstRead (, $bad)) } | Should -Throw
        Get-StreamSha256 -Stream (New-Object IO.MemoryStream (, $good)) | Should -BeExactly $expected
    }
    It 'computes no hash anywhere but in that function' {
        $fn = @($script:PfAst.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Get-StreamSha256' }, $true))[0]
        $calls = @($script:PfAst.FindAll({ param($x) $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and "$($x.Member)" -eq 'ComputeHash' }, $true))
        $calls.Count | Should -BeGreaterThan 0
        foreach ($c in $calls) {
            ($c.Extent.StartOffset -gt $fn.Extent.StartOffset -and $c.Extent.EndOffset -lt $fn.Extent.EndOffset) | Should -BeTrue
        }
    }
}
