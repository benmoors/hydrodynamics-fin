<#
    Pester 6.x, Windows PowerShell 5.1. Runs with SWD CLOSED.

    Covers the parts of swd_probe.ps1 whose failure would be silent or unsafe:
      - the click allowlist and the denylist (a wrong answer here clicks a scan or a delete)
      - the board guard (originals refused)
      - the kill switch, including the left-monitor false positive measured 2026-09-30
      - the MSAA diff, volatility set, library hash and settle decision
      - the native helper against a throwaway in-process WinForms window: MSAA walk
        (checkbox state on a FlatStyle=Standard CheckBox, the case BM_GETCHECK is blind to),
        frame hashing with ignore rectangles, tab switching by TCM_SETCURFOCUS.
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

Describe 'denylist holds when the allowlist is widened: more verbs, invisible characters, NFD, locale (SQA W1)' {
    # Each caption must be refused however the allowlist was widened: with the word as a person
    # reads it ($visible), or with the caption copied exactly, invisible characters and all.
    It 'refuses <label>' -ForEach @(
        @{ label = 'Scan'; text = 'Scan'; visible = 'Scan' }
        @{ label = 'Start scan'; text = 'Start scan'; visible = 'Start scan' }
        @{ label = 'Rescan'; text = 'Rescan'; visible = 'Rescan' }
        @{ label = 'Hydro-Scan'; text = 'Hydro-Scan'; visible = 'Hydro-Scan' }
        @{ label = 'Lancer le scan'; text = 'Lancer le scan'; visible = 'Lancer le scan' }
        @{ label = 'Import'; text = 'Import'; visible = 'Import' }
        @{ label = 'Importer'; text = 'Importer'; visible = 'Importer' }
        @{ label = 'Duplicate'; text = 'Duplicate'; visible = 'Duplicate' }
        @{ label = 'Dupliquer'; text = 'Dupliquer'; visible = 'Dupliquer' }
        @{ label = 'Remove'; text = 'Remove'; visible = 'Remove' }
        @{ label = 'Effacer'; text = 'Effacer'; visible = 'Effacer' }
        @{ label = 'Sauvegarder'; text = 'Sauvegarder'; visible = 'Sauvegarder' }
        @{ label = 'Reinitialiser, unaccented'; text = 'Reinitialiser'; visible = 'Reinitialiser' }
        @{ label = 'Reinitialiser, e-acute'; text = ('R' + [char]0x00E9 + 'initialiser'); visible = ('R' + [char]0x00E9 + 'initialiser') }
        @{ label = 'REINITIALISER, upper-case E-acute'; text = ('R' + [char]0x00C9 + 'INITIALISER'); visible = ('R' + [char]0x00C9 + 'INITIALISER') }
        @{ label = 'Deverrouiller, unaccented'; text = 'Deverrouiller'; visible = 'Deverrouiller' }
        @{ label = 'Deverrouiller, e-acute'; text = ('D' + [char]0x00E9 + 'verrouiller'); visible = ('D' + [char]0x00E9 + 'verrouiller') }
        @{ label = 'soft hyphen inside Delete'; text = ('Del' + [char]0x00AD + 'ete'); visible = 'Delete' }
        @{ label = 'zero-width space inside Delete'; text = ('Del' + [char]0x200B + 'ete'); visible = 'Delete' }
        @{ label = 'word joiner inside Delete'; text = ('Del' + [char]0x2060 + 'ete'); visible = 'Delete' }
        @{ label = 'BOM inside Delete'; text = ('Del' + [char]0xFEFF + 'ete'); visible = 'Delete' }
        @{ label = 'combining grapheme joiner (Mn, not Cf) inside Delete'; text = ('Del' + [char]0x034F + 'ete'); visible = 'Delete' }
        @{ label = 'variation selector inside Delete'; text = ('Del' + [char]0xFE0F + 'ete'); visible = 'Delete' }
        @{ label = 'NUL inside Delete'; text = ('Del' + [char]0x0000 + 'ete'); visible = 'Delete' }
        @{ label = 'C1 control inside Delete'; text = ('Del' + [char]0x0085 + 'ete'); visible = 'Delete' }
        @{ label = 'astral tag character inside Delete'; text = ('Del' + [char]::ConvertFromUtf32(0xE0020) + 'ete'); visible = 'Delete' }
        @{ label = 'astral format character (Kaithi number sign) inside Delete'; text = ('Del' + [char]::ConvertFromUtf32(0x110BD) + 'ete'); visible = 'Delete' }
        @{ label = 'zero-width joiner inside Save'; text = ('Sa' + [char]0x200D + 've'); visible = 'Save' }
        @{ label = 'soft hyphen inside Hydro-Scan'; text = ('Hydro' + [char]0x00AD + 'Scan'); visible = 'Hydro-Scan' }
        @{ label = 'Creer decomposed (e + combining acute, NFD)'; text = ('Cre' + [char]0x0301 + 'er'); visible = ('Cr' + [char]0x00E9 + 'er') }
        @{ label = 'Creer with a joiner between e and its combining acute'; text = ('Cre' + [char]0x200D + [char]0x0301 + 'er'); visible = ('Cr' + [char]0x00E9 + 'er') }
    ) {
        $saved = $script:ProbeAllowedButtons
        try {
            foreach ($entry in @($visible, $text)) {
                $script:ProbeAllowedButtons = @($saved) + $entry
                Test-SwdProbeAllowedButton $text | Should -BeFalse
            }
            # The denylist itself sees the word, not just the allowlist refusing a spelling.
            Get-SwdProbeDenyMatch (ConvertTo-SwdProbeLabel $text) | Should -Not -BeNullOrEmpty
        } finally { $script:ProbeAllowedButtons = $saved }
    }
    It 'the allowlist is exact (ordinal): refuses <label>' -ForEach @(
        # Visible letters the old linguistic -ccontains ignored (measured: 2,534 BMP code points).
        @{ label = 'Apply Length with U+0525 inside'; text = ('Apply Len' + [char]0x0525 + 'gth'); entry = '' }
        @{ label = 'Apply Length with U+A7AA inside'; text = ('Apply ' + [char]0xA7AA + 'Length'); entry = '' }
        @{ label = 'Delete with U+0525 inside, allowlist widened with Delete'; text = ('Del' + [char]0x0525 + 'ete'); entry = 'Delete' }
    ) {
        $saved = $script:ProbeAllowedButtons
        try {
            if ($entry) { $script:ProbeAllowedButtons = @($saved) + $entry }
            Test-SwdProbeAllowedButton $text | Should -BeFalse
        } finally { $script:ProbeAllowedButtons = $saved }
    }
    It 'the tab allowlist is exact (ordinal)' {
        Test-SwdProbeAllowedTab ('Fi' + [char]0x0525 + 'ns') | Should -BeFalse
    }
    It 'refuses <_> under a Turkish culture, where (?i) folds I to a dotless i' -ForEach @('IMPORT', 'SUPPRIMER', 'Import') {
        $saved = $script:ProbeAllowedButtons; $culture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            $script:ProbeAllowedButtons = @($saved) + $_
            Test-SwdProbeAllowedButton $_ | Should -BeFalse
        } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $culture; $script:ProbeAllowedButtons = $saved }
    }
    It 'normalises invisible characters away and composes to NFC (compared ordinally)' {
        # Should -BeExactly is itself linguistic and passes with the soft hyphen still present.
        [string]::Equals((ConvertTo-SwdProbeLabel ('Del' + [char]0x00AD + 'ete')), 'Delete', [StringComparison]::Ordinal) | Should -BeTrue
        [string]::Equals((ConvertTo-SwdProbeLabel ('Cre' + [char]0x0301 + 'er')), ('Cr' + [char]0x00E9 + 'er'), [StringComparison]::Ordinal) | Should -BeTrue
        [string]::Equals((ConvertTo-SwdProbeLabel ('&Apply' + [char]0x00A0 + ' Length ')), 'Apply Length', [StringComparison]::Ordinal) | Should -BeTrue
    }
    It 'still allows every allowlisted button caption' {
        foreach ($c in $script:ProbeAllowedButtons) { Test-SwdProbeAllowedButton $c | Should -BeTrue -Because $c }
    }
    It 'still allows every allowlisted tab' {
        foreach ($t in $script:ProbeAllowedTabs) { Test-SwdProbeAllowedTab $t | Should -BeTrue -Because $t }
    }
    It 'refuses an ill-formed caption (<label>) rather than waving it through' -ForEach @(
        @{ label = 'a lone surrogate'; text = ('Apply ' + [char]0xD800 + 'Length') }
        @{ label = 'a noncharacter'; text = ('Apply Length' + [char]0xFFFE) }
    ) {
        { Assert-SwdProbeButton -Handle 42 -TextReader { param($h) $text }.GetNewClosure() } | Should -Throw
    }
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
    It 'writes T13 CSV as UTF-8 without a BOM' {
        Mock Get-SwdProbeMain { [pscustomobject]@{ Handle = 1 } }
        Mock Get-SwdProbeLengthContext { [pscustomobject]@{ LengthMm = 2000; Group = 100; Edit = 101; Apply = 102 } }
        Mock Set-SwdProbeLength { return [pscustomobject]@{ Applied = $true; GeometryMs = 10; Settle = [pscustomobject]@{ SettleMs = 100; TimedOut = $false; FirstResponsiveMs = 10; FirstCpuQuietMs = 20; FirstFramesStableMs = 30; MaxCpuPct = 5 } } }
        $d = Join-Path $TestDrive 't13'
        New-Item -ItemType Directory -Path $d | Out-Null
        Invoke-SwdProbeT13 -RunDir $d -DeltaMm 1.0 -Repeats 1 -StopFile 'STOP' | Out-Null
        $p = Join-Path $d 't13-settle.csv'
        $bytes = [IO.File]::ReadAllBytes($p)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
    }
}

Describe 'the library check runs on a stopped or failed run too (SQA W3)' {
    BeforeAll {
        function Get-Summary {
            $f = Get-ChildItem -LiteralPath $script:LogRoot -Recurse -Filter 'summary.json' | Select-Object -First 1
            Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json
        }
    }
    BeforeEach {
        $script:LogRoot = Join-Path $TestDrive ('w3-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:LogRoot | Out-Null
        $script:HashN = 0
        Mock Get-SwdProbeLogDir { $script:LogRoot }
        Mock Get-SwdProbeMain { [pscustomobject]@{ Process = [pscustomobject]@{ Id = $PID }; Handle = 1; Title = 'FYN Shaper Wave Dynamics   <Board: x_Copy_1(2000mm)>' } }
        # Never the real library: every hash is a stub, and it differs between calls.
        Mock Get-SwdLibraryHash { $script:HashN++; @{ 'Boards\a.fynbs' = "H$($script:HashN)" } }
    }
    It 'still re-hashes and records the library after a STOP, and the stop is what surfaces' {
        Mock Invoke-SwdProbeT12 { throw 'SWD-PROBE-STOPPED: stop file present' }
        { Invoke-SwdProbe -Name T12 3>$null } | Should -Throw 'SWD-PROBE-STOPPED*'
        Should -Invoke Get-SwdLibraryHash -Times 2 -Exactly
        $s = Get-Summary
        $s.Outcome | Should -Be 'error'
        $s.Library.Ok | Should -BeFalse
        @($s.Library.Changed) | Should -Be @('Boards\a.fynbs')
    }
    It 'a failing re-hash never replaces the original error, and is recorded as not re-checked' {
        Mock Invoke-SwdProbeT12 { throw 'probe crashed' }
        Mock Get-SwdLibraryHash {
            $script:HashN++
            if ($script:HashN -ge 2) { throw ("cannot read " + (Join-Path $env:USERPROFILE 'x.fynbs')) }
            @{ 'a' = 'x' }
        }
        { Invoke-SwdProbe -Name T12 3>$null } | Should -Throw 'probe crashed'
        $s = Get-Summary
        $null -eq $s.Library.Ok | Should -BeTrue
        $s.Library.Error | Should -Match 'cannot read'
        $s.Library.Error | Should -Not -Match ([regex]::Escape($env:USERPROFILE))
    }
    It 'records the library on a completed run as before' {
        Mock Get-SwdLibraryHash { @{ 'a' = 'same' } }
        Mock Invoke-SwdProbeT12 { [pscustomobject]@{ Exact = $true } }
        $r = Invoke-SwdProbe -Name T12
        $r.Outcome | Should -Be 'completed'
        $r.Library.Ok | Should -BeTrue
        Should -Invoke Get-SwdLibraryHash -Times 2 -Exactly
    }
    It 'a failure before the library was hashed surfaces as itself, not as a StrictMode error from finally' {
        Mock Get-SwdProbeMain { throw 'no SWD window' }
        { Invoke-SwdProbe -Name T12 3>$null } | Should -Throw 'no SWD window'
        Should -Invoke Get-SwdLibraryHash -Times 0 -Exactly
        (Get-Summary).Outcome | Should -Be 'error'
    }
}

Describe 'a missing library root is reported without the username or tenant (SQA W4)' {
    It 'redacts <label>' -ForEach @(
        @{ label = 'a plain OneDrive path'; shape = 'plain' }
        @{ label = 'a forward-slash spelling'; shape = 'slash' }
        @{ label = 'an upper-case spelling'; shape = 'upper' }
        @{ label = 'a trailing backslash'; shape = 'trail' }
    ) {
        $saved = $env:OneDriveCommercial
        $fake = Join-Path $TestDrive 'OneDrive - Contoso Fixture Tenant'
        try {
            $env:OneDriveCommercial = $fake
            $root = Join-Path $fake 'Documents\ShaperWaveDynamics documents\biblio'
            switch ($shape) {
                'slash' { $root = $root.Replace('\', '/') }
                'upper' { $root = $root.ToUpperInvariant() }
                'trail' { $root = $root + '\' }
            }
            $err = $null
            try { [void](Get-SwdLibraryHash -Root $root) } catch { $err = $_.Exception.Message }
            $err | Should -Match 'not found'
            $err | Should -Not -Match '(?i)Contoso Fixture Tenant'
            $err | Should -Not -Match ('(?i)' + [regex]::Escape($env:USERPROFILE))
            $err | Should -Match '~\\OneDrive\\'
        } finally { $env:OneDriveCommercial = $saved }
    }
}

Describe 'T9 reads the Apply Volume caption before its write and flags a dirty baseline (SQA S3)' {
    BeforeAll {
        function Ctl($h, $cls, $parent, $text) {
            [pscustomobject]@{ Handle = [int64]$h; Class = $cls; CtrlId = 0; Visible = $true; Enabled = $true; Rect = '0,0,10,10'
                               Parent = [int64]$parent; Text = $text; TimedOut = $false; Skipped = $false; LastError = 0 }
        }
        function Set-T9Scenario($CaptionBefore, $CaptionAfter = 'Set 11 liters volume to board') {
            $mk = { param($cap) @((Ctl 500 'WindowsForms10.Window.8' 200 'Board Volume: 26.8 liters'), (Ctl 511 'WindowsForms10.EDIT' 510 '10'),
                                  (Ctl 512 'WindowsForms10.BUTTON' 500 $cap)) }
            $script:SnapBefore = [pscustomobject]@{ Title = 'FYN'; Origin = @(0, 0); Controls = (& $mk $CaptionBefore); Msaa = @(); Image = $null }
            $script:CtlAfter = & $mk $CaptionAfter
            $script:SnapAfter = [pscustomobject]@{ Title = 'FYN'; Origin = @(0, 0); Controls = $script:CtlAfter; Msaa = @(); Image = $null }
        }
    }
    BeforeEach {
        Mock Resolve-SwdGeometryControl { [pscustomobject]@{ Volume = [pscustomobject]@{ Group = [int64]500; Edit = [int64]511; Apply = [int64]512 }; Missing = @() } }
        Mock Get-SwdText { '10' }
        Mock Assert-SwdProbeContinue { }
        Mock Set-SwdNumeric { [pscustomobject]@{ Ok = $true; After = '11'; Culture = 'Invariant' } }
        Mock Wait-SwdProbeSettle { [pscustomobject]@{ Settled = $true } }
        Mock Get-SwdProbeMain { [pscustomobject]@{ Handle = 1 } }
        Mock Find-SwdProbeNoiseMask { $null }
        Mock Get-SwdProbeSnapshot { $script:SnapBefore } -ParameterFilter { $Label -eq 't9-0-before' }
        Mock Get-SwdProbeSnapshot { $script:SnapAfter } -ParameterFilter { $Label -ne 't9-0-before' }
        Mock Get-SwdControl { $script:CtlAfter }
        $script:T9Stop = Join-Path $TestDrive 'STOP-t9'
    }
    It 'a clean board: the caption before the write is Apply Volume, and the baseline is not dirty' {
        Set-T9Scenario -CaptionBefore 'Apply Volume'
        $r = Invoke-SwdProbeT9 -RunDir $TestDrive -StopFile $script:T9Stop
        @($r.ApplyVolumeCaptionBefore) | Should -Be @('Apply Volume')
        @($r.ApplyVolumeCaption) | Should -Be @('Set 11 liters volume to board')
        $r.BaselineDirty | Should -BeOfType [bool]
        $r.BaselineDirty | Should -BeFalse
        $r.LeavesResidue | Should -BeTrue
    }
    It 'a board whose Volume box was written earlier this session: the baseline is dirty' {
        Set-T9Scenario -CaptionBefore 'Set 10 liters volume to board'
        $r = Invoke-SwdProbeT9 -RunDir $TestDrive -StopFile $script:T9Stop
        $r.BaselineDirty | Should -BeTrue
    }
    It 'a caption that did not answer before the write: dirty or not is unknown, never clean' {
        Set-T9Scenario -CaptionBefore $null
        $r = Invoke-SwdProbeT9 -RunDir $TestDrive -StopFile $script:T9Stop
        $null -eq $r.BaselineDirty | Should -BeTrue
    }
    It 'LeavesResidue is unknown, not false, when the image detector failed (W2)' {
        Set-T9Scenario -CaptionBefore 'Apply Volume'
        Mock Compare-SwdProbeSnapshot { [pscustomobject]@{ InScopeCount = 0; OutOfScopeCount = $null; ImageError = 'boom'
                                                           OutOfScope = [pscustomobject]@{ Win32 = @(); Msaa = @(); ImageBoxes = @() } } }
        $r = Invoke-SwdProbeT9 -RunDir $TestDrive -StopFile $script:T9Stop
        $null -eq $r.LeavesResidue | Should -BeTrue
    }
}

Describe 'library hash sees hidden files and hidden folders (SQA S11)' {
    BeforeEach {
        $script:HLib = Join-Path $TestDrive ('hlib' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force -Path (Join-Path $script:HLib 'Boards\hid den'), (Join-Path $script:HLib 'temp') | Out-Null
        Set-Content (Join-Path $script:HLib 'Boards\a.fynbs') 'board a'
        Set-Content (Join-Path $script:HLib 'Boards\.hidden.fynbs') 'hidden board'
        [IO.File]::SetAttributes((Join-Path $script:HLib 'Boards\.hidden.fynbs'), [IO.FileAttributes]::Hidden)
        Set-Content (Join-Path $script:HLib 'desktop.ini') '[x]'
        [IO.File]::SetAttributes((Join-Path $script:HLib 'desktop.ini'), [IO.FileAttributes]'Hidden, System')
        Set-Content (Join-Path $script:HLib 'Boards\hid den\c.fynbs') 'in a hidden folder'
        $d = Get-Item -LiteralPath (Join-Path $script:HLib 'Boards\hid den')
        $d.Attributes = $d.Attributes -bor [IO.FileAttributes]::Hidden
        Set-Content (Join-Path $script:HLib 'temp\render.png') 'x'
        [IO.File]::SetAttributes((Join-Path $script:HLib 'temp\render.png'), [IO.FileAttributes]::Hidden)
    }
    It 'hashes <rel>, and reports a change to it' -ForEach @(
        @{ rel = 'Boards\.hidden.fynbs' }
        @{ rel = 'desktop.ini' }
        @{ rel = 'Boards\hid den\c.fynbs' }
    ) {
        $b = Get-SwdLibraryHash -Root $script:HLib
        $b.ContainsKey($rel) | Should -BeTrue
        [IO.File]::AppendAllText((Join-Path $script:HLib $rel), 'tampered')
        $c = Compare-SwdLibraryHash -Before $b -After (Get-SwdLibraryHash -Root $script:HLib)
        $c.Ok | Should -BeFalse
        @($c.Changed) | Should -Be @($rel)
    }
    It 'still excludes SWD''s own temp folder, hidden files in it included' {
        (Get-SwdLibraryHash -Root $script:HLib).Keys | Should -Not -Contain 'temp\render.png'
    }
}

Describe 'MSAA truncation is flagged and surfaced (SQA S4)' {
    It 'a node with more than 10,000 children marks the walk truncated instead of reading as a leaf' {
        $f = New-Object System.Windows.Forms.Form; $f.StartPosition = 'Manual'; $f.Location = New-Object System.Drawing.Point(900, 400)
        $lb = New-Object System.Windows.Forms.ListBox; $lb.Size = New-Object System.Drawing.Size(150, 100)
        $lb.BeginUpdate(); foreach ($i in 1..10001) { [void]$lb.Items.Add("i$i") }; $lb.EndUpdate()
        $f.Controls.Add($lb)
        try {
            $f.Show(); [System.Windows.Forms.Application]::DoEvents()
            $n = [SwdProbeNative]::Walk([intptr][int64]$lb.Handle, 50000, 60000)
            @($n).Count | Should -BeLessThan 10
            [SwdProbeNative]::LastWalkTruncated | Should -BeTrue
            # The control: under the cap the same list is walked in full and not truncated.
            $lb.BeginUpdate(); $lb.Items.RemoveAt(0); $lb.Items.RemoveAt(0); $lb.EndUpdate(); [System.Windows.Forms.Application]::DoEvents()
            $m = [SwdProbeNative]::Walk([intptr][int64]$lb.Handle, 50000, 60000)
            @($m).Count | Should -BeGreaterThan 9999
            [SwdProbeNative]::LastWalkTruncated | Should -BeFalse
        } finally { $f.Close(); $f.Dispose() }
    }
    It 'Compare-SwdProbeSnapshot and Format-SwdProbeDiff surface a truncated walk on either side' {
        $clean = [pscustomobject]@{ Controls = @(); Msaa = @(); Image = $null; MsaaTruncated = $false }
        $cut = [pscustomobject]@{ Controls = @(); Msaa = @(); Image = $null; MsaaTruncated = $true }
        (Compare-SwdProbeSnapshot -Before $clean -After $clean).MsaaTruncated | Should -BeFalse
        $d = Compare-SwdProbeSnapshot -Before $clean -After $cut
        $d.MsaaTruncated | Should -BeTrue
        (Format-SwdProbeDiff $d) -join "`n" | Should -Match 'MSAA WALK TRUNCATED'
        (Compare-SwdProbeSnapshot -Before $cut -After $clean).MsaaTruncated | Should -BeTrue
    }
    It 'a snapshot without the flag (built offline) reads as not truncated' {
        $s = [pscustomobject]@{ Controls = @(); Msaa = @(); Image = $null }
        (Compare-SwdProbeSnapshot -Before $s -After $s).MsaaTruncated | Should -BeFalse
    }
}

Describe 'a tab switch is confirmed by name, not only by index (SQA S12)' {
    It 'refuses when the tab at the selected index no longer carries the requested name' {
        $f = New-Object System.Windows.Forms.Form; $f.StartPosition = 'Manual'; $f.Location = New-Object System.Drawing.Point(900, 400)
        $tc = New-Object System.Windows.Forms.TabControl; $tc.Size = New-Object System.Drawing.Size(200, 100)
        foreach ($t in 'Shape', 'Fins') { $pg = New-Object System.Windows.Forms.TabPage; $pg.Text = $t; $tc.TabPages.Add($pg) }
        # An application that renames the page it has just shown: index 1 is selected, but it
        # is no longer the 'Fins' tab.
        $tc.add_SelectedIndexChanged({ if ($tc.SelectedIndex -eq 1) { $tc.TabPages[1].Text = 'Wave Room' } }.GetNewClosure())
        $f.Controls.Add($tc)
        try {
            $f.Show(); [System.Windows.Forms.Application]::DoEvents()
            { Select-SwdProbeTab -Handle ([int64]$f.Handle) -Name 'Fins' } | Should -Throw "*not the selected 'Fins' tab*"
        } finally { $f.Close(); $f.Dispose() }
    }
    It 'reads the page tab it selected back through MSAA, selected and named' {
        $f = New-Object System.Windows.Forms.Form; $f.StartPosition = 'Manual'; $f.Location = New-Object System.Drawing.Point(900, 400)
        $tc = New-Object System.Windows.Forms.TabControl; $tc.Size = New-Object System.Drawing.Size(200, 100)
        foreach ($t in 'Shape', 'Fins') { $pg = New-Object System.Windows.Forms.TabPage; $pg.Text = $t; $tc.TabPages.Add($pg) }
        $f.Controls.Add($tc)
        try {
            $f.Show(); [System.Windows.Forms.Application]::DoEvents()
            $r = Select-SwdProbeTab -Handle ([int64]$f.Handle) -Name 'Fins'
            $n = [SwdProbeNative]::ChildAt([intptr]$r.TabControl, $r.Index)
            $n.Name | Should -BeExactly 'Fins'
            ($n.State -band 0x2) | Should -Be 0x2
            $null -eq [SwdProbeNative]::ChildAt([intptr]$r.TabControl, 99) | Should -BeTrue
        } finally { $f.Close(); $f.Dispose() }
    }
    It 'normalises the requested tab name before matching, so MSAA semicolon separators work' {
        $f = New-Object System.Windows.Forms.Form; $f.StartPosition = 'Manual'; $f.Location = New-Object System.Drawing.Point(900, 400)
        $tc = New-Object System.Windows.Forms.TabControl; $tc.Size = New-Object System.Drawing.Size(200, 100)
        $tabTexts = @('Shape', 'Elements;analysis')
        foreach ($t in $tabTexts) { $pg = New-Object System.Windows.Forms.TabPage; $pg.Text = $t; $tc.TabPages.Add($pg) }
        $f.Controls.Add($tc)
        try {
            $f.Show(); [System.Windows.Forms.Application]::DoEvents()
            # The allowlist holds 'Elements analysis', but MSAA reports 'Elements;analysis'.
            $r = Select-SwdProbeTab -Handle ([int64]$f.Handle) -Name 'Elements;analysis'
            $r.Index | Should -Be 1
            $n = [SwdProbeNative]::ChildAt([intptr]$r.TabControl, $r.Index)
            ($n.State -band 0x2) | Should -Be 0x2
        } finally { $f.Close(); $f.Dispose() }
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
        # SQA W6: PrintWindow(PW_RENDERFULLCONTENT) returns different pixels for back-to-back
        # captures of this fixture's themed TabControl strip and TextBox, with nothing changing
        # (measured 2026-10-01: raw hashes differed in 12 of 320 pairs, masked in 0 of 320). The
        # three FrameHash tests ignore both, +/-2 px. Production FrameHash keeps flag 2.
        function FixtureNoise {
            $r = New-Object 'SwdWin+RECT'; [void][SwdWin]::GetWindowRect($script:H, [ref]$r)
            $out = @()
            foreach ($c in $script:Tabs, $script:Box) {
                $s = $c.RectangleToScreen($c.ClientRectangle)
                $out += ($s.X - $r.Left - 2), ($s.Y - $r.Top - 2), ($s.Width + 4), ($s.Height + 4)
            }
            return , ([int[]]$out)
        }
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
        $n = FixtureNoise
        $a = [SwdProbeNative]::FrameHash($script:H, $n); $b = [SwdProbeNative]::FrameHash($script:H, $n)
        $a | Should -Match '^\d+x\d+:[0-9A-F]{32}$'
        $b | Should -Be $a
    }
    It 'FrameHash changes when visible content changes, and not when the change is inside an ignore rect' {
        Pump
        $r = New-Object 'SwdWin+RECT'; [void][SwdWin]::GetWindowRect($script:H, [ref]$r)
        $lr = $script:Label.RectangleToScreen($script:Label.ClientRectangle)
        $n = FixtureNoise
        $ignore = [int[]](@(($lr.X - $r.Left - 2), ($lr.Y - $r.Top - 2), ($lr.Width + 4), ($lr.Height + 4)) + $n)
        $a = [SwdProbeNative]::FrameHash($script:H, $n); $ai = [SwdProbeNative]::FrameHash($script:H, $ignore)
        $script:Label.Text = 'Board Volume: 40.8 liters'; Pump
        [SwdProbeNative]::FrameHash($script:H, $n) | Should -Not -Be $a
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
            $n = FixtureNoise
            $ignore = [int[]](@(($lr.X - $r.Left - 2), ($lr.Y - $r.Top - 2), ($lr.Width + 4), ($lr.Height + 4)) + $n)
            $raw = @(); $masked = @()
            foreach ($i in 1..6) { Pump; Start-Sleep -Milliseconds 120; Pump; $raw += [SwdProbeNative]::FrameHash($script:H, $n); $masked += [SwdProbeNative]::FrameHash($script:H, $ignore) }
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

Describe 'image diff runner: its arguments, real diffs, and a failure reported as data (SQA S1, W2)' {
    BeforeAll {
        # Real PNGs from System.Drawing, in a folder whose name has a space.
        function New-TestPng([string]$Path, [int]$W, [int]$H, [int[]]$Box) {
            $b = New-Object System.Drawing.Bitmap($W, $H)
            try {
                if ($Box) {
                    $g = [System.Drawing.Graphics]::FromImage($b)
                    try { $g.FillRectangle([System.Drawing.Brushes]::White, $Box[0], $Box[1], $Box[2], $Box[3]) } finally { $g.Dispose() }
                }
                $b.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
            } finally { $b.Dispose() }
        }
        $script:ImgDir = Join-Path $TestDrive 'image diff'
        New-Item -ItemType Directory -Force -Path $script:ImgDir | Out-Null
        $script:PngA = Join-Path $script:ImgDir 'a.png'; New-TestPng $script:PngA 100 100
        $script:PngB = Join-Path $script:ImgDir 'b changed.png'; New-TestPng $script:PngB 100 100 @(70, 70, 10, 10)
        $script:PngBig = Join-Path $script:ImgDir 'big.png'; New-TestPng $script:PngBig 200 200
        function Snap($img) { [pscustomobject]@{ Controls = @(); Msaa = @(); Image = $img } }
    }
    It 'hands py -3.14 the script, pair, both images, --mask and every --expect rect' {
        # A test-scoped py shadows the launcher, so the argv is asserted, not the source text.
        function py { $script:PyArgs = @($args); '{"changed_tiles": 0, "in_scope": [], "out_of_scope": [], "missing_expected": []}' }
        $r = Invoke-SwdProbeImageDiff -BeforeImage 'b4 x.png' -AfterImage 'af.png' -Mask 'm.npy' -ExpectRects @(@(1, 2, 3, 4), @(5, 6, 7, 8))
        $got = @($script:PyArgs | ForEach-Object { "$_" })
        $got[0] | Should -BeExactly '-3.14'
        $got[1] | Should -BeExactly (Join-Path $script:ProbeRoot 'swd_diff.py')
        ($got[2..4] -join '|') | Should -BeExactly 'pair|b4 x.png|af.png'
        ($got[5..6] -join '|') | Should -BeExactly '--mask|m.npy'
        ($got[7..9] -join '|') | Should -BeExactly '--expect|1,2,3,4|5,6,7,8'
        $got.Count | Should -Be 10
        $r.changed_tiles | Should -Be 0
    }
    It 'leaves out --mask and --expect when there are none, and skips a malformed rect' {
        function py { $script:PyArgs = @($args); '{"changed_tiles": 0, "in_scope": [], "out_of_scope": [], "missing_expected": []}' }
        [void](Invoke-SwdProbeImageDiff -BeforeImage 'a.png' -AfterImage 'b.png' -ExpectRects @(, @(1, 2, 3)))
        @($script:PyArgs | ForEach-Object { "$_" }) -join '|' | Should -BeExactly ('-3.14|' + (Join-Path $script:ProbeRoot 'swd_diff.py') + '|pair|a.png|b.png')
    }
    It 'the real interpreter puts a change inside an expected rect in scope, and outside it out of scope' {
        $in = Invoke-SwdProbeImageDiff -BeforeImage $script:PngA -AfterImage $script:PngB -ExpectRects @(, @(64, 64, 36, 36))
        @($in.in_scope).Count | Should -Be 1
        @($in.out_of_scope).Count | Should -Be 0
        $out = Invoke-SwdProbeImageDiff -BeforeImage $script:PngA -AfterImage $script:PngB -ExpectRects @(, @(0, 0, 32, 32))
        @($out.out_of_scope).Count | Should -Be 1
        @($out.missing_expected).Count | Should -Be 1
    }
    It 'a failed diff (images of different sizes) comes back as data under Stop and never throws' {
        $ErrorActionPreference = 'Stop'
        { $script:R = Invoke-SwdProbeImageDiff -BeforeImage $script:PngA -AfterImage $script:PngBig } | Should -Not -Throw
        $script:R.PSObject.Properties['out_of_scope'] | Should -BeNullOrEmpty
        $script:R.Error | Should -Match 'shape mismatch'
    }
    It 'a warning on stderr does not spoil a good diff, even under Stop' {
        # A real interpreter that writes to stderr at start-up and still exits 0: stderr must
        # be kept apart from the JSON, never turned into a failure (W2).
        $site = Join-Path $TestDrive 'site warn'
        New-Item -ItemType Directory -Force -Path $site | Out-Null
        [IO.File]::WriteAllText((Join-Path $site 'sitecustomize.py'), "import sys`nsys.stderr.write('UserWarning: something upstream is deprecated\n')`n")
        $saved = $env:PYTHONPATH
        try {
            $env:PYTHONPATH = $site
            $ErrorActionPreference = 'Stop'
            $r = Invoke-SwdProbeImageDiff -BeforeImage $script:PngA -AfterImage $script:PngB
            $r.PSObject.Properties['Error'] | Should -BeNullOrEmpty
            $r.changed_tiles | Should -Be 1
        } finally { $env:PYTHONPATH = $saved }
    }
    It 'a runner that does not run, or answers with no result, comes back as data too' {
        function py { throw 'launcher missing' }
        (Invoke-SwdProbeImageDiff -BeforeImage 'a.png' -AfterImage 'b.png').Error | Should -Match 'did not run: launcher missing'
        function py { 'not json at all' }
        (Invoke-SwdProbeImageDiff -BeforeImage 'a.png' -AfterImage 'b.png').Error | Should -Match 'no usable result'
    }
    It 'Compare-SwdProbeSnapshot reports a failed image diff as DETECTOR FAILED, with a $null count, never 0' {
        $ErrorActionPreference = 'Stop'
        $d = Compare-SwdProbeSnapshot -Before (Snap $script:PngA) -After (Snap $script:PngBig)
        $null -eq $d.OutOfScopeCount | Should -BeTrue
        $d.ImageError | Should -Match 'shape mismatch'
        (Format-SwdProbeDiff $d) -join "`n" | Should -Match 'DETECTOR FAILED'
    }
    It 'a working diff still counts its changes and carries no ImageError' {
        $d = Compare-SwdProbeSnapshot -Before (Snap $script:PngA) -After (Snap $script:PngB)
        $d.OutOfScopeCount | Should -Be 1
        $d.ImageError | Should -BeNullOrEmpty
    }
    It 'the failure text names no username or tenant (R9), though Python doubles the backslashes' {
        $saved = $env:OneDriveCommercial
        $fake = Join-Path $TestDrive 'OneDrive - Contoso Fixture Tenant'
        New-Item -ItemType Directory -Force -Path $fake | Out-Null
        try {
            $env:OneDriveCommercial = $fake
            $d = Compare-SwdProbeSnapshot -Before (Snap (Join-Path $fake 'no such frame.png')) -After (Snap $script:PngA)
            $d.ImageError | Should -Not -BeNullOrEmpty
            $d.ImageError | Should -Not -Match 'Contoso Fixture Tenant'
            $d.ImageError | Should -Not -Match ([regex]::Escape($env:USERPROFILE))
            $d.ImageError | Should -Match ([regex]::Escape('~\OneDrive\no such frame.png'))
        } finally { $env:OneDriveCommercial = $saved }
    }
    It 'T12 reports Exact as unknown, not true or false, when the image detector failed' {
        Mock Get-SwdProbeMain { [pscustomobject]@{ Handle = 1; Title = 'FYN' } }
        Mock Get-SwdProbeSnapshot { [pscustomobject]@{ Title = 'FYN'; Origin = @(0, 0) } }
        Mock Get-SwdProbeLengthContext { [pscustomobject]@{ LengthMm = 2000.0 } }
        Mock Set-SwdProbeLength { [pscustomobject]@{ Applied = $false } }
        Mock Find-SwdProbeNoiseMask { $null }
        Mock Compare-SwdProbeSnapshot { [pscustomobject]@{ OutOfScopeCount = $null; ImageError = 'boom'; OutOfScope = [pscustomobject]@{ Win32 = @(); Msaa = @(); ImageBoxes = @() } } }
        $r = Invoke-SwdProbeT12 -RunDir $TestDrive -StopFile (Join-Path $TestDrive 'STOP-t12') -DeltaMm 1
        $null -eq $r.Exact | Should -BeTrue
        $null -eq $r.Residual | Should -BeTrue
        $r.Lines -join "`n" | Should -Match 'DETECTOR FAILED'
    }
    It 'T14 reports both controls as unknown when an image detector failed' {
        Mock Get-SwdProbeMain { [pscustomobject]@{ Handle = 1; Title = 'FYN' } }
        Mock Get-SwdProbeSnapshot { [pscustomobject]@{ Title = 'FYN'; Origin = @(0, 0) } }
        Mock Get-SwdProbeLengthContext { [pscustomobject]@{ LengthMm = 2000.0; ExpectHandles = @(1); LengthText = '2000'; ExpectRect = @(0, 0, 1, 1) } }
        Mock Set-SwdProbeLength { [pscustomobject]@{ Applied = $true; Settle = [pscustomobject]@{ SettleMs = 1 } } }
        Mock Find-SwdProbeNoiseMask { $null }
        Mock Start-Sleep { }
        Mock Assert-SwdProbeContinue { }
        Mock Compare-SwdProbeSnapshot { [pscustomobject]@{ Win32 = @(); Msaa = @(); OutOfScopeCount = $null; InScopeCount = 0; ImageError = 'boom'; OutOfScope = [pscustomobject]@{ Win32 = @(); Msaa = @(); ImageBoxes = @() } } }
        $r = Invoke-SwdProbeT14 -RunDir $TestDrive -StopFile (Join-Path $TestDrive 'STOP-t14') -DeltaMm 1
        $null -eq $r.NegativeClean | Should -BeTrue
        $null -eq $r.PositiveDetected | Should -BeTrue
    }
}

Describe 'input sweep (2026-10-01): allowlist additions keep the denylist on top' {
    It 'allows the renamed Apply Volume caption by anchored pattern: <_>' -ForEach @('Set 10 liters volume to board', 'Set 40,7 liters volume to board', '&Set 3.5 liters volume to board') {
        Test-SwdProbeAllowedButton $_ | Should -BeTrue
    }
    It 'refuses near-misses of the volume pattern: <_>' -ForEach @('Set 10 liters volume to board and save', 'Set ten liters volume to board', 'Reset 10 liters volume to board', 'Set 10 liters volume to boards') {
        Test-SwdProbeAllowedButton $_ | Should -BeFalse
    }
    It 'still refuses a bare Apply' { Test-SwdProbeAllowedButton 'Apply' | Should -BeFalse }
    It 'allows the Board Dynamics tabs: <_>' -ForEach @('Test Position', 'Elements;analysis', 'Dashboard', 'Spoon') { Test-SwdProbeAllowedTab $_ | Should -BeTrue }
    It 'still refuses <_>' -ForEach @('Shaper;Report', 'Board;Aspect', 'CNC', 'SurfCommunity(Off)') { Test-SwdProbeAllowedTab $_ | Should -BeFalse }
}

Describe 'input sweep: MSAA action policy (Invoke-SwdProbeAcc)' {
    BeforeAll {
        $script:Calls = New-Object System.Collections.Generic.List[string]
        $script:Node = { param($status, $da, $cnt) [pscustomobject]@{ Status = $status; Matches = $cnt; Name = 'n'; Value = 'v'; Role = '36'; State = 0; DefaultAction = $da } }
        $script:Still = { @(5, 5) }
    }
    BeforeEach { $script:Calls.Clear() }
    It 'reads anything without acting' {
        $nat = { param($h, $n, $r, $i, $a, $v) $script:Calls.Add($a); & $script:Node 'ok' 'Press' 1 }
        (Invoke-SwdProbeAcc -Handle 1 -Name 'Delete hydroscan' -Native $nat -CursorReader $script:Still).Status | Should -Be 'ok'
        $script:Calls -join ',' | Should -Be 'read'
    }
    It 'refuses a default action that is not on the MSAA allowlist, before any call' {
        $nat = { param($h, $n, $r, $i, $a, $v) $script:Calls.Add($a); & $script:Node 'ok' 'Press' 1 }
        { Invoke-SwdProbeAcc -Handle 1 -Name 'Hydrodynamics Scanner' -Action default -Native $nat -CursorReader $script:Still } | Should -Throw '*not on the MSAA allowlist*'
        $script:Calls.Count | Should -Be 0
    }
    It 'performs the allowlisted default action after a read' {
        $nat = { param($h, $n, $r, $i, $a, $v) $script:Calls.Add($a); & $script:Node 'ok' 'Press' 1 }
        (Invoke-SwdProbeAcc -Handle 1 -Name 'Board Dynamics' -Action default -Native $nat -CursorReader $script:Still).Status | Should -Be 'ok'
        $script:Calls -join ',' | Should -Be 'read,default'
    }
    It 'expands a tree item only when its own default action is Expand' {
        $nat = { param($h, $n, $r, $i, $a, $v) $script:Calls.Add("$a/$r"); & $script:Node 'ok' 'Collapse' 1 }
        (Invoke-SwdProbeAcc -Handle 1 -Name '11 HydroScans' -Action expand -Native $nat -CursorReader $script:Still).Status | Should -Match 'not-expandable'
        $script:Calls -join ',' | Should -Be 'read/36'
    }
    It 'refuses an ambiguous name unless told otherwise' {
        $nat = { param($h, $n, $r, $i, $a, $v) $script:Calls.Add($a); & $script:Node 'ok' 'Expand' 2 }
        { Invoke-SwdProbeAcc -Handle 1 -Name 'Statics fins' -Action expand -Native $nat -CursorReader $script:Still } | Should -Throw '*matches 2*'
        $script:Calls -join ',' | Should -Be 'read'
    }
    It 'refuses to set a value not on the caller list, and a denylisted one even if listed' {
        $nat = { param($h, $n, $r, $i, $a, $v) $script:Calls.Add($a); & $script:Node 'ok' '' 1 }
        { Invoke-SwdProbeAcc -Handle 1 -Name 'Ra_micron' -Action setvalue -Value '5' -Native $nat -CursorReader $script:Still } | Should -Throw '*set-value list*'
        { Invoke-SwdProbeAcc -Handle 1 -Name 'Delete_me' -Action setvalue -Value '5' -AllowedSetValue @('Delete_me') -Native $nat -CursorReader $script:Still } | Should -Throw '*set-value list*'
        $script:Calls.Count | Should -Be 0
    }
    It 'stops when an action moves the cursor (it simulated input)' {
        $nat = { param($h, $n, $r, $i, $a, $v) & $script:Node 'ok' 'Press' 1 }
        $script:Pos = 0
        $moving = { $script:Pos++; @($script:Pos, 0) }
        { Invoke-SwdProbeAcc -Handle 1 -Name 'Board Dynamics' -Action default -Native $nat -CursorReader $moving } | Should -Throw 'SWD-PROBE-CURSOR-MOVED*'
    }
}

Describe 'input sweep: toggle guard' {
    It 'accepts a check box (44) and a radio button (45)' {
        (Assert-SwdProbeToggle -Handle 7 -Reader { param($h) [pscustomobject]@{ Role = '44'; Name = 'Forces' } }).Name | Should -Be 'Forces'
        (Assert-SwdProbeToggle -Handle 7 -Reader { param($h) [pscustomobject]@{ Role = '45'; Name = 'Static' } }).Name | Should -Be 'Static'
    }
    It 'refuses a push button, even one whose style looks like a toggle' {
        { Assert-SwdProbeToggle -Handle 7 -Reader { param($h) [pscustomobject]@{ Role = '43'; Name = 'Apply' } } } | Should -Throw '*not a check box or radio button*'
    }
    It 'refuses an unreadable control and a denylisted caption' {
        { Assert-SwdProbeToggle -Handle 7 -Reader { param($h) $null } } | Should -Throw
        { Assert-SwdProbeToggle -Handle 7 -Reader { param($h) [pscustomobject]@{ Role = '44'; Name = 'Export STL' } } } | Should -Throw '*denylisted*'
    }
}

Describe 'input sweep: values, ladders, dialogs (pure)' {
    It 'numeric values are +-10%, never the base, invariant culture' {
        @(Get-SwdSweepValue -Kind numeric -Base '1840') | Should -Be @('2024', '1656')
        @(Get-SwdSweepValue -Kind numeric -Base '4.291') | Should -Be @('4.7201', '3.8619')
        @(Get-SwdSweepValue -Kind numeric -Base '0') | Should -Be @('1', '-1')
    }
    It 'numeric values are clamped to a known range and deduplicated' {
        @(Get-SwdSweepValue -Kind numeric -Base '10' -Min 0 -Max 10) | Should -Be @('9')
        @(Get-SwdSweepValue -Kind numeric -Base '0' -Min 0 -Max 5) | Should -Be @('1')
    }
    It 'non-numeric and bool bases' {
        @(Get-SwdSweepValue -Kind numeric -Base 'abc').Count | Should -Be 0
        @(Get-SwdSweepValue -Kind bool -Base 'False') | Should -Be @('True')
        @(Get-SwdSweepValue -Kind check -Base 'True') | Should -Be @('toggle')
    }
    It 'index kinds take the other options, capped' {
        @(Get-SwdSweepValue -Kind combo -Base '1' -Options @('0', '1', '2')) | Should -Be @('0', '2')
        @(Get-SwdSweepValue -Kind radio -Base 'A' -Options @('A', 'B')) | Should -Be @('B')
        @(Get-SwdSweepValue -Kind combo -Base '0' -Options @(0..20 | ForEach-Object { "$_" }) -MaxOptions 3).Count | Should -Be 3
    }
    It 'the curve ladder is ascending, clamped and excludes the base' {
        @(Get-SwdSweepCurveLevel -Base 10) | Should -Be @('5', '7.5', '9', '11', '12.5', '15')
        @(Get-SwdSweepCurveLevel -Base 0 -Min 0) | Should -Be @('1', '2', '3')
    }
    It 'a dialog is declined or cancelled, never confirmed' {
        Select-SwdSweepDialogAction -Title 'Save?' -Buttons @('&Yes', '&No', 'Cancel') | Should -Be 'Cancel'
        Select-SwdSweepDialogAction -Title 'Delete this hydroscan?' -Buttons @('&Yes', '&No') | Should -Be 'No'
        Select-SwdSweepDialogAction -Title 'Fermer' -Buttons @('Oui', 'Non') | Should -Be 'Non'
    }
    It 'a lone OK is pressed only on an information box' {
        Select-SwdSweepDialogAction -Title 'SWD' -Texts @('Value out of range') -Buttons @('OK') | Should -Be 'OK'
        $null -eq (Select-SwdSweepDialogAction -Title 'SWD' -Texts @('HydroScan can takes more than 60 mn') -Buttons @('OK')) | Should -BeTrue
        $null -eq (Select-SwdSweepDialogAction -Title 'Export' -Buttons @('OK')) | Should -BeTrue
    }
    It 'anything else stops the run' {
        $null -eq (Select-SwdSweepDialogAction -Title 'x' -Buttons @('&Yes')) | Should -BeTrue
        $null -eq (Select-SwdSweepDialogAction -Title 'x' -Buttons @('Retry', 'Ignore')) | Should -BeTrue
        $null -eq (Select-SwdSweepDialogAction -Title 'x' -Buttons @()) | Should -BeTrue
    }
    It 'tab steps keep only allowlisted tabs, outermost first' {
        @(Get-SwdSweepTabStep 'Shape|Guides Sections') | Should -Be @('Shape', 'Guides Sections')
        @(Get-SwdSweepTabStep 'Fins|Fins set ') | Should -Be @('Fins')
        @(Get-SwdSweepTabStep 'Shaper;Report').Count | Should -Be 0
        @(Get-SwdSweepTabStep '').Count | Should -Be 0
    }
}

Describe 'input sweep: manifest from census rows (pure)' {
    BeforeAll {
        function New-Row($kind, $type, $aid, $parents, $extra = @{}) {
            $o = [ordered]@{ Kind = $kind; Type = $type; AutomationId = $aid; Parents = $parents; Name = "$aid"; TabPath = 'SizeConfig'; Value = '1840'; Enabled = $true }
            foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] }
            [pscustomobject]$o
        }
        $script:Rows = @(
            (New-Row 'input:text' 'Edit' 'TextBox_board_length_mm' '/F/G_len')
            (New-Row 'button' 'Button' 'Button_appliquer_longuer' '/F/G_len' @{ Name = 'Apply Length' })
            (New-Row 'button' 'Button' 'Button_basic_hydro_scan' '/F/G_len' @{ Name = 'Hydrodynamics Scanner' })
            (New-Row 'input:text' 'Edit' 'TextBox_description_project_object_select' '/F' @{ Value = 'Scaned drifts' })
            (New-Row 'input:text' 'Edit' 'TextBox_note' '/F' @{ Value = 'free text' })
            (New-Row 'input:text' 'Edit' '8392322' '/F' @{ Value = '10' })
            (New-Row 'input:numeric' 'Edit' '24380102' '/F/NumericUpDown_box_y_Offset_mm' @{ SpinnerOf = 'NumericUpDown_box_y_Offset_mm'; SpinnerRange = [pscustomobject]@{ Min = -50; Max = 50 } })
            (New-Row 'input:toggle' 'RadioButton' 'RadioButtonWidth_mm' '/F/G_w')
            (New-Row 'input:toggle' 'RadioButton' 'RadioButtonWidth_inch' '/F/G_w')
            (New-Row 'input:toggle' 'RadioButton' 'RadioButtonLonely' '/F/G_one')
            (New-Row 'input:toggle' 'CheckBox' 'CheckBox_planing_forces' '/F/E')
            (New-Row 'input:combo' 'ComboBox' 'ComboBox_tail_bevel' '/F/G_b')
        )
        $script:Man = @(ConvertTo-SwdSweepInput -Rows $script:Rows -Mode 'S')
    }
    It 'pairs an input with the allowlisted Apply in its own container, never a denied button' {
        $len = @($script:Man | Where-Object Target -eq 'TextBox_board_length_mm')[0]
        $len.Apply | Should -Be 'Button_appliquer_longuer'
        $len.Kind | Should -Be 'numeric'
        $len.Id | Should -Be 'S/TextBox_board_length_mm'
    }
    It 'leaves out skip-listed, free-text and unnamed controls' {
        @($script:Man | Where-Object { $_.Target -in 'TextBox_description_project_object_select', 'TextBox_note', '8392322' }).Count | Should -Be 0
    }
    It 'addresses a spinner by its designer name and keeps its range' {
        $sp = @($script:Man | Where-Object Target -eq 'NumericUpDown_box_y_Offset_mm')[0]
        $sp.Min | Should -Be -50
        $sp.Max | Should -Be 50
    }
    It 'groups radio buttons by container and drops a group of one' {
        $g = @($script:Man | Where-Object Kind -eq 'radio')
        $g.Count | Should -Be 1
        @($g[0].Options) | Should -Be @('RadioButtonWidth_mm', 'RadioButtonWidth_inch')
    }
    It 'keeps check boxes and combos' {
        @($script:Man | Where-Object Kind -eq 'check').Count | Should -Be 1
        @($script:Man | Where-Object Kind -eq 'combo').Count | Should -Be 1
    }
    It 'the plan runs S before D, Volume last within S, each value twice' {
        $man = @(
            [pscustomobject]@{ Id = 'D/a'; Mode = 'D'; Target = 'a'; Values = @('1') }
            [pscustomobject]@{ Id = 'S/NumericUpDownBoardVolumeInput'; Mode = 'S'; Target = 'NumericUpDownBoardVolumeInput'; Values = @('11') }
            [pscustomobject]@{ Id = 'S/len'; Mode = 'S'; Target = 'len'; Values = @('2', '3') }
        )
        @(Get-SwdSweepPlan -Manifest $man | ForEach-Object { $_.Id }) | Should -Be @(
            'S/len|2|r1', 'S/len|2|r2', 'S/len|3|r1', 'S/len|3|r2', 'S/NumericUpDownBoardVolumeInput|11|r1', 'S/NumericUpDownBoardVolumeInput|11|r2', 'D/a|1|r1', 'D/a|1|r2')
    }
    It 'change keys are stable and unique' {
        $c = @([pscustomobject]@{ Ch = 'msaa'; Owner = 'G'; Item = 'vertical_force_n'; Field = 'Value' }, [pscustomobject]@{ Ch = 'msaa'; Owner = 'G'; Item = 'vertical_force_n'; Field = 'Value' }, $null)
        @(Get-SwdSweepChangeKey $c) | Should -Be @('msaa|G|vertical_force_n|Value')
    }
}

Describe 'a failed window capture is a failed detector, not zero changes (SQA NEW-1)' {
    It 'Compare-SwdProbeSnapshot gives a $null count and an ImageError when either capture failed' {
        $ok = [pscustomobject]@{ Controls = @(); Msaa = @(); Image = $null; ImageFailed = $false }
        $bad = [pscustomobject]@{ Controls = @(); Msaa = @(); Image = $null; ImageFailed = $true }
        $d = Compare-SwdProbeSnapshot -Before $ok -After $bad
        $null -eq $d.OutOfScopeCount | Should -BeTrue
        $d.ImageError | Should -Match 'capture failed'
        $null -eq (Compare-SwdProbeSnapshot -Before $bad -After $ok).OutOfScopeCount | Should -BeTrue
        (Compare-SwdProbeSnapshot -Before $ok -After $ok).OutOfScopeCount | Should -Be 0
    }
}
Describe 'input sweep: a relaunch censuses only the modes still owed work' {
    It 'lists the modes with trials left, and both when none are left or the pass is not Map' {
        $man = @([pscustomobject]@{ Id = 'S/a'; Mode = 'S'; Target = 'a'; Values = @('1') }, [pscustomobject]@{ Id = 'D/b'; Mode = 'D'; Target = 'b'; Values = @('2') })
        $ctx = [pscustomobject]@{ Manifest = $man; Done = @{ 'S/a|1|r1' = $true; 'S/a|1|r2' = $true } }
        @(Get-SwdSweepModesLeft -Ctx $ctx) | Should -Be @('D')
        $ctx.Done['D/b|2|r1'] = $true; $ctx.Done['D/b|2|r2'] = $true
        @(Get-SwdSweepModesLeft -Ctx $ctx) | Should -Be @('S', 'D')
        @(Get-SwdSweepModesLeft -Ctx $ctx -Pass 'Curve').Count | Should -Be 0
        @(Get-SwdSweepModesLeft -Ctx $ctx -Pass 'Census') | Should -Be @('S', 'D')
    }
}
Describe 'input sweep: Apply-situation levels end on the original value' {
    It 'flow speed: the ladder, then 20 m/s (the hydroscan speed), then the base last' {
        @(Get-SwdSweepSituationLevel -Base 10 -Target 'TextBox_speed_ms') | Should -Be @('5', '7.5', '9', '11', '12.5', '15', '20', '10')
    }
    It 'slope from zero: -3..3 without 0, then 0 last' {
        @(Get-SwdSweepSituationLevel -Base 0 -Target 'TextBox_relative_flow_pente_deg') | Should -Be @('-3', '-2', '-1', '1', '2', '3', '0')
    }
    It 'the Situation pass censuses only Board Dynamics mode' {
        @(Get-SwdSweepModesLeft -Ctx ([pscustomobject]@{ Manifest = @(); Done = @{} }) -Pass 'Situation') | Should -Be @('D')
    }
}
Describe 'input sweep: geometry ladders stay within +-10%' {
    It 'takes explicit factors' {
        @(Get-SwdSweepCurveLevel -Base 2000 -Factors @(0.9, 0.95, 0.975, 1.025, 1.05, 1.1)) | Should -Be @('1800', '1900', '1950', '2050', '2100', '2200')
    }
}
Describe 'live solver: Project-tree names (pure)' {
    It 'reads SWD''s own spellings, degree sign included' {
        $deg = [string][char]0x00B0
        (ConvertFrom-SwdSolverNode '11 HydroScans').Kind | Should -Be 'root'
        $d = ConvertFrom-SwdSolverNode "Analyse Positions drift 15$deg"; $d.Kind | Should -Be 'drift'; $d.Value | Should -Be 15
        $y = ConvertFrom-SwdSolverNode 'Positons Y 0.027'; $y.Kind | Should -Be 'y'; $y.Value | Should -Be 0.027
        $x = ConvertFrom-SwdSolverNode 'Positon X 0.467'; $x.Kind | Should -Be 'x'; $x.Value | Should -Be 0.467
        (ConvertFrom-SwdSolverNode 'Positions Y 0').Kind | Should -Be 'y'
    }
    It 'returns null for anything else: <_>' -ForEach @('Board: default_shortboard_Copy_1', 'Rails 0', 'Positon X abc', 'Positon X 0.4 7', 'HydroScans', '') {
        ConvertFrom-SwdSolverNode $_ | Should -BeNullOrEmpty
    }
    It 'reads the analysis tree element and compares it with a position' {
        $e = ConvertFrom-SwdSolverElement ("Drift 0" + [char]0x00B0 + "`r`nPos Y=0.027 X=0.467")
        $e.Drift | Should -Be 0; $e.Y | Should -Be 0.027; $e.X | Should -Be 0.467
        Test-SwdSolverElementIs -Element $e -Position ([pscustomobject]@{ Drift = 0; Y = 0.027; X = 0.467 }) | Should -BeTrue
        Test-SwdSolverElementIs -Element $e -Position ([pscustomobject]@{ Drift = 0; Y = 0; X = 0.467 }) | Should -BeFalse
        Test-SwdSolverElementIs -Element $null -Position ([pscustomobject]@{ Drift = 0; Y = 0; X = 0.467 }) | Should -BeFalse
        ConvertFrom-SwdSolverElement 'Details element0' | Should -BeNullOrEmpty
    }
    It 'matches the analysis tree''s negative Y to the Project tree''s positive label' {
        $e = ConvertFrom-SwdSolverElement ('Drift 0' + [char]0x00B0 + "`r`nPos Y=-0.027 X=0.4")
        $e.Y | Should -Be -0.027
        Test-SwdSolverElementIs -Element $e -Position ([pscustomobject]@{ Drift = 0; Y = 0.027; X = 0.4 }) | Should -BeTrue
        Test-SwdSolverElementIs -Element $e -Position ([pscustomobject]@{ Drift = 0; Y = 0.054; X = 0.4 }) | Should -BeFalse
        $m = ConvertFrom-SwdSolverElement ('Drift -2' + [char]0x00B0 + "`r`nPos Y=-0.027 X=0.15")
        Test-SwdSolverElementIs -Element $m -Position ([pscustomobject]@{ Drift = 2; Y = 0.027; X = 0.15 }) | Should -BeTrue
        Test-SwdSolverElementIs -Element $m -Position ([pscustomobject]@{ Drift = 5; Y = 0.027; X = 0.15 }) | Should -BeFalse
    }
}
Describe 'live solver: position list from a tree walk (pure)' {
    BeforeAll {
        $deg = [string][char]0x00B0
        $script:TreeNodes = @('Wave', 'Positon X 9', 'Board: b_Copy_1', '11 HydroScans', "Analyse Positions drift 0$deg", 'Positons Y 0', 'Positon X 0.1', 'Positon X 0.467',
                              'Positons Y 0.027', 'Positon X 0.1', "Analyse Positions drift 30$deg", 'Positons Y 0', 'Positon X 0.1') |
                            ForEach-Object { [pscustomobject]@{ Role = '36'; Name = $_ } }
        $script:TreeNodes = @([pscustomobject]@{ Role = '35'; Name = 'Positon X 0.1' }) + $script:TreeNodes
    }
    It 'keeps Pos X items under the root, in tree order, within MaxDrift' {
        $p = @(Get-SwdSolverPositionList -Nodes $script:TreeNodes -MaxDrift 20)
        $p.Count | Should -Be 3
        ($p | ForEach-Object { '{0}|{1}|{2}' -f $_.Drift, $_.Y, $_.X }) | Should -Be @('0|0|0.1', '0|0|0.467', '0|0.027|0.1')
    }
    It 'numbers repeated names the way Act finds them (role 36 only, tree order)' {
        $p = @(Get-SwdSolverPositionList -Nodes $script:TreeNodes -MaxDrift 90)
        $p.Count | Should -Be 4
        ($p | ForEach-Object { $_.Nth }) | Should -Be @(0, 0, 1, 2)
        $p[3].YNode.Name | Should -Be 'Positons Y 0'; $p[3].YNode.Nth | Should -Be 1
        $p[3].DriftNode.Value | Should -Be 30
    }
    It 'returns nothing for an empty walk' {
        @(Get-SwdSolverPositionList -Nodes @()).Count | Should -Be 0
    }
}
Describe 'live solver: levels, plan and resume (pure)' {
    It 'blocks run speed-major, slope inside' {
        @(Get-SwdSolverBlock -Speeds @('5', '10') -Slopes @('-3', '0') | ForEach-Object { $_.Id }) | Should -Be @('v=5|s=-3', 'v=5|s=0', 'v=10|s=-3', 'v=10|s=0')
    }
    It 'splits a comma list handed over as one argument' {
        @(ConvertTo-SwdSolverLevel @('5,10,20')) | Should -Be @('5', '10', '20')
        @(ConvertTo-SwdSolverLevel @('-3', '0', '3')) | Should -Be @('-3', '0', '3')
    }
    It 'types only plain decimal numbers: <_>' -ForEach @('-3', '12.5', '0', '20', '-30') {
        (ConvertTo-SwdSolverKey -Value $_) -join '' | Should -Be $_
    }
    It 'refuses anything else: <_>' -ForEach @('', '1,5', '12.5.1', '1234', ' 5', '+5', 'Enter', '5%', '1e3', ([string][char]0x0663), ([string][char]0xFF15)) {
        { ConvertTo-SwdSolverKey -Value $_ } | Should -Throw
    }
    It 'refuses a bad level in a list' {
        { ConvertTo-SwdSolverLevel @('5,abc') } | Should -Throw
    }
    It 'maps a read number to block and position' {
        $c = Get-SwdSolverCursor -Cursor 0 -Positions 272; $c.Block | Should -Be 0; $c.Position | Should -Be 0
        $c = Get-SwdSolverCursor -Cursor 271 -Positions 272; $c.Block | Should -Be 0; $c.Position | Should -Be 271
        $c = Get-SwdSolverCursor -Cursor 272 -Positions 272; $c.Block | Should -Be 1; $c.Position | Should -Be 0
        { Get-SwdSolverCursor -Cursor 1 -Positions 0 } | Should -Throw
    }
    It 'fingerprints the plan: same input same print, any change a new one' {
        $pos = @([pscustomobject]@{ Drift = 0; Y = 0; X = 0.1 }, [pscustomobject]@{ Drift = 0; Y = 0; X = 0.467 })
        $a = Get-SwdSolverFingerprint -Board 'b' -Speeds @('5', '10') -Slopes @('0') -Positions $pos
        Get-SwdSolverFingerprint -Board 'b' -Speeds @('5', '10') -Slopes @('0') -Positions $pos | Should -Be $a
        Get-SwdSolverFingerprint -Board 'b' -Speeds @('5', '11') -Slopes @('0') -Positions $pos | Should -Not -Be $a
        Get-SwdSolverFingerprint -Board 'b' -Speeds @('5', '10') -Slopes @('0') -Positions @($pos[0]) | Should -Not -Be $a
        Get-SwdSolverFingerprint -Board 'c' -Speeds @('5', '10') -Slopes @('0') -Positions $pos | Should -Not -Be $a
    }
}
Describe 'live solver: read comparison and records (pure)' {
    It 'names the rows that differ, missing rows included, case-sensitively' {
        $a = [ordered]@{ Fx_friction_n = '122.071617'; Name = 'abc' }
        @(Compare-SwdSolverRow -A $a -B ([ordered]@{ Fx_friction_n = '122.071617'; Name = 'abc' })).Count | Should -Be 0
        @(Compare-SwdSolverRow -A $a -B ([ordered]@{ Fx_friction_n = '122.07'; Name = 'abc' })) | Should -Be @('Fx_friction_n')
        @(Compare-SwdSolverRow -A $a -B ([ordered]@{ Fx_friction_n = '122.071617' })) | Should -Be @('Name')
        @(Compare-SwdSolverRow -A $a -B ([ordered]@{ Fx_friction_n = '122.071617'; Name = 'ABC' })) | Should -Be @('Name')
    }
    It 'relative difference, null when it cannot be computed' {
        Get-SwdSolverRelDiff '101' '100' | Should -BeLessThan 0.0100001
        Get-SwdSolverRelDiff '101' '100' | Should -BeGreaterThan 0.0099999
        Get-SwdSolverRelDiff 'x' '100' | Should -BeNullOrEmpty
        Get-SwdSolverRelDiff '1' '0' | Should -BeNullOrEmpty
    }
    It 'builds the record a read is stored as' {
        $read = [pscustomobject]@{ Rows = [ordered]@{ portance_globale_verticale_n = '807.3515'; Fx_friction_n = '122.071617' }; ElementName = 'Drift 0'; Match = $true
                                   SameAsPrevious = $false; SelectMs = 90; SettleMs = 1100; ReadMs = 300 }
        $r = ConvertTo-SwdSolverRecord -Board 'b_Copy_1' -Speed '10' -Slope '0' -Position ([pscustomobject]@{ Drift = 0; Y = 0; X = 0.467 }) -Read $read -Seq 7
        $r.Seq | Should -Be 7; $r.Lift | Should -Be '807.3515'; $r.X | Should -Be 0.467; $r.ElementMatch | Should -BeTrue
        @($r.PSObject.Properties.Name) | Should -Be @('Seq', 'Board', 'Speed', 'Slope', 'Drift', 'Y', 'X', 'ElementMatch', 'Element', 'Lift', 'SameAsPrevious', 'SelectMs', 'SettleMs', 'ReadMs', 'Rows', 'Time')
    }
    It 'spells the total-drag row with its accent' {
        $script:SolverDragRow | Should -Be ('train' + [char]0x00E9 + 'e_globale_horizontale_n')
    }
    It 'carries the 2026-10-01 reference for 8 speeds and 7 slopes' {
        $script:SolverReference.Count | Should -Be 14
        @($script:SolverReference | Where-Object { $_.Speed -eq '10' -and $_.Slope -eq '0' })[0].Friction | Should -Be 122.071617
    }
}
Describe 'live solver: tree items scrolled out of view (Invoke-SwdProbeAcc -Offscreen)' {
    BeforeAll {
        $script:OffCalls = New-Object System.Collections.Generic.List[string]
        $script:OffNode = { param($status, $da) [pscustomobject]@{ Status = $status; Matches = 1; Name = 'n'; Value = '4'; Role = '36'; State = 0x8000; DefaultAction = $da } }
        $script:OffStill = { @(5, 5) }
    }
    BeforeEach { $script:OffCalls.Clear() }
    It 'selects through the native tree verbs: read-tree, then select-tree' {
        $nat = { param($h, $n, $r, $i, $a, $v) $script:OffCalls.Add("$a/$r/$i"); & $script:OffNode 'ok' 'Expand' }
        (Invoke-SwdProbeAcc -Handle 1 -Name 'Positon X 0.467' -Nth 2 -Action select -Offscreen -Native $nat -CursorReader $script:OffStill).Status | Should -Be 'ok'
        $script:OffCalls -join ',' | Should -Be 'read-tree/36/2,select-tree/36/2'
    }
    It 'expands through default-tree, still only when the default action is Expand' {
        $nat = { param($h, $n, $r, $i, $a, $v) $script:OffCalls.Add($a); & $script:OffNode 'ok' 'Expand' }
        (Invoke-SwdProbeAcc -Handle 1 -Name 'Positons Y 0' -Action expand -Offscreen -Native $nat -CursorReader $script:OffStill).Status | Should -Be 'ok'
        $script:OffCalls -join ',' | Should -Be 'read-tree,default-tree'
    }
    It 'refuses -Offscreen with any other action, before any call: <_>' -ForEach @('read', 'default', 'setvalue') {
        $nat = { param($h, $n, $r, $i, $a, $v) $script:OffCalls.Add($a); & $script:OffNode 'ok' 'Press' }
        { Invoke-SwdProbeAcc -Handle 1 -Name 'Board Dynamics' -Action $_ -Value '1' -AllowedSetValue @('Board Dynamics') -Offscreen -Native $nat -CursorReader $script:OffStill } | Should -Throw '*-Offscreen applies*'
        $script:OffCalls.Count | Should -Be 0
    }
}
Describe 'live solver: native tree verbs and list box (in-process windows)' {
    # Reaching a scrolled-out item is verified live only: an IN-PROCESS WinForms TreeView exposes
    # one outline node (role 35) with no item children to MSAA (measured 2026-10-05), while SWD's
    # tree, read from another process, exposes every item as a role-36 child.
    It 'Act refuses a tree verb on anything that is not a tree item' {
        $f = New-Object System.Windows.Forms.Form
        $b = New-Object System.Windows.Forms.Button; $b.Text = 'Press me'
        $f.Controls.Add($b); $script:Pressed = 0; $b.add_Click({ $script:Pressed++ })
        $f.Show(); [System.Windows.Forms.Application]::DoEvents()
        try {
            foreach ($verb in 'default-tree', 'select-tree', 'read-tree') {
                ([SwdProbeNative]::Act([intptr]$f.Handle, 'Press me', $null, 0, $verb, $null, 2000, 5000)).Status | Should -Be 'not-a-tree-item' -Because $verb
            }
            [System.Windows.Forms.Application]::DoEvents()
            $script:Pressed | Should -Be 0
        } finally { $f.Close(); $f.Dispose() }
    }
    It 'ListSelect raises SelectedIndexChanged and reads back the index' {
        $f = New-Object System.Windows.Forms.Form
        $lb = New-Object System.Windows.Forms.ListBox; foreach ($s in '0', '2', '5', '10') { [void]$lb.Items.Add($s) }
        $f.Controls.Add($lb); $script:Changed = 0
        $lb.add_SelectedIndexChanged({ $script:Changed++ })
        $f.Show(); [System.Windows.Forms.Application]::DoEvents()
        try {
            [SwdProbeNative]::ListCount([intptr]$lb.Handle, 2000) | Should -Be 4
            [SwdProbeNative]::ListSelect([intptr]$lb.Handle, 2, 2000) | Should -Be 2
            [System.Windows.Forms.Application]::DoEvents()
            $lb.SelectedIndex | Should -Be 2
            $script:Changed | Should -BeGreaterThan 0
        } finally { $f.Close(); $f.Dispose() }
    }
}
Describe 'cursor guard: a simulated click lands on the node, a hand at the mouse does not' {
    BeforeAll {
        $script:RectNode = { [pscustomobject]@{ Status = 'ok'; Matches = 1; Name = 'n'; Value = 'v'; Role = '36'; State = 0; DefaultAction = 'Expand'; Rect = @(100, 200, 50, 20) } }
    }
    It 'stops when the cursor ends inside the acted node (it simulated input)' {
        $nat = { param($h, $n, $r, $i, $a, $v) & $script:RectNode }
        $script:Seq = 0
        $toNode = { $script:Seq++; if ($script:Seq -eq 1) { @(5, 5) } else { @(120, 210) } }
        { Invoke-SwdProbeAcc -Handle 1 -Name 'Positon X 0.1' -Action select -Native $nat -CursorReader $toNode 3>$null } | Should -Throw 'SWD-PROBE-CURSOR-MOVED*'
    }
    It 'notes and continues when the cursor ends away from the node (someone at the mouse)' {
        $nat = { param($h, $n, $r, $i, $a, $v) & $script:RectNode }
        $script:Seq = 0
        $jitter = { $script:Seq++; if ($script:Seq -eq 1) { @(859, 313) } else { @(859, 311) } }
        $r = Invoke-SwdProbeAcc -Handle 1 -Name 'Positon X 0.1' -Action select -Native $nat -CursorReader $jitter 3>$null
        $r.Status | Should -Be 'ok'
        $r.CursorNote | Should -Match 'someone at the mouse'
    }
}
Describe 'live solver: tree positions against elements.csv rows (pure)' {
    It 'counts Pos X per (drift, Pos Y index) and rows per (drift, roll_case)' {
        $pos = @(@(0, 0, 0.1), @(0, 0, 0.2), @(0, 0.027, 0.1), @(2, 0, 0.1)) | ForEach-Object { [pscustomobject]@{ Drift = $_[0]; Y = $_[1]; X = $_[2] } }
        $csv = @(@('0', '0'), @('0', '0'), @('0', '1'), @('2', '0'), @('30', '0')) | ForEach-Object { [pscustomobject]@{ drift_deg = $_[0]; roll_case = $_[1] } }
        $c = @(Compare-SwdSolverPositionCount -Positions $pos -ElementRows $csv)
        ($c | ForEach-Object { '{0}={1}/{2}' -f $_.Key, $_.Tree, $_.Csv }) -join ' ' | Should -Be '0|0=2/2 0|1=1/1 2|0=1/1'
    }
    It 'reports a missing position on either side' {
        $pos = @([pscustomobject]@{ Drift = 0; Y = 0; X = 0.1 })
        $csv = @([pscustomobject]@{ drift_deg = '0'; roll_case = '0' }, [pscustomobject]@{ drift_deg = '0'; roll_case = '1' })
        @(Compare-SwdSolverPositionCount -Positions $pos -ElementRows $csv | Where-Object { $_.Tree -ne $_.Csv }).Key | Should -Be '0|1'
    }
}
Describe 'live solver: a loop names its state directory' {
    It 'refuses SolverLoop without -SweepDir, before touching anything' {
        Mock Get-SwdProbeLogDir { throw 'should not be reached' }
        { Invoke-SwdProbe -Name Sweep -Pass SolverLoop } | Should -Throw '*needs -SweepDir*'
        Should -Invoke Get-SwdProbeLogDir -Times 0
    }
}

# ---------------------------------------------------------------------------------------
# SQA pass 2026-10-06 (code-reviewer intake): one Describe per finding fixed, each test
# failing on the pre-fix code. Nothing here launches, closes or touches SWD: every path that
# could reach a launch pins $script:SweepExe to a file that does not exist and mocks
# Start-Process / Stop-Process as tripwires, and fake process ids are ODD, which a Windows
# process id never is (they are multiples of 4).
# ---------------------------------------------------------------------------------------

Describe 'SQA 2026-10-06 W5: resume state is written whole, and an unreadable one stops the run' {
    It 'Write-SwdProbeJson swaps the new text in whole and leaves no temp file (<label>)' -ForEach @(
        @{ label = 'a new file'; existing = $false }
        @{ label = 'over an existing file'; existing = $true }
    ) {
        $p = Join-Path $TestDrive ('st-' + [guid]::NewGuid().ToString('N') + '.json')
        if ($existing) { Write-SwdProbeJson -Path $p -Object ([pscustomobject]@{ Cursor = 1 }) }
        Write-SwdProbeJson -Path $p -Object ([pscustomobject]@{ Cursor = 2; Name = ('caf' + [char]0x00E9) })
        $back = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        $back.Cursor | Should -Be 2
        $back.Name | Should -Be ('caf' + [char]0x00E9)
        Test-Path -LiteralPath "$p.tmp" | Should -BeFalse
    }
    It 'a write that cannot complete leaves the old file whole, never truncated in place' {
        $p = Join-Path $TestDrive 'whole.json'
        Write-SwdProbeJson -Path $p -Object ([pscustomobject]@{ Cursor = 7 })
        # The temp name is taken by a directory, so the new text cannot be written beside the file.
        New-Item -ItemType Directory -Path "$p.tmp" | Out-Null
        { Write-SwdProbeJson -Path $p -Object ([pscustomobject]@{ Cursor = 8 }) } | Should -Throw
        (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json).Cursor | Should -Be 7
    }
    It 'Read-SwdProbeState gives $null for no file and the object for a JSON object (<label>)' -ForEach @(
        @{ label = 'no BOM'; bytes = [Text.Encoding]::UTF8.GetBytes('{"Cursor":3}') }
        @{ label = 'a UTF-8 BOM'; bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes('{"Cursor":3}')) }
        @{ label = 'CRLF and indentation'; bytes = [Text.Encoding]::UTF8.GetBytes("{`r`n  `"Cursor`": 3`r`n}`r`n") }
    ) {
        $p = Join-Path $TestDrive ('ok-' + [guid]::NewGuid().ToString('N') + '.json')
        $null -eq (Read-SwdProbeState -Path $p) | Should -BeTrue
        [IO.File]::WriteAllBytes($p, $bytes)
        (Read-SwdProbeState -Path $p).Cursor | Should -Be 3
    }
    It 'Read-SwdProbeState refuses a state file that is <label>' -ForEach @(
        @{ label = 'empty (0 bytes)'; text = '' }
        @{ label = 'blank (spaces and CRLF)'; text = "   `r`n" }
        @{ label = 'a BOM and nothing else'; text = [string][char]0xFEFF }
        @{ label = 'literal null'; text = 'null' }
        @{ label = 'literal false'; text = 'false' }
        @{ label = 'a bare number'; text = '0' }
        @{ label = 'an array'; text = '[{"Cursor":3}]' }
        @{ label = 'cut off mid-write'; text = '{"Fingerprint":"ab12","Cur' }
    ) {
        $p = Join-Path $TestDrive ('bad-' + [guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::WriteAllText($p, $text, (New-Object Text.UTF8Encoding $false))
        { Read-SwdProbeState -Path $p } | Should -Throw 'SWD-STATE-UNREADABLE*'
    }
    It 'names the unreadable file without the username (R9)' {
        $p = Join-Path $TestDrive 'empty-r9.json'
        [IO.File]::WriteAllText($p, '')
        $err = $null
        try { [void](Read-SwdProbeState -Path $p) } catch { $err = $_.Exception.Message }
        $err | Should -Match 'SWD-STATE-UNREADABLE'
        $err | Should -Not -Match ([regex]::Escape($env:USERPROFILE))
    }
    It 'Invoke-SwdSweep stops on an empty state.json before anything runs, and leaves the file as it was' {
        $dir = Join-Path $TestDrive 'sweep-empty'
        New-Item -ItemType Directory -Path $dir | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'state.json'), '')
        Mock Start-SwdSweepApp { throw 'must not launch' }
        Mock Get-SwdProbeMain { throw 'must not look' }
        { Invoke-SwdSweep -Pass Map -Dir $dir -RunDir $TestDrive -StopFile (Join-Path $TestDrive 'STOP-none') } | Should -Throw 'SWD-STATE-UNREADABLE*'
        (Get-Item -LiteralPath (Join-Path $dir 'state.json')).Length | Should -Be 0
        Should -Invoke Start-SwdSweepApp -Times 0 -Exactly
        Should -Invoke Get-SwdProbeMain -Times 0 -Exactly
    }
}

Describe 'SQA 2026-10-06: the solver loop resumes its own plan, and only its own (W5, S20, W3, S21)' {
    BeforeAll {
        $script:LoopPos = @(
            [pscustomobject]@{ Drift = 0.0; Y = 0.0; X = 0.1; Name = 'Positon X 0.1'; Nth = 0; DriftIndex = 0 }
            [pscustomobject]@{ Drift = 0.0; Y = 0.0; X = 0.467; Name = 'Positon X 0.467'; Nth = 0; DriftIndex = 0 }
        )
        function Invoke-Loop([string]$Dir) {
            Invoke-SwdSolver -Pass SolverLoop -Dir $Dir -RunDir $TestDrive -StopFile (Join-Path $TestDrive 'STOP-loop') -Speeds @('10') -Slopes @('0')
        }
        function Get-LoopSeq([string]$Dir) {
            @(Get-Content -LiteralPath (Join-Path $Dir 'solver.jsonl') | Where-Object { $_ } | ForEach-Object { ($_ | ConvertFrom-Json).Seq })
        }
    }
    BeforeEach {
        $script:LoopDir = Join-Path $TestDrive ('loop-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:LoopDir | Out-Null
        $script:SavedExe = $script:SweepExe; $script:SweepExe = Join-Path $TestDrive 'no-such-app.exe'
        Mock Start-Process { throw 'Start-Process reached in a test' }
        Mock Get-Process { [pscustomobject]@{ Id = 4243; StartTime = (Get-Date).AddHours(-1) } } -ParameterFilter { $Name -contains 'SurfHydrodynamics' }
        Mock Start-SwdSweepApp { 'b_Copy_1' }
        Mock Initialize-SwdSolverSession { $Ctx.Positions = $script:LoopPos; $Ctx.Board = 'b_Copy_1'; [pscustomobject]@{ Positions = 2 } }
        Mock Set-SwdSolverSituation { $Ctx.Applied = "v=$Speed|s=$Slope"; [pscustomobject]@{ Speed = $Speed; Slope = $Slope } }
        Mock Select-SwdSolverPosition { [pscustomobject]@{ Rows = [ordered]@{ Fx_friction_n = "$($Position.X)" }; ElementName = 'e'; Match = $true; SameAsPrevious = $false; SelectMs = 1; SettleMs = 1; ReadMs = 1 } }
    }
    AfterEach { $script:SweepExe = $script:SavedExe }
    It 'a fresh loop reads every position in order, checks the block, and saves its cursor whole' {
        Invoke-Loop $script:LoopDir
        Get-LoopSeq $script:LoopDir | Should -Be @(0, 1)
        (Read-SwdProbeState -Path (Join-Path $script:LoopDir 'loop_state.json')).Cursor | Should -Be 2
        Test-Path -LiteralPath (Join-Path $script:LoopDir 'loop_state.json.tmp') | Should -BeFalse
        @(Get-Content -LiteralPath (Join-Path $script:LoopDir 'controls.jsonl') | Where-Object { $_ }).Count | Should -Be 1
        Should -Invoke Set-SwdSolverSituation -Times 1 -Exactly
    }
    It 'a resumed loop starts at its saved cursor (S20)' {
        $fp = Get-SwdSolverFingerprint -Board 'b_Copy_1' -Speeds @('10') -Slopes @('0') -Positions $script:LoopPos
        Write-SwdProbeJson -Path (Join-Path $script:LoopDir 'loop_state.json') -Object ([pscustomobject]@{ Fingerprint = $fp; Cursor = 1; BlockFirst = $null })
        Invoke-Loop $script:LoopDir
        Get-LoopSeq $script:LoopDir | Should -Be @(1)
        Should -Invoke Select-SwdSolverPosition -Times 1 -Exactly
        Should -Invoke Select-SwdSolverPosition -Times 1 -Exactly -ParameterFilter { $Position.X -eq 0.467 }
    }
    It 'a loop_state written for another plan is refused before anything is applied or read (S20)' {
        Write-SwdProbeJson -Path (Join-Path $script:LoopDir 'loop_state.json') -Object ([pscustomobject]@{ Fingerprint = 'FFFFFFFFFFFFFFFF'; Cursor = 1 })
        { Invoke-Loop $script:LoopDir } | Should -Throw 'SWD-SOLVER-PLAN*'
        Should -Invoke Set-SwdSolverSituation -Times 0 -Exactly
        Should -Invoke Select-SwdSolverPosition -Times 0 -Exactly
    }
    It 'an empty loop_state.json stops the chunk instead of starting over at cursor 0 (W5)' {
        [IO.File]::WriteAllText((Join-Path $script:LoopDir 'loop_state.json'), '')
        { Invoke-Loop $script:LoopDir } | Should -Throw 'SWD-STATE-UNREADABLE*'
        (Get-Item -LiteralPath (Join-Path $script:LoopDir 'loop_state.json')).Length | Should -Be 0
        Should -Invoke Select-SwdSolverPosition -Times 0 -Exactly
    }
    It 'a loop that must launch SWD hands the launch its kill switch (W3)' {
        Mock Get-Process { } -ParameterFilter { $Name -contains 'SurfHydrodynamics' }
        Invoke-Loop $script:LoopDir
        Should -Invoke Start-SwdSweepApp -Times 1 -Exactly -ParameterFilter { $StopFile -like '*STOP-loop' }
    }
}

Describe 'SQA 2026-10-06 W4: a Sweep hashes the library before it launches SWD' {
    BeforeEach {
        $script:W4Root = Join-Path $TestDrive ('w4-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:W4Root | Out-Null
        $script:W4Order = New-Object System.Collections.Generic.List[string]
        $script:SavedExe = $script:SweepExe; $script:SweepExe = Join-Path $TestDrive 'no-such-app.exe'
        Mock Start-Process { throw 'Start-Process reached in a test' }
        Mock Get-SwdProbeLogDir { $script:W4Root }
        Mock Get-Process { } -ParameterFilter { $Name -contains 'SurfHydrodynamics' }
        Mock Get-SwdLibraryHash { $script:W4Order.Add('hash'); @{ 'Boards\a.fynbs' = 'same' } }
    }
    AfterEach { $script:SweepExe = $script:SavedExe }
    It 'hashes first, and a launch that fails still leaves a library verdict' {
        Mock Start-SwdSweepApp { $script:W4Order.Add('launch'); throw 'launch failed' }
        { Invoke-SwdProbe -Name Sweep -Pass Map -SweepDir (Join-Path $script:W4Root 'sw') 3>$null } | Should -Throw 'launch failed'
        ($script:W4Order -join ',') | Should -Be 'hash,launch,hash'
        $f = Get-ChildItem -LiteralPath $script:W4Root -Recurse -Filter 'summary.json' | Select-Object -First 1
        (Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json).Library.Ok | Should -BeTrue
        Should -Invoke Start-SwdSweepApp -Times 1 -Exactly -ParameterFilter { $StopFile -like '*\STOP' }
    }
}

Describe 'SQA 2026-10-06 W3: every act on the sweep and solver paths carries the kill switch' {
    It 'passes -StopFile at every call of an acting or waiting helper (restores and the close excepted)' {
        $tok = $null; $perr = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Phase2 'swd_probe.ps1'), [ref]$tok, [ref]$perr)
        $gated = @('Start-SwdSweepApp', 'Clear-SwdSweepPopup', 'Invoke-SwdProbeAcc', 'Select-SwdProbeTab', 'Select-SwdSweepTreeItem', 'Write-SwdSweepInput', 'Wait-SwdProbeSettle')
        $fns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and ($n.Name -match '-Swd(Sweep|Solver)' -or $n.Name -eq 'Invoke-SwdProbe') }, $true))
        $checked = 0; $missing = @(); $exempt = @()
        foreach ($f in $fns) {
            foreach ($c in @($f.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $gated -contains $n.GetCommandName() }, $true))) {
                # A restore in a finally block, and the close's own popup answering, run whatever STOP says, by design.
                $inFinally = $false; $p = $c.Parent
                while ($p -and $p -ne $f) {
                    if ($p.Parent -is [System.Management.Automation.Language.TryStatementAst] -and $p.Parent.Finally -eq $p) { $inFinally = $true; break }
                    $p = $p.Parent
                }
                if ($inFinally -or ($f.Name -eq 'Stop-SwdSweepApp' -and $c.GetCommandName() -eq 'Clear-SwdSweepPopup')) { $exempt += "$($f.Name) -> $($c.GetCommandName())"; continue }
                $checked++
                if (-not @($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'StopFile' }).Count) {
                    $missing += "$($f.Name) -> $($c.GetCommandName()) (line $($c.Extent.StartLineNumber))"
                }
            }
        }
        $perr.Count | Should -Be 0
        # 50 gated calls on 2026-10-06; the exemptions are exactly the three documented ones, so an
        # act cannot dodge the check by moving into a finally block.
        $checked | Should -BeGreaterOrEqual 50
        @($exempt | Sort-Object) | Should -Be @('Invoke-SwdSweep -> Write-SwdSweepInput', 'Invoke-SwdSweepTrial -> Write-SwdSweepInput', 'Stop-SwdSweepApp -> Clear-SwdSweepPopup')
        $missing | Should -BeNullOrEmpty
    }
}

Describe 'SQA 2026-10-06 W3: a STOP or the cursor corner stops the next act' {
    BeforeEach {
        $script:K = Join-Path $TestDrive ('STOP-k-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $script:KCalls = New-Object System.Collections.Generic.List[string]
        $script:KNode = { param($h, $n, $r, $i, $a, $v) $script:KCalls.Add($a); [pscustomobject]@{ Status = 'ok'; Matches = 1; Name = 'n'; Value = 'v'; Role = '36'; State = 0; DefaultAction = 'Expand'; Rect = @(1, 1, 10, 10) } }
        $script:SavedExe = $script:SweepExe; $script:SweepExe = Join-Path $TestDrive 'no-such-app.exe'
        Mock Start-Process { throw 'Start-Process reached in a test' }
    }
    AfterEach { $script:SweepExe = $script:SavedExe }
    It 'Invoke-SwdProbeAcc reads, then refuses to act while STOP is present' {
        New-Item -ItemType File -Path $script:K | Out-Null
        { Invoke-SwdProbeAcc -Handle 1 -Name 'Positon X 0.1' -Action select -Native $script:KNode -CursorReader { @(500, 500) } -StopFile $script:K } | Should -Throw 'SWD-PROBE-STOPPED*'
        $script:KCalls -join ',' | Should -Be 'read'
    }
    It 'Invoke-SwdProbeAcc refuses to act with the cursor parked in the corner' {
        { Invoke-SwdProbeAcc -Handle 1 -Name 'Positon X 0.1' -Action select -Native $script:KNode -CursorReader { @(1, 1) } -StopFile $script:K } | Should -Throw 'SWD-PROBE-STOPPED*corner*'
        $script:KCalls -join ',' | Should -Be 'read'
    }
    It 'Invoke-SwdProbeAcc still acts with no stop signal' {
        (Invoke-SwdProbeAcc -Handle 1 -Name 'Positon X 0.1' -Action select -Native $script:KNode -CursorReader { @(500, 500) } -StopFile $script:K).Status | Should -Be 'ok'
        $script:KCalls -join ',' | Should -Be 'read,select'
    }
    It 'Select-SwdProbeTab does not switch while STOP is present' {
        $f = New-Object System.Windows.Forms.Form; $f.StartPosition = 'Manual'; $f.Location = New-Object System.Drawing.Point(900, 400)
        $tc = New-Object System.Windows.Forms.TabControl; $tc.Size = New-Object System.Drawing.Size(200, 100)
        foreach ($t in 'Shape', 'Fins') { $pg = New-Object System.Windows.Forms.TabPage; $pg.Text = $t; $tc.TabPages.Add($pg) }
        $f.Controls.Add($tc)
        try {
            $f.Show(); [System.Windows.Forms.Application]::DoEvents()
            New-Item -ItemType File -Path $script:K | Out-Null
            { Select-SwdProbeTab -Handle ([int64]$f.Handle) -Name 'Fins' -StopFile $script:K } | Should -Throw 'SWD-PROBE-STOPPED*'
            [System.Windows.Forms.Application]::DoEvents()
            $tc.SelectedIndex | Should -Be 0
        } finally { $f.Close(); $f.Dispose() }
    }
    It 'Select-SwdProbeTab re-reads the tab right before switching and refuses a tab set that moved (S7)' {
        $f = New-Object System.Windows.Forms.Form; $f.StartPosition = 'Manual'; $f.Location = New-Object System.Drawing.Point(900, 400)
        $tc = New-Object System.Windows.Forms.TabControl; $tc.Size = New-Object System.Drawing.Size(200, 100)
        foreach ($t in 'Shape', 'Fins') { $pg = New-Object System.Windows.Forms.TabPage; $pg.Text = $t; $tc.TabPages.Add($pg) }
        $f.Controls.Add($tc)
        try {
            $f.Show(); $tc.SelectedIndex = 1; [System.Windows.Forms.Application]::DoEvents()
            # The walk is stale: it still finds 'Fins' at index 0, where 'Shape' is now.
            $script:S7Tab = [int64]$tc.Handle
            Mock Get-SwdMsaaSnapshot { [pscustomobject]@{ Nodes = @([pscustomobject]@{ Role = '37'; Name = 'Fins'; Key = "h$($script:S7Tab):0/0" }); Truncated = $false } }
            { Select-SwdProbeTab -Handle ([int64]$f.Handle) -Name 'Fins' } | Should -Throw '*the tab set changed*'
            [System.Windows.Forms.Application]::DoEvents()
            $tc.SelectedIndex | Should -Be 1
        } finally { $f.Close(); $f.Dispose() }
    }
    It 'Clear-SwdSweepPopup presses nothing once STOP is present' {
        Mock Get-SwdSweepTopWindows { [pscustomobject]@{ Handle = [int64]77; Title = 'SWD'; IsMain = $false } }
        Mock Get-SwdDialogControl { [pscustomobject]@{ Class = 'WindowsForms10.BUTTON'; Visible = $true; Enabled = $true; Text = 'Cancel' } }
        Mock Invoke-SwdDialogButton { [pscustomobject]@{ Attempted = $true } }
        Mock Wait-SwdDialogGone { $true }
        New-Item -ItemType File -Path $script:K | Out-Null
        { Clear-SwdSweepPopup -TransientMs 0 -StopFile $script:K } | Should -Throw 'SWD-PROBE-STOPPED*'
        Should -Invoke Invoke-SwdDialogButton -Times 0 -Exactly
    }
    It 'Clear-SwdSweepPopup checks again right before the press (STOP raised while it looked)' {
        Mock Get-SwdSweepTopWindows { [pscustomobject]@{ Handle = [int64]79; Title = 'SWD'; IsMain = $false } }
        Mock Get-SwdDialogControl { New-Item -ItemType File -Path $script:K -Force | Out-Null; [pscustomobject]@{ Class = 'WindowsForms10.BUTTON'; Visible = $true; Enabled = $true; Text = 'Cancel' } }
        Mock Invoke-SwdDialogButton { [pscustomobject]@{ Attempted = $true } }
        Mock Wait-SwdDialogGone { $true }
        { Clear-SwdSweepPopup -TransientMs 0 -StopFile $script:K } | Should -Throw 'SWD-PROBE-STOPPED*'
        Should -Invoke Invoke-SwdDialogButton -Times 0 -Exactly
    }
    It 'Clear-SwdSweepPopup still answers a dialog with no stop signal' {
        $script:PopN = 0
        Mock Get-SwdSweepTopWindows { $script:PopN++; if ($script:PopN -eq 1) { [pscustomobject]@{ Handle = [int64]81; Title = 'SWD'; IsMain = $false } } }
        Mock Get-SwdDialogControl { [pscustomobject]@{ Class = 'WindowsForms10.BUTTON'; Visible = $true; Enabled = $true; Text = 'Cancel' } }
        Mock Invoke-SwdDialogButton { [pscustomobject]@{ Attempted = $true } }
        Mock Wait-SwdDialogGone { $true }
        @(Clear-SwdSweepPopup -TransientMs 0 -StopFile $script:K) -join "`n" | Should -Match "pressed 'Cancel'"
        Should -Invoke Invoke-SwdDialogButton -Times 1 -Exactly
    }
    It 'Start-SwdSweepApp launches nothing while STOP is present' {
        Mock Get-Process { } -ParameterFilter { $Name -contains 'SurfHydrodynamics' }
        New-Item -ItemType File -Path $script:K | Out-Null
        { Start-SwdSweepApp -StopFile $script:K } | Should -Throw 'SWD-PROBE-STOPPED*'
        Should -Invoke Start-Process -Times 0 -Exactly
    }
    It 'Start-SwdSweepApp stops waiting for the window once STOP appears' {
        Mock Get-Process { } -ParameterFilter { $Name -contains 'SurfHydrodynamics' }
        Mock Start-Process { }
        Mock Start-Sleep { New-Item -ItemType File -Path $script:K -Force | Out-Null }
        Mock Get-SwdSweepTopWindows { }
        { Start-SwdSweepApp -StopFile $script:K } | Should -Throw 'SWD-PROBE-STOPPED*'
        Should -Invoke Start-Process -Times 1 -Exactly
        Should -Invoke Get-SwdSweepTopWindows -Times 0 -Exactly
    }
}

Describe 'SQA 2026-10-06: Set-SwdSolverSituation against in-process boxes (W3, S12, S20, S1)' {
    BeforeAll {
        function Open-SitForm {
            $f = New-Object System.Windows.Forms.Form; $f.StartPosition = 'Manual'; $f.Location = New-Object System.Drawing.Point(900, 400)
            $sp = New-Object System.Windows.Forms.TextBox; $sp.Text = '5'
            $sl = New-Object System.Windows.Forms.TextBox; $sl.Text = '-3'; $sl.Top = 30
            $b = New-Object System.Windows.Forms.Button; $b.Text = 'Apply situation'; $b.Top = 60; $b.Width = 150
            $f.Controls.AddRange(@($sp, $sl, $b)); $f.Show(); [System.Windows.Forms.Application]::DoEvents()
            return [pscustomobject]@{ Form = $f; Speed = $sp; Slope = $sl; Button = $b }
        }
    }
    BeforeEach {
        $script:Sit = Open-SitForm
        $script:SitStop = Join-Path $TestDrive ('STOP-sit-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $script:SitCtx = [pscustomobject]@{ SpeedBox = [int64]$script:Sit.Speed.Handle; SlopeBox = [int64]$script:Sit.Slope.Handle
                                           ApplyButton = [int64]$script:Sit.Button.Handle; StopFile = $script:SitStop; Applied = $null; LastRows = $null }
        $script:Late = $false
        Mock Get-SwdProbeMain { [pscustomobject]@{ Handle = 1 } }
        Mock Wait-SwdProbeSettle { [pscustomobject]@{ Settled = $true; TimedOut = $false } }
        Mock Clear-SwdSweepPopup { }
        Mock Set-SwdNumeric { [pscustomobject]@{ Ok = $false; Reason = 'not expected here' } }
        # SWD's 'Apply situation' disables itself once pressed (measured 2026-10-05).
        Mock Invoke-SwdButton { $script:Sit.Button.Enabled = $false; [System.Windows.Forms.Application]::DoEvents() }
        # Keystrokes posted to an in-process box arrive only when its queue is pumped.
        Mock Start-Sleep { [System.Windows.Forms.Application]::DoEvents() }
    }
    AfterEach { $script:Sit.Form.Close(); $script:Sit.Form.Dispose() }
    It 'types both values, checks them, and presses Apply once' {
        $r = Set-SwdSolverSituation -Speed '12.5' -Slope '-3' -Ctx $script:SitCtx
        $r.SpeedRead | Should -BeExactly '12.5'
        $r.SlopeRead | Should -BeExactly '-3'
        $script:SitCtx.Applied | Should -Be 'v=12.5|s=-3'
        Should -Invoke Invoke-SwdButton -Times 1 -Exactly
    }
    It 'types nothing and presses nothing while STOP is present (W3)' {
        New-Item -ItemType File -Path $script:SitStop | Out-Null
        { Set-SwdSolverSituation -Speed '10' -Slope '0' -Ctx $script:SitCtx } | Should -Throw 'SWD-PROBE-STOPPED*'
        [System.Windows.Forms.Application]::DoEvents()
        $script:Sit.Speed.Text | Should -Be '5'
        Should -Invoke Invoke-SwdButton -Times 0 -Exactly
    }
    It 'does not press Apply when STOP appears once both boxes are typed (W3)' {
        Mock Start-Sleep { [System.Windows.Forms.Application]::DoEvents(); if ($script:Sit.Slope.Text -eq '0') { New-Item -ItemType File -Path $script:SitStop -Force | Out-Null } }
        { Set-SwdSolverSituation -Speed '10' -Slope '0' -Ctx $script:SitCtx } | Should -Throw 'SWD-PROBE-STOPPED*'
        $script:Sit.Speed.Text | Should -Be '10'
        Should -Invoke Invoke-SwdButton -Times 0 -Exactly
    }
    It 'refuses to press when a box no longer reads the request, a late keystroke (S12)' {
        Mock Start-Sleep { [System.Windows.Forms.Application]::DoEvents(); if ($script:Sit.Slope.Text -eq '0' -and -not $script:Late) { $script:Late = $true; $script:Sit.Speed.AppendText('0') } }
        { Set-SwdSolverSituation -Speed '10' -Slope '0' -Ctx $script:SitCtx } | Should -Throw "*speed box reads '100'*"
        Should -Invoke Invoke-SwdButton -Times 0 -Exactly
    }
    It 'never records a block as applied when a box changed after the press (S12)' {
        Mock Invoke-SwdButton { $script:Sit.Button.Enabled = $false; $script:Sit.Slope.Text = '30'; [System.Windows.Forms.Application]::DoEvents() }
        { Set-SwdSolverSituation -Speed '10' -Slope '0' -Ctx $script:SitCtx } | Should -Throw "*slope box reads '30'*"
        $null -eq $script:SitCtx.Applied | Should -BeTrue
    }
    It 're-checks the Apply caption against the allowlist right before the press (S20)' {
        $script:Sit.Button.Text = 'Hydrodynamics Scanner'; [System.Windows.Forms.Application]::DoEvents()
        { Set-SwdSolverSituation -Speed '10' -Slope '0' -Ctx $script:SitCtx } | Should -Throw '*not on the probe allowlist*'
        Should -Invoke Invoke-SwdButton -Times 0 -Exactly
    }
    It 'a press that leaves Apply enabled is an error, not an applied block (S20)' {
        Mock Invoke-SwdButton { }
        { Set-SwdSolverSituation -Speed '10' -Slope '0' -Ctx $script:SitCtx } | Should -Throw '*did not disable itself*'
        $null -eq $script:SitCtx.Applied | Should -BeTrue
    }
    It 'refuses a value carrying a line break before typing anything (S1): <_>' -ForEach @("10`n", "`n10", "10`r`n", "1`n0") {
        { Set-SwdSolverSituation -Speed $_ -Slope '0' -Ctx $script:SitCtx } | Should -Throw 'Refusing to type*'
        [System.Windows.Forms.Application]::DoEvents()
        $script:Sit.Speed.Text | Should -Be '5'
    }
}

Describe 'SQA 2026-10-06: the drift list is driven only as a live SWD list box (S8, W3)' {
    BeforeEach {
        Mock Select-SwdSolverRoot { }
        Mock Wait-SwdProbeSettle { }
        Mock Get-SwdProbeMain { [pscustomobject]@{ Handle = 1 } }
        $script:DF = New-Object System.Windows.Forms.Form; $script:DF.StartPosition = 'Manual'; $script:DF.Location = New-Object System.Drawing.Point(900, 400)
        $script:DL = New-Object System.Windows.Forms.ListBox; foreach ($s in '0', '2', '5') { [void]$script:DL.Items.Add($s) }
        $script:DB = New-Object System.Windows.Forms.Button; $script:DB.Text = 'Apply situation'; $script:DB.Top = 120
        $script:DF.Controls.AddRange(@($script:DL, $script:DB)); $script:DF.Show(); [System.Windows.Forms.Application]::DoEvents()
        $script:DStop = Join-Path $TestDrive ('STOP-d-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $script:DCtx = [pscustomobject]@{ DriftList = [int64]$script:DL.Handle; StopFile = $script:DStop; DriftNow = -1; Expanded = @{ a = $true } }
    }
    AfterEach { $script:DF.Close(); $script:DF.Dispose() }
    It 'refuses a handle that is not a SurfHydrodynamics window' {
        { Select-SwdSolverDrift -Index 1 -Ctx $script:DCtx } | Should -Throw '*not a live SurfHydrodynamics window*'
        [System.Windows.Forms.Application]::DoEvents()
        $script:DL.SelectedIndex | Should -Be -1
    }
    It 'refuses a live window of another class: a button answers LB_GETCURSEL with 0, which read as success' {
        Mock Test-SwdHandle { $true }
        $script:DCtx.DriftList = [int64]$script:DB.Handle
        { Select-SwdSolverDrift -Index 0 -Ctx $script:DCtx } | Should -Throw '*class*BUTTON*'
    }
    It 'selects the drift on a live list box and records it' {
        Mock Test-SwdHandle { $true }
        Select-SwdSolverDrift -Index 2 -Ctx $script:DCtx
        $script:DCtx.DriftNow | Should -Be 2
        $script:DCtx.Expanded.Count | Should -Be 0
        [System.Windows.Forms.Application]::DoEvents()
        $script:DL.SelectedIndex | Should -Be 2
    }
    It 'selects nothing while STOP is present (W3)' {
        Mock Test-SwdHandle { $true }
        New-Item -ItemType File -Path $script:DStop | Out-Null
        { Select-SwdSolverDrift -Index 2 -Ctx $script:DCtx } | Should -Throw 'SWD-PROBE-STOPPED*'
        [System.Windows.Forms.Application]::DoEvents()
        $script:DL.SelectedIndex | Should -Be -1
    }
    It 'Write-SwdSweepInput refuses a combo or trackbar handle of the wrong class (S8)' {
        Mock Test-SwdHandle { $true }
        Mock Get-SwdSweepHandle { [int64]$script:DB.Handle }
        $ctx = [pscustomobject]@{ StopFile = $script:DStop }
        { Write-SwdSweepInput -Spec ([pscustomobject]@{ Kind = 'combo'; Target = 'ComboBox_tail_bevel'; Apply = $null }) -Value '1' -Ctx $ctx } | Should -Throw '*class*BUTTON*COMBOBOX*'
        { Write-SwdSweepInput -Spec ([pscustomobject]@{ Kind = 'slider'; Target = 'TrackBar_x'; Apply = $null }) -Value '1' -Ctx $ctx } | Should -Throw '*class*BUTTON*trackbar32*'
    }
}

Describe 'SQA 2026-10-06 S20: position selection and the element check' {
    BeforeEach {
        Mock Select-SwdSolverDrift { $Ctx.DriftNow = $Index; $Ctx.Expanded = @{} }
        Mock Invoke-SwdProbeAcc { [pscustomobject]@{ Status = 'ok' } }
        Mock Start-Sleep { }
        $script:SPStop = Join-Path $TestDrive 'STOP-sp'
        $script:SPPos = [pscustomobject]@{ Name = 'Positon X 0.1'; Nth = 0; DriftIndex = 1
                                           DriftNode = [pscustomobject]@{ Name = 'Analyse Positions drift 2'; Nth = 0 }; YNode = [pscustomobject]@{ Name = 'Positons Y 0'; Nth = 1 } }
    }
    It 'switches the drift list first when the position is in another drift' {
        [void](Show-SwdSolverPosition -Position $script:SPPos -Ctx ([pscustomobject]@{ DriftNow = 0; Expanded = @{}; Tree = 5; StopFile = $script:SPStop }))
        Should -Invoke Select-SwdSolverDrift -Times 1 -Exactly -ParameterFilter { $Index -eq 1 }
    }
    It 'does not switch when the list already shows its drift' {
        [void](Show-SwdSolverPosition -Position $script:SPPos -Ctx ([pscustomobject]@{ DriftNow = 1; Expanded = @{}; Tree = 5; StopFile = $script:SPStop }))
        Should -Invoke Select-SwdSolverDrift -Times 0 -Exactly
    }
    It 'expands and selects off-screen, by name and occurrence, with the kill switch (W3)' {
        [void](Show-SwdSolverPosition -Position $script:SPPos -Ctx ([pscustomobject]@{ DriftNow = 1; Expanded = @{}; Tree = 5; StopFile = $script:SPStop }))
        Should -Invoke Invoke-SwdProbeAcc -Times 3 -Exactly -ParameterFilter { $StopFile -eq $script:SPStop -and $Offscreen }
        Should -Invoke Invoke-SwdProbeAcc -Times 1 -Exactly -ParameterFilter { $Action -eq 'select' -and $Name -eq 'Positon X 0.1' -and $Nth -eq 0 }
        Should -Invoke Invoke-SwdProbeAcc -Times 1 -Exactly -ParameterFilter { $Action -eq 'expand' -and $Name -eq 'Positons Y 0' -and $Nth -eq 1 }
    }
    It 'compares X by sign and value: another X, or the mirrored one, is another position' {
        $e = [pscustomobject]@{ Drift = 0; Y = 0.027; X = 0.467 }
        Test-SwdSolverElementIs -Element $e -Position ([pscustomobject]@{ Drift = 0; Y = 0.027; X = 0.4 }) | Should -BeFalse
        Test-SwdSolverElementIs -Element $e -Position ([pscustomobject]@{ Drift = 0; Y = 0.027; X = -0.467 }) | Should -BeFalse
        Test-SwdSolverElementIs -Element $e -Position ([pscustomobject]@{ Drift = 0; Y = 0.027; X = 0.467 }) | Should -BeTrue
    }
    It 'Act refuses to act on an unavailable (disabled) node and says so' {
        $f = New-Object System.Windows.Forms.Form
        $b = New-Object System.Windows.Forms.Button; $b.Text = 'Press me'; $b.Enabled = $false; $f.Controls.Add($b)
        $script:DisPressed = 0; $b.add_Click({ $script:DisPressed++ })
        $f.Show(); [System.Windows.Forms.Application]::DoEvents()
        try {
            ([SwdProbeNative]::Act([intptr]$f.Handle, 'Press me', $null, 0, 'default', $null, 2000, 5000)).Status | Should -Be 'unavailable'
            [System.Windows.Forms.Application]::DoEvents()
            $script:DisPressed | Should -Be 0
        } finally { $f.Close(); $f.Dispose() }
    }
    It 'Act refuses setvalue-tree natively, before it finds anything (S6)' {
        $f = New-Object System.Windows.Forms.Form
        $b = New-Object System.Windows.Forms.Button; $b.Text = 'Press me'; $f.Controls.Add($b)
        $f.Show(); [System.Windows.Forms.Application]::DoEvents()
        try {
            $r = [SwdProbeNative]::Act([intptr]$f.Handle, 'Press me', $null, 0, 'setvalue-tree', '5', 2000, 5000)
            $r.Status | Should -Be 'bad-action'
            $r.Matches | Should -Be 0
        } finally { $f.Close(); $f.Dispose() }
    }
}

Describe 'SQA 2026-10-06: drift limits, labels, keys and fingerprints (S13, S19, S1, S14)' {
    It 'leaves out a drift beyond -MaxDrift whatever its sign (S13)' {
        $deg = [string][char]0x00B0
        $nodes = @('11 HydroScans', "Analyse Positions drift -25$deg", 'Positons Y 0', 'Positon X 0.1', "Analyse Positions drift -15$deg", 'Positons Y 0', 'Positon X 0.2',
                   "Analyse Positions drift 25$deg", 'Positons Y 0', 'Positon X 0.3') | ForEach-Object { [pscustomobject]@{ Role = '36'; Name = $_ } }
        @(Get-SwdSolverPositionList -Nodes $nodes -MaxDrift 20 | ForEach-Object { $_.Drift }) | Should -Be @(-15)
        Test-SwdSolverDriftWithin -Drift -20 -MaxDrift 20 | Should -BeTrue
        Test-SwdSolverDriftWithin -Drift -20.5 -MaxDrift 20 | Should -BeFalse
        Test-SwdSolverDriftWithin -Drift 20.5 -MaxDrift 20 | Should -BeFalse
    }
    It 'reads an element label only when nothing trails it, the same rule as swd_solver_table.py (S19): <label>' -ForEach @(
        @{ label = 'trailing text'; name = ('Drift 2' + [char]0x00B0 + "`r`nPos Y=0 X=0.15 extra"); ok = $false }
        @{ label = 'a split number'; name = ('Drift 2' + [char]0x00B0 + "`r`nPos Y=0 X=0.4 7"); ok = $false }
        @{ label = 'leading text'; name = ('see Drift 2' + [char]0x00B0 + ' Pos Y=0 X=0.15'); ok = $false }
        @{ label = 'trailing blanks'; name = ('Drift 2' + [char]0x00B0 + "`r`nPos Y=0 X=0.15 `r`n"); ok = $true }
        @{ label = 'a negative Y on one line'; name = ('Drift -2' + [char]0x00B0 + ' Pos Y=-0.027 X=0.15'); ok = $true }
    ) {
        $null -ne (ConvertFrom-SwdSolverElement $name) | Should -Be $ok
    }
    It 'refuses a typed value that hides a line break (S1): <_>' -ForEach @("10`n", "10`r`n", "`n10", "10`r", "1`n0") {
        { ConvertTo-SwdSolverKey -Value $_ } | Should -Throw
    }
    It 'fingerprints a plan identically under any culture, and as the en-US runs did (S14)' {
        $pos = @([pscustomobject]@{ Drift = 0; Y = 0.027; X = 0.467 }, [pscustomobject]@{ Drift = 2.5; Y = -0.054; X = 0.1 })
        $a = Get-SwdSolverFingerprint -Board 'b' -Speeds @('12.5') -Slopes @('-3') -Positions $pos
        # Printed by the pre-fix '-f' formula under en-US (2026-10-06): saved loop_state.json files stay valid.
        $a | Should -Be 'BB205213B3CA4216'
        $saved = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
            Get-SwdSolverFingerprint -Board 'b' -Speeds @('12.5') -Slopes @('-3') -Positions $pos | Should -Be $a
        } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $saved }
    }
}

Describe 'SQA 2026-10-06 S2: sweep values are plain decimals, and never NaN or infinite' {
    It 'formats <label> without an exponent' -ForEach @(
        @{ label = 'a tiny grid value'; v = 9.17912E-07; s = '0.000000917912' }
        @{ label = 'a negative tiny value'; v = -1.5E-05; s = '-0.000015' }
        @{ label = 'a large value'; v = 1234567.0; s = '1234570' }
        @{ label = 'a plain fraction'; v = 4.7201; s = '4.7201' }
        @{ label = 'zero'; v = 0.0; s = '0' }
    ) {
        Format-SwdSweepNumber $v | Should -BeExactly $s
    }
    It 'refuses to format <_>' -ForEach @([double]::NaN, [double]::PositiveInfinity, [double]::NegativeInfinity) {
        { Format-SwdSweepNumber $_ } | Should -Throw
    }
    It 'sweeps nothing around a base that reads NaN or Infinity, and plain decimals around a tiny one' {
        @(Get-SwdSweepValue -Kind numeric -Base 'NaN').Count | Should -Be 0
        @(Get-SwdSweepValue -Kind numeric -Base 'Infinity').Count | Should -Be 0
        @(Get-SwdSweepValue -Kind numeric -Base '-Infinity').Count | Should -Be 0
        @(Get-SwdSweepValue -Kind numeric -Base '9.17912E-07') | Should -Be @('0.0000010097', '0.000000826121')
        @(Get-SwdSweepCurveLevel -Base ([double]::NaN)).Count | Should -Be 0
    }
    It 'sweeps nothing around an infinite base even where a range would clamp it to a finite bound' {
        # The clamp turns +-Infinity into Min or Max, a value derived from no number at all.
        @(Get-SwdSweepValue -Kind numeric -Base 'Infinity' -Min 0 -Max 10).Count | Should -Be 0
        @(Get-SwdSweepValue -Kind numeric -Base '-Infinity' -Min -5 -Max 5).Count | Should -Be 0
    }
}

Describe 'SQA 2026-10-06 S5: the cursor guard on a degenerate rectangle or an unread start' {
    BeforeAll {
        $script:PtNode = { param($x, $y, $w, $h) [pscustomobject]@{ Status = 'ok'; Matches = 1; Name = 'n'; Value = 'v'; Role = '36'; State = 0; DefaultAction = 'Expand'; Rect = @($x, $y, $w, $h) } }
    }
    It 'catches a click at the point a degenerate rectangle marks (<label>)' -ForEach @(
        @{ label = 'zero width and height'; w = 0; h = 0 }
        @{ label = 'zero width'; w = 0; h = 20 }
        @{ label = 'negative width'; w = -5; h = 20 }
    ) {
        $script:PtW = $w; $script:PtH = $h
        $nat = { param($hh, $n, $r, $i, $a, $v) & $script:PtNode 300 400 $script:PtW $script:PtH }
        $script:CSeq = 0
        $toPoint = { $script:CSeq++; if ($script:CSeq -eq 1) { @(5, 5) } else { @(300, 400) } }
        { Invoke-SwdProbeAcc -Handle 1 -Name 'Positon X 0.1' -Action select -Native $nat -CursorReader $toPoint 3>$null } | Should -Throw 'SWD-PROBE-CURSOR-MOVED*'
    }
    It 'still only notes a hand elsewhere when the rectangle is degenerate' {
        $nat = { param($hh, $n, $r, $i, $a, $v) & $script:PtNode 300 400 0 0 }
        $script:CSeq = 0
        $away = { $script:CSeq++; if ($script:CSeq -eq 1) { @(859, 313) } else { @(859, 311) } }
        (Invoke-SwdProbeAcc -Handle 1 -Name 'Positon X 0.1' -Action select -Native $nat -CursorReader $away 3>$null).CursorNote | Should -Match 'someone at the mouse'
    }
    It 'an unread start still checks where the cursor ended: on the node is fatal, away is noted' {
        $nat = { param($hh, $n, $r, $i, $a, $v) & $script:PtNode 100 200 50 20 }
        $script:CSeq = 0
        $onNode = { $script:CSeq++; if ($script:CSeq -eq 1) { $null } else { @(120, 210) } }
        { Invoke-SwdProbeAcc -Handle 1 -Name 'Positon X 0.1' -Action select -Native $nat -CursorReader $onNode 3>$null } | Should -Throw 'SWD-PROBE-CURSOR-MOVED*unread*'
        $script:CSeq = 0
        $offNode = { $script:CSeq++; if ($script:CSeq -eq 1) { $null } else { @(859, 311) } }
        (Invoke-SwdProbeAcc -Handle 1 -Name 'Positon X 0.1' -Action select -Native $nat -CursorReader $offNode 3>$null).CursorNote | Should -Match 'unread'
    }
}

Describe 'SQA 2026-10-06 S16: census rows merge by window handle' {
    It 'keys a windowed row by its handle and a windowless one by its path' {
        Get-SwdSweepCensusKey ([pscustomobject]@{ Hwnd = 1234; Path = '/F/Edit' }) | Should -Be 'h1234'
        Get-SwdSweepCensusKey ([pscustomobject]@{ Hwnd = 0; Path = '/F/TabItem' }) | Should -Be 'p/F/TabItem'
        Get-SwdSweepCensusKey ([pscustomobject]@{ Path = '/F/ERROR' }) | Should -Be 'p/F/ERROR'
    }
    It 'Import-SwdSweepCensus keeps unnamed siblings that share a path, and a later dump wins per window' {
        $dir = Join-Path $TestDrive 'census-merge'; $cen = Join-Path $dir 'census'
        New-Item -ItemType Directory -Path $cen -Force | Out-Null
        $row = { param($h, $path, $name) [ordered]@{ Hwnd = $h; Path = $path; Name = $name; AutomationId = ''; Type = 'Edit'; Kind = '' } }
        [IO.File]::WriteAllText((Join-Path $cen '4243-S-00.json'), (@{ rows = @((& $row 11 '/F/Edit' 'a'), (& $row 12 '/F/Edit' 'b'), (& $row 0 '/F/TabItem' 't')) } | ConvertTo-Json -Depth 5))
        [IO.File]::WriteAllText((Join-Path $cen '4243-S-01.json'), (@{ rows = @((& $row 12 '/F/Edit' 'b2')) } | ConvertTo-Json -Depth 5))
        Mock Get-SwdProcess { [pscustomobject]@{ Id = 4243 } }
        $ctx = [pscustomobject]@{ Dir = $dir; Census = @{}; Map = @{}; Names = @{}; Pid = 0 }
        Import-SwdSweepCensus -Ctx $ctx -Modes @('S') | Should -BeTrue
        @($ctx.Census.S | ForEach-Object { $_.Name }) | Should -Be @('a', 'b2', 't')
    }
    It 'Invoke-SwdSweepCensus merges the same way, and dumps nothing once STOP is present (W3)' {
        Mock Switch-SwdSweepMode { $false }
        Mock Get-SwdProbeMain { [pscustomobject]@{ Handle = 1; Process = [pscustomobject]@{ Id = 4243 } } }
        $script:Dumps = 0
        Mock Invoke-SwdSweepUia3 { $script:Dumps++; [pscustomobject]@{ rows = @([pscustomobject]@{ Hwnd = 21; Path = '/F/Edit'; Name = 'x'; AutomationId = ''; Type = 'Edit'; Kind = '' },
                                                                                   [pscustomobject]@{ Hwnd = 22; Path = '/F/Edit'; Name = 'y'; AutomationId = ''; Type = 'Edit'; Kind = '' }) } }
        $stop = Join-Path $TestDrive 'STOP-census'
        $ctx = [pscustomobject]@{ Dir = (Join-Path $TestDrive 'cen2'); StopFile = $stop; Census = @{}; Map = @{}; Names = @{}; Notes = (New-Object System.Collections.Generic.List[string]); Pid = 0 }
        Invoke-SwdSweepCensus -Mode 'S' -Ctx $ctx
        @($ctx.Census.S).Count | Should -Be 2
        New-Item -ItemType File -Path $stop | Out-Null
        { Invoke-SwdSweepCensus -Mode 'S' -Ctx $ctx } | Should -Throw 'SWD-PROBE-STOPPED*'
        $script:Dumps | Should -Be 1
    }
}

Describe 'SQA 2026-10-06 S15: a census walk cut short is refused, never used' {
    It 'throws on a truncated dump and sets the file aside, so no cached reader picks it up' {
        $out = Join-Path $TestDrive 'trunc.json'
        function py { [IO.File]::WriteAllText($args[3], '{"truncated": true, "elements": 8001, "seconds": 120.4, "rows": []}') }
        { Invoke-SwdSweepUia3 -OutFile $out } | Should -Throw '*cut its walk short*'
        Test-Path -LiteralPath $out | Should -BeFalse
        Test-Path -LiteralPath "$out.truncated" | Should -BeTrue
    }
    It 'returns a complete dump as before' {
        $out = Join-Path $TestDrive 'complete.json'
        function py { [IO.File]::WriteAllText($args[3], '{"truncated": false, "elements": 2, "seconds": 0.1, "rows": [{"Path": "/a"}, {"Path": "/b"}]}') }
        @((Invoke-SwdSweepUia3 -OutFile $out).rows).Count | Should -Be 2
    }
}

Describe 'SQA 2026-10-06 S3: a lone OK on an overwrite or licence notice stops the run' {
    It 'stops on <label>' -ForEach @(
        @{ label = 'an overwrite notice'; title = 'SWD'; text = 'The file already exists and will be overwritten.' }
        @{ label = 'a licence notice'; title = 'Licence'; text = 'Your licence expires in 3 days.' }
        @{ label = 'a LICENSE notice in capitals'; title = 'SWD'; text = 'LICENSE SERVER UNREACHABLE' }
        @{ label = 'ecraser, unaccented'; title = 'SWD'; text = 'Ecraser le fichier existant ?' }
        @{ label = 'ecraser, e-acute'; title = 'SWD'; text = ([string][char]0x00E9 + 'craser le fichier existant ?') }
        @{ label = 'ECRASER, capital E-acute'; title = 'SWD'; text = ([string][char]0x00C9 + 'CRASER LE FICHIER') }
    ) {
        $null -eq (Select-SwdSweepDialogAction -Title $title -Texts @($text) -Buttons @('OK')) | Should -BeTrue
    }
    It 'still acknowledges a plain information box, and every allowlisted caption and tab still passes' {
        Select-SwdSweepDialogAction -Title 'SWD' -Texts @('Value out of range') -Buttons @('OK') | Should -Be 'OK'
        foreach ($c in $script:ProbeAllowedButtons) { Test-SwdProbeAllowedButton $c | Should -BeTrue -Because $c }
        foreach ($t in $script:ProbeAllowedTabs) { Test-SwdProbeAllowedTab $t | Should -BeTrue -Because $t }
    }
}

Describe 'SQA 2026-10-06 S9: redaction ignores case, and STOP is reported without the profile path' {
    It 'collapses the profile or OneDrive root spelled in another case (<label>)' -ForEach @(
        @{ label = 'upper-case profile'; shape = 'upper' }
        @{ label = 'lower-case profile'; shape = 'lower' }
        @{ label = 'upper-case OneDrive root'; shape = 'od' }
    ) {
        $saved = $env:OneDriveCommercial
        $fake = Join-Path $env:USERPROFILE 'OneDrive - Contoso Fixture Tenant'
        try {
            $env:OneDriveCommercial = $fake
            $msg = switch ($shape) {
                'upper' { 'cannot read ' + $env:USERPROFILE.ToUpperInvariant() + '\x.fynbs' }
                'lower' { 'cannot read ' + $env:USERPROFILE.ToLowerInvariant() + '\x.fynbs' }
                'od' { 'cannot read ' + $fake.ToUpperInvariant() + '\Documents\x.fynbs' }
            }
            $out = Format-MessageForDisplay $msg
            $out | Should -Not -Match ([regex]::Escape($env:USERPROFILE))
            $out | Should -Not -Match 'Contoso Fixture Tenant'
            if ($shape -eq 'od') { $out | Should -Match ([regex]::Escape('~\OneDrive\Documents\x.fynbs')) } else { $out | Should -Match ([regex]::Escape('~\x.fynbs')) }
        } finally { $env:OneDriveCommercial = $saved }
    }
    It 'reports a STOP file without the username' {
        $stop = Join-Path $TestDrive 'STOP-r9'
        New-Item -ItemType File -Path $stop | Out-Null
        $why = Test-SwdProbeStop -StopFile $stop -CursorReader { $null }
        $why | Should -BeLike 'stop file present*'
        $why | Should -Not -Match ([regex]::Escape($env:USERPROFILE))
    }
}

Describe 'SQA 2026-10-06 S11: the never-sweep rules hold on a resumed manifest' {
    It 'plans no skip-listed, grid-skipped or denylisted input, whatever state.json holds' {
        $man = @(
            [pscustomobject]@{ Id = 'D/TextBox_infos_fin'; Mode = 'D'; Kind = 'numeric'; Target = 'TextBox_infos_fin'; Values = @('1') }
            [pscustomobject]@{ Id = 'D/grid:Nom'; Mode = 'D'; Kind = 'grid'; Target = 'Nom'; Values = @('x') }
            [pscustomobject]@{ Id = 'D/grid:Delete_hydro'; Mode = 'D'; Kind = 'grid'; Target = 'Delete_hydro'; Values = @('1') }
            [pscustomobject]@{ Id = 'S/len'; Mode = 'S'; Kind = 'numeric'; Target = 'len'; Values = @('2') }
            [pscustomobject]@{ Id = 'D/grid:Ra_micron'; Mode = 'D'; Kind = 'grid'; Target = 'Ra_micron'; Values = @('5') }
        )
        @(Get-SwdSweepPlan -Manifest $man | ForEach-Object { $_.Input.Id } | Select-Object -Unique) | Should -Be @('S/len', 'D/grid:Ra_micron')
    }
}

Describe 'SQA 2026-10-06 S21: the T13 CSV carries its rows, header first, CRLF' {
    It 'round-trips the rows Export-Csv wrote, without the BOM' {
        Mock Get-SwdProbeMain { [pscustomobject]@{ Handle = 1 } }
        Mock Get-SwdProbeLengthContext { [pscustomobject]@{ LengthMm = 2000 } }
        Mock Set-SwdProbeLength { [pscustomobject]@{ Applied = $true; GeometryMs = 10; Settle = [pscustomobject]@{ SettleMs = 100; TimedOut = $false; FirstResponsiveMs = 10; FirstCpuQuietMs = 20; FirstFramesStableMs = 30; MaxCpuPct = 5 } } }
        $d = Join-Path $TestDrive 't13b'
        New-Item -ItemType Directory -Path $d | Out-Null
        Invoke-SwdProbeT13 -RunDir $d -DeltaMm 1.0 -Repeats 2 -StopFile 'STOP' | Out-Null
        $p = Join-Path $d 't13-settle.csv'
        $text = [IO.File]::ReadAllText($p)
        $text.Split("`n")[0].TrimEnd("`r") | Should -BeExactly '"I","Target","Applied","GeometryMs","SettleMs","TimedOut","FirstResponsiveMs","FirstCpuQuietMs","FirstFramesStableMs","MaxCpuPct"'
        $text.EndsWith("`r`n") | Should -BeTrue
        $rows = @(Import-Csv -LiteralPath $p)
        $rows.Count | Should -Be 2
        @($rows | ForEach-Object { $_.Target }) | Should -Be @('2001', '2000')
        $rows[0].SettleMs | Should -Be '100'
    }
}

Describe 'SQA 2026-10-06 W1/W2: a trial restores whatever stops its write (Invoke-SwdSweepTrial)' {
    BeforeEach {
        $script:TW = New-Object System.Collections.Generic.List[object]
        $script:TSaved = New-Object System.Collections.Generic.List[object]
        $script:TReads = New-Object System.Collections.Generic.Queue[object]
        $script:TChanges = @()
        Mock Enter-SwdSweepInputView { 'S|SizeConfig' }
        Mock Get-SwdSweepVolatility { @{} }
        Mock Get-SwdProbeSnapshot { [pscustomobject]@{ Origin = @(0, 0); Label = $Label } }
        Mock Compare-SwdProbeSnapshot { [pscustomobject]@{ ImageError = $null; MsaaTruncated = $false } }
        Mock ConvertTo-SwdSweepChange { $script:TChanges }
        Mock Get-SwdSweepHandle { 0 }
        Mock Get-SwdProcess { [pscustomobject]@{ Id = 4243 } }
        Mock Save-SwdSweepState { $script:TSaved.Add($Ctx.RestorePendingPid) }
        Mock Read-SwdSweepInput { if ($script:TReads.Count) { $script:TReads.Dequeue() } else { '2000' } }
        $script:TCtx = [pscustomobject]@{ RunDir = $TestDrive; Seq = 0; StopFile = (Join-Path $TestDrive 'STOP-trial'); Mask = $null; RestorePendingPid = [int64]0 }
        $script:TSpec = [pscustomobject]@{ Id = 'S/TextBox_board_length_mm'; Mode = 'S'; Kind = 'numeric'; Target = 'TextBox_board_length_mm'; Label = 'len'
                                           TabPath = 'SizeConfig'; Apply = 'Button_appliquer_longuer'; Options = @() }
        $script:TOk = { [pscustomobject]@{ ReadBack = '2200'; SettleMs = 1; TimedOut = $false; Dialogs = @() } }
    }
    It 'a STOP raised after the write still restores the base, without the kill switch, and is rethrown' {
        Mock Write-SwdSweepInput { $script:TW.Add([pscustomobject]@{ Value = $Value; StopFile = $StopFile }); if ($StopFile) { throw 'SWD-PROBE-STOPPED: cursor parked in the top-left corner' }; & $script:TOk }
        { Invoke-SwdSweepTrial -Spec $script:TSpec -Value '2200' -Ctx $script:TCtx } | Should -Throw 'SWD-PROBE-STOPPED*'
        @($script:TW | ForEach-Object { $_.Value }) | Should -Be @('2200', '2000')
        $script:TW[0].StopFile | Should -Be $script:TCtx.StopFile
        [string]::IsNullOrEmpty($script:TW[1].StopFile) | Should -BeTrue
        $script:TSaved[0] | Should -Be 4243
        $script:TCtx.RestorePendingPid | Should -Be 4243
    }
    It 'a <label> halts with no restore attempted, and leaves the restore pending' -ForEach @(
        @{ label = 'dialog with no safe button'; msg = 'SWD-SWEEP-DIALOG: dialog x offers no safe button; stopping.' }
        @{ label = 'moved cursor'; msg = 'SWD-PROBE-CURSOR-MOVED: the MSAA select moved the cursor; it simulated input.' }
    ) {
        $script:TMsg = $msg
        Mock Write-SwdSweepInput { $script:TW.Add([pscustomobject]@{ Value = $Value; StopFile = $StopFile }); if ($StopFile) { throw $script:TMsg }; & $script:TOk }
        { Invoke-SwdSweepTrial -Spec $script:TSpec -Value '2200' -Ctx $script:TCtx } | Should -Throw ($msg.Split(':')[0] + '*')
        $script:TW.Count | Should -Be 1
        $script:TCtx.RestorePendingPid | Should -Be 4243
    }
    It 'an exact restore puts the pending flag back as it was (<label>)' -ForEach @(
        @{ label = 'none before'; before = 0 }
        @{ label = 'a process gone since'; before = 4001 }
    ) {
        $script:TCtx.RestorePendingPid = [int64]$before
        Mock Write-SwdSweepInput { $script:TW.Add([pscustomobject]@{ Value = $Value; StopFile = $StopFile }); & $script:TOk }
        $rec = Invoke-SwdSweepTrial -Spec $script:TSpec -Value '2200' -Ctx $script:TCtx
        $rec.RestoreExact | Should -BeTrue
        $script:TCtx.RestorePendingPid | Should -Be $before
        $script:TSaved[0] | Should -Be 4243
        @($script:TW | ForEach-Object { $_.Value }) | Should -Be @('2200', '2000')
    }
    It 'an inexact restore leaves the flag pending' {
        $script:TChanges = @([pscustomobject]@{ Ch = 'msaa'; Owner = 'G'; Item = 'volume_litre'; Field = 'Value'; From = '34'; To = '35' })
        Mock Write-SwdSweepInput { $script:TW.Add([pscustomobject]@{ Value = $Value; StopFile = $StopFile }); & $script:TOk }
        (Invoke-SwdSweepTrial -Spec $script:TSpec -Value '2200' -Ctx $script:TCtx).RestoreExact | Should -BeFalse
        $script:TCtx.RestorePendingPid | Should -Be 4243
    }
    It 'a check box is toggled back only when it reads changed' {
        $spec = [pscustomobject]@{ Id = 'D/CheckBox_planing_forces'; Mode = 'D'; Kind = 'check'; Target = 'CheckBox_planing_forces'; Label = 'forces'; TabPath = 'Test Position'; Apply = $null; Options = @() }
        Mock Write-SwdSweepInput { $script:TW.Add([pscustomobject]@{ Value = $Value; StopFile = $StopFile }); if ($StopFile) { throw 'SWD-PROBE-STOPPED: x' } }
        # It toggled, then STOP: it reads changed, so the restore toggles it back.
        $script:TReads.Enqueue('True'); $script:TReads.Enqueue('False')
        { Invoke-SwdSweepTrial -Spec $spec -Value 'toggle' -Ctx $script:TCtx } | Should -Throw 'SWD-PROBE-STOPPED*'
        @($script:TW | ForEach-Object { $_.Value }) | Should -Be @('toggle', 'toggle')
        # Stopped before it toggled: it reads unchanged, so nothing is pressed again.
        $script:TW.Clear(); $script:TReads.Clear(); $script:TReads.Enqueue('True'); $script:TReads.Enqueue('True')
        { Invoke-SwdSweepTrial -Spec $spec -Value 'toggle' -Ctx $script:TCtx } | Should -Throw 'SWD-PROBE-STOPPED*'
        @($script:TW | ForEach-Object { $_.Value }) | Should -Be @('toggle')
    }
    It 'never writes the volume target back, so its restore stays pending for the relaunch (W2)' {
        $spec = [pscustomobject]@{ Id = 'S/NumericUpDownBoardVolumeInput'; Mode = 'S'; Kind = 'numeric'; Target = 'NumericUpDownBoardVolumeInput'; Label = 'volume'; TabPath = 'SizeConfig'; Apply = 'Button_volume'; Options = @() }
        $script:TReads.Enqueue('10')
        Mock Write-SwdSweepInput { $script:TW.Add([pscustomobject]@{ Value = $Value; StopFile = $StopFile }); & $script:TOk }
        [void](Invoke-SwdSweepTrial -Spec $spec -Value '11' -Ctx $script:TCtx)
        @($script:TW | ForEach-Object { $_.Value }) | Should -Be @('11')
        $script:TCtx.RestorePendingPid | Should -Be 4243
    }
}

Describe 'SQA 2026-10-06 W1/W2: a sweep chunk never hands SWD back holding a changed board' {
    BeforeAll {
        function Write-SweepState([string]$Dir, $Manifest, [int64]$Pending, [string[]]$Relaunched = @(), [string[]]$Done = @()) {
            Write-SwdProbeJson -Path (Join-Path $Dir 'state.json') -Depth 8 -Object ([pscustomobject]@{ Board = 'b_Copy_1'; Pid = 0; Manifest = @($Manifest); Done = @($Done); Attempts = @{}
                Skipped = @(); Restarts = 0; WarmPid = 0; Relaunched = @($Relaunched); Halted = $null; Seq = 0; Notes = @(); RestorePendingPid = $Pending })
        }
        function Invoke-Chunk([string]$Dir) { Invoke-SwdSweep -Pass Map -Dir $Dir -RunDir $TestDrive -StopFile (Join-Path $TestDrive 'STOP-chunk') }
    }
    BeforeEach {
        $script:SDir = Join-Path $TestDrive ('swc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:SDir | Out-Null
        $script:SavedExe = $script:SweepExe; $script:SweepExe = Join-Path $TestDrive 'no-such-app.exe'
        $script:SPid = [int64]4243
        Mock Start-Process { throw 'Start-Process reached in a test' }
        Mock Stop-Process { throw 'Stop-Process reached in a test' }
        Mock Get-Process { [pscustomobject]@{ Id = $script:SPid } } -ParameterFilter { $Name -contains 'SurfHydrodynamics' }
        Mock Get-SwdSweepPid { $script:SPid }
        Mock Get-SwdProcess { [pscustomobject]@{ Id = $script:SPid } }
        Mock Stop-SwdSweepApp { 'closed' }
        Mock Start-SwdSweepApp { $script:SPid += 4; 'b_Copy_1' }
        Mock Get-SwdProbeMain { [pscustomobject]@{ Handle = 1; Title = 'FYN Shaper Wave Dynamics   <Board: b_Copy_1(2000mm)>'; Process = [pscustomobject]@{ Id = $script:SPid } } }
        Mock Clear-SwdSweepPopup { }
        Mock Import-SwdSweepCensus { $true }
        Mock Invoke-SwdSweepCensus { }
        Mock Invoke-SwdSweepWarmup { 'warm' }
        Mock Find-SwdProbeNoiseMask { $null }
        # A manifest whose trials are all done: nothing runs, so only the restore bookkeeping shows.
        $script:DoneMan = @([pscustomobject]@{ Id = 'S/len'; Mode = 'S'; Kind = 'numeric'; Target = 'len'; TabPath = 'SizeConfig'; Values = @('2200') })
        $script:DoneIds = @('S/len|2200|r1', 'S/len|2200|r2')
    }
    AfterEach { $script:SweepExe = $script:SavedExe }
    It 'relaunches before anything reads the board when a restore is pending in the running SWD (W1)' {
        Write-SweepState $script:SDir $script:DoneMan 4243 @() $script:DoneIds
        Invoke-Chunk $script:SDir
        Should -Invoke Stop-SwdSweepApp -Times 1 -Exactly
        Should -Invoke Start-SwdSweepApp -Times 1 -Exactly -ParameterFilter { $StopFile -like '*STOP-chunk' }
        (Read-SwdProbeState -Path (Join-Path $script:SDir 'state.json')).RestorePendingPid | Should -Be 0
    }
    It 'drops a pending restore that belongs to a process no longer running, with no relaunch' {
        Write-SweepState $script:SDir $script:DoneMan 4001 @() $script:DoneIds
        Invoke-Chunk $script:SDir
        Should -Invoke Stop-SwdSweepApp -Times 0 -Exactly
        Should -Invoke Start-SwdSweepApp -Times 0 -Exactly
        (Read-SwdProbeState -Path (Join-Path $script:SDir 'state.json')).RestorePendingPid | Should -Be 0
    }
    It 'closes SWD at the end of a chunk whose last restore was inexact (W2)' {
        $man = @([pscustomobject]@{ Id = 'S/len'; Mode = 'S'; Kind = 'numeric'; Target = 'len'; TabPath = 'SizeConfig'; Values = @('2200') })
        Write-SweepState $script:SDir $man 0 @('S/len')
        Mock Invoke-SwdSweepTrial { $Ctx.RestorePendingPid = $script:SPid; [pscustomobject]@{ Id = "$($Spec.Id)|$Value|r$Rep"; RestoreExact = $false } }
        Invoke-Chunk $script:SDir
        Should -Invoke Invoke-SwdSweepTrial -Times 2 -Exactly
        Should -Invoke Stop-SwdSweepApp -Times 1 -Exactly
        Should -Invoke Start-SwdSweepApp -Times 0 -Exactly
        $st = Read-SwdProbeState -Path (Join-Path $script:SDir 'state.json')
        $st.RestorePendingPid | Should -Be 0
        @($st.Notes | Where-Object { $_ -like 'chunk end with a restore pending*' }).Count | Should -Be 1
    }
    It 'relaunches after EVERY trial of the volume target, even one whose diff looks exact (W2)' {
        $man = @([pscustomobject]@{ Id = 'S/NumericUpDownBoardVolumeInput'; Mode = 'S'; Kind = 'numeric'; Target = 'NumericUpDownBoardVolumeInput'; TabPath = 'SizeConfig'; Values = @('11') })
        Write-SweepState $script:SDir $man 0 @('S/NumericUpDownBoardVolumeInput')
        Mock Invoke-SwdSweepTrial { $Ctx.RestorePendingPid = $script:SPid; [pscustomobject]@{ Id = "$($Spec.Id)|$Value|r$Rep"; RestoreExact = $true } }
        Invoke-Chunk $script:SDir
        Should -Invoke Start-SwdSweepApp -Times 2 -Exactly
        Should -Invoke Stop-SwdSweepApp -Times 2 -Exactly
        (Read-SwdProbeState -Path (Join-Path $script:SDir 'state.json')).RestorePendingPid | Should -Be 0
    }
}
