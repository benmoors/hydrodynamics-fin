<#
    Pester 6.x. Runs with SWD CLOSED.

    Everything covered here is the part that decides WHERE to write and WHAT the app
    said back - structural control resolution and label parsing. Those are exactly the
    functions whose failure is silent: a resolver that picks the read-only inches box
    instead of the millimetres box accepts a write, reports success, and applies
    nothing. The live functions that need a running SWD are out of scope by design.

    Control-list fixtures mirror the real shape captured in control-map.csv, including
    the two traps: the Volume EDIT sits two hops below its group inside a NumericUpDown
    container, and each group holds extra DISABLED unit-conversion EDITs.
#>

BeforeAll {
    $script:Phase2 = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:Phase2 'swd_msg.ps1')
    . (Join-Path $script:Phase2 'swd_geometry.ps1')

    # Shape taken from control-map.csv (2026-08-31). Handles are invented; only the
    # structure matters, because the resolver is forbidden from using literal handles.
    function New-Control {
        param($Handle, $Class, $Parent, $Text = '', $Enabled = $true, $Visible = $true)
        [pscustomobject]@{
            Handle = [int64]$Handle; Class = $Class; Parent = [int64]$Parent
            Text = $Text; Enabled = $Enabled; Visible = $Visible
        }
    }

    function New-GeometryFixture {
        param([switch]$NoVolumeGroup, [switch]$DuplicateLengthGroup, [switch]$NoConfiguration)
        $c = @(
            New-Control 100 'WindowsForms10.SysTabControl32.app.0.141b42a_r7_ad1' 0
            New-Control 200 'WindowsForms10.Window.8.app.0.141b42a_r7_ad1' 100 'SizeConfig'

            New-Control 300 'WindowsForms10.Window.8.app.0.141b42a_r7_ad1' 200 'Board Length'
            New-Control 301 'WindowsForms10.EDIT.app.0.141b42a_r7_ad1' 300 '2133.6' $true
            New-Control 302 'WindowsForms10.EDIT.app.0.141b42a_r7_ad1' 300 '7' $false
            New-Control 303 'WindowsForms10.EDIT.app.0.141b42a_r7_ad1' 300 '7.629395E-06' $false
            New-Control 304 'WindowsForms10.BUTTON.app.0.141b42a_r7_ad1' 300 'Apply Length'
            New-Control 305 'WindowsForms10.BUTTON.app.0.141b42a_r7_ad1' 300 "Preserve relative Roker`nConstant shape (homothety)" $false

            New-Control 400 'WindowsForms10.Window.8.app.0.141b42a_r7_ad1' 200 'Board Width'
            New-Control 401 'WindowsForms10.EDIT.app.0.141b42a_r7_ad1' 400 '552.7396' $true
            New-Control 402 'WindowsForms10.EDIT.app.0.141b42a_r7_ad1' 400 '21.7614' $false
            New-Control 403 'WindowsForms10.BUTTON.app.0.141b42a_r7_ad1' 400 'Apply Width'
        )
        if (-not $NoVolumeGroup) {
            $c += New-Control 500 'WindowsForms10.Window.8.app.0.141b42a_r7_ad1' 200 'Board Volume: 26.8 liters'
            # Two hops down, as in the real app.
            $c += New-Control 510 'WindowsForms10.Window.8.app.0.141b42a_r7_ad1' 500 ''
            $c += New-Control 511 'WindowsForms10.EDIT.app.0.141b42a_r7_ad1' 510 '10' $true
            $c += New-Control 512 'WindowsForms10.BUTTON.app.0.141b42a_r7_ad1' 500 'Apply Volume'
        }
        if ($DuplicateLengthGroup) {
            $c += New-Control 600 'WindowsForms10.Window.8.app.0.141b42a_r7_ad1' 200 'Board Length'
        }
        if (-not $NoConfiguration) {
            $c += New-Control 700 'WindowsForms10.STATIC.app.0.141b42a_r7_ad1' 200 $script:RealConfigText
        }
        return $c
    }

    # Verbatim from control-map.csv handle 9179338.
    $script:RealConfigText = @"
Configuration:
Displacement (board+surfer)80.10 Liters,
Volume 26.85 Liters,
Length 2134 mm,
Width 553 mm
Length/Width: 3.9
Thick: 40.3 mm
Width/Thick: 13.7
Length/Thick: 53.0
Length' x Width'' x Thick'':  7'  x  21.8''  x  1.6''
"@
}

Describe 'ConvertFrom-SwdConfigurationText' {

    It 'parses every field of the real label' {
        $p = ConvertFrom-SwdConfigurationText -Text $script:RealConfigText
        $p.VolumeL         | Should -Be 26.85
        $p.DisplacementL   | Should -Be 80.10
        $p.LengthMm        | Should -Be 2134
        $p.WidthMm         | Should -Be 553
        $p.ThickMm         | Should -Be 40.3
        $p.LengthOverWidth | Should -Be 3.9
        $p.WidthOverThick  | Should -Be 13.7
        $p.LengthOverThick | Should -Be 53.0
        $p.Parsed          | Should -Be 8
    }

    It 'agrees with the ratios the extractor derives from board.csv' {
        # The whole geometry recovery rests on these two being the same quantities the
        # binary encodes. Length/Width and Thick/Length are cross-checked here against
        # the panel's own arithmetic.
        $p = ConvertFrom-SwdConfigurationText -Text $script:RealConfigText
        ($p.LengthMm / $p.WidthMm) | Should -BeGreaterThan 3.85
        ($p.LengthMm / $p.WidthMm) | Should -BeLessThan 3.87
        ($p.ThickMm / $p.LengthMm) | Should -BeGreaterThan 0.0188
        ($p.ThickMm / $p.LengthMm) | Should -BeLessThan 0.0189
    }

    It 'leaves an absent field null rather than zero' {
        # A zero would flow into a delta and read as 'this dimension collapsed'.
        $p = ConvertFrom-SwdConfigurationText -Text "Configuration:`nVolume 30.0 Liters,"
        $p.VolumeL  | Should -Be 30.0
        $p.LengthMm | Should -BeNullOrEmpty
        $p.ThickMm  | Should -BeNullOrEmpty
        $p.Parsed   | Should -Be 1
    }

    It 'survives null and empty input without throwing' {
        (ConvertFrom-SwdConfigurationText -Text $null).Parsed | Should -Be 0
        (ConvertFrom-SwdConfigurationText -Text '').Parsed    | Should -Be 0
    }

    It 'does not mistake Length/Width for Length' {
        # 'Length/Width: 3.9' must not satisfy the 'Length <n> mm' pattern.
        $p = ConvertFrom-SwdConfigurationText -Text "Length/Width: 3.9"
        $p.LengthMm        | Should -BeNullOrEmpty
        $p.LengthOverWidth | Should -Be 3.9
    }

    It 'refuses a comma decimal rather than silently truncating it' {
        # SQA W16. The three ratio patterns had no trailing anchor, unlike the five
        # ...mm / ...Liters patterns beside them, so a French-locale render of
        # 'Length/Width: 3,9' parsed as 3 and 'Width/Thick: 13,7' as 13 - with Parsed
        # blind to it, feeding the delta table the docstring calls "the measurement".
        # Not demonstrated on this install (both captures show period decimals), which
        # is why the correct behaviour is to REFUSE, not to guess the locale.
        $p = ConvertFrom-SwdConfigurationText -Text "Length/Width: 3,9`nWidth/Thick: 13,7"
        $p.LengthOverWidth | Should -Not -Be 3
        $p.LengthOverWidth | Should -BeNullOrEmpty
        $p.WidthOverThick  | Should -Not -Be 13
        $p.WidthOverThick  | Should -BeNullOrEmpty
    }

    It 'still parses the real period-decimal ratios' {
        # The anchor must not break the case that actually occurs.
        $p = ConvertFrom-SwdConfigurationText -Text $script:RealConfigText
        $p.LengthOverWidth | Should -Be 3.9
        $p.WidthOverThick  | Should -Be 13.7
        $p.LengthOverThick | Should -Be 53.0
    }

    It 'does not throw on a malformed multi-dot length' {
        # The third site of the bare [double] cast. From the poll loop a throw here is
        # swallowed and misreported as configuration-label-unreadable, conflating
        # "did not answer" with "answered something unparseable".
        { ConvertFrom-SwdConfigurationText -Text "Length 21.3.4 mm" } | Should -Not -Throw
        (ConvertFrom-SwdConfigurationText -Text "Length 21.3.4 mm").LengthMm |
            Should -BeNullOrEmpty
    }
}

Describe 'Resolve-SwdGeometryControl - a hung SWD is not a hidden tab' {

    It 'diagnoses an incomplete control map rather than blaming the tab' {
        # SQA W2. swd_msg.ps1 emits TimedOut/Skipped per row for exactly this, and the
        # resolver never read them - so a mid-scan hung SWD produced "the Shape Room tab
        # must be the visible tab", whose remedy is the WRONG action on a hung app.
        $controls = @(
            [pscustomobject]@{ Handle=1; Class='WindowsForms10.Window.8.app.0.x'; Parent=0
                               Text='something'; Enabled=$true; Visible=$true
                               TimedOut=$true; Skipped=$false }
        )
        { Resolve-SwdGeometryControl -Controls $controls } |
            Should -Throw -ExpectedMessage '*INCOMPLETE*'
    }

    It 'still blames the tab when the map is complete and SizeConfig is absent' {
        $controls = @(
            [pscustomobject]@{ Handle=1; Class='WindowsForms10.Window.8.app.0.x'; Parent=0
                               Text='something'; Enabled=$true; Visible=$true
                               TimedOut=$false; Skipped=$false }
        )
        { Resolve-SwdGeometryControl -Controls $controls } |
            Should -Throw -ExpectedMessage '*SizeConfig*'
    }
}

Describe 'Get-SwdDescendant' {

    It 'reaches a control two hops down' {
        $c = New-GeometryFixture
        $d = Get-SwdDescendant -Controls $c -Handle 500
        ($d | Where-Object Handle -eq 511) | Should -Not -BeNullOrEmpty
    }

    It 'returns every descendant of the panel' {
        $c = New-GeometryFixture
        (Get-SwdDescendant -Controls $c -Handle 200).Count | Should -Be 15
    }

    It 'returns nothing for a leaf' {
        (Get-SwdDescendant -Controls (New-GeometryFixture) -Handle 301).Count | Should -Be 0
    }

    It 'terminates on a cycle instead of hanging' {
        # Enumeration is live, so a malformed parent chain is possible. A hang here
        # would block a batch run with no diagnostic at all.
        $c = @(
            New-Control 1 'X' 2
            New-Control 2 'X' 1
        )
        $d = Get-SwdDescendant -Controls $c -Handle 1
        $d.Count | Should -BeLessOrEqual 2
    }
}

Describe 'Resolve-SwdGeometryControl' {

    It 'resolves all three axes and the Configuration label' {
        $r = Resolve-SwdGeometryControl -Controls (New-GeometryFixture)
        $r.Missing.Count           | Should -Be 0
        $r.Length.Edit             | Should -Be 301
        $r.Length.Apply            | Should -Be 304
        $r.Width.Edit              | Should -Be 401
        $r.Volume.Edit             | Should -Be 511
        $r.ConfigurationHandle     | Should -Be 700
    }

    It 'picks the ENABLED edit, never a read-only unit box' {
        # 302 (feet) and 303 (inches) are disabled. Writing to one would be accepted
        # by WM_SETTEXT and apply nothing - a silent no-op batch.
        $r = Resolve-SwdGeometryControl -Controls (New-GeometryFixture)
        $r.Length.Edit | Should -Be 301
        $r.Length.Edit | Should -Not -Be 302
        $r.Length.Edit | Should -Not -Be 303
    }

    It 'matches the Volume group by prefix, since its caption carries the value' {
        $r = Resolve-SwdGeometryControl -Controls (New-GeometryFixture)
        $r.Volume.Apply | Should -Be 512
    }

    It 'never selects the homothety checkbox as an Apply button' {
        $r = Resolve-SwdGeometryControl -Controls (New-GeometryFixture)
        $r.Length.Apply | Should -Not -Be 305
    }

    It 'reports a missing group instead of silently returning fewer axes' {
        $r = Resolve-SwdGeometryControl -Controls (New-GeometryFixture -NoVolumeGroup)
        $r.Missing.Count | Should -BeGreaterThan 0
        ($r.Missing -join ' ') | Should -BeLike '*Volume group*'
    }

    It 'refuses to guess between duplicate groups' {
        $r = Resolve-SwdGeometryControl -Controls (New-GeometryFixture -DuplicateLengthGroup)
        ($r.Missing -join ' ') | Should -BeLike '*Length group*'
        $r.Length              | Should -BeNullOrEmpty
    }

    It 'reports a missing Configuration label' {
        $r = Resolve-SwdGeometryControl -Controls (New-GeometryFixture -NoConfiguration)
        ($r.Missing -join ' ') | Should -BeLike '*Configuration label*'
    }

    It 'throws when the SizeConfig panel is absent' {
        # The real cause is the Shape Room tab not being the visible tab: controls on a
        # hidden tab are not enumerated at all.
        { Resolve-SwdGeometryControl -Controls @(New-Control 1 'X' 0 'Something') } |
            Should -Throw -ExpectedMessage "*SizeConfig*"
    }
}

Describe 'Set-SwdGeometry parameter contract' {

    It 'rejects an axis outside the three real ones' {
        { Set-SwdGeometry -Axis 'Rocker' -Value 100 -WhatIf } | Should -Throw
    }

    It 'rejects a non-positive value' {
        { Set-SwdGeometry -Axis 'Length' -Value 0 -WhatIf } | Should -Throw -ExpectedMessage '*must be positive*'
    }

    It 'supports -WhatIf, so a rehearsal cannot click for real' {
        (Get-Command Set-SwdGeometry).Parameters.ContainsKey('WhatIf') | Should -BeTrue
    }

    It 'defaults to High confirm impact, because it writes to the library board' {
        $meta = (Get-Command Set-SwdGeometry).ScriptBlock.Ast.Body.ParamBlock.Attributes |
            Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }
        ($meta.NamedArguments | Where-Object ArgumentName -eq 'ConfirmImpact').Argument.Value |
            Should -Be 'High'
    }
}
