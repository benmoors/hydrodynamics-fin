<#
    Pester 6.x. Runs with SWD CLOSED.

    Closes SQA finding 15: Set-SwdGeometry had zero behavioural coverage. The existing
    swd_geometry.Tests.ps1 asserts the parameter contract only, and a mutant replacing
    the whole verdict with `$applied = $true` passed all 21 of them.

    That mattered because of what this function is FOR. The three Apply buttons have
    never been driven against SWD. Set-SwdGeometry exists to find out whether they
    actuate at all, and a function that answers "yes" regardless would settle the
    question wrongly and permanently. So every test here asks one thing: given what the
    application actually did, does the verdict tell the truth about it?

    The whole call graph below Set-SwdGeometry is mocked, because the logic under test
    IS the verdict, not the plumbing. Structural resolution and label parsing are
    covered separately in swd_geometry.Tests.ps1.
#>

BeforeAll {
    $script:Phase2 = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:Phase2 'swd_msg.ps1')
    . (Join-Path $script:Phase2 'swd_geometry.ps1')

    # A geometry snapshot shaped exactly as Get-SwdGeometry returns one.
    function New-State {
        # $Raw is deliberately UNTYPED. A [string] parameter coerces $null to '', which
        # would make this fixture construct "answered empty" while the test claims to
        # construct "did not answer" - the exact distinction under test, and the exact
        # trap the source itself carried at its [AllowNull()][string] annotation.
        param([double]$LengthMm = 2134, [double]$WidthMm = 553, [double]$VolumeL = 26.85,
              [double]$ThickMm = 40.3, $Raw, [switch]$Unparsed)
        if (-not $PSBoundParameters.ContainsKey('Raw')) {
            $Raw = "Configuration:`nVolume $VolumeL Liters,`nLength $LengthMm mm,`nWidth $WidthMm mm`nThick: $ThickMm mm"
        }
        [pscustomobject]@{
            Configuration = [pscustomobject]@{
                VolumeL = if ($Unparsed) { $null } else { $VolumeL }
                DisplacementL = 80.10
                LengthMm = if ($Unparsed) { $null } else { $LengthMm }
                WidthMm = if ($Unparsed) { $null } else { $WidthMm }
                ThickMm = if ($Unparsed) { $null } else { $ThickMm }
                LengthOverWidth = 3.9; WidthOverThick = 13.7; LengthOverThick = 53.0
                Raw = $Raw; Parsed = if ($Unparsed) { 0 } else { 8 }
            }
            Boxes = [pscustomobject]@{ Length = $LengthMm; Width = $WidthMm; Volume = 10 }
            Title = "FYN Shaper Wave Dynamics  <Board: test($LengthMm mm)>"
            TitleLengthMm = $LengthMm; Homothety = 'unknown'; Agree = $true
        }
    }

    function Set-Scenario {
        param($Before, $After, [bool]$WriteOk = $true, [bool]$ClickSent = $true,
              [string]$Observed = 'handled', [int]$LastError = 0)
        Mock Get-SwdControl { @() } -ModuleName $null
        Mock Resolve-SwdGeometryControl {
            [pscustomobject]@{
                Length = [pscustomobject]@{ Group=300; Edit=301; Apply=304; ApplyEnabled=$true; Unit='mm' }
                Width  = [pscustomobject]@{ Group=400; Edit=401; Apply=403; ApplyEnabled=$true; Unit='mm' }
                Volume = [pscustomobject]@{ Group=500; Edit=511; Apply=512; ApplyEnabled=$true; Unit='litres' }
                ConfigurationHandle = 700; Missing = @()
            }
        }
        Mock Get-SwdGeometry { $Before }.GetNewClosure()
        Mock Read-SwdGeometryState { $After }.GetNewClosure()
        Mock Set-SwdNumeric {
            [pscustomobject]@{ Ok=$WriteOk; Reason=if($WriteOk){'ok'}else{'clamped'};
                               Before='2134'; After='2200'; WhatIf=$false }
        }.GetNewClosure()
        Mock Invoke-SwdButton {
            [pscustomobject]@{ Sent=$ClickSent; Observed=$Observed; LastError=$LastError; WhatIf=$false }
        }.GetNewClosure()
        Mock Test-SwdHandle { $true }
    }
}

Describe 'Set-SwdGeometry verdict - the mutant that used to survive' {

    It 'reports Applied when the label actually reaches the target' {
        Set-Scenario -Before (New-State -LengthMm 2134) -After (New-State -LengthMm 2200)
        $r = Set-SwdGeometry -Axis Length -Value 2200 -Confirm:$false -TimeoutMs 1 -PollMs 1
        $r.Applied | Should -BeTrue
        $r.Reason  | Should -Be 'ok'
    }

    It 'does NOT report Applied when nothing moved' {
        # The core defect: the old code read the after-state alone, so a board already
        # near target came back Applied=True for a click that did nothing.
        Set-Scenario -Before (New-State -LengthMm 2134) -After (New-State -LengthMm 2134)
        $r = Set-SwdGeometry -Axis Length -Value 2200 -Confirm:$false -TimeoutMs 1 -PollMs 1
        $r.Applied | Should -BeFalse
        $r.Changed | Should -BeFalse
    }

    It 'distinguishes "already at target" from "it worked"' {
        # A board that starts at the requested value is NO EVIDENCE either way. This is
        # the exact case that would have recorded "Apply Length works" on a first live
        # run, permanently and wrongly.
        Set-Scenario -Before (New-State -LengthMm 2200) -After (New-State -LengthMm 2200)
        $r = Set-SwdGeometry -Axis Length -Value 2200 -Confirm:$false -TimeoutMs 1 -PollMs 1
        $r.Applied | Should -BeFalse
        $r.Reason  | Should -BeLike 'already-at-target*'
    }

    It 'does NOT report Applied when the click was never transported' {
        # Measured pre-fix: Applied=True with ClickSent=False, LastError=5 (UIPI).
        Set-Scenario -Before (New-State -LengthMm 2134) -After (New-State -LengthMm 2134) `
                     -ClickSent $false -Observed 'access-denied' -LastError 5
        $r = Set-SwdGeometry -Axis Length -Value 2200 -Confirm:$false -TimeoutMs 1 -PollMs 1
        $r.Applied        | Should -BeFalse
        $r.ClickSent      | Should -BeFalse
        $r.ClickLastError | Should -Be 5
        $r.Reason         | Should -BeLike 'apply-click-not-transported*'
    }
}

Describe 'Set-SwdGeometry tolerance - absolute, not relative' {

    It 'refuses a move that lands 20 mm short of a 2200 mm target' {
        # THE tolerance mutant. Relative 0.02 on 2200 mm is +/-44 mm, so 2180 would have
        # been accepted as success. Absolute 0.5 mm rejects it. The label prints whole
        # millimetres, so anything looser cannot be falsified by the label at all.
        Set-Scenario -Before (New-State -LengthMm 2134) -After (New-State -LengthMm 2180)
        $r = Set-SwdGeometry -Axis Length -Value 2200 -Confirm:$false -TimeoutMs 1 -PollMs 1
        $r.Applied | Should -BeFalse
        $r.Changed | Should -BeTrue
        $r.Reason  | Should -Be 'changed-but-not-to-target'
    }

    It 'accepts a move inside half the label quantum' {
        Set-Scenario -Before (New-State -LengthMm 2134) -After (New-State -LengthMm 2200.4)
        (Set-SwdGeometry -Axis Length -Value 2200 -Confirm:$false -TimeoutMs 1 -PollMs 1).Applied |
            Should -BeTrue
    }

    It 'uses a tighter absolute tolerance for Volume than for Length' {
        # Litres and millimetres are not interchangeable units and cannot share a number.
        $script:GeometryAxes['Volume'].Tolerance | Should -BeLessThan $script:GeometryAxes['Length'].Tolerance
        $script:GeometryAxes['Volume'].Tolerance | Should -Be 0.005
        $script:GeometryAxes['Length'].Tolerance | Should -Be 0.5
    }

    It 'honours an explicit -Tolerance' {
        Set-Scenario -Before (New-State -LengthMm 2134) -After (New-State -LengthMm 2180)
        (Set-SwdGeometry -Axis Length -Value 2200 -Tolerance 25 -Confirm:$false -TimeoutMs 1 -PollMs 1).Applied |
            Should -BeTrue
    }
}

Describe 'Set-SwdGeometry - a read that failed is never an answer' {

    It 'reports UNKNOWN, not success, when the label cannot be re-read' {
        Set-Scenario -Before (New-State -LengthMm 2134) -After $null
        $r = Set-SwdGeometry -Axis Length -Value 2200 -Confirm:$false -TimeoutMs 1 -PollMs 1
        $r.Applied | Should -BeFalse
        $r.Reason  | Should -BeLike 'configuration-label-unreadable*'
        $r.After   | Should -BeNullOrEmpty
    }

    It 'does not claim "changed" when the BEFORE read failed' {
        # The second surviving mutant. A transient WM_GETTEXT timeout on the before-side
        # makes Raw null, and `$after.Raw -ne $before.Raw` is then trivially true - a
        # positive claim that the board moved, on no evidence whatever.
        Set-Scenario -Before (New-State -Unparsed -Raw $null) -After (New-State -LengthMm 2134)
        $r = Set-SwdGeometry -Axis Length -Value 2200 -Confirm:$false -TimeoutMs 1 -PollMs 1
        $r.Applied | Should -BeFalse
        # THE assertion this test was named for and did not make: without .Changed,
        # deleting the before-side null guard survived all 60 tests and produced
        # Changed=$true beside Reason=configuration-label-unreadable.
        $r.Changed | Should -BeFalse
        $r.Reason  | Should -Not -Be 'ok'
    }

    It 'does not assert the panel is unchanged when the box write failed' {
        # The write may already have committed by then; claiming After = Before would be
        # a positive statement about a panel nobody looked at.
        Set-Scenario -Before (New-State -LengthMm 2134) -After (New-State -LengthMm 2134) -WriteOk $false
        $r = Set-SwdGeometry -Axis Length -Value 2200 -Confirm:$false -TimeoutMs 1 -PollMs 1
        $r.Applied | Should -BeFalse
        $r.Reason  | Should -BeLike 'box-write-*'
    }
}

Describe 'Set-SwdGeometry - domain refusals before anything is written' {

    BeforeEach { Set-Scenario -Before (New-State) -After (New-State) }

    It 'refuses NaN' {
        # `-le 0` alone admits NaN, and ConvertTo-SwdNumber reports Ok=$true for it, so
        # the literal reached WM_SETTEXT and was committed.
        { Set-SwdGeometry -Axis Length -Value ([double]::NaN) -Confirm:$false } | Should -Throw
        Should -Invoke Set-SwdNumeric -Times 0
    }

    It 'refuses positive infinity' {
        { Set-SwdGeometry -Axis Length -Value ([double]::PositiveInfinity) -Confirm:$false } | Should -Throw
        Should -Invoke Set-SwdNumeric -Times 0
    }

    It 'refuses a non-positive value' {
        { Set-SwdGeometry -Axis Length -Value 0 -Confirm:$false } | Should -Throw
        Should -Invoke Set-SwdNumeric -Times 0
    }

    It 'writes nothing under -WhatIf' {
        $r = Set-SwdGeometry -Axis Length -Value 2200 -WhatIf
        $r.Applied | Should -BeFalse
        $r.Reason  | Should -Be 'whatif'
        Should -Invoke Set-SwdNumeric -Times 0
        Should -Invoke Invoke-SwdButton -Times 0
    }
}

Describe 'Set-SwdGeometry - one result shape on every path' {

    It 'emits the same fields whichever way it exits' {
        # StrictMode makes a missing property a terminating error, so a caller reading
        # .ClickLastError on an early-return path would crash rather than see $null.
        $expected = @('Axis','Requested','Tolerance','Applied','Changed','Reason',
                      'Before','After','Deltas','DeltasUnavailable','BoxBefore','BoxAfter',
                      'ClickSent','ClickObserved','ClickLastError','ClickWhatIf','ElapsedMs')
        $paths = @()
        Set-Scenario -Before (New-State -LengthMm 2134) -After (New-State -LengthMm 2200)
        $paths += Set-SwdGeometry -Axis Length -Value 2200 -Confirm:$false -TimeoutMs 1 -PollMs 1
        $paths += Set-SwdGeometry -Axis Length -Value 2200 -WhatIf
        Set-Scenario -Before (New-State) -After $null
        $paths += Set-SwdGeometry -Axis Length -Value 2200 -Confirm:$false -TimeoutMs 1 -PollMs 1
        Set-Scenario -Before (New-State) -After (New-State) -WriteOk $false
        $paths += Set-SwdGeometry -Axis Length -Value 2200 -Confirm:$false -TimeoutMs 1 -PollMs 1

        foreach ($result in $paths) {
            foreach ($field in $expected) {
                $result.PSObject.Properties.Name | Should -Contain $field
            }
        }
    }
}
