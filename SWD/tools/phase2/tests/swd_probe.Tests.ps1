<#
    Pester 6.x, Windows PowerShell 5.1. Runs with SWD CLOSED.

    Covers the parts of swd_probe.ps1 whose failure would be silent or unsafe:
      - the click allowlist and the denylist (a wrong answer here clicks a scan or a delete)
      - the board guard (originals refused)
      - the kill switch, including the left-monitor false positive measured 2026-09-30
      - the MSAA diff, volatility set, library hash and settle decision
      - the native helper against a throwaway in-process WinForms window: MSAA walk
        (checkbox state on a FlatStyle=Standard CheckBox, the case BM_GETCHECK is blind to),
        frame hashing with ignore rectangles, tab switching by MSAA default action.
    The live probes (T9-T14) need SWD and are exercised by running the script itself.
#>

BeforeAll {
    $script:Phase2 = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:Phase2 'swd_probe.ps1')
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
}

Describe 'click allowlist and denylist' {
    It 'allows exactly the allowlisted captions: <_>' -ForEach @('Apply Length', 'Apply Width', 'Apply Volume', 'Apply situation', '&Apply Length', '  Apply Length  ') {
        Test-SwdProbeAllowedButton $_ | Should -BeTrue
    }
    It 'refuses real SWD captions that must never be clicked: <_>' -ForEach @(
        'Hydrodynamics Scanner', 'No HydroScan', 'Delete hydroscan', 'UnLock', 'Share blueTreck_Copy_4 on SurfCommunity',
        'Reset', 'Creer un sous-dossier', 'Rename', 'Delete', 'Create', 'Save project', 'Export Board STL', 'CNC', 'Button6', 'Edit Rail') {
        Test-SwdProbeAllowedButton $_ | Should -BeFalse
    }
    It 'refuses near-misses: <_>' -ForEach @('apply length', 'Apply Length and Save', 'Apply Length (export)', 'Apply', 'ApplyLength') {
        Test-SwdProbeAllowedButton $_ | Should -BeFalse
    }
    It 'refuses null and empty' {
        Test-SwdProbeAllowedButton $null | Should -BeFalse
        Test-SwdProbeAllowedButton '' | Should -BeFalse
    }
    It 'denylist wins even if the allowlist is widened' {
        $saved = $script:ProbeAllowedButtons
        try {
            $script:ProbeAllowedButtons = @($saved) + 'Hydrodynamics Scanner'
            Test-SwdProbeAllowedButton 'Hydrodynamics Scanner' | Should -BeFalse
        } finally { $script:ProbeAllowedButtons = $saved }
    }
    It 'Assert-SwdProbeButton re-reads the caption and returns the normalised label' {
        Assert-SwdProbeButton -Handle 42 -TextReader { param($h) '&Apply Length' } | Should -Be 'Apply Length'
    }
    It 'Assert-SwdProbeButton throws on a denied caption' {
        { Assert-SwdProbeButton -Handle 42 -TextReader { param($h) 'Hydrodynamics Scanner' } } | Should -Throw '*not on the probe allowlist*'
    }
    It 'Assert-SwdProbeButton throws when the caption cannot be read' {
        { Assert-SwdProbeButton -Handle 42 -TextReader { param($h) $null } } | Should -Throw
    }
}

Describe 'tab allowlist' {
    It 'allows <_>' -ForEach @('Shape', 'Fins', 'SizeConfig', 'Rockers') { Test-SwdProbeAllowedTab $_ | Should -BeTrue }
    It 'refuses <_>' -ForEach @('SurfCommunity(Off)', 'CNC', 'Wave Room', 'Shaper;Report', 'Warnings(2)', '', $null) { Test-SwdProbeAllowedTab $_ | Should -BeFalse }
    It 'normalises MSAA line breaks before matching' { ConvertTo-SwdProbeLabel 'Board;Aspect' | Should -Be 'Board Aspect' }
}

Describe 'board guard' {
    It 'reads the board from the real caption' {
        Get-SwdProbeBoardName 'FYN Shaper Wave Dynamics   <Board: blueTreck_Copy_4(2133.6mm)> <no Wave> <Surfer: Surfer Pro(80Kg)>' | Should -Be 'blueTreck_Copy_4'
    }
    It 'accepts a copy' {
        Assert-SwdProbeBoard 'FYN Shaper Wave Dynamics   <Board: blueTreck_Copy_4(2133.6mm)> <no Wave>' | Should -Be 'blueTreck_Copy_4'
    }
    It 'refuses an original' {
        { Assert-SwdProbeBoard 'FYN Shaper Wave Dynamics   <Board: default_fish(2134mm)> <no Wave>' } | Should -Throw '*not a copy*'
    }
    It 'refuses an unreadable caption' {
        { Assert-SwdProbeBoard 'Starting HydroScan' } | Should -Throw '*Cannot read the loaded board*'
        { Assert-SwdProbeBoard $null } | Should -Throw
    }
}

Describe 'kill switch' {
    BeforeEach { $script:Stop = Join-Path $TestDrive 'STOP' ; if (Test-Path $script:Stop) { Remove-Item $script:Stop } }
    It 'stops on a stop file' {
        New-Item -ItemType File -Path $script:Stop | Out-Null
        Test-SwdProbeStop -StopFile $script:Stop -CursorReader { $null } | Should -BeLike 'stop file present*'
    }
    It 'stops with the cursor in the primary top-left corner' {
        Test-SwdProbeStop -StopFile $script:Stop -CursorReader { , @(1, 0) } | Should -BeLike '*corner*'
    }
    It 'does NOT stop on the top edge of a monitor left of the primary (measured regression)' {
        Test-SwdProbeStop -StopFile $script:Stop -CursorReader { , @(-1920, 127) } | Should -BeNullOrEmpty
        Test-SwdProbeStop -StopFile $script:Stop -CursorReader { , @(-1500, 0) } | Should -BeNullOrEmpty
    }
    It 'does not stop elsewhere or when the cursor is unreadable' {
        Test-SwdProbeStop -StopFile $script:Stop -CursorReader { , @(500, 400) } | Should -BeNullOrEmpty
        Test-SwdProbeStop -StopFile $script:Stop -CursorReader { $null } | Should -BeNullOrEmpty
    }
    It 'Assert-SwdProbeContinue throws the recognisable stop message' {
        New-Item -ItemType File -Path $script:Stop | Out-Null
        { Assert-SwdProbeContinue -StopFile $script:Stop -CursorReader { $null } } | Should -Throw 'SWD-PROBE-STOPPED:*'
    }
    It 'T17: a stop file appearing during step 3 stops the loop before step 4' {
        $stop = $script:Stop
        $r = Invoke-SwdProbeStopLoop -StopFile $stop -Iterations 10 -Step { param($i) if ($i -eq 2) { New-Item -ItemType File -Path $stop -Force | Out-Null } }
        $r.Stopped | Should -BeTrue
        $r.Completed | Should -Be 3
    }
    It 'runs to completion with no stop signal' {
        $r = Invoke-SwdProbeStopLoop -StopFile $script:Stop -Iterations 4 -Step { param($i) }
        $r.Completed | Should -Be 4
        $r.Stopped | Should -BeFalse
    }
    It 'rethrows a real error instead of reporting it as a stop' {
        { Invoke-SwdProbeStopLoop -StopFile $script:Stop -Iterations 3 -Step { param($i) throw 'boom' } } | Should -Throw 'boom'
    }
    It 'Invoke-SwdProbeT17 passes end to end' {
        (Invoke-SwdProbeT17 -RunDir $TestDrive).Pass | Should -BeTrue
        Test-Path (Join-Path $TestDrive 'STOP-t17-test') | Should -BeFalse
    }
}

Describe 'rectangles' {
    It 'converts a map rect to window-relative x,y,w,h' {
        $r = ConvertFrom-SwdMapRect -Rect '0,23,1829,1069' -OriginX -8 -OriginY -8
        $r.Count | Should -Be 4
        ($r -join ',') | Should -Be '8,31,1829,1046'
    }
    It 'rejects a malformed rect' { { ConvertFrom-SwdMapRect -Rect '1,2,3' } | Should -Throw }
}

Describe 'MSAA diff' {
    BeforeAll {
        function N($Path, $Role, $Name, $Value = $null, $State = 0) { [pscustomobject]@{ Path = $Path; Role = $Role; Name = $Name; Value = $Value; State = $State } }
        $script:Base = @((N '0' '10' 'client'), (N '0/1' '42' 'Board Length' '2133.6'), (N '0/2' '44' 'homothety' $null 16), (N '0/3' '41' 'Cpu:22%'))
    }
    It 'identical walks give no changes' { @(Compare-SwdMsaa -Before $script:Base -After $script:Base).Count | Should -Be 0 }
    It 'detects a value change' {
        $after = @($script:Base[0], (N '0/1' '42' 'Board Length' '2134.6'), $script:Base[2], $script:Base[3])
        $d = @(Compare-SwdMsaa -Before $script:Base -After $after)
        $d.Count | Should -Be 1
        $d[0].Field | Should -Be 'Value'
        $d[0].To | Should -Be '2134.6'
    }
    It 'detects a checkbox state change' {
        $after = @($script:Base[0], $script:Base[1], (N '0/2' '44' 'homothety' $null 0), $script:Base[3])
        (@(Compare-SwdMsaa -Before $script:Base -After $after))[0].Field | Should -Be 'State'
    }
    It 'treats null versus empty as a change' {
        $after = @($script:Base[0], (N '0/1' '42' 'Board Length' ''), $script:Base[2], $script:Base[3])
        $b2 = @($script:Base[0], (N '0/1' '42' 'Board Length' $null), $script:Base[2], $script:Base[3])
        @(Compare-SwdMsaa -Before $b2 -After $after).Count | Should -Be 1
    }
    It 'reports appeared and vanished nodes' {
        $after = @($script:Base[0], $script:Base[1], $script:Base[3], (N '0/4' '37' 'Fins'))
        $d = @(Compare-SwdMsaa -Before $script:Base -After $after)
        ($d.Kind | Sort-Object) -join ',' | Should -Be 'APPEARED,VANISHED'
    }
    It 'skips status-bar noise even with SWD''s leading space (live T9 regression)' {
        $b = @((N '0/3' '41' ' Cpu:36%'), (N '0/4' '41' ' Available RAM: 4178 Mo (Ok)'))
        $a = @((N '0/3' '41' ' Cpu:13%'), (N '0/4' '41' ' Available RAM: 4188 Mo (Ok)'))
        @(Compare-SwdMsaa -Before $b -After $a).Count | Should -Be 0
    }
    It 'skips status-bar noise by name' {
        $after = @($script:Base[0], $script:Base[1], $script:Base[2], (N '0/3' '41' 'Cpu:9%'))
        @(Compare-SwdMsaa -Before $script:Base -After $after).Count | Should -Be 0
    }
    It 'a volatility set learned from a null action suppresses exactly those keys' {
        $after = @($script:Base[0], (N '0/1' '42' 'Board Length' '2134.6'), $script:Base[2], $script:Base[3])
        $d = @(Compare-SwdMsaa -Before $script:Base -After $after)
        $ig = Get-SwdProbeVolatility -MsaaDiff $d -Win32Diff @()
        @(Compare-SwdMsaa -Before $script:Base -After $after -Ignore $ig).Count | Should -Be 0
        $after2 = @($script:Base[0], $script:Base[1], (N '0/2' '44' 'homothety' $null 0), $script:Base[3])
        @(Compare-SwdMsaa -Before $script:Base -After $after2 -Ignore $ig).Count | Should -Be 1
    }
}

Describe 'snapshot diff (offline, no image)' {
    BeforeAll {
        function C($h, $t, $p = 1) { [pscustomobject]@{ Handle = [int64]$h; Class = 'WindowsForms10.EDIT'; CtrlId = 0; Visible = $true; Enabled = $true; Rect = '0,0,10,10'; Parent = [int64]$p; Text = $t; TimedOut = $false; Skipped = $false; LastError = 0 } }
        function M($path, $name, $value) { [pscustomobject]@{ Path = $path; Role = '42'; Name = $name; Value = $value; State = 0 } }
        $script:SnapA = [pscustomobject]@{ Controls = @((C 10 '2133.6'), (C 11 '680.5888')); Msaa = @((M '0/1' 'len' '2133.6')); Image = $null }
    }
    It 'identical snapshots give zero changes and zero image boxes (live T9 regression)' {
        $d = Compare-SwdProbeSnapshot -Before $script:SnapA -After $script:SnapA
        $d.OutOfScopeCount | Should -Be 0
        @($d.OutOfScope.ImageBoxes).Count | Should -Be 0
    }
    It 'classifies an expected handle as in scope and another as out of scope' {
        $after = [pscustomobject]@{ Controls = @((C 10 '2134.6'), (C 11 '681.0')); Msaa = @((M '0/1' 'len' '2134.6')); Image = $null }
        $d = Compare-SwdProbeSnapshot -Before $script:SnapA -After $after -ExpectHandles @(10) -ExpectValues @('2133.6', '2134.6')
        @($d.OutOfScope.Win32 | ForEach-Object { $_.Handle }) | Should -Be @(11)
        $d.InScopeCount | Should -Be 2
        @($d.OutOfScope.Msaa).Count | Should -Be 0
    }
    It 'a control that appears HIDDEN is structure, not an out-of-scope effect' {
        $b = [pscustomobject]@{ Controls = @((C 10 'x')); Msaa = @(); Image = $null }
        $hid = C 30 'Fin Base type'; $hid.Visible = $false
        $a = [pscustomobject]@{ Controls = @((C 10 'x'), $hid); Msaa = @(); Image = $null }
        $d = Compare-SwdProbeSnapshot -Before $b -After $a
        $d.OutOfScopeCount | Should -Be 0
        $d.HiddenStructural | Should -Be 1
    }
    It 'a control that appears VISIBLE is out of scope' {
        $b = [pscustomobject]@{ Controls = @((C 10 'x')); Msaa = @(); Image = $null }
        $a = [pscustomobject]@{ Controls = @((C 10 'x'), (C 31 'Warning dialog')); Msaa = @(); Image = $null }
        (Compare-SwdProbeSnapshot -Before $b -After $a).OutOfScopeCount | Should -Be 1
    }
    It 'a value change on a hidden control still counts' {
        $hb = C 32 '680.5888'; $hb.Visible = $false; $ha = C 32 '681.0'; $ha.Visible = $false
        $b = [pscustomobject]@{ Controls = @($hb); Msaa = @(); Image = $null }
        $a = [pscustomobject]@{ Controls = @($ha); Msaa = @(); Image = $null }
        (Compare-SwdProbeSnapshot -Before $b -After $a).OutOfScopeCount | Should -Be 1
    }
    It 'a child of an expected handle is in scope' {
        $b = [pscustomobject]@{ Controls = @((C 10 'x'), (C 20 'a' 10)); Msaa = @(); Image = $null }
        $a = [pscustomobject]@{ Controls = @((C 10 'x'), (C 20 'b' 10)); Msaa = @(); Image = $null }
        (Compare-SwdProbeSnapshot -Before $b -After $a -ExpectHandles @(10)).OutOfScopeCount | Should -Be 0
    }
}

Describe 'expected handles for an Apply (live T12 regression)' {
    BeforeAll {
        function K($h, $p, $t = '') { [pscustomobject]@{ Handle = [int64]$h; Parent = [int64]$p; Class = 'WindowsForms10.Window.8'; Text = $t } }
        # Shape of the SizeConfig panel: Length group with an EDIT and a nested container.
        $script:Ctl = @((K 200 100 'SizeConfig'), (K 300 200 'Board Length'), (K 301 300 '2133.6'), (K 304 300 'Apply Length'), (K 310 300), (K 311 310 '7'), (K 400 200 'Board Width'))
    }
    It 'returns the group and every descendant, as int64' {
        $h = Get-SwdProbeExpectHandle -Controls $script:Ctl -Group 300
        ($h | Sort-Object) -join ',' | Should -Be '300,301,304,310,311'
        $h[0].GetType().Name | Should -Be 'Int64'
    }
    It 'returns just the group for a leaf' {
        $h = Get-SwdProbeExpectHandle -Controls $script:Ctl -Group 400
        @($h).Count | Should -Be 1
        $h[0] | Should -Be 400
    }
    It 'does not leak a sibling group' {
        (Get-SwdProbeExpectHandle -Controls $script:Ctl -Group 300) -contains 400 | Should -BeFalse
    }
}

Describe 'geometry delta access (live T12 regression)' {
    It 'reads a field from an ordered dictionary, as Set-SwdGeometry returns' {
        $d = [ordered]@{ LengthMm = 1; VolumeL = 0.06 }
        Get-SwdProbeDelta -Deltas $d -Field 'LengthMm' | Should -Be 1
    }
    It 'reads a field from an object' { Get-SwdProbeDelta -Deltas ([pscustomobject]@{ LengthMm = -1 }) -Field 'LengthMm' | Should -Be -1 }
    It 'returns null, never 0, for an absent field or no deltas' {
        Get-SwdProbeDelta -Deltas ([ordered]@{ VolumeL = 0 }) -Field 'LengthMm' | Should -BeNullOrEmpty
        Get-SwdProbeDelta -Deltas $null -Field 'LengthMm' | Should -BeNullOrEmpty
    }
    It 'keeps a genuine zero' { Get-SwdProbeDelta -Deltas ([ordered]@{ LengthMm = 0 }) -Field 'LengthMm' | Should -Be 0 }
}

Describe 'noise rectangles for image boxes' {
    It 'drops a box wholly inside a measured noise rect (live T9 tile)' { Test-SwdBoxInNoise -Box @(1280, 128, 32, 32) | Should -BeTrue }
    It 'drops a box inside the title-bar strip' { Test-SwdBoxInNoise -Box @(400, 0, 64, 32) | Should -BeTrue }
    It 'keeps a box that only overlaps a noise rect' { Test-SwdBoxInNoise -Box @(1270, 120, 40, 40) | Should -BeFalse }
    It 'keeps a real change elsewhere (the Apply Volume caption area)' { Test-SwdBoxInNoise -Box @(1600, 384, 64, 96) | Should -BeFalse }
    It 'ignores a malformed box' { Test-SwdBoxInNoise -Box @(1, 2, 3) | Should -BeFalse }
}

Describe 'library hash' {
    BeforeEach {
        $script:Lib = Join-Path $TestDrive ('lib' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path (Join-Path $script:Lib 'Boards'), (Join-Path $script:Lib 'temp') -Force | Out-Null
        Set-Content (Join-Path $script:Lib 'Boards\a.fynbs') 'board a'
        Set-Content (Join-Path $script:Lib 'Boards\b.fynrhydro') 'report b'
        Set-Content (Join-Path $script:Lib 'temp\image_dessous.png') 'render 1'
    }
    It 'excludes SWD''s own temp folder' {
        $h = Get-SwdLibraryHash -Root $script:Lib
        $h.Count | Should -Be 2
        $h.ContainsKey('temp\image_dessous.png') | Should -BeFalse
    }
    It 'a temp-only change leaves the invariant intact' {
        $b = Get-SwdLibraryHash -Root $script:Lib
        Set-Content (Join-Path $script:Lib 'temp\image_dessous.png') 'render 2'
        (Compare-SwdLibraryHash -Before $b -After (Get-SwdLibraryHash -Root $script:Lib)).Ok | Should -BeTrue
    }
    It 'reports changed, added and removed board files' {
        $b = Get-SwdLibraryHash -Root $script:Lib
        Set-Content (Join-Path $script:Lib 'Boards\a.fynbs') 'board a EDITED'
        Set-Content (Join-Path $script:Lib 'Boards\c.fynbs') 'new'
        Remove-Item (Join-Path $script:Lib 'Boards\b.fynrhydro')
        $c = Compare-SwdLibraryHash -Before $b -After (Get-SwdLibraryHash -Root $script:Lib)
        $c.Ok | Should -BeFalse
        $c.Changed | Should -Be @('Boards\a.fynbs')
        $c.Added | Should -Be @('Boards\c.fynbs')
        $c.Removed | Should -Be @('Boards\b.fynrhydro')
    }
    It 'hashes a file another process holds open for writing' {
        $p = Join-Path $script:Lib 'Boards\a.fynbs'
        $fs = [IO.File]::Open($p, 'Open', 'ReadWrite', 'ReadWrite')
        try { (Get-SwdLibraryHash -Root $script:Lib).ContainsKey('Boards\a.fynbs') | Should -BeTrue } finally { $fs.Dispose() }
    }
    It 'refuses a missing root' { { Get-SwdLibraryHash -Root (Join-Path $TestDrive 'nope') } | Should -Throw '*not found*' }
}

Describe 'settle decision' {
    BeforeAll { function S($T, $R, $C, $F) { @{ T = $T; Responsive = $R; CpuPct = $C; Frame = $F } } }
    It 'settles at the first sample where all three rules hold' {
        $s = @((S 250 $true 30 'a'), (S 500 $true 10 'b'), (S 750 $true 1 'c'), (S 1000 $true 1 'c'), (S 1250 $true 1 'c'), (S 1500 $true 1 'c'))
        $m = Measure-SwdSettle -Samples $s -FrameK 3
        $m.Settled | Should -BeTrue
        $m.SettleMs | Should -Be 1250
        $m.FirstCpuQuietMs | Should -Be 750
        $m.FirstFramesStableMs | Should -Be 1250
    }
    It 'high CPU blocks settling even with stable frames' {
        $s = @((S 250 $true 30 'c'), (S 500 $true 30 'c'), (S 750 $true 30 'c'))
        (Measure-SwdSettle -Samples $s -FrameK 3).Settled | Should -BeFalse
    }
    It 'an unresponsive app never settles' {
        $s = @((S 250 $false 0 'c'), (S 500 $false 0 'c'), (S 750 $false 0 'c'))
        (Measure-SwdSettle -Samples $s -FrameK 3).Settled | Should -BeFalse
    }
    It 'failed captures (null frames) are never "stable"' {
        $s = @((S 250 $true 0 $null), (S 500 $true 0 $null), (S 750 $true 0 $null))
        $m = Measure-SwdSettle -Samples $s -FrameK 3
        $m.Settled | Should -BeFalse
        $m.FirstFramesStableMs | Should -BeNullOrEmpty
    }
    It 'an unknown CPU reading is not quiet' {
        $s = @((S 250 $true $null 'c'), (S 500 $true $null 'c'), (S 750 $true $null 'c'))
        (Measure-SwdSettle -Samples $s -FrameK 3).Settled | Should -BeFalse
    }
    It 'FrameK 1 settles on the first good sample' {
        (Measure-SwdSettle -Samples @((S 250 $true 0 'x')) -FrameK 1).SettleMs | Should -Be 250
    }
    It 'an empty series is not settled' { (Measure-SwdSettle -Samples @() -FrameK 3).Settled | Should -BeFalse }
    It 'accepts a generic List[object] of hashtables, as Wait-SwdProbeSettle builds (live regression 2026-09-30)' {
        $l = New-Object System.Collections.Generic.List[object]
        foreach ($t in 250, 500, 750) { $l.Add((S $t $true 0 'same')) }
        (Measure-SwdSettle -Samples $l -FrameK 3).SettleMs | Should -Be 750
    }
}

Describe 'paths and output' {
    It 'refuses to log inside the SWD install' {
        { Get-SwdProbeLogDir -Override 'C:\Program Files\ShaperWaveDynamics\probe-logs' 3>$null } | Should -Throw '*path guard*'
    }
    It 'writes JSON as UTF-8 without a BOM' {
        $p = Join-Path $TestDrive 'x.json'
        Write-SwdProbeJson -Path $p -Object ([pscustomobject]@{ a = [string][char]0x00E9 })
        $bytes = [IO.File]::ReadAllBytes($p)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
        (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json).a | Should -Be ([string][char]0x00E9)
    }
}

Describe 'native helper against a throwaway WinForms window' {
    BeforeAll {
        $script:Form = New-Object System.Windows.Forms.Form
        $script:Form.Text = 'swd_probe test target'; $script:Form.Width = 420; $script:Form.Height = 320
        # Placed away from the mouse: hover highlighting (menu items, themed checkbox) is real
        # idle noise and made the masked-frame test flaky when the form opened under the cursor.
        $cur = [SwdProbeNative]::CursorPos()
        $fx = if ($cur -and $cur[0] -ge 0 -and $cur[0] -lt 520) { 900 } else { 40 }
        $script:Form.StartPosition = 'Manual'; $script:Form.Location = New-Object System.Drawing.Point($fx, 40)
        $script:Check = New-Object System.Windows.Forms.CheckBox
        $script:Check.Text = 'homothety'; $script:Check.FlatStyle = 'Standard'; $script:Check.Checked = $true
        $script:Check.Location = New-Object System.Drawing.Point(10, 10); $script:Check.Width = 150
        $script:Box = New-Object System.Windows.Forms.TextBox
        $script:Box.Text = '2133.6'; $script:Box.Location = New-Object System.Drawing.Point(10, 40)
        $script:Label = New-Object System.Windows.Forms.Label
        $script:Label.Text = 'Board Volume: 40.7 liters'; $script:Label.Location = New-Object System.Drawing.Point(200, 200); $script:Label.Width = 200
        $script:Tabs = New-Object System.Windows.Forms.TabControl
        $script:Tabs.Location = New-Object System.Drawing.Point(10, 80); $script:Tabs.Size = New-Object System.Drawing.Size(180, 100)
        foreach ($t in 'Shape', 'Fins') { $pg = New-Object System.Windows.Forms.TabPage; $pg.Text = $t; $script:Tabs.TabPages.Add($pg) }
        # Controls on the not-yet-shown Fins page, like SWD's Fins tab (created on first show).
        foreach ($k in 0..3) { $fb = New-Object System.Windows.Forms.TextBox; $fb.Text = "fin $k"; $fb.Location = New-Object System.Drawing.Point(5, (5 + 20 * $k)); $script:Tabs.TabPages[1].Controls.Add($fb) }
        $script:Btn = New-Object System.Windows.Forms.Button
        $script:Btn.Text = 'Set 10 liters volume to board'; $script:Btn.Location = New-Object System.Drawing.Point(200, 10); $script:Btn.Width = 190
        $script:Form.Controls.Add($script:Btn)
        $script:Menu = New-Object System.Windows.Forms.MenuStrip
        [void]$script:Menu.Items.Add('Files'); [void]$script:Menu.Items.Add('Tools')
        $script:Form.Controls.AddRange(@($script:Check, $script:Box, $script:Label, $script:Tabs, $script:Menu))
        $script:Form.MainMenuStrip = $script:Menu
        $script:Form.Show(); [System.Windows.Forms.Application]::DoEvents()
        $script:H = $script:Form.Handle
        function Pump { 1..5 | ForEach-Object { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20 } }
    }
    AfterAll { if ($script:Form) { $script:Form.Close(); $script:Form.Dispose() } }

    It 'Walk refuses a NULL window' { { [SwdProbeNative]::Walk([IntPtr]::Zero, 100, 1000) } | Should -Throw }
    It 'Walk returns a non-truncated tree for a small window' {
        $n = [SwdProbeNative]::Walk($script:H, 2000, 10000)
        $n.Count | Should -BeGreaterThan 5
        [SwdProbeNative]::LastWalkTruncated | Should -BeFalse
    }
    It 'Walk reports truncation when capped' {
        [void][SwdProbeNative]::Walk($script:H, 3, 10000)
        [SwdProbeNative]::LastWalkTruncated | Should -BeTrue
    }
    It 'reads a FlatStyle=Standard checkbox as CHECKED (the BM_GETCHECK blind spot)' {
        $n = @([SwdProbeNative]::Walk($script:H, 2000, 10000) | Where-Object { $_.Name -eq 'homothety' -and $_.Role -eq '44' })
        $n.Count | Should -BeGreaterThan 0
        ($n[0].State -band 0x10) | Should -Be 0x10
        $script:Check.Checked = $false; Pump
        $n2 = @([SwdProbeNative]::Walk($script:H, 2000, 10000) | Where-Object { $_.Name -eq 'homothety' -and $_.Role -eq '44' })
        ($n2[0].State -band 0x10) | Should -Be 0
        $script:Check.Checked = $true; Pump
    }
    It 'reads an edit box value exactly once (no title-bar echo of the window text)' {
        @([SwdProbeNative]::Walk($script:H, 2000, 10000) | Where-Object { $_.Value -eq '2133.6' }).Count | Should -Be 1
    }
    It 'a renamed button appears once in the walk and once in the diff (live T9 regression)' {
        $a = [SwdProbeNative]::Walk($script:H, 2000, 10000)
        @($a | Where-Object { $_.Name -eq 'Set 10 liters volume to board' }).Count | Should -Be 1
        $script:Btn.Text = 'Set 11 liters volume to board'; Pump
        $b = [SwdProbeNative]::Walk($script:H, 2000, 10000)
        @(Compare-SwdMsaa -Before $a -After $b | Where-Object { $_.Field -eq 'Name' }).Count | Should -Be 1
        $script:Btn.Text = 'Set 10 liters volume to board'; Pump
    }
    It 'drops non-client chrome (title bars, system menus, grips) of child windows' {
        $n = @([SwdProbeNative]::Walk($script:H, 2000, 10000))
        @($n | Where-Object { $_.Role -in '1', '4' }).Count | Should -Be 0
        @($n | Where-Object { $_.Name -in 'System', 'Application' -and $_.Role -eq '2' }).Count | Should -Be 0
    }
    It 'keeps a MenuStrip and its items (menu-bar role on a CLIENT must survive the filter)' {
        $n = @([SwdProbeNative]::Walk($script:H, 2000, 10000))
        @($n | Where-Object { $_.Role -eq '12' -and $_.Name -eq 'Files' }).Count | Should -Be 1
    }
    It 'a value change shows up in Compare-SwdMsaa' {
        $a = [SwdProbeNative]::Walk($script:H, 2000, 10000)
        $script:Box.Text = '2134.6'; Pump
        $b = [SwdProbeNative]::Walk($script:H, 2000, 10000)
        $d = @(Compare-SwdMsaa -Before $a -After $b)
        @($d | Where-Object { $_.Field -eq 'Value' -and $_.To -eq '2134.6' }).Count | Should -Be 1
        $script:Box.Text = '2133.6'; Pump
    }
    It 'selects a tab by message, window in the background, without moving the cursor' {
        $script:Tabs.SelectedIndex = 0; Pump
        $c0 = [SwdProbeNative]::CursorPos() -join ','
        $r = Select-SwdProbeTab -Handle $script:H -Name 'Fins'; Pump
        $r.Selected | Should -Be 1
        $script:Tabs.SelectedIndex | Should -Be 1
        ([SwdProbeNative]::CursorPos() -join ',') | Should -Be $c0
        [void](Select-SwdProbeTab -Handle $script:H -Name 'Shape'); Pump
        $script:Tabs.SelectedIndex | Should -Be 0
    }
    It 'keys every node to its owning window handle' {
        $n = @([SwdProbeNative]::Walk($script:H, 2000, 10000))
        @($n | Where-Object { $_.Key -notmatch '^h\d+:0' -or $_.Hwnd -eq 0 }).Count | Should -Be 0
    }
    It 'visiting a tab and coming back leaves no VISIBLE change (live T11 regression: 1,103 false changes)' {
        $script:Tabs.SelectedIndex = 0; Pump
        $before = [SwdProbeNative]::Walk($script:H, 4000, 10000)
        [void](Select-SwdProbeTab -Handle $script:H -Name 'Fins'); Pump
        [void](Select-SwdProbeTab -Handle $script:H -Name 'Shape'); Pump
        $after = [SwdProbeNative]::Walk($script:H, 4000, 10000)
        $script:Tabs.TabPages[1].Controls[0].IsHandleCreated | Should -BeTrue
        $d = @(Compare-SwdMsaa -Before $before -After $after)
        @($d | Where-Object { -not $_.Hidden }).Count | Should -Be 0
    }
    It 'Select-SwdProbeTab refuses a tab that is not allowlisted' {
        { Select-SwdProbeTab -Handle $script:H -Name 'Wave Room' } | Should -Throw '*not on the probe allowlist*'
    }
    It 'Select-SwdProbeTab refuses an allowlisted name that is not a page tab here' {
        { Select-SwdProbeTab -Handle $script:H -Name 'Rockers' } | Should -Throw '*found 0*'
    }
    It 'FrameHash is stable for an unchanged window and names its size' {
        Pump
        $a = [SwdProbeNative]::FrameHash($script:H, $null); $b = [SwdProbeNative]::FrameHash($script:H, $null)
        $a | Should -Match '^\d+x\d+:[0-9A-F]{32}$'
        $b | Should -Be $a
    }
    It 'FrameHash changes when visible content changes, and not when the change is inside an ignore rect' {
        Pump
        $r = New-Object 'SwdWin+RECT'; [void][SwdWin]::GetWindowRect($script:H, [ref]$r)
        $lr = $script:Label.RectangleToScreen($script:Label.ClientRectangle)
        $ignore = [int[]]@(($lr.X - $r.Left - 2), ($lr.Y - $r.Top - 2), ($lr.Width + 4), ($lr.Height + 4))
        $a = [SwdProbeNative]::FrameHash($script:H, $null); $ai = [SwdProbeNative]::FrameHash($script:H, $ignore)
        $script:Label.Text = 'Board Volume: 40.8 liters'; Pump
        [SwdProbeNative]::FrameHash($script:H, $null) | Should -Not -Be $a
        [SwdProbeNative]::FrameHash($script:H, $ignore) | Should -Be $ai
        $script:Label.Text = 'Board Volume: 40.7 liters'; Pump
    }
    It 'NullRoundTripMs answers for a live window' { [SwdProbeNative]::NullRoundTripMs($script:H, 200) | Should -BeGreaterOrEqual 0 }
    It 'a self-updating readout (like SWD''s status-bar CPU %) is idle noise that an ignore rect removes' {
        $cpu = New-Object System.Windows.Forms.Label
        $cpu.Location = New-Object System.Drawing.Point(200, 240); $cpu.Width = 120; $cpu.Text = 'Cpu:0%'
        $script:Form.Controls.Add($cpu)
        $n = 0; $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 60
        $timer.add_Tick({ $script:tick++; $cpu.Text = "Cpu:$($script:tick)%" }.GetNewClosure())
        $script:tick = 0; $timer.Start()
        try {
            Pump
            $r = New-Object 'SwdWin+RECT'; [void][SwdWin]::GetWindowRect($script:H, [ref]$r)
            $lr = $cpu.RectangleToScreen($cpu.ClientRectangle)
            $ignore = [int[]]@(($lr.X - $r.Left - 2), ($lr.Y - $r.Top - 2), ($lr.Width + 4), ($lr.Height + 4))
            $raw = @(); $masked = @()
            foreach ($i in 1..6) { Pump; Start-Sleep -Milliseconds 120; Pump; $raw += [SwdProbeNative]::FrameHash($script:H, $null); $masked += [SwdProbeNative]::FrameHash($script:H, $ignore) }
            @($raw | Select-Object -Unique).Count | Should -BeGreaterThan 1
            @($masked | Select-Object -Unique).Count | Should -Be 1
        } finally { $timer.Stop(); $timer.Dispose(); $script:Form.Controls.Remove($cpu); $cpu.Dispose(); Pump }
    }
    It 'Measure-SwdSettle settles on live frame hashes of an idle window (focus off the caret)' {
        $script:Check.Focus() | Out-Null; Pump
        $samples = @(); foreach ($i in 1..4) { Pump; Start-Sleep -Milliseconds 150; $samples += @{ T = $i * 100; Responsive = $true; CpuPct = 0.0; Frame = [SwdProbeNative]::FrameHash($script:H, $null) } }
        (Measure-SwdSettle -Samples $samples -FrameK 3).Settled | Should -BeTrue
    }
}
