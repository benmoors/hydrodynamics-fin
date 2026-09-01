#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }
<#
    Pester 6 tests for the pure functions of swd_extract.ps1.

    The functions are lifted out of the REAL script by AST, not copied, so the
    test cannot pass against a stale duplicate. The script is never executed as a
    whole here: it deserialises a 627 MB licensed library and reads
    C:\Program Files, neither of which belongs in a unit test.
#>

BeforeAll {
    # The script runs under Set-StrictMode -Version Latest, so the tests must
    # too - without this the suite passed a build that died on the real run
    # ($null.Count and <string>.Count are terminating only under StrictMode).
    Set-StrictMode -Version Latest

    $script:Target = $env:SWD_EXTRACT_TARGET
    if (-not $script:Target) {
        # tests\ sits beside the script; relative so any clone can run this.
        $script:Target = Join-Path (Split-Path -Parent $PSScriptRoot) 'swd_extract.ps1'
    }
    $src = Get-Content -Raw -LiteralPath $script:Target
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$errs)
    if ($errs) { throw "target does not parse: $($errs[0].Message)" }

    # Dependencies the lifted functions close over.
    $script:BIND = [Reflection.BindingFlags]'Public,NonPublic,Instance'
    $BIND = $script:BIND
    $script:WarnedOnce     = New-Object 'System.Collections.Generic.HashSet[string]'
    $script:DroppedColumns = [ordered]@{}
    $script:WrittenTables  = [ordered]@{}
    $script:PolarBadTokens = 0
    $script:PolarTruncated = 0

    # Top-level Add-Type blocks are lifted as well - Get-CanonicalDirectory is
    # P/Invoke and is useless without the script's own SwdPath.Native definition.
    # Lifted from the target, never re-declared here, so the tests cannot pass
    # against a signature the script does not actually use.
    $addTypes = $ast.FindAll({
        param($x)
        $x -is [System.Management.Automation.Language.CommandAst] -and
        "$($x.GetCommandName())" -eq 'Add-Type'
    }, $false)
    foreach ($a in $addTypes) {
        # a second Add-Type of the same namespace throws; that is expected on a
        # re-run in the same session and is not a test failure
        try { . ([scriptblock]::Create($a.Extent.Text)) }
        catch { Write-Verbose "Add-Type already applied: $($_.Exception.Message)" }
    }

    $fns = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
    foreach ($f in $fns) { . ([scriptblock]::Create($f.Extent.Text)) }
    $script:LiftedNames = @($fns.Name)

    $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ("swdtest-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:Tmp | Out-Null

    function Invoke-SwdExtract {
        <# Run the target out-of-process and hand back exit code + stderr.
           Every argument is quoted: Start-Process -ArgumentList builds a single
           command line, so an unquoted "C:\Program Files" splits and the script
           dies with "A positional parameter cannot be found" long before the guard
           under test ever runs - which reads exactly like a passing refusal. #>
        param([string] $Target, [string] $InstallPath, [string] $BiblioPath, [string] $OutDir,
              [string] $TmpDir, [switch] $SkipElements)
        $err = Join-Path $TmpDir ('run-' + [Guid]::NewGuid().ToString('N') + '.err')
        $out = Join-Path $TmpDir ('run-' + [Guid]::NewGuid().ToString('N') + '.out')
        $q = { param($s) '"' + $s + '"' }
        $argv = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                  '-File', (& $q $Target),
                  '-InstallPath', (& $q $InstallPath),
                  '-BiblioPath',  (& $q $BiblioPath),
                  '-OutDir',      (& $q $OutDir))
        if ($SkipElements) { $argv += '-SkipElements' }
        $p = Start-Process -FilePath 'powershell.exe' -Wait -PassThru -NoNewWindow `
             -RedirectStandardError $err -RedirectStandardOutput $out -ArgumentList $argv
        return @{
            Exit   = $p.ExitCode
            Err    = [string](Get-Content -Raw -LiteralPath $err)
            Stdout = [string](Get-Content -Raw -LiteralPath $out)
        }
    }

    # --- fixture builder: an SWD-shaped profile DB -------------------------
    # Varies the dimensions the parser branches on: block count, indentation
    # (so whitespace text nodes are present or absent), file encoding (BOM and
    # no BOM), decimal form, sign, exponent, and non-ASCII profile names.
    # ponytail: New- is a state-changing verb by PSScriptAnalyzer's rules, so this
    # trips PSUseShouldProcessForStateChangingFunctions. It is a test fixture that
    # writes one file into $script:Tmp and is deleted in AfterAll; SupportsShouldProcess
    # on a fixture would be scaffolding. Suppressed with the reason recorded.
    function New-PolarXml {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        param(
            [int] $Blocks = 6,
            [switch] $Compact,          # no whitespace between elements at all
            [switch] $Bom,
            [string[]] $Names,
            [int] $Points = 3,
            [hashtable] $Override = @{} # per-block element overrides
        )
        $nl = if ($Compact) { '' } else { "`r`n" }
        $ind = if ($Compact) { '' } else { '  ' }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('<?xml version="1.0" standalone="yes"?>' + $nl)
        [void]$sb.Append('<base_profilsDataSet xmlns="http://tempuri.org/base_profilsDataSet.xsd">' + $nl)
        for ($i = 1; $i -le $Blocks; $i++) {
            $nm = if ($Names -and $Names.Count -ge $i) { $Names[$i - 1] } else { "prof$i" }
            $angles = (0..($Points - 1) | ForEach-Object { "$_,5" }) -join ';'
            $cls    = (0..($Points - 1) | ForEach-Object { "0,$($_ + 1)" }) -join ';'
            $cds    = (0..($Points - 1) | ForEach-Object { "0,0$($_ + 1)" }) -join ';'
            $cms    = (0..($Points - 1) | ForEach-Object { "-0,00$($_ + 1)" }) -join ';'
            if ($Override.ContainsKey("angles$i")) { $angles = $Override["angles$i"] }
            if ($Override.ContainsKey("cls$i"))    { $cls    = $Override["cls$i"] }
            if ($Override.ContainsKey("cds$i"))    { $cds    = $Override["cds$i"] }
            [void]$sb.Append("$ind<Table4>$nl")
            [void]$sb.Append("$ind$ind<nom_profil>$nm</nom_profil>$nl")
            [void]$sb.Append("$ind$ind<epaisseur>0,0$i</epaisseur>$nl")
            [void]$sb.Append("$ind$ind<Re>$($i)0000</Re>$nl")
            [void]$sb.Append("$ind$ind<list_angles>$angles</list_angles>$nl")
            [void]$sb.Append("$ind$ind<list_cl>$cls</list_cl>$nl")
            [void]$sb.Append("$ind$ind<list_cd>$cds</list_cd>$nl")
            [void]$sb.Append("$ind$ind<list_cm>$cms</list_cm>$nl")
            [void]$sb.Append("$ind</Table4>$nl")
        }
        [void]$sb.Append('</base_profilsDataSet>' + $nl)
        $p = Join-Path $script:Tmp ("polar-" + [Guid]::NewGuid().ToString('N') + ".xml")
        [IO.File]::WriteAllText($p, $sb.ToString(), (New-Object Text.UTF8Encoding($Bom.IsPresent)))
        return $p
    }

    # --- the two loop shapes, extracted so they can be compared directly ----
    function Read-BlocksOldWay {
        param([string] $Xml, [bool] $IgnoreWhitespace = $true)
        $st = New-Object System.Xml.XmlReaderSettings
        $st.IgnoreWhitespace = $IgnoreWhitespace
        $rd = [System.Xml.XmlReader]::Create($Xml, $st)
        $out = @()
        try {
            while ($rd.ReadToFollowing('Table4')) {
                $node = [xml]$rd.ReadOuterXml()
                $out += [string](Get-XmlText $node.DocumentElement 'Re')
            }
        } finally { $rd.Dispose() }
        return $out
    }
    # NOTE: there is deliberately no local re-implementation of the CURRENT loop.
    # The previous round had one, and it meant every "the new loop is correct"
    # test passed against a copy while the real code was covered only by
    # source-text assertions. Read-PolarDatabase is now called directly.
    # Read-BlocksOldWay stays because it is the DEFECT witness - it has to be a
    # local copy, since the defect no longer exists in the script.
}

AfterAll {
    if ($script:Tmp -and (Test-Path -LiteralPath $script:Tmp)) {
        Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'the script under test' {
    It 'exposes the functions the tests lift' {
        $script:LiftedNames | Should -Contain 'Get-XmlText'
        $script:LiftedNames | Should -Contain 'ConvertTo-DoubleList'
        $script:LiftedNames | Should -Contain 'Get-ConstantZeroColumn'
        $script:LiftedNames | Should -Contain 'Write-CsvNoBom'
        $script:LiftedNames | Should -Contain 'Get-FieldDouble'
    }
    It 'still declares the raw-scan block assertion' {
        $src = Get-Content -Raw -LiteralPath $script:Target
        $src | Should -Match 'fin polar parse incomplete'
    }
    It 'no longer CALLS ReadToFollowing (the comment explaining why may name it)' {
        $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Target, [ref]$null, [ref]$errs)
        $calls = $ast.FindAll({
            param($x)
            $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            "$($x.Member)" -eq 'ReadToFollowing'
        }, $true)
        $calls.Count | Should -Be 0
    }
    It 'does not export shaper_name' {
        $src = Get-Content -Raw -LiteralPath $script:Target
        ([regex]::Matches($src, 'shaper_name')).Count | Should -BeGreaterThan 0   # the header explains why
        $src | Should -Not -Match "shaper_name\s*=\s*\["                          # but no column assignment
    }
}

Describe 'CRITICAL 1 - every Table4 block is parsed (REAL Read-PolarDatabase)' {
    It 'the OLD ReadToFollowing loop drops every second block (the defect)' {
        $xml = New-PolarXml -Blocks 6
        $old = @(Read-BlocksOldWay -Xml $xml -IgnoreWhitespace $true)
        $old.Count | Should -Be 3
        $old | Should -Be @('10000', '30000', '50000')
    }

    It 'the REAL parser returns EVERY block and every row, in file order' {
        $xml = New-PolarXml -Blocks 6 -Points 3
        $r = Read-PolarDatabase -Path $xml
        $r.Blocks   | Should -Be 6
        $r.Expected | Should -Be 6
        @($r.Rows).Count | Should -Be 18
        # the Re sequence proves no block was SKIPPED, which a bare count cannot:
        # the halved version produced 945 well-formed groups and looked healthy.
        $seen = @($r.Rows | ForEach-Object { $_.reynolds } | Select-Object -Unique)
        $seen | Should -Be @(10000, 20000, 30000, 40000, 50000, 60000)
    }

    It 'the REAL parser is correct for <n> blocks (none, one, even, odd, many)' -ForEach @(
        @{ n = 0 }, @{ n = 1 }, @{ n = 2 }, @{ n = 5 }, @{ n = 17 }
    ) {
        $xml = New-PolarXml -Blocks $n
        $r = Read-PolarDatabase -Path $xml
        $r.Blocks | Should -Be $n
        @($r.Rows).Count | Should -Be ($n * 3)
    }

    It 'the REAL parser survives a compact file with no inter-element whitespace' {
        $r = Read-PolarDatabase -Path (New-PolarXml -Blocks 4 -Compact)
        $r.Blocks | Should -Be 4
        @($r.Rows).Count | Should -Be 12
    }

    It 'the REAL parser survives a UTF-8 BOM and non-ASCII profile names' {
        # Each element PARENTHESISED. PowerShell's comma binds tighter than +, so
        # @("aile" + [char]0xE9 + "ron", "na" + ...) is ONE string,
        # "aileeron naif plain" - this fixture silently tested a single mangled
        # name through two review rounds instead of three non-ASCII names.
        $xml = New-PolarXml -Blocks 3 -Bom -Names @(("aile" + [char]0xE9 + "ron"), ("na" + [char]0xEF + "f"), 'plain')
        $r = Read-PolarDatabase -Path $xml
        $r.Blocks | Should -Be 3
        @($r.Rows | ForEach-Object { $_.profile } | Select-Object -Unique).Count | Should -Be 3
        @($r.Rows)[0].profile | Should -Be ("aile" + [char]0xE9 + "ron")
    }

    It 'the REAL parser preserves French-locale values, not just block counts' {
        $r = Read-PolarDatabase -Path (New-PolarXml -Blocks 1 -Points 3)
        $row = @($r.Rows)[0]
        $row.angle_deg | Should -Be 0.5
        $row.cl        | Should -Be 0.1
        $row.cd        | Should -Be 0.01
        $row.cm        | Should -Be -0.001
        $row.thickness | Should -Be 0.01
    }

    It 'the REAL parser THROWS when the parsed count disagrees with the raw scan' {
        # A <Table4> the reader cannot see as an element - it is inside a comment -
        # so the raw scan counts 3 and the parser finds 2. This is the assertion
        # firing on a genuine disagreement, not on a mutated loop.
        $xml = New-PolarXml -Blocks 2
        $text = [IO.File]::ReadAllText($xml)
        $text = $text.Replace('</base_profilsDataSet>', '  <!-- <Table4>ghost</Table4> -->' + "`r`n" + '</base_profilsDataSet>')
        $ghost = Join-Path $script:Tmp ('ghost-' + [Guid]::NewGuid().ToString('N') + '.xml')
        [IO.File]::WriteAllText($ghost, $text, (New-Object Text.UTF8Encoding($false)))
        (Measure-PolarBlockCount -Path $ghost) | Should -Be 3
        { Read-PolarDatabase -Path $ghost } | Should -Throw -ExpectedMessage '*parse incomplete*'
    }

    It 'the raw Table4 scan agrees with the parser on <label>' -ForEach @(
        @{ label = 'indented';  compact = $false; bom = $false; n = 6 }
        @{ label = 'compact';   compact = $true;  bom = $false; n = 6 }
        @{ label = 'bom';       compact = $false; bom = $true;  n = 3 }
        @{ label = 'single';    compact = $false; bom = $false; n = 1 }
    ) {
        $xml = if ($compact -and $bom)      { New-PolarXml -Blocks $n -Compact -Bom }
               elseif ($compact)            { New-PolarXml -Blocks $n -Compact }
               elseif ($bom)                { New-PolarXml -Blocks $n -Bom }
               else                         { New-PolarXml -Blocks $n }
        # the same raw scan the script performs
        $expected = 0
        $rdr = New-Object System.IO.StreamReader($xml)
        try {
            while ($null -ne ($line = $rdr.ReadLine())) {
                $at = 0
                while (($at = $line.IndexOf('<Table4', $at, [StringComparison]::Ordinal)) -ge 0) {
                    $after = if ($at + 7 -lt $line.Length) { $line[$at + 7] } else { [char]0x3E }
                    if ($after -eq [char]0x3E -or $after -eq [char]0x20 -or $after -eq [char]0x09 -or $after -eq [char]0x2F) { $expected++ }
                    $at += 7
                }
            }
        } finally { $rdr.Dispose() }
        $expected | Should -Be $n
        (Measure-PolarBlockCount -Path $xml) | Should -Be $expected
        (Read-PolarDatabase -Path $xml).Blocks | Should -Be $expected
    }
}

Describe 'polar list arrays survive StrictMode at every length' {
    It 'a <label> list still answers .Count and indexes' -ForEach @(
        @{ label = 'empty';        text = '';            n = 0 }
        @{ label = 'single-point'; text = '1,5';         n = 1 }
        @{ label = 'two-point';    text = '1,5;2,5';     n = 2 }
        @{ label = 'many-point';   text = '1;2;3;4;5';   n = 5 }
    ) {
        Set-StrictMode -Version Latest
        # exactly the shape the script uses
        $angles = @(ConvertTo-DoubleList $text)
        $cls    = @(ConvertTo-DoubleList $text)
        $cds    = @(ConvertTo-DoubleList $text)
        $counts = @($angles.Count, $cls.Count, $cds.Count)
        { ($counts | Measure-Object -Minimum).Minimum } | Should -Not -Throw
        ($counts | Measure-Object -Minimum).Minimum | Should -Be $n
        if ($n -gt 0) { $angles[0] | Should -Not -BeNullOrEmpty }
    }
    It 'the UNWRAPPED form is what breaks - one point yields a scalar' {
        Set-StrictMode -Version Latest
        $bare = ConvertTo-DoubleList '1,5'
        $bare -is [array] | Should -BeFalse
        { $bare.Count } | Should -Throw
    }
}

Describe 'Get-XmlText' {
    BeforeAll {
        $xmlText = '<Table4 xmlns="http://tempuri.org/base_profilsDataSet.xsd">' +
                   '<Re>4,5</Re><nom_profil>na' + [char]0xE9 + 'ca</nom_profil></Table4>'
        $script:doc = [xml]$xmlText
    }
    It 'reads a child through a default namespace' {
        Get-XmlText $script:doc.DocumentElement 'Re' | Should -Be '4,5'
    }
    It 'preserves non-ASCII text' {
        Get-XmlText $script:doc.DocumentElement 'nom_profil' | Should -Be ('na' + [char]0xE9 + 'ca')
    }
    It 'returns $null for an absent child rather than throwing under StrictMode' {
        Set-StrictMode -Version Latest
        Get-XmlText $script:doc.DocumentElement 'list_cm' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-DoubleList' {
    It 'parses <text> to <expected>' -ForEach @(
        @{ text = '0,9956;0,0004';      expected = @(0.9956, 0.0004) }
        @{ text = '1;2;3';              expected = @(1.0, 2.0, 3.0) }
        @{ text = '-0,5;+0,5';          expected = @(-0.5, 0.5) }
        @{ text = '1,5E3';              expected = @(1500.0) }
        @{ text = ' 1,5 ; 2,5 ';        expected = @(1.5, 2.5) }
        @{ text = '1,5;;2,5';           expected = @(1.5, 2.5) }
    ) {
        $script:PolarBadTokens = 0
        $r = @(ConvertTo-DoubleList $text)
        $exp = @($expected)
        $r.Count | Should -Be $exp.Count
        for ($i = 0; $i -lt $exp.Count; $i++) { $r[$i] | Should -Be $exp[$i] }
        $script:PolarBadTokens | Should -Be 0
    }
    It 'returns empty for <text>' -ForEach @(
        @{ text = '' }, @{ text = '   ' }, @{ text = $null }
    ) {
        @(ConvertTo-DoubleList $text).Count | Should -Be 0
    }
    It 'COUNTS an unparseable token instead of dropping it silently' {
        $script:PolarBadTokens = 0
        $r = @(ConvertTo-DoubleList '1,0;nan-ish;3,0')
        $r.Count | Should -Be 2
        $script:PolarBadTokens | Should -Be 1
    }
    It 'is not affected by the current culture' {
        $old = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
            (ConvertTo-DoubleList '0,25')[0] | Should -Be 0.25
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
            (ConvertTo-DoubleList '0,25')[0] | Should -Be 0.25
        } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $old }
    }
}

Describe 'CRITICAL 2 / WARNING 2 - constant-zero columns' {
    BeforeEach {
        $script:DroppedColumns = [ordered]@{}
        $script:WrittenTables  = [ordered]@{}
        $script:WarnedOnce = New-Object 'System.Collections.Generic.HashSet[string]'
    }
    It 'names a column that is zero on every row' {
        $rows = 1..5 | ForEach-Object {
            [pscustomobject][ordered]@{ a = [double]$_; fake = 0.0; b = [double](-$_) }
        }
        Get-ConstantZeroColumn -Rows $rows | Should -Be @('fake')
    }
    It 'does NOT name a column with a single non-zero anywhere' -ForEach @(
        @{ pos = 0 }, @{ pos = 2 }, @{ pos = 4 }
    ) {
        $rows = 0..4 | ForEach-Object {
            [pscustomobject][ordered]@{ a = 1.0; nearly = $(if ($_ -eq $pos) { 1e-12 } else { 0.0 }) }
        }
        @(Get-ConstantZeroColumn -Rows $rows) | Should -BeNullOrEmpty
    }
    It 'does NOT name a column that is NaN, which means missing, not zero' {
        $rows = 1..3 | ForEach-Object { [pscustomobject][ordered]@{ a = 1.0; miss = [double]::NaN } }
        @(Get-ConstantZeroColumn -Rows $rows) | Should -BeNullOrEmpty
    }
    It 'a NON-NUMERIC column neither throws nor gets dropped' {
        # closes a surviving mutant: reverting -as [double] to a [double] CAST
        # makes this throw from inside a purely advisory check and abort the run.
        # DateTime is not skipped by the string/bool filter, so it reaches the cast.
        $rows = 1..3 | ForEach-Object {
            [pscustomobject][ordered]@{ when = (Get-Date).AddDays($_); a = 1.0; z = 0.0 }
        }
        # no assignment inside the Should scriptblock - it gets its own scope and
        # the value would never reach the enclosing $drop
        { Get-ConstantZeroColumn -Rows $rows } | Should -Not -Throw
        $drop = @(Get-ConstantZeroColumn -Rows $rows)
        $drop | Should -Be @('z')
        $drop | Should -Not -Contain 'when'
    }
    It 'a non-numeric column does not stop Write-CsvNoBom either' {
        $rows = 1..2 | ForEach-Object { [pscustomobject][ordered]@{ when = (Get-Date); z = 0.0; a = [double]$_ } }
        $p = Join-Path $script:Tmp 'nonnum.csv'
        { Write-CsvNoBom -Rows $rows -Path $p -WarningAction SilentlyContinue | Out-Null } | Should -Not -Throw
        (Get-Content -LiteralPath $p)[0] | Should -Match 'when'
    }
    It 'never names a string or boolean column' {
        $rows = 1..3 | ForEach-Object { [pscustomobject][ordered]@{ s = '0'; f = $false; z = 0.0 } }
        Get-ConstantZeroColumn -Rows $rows | Should -Be @('z')
    }
    It 'honours -Keep for a structural index column' {
        $rows = 1..3 | ForEach-Object { [pscustomobject][ordered]@{ roll_case = 0; z = 0.0 } }
        Get-ConstantZeroColumn -Rows $rows -Keep @('roll_case') | Should -Be @('z')
    }
    It 'returns nothing for an empty row set' {
        (Get-ConstantZeroColumn -Rows @()) | Should -BeNullOrEmpty
    }
    It 'survives StrictMode when exactly <k> column(s) drop' -ForEach @(
        @{ k = 0 }, @{ k = 1 }, @{ k = 2 }
    ) {
        Set-StrictMode -Version Latest
        $rows = 1..4 | ForEach-Object {
            $o = [ordered]@{ real = [double]$_ }
            for ($j = 1; $j -le $k; $j++) { $o["fake$j"] = 0.0 }
            [pscustomobject]$o
        }
        $p = Join-Path $script:Tmp "strict$k.csv"
        { Write-CsvNoBom -Rows $rows -Path $p -WarningAction SilentlyContinue | Out-Null } | Should -Not -Throw
        @($script:DroppedColumns["strict$k.csv"]).Count | Should -Be $k
        (Get-Content -LiteralPath $p)[0] | Should -Be '"real"'
    }
    It 'drops the column from the written CSV and records it' {
        $rows = 1..3 | ForEach-Object { [pscustomobject][ordered]@{ keepme = [double]$_; fake = 0.0 } }
        $p = Join-Path $script:Tmp 'drop.csv'
        Write-CsvNoBom -Rows $rows -Path $p -WarningAction SilentlyContinue | Out-Null
        $head = (Get-Content -LiteralPath $p)[0]
        $head | Should -Be '"keepme"'
        $script:DroppedColumns['drop.csv'] | Should -Be @('fake')
    }
    It 'warns, loudly, when it drops one' {
        $rows = 1..3 | ForEach-Object { [pscustomobject][ordered]@{ a = 1.0; fake = 0.0 } }
        $p = Join-Path $script:Tmp 'warn.csv'
        $w = @()
        Write-CsvNoBom -Rows $rows -Path $p -WarningVariable w -WarningAction SilentlyContinue | Out-Null
        ($w -join ' ') | Should -Match 'fake'
    }
}

Describe 'Write-CsvNoBom output bytes' {
    BeforeEach { $script:DroppedColumns = [ordered]@{}; $script:WrittenTables = [ordered]@{} }
    It 'writes no BOM' {
        $rows = @([pscustomobject]@{ a = 1; b = 2 })
        $p = Join-Path $script:Tmp 'bom.csv'
        Write-CsvNoBom -Rows $rows -Path $p | Out-Null
        $bytes = [IO.File]::ReadAllBytes($p)
        @($bytes[0], $bytes[1], $bytes[2]) | Should -Not -Be @(0xEF, 0xBB, 0xBF)
        $bytes[0] | Should -Be 0x22   # opening quote of the header
    }
    It 'writes CRLF line endings including a trailing one' {
        $rows = 1..3 | ForEach-Object { [pscustomobject]@{ a = $_ } }
        $p = Join-Path $script:Tmp 'crlf.csv'
        Write-CsvNoBom -Rows $rows -Path $p | Out-Null
        $text = [IO.File]::ReadAllText($p)
        $text.EndsWith("`r`n") | Should -BeTrue
        ([regex]::Matches($text, "`r`n")).Count | Should -Be 4      # header + 3 rows
        ([regex]::Matches($text, "(?<!`r)`n")).Count | Should -Be 0 # no bare LF
    }
    It 'is byte-identical to the old -join implementation when nothing is dropped' {
        $rows = 1..20 | ForEach-Object {
            [pscustomobject][ordered]@{
                board = "b,$_"; note = 'has "quotes" and, commas'; v = [double]$_ / 3.0; nan = [double]::NaN
            }
        }
        $new = Join-Path $script:Tmp 'new.csv'
        Write-CsvNoBom -Rows $rows -Path $new | Out-Null
        $old = Join-Path $script:Tmp 'old.csv'
        $csv = ($rows | ConvertTo-Csv -NoTypeInformation) -join "`r`n"
        [IO.File]::WriteAllText($old, $csv + "`r`n", (New-Object Text.UTF8Encoding($false)))
        [IO.File]::ReadAllBytes($new) | Should -Be ([IO.File]::ReadAllBytes($old))
    }
    It 'round-trips non-ASCII as UTF-8' {
        $rows = @([pscustomobject]@{ nom = 'train' + [char]0xE9 + 'e' })
        $p = Join-Path $script:Tmp 'utf8.csv'
        Write-CsvNoBom -Rows $rows -Path $p | Out-Null
        ([IO.File]::ReadAllText($p, [Text.UTF8Encoding]::new($false))) | Should -Match ([char]0xE9)
    }
    It 'warns and writes nothing for an empty row set' {
        $p = Join-Path $script:Tmp 'empty.csv'
        Write-CsvNoBom -Rows @() -Path $p -WarningAction SilentlyContinue | Out-Null
        Test-Path -LiteralPath $p | Should -BeFalse
    }
}

Describe 'WARNING 2 - Get-FieldDouble maps missing and null to NaN' {
    BeforeAll {
        Add-Type -TypeDefinition @'
public class SwdTestProbe {
    public float present = 2.5f;
    public float zero = 0.0f;
    public object nullObj = null;
    public System.Nullable<float> nullNum = null;
}
'@ -ErrorAction SilentlyContinue
        $script:probe = New-Object SwdTestProbe
        $script:probeType = $script:probe.GetType()
    }
    BeforeEach { $script:WarnedOnce = New-Object 'System.Collections.Generic.HashSet[string]' }

    It 'reads a present value' {
        Get-FieldDouble -Object $script:probe -Name 'present' -Type $script:probeType | Should -Be 2.5
    }
    It 'reads a genuine zero as 0, not NaN' {
        $v = Get-FieldDouble -Object $script:probe -Name 'zero' -Type $script:probeType
        [double]::IsNaN($v) | Should -BeFalse
        $v | Should -Be 0.0
    }
    It 'maps an ABSENT field to NaN, not 0' {
        $v = Get-FieldDouble -Object $script:probe -Name 'no_such_field' -Type $script:probeType -WarningAction SilentlyContinue
        [double]::IsNaN($v) | Should -BeTrue
    }
    It 'maps a NULL field to NaN, not 0' -ForEach @(
        @{ f = 'nullObj' }, @{ f = 'nullNum' }
    ) {
        $v = Get-FieldDouble -Object $script:probe -Name $f -Type $script:probeType -WarningAction SilentlyContinue
        [double]::IsNaN($v) | Should -BeTrue
    }
    It 'warns once per distinct message, not once per call' {
        $w = @()
        1..10 | ForEach-Object {
            Get-FieldDouble -Object $script:probe -Name 'no_such_field' -Type $script:probeType -WarningVariable +w -WarningAction SilentlyContinue | Out-Null
        }
        $w.Count | Should -Be 1
    }
    It 'the plain cast it replaced would have produced a fake zero' {
        # documents WHY the helper exists
        [double]$null | Should -Be 0.0
    }
}

Describe 'SUGGESTION - median, not upper-middle quantile' {
    It 'median of <v> is <expected>' -ForEach @(
        @{ v = @(1.0, 2.0, 3.0, 4.0); expected = 2.5 }   # the old code returned 3
        @{ v = @(1.0, 2.0, 3.0);      expected = 2.0 }
        @{ v = @(4.0, 1.0, 3.0, 2.0); expected = 2.5 }   # unsorted input
        @{ v = @(7.0);                expected = 7.0 }
        @{ v = @(2.0, 2.0);           expected = 2.0 }
        @{ v = @(-1.0, 1.0);          expected = 0.0 }
    ) {
        Get-MedianDouble -Values $v | Should -Be $expected
    }
    It 'the OLD expression really did return the upper-middle value' {
        $sorted = @(1.0, 2.0, 3.0, 4.0)
        $sorted[[int][math]::Floor($sorted.Count / 2)] | Should -Be 3.0
    }
    It 'an empty list is NaN, not a throw' {
        $v = Get-MedianDouble -Values @()
        [double]::IsNaN($v) | Should -BeTrue
    }
    It 'a generic List[double] works, which is what the script passes' {
        $l = New-Object System.Collections.Generic.List[double]
        @(3.0, 1.0, 2.0, 4.0) | ForEach-Object { $l.Add($_) }
        Get-MedianDouble -Values $l | Should -Be 2.5
    }
}

Describe 'WARNING 3 - board name from the first segment under rapports_hydro' {
    It 'depth 1 - <full>' -ForEach @(
        @{ full = 'C:\lib\rapports_hydro\Poahaku\r1.fynrhydro'; root = 'C:\lib\rapports_hydro'; expected = 'Poahaku' }
        @{ full = 'C:\lib\rapports_hydro\Mini_Simmons\a.fynrhydro'; root = 'C:\lib\rapports_hydro\'; expected = 'Mini_Simmons' }
    ) {
        Get-BoardNameFromPath -FullName $full -ScanRoot $root | Should -Be $expected
    }
    It 'depth 2 still yields the BOARD, not the intermediate directory' {
        Get-BoardNameFromPath -FullName 'C:\lib\rapports_hydro\Poahaku\2026\r1.fynrhydro' -ScanRoot 'C:\lib\rapports_hydro' |
            Should -Be 'Poahaku'
    }
    It 'the OLD one-level hop returned the intermediate directory at depth 2' {
        Split-Path (Split-Path 'C:\lib\rapports_hydro\Poahaku\2026\r1.fynrhydro' -Parent) -Leaf | Should -Be '2026'
    }
    It 'handles a board name with spaces, an apostrophe and an accent' {
        Get-BoardNameFromPath -FullName ('C:\lib\rapports_hydro\Bruce Iron' + [char]0x27 + 's Gun ' + [char]0xE9 + '\r.fynrhydro') -ScanRoot 'C:\lib\rapports_hydro' |
            Should -Be ('Bruce Iron' + [char]0x27 + 's Gun ' + [char]0xE9)
    }
    It 'handles a root given with .. that normalises' {
        Get-BoardNameFromPath -FullName 'C:\lib\rapports_hydro\X\r.fynrhydro' -ScanRoot 'C:\lib\sub\..\rapports_hydro' | Should -Be 'X'
    }
    It 'falls back rather than throwing when the file is outside the root' {
        Get-BoardNameFromPath -FullName 'D:\elsewhere\Board\r.fynrhydro' -ScanRoot 'C:\lib\rapports_hydro' | Should -Be 'Board'
    }
    It 'a forward-slash path still resolves' {
        Get-BoardNameFromPath -FullName 'C:/lib/rapports_hydro/Poahaku/r1.fynrhydro' -ScanRoot 'C:\lib\rapports_hydro' | Should -Be 'Poahaku'
    }
}

Describe 'WARNING 1 - relative -OutDir anchors to $PWD, not the process directory' {
    It 'GetFullPath alone disagrees with $PWD after Set-Location (the defect)' {
        $here = (Get-Location).ProviderPath
        Push-Location $script:Tmp
        try {
            [IO.Path]::GetFullPath('swdout') | Should -Be (Join-Path $here 'swdout')
        } finally { Pop-Location }
    }
    It 'anchoring to $PWD.ProviderPath first gives the caller-visible location' {
        Push-Location $script:Tmp
        try {
            $o = 'swdout'
            if (-not [IO.Path]::IsPathRooted($o)) { $o = Join-Path $PWD.ProviderPath $o }
            [IO.Path]::GetFullPath($o) | Should -Be (Join-Path ([IO.Path]::GetFullPath($script:Tmp)) 'swdout')
        } finally { Pop-Location }
    }
    It 'containment rejects <out> under <ro>' -ForEach @(
        @{ out = 'C:\Program Files\ShaperWaveDynamics\ShaperWaveDynamics'; ro = 'C:\Program Files\ShaperWaveDynamics\ShaperWaveDynamics'; blocked = $true }
        @{ out = 'C:\Program Files\ShaperWaveDynamics\ShaperWaveDynamics\out'; ro = 'C:\Program Files\ShaperWaveDynamics\ShaperWaveDynamics'; blocked = $true }
        @{ out = 'C:\PROGRAM FILES\SHAPERWAVEDYNAMICS\SHAPERWAVEDYNAMICS\x'; ro = 'C:\Program Files\ShaperWaveDynamics\ShaperWaveDynamics'; blocked = $true }
        @{ out = 'C:\Program Files\ShaperWaveDynamics\ShaperWaveDynamics\..\..\out'; ro = 'C:\Program Files\ShaperWaveDynamics\ShaperWaveDynamics'; blocked = $false }
        @{ out = 'C:\Program Files\ShaperWaveDynamicsOther'; ro = 'C:\Program Files\ShaperWaveDynamics'; blocked = $false }
        @{ out = 'C:\elsewhere'; ro = 'C:\Program Files\ShaperWaveDynamics'; blocked = $false }
    ) {
        $o = [IO.Path]::GetFullPath($out).TrimEnd([char]0x5C)
        $r = [IO.Path]::GetFullPath($ro).TrimEnd([char]0x5C)
        $hit = ($o -eq $r -or $o.StartsWith($r + [char]0x5C, [StringComparison]::OrdinalIgnoreCase))
        $hit | Should -Be $blocked
    }
}

Describe 'WARNING 1 - the REAL script refuses a contained -OutDir' {
    BeforeAll {
        # Sandboxed stand-ins for the install directory and the library, so this
        # exercises the containment branch without going anywhere near
        # C:\Program Files or the real biblio.
        # Nested one level deeper than the sandbox root ON PURPOSE: the guard
        # protects each supplied path AND its parent, mirroring the real layout
        # (Product\Install, Docs\biblio). Putting them directly under $Tmp would
        # protect the whole sandbox and make every case pass for the wrong reason.
        $script:fakeProduct = Join-Path $script:Tmp 'Product'
        $script:fakeDocs    = Join-Path $script:Tmp 'Docs'
        $script:fakeInstall = Join-Path $script:fakeProduct 'Install'
        $script:fakeBiblio  = Join-Path $script:fakeDocs 'biblio'
        New-Item -ItemType Directory -Force -Path $script:fakeInstall, $script:fakeBiblio | Out-Null
    }
    It 'refuses -OutDir <where> and creates nothing' -ForEach @(
        @{ where = 'inside the install dir';   sub = 'Product\Install\out'; preexisting = $false }
        @{ where = 'equal to the install dir'; sub = 'Product\Install';      preexisting = $true }
        @{ where = 'inside the library';       sub = 'Docs\biblio\data';     preexisting = $false }
        @{ where = 'inside the library, wrong case'; sub = 'docs\BIBLIO\DATA'; preexisting = $false }
        # CRITICAL, round 3: the PARENT of each supplied path. $InstallPath
        # defaults to the inner ShaperWaveDynamics\ShaperWaveDynamics and
        # $BiblioPath to biblio\ inside "ShaperWaveDynamics documents\", so the
        # product root and the documents root - which holds swdshare\, fonds\,
        # home boards\ and video\ - were both accepted and written to.
        @{ where = 'the INSTALL PARENT (product root)'; sub = 'Product\out';   preexisting = $false }
        @{ where = 'equal to the install parent';       sub = 'Product';        preexisting = $true }
        @{ where = 'the LIBRARY PARENT (documents root)'; sub = 'Docs\out';     preexisting = $false }
        @{ where = 'equal to the library parent';       sub = 'Docs';           preexisting = $true }
        @{ where = 'a swdshare-shaped sibling of biblio'; sub = 'Docs\swdshare\ctr25'; preexisting = $false }
    ) {
        $out = Join-Path $script:Tmp $sub
        # snapshot BEFORE, because a protected parent legitimately has children
        $before = if (Test-Path -LiteralPath $out) {
            @(Get-ChildItem -LiteralPath $out -Force | ForEach-Object { $_.Name }) | Sort-Object
        } else { $null }
        $r = Invoke-SwdExtract -Target $script:Target -InstallPath $script:fakeInstall `
                               -BiblioPath $script:fakeBiblio -OutDir $out -TmpDir $script:Tmp
        $r.Exit | Should -Not -Be 0
        $r.Err  | Should -Match 'must not resolve inside a read-only SWD directory'
        if ($preexisting) {
            $after = @(Get-ChildItem -LiteralPath $out -Force | ForEach-Object { $_.Name }) | Sort-Object
            ($after -join '|') | Should -Be ($before -join '|')
        } else {
            Test-Path -LiteralPath $out | Should -BeFalse
        }
    }
    It 'accepts an -OutDir that merely SHARES A PREFIX with the install dir' {
        $out = $script:fakeProduct + 'Other'
        $r = Invoke-SwdExtract -Target $script:Target -InstallPath $script:fakeInstall `
                               -BiblioPath $script:fakeBiblio -OutDir $out -TmpDir $script:Tmp
        # It gets past containment and fails later (no SurfHydrodynamics.exe in the
        # fake install), which is exactly the point: containment did not fire.
        $r.Err | Should -Not -Match 'must not resolve inside a read-only SWD directory'
        Test-Path -LiteralPath $out | Should -BeTrue
    }
}

Describe 'WARNING 1 round 3 - containment is CANONICAL, not lexical' {
    BeforeAll {
        $script:cProduct = Join-Path $script:Tmp 'Canon Product'
        $script:cInstall = Join-Path $script:cProduct 'Install'
        $script:cDocs    = Join-Path $script:Tmp 'Canon Docs'
        $script:cBiblio  = Join-Path $script:cDocs 'biblio'
        New-Item -ItemType Directory -Force -Path $script:cInstall, $script:cBiblio | Out-Null
        $script:cJunction = Join-Path $script:Tmp 'jn'
        cmd /c mklink /J "$script:cJunction" "$script:cProduct" | Out-Null
        $fso = New-Object -ComObject Scripting.FileSystemObject
        # "Canon Product" has a space, so it definitely has an 8.3 alias
        $script:cShort = $fso.GetFolder($script:cProduct).ShortPath

        function Invoke-Target {
            param([string] $Out)
            return Invoke-SwdExtract -Target $script:Target -InstallPath $script:cInstall `
                                     -BiblioPath $script:cBiblio -OutDir $Out -TmpDir $script:Tmp
        }
    }
    AfterAll {
        if ($script:cJunction -and (Test-Path -LiteralPath $script:cJunction)) {
            cmd /c rmdir "$script:cJunction" | Out-Null
        }
    }

    It 'the LEXICAL test alone would have accepted <label> (the defect)' -ForEach @(
        @{ label = 'an 8.3 short name' }, @{ label = 'a junction' }
    ) {
        $out = if ($label -eq 'an 8.3 short name') { Join-Path $script:cShort 'out' }
               else { Join-Path $script:cJunction 'out' }
        $root = $script:cInstall.TrimEnd([char]0x5C)
        $lex = [IO.Path]::GetFullPath($out).TrimEnd([char]0x5C)
        ($lex -eq $root -or $lex.StartsWith($root + [char]0x5C, [StringComparison]::OrdinalIgnoreCase)) | Should -BeFalse
    }

    It 'the REAL script refuses <label>' -ForEach @(
        @{ label = 'an 8.3 short name for the install parent' }
        @{ label = 'a junction into the install parent' }
        @{ label = 'an 8.3 short name for the install dir itself' }
    ) {
        $out = switch ($label) {
            'an 8.3 short name for the install parent'    { Join-Path $script:cShort 'out' }
            'a junction into the install parent'          { Join-Path $script:cJunction 'out' }
            'an 8.3 short name for the install dir itself' { Join-Path $script:cShort 'Install\out' }
        }
        $r = Invoke-Target -Out $out
        $r.Exit | Should -Not -Be 0
        $r.Err  | Should -Match 'must not resolve inside a read-only SWD directory'
        Test-Path -LiteralPath $out | Should -BeFalse
    }

    It 'the REAL script refuses <label> outright' -ForEach @(
        @{ label = 'an extended-length path'; out = '\\?\C:\swdout' }
        @{ label = 'a device path';           out = '\\.\C:\swdout' }
        @{ label = 'a UNC path';              out = '\\localhost\C$\swdout' }
    ) {
        $r = Invoke-Target -Out $out
        $r.Exit | Should -Not -Be 0
        $r.Err  | Should -Match 'must be a local drive path'
    }

    It 'a junction that does NOT lead into a protected tree is still accepted' {
        $safe = Join-Path $script:Tmp 'SafeTarget'
        New-Item -ItemType Directory -Force -Path $safe | Out-Null
        $link = Join-Path $script:Tmp 'safejn'
        cmd /c mklink /J "$link" "$safe" | Out-Null
        try {
            $r = Invoke-Target -Out (Join-Path $link 'out')
            $r.Err | Should -Not -Match 'must not resolve inside a read-only SWD directory'
            $r.Err | Should -Not -Match 'must be a local drive path'
        } finally { cmd /c rmdir "$link" | Out-Null }
    }

    It 'Get-ProtectedRoot returns each path AND its parent, never a drive root' {
        $roots = @(Get-ProtectedRoot -Path @('C:\Program Files\SWD\Inner', 'D:\lib\biblio'))
        $roots | Should -Contain 'C:\Program Files\SWD\Inner'
        $roots | Should -Contain 'C:\Program Files\SWD'
        $roots | Should -Contain 'D:\lib\biblio'
        $roots | Should -Contain 'D:\lib'
        $roots | Should -Not -Contain 'C:'
        $roots | Should -Not -Contain 'D:'
    }
    It 'Get-ProtectedRoot on a top-level path does not protect the whole drive' {
        $roots = @(Get-ProtectedRoot -Path @('C:\swd'))
        $roots | Should -Be @('C:\swd')
    }
    It 'Test-PathUnderRoot needs a separator, so a shared prefix is not a hit' {
        Test-PathUnderRoot -Path 'C:\a\SWDOther' -Root @('C:\a\SWD') | Should -BeNullOrEmpty
        Test-PathUnderRoot -Path 'C:\a\SWD\x'   -Root @('C:\a\SWD') | Should -Be 'C:\a\SWD'
        Test-PathUnderRoot -Path 'C:\a\SWD'      -Root @('C:\a\SWD') | Should -Be 'C:\a\SWD'
    }
    It 'Get-CanonicalDirectory resolves an 8.3 name and a junction to one path' {
        $viaShort = Get-CanonicalDirectory -Path $script:cShort
        $viaLink  = Get-CanonicalDirectory -Path $script:cJunction
        $viaReal  = Get-CanonicalDirectory -Path $script:cProduct
        $viaShort | Should -Be $viaReal
        $viaLink  | Should -Be $viaReal
    }
    It 'Resolve-CanonicalTarget handles a path whose nearest existing ancestor is the DRIVE ROOT' {
        # The walk stops at C:\, and PowerShell's Join-Path 'C:' 'a' yields C:\a
        # rather than .NET Path.Combine's drive-relative C:a. Pinned because the
        # difference is invisible until a whole tree under the root is missing.
        Resolve-CanonicalTarget -Path 'C:\nope\deep\tree' | Should -Be 'C:\nope\deep\tree'
        Resolve-CanonicalTarget -Path 'C:\Windows\nope'     | Should -Be 'C:\Windows\nope'
        Resolve-CanonicalTarget -Path 'C:\Windows'            | Should -Be 'C:\Windows'
    }
    It 'Get-ProtectedRoot is insensitive to a trailing separator' {
        $a = @(Get-ProtectedRoot -Path @('C:\x\y'))
        $b = @(Get-ProtectedRoot -Path @('C:\x\y\'))
        ($a -join '|') | Should -Be ($b -join '|')
    }
    It 'Resolve-CanonicalTarget canonicalises a path that does NOT exist yet' {
        $missing = Join-Path $script:cShort 'no\such\dir'
        $r = Resolve-CanonicalTarget -Path $missing
        $r | Should -Not -BeNullOrEmpty
        $r | Should -BeLike '*Canon Product*'
        Test-Path -LiteralPath $missing | Should -BeFalse   # nothing was created
    }
}

Describe 'WARNING 2 round 3 - an empty corpus does not crash under StrictMode' {
    It 'member enumeration on an empty array is the defect' {
        Set-StrictMode -Version Latest
        $empty = @()
        { $empty.board_speed_setting_ms } | Should -Throw
    }
    It 'the piped form the script now uses is safe on <label>' -ForEach @(
        @{ label = 'an empty array';  rows = @() }
        @{ label = 'one row';         rows = @([pscustomobject]@{ board_speed_setting_ms = 5.0 }) }
        @{ label = 'three rows';      rows = @(1..3 | ForEach-Object { [pscustomobject]@{ board_speed_setting_ms = [double]$_ } }) }
    ) {
        Set-StrictMode -Version Latest
        # assigned OUTSIDE the Should scriptblock - a scriptblock gets its own
        # scope, so an assignment inside it never reaches the enclosing $r
        { @($rows | ForEach-Object { $_.board_speed_setting_ms }) } | Should -Not -Throw
        $r = @($rows | ForEach-Object { $_.board_speed_setting_ms } | Sort-Object -Unique)
        $r.Count | Should -Be @($rows).Count
    }
    It 'the REAL script completes on an EMPTY library and writes no sentinel' {
        $emptyDocs = Join-Path $script:Tmp 'EmptyDocs'
        $emptyBib  = Join-Path $emptyDocs 'biblio'
        $out       = Join-Path $script:Tmp 'emptyout'
        New-Item -ItemType Directory -Force -Path (Join-Path $emptyBib 'Boards') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $emptyBib 'rapports_hydro') | Out-Null
        # the assembly still has to load, so the real install path is used for
        # that and ONLY that - it is never written to, and -OutDir is in temp
        $realInstall = 'C:\Program Files\ShaperWaveDynamics\ShaperWaveDynamics'
        if (-not (Test-Path -LiteralPath $realInstall)) { Set-ItResult -Skipped -Because 'SWD is not installed'; return }
        $r = Invoke-SwdExtract -Target $script:Target -InstallPath $realInstall `
                               -BiblioPath $emptyBib -OutDir $out -TmpDir $script:Tmp -SkipElements
        $r.Err | Should -Not -Match 'PropertyNotFoundStrict'
        $r.Err | Should -Not -Match 'cannot be found on this object'
        $r.Exit | Should -Be 0
        # no boards and no reports means no table this run produced, so no sentinel
        Test-Path -LiteralPath (Join-Path $out 'boards.csv') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $out 'operating_points.csv') | Should -BeFalse
    }
}

Describe 'WARNING 3 round 3 - the sentinel only vouches for tables this run wrote' {
    BeforeEach { $script:WrittenTables = [ordered]@{}; $script:DroppedColumns = [ordered]@{} }
    It 'Write-CsvNoBom records what it wrote' {
        $p = Join-Path $script:Tmp 'prov.csv'
        Write-CsvNoBom -Rows @([pscustomobject]@{ a = 1.0 }) -Path $p | Out-Null
        $script:WrittenTables.Contains('prov.csv') | Should -BeTrue
        $script:WrittenTables['prov.csv'].rows | Should -Be 1
    }
    It 'a zero-row table is NOT recorded as written' {
        $p = Join-Path $script:Tmp 'none.csv'
        Write-CsvNoBom -Rows @() -Path $p -WarningAction SilentlyContinue | Out-Null
        $script:WrittenTables.Contains('none.csv') | Should -BeFalse
    }
    It 'the script deletes a table it did not produce, so complete:true cannot cover it' {
        # literal Contains, not hand-written regex: a backtick-dollar inside a
        # single-quoted PowerShell string is a LITERAL backtick, so those
        # patterns could never have matched and the assertion proved nothing
        $src = Get-Content -Raw -LiteralPath $script:Target
        $d = [char]0x24
        $src.Contains("foreach (" + $d + "known in @('boards.csv', 'operating_points.csv', 'elements.csv', 'fin_polars.csv'))") | Should -BeTrue
        $src.Contains($d + "script:WrittenTables.Contains(" + $d + "known)") | Should -BeTrue
        $src.Contains("Remove-Item -LiteralPath " + $d + "stale -Force") | Should -BeTrue
        $src.Contains("tables          = " + $d + "script:WrittenTables") | Should -BeTrue
        # the old shape, which reported rows from variables rather than from what
        # was actually written, must be gone
        $src.Contains("elements         = " + $d + "(if (" + $d + "SkipElements)") | Should -BeFalse
    }
}

Describe 'WARNING 4 round 3 - the manifest carries no identifying data' {
    It 'the manifest builder records no absolute path or tenant field' {
        $src = Get-Content -Raw -LiteralPath $script:Target
        $d = [char]0x24
        # the ASSIGNMENT, not the bare token - the comment explaining the removal
        # legitimately names $PSCommandPath
        $src.Contains("script          = " + $d + "PSCommandPath") | Should -BeFalse
        $src.Contains("biblio          = " + $d + "BiblioPath")  | Should -BeFalse
        $src.Contains("install         = " + $d + "InstallPath") | Should -BeFalse
    }
    It 'no file under SWD/data carries a username or tenant string' {
        # from the runner: the target under test is a staged temp copy, so the
        # data directory cannot be derived by walking up from it
        $dataDir = $env:SWD_DATA_DIR
        if (-not $dataDir) {
            $dataDir = Join-Path (Split-Path -Parent (Split-Path -Parent $script:Target)) 'data'
        }
        if (-not (Test-Path -LiteralPath $dataDir)) { Set-ItResult -Skipped -Because 'no data directory'; return }
        foreach ($f in Get-ChildItem -LiteralPath $dataDir -File) {
            if ($f.Length -gt 5MB) { continue }   # the polar table is numeric only
            $text = Get-Content -Raw -LiteralPath $f.FullName
            $text | Should -Not -Match ([regex]::Escape($env:USERNAME))
            $text | Should -Not -Match 'Monash University'
            $text | Should -Not -Match 'C:..Users'
        }
    }
}

Describe 'structural guards for hunks that live inline in the script' {
    BeforeAll {
        $script:srcText = Get-Content -Raw -LiteralPath $script:Target
    }
    It 'roll min/max are seeded NaN, never +/-Infinity' {
        $script:srcText | Should -Match '\$rollMin = \[double\]::NaN'
        $script:srcText | Should -Not -Match '\$rollMin = \[double\]::PositiveInfinity'
        $script:srcText | Should -Not -Match '\$rollMax = \[double\]::NegativeInfinity'
    }
    It 'the polar loop tests the CURRENT node rather than advancing to find one' {
        $needle = 'if ($reader.NodeType -ne [System.Xml.XmlNodeType]::Element -or $reader.LocalName -ne ''Table4'')'
        $script:srcText.Contains($needle) | Should -BeTrue
    }
    It 'the block-count assertion throws rather than warning' {
        $d = [char]0x24
        $script:srcText.Contains("if (" + $d + "blocks -ne " + $d + "expected) {") | Should -BeTrue
        $script:srcText.Contains('throw "fin polar parse incomplete:') | Should -BeTrue
    }
    # The equality-or-prefix assertion that used to live here is GONE on purpose:
    # that logic moved into Test-PathUnderRoot and is now covered behaviourally
    # ("Test-PathUnderRoot needs a separator, so a shared prefix is not a hit"),
    # which is a stronger check than matching source text.
    It 'CSV output is UTF8 WITHOUT a BOM and CRLF-terminated' {
        $script:srcText | Should -Match 'UTF8Encoding\(\$false\)'
        $script:srcText | Should -Not -Match 'UTF8Encoding\(\$true\)'
    }
}

Describe 'SUGGESTION - roll min/max never leak infinity' {
    It 'an all-NaN case yields NaN, not +/-Infinity' {
        $rollMin = [double]::NaN; $rollMax = [double]::NaN; $rollCount = 0; $rollSum = 0.0
        foreach ($roll in @([double]::NaN, [double]::NaN)) {
            if (-not [double]::IsNaN($roll)) {
                $rollCount++; $rollSum += $roll
                if ([double]::IsNaN($rollMin) -or $roll -lt $rollMin) { $rollMin = $roll }
                if ([double]::IsNaN($rollMax) -or $roll -gt $rollMax) { $rollMax = $roll }
            }
        }
        [double]::IsNaN($rollMin) | Should -BeTrue
        [double]::IsNaN($rollMax) | Should -BeTrue
        [double]::IsInfinity($rollMin) | Should -BeFalse
        $rollCount | Should -Be 0
    }
    It 'the OLD seeding would have written infinity' {
        $rollMin = [double]::PositiveInfinity
        foreach ($roll in @([double]::NaN)) { if ($roll -lt $rollMin) { $rollMin = $roll } }
        [double]::IsPositiveInfinity($rollMin) | Should -BeTrue
    }
    It 'mixed NaN and real values average over the real ones only' {
        $rollMin = [double]::NaN; $rollMax = [double]::NaN; $rollCount = 0; $rollSum = 0.0
        foreach ($roll in @([double]::NaN, 0.5, -0.25, [double]::NaN, 0.75)) {
            if (-not [double]::IsNaN($roll)) {
                $rollCount++; $rollSum += $roll
                if ([double]::IsNaN($rollMin) -or $roll -lt $rollMin) { $rollMin = $roll }
                if ([double]::IsNaN($rollMax) -or $roll -gt $rollMax) { $rollMax = $roll }
            }
        }
        $rollCount | Should -Be 3
        $rollMin | Should -Be -0.25
        $rollMax | Should -Be 0.75
        ($rollSum / $rollCount) | Should -Be (1.0 / 3.0)
    }
}
