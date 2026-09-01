#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }
<#
    Pester 6 tests for the density inference in extract_board.ps1.

    Get-InferredRho and the three constants it reads are LIFTED OUT OF THE REAL
    SCRIPT BY AST, from a hash-checked copy staged into temp - not copied into
    this file - so the test cannot pass against a stale duplicate of the logic or
    against a stale value of V_REF. The script is never executed as a whole: it
    loads SlimDX, deserialises a licensed 627 MB library and reads
    C:\Program Files, none of which belongs in a unit test.

    WHAT THIS FILE EXISTS TO PIN
    ----------------------------
    The pre-2026-08-31 implementation decomposed the measured rho*V against the
    BOARD'S STORED vitesse_flux_relatif_ms - the GUI speed box as it stood when
    the board was last saved, which CLAUDE.md section 6 and swd_extract.ps1:50-52
    both state is NOT the speed the hydroscan ran at. On the 8 of 14 scanned
    boards whose setting is not 20 m/s the density candidate landed between 1578
    and 10230 kg/m^3 - up to 9.95x outside the only table SWD can select from -
    and the unconditional nearest-neighbour snap still returned a confident 1028,
    giving scan_speed_ms = 19.9027 on 3,965 of the corpus's 6,867 elements.

    Get-InferredRhoLEGACY below is that implementation, kept verbatim so the
    defect is demonstrated rather than described. Every case it gets wrong is
    asserted against it as well as against the current function.
#>

BeforeAll {
    # The target runs under Set-StrictMode -Version Latest, so the tests must too:
    # without it a suite happily passes a build that dies on the real run.
    Set-StrictMode -Version Latest

    $live = $env:EXTRACT_BOARD_TARGET
    if (-not $live) {
        # tests\ sits beside the script, so any clone can run this.
        $live = Join-Path (Split-Path -Parent $PSScriptRoot) 'extract_board.ps1'
    }
    if (-not (Test-Path -LiteralPath $live)) { throw "target not found beside tests\: $live" }

    # Staged into temp and hash-checked, the way run_pester.ps1 does it. Nothing
    # here executes the target, but the copy also proves the file on disk parses.
    $script:Stage = Join-Path ([IO.Path]::GetTempPath()) ('eb-stage-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:Stage | Out-Null
    $copy = Join-Path $script:Stage 'extract_board.ps1'
    Copy-Item -LiteralPath $live -Destination $copy
    # Get-FileHash is NOT available in this Windows PowerShell 5.1 host (measured:
    # CommandNotFoundException), so hash through .NET directly.
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hLive = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($live))).Replace('-', '')
        $hCopy = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($copy))).Replace('-', '')
    } finally { $sha.Dispose() }
    if ($hLive -ne $hCopy) { throw "staged copy does not match the live script ($hLive vs $hCopy)" }

    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($copy, [ref]$null, [ref]$errs)
    if ($errs) { throw "target does not parse: $($errs[0].Message)" }

    # The three constants Get-InferredRho closes over, lifted by AST rather than
    # retyped. A test that hardcodes V_REF = 20 would keep passing after someone
    # changed it in the script, which is the one edit that most needs catching.
    $wanted = @('V_REF', 'RHO_TABLE', 'RHO_SNAP_RTOL')
    $assigns = $ast.FindAll({
        param($x)
        $x -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $x.Left -is [System.Management.Automation.Language.VariableExpressionAst]
    }, $false)
    $found = @()
    foreach ($a in $assigns) {
        $n = $a.Left.VariablePath.UserPath
        if ($wanted -contains $n) { . ([scriptblock]::Create($a.Extent.Text)); $found += $n }
    }
    foreach ($w in $wanted) { if ($found -notcontains $w) { throw "constant `$$w not found in the target" } }

    # Promote to script scope: an unqualified read inside the lifted function
    # walks the scope chain, and Pester runs each It in a child scope.
    $script:V_REF         = $V_REF
    $script:RHO_TABLE     = $RHO_TABLE
    $script:RHO_SNAP_RTOL = $RHO_SNAP_RTOL

    # Counters the lifted function writes to.
    $script:RhoSnapMisses = 0
    $script:RhoSnapWorst  = 0.0

    # $SENTINEL_LIMIT and the tally Get-Num writes to.
    $script:SENTINEL_LIMIT = 1e30
    $script:SentinelHits = @{}

    $fns = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
    foreach ($n in @('Get-InferredRho', 'Get-Num', 'Get-RowVal', 'Get-Count', 'Get-ListItem')) {
        $f = $fns | Where-Object { $_.Name -eq $n } | Select-Object -First 1
        if (-not $f) { throw "$n not found in the target" }
        . ([scriptblock]::Create($f.Extent.Text))
    }
    $script:RhoFn = $fns | Where-Object { $_.Name -eq 'Get-InferredRho' } | Select-Object -First 1

    # SENTINEL_LIMIT is lifted too, so the test cannot drift from the script.
    $slAssign = $assigns | Where-Object {
        $_.Left.VariablePath.UserPath -eq 'SENTINEL_LIMIT'
    } | Select-Object -First 1
    if (-not $slAssign) { throw 'constant $SENTINEL_LIMIT not found in the target' }
    . ([scriptblock]::Create($slAssign.Extent.Text))
    $script:SENTINEL_LIMIT = $SENTINEL_LIMIT

    # A real FieldInfo to read through, on a type that is always present.
    Add-Type -TypeDefinition @'
namespace SwdTestFixture {
    public class Holder {
        public double Real;
        public float  Sentinel;
        public object Missing;
        public bool   Flag;
    }
}
'@ -ErrorAction SilentlyContinue
    $script:HolderType = [SwdTestFixture.Holder]
    $script:FiReal     = $script:HolderType.GetField('Real')
    $script:FiSentinel = $script:HolderType.GetField('Sentinel')
    $script:FiMissing  = $script:HolderType.GetField('Missing')
    $script:FiFlag     = $script:HolderType.GetField('Flag')

    # The pre-fix implementation, verbatim. Only the name and $RHO_DEFAULT (a
    # script variable the current file no longer defines) are localised.
    function Get-InferredRhoLEGACY {
        param([double] $RhoV, [double] $VSetting)
        $legacyDefault = 1023.0
        if ([double]::IsNaN($RhoV)) { return [double]::NaN }
        if ([double]::IsNaN($VSetting) -or $VSetting -le 0) { return $legacyDefault }
        $cand = $RhoV / $VSetting
        $best = $legacyDefault; $bestD = [double]::MaxValue
        foreach ($r in $RHO_TABLE) {
            $d = [Math]::Abs($r - $cand)
            if ($d -lt $bestD) { $bestD = $d; $best = $r }
        }
        return $best
    }

    # The two rho*V values the whole 6,867-element corpus takes, and the observed
    # extremes of each group's float spread.
    $script:RHOV_1023      = 20460.0
    $script:RHOV_1025      = 20500.0
    $script:RHOV_1023_LOW  = 20459.892123555655   # worst corpus residual, 5.27e-6 rel
    $script:RHOV_1023_HIGH = 20460.005134531177   # worst on default_shortboard
    $script:RHOV_1025_HIGH = 20500.00544542617

    # Every stored board_speed_setting_ms in the corpus. 20 is the only one that
    # ever made the legacy decomposition right, and it is right by coincidence.
    $script:SETTINGS = @(2.0, 4.0, 5.0, 10.0, 12.9639520645142, 20.0)
}

AfterAll {
    if ($script:Stage -and (Test-Path -LiteralPath $script:Stage)) {
        Remove-Item -LiteralPath $script:Stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-InferredRho: the board speed setting cannot reach it' {

    It 'takes no velocity parameter at all' {
        # Structural, not behavioural: the fix is that the stored setting is not
        # an input. A parameter named VSetting reappearing is the regression.
        $names = @($script:RhoFn.Body.ParamBlock.Parameters |
                   ForEach-Object { $_.Name.VariablePath.UserPath })
        $names | Should -Be @('RhoV')
    }

    It 'decomposes against the fixed V_REF, which is 20.000 m/s' {
        $script:V_REF | Should -Be 20.0
    }

    It 'has exactly the eight densities Form_shaper.actualiser_fluide can select' {
        # salt 0/10/20/30 C, then fresh 0/10/20/30 C.
        @($script:RHO_TABLE) | Should -Be @(1028.0, 1027.0, 1025.0, 1023.0, 999.87, 999.73, 998.23, 995.67)
    }
}

Describe 'Get-InferredRho: the corpus values' {

    It 'snaps rho*V = <rhov> to <expected>' -ForEach @(
        @{ rhov = 20460.0;              expected = 1023.0 }
        @{ rhov = 20500.0;              expected = 1025.0 }
        @{ rhov = 20459.892123555655;   expected = 1023.0 }   # worst corpus residual
        @{ rhov = 20460.005134531177;   expected = 1023.0 }
        @{ rhov = 20500.00544542617;    expected = 1025.0 }
    ) {
        Get-InferredRho -RhoV $rhov | Should -Be $expected
    }

    It 'reproduces scan_speed_ms = 20.000 to better than 1e-5 for rho*V = <rhov>' -ForEach @(
        @{ rhov = 20460.0 }
        @{ rhov = 20500.0 }
        @{ rhov = 20460.005134531177 }   # worst on default_shortboard
        @{ rhov = 20500.00544542617 }
    ) {
        $rho = Get-InferredRho -RhoV $rhov
        [Math]::Abs(($rhov / $rho) - 20.0) | Should -BeLessThan 1e-5
    }

    It 'is worse than 1e-5 on the corpus outlier, and 1.06e-4 is the real bound' {
        # Written down rather than smoothed over. scan_speed_ms is rho*V divided
        # by a snapped density, so it inherits the measurement residual: this one
        # element sits 5.27e-6 off 1023 and lands at 19.99989, not 20.00000. The
        # "20.000 +- 1e-5" figure quoted for default_shortboard is a property of
        # THAT BOARD's 467 rows (worst 5.02e-6), not of every scan SWD produces.
        $rho = Get-InferredRho -RhoV 20459.892123555655
        $rho | Should -Be 1023.0
        $err = [Math]::Abs((20459.892123555655 / $rho) - 20.0)
        $err | Should -BeGreaterThan 1e-5
        $err | Should -BeLessThan 2e-4
    }

    It 'gives the same density whatever the board stored as its speed setting' {
        # The point of the fix, stated as a property: the answer is invariant to
        # a quantity the function can no longer see. The legacy function is
        # asserted alongside to show it was not.
        foreach ($rhov in @(20460.0, 20500.0)) {
            $expected = Get-InferredRho -RhoV $rhov
            foreach ($v in $script:SETTINGS) {
                Get-InferredRho -RhoV $rhov | Should -Be $expected
            }
            # Legacy: correct only at 20, and only because 20 IS the real speed.
            (Get-InferredRhoLEGACY -RhoV $rhov -VSetting 20.0) | Should -Be $expected
        }
    }
}

Describe 'Get-InferredRho: the defect the legacy version shipped' {

    It 'legacy returns an out-of-table 1028 for stored setting <setting>, the fix returns 1023' -ForEach @(
        @{ setting = 2.0;               candidate = 10230.0 }
        @{ setting = 4.0;               candidate = 5115.0 }
        @{ setting = 5.0;               candidate = 4092.0 }
        @{ setting = 10.0;              candidate = 2046.0 }
        @{ setting = 12.9639520645142;  candidate = 1578.2 }
    ) {
        $rhov = 20460.0
        # What the legacy code was actually dividing by, for the record.
        [Math]::Abs(($rhov / $setting) - $candidate) | Should -BeLessThan 0.2

        # It never once refused: every one of these came back as a table value.
        $bad = Get-InferredRhoLEGACY -RhoV $rhov -VSetting $setting
        $bad | Should -Be 1028.0
        [Math]::Abs(($rhov / $bad) - 19.9027) | Should -BeLessThan 1e-3

        # The current function ignores the setting entirely.
        Get-InferredRho -RhoV $rhov | Should -Be 1023.0
    }

    It 'legacy regenerates the phantom 20.0391 m/s when the .fynbs is missing' {
        # Its VSetting fallback pinned rho at 1023 for the 1025 group, and
        # 20500/1023 = 20.0391 exactly - the number the header claims to have
        # eliminated. NaN VSetting is what a missing or untrusted .fynbs produced.
        $bad = Get-InferredRhoLEGACY -RhoV 20500.0 -VSetting ([double]::NaN)
        $bad | Should -Be 1023.0
        [Math]::Abs((20500.0 / $bad) - 20.0391) | Should -BeLessThan 1e-4

        Get-InferredRho -RhoV 20500.0 | Should -Be 1025.0
    }
}

Describe 'Get-InferredRho: it refuses rather than guesses' {

    BeforeEach {
        $script:RhoSnapMisses = 0
        $script:RhoSnapWorst  = 0.0
    }

    It 'returns NaN for an out-of-table rho*V (<label>)' -ForEach @(
        @{ label = 'legacy 2 m/s candidate';  rhov = 10230.0 * 20.0 }
        @{ label = 'legacy 5 m/s candidate';  rhov = 4092.0 * 20.0 }
        @{ label = 'half the real speed';     rhov = 1023.0 * 10.0 }
        @{ label = 'double the real speed';   rhov = 1023.0 * 40.0 }
        @{ label = 'air';                     rhov = 1.225 * 20.0 }
        @{ label = 'negative';                rhov = -20460.0 }
        @{ label = 'zero';                    rhov = 0.0 }
    ) {
        [double]::IsNaN((Get-InferredRho -RhoV $rhov)) | Should -BeTrue
        $script:RhoSnapMisses | Should -Be 1
        $script:RhoSnapWorst | Should -BeGreaterThan $script:RHO_SNAP_RTOL
    }

    It 'passes NaN straight through without counting a miss' {
        [double]::IsNaN((Get-InferredRho -RhoV ([double]::NaN))) | Should -BeTrue
        $script:RhoSnapMisses | Should -Be 0
    }

    It 'accepts a residual just inside the tolerance and refuses one just outside' {
        # Boundary either side of $RHO_SNAP_RTOL, built FROM the lifted constant.
        $inside  = 1023.0 * (1.0 + $script:RHO_SNAP_RTOL * 0.5) * $script:V_REF
        $outside = 1023.0 * (1.0 + $script:RHO_SNAP_RTOL * 2.0) * $script:V_REF
        Get-InferredRho -RhoV $inside | Should -Be 1023.0
        [double]::IsNaN((Get-InferredRho -RhoV $outside)) | Should -BeTrue
        $script:RhoSnapMisses | Should -Be 1
    }

    It 'keeps a dead zone between every adjacent pair of table densities' {
        # If the tolerance reaches half the gap to the neighbour, the entire
        # interval between two entries is accepted and the guard can reject
        # nothing there. Checked against EVERY adjacent pair, not just the salt
        # ones: the binding constraint is the fresh-water 999.87/999.73, which are
        # 1.40e-4 apart - 7x closer than 1028/1027.
        $sorted = @($script:RHO_TABLE | Sort-Object)
        for ($i = 1; $i -lt $sorted.Count; $i++) {
            $gap = ($sorted[$i] - $sorted[$i - 1]) / $sorted[$i - 1]
            $script:RHO_SNAP_RTOL | Should -BeLessThan ($gap / 2.0) -Because "the pair $($sorted[$i-1]) / $($sorted[$i]) is only $gap apart relatively"
        }
    }

    It 'still accepts the worst residual seen anywhere in the corpus' {
        # The floor. 5.27e-6 relative, on one element of the 6,865; a tolerance
        # tightened below it would refuse a genuine measurement.
        Get-InferredRho -RhoV 20459.892123555655 | Should -Be 1023.0
        $script:RhoSnapMisses | Should -Be 0
    }
}

Describe 'Get-Num: a field this build does not have is NaN, never a measurement' {

    BeforeEach { $script:SentinelHits = @{} }

    It 'returns NaN for a $null FieldInfo instead of dereferencing it' {
        # The guard that makes the eight unchecked Type.GetField results safe.
        # Without it this is a null-method call, and because every CSV is written
        # at the very end of the script, one missing field on a different SWD
        # build produced ZERO output files rather than a degraded run.
        [double]::IsNaN((Get-Num ([SwdTestFixture.Holder]::new()) $null)) | Should -BeTrue
    }

    It 'does not count a $null FieldInfo as a sentinel hit' {
        [void](Get-Num ([SwdTestFixture.Holder]::new()) $null)
        $script:SentinelHits.Count | Should -Be 0
    }

    It 'reads a real value through' {
        $h = [SwdTestFixture.Holder]::new(); $h.Real = 20460.5
        Get-Num $h $script:FiReal | Should -Be 20460.5
    }

    It 'maps a null field value to NaN, not to a measured 0' {
        # [double]$null is 0 in PowerShell; that is the fake-zero this exists for.
        $h = [SwdTestFixture.Holder]::new()
        [double]::IsNaN((Get-Num $h $script:FiMissing)) | Should -BeTrue
    }

    It 'maps Single.MaxValue to NaN and counts it' {
        $h = [SwdTestFixture.Holder]::new(); $h.Sentinel = [float]::MaxValue
        [double]::IsNaN((Get-Num $h $script:FiSentinel)) | Should -BeTrue
        $script:SentinelHits['Sentinel'] | Should -Be 1
    }

    It 'converts a bool to 1/0 rather than the strings True/False' {
        $h = [SwdTestFixture.Holder]::new(); $h.Flag = $true
        Get-Num $h $script:FiFlag | Should -Be 1.0
    }

    It 'has a sentinel threshold below Single.MaxValue and above any real value' {
        $script:SENTINEL_LIMIT | Should -BeLessThan ([double][float]::MaxValue)
        # The largest magnitude anywhere in default_shortboard's element table is
        # a wetted length of ~9019 mm, so 1e30 has ~26 orders of headroom.
        $script:SENTINEL_LIMIT | Should -BeGreaterThan 1e6
    }
}

Describe 'Get-RowVal / Get-Count / Get-ListItem: absent is NaN or zero, never invented' {

    It 'Get-RowVal returns NaN for a $null column name (field unresolved)' {
        $row = [ordered]@{ a = 1.0 }
        [double]::IsNaN((Get-RowVal $row $null)) | Should -BeTrue
    }

    It 'Get-RowVal returns NaN for a name the row does not carry' {
        $row = [ordered]@{ a = 1.0 }
        [double]::IsNaN((Get-RowVal $row 'b')) | Should -BeTrue
    }

    It 'Get-RowVal returns the stored value without re-reading the field' {
        $row = [ordered]@{ a = 20460.0 }
        Get-RowVal $row 'a' | Should -Be 20460.0
    }

    It 'Get-Count is 0 for $null and correct for <label>' -ForEach @(
        @{ label = 'an array';     value = @(1, 2, 3);                          expected = 3 }
        @{ label = 'an ArrayList'; value = [Collections.ArrayList]@(1, 2);      expected = 2 }
        @{ label = 'an empty array'; value = @();                              expected = 0 }
    ) {
        Get-Count $value | Should -Be $expected
    }

    It 'Get-Count is 0 for $null' { Get-Count $null | Should -Be 0 }

    It 'Get-ListItem is NaN past the end, at a null entry, and on a null list' {
        [double]::IsNaN((Get-ListItem @(1.0, 2.0) 5)) | Should -BeTrue
        [double]::IsNaN((Get-ListItem @(1.0, $null) 1)) | Should -BeTrue
        [double]::IsNaN((Get-ListItem $null 0)) | Should -BeTrue
        Get-ListItem @(1.0, 2.0) 1 | Should -Be 2.0
    }
}

Describe 'Get-InferredRho: swd_extract.ps1 carries the SAME implementation' {

    # The density decomposition now lives in two scripts. It was COPIED, not
    # re-derived, and this is what stops the copies forking: a change made to one
    # and not the other fails here rather than quietly giving the corpus table
    # and the per-board table two different physics.
    BeforeAll {
        $script:Sibling = Join-Path (Split-Path -Parent $PSScriptRoot) 'swd_extract.ps1'
        $script:SibAst = $null
        if (Test-Path -LiteralPath $script:Sibling) {
            $e = $null
            $script:SibAst = [System.Management.Automation.Language.Parser]::ParseFile($script:Sibling, [ref]$null, [ref]$e)
            if ($e) { throw "swd_extract.ps1 does not parse: $($e[0].Message)" }
        }
    }

    It 'defines Get-InferredRho with identical text' {
        $script:SibAst | Should -Not -BeNullOrEmpty
        $sibFn = $script:SibAst.FindAll({ param($x)
            $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Get-InferredRho'
        }, $false) | Select-Object -First 1
        $sibFn | Should -Not -BeNullOrEmpty
        # Line endings normalised, and that is not a loosened assertion:
        # extract_board.ps1 is CRLF and swd_extract.ps1 is LF, each preserved
        # deliberately, so a raw byte comparison can NEVER pass and would be a
        # test that fails for a reason it does not name. Everything else -
        # indentation, comments, operators - still has to match exactly.
        $norm = { param($t) $t -replace "`r`n", "`n" }
        (& $norm $sibFn.Extent.Text) | Should -Be (& $norm $script:RhoFn.Extent.Text)
    }

    It 'defines the same <name>' -ForEach @(
        @{ name = 'V_REF' }
        @{ name = 'RHO_TABLE' }
        @{ name = 'RHO_SNAP_RTOL' }
    ) {
        $a = $script:SibAst.FindAll({ param($x)
            $x -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $x.Left -is [System.Management.Automation.Language.VariableExpressionAst]
        }, $false) | Where-Object { $_.Left.VariablePath.UserPath -eq $name } | Select-Object -First 1
        $a | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($a.Extent.Text))
        (Get-Variable -Name $name -ValueOnly) | Should -Be (Get-Variable -Name $name -ValueOnly -Scope Script)
    }

    It 'no longer pins a single density anywhere' {
        (Get-Content -Raw -LiteralPath $script:Sibling) | Should -Not -Match 'RHO_SWD'
    }
}

Describe 'Output encoding and the signed-pair gate: pinned against CODE, not prose' {

    # These three mutants all passed a 56/56 suite. None is equivalent; each is a
    # real defect the tests could not see, because the suite only exercised pure
    # functions and never looked at how the files are WRITTEN, or at the gate
    # deciding which rows carry a measurement.
    #
    # Asserted structurally rather than by running the extractors: those
    # deserialise a licensed 627 MB library and read C:\Program Files, which does
    # not belong in a unit test.
    #
    # COMMENTS ARE STRIPPED FIRST, and that is not a detail. The first version of
    # this block regexed the raw file and failed on both counts - it matched the
    # word "Export-Csv" inside a comment explaining why Export-Csv is not used,
    # and it counted "$fa -ne 0" in a comment describing the gate as a second
    # occurrence of the gate. An assertion that reads prose is an assertion that
    # can be satisfied by rewording, which is the opposite of what it is for.
    BeforeAll {
        function Get-CodeOnlyText {
            <# File text with every comment token blanked out, so a regex sees
               only code. Uses the parser's own tokens rather than a $-anything
               heuristic, because '#' appears legitimately inside strings. #>
            param([Parameter(Mandatory)][string] $Path)
            $tokens = $null; $errs = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs)
            if ($errs) { throw "$Path does not parse: $($errs[0].Message)" }
            $sb = New-Object System.Text.StringBuilder (Get-Content -Raw -LiteralPath $Path)
            foreach ($t in $tokens) {
                if ($t.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment) { continue }
                $o = $t.Extent.StartOffset
                for ($i = 0; $i -lt ($t.Extent.EndOffset - $o); $i++) {
                    if ($sb[$o + $i] -ne [char]10 -and $sb[$o + $i] -ne [char]13) { $sb[$o + $i] = ' ' }
                }
            }
            return $sb.ToString()
        }

        $script:Code = @{}
        foreach ($n in @('extract_board.ps1', 'census_board.ps1', 'swd_extract.ps1')) {
            $f = Join-Path (Split-Path -Parent $PSScriptRoot) $n
            if (Test-Path -LiteralPath $f) { $script:Code[$n] = Get-CodeOnlyText -Path $f }
        }
    }

    It 'the comment stripper actually strips: <file> mentions Export-Csv in prose only' -ForEach @(
        @{ file = 'census_board.ps1' }
    ) {
        # Guards the guard. If this ever fails, every assertion below is running
        # against raw text again and proves less than it claims.
        (Get-Content -Raw -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) $file)) | Should -Match 'Export-Csv'
        $script:Code[$file] | Should -Not -Match 'Export-Csv'
    }

    It '<file> writes UTF-8 with NO BOM' -ForEach @(
        @{ file = 'extract_board.ps1' }
        @{ file = 'census_board.ps1' }
        @{ file = 'swd_extract.ps1' }
    ) {
        # UTF8Encoding($true) EMITS a BOM. Every CSV these scripts produce is read
        # by pandas/csv downstream, and CLAUDE.md section 5 records a BOM breaking
        # those readers as an established, already-paid-for defect. The mutant that
        # flipped $false to $true put a BOM on every output file and the whole
        # suite stayed green.
        $c = $script:Code[$file]
        $c | Should -Not -BeNullOrEmpty
        $ctors = [regex]::Matches($c, 'UTF8Encoding\s*\(\s*\$(true|false)\s*\)')
        $ctors.Count | Should -BeGreaterThan 0
        foreach ($m in $ctors) {
            $m.Groups[1].Value | Should -Be 'false' -Because 'UTF8Encoding($true) writes a BOM and the Python readers reject it'
        }
    }

    It '<file> never reaches for a BOM-writing writer by another spelling' -ForEach @(
        @{ file = 'extract_board.ps1' }
        @{ file = 'census_board.ps1' }
        @{ file = 'swd_extract.ps1' }
    ) {
        # Export-Csv -Encoding UTF8 on 5.1 writes a BOM; Out-File writes UTF-16LE.
        # Same defect, different route.
        $script:Code[$file] | Should -Not -Match 'Export-Csv'
        $script:Code[$file] | Should -Not -Match 'Out-File'
    }

    It '<file> gates rho*V on -ne 0, never on -gt 0' -ForEach @(
        @{ file = 'extract_board.ps1'; expected = 2 }
        @{ file = 'swd_extract.ps1';   expected = 1 }
    ) {
        # SWD signs the frontal section and the mass flux TOGETHER by flow
        # direction, so a negative pair divides to a clean +20460. The -gt 0
        # spelling silently discards those rows - 40 sub-element rows on
        # default_shortboard, 57 elements corpus-wide. Both mutants reverting this
        # passed 56/56, because no test ever read a negative-section row.
        $c = $script:Code[$file]
        ([regex]::Matches($c, '\$(sS|S|fa)\s+-ne\s+0')).Count | Should -Be $expected
        ([regex]::Matches($c, '\$(sS|S|fa)\s+-gt\s+0')).Count | Should -Be 0
    }

    It 'the signed-pair gate is reachable: a negative section still yields a table density' {
        # The behavioural half, with the real values from the 40 recovered rows.
        $S = -5.77795e-06; $Q = -0.118217
        $rhoV = $Q / $S
        $rhoV | Should -BeGreaterThan 0
        Get-InferredRho -RhoV $rhoV | Should -Be 1023.0
    }

    It 'RhoSnapWorst is published on a CLEAN run, not left at zero' {
        # snap_worst_rel is the one number that makes V_REF credible, and updating
        # it only inside the miss branch made a clean run report 0.0 - which reads
        # as "perfect" and is exactly wrong.
        $script:RhoSnapMisses = 0
        $script:RhoSnapWorst  = 0.0
        Get-InferredRho -RhoV 20459.892123555655 | Should -Be 1023.0
        $script:RhoSnapMisses | Should -Be 0
        $script:RhoSnapWorst | Should -BeGreaterThan 0.0
        [Math]::Abs($script:RhoSnapWorst - 5.2726e-06) | Should -BeLessThan 1e-9
    }
}

Describe 'Get-InferredRho: the fresh-water half of the table is reachable' {

    It 'snaps fresh-water rho*V = <rho> * V_REF to <rho>' -ForEach @(
        @{ rho = 999.87 }
        @{ rho = 999.73 }
        @{ rho = 998.23 }
        @{ rho = 995.67 }
    ) {
        # 999.87 and 999.73 are 1.4e-4 apart relatively - closer than the salt
        # entries - so this also checks the snap resolves neighbours it must.
        Get-InferredRho -RhoV ($rho * $script:V_REF) | Should -Be $rho
    }

    It 'still separates 999.87 from 999.73 at a realistic measurement residual' {
        $rhov = 999.87 * (1.0 - 1e-6) * $script:V_REF
        Get-InferredRho -RhoV $rhov | Should -Be 999.87
    }
}
